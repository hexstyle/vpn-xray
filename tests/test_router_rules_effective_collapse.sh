#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"
PYTHON_GENERATOR="$ROOT/routers/common/files/router-rules-external.py"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

VX_LIB_COMMON="$ROOT/routers/common/files/lib-common.sh" VX_RULES_LIB_DIR="$ROOT/routers/common/files" ROUTER_RULES_LIB_ONLY=1 . "$ROUTER_RULES_FILE"

repo_path() { printf '%s\n' "$TMPDIR/repo"; }
generated_dir() { printf '%s\n' "$TMPDIR/generated"; }
rules_relpath() { printf '%s\n' 'lists/shared-targets.txt'; }
rules_tree_relpath() { printf '%s\n' 'lists'; }
repo_rules_path() { printf '%s/%s\n' "$(repo_path)" "$(rules_relpath)"; }
repo_rules_tree_path() { printf '%s/%s\n' "$(repo_path)" "$(rules_tree_relpath)"; }
external_source_catalog() { printf '%s\n' 'cloudflare_ipv4|Cloudflare IPv4|https://www.cloudflare.com/ips-v4'; }
external_source_path() { printf '%s/%s\n' "$(repo_path)" "lists/external/$1.txt"; }
external_source_script() { printf '%s\n' "$PYTHON_GENERATOR"; }
external_source_enabled_by_id() { printf '1\n'; }

mkdir -p "$(repo_rules_tree_path)/external" "$(generated_dir)"
cat > "$(repo_rules_path)" <<'EOF'
10.0.0.0/25
Example.com
EOF
cat > "$(external_source_path cloudflare_ipv4)" <<'EOF'
10.0.0.128/25
10.0.1.0/24
EOF

compose_effective_rules_internal >/dev/null

expected="$TMPDIR/expected.txt"
cat > "$expected" <<'EOF'
10.0.0.0/23
example.com
EOF

cmp -s "$(effective_rules_file)" "$expected" || {
	printf 'FAIL: effective rules file was not collapsed into the minimal IPv4 set\n' >&2
	printf -- '--- expected ---\n' >&2
	cat "$expected" >&2
	printf -- '--- actual ---\n' >&2
	cat "$(effective_rules_file)" >&2
	exit 1
}

printf 'ok\n'
