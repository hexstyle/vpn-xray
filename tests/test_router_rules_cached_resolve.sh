#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

VX_LIB_COMMON="$ROOT/routers/common/files/lib-common.sh" VX_RULES_LIB_DIR="$ROOT/routers/common/files" ROUTER_RULES_LIB_ONLY=1 . "$ROUTER_RULES_FILE"

repo_path() { printf '%s\n' "$TMPDIR/repo"; }
rules_relpath() { printf '%s\n' 'lists/shared-targets.txt'; }
generated_dir() { printf '%s\n' "$TMPDIR/generated"; }
dns_resolver() { printf '%s\n' '9.9.9.9'; }
external_source_catalog() { printf ''; }
status_set() { :; }

mkdir -p "$(dirname "$(repo_rules_path)")" "$(generated_dir)"
cat > "$(repo_rules_path)" <<'EOF'
cached.example
new.example
203.0.113.7
EOF

cat > "$(mapping_file)" <<'EOF'
198.51.100.10	domain	cached.example
EOF

resolve_calls="$TMPDIR/resolve_calls"
: > "$resolve_calls"
resolve_domain_ipv4() {
	printf '%s\n' "$1" >> "$resolve_calls"
	case "$1" in
		new.example)
			printf '%s\n' '198.51.100.20'
			;;
		*)
			return 1
			;;
	esac
}

ROUTER_RULES_REUSE_RESOLVED_CACHE=1 resolve_rules_internal

grep -Fxq '198.51.100.10' "$(resolved_file)" || {
	printf 'FAIL: cached domain resolution was not reused\n' >&2
	exit 1
}
grep -Fxq '198.51.100.20' "$(resolved_file)" || {
	printf 'FAIL: new domain was not resolved\n' >&2
	exit 1
}
grep -Fxq '203.0.113.7' "$(resolved_file)" || {
	printf 'FAIL: literal IPv4 target missing from resolved file\n' >&2
	exit 1
}
if grep -Fxq 'cached.example' "$resolve_calls"; then
	printf 'FAIL: cached domain should not be resolved in fast path\n' >&2
	exit 1
fi
grep -Fxq 'new.example' "$resolve_calls" || {
	printf 'FAIL: new domain should be resolved in fast path\n' >&2
	exit 1
}

printf 'ok\n'
