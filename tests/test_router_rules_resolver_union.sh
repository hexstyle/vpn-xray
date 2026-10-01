#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

VX_LIB_COMMON="$ROOT/routers/common/files/lib-common.sh" VX_RULES_LIB_DIR="$ROOT/routers/common/files" ROUTER_RULES_LIB_ONLY=1 . "$ROUTER_RULES_FILE"

fallback_calls="$TMPDIR/fallback.calls"
: > "$fallback_calls"

resolve_via_doh() { printf 'doh\n' >> "$fallback_calls"; printf '%s\n' 192.0.2.10; }
resolve_via_dig() {
	case "$2" in
		9.9.9.9) printf '%s\n' 198.51.100.20;;
		*) return 1;;
	esac
}
resolve_via_nslookup() {
	case "$2" in
		208.67.222.222) printf '%s\n' 203.0.113.30;;
		*) return 1;;
	esac
}
resolver_candidates() { printf 'fallback\n' >> "$fallback_calls"; printf '%s\n' 1.1.1.1; }
resolve_via_resolveip() { printf 'resolveip\n' >> "$fallback_calls"; return 1; }

actual="$(resolve_domain_ipv4 cdn.example '9.9.9.9 208.67.222.222')"
expected='198.51.100.20
203.0.113.30'
[ "$actual" = "$expected" ] || {
	printf 'FAIL: resolver union mismatch\nexpected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
	exit 1
}
[ ! -s "$fallback_calls" ] || {
	printf 'FAIL: fallback resolvers ran despite primary answers\n' >&2
	exit 1
}

resolve_via_dig() { return 1; }
resolve_via_nslookup() { return 1; }
actual="$(resolve_domain_ipv4 fallback.example '9.9.9.9 208.67.222.222')"
[ "$actual" = '192.0.2.10' ] || {
	printf 'FAIL: DoH fallback did not supply an answer\n' >&2
	exit 1
}
[ "$(cat "$fallback_calls")" = 'doh' ] || {
	printf 'FAIL: later fallbacks ran after DoH succeeded\n' >&2
	exit 1
}

printf 'ok\n'
