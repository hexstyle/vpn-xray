#!/bin/sh
# xray-diag-capture.sh — detailed diagnostic snapshot taken when the AI
# endpoints (Claude / Codex) become unreachable through the tunnel.
#
# Contract:
#   - single instance: atomic mkdir lock, stale after LOCK_STALE_SECONDS
#   - rate limit: at most one capture per MIN_INTERVAL_SECONDS (30 min)
#   - retention: KEEP_LOGS most recent captures, stored in RAM (/tmp)
#
# Usage: xray-diag-capture.sh [reason-slug]
# Test hooks: VX_DIAG_DIR, VX_DIAG_MIN_INTERVAL, VX_DIAG_PROBES=0.

set -u

DIAG_DIR="${VX_DIAG_DIR:-/tmp/vpn-xray-diag}"
LOCK_DIR="$DIAG_DIR/.lock"
STAMP_FILE="$DIAG_DIR/.last-capture-epoch"
MIN_INTERVAL_SECONDS="${VX_DIAG_MIN_INTERVAL:-1800}"
KEEP_LOGS=5
LOCK_STALE_SECONDS=600
LOCAL_HTTP_PROXY="${LOCAL_HTTP_PROXY:-http://127.0.0.1:1083}"
LIVE_SOCKS_PORT="${LIVE_SOCKS_PORT:-1084}"
XRAY_CONFIG='/etc/xray/codex-xray.json'
ADMIN_CGI='/www/cgi-bin/xray-admin'
REASON="$(printf '%s' "${1:-manual}" | tr -c 'a-zA-Z0-9_-' '-')"

now() {
	date +%s
}

rate_limited() {
	local last
	last="$(cat "$STAMP_FILE" 2>/dev/null || echo 0)"
	[ "$(( $(now) - last ))" -lt "$MIN_INTERVAL_SECONDS" ]
}

rate_limited && exit 0

mkdir -p "$DIAG_DIR"

# Atomic lock. A crashed holder leaves the dir behind: its epoch marker
# makes it reclaimable after LOCK_STALE_SECONDS.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
	lock_epoch="$(cat "$LOCK_DIR/epoch" 2>/dev/null || true)"
	if [ -z "$lock_epoch" ]; then
		# Holder may be between mkdir and its epoch write — give it a moment.
		sleep 2
		lock_epoch="$(cat "$LOCK_DIR/epoch" 2>/dev/null || echo 0)"
	fi
	[ "$(( $(now) - lock_epoch ))" -gt "$LOCK_STALE_SECONDS" ] || exit 0
	rm -rf "$LOCK_DIR"
	mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
now > "$LOCK_DIR/epoch"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

# Re-check under the lock: a parallel caller may have just captured.
rate_limited && exit 0
now > "$STAMP_FILE"

out="$DIAG_DIR/diag-$(date +%Y%m%d-%H%M%S)-$REASON.log"

section() {
	printf '\n===== %s =====\n' "$1"
}

probe_url() {
	# probe_url <label> <url> [curl proxy args...]
	local label="$1" url="$2"
	shift 2
	printf -- '--- %s %s\n' "$label" "$url"
	curl -ksS -o /dev/null -m 10 "$@" \
		-w 'code=%{http_code} connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s\n' \
		"$url" 2>&1 || true
}

{
	echo "vpn-xray diagnostic capture"
	echo "reason: $REASON"
	echo "date: $(date) (epoch $(now))"

	if [ "${VX_DIAG_PROBES:-1}" != "0" ]; then
		section "AI endpoints via tunnel (socks 127.0.0.1:$LIVE_SOCKS_PORT)"
		probe_url claude https://api.anthropic.com/v1/models --socks5-hostname "127.0.0.1:$LIVE_SOCKS_PORT"
		probe_url codex https://api.openai.com/v1/models --socks5-hostname "127.0.0.1:$LIVE_SOCKS_PORT"

		section "AI endpoints direct (WAN, expected blocked/403)"
		probe_url claude-direct https://api.anthropic.com/v1/models
		probe_url codex-direct https://api.openai.com/v1/models

		section "tunnel egress"
		curl -ksS -m 8 --socks5-hostname "127.0.0.1:$LIVE_SOCKS_PORT" https://ipinfo.io/ip 2>&1 || true
		echo

		section "VPS reachability (uplink leg)"
		vps_addr="$(jsonfilter -i "$XRAY_CONFIG" -e '@.outbounds[0].settings.vnext[0].address' 2>/dev/null | sed -n '1p')"
		vps_port="$(jsonfilter -i "$XRAY_CONFIG" -e '@.outbounds[0].settings.vnext[0].port' 2>/dev/null | sed -n '1p')"
		echo "vps: ${vps_addr:-?}:${vps_port:-?}"
		if [ -n "$vps_addr" ]; then
			ip route get "$vps_addr" 2>&1 || true
			ping -c 3 -W 2 "$vps_addr" 2>&1 | tail -2 || true
			i=1
			while [ "$i" -le 5 ]; do
				probe_url "tls-$i" "https://$vps_addr:${vps_port:-443}/"
				i=$((i + 1))
			done
		fi

		section "admin status"
		[ -x "$ADMIN_CGI" ] && QUERY_STRING='action=status' REQUEST_METHOD=GET "$ADMIN_CGI" 2>&1 | tail -1
		echo

		section "admin smoke"
		[ -x "$ADMIN_CGI" ] && QUERY_STRING='action=smoke' REQUEST_METHOD=GET "$ADMIN_CGI" 2>&1 | tail -1
		echo
	fi

	section "runtime"
	echo "loadavg: $(cat /proc/loadavg 2>/dev/null)"
	grep -E 'MemTotal|MemAvailable' /proc/meminfo 2>/dev/null || true
	echo "conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)"
	for pidfile in /var/run/codex-xray.pid /var/run/redsocks.pid; do
		pid="$(cat "$pidfile" 2>/dev/null || true)"
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			echo "$pidfile: pid=$pid up"
		else
			echo "$pidfile: DOWN"
		fi
	done
	netstat -ltn 2>/dev/null | grep -E ':(1083|1084|12345) ' || true

	section "nat / ipset"
	iptables -t nat -S PREROUTING 2>/dev/null | grep CODEX_TRANSPROXY || echo "no CODEX_TRANSPROXY rule"
	iptables -t nat -L CODEX_TRANSPROXY -vn 2>/dev/null | head -12 || true
	ipset list xray_selective_dst 2>/dev/null | sed -n '1,7p' || true

	section "xray error log (tail)"
	tail -n 80 /etc/xray/logs/codex-xray-error.log 2>/dev/null || true

	section "syslog: redsocks/xray/uplink (tail)"
	logread 2>/dev/null | grep -iE 'redsocks|xray|uplink' | grep -v failsafe | tail -n 60 || true

	section "health monitor (tail)"
	tail -n 20 /tmp/xray-health.tsv 2>/dev/null || true

	section "health alerts (tail)"
	tail -n 20 /tmp/xray-health-alerts.log 2>/dev/null || true
} > "$out" 2>&1

# Retention: keep the KEEP_LOGS newest captures.
ls -1t "$DIAG_DIR"/diag-*.log 2>/dev/null | sed -n "$((KEEP_LOGS + 1)),\$p" | while read -r old; do
	rm -f "$old"
done

logger -t vpn-xray-diag "captured $out (reason=$REASON)" 2>/dev/null || true
echo "$out"
