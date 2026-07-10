#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

VX_LIB_COMMON="$ROOT/routers/common/files/lib-common.sh" VX_RULES_LIB_DIR="$ROOT/routers/common/files" ROUTER_RULES_LIB_ONLY=1 . "$ROUTER_RULES_FILE"

repo_path() { printf '%s\n' "$TMPDIR/repo"; }
rules_relpath() { printf '%s\n' 'lists/shared-targets.txt'; }
rules_tree_relpath() { printf '%s\n' 'lists'; }
repo_rules_path() { printf '%s/%s\n' "$(repo_path)" "$(rules_relpath)"; }
external_source_catalog() { printf '%s\n' 'cloudflare_ipv4|Cloudflare IPv4|https://www.cloudflare.com/ips-v4'; }
external_source_path() { printf '%s/%s\n' "$(repo_path)" "lists/external/$1.txt"; }
external_source_repo_layout_version() { printf '0\n'; }
status_trace_add() { :; }
status_set() { :; }
uci() { :; }

mkdir -p "$(repo_path)/lists/external"

base_file="$TMPDIR/base.txt"
candidate_file="$TMPDIR/candidate.txt"
out_file="$TMPDIR/additions.txt"

: > "$base_file"
cat > "$candidate_file" <<'EOF'
103.21.244.0/22
103.22.200.0/22
EOF

compute_unique_rule_additions_internal "$base_file" "$candidate_file" "$out_file"
cmp -s "$candidate_file" "$out_file" || {
	printf 'FAIL: empty base file must keep all candidate additions\n' >&2
	exit 1
}

remote_file="$TMPDIR/remote.txt"
local_file="$TMPDIR/local.txt"
merged_file="$TMPDIR/merged.txt"

: > "$remote_file"
cat > "$local_file" <<'EOF'
example.com
example.net
EOF

merge_remote_preferred "$remote_file" "$local_file" "$merged_file"
grep -q '^# merged unique local rules from ' "$merged_file" || {
	printf 'FAIL: merge_remote_preferred must append local rules when remote file is empty\n' >&2
	exit 1
}
grep -q '^example.com$' "$merged_file" || {
	printf 'FAIL: merge_remote_preferred must preserve local additions when remote file is empty\n' >&2
	exit 1
}

managed_file="$(external_source_path cloudflare_ipv4)"
main_file="$(repo_rules_path)"

: > "$managed_file"
cat > "$main_file" <<'EOF'
manual.example
203.0.113.0/24
EOF

removed_count="$(maybe_migrate_external_repo_layout_internal)"
[ "$removed_count" = '0' ] || {
	printf 'FAIL: empty managed source files must not remove manual rules (got %s)\n' "$removed_count" >&2
	exit 1
}
grep -q '^manual.example$' "$main_file" || {
	printf 'FAIL: manual rules disappeared during empty managed source migration\n' >&2
	exit 1
}
grep -q '^203.0.113.0/24$' "$main_file" || {
	printf 'FAIL: manual CIDR disappeared during empty managed source migration\n' >&2
	exit 1
}

external_source_repo_layout_version() { printf '2\n'; }
cat > "$managed_file" <<'EOF'
203.0.113.0/24
EOF
cat > "$main_file" <<'EOF'
manual.example
203.0.113.0/24
EOF

removed_count="$(maybe_migrate_external_repo_layout_internal)"
[ "$removed_count" = '1' ] || {
	printf 'FAIL: managed targets must still be removed from the editable file after layout version upgrade (got %s)\n' "$removed_count" >&2
	exit 1
}
grep -q '^manual.example$' "$main_file" || {
	printf 'FAIL: manual editable rules must survive managed source cleanup after layout upgrade\n' >&2
	exit 1
}
if grep -q '^203.0.113.0/24$' "$main_file"; then
	printf 'FAIL: managed target stayed in the editable rules file after layout upgrade cleanup\n' >&2
	exit 1
fi

cat > "$managed_file" <<'EOF'
manual.example
203.0.113.0/24
EOF
cat > "$main_file" <<'EOF'
manual.example
203.0.113.0/24
EOF

if maybe_migrate_external_repo_layout_internal >/dev/null 2>&1; then
	printf 'FAIL: managed source cleanup must not silently wipe the editable rules file\n' >&2
	exit 1
fi
grep -q '^manual.example$' "$main_file" || {
	printf 'FAIL: blocked managed cleanup must preserve manual.example\n' >&2
	exit 1
}
grep -q '^203.0.113.0/24$' "$main_file" || {
	printf 'FAIL: blocked managed cleanup must preserve the previous editable file\n' >&2
	exit 1
}

printf 'ok\n'
