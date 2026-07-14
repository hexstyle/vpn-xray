#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
CAPTURE="$ROOT/routers/common/files/xray-diag-capture.sh"
GL_MON="$ROOT/routers/gl-mt3000-glinet/files/xray-health-monitor.init"
ASUS_MON="$ROOT/routers/asus-tuf-ax4200-openwrt/files/xray-health-monitor.init"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

[ -f "$CAPTURE" ] || fail "xray-diag-capture.sh must exist in routers/common/files"

# --- Static contract ---

grep -q 'MIN_INTERVAL_SECONDS="${VX_DIAG_MIN_INTERVAL:-1800}"' "$CAPTURE" \
	|| fail "capture must rate-limit to one snapshot per 30 minutes"

grep -q 'KEEP_LOGS=5' "$CAPTURE" \
	|| fail "capture must keep exactly 5 most recent logs"

grep -q 'mkdir "$LOCK_DIR"' "$CAPTURE" \
	|| fail "capture must take an atomic mkdir lock against concurrent runs"

grep -q 'LOCK_STALE_SECONDS' "$CAPTURE" \
	|| fail "capture must reclaim a stale lock left by a crashed holder"

grep -q '/tmp/vpn-xray-diag' "$CAPTURE" \
	|| fail "capture must store logs in RAM (/tmp)"

for mon in "$GL_MON" "$ASUS_MON"; do
	grep -q 'api.anthropic.com' "$mon" \
		|| fail "$(basename "$(dirname "$(dirname "$mon")")") monitor must probe claude (api.anthropic.com)"
	grep -q 'api.openai.com' "$mon" \
		|| fail "$(basename "$(dirname "$(dirname "$mon")")") monitor must probe codex (api.openai.com)"
	grep -q 'xray-diag-capture.sh' "$mon" \
		|| fail "monitor must trigger xray-diag-capture.sh on AI unavailability"
	grep -q 'AI_UNREACHABLE' "$mon" \
		|| fail "monitor must record an AI_UNREACHABLE alert"
	grep -q 'xray_failsafe_hold_active' "$mon" \
		|| fail "monitor must not fire AI diag while a failsafe hold is active"
	# redsocks-down must be captured, not only alerted (the hole that let
	# the path stay degraded for minutes during an interrupted install).
	grep -q 'path-down-xu' "$mon" \
		|| fail "monitor must capture a diag when a path daemon is down, not only on AI-unreachable"
	grep -q 'guard_restart_redsocks' "$mon" \
		|| fail "monitor must auto-recover redsocks, not just alert REDSOCKS_DOWN"
	grep -q 'REDSOCKS_DOWN_SUSTAINED' "$mon" \
		|| fail "monitor must restart redsocks after a sustained down streak"
	grep -q 'codex-transproxy restart' "$mon" \
		|| fail "redsocks recovery must go through codex-transproxy restart"
done

for inst in "$ROOT/routers/gl-mt3000-glinet/install-platform.sh" \
	"$ROOT/routers/asus-tuf-ax4200-openwrt/install-platform.sh"; do
	grep -q 'xray-diag-capture.sh" /usr/share/vpn-xray/xray-diag-capture.sh' "$inst" \
		|| fail "$(basename "$(dirname "$inst")") installer must ship xray-diag-capture.sh"
	grep -qE 'chmod 755 .*xray-diag-capture\.sh' "$inst" \
		|| fail "$(basename "$(dirname "$inst")") installer must chmod xray-diag-capture.sh"
done

# --- Behavioral: rate limit, lock, retention ---

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
DIAG="$tmpdir/diag"

# 1. Fresh run captures (probes disabled: no network in tests).
VX_DIAG_DIR="$DIAG" VX_DIAG_PROBES=0 sh "$CAPTURE" test-one >/dev/null \
	|| fail "fresh capture must succeed"
count="$(ls "$DIAG"/diag-*.log 2>/dev/null | wc -l | tr -d ' ')"
[ "$count" = "1" ] || fail "fresh capture must produce exactly one log (got $count)"

# 2. Immediate second run is rate-limited: no new log.
VX_DIAG_DIR="$DIAG" VX_DIAG_PROBES=0 sh "$CAPTURE" test-two >/dev/null \
	|| fail "rate-limited run must still exit 0"
count="$(ls "$DIAG"/diag-*.log 2>/dev/null | wc -l | tr -d ' ')"
[ "$count" = "1" ] || fail "second run within 30 min must not capture (got $count logs)"

# 3. Held lock blocks capture even when the rate limit allows it.
echo 0 > "$DIAG/.last-capture-epoch"
mkdir -p "$DIAG/.lock"
date +%s > "$DIAG/.lock/epoch"
VX_DIAG_DIR="$DIAG" VX_DIAG_PROBES=0 sh "$CAPTURE" test-locked >/dev/null \
	|| fail "locked run must exit 0"
count="$(ls "$DIAG"/diag-*.log 2>/dev/null | wc -l | tr -d ' ')"
[ "$count" = "1" ] || fail "a held lock must block concurrent capture (got $count logs)"
rm -rf "$DIAG/.lock"

# 4. Stale lock (older than LOCK_STALE_SECONDS) is reclaimed.
echo 0 > "$DIAG/.last-capture-epoch"
mkdir -p "$DIAG/.lock"
echo 1 > "$DIAG/.lock/epoch"
VX_DIAG_DIR="$DIAG" VX_DIAG_PROBES=0 sh "$CAPTURE" test-stale >/dev/null \
	|| fail "stale-lock run must succeed"
count="$(ls "$DIAG"/diag-*.log 2>/dev/null | wc -l | tr -d ' ')"
[ "$count" = "2" ] || fail "stale lock must be reclaimed and capture proceed (got $count logs)"

# 5. Retention: only the 5 newest logs survive.
i=1
while [ "$i" -le 7 ]; do
	f="$DIAG/diag-2020010$i-00000$i-seed.log"
	echo seed > "$f"
	touch -t "2020010${i}0000" "$f" 2>/dev/null || true
	i=$((i + 1))
done
echo 0 > "$DIAG/.last-capture-epoch"
VX_DIAG_DIR="$DIAG" VX_DIAG_PROBES=0 sh "$CAPTURE" test-rotate >/dev/null \
	|| fail "rotation run must succeed"
count="$(ls "$DIAG"/diag-*.log 2>/dev/null | wc -l | tr -d ' ')"
[ "$count" = "5" ] || fail "retention must keep exactly 5 logs (got $count)"
ls "$DIAG"/diag-*-test-rotate.log >/dev/null 2>&1 \
	|| fail "retention must keep the newest capture"

printf 'ok\n'
