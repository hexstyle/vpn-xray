#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"

grep -q 'ROUTER_RULES_SKIP_EFFECTIVE_COLLAPSE=1 .*apply_xray_internal' "$ROUTER_RULES_FILE" || {
	printf 'FAIL: fast local cutover must skip expensive effective-rules collapse in the foreground path\n' >&2
	exit 1
}

grep -q 'ROUTER_RULES_INCREMENTAL_IPSET=1 .*apply_xray_internal' "$ROUTER_RULES_FILE" || {
	printf 'FAIL: fast local cutover must update ipset incrementally in the foreground path\n' >&2
	exit 1
}

if grep -q "set_sync_phase refreshing_dns 'Refreshing full DNS resolution after fast local apply'" "$ROUTER_RULES_FILE"; then
	printf 'FAIL: background-tick must not run full DNS/collapse refresh after fast local apply under the global lock\n' >&2
	exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

VX_LIB_COMMON="$ROOT/routers/common/files/lib-common.sh" ROUTER_RULES_LIB_ONLY=1 . "$ROUTER_RULES_FILE"

status_file="$TMPDIR/status"
events_file="$TMPDIR/events"
: > "$events_file"

status_get() {
	sed -n "s/^$1=//p" "$status_file" 2>/dev/null | sed -n '1p'
}

status_set() {
	local key="$1"
	local value="$2"
	local tmp="$TMPDIR/status.tmp"

	grep -v "^${key}=" "$status_file" > "$tmp" 2>/dev/null || true
	printf '%s=%s\n' "$key" "$value" >> "$tmp"
	mv "$tmp" "$status_file"
}

sync_mode() { printf '%s\n' 'push'; }
sync_actor() { printf '%s\n' 'ui-sync'; }
repo_configured() { return 0; }
resolved_snapshot_needs_apply_internal() { return 1; }

xray_needs_apply_internal() {
	[ "$(status_get applied)" != '1' ]
}

hard_cutover_xray_internal() {
	printf 'cutover fast=%s skip_collapse=%s\n' "${ROUTER_RULES_FAST_RESOLVE:-0}" "${ROUTER_RULES_SKIP_EFFECTIVE_COLLAPSE:-0}" >> "$events_file"
	status_set applied 1
}

sync_repo_internal() {
	printf 'git-sync\n' >> "$events_file"
	return 0
}

set_sync_phase() {
	printf 'phase %s\n' "$1" >> "$events_file"
}

sync_apply_xray_internal

expected="$TMPDIR/expected"
cat > "$expected" <<'EOF'
phase local_apply_in_progress
cutover fast=1 skip_collapse=0
phase checking_remote
git-sync
phase verified
EOF

cmp -s "$expected" "$events_file" || {
	printf 'FAIL: push mode must fast-apply local routing before Git sync\n' >&2
	printf 'Expected:\n' >&2
	cat "$expected" >&2
	printf 'Actual:\n' >&2
	cat "$events_file" >&2
	exit 1
}

printf 'ok\n'
