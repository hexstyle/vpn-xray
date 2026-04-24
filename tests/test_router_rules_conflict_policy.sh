#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

VX_LIB_COMMON="$ROOT/routers/common/files/lib-common.sh" ROUTER_RULES_LIB_ONLY=1 . "$ROUTER_RULES_FILE"

repo_path() { printf '%s\n' "$TMPDIR/repo"; }
rules_relpath() { printf '%s\n' 'lists/shared-targets.txt'; }
rules_tree_relpath() { printf '%s\n' 'lists'; }
external_source_catalog() { printf ''; }
device_id() { printf '%s\n' 'router-test'; }
repo_branch() { printf '%s\n' 'main'; }

remote_root="$TMPDIR/remote"
local_root="$TMPDIR/local"
repo_root="$(repo_path)"
merged_file="$repo_root/$(rules_relpath)"

mkdir -p "$remote_root/lists" "$local_root/lists" "$(dirname "$merged_file")"

cat > "$remote_root/$(rules_relpath)" <<'EOF'
# upstream explanation
remote.example
EOF

cat > "$local_root/$(rules_relpath)" <<'EOF'
local-only.example
# local note
EOF

merge_rules_tree_for_mode_internal pull "$remote_root" "$local_root" "$repo_root"

first_line="$(sed -n '1p' "$merged_file")"
second_line="$(sed -n '2p' "$merged_file")"
[ "$first_line" = '# upstream explanation' ] || {
	printf 'FAIL: conflict merge must keep the fetched Git rules file as the base text\n' >&2
	exit 1
}
[ "$second_line" = 'remote.example' ] || {
	printf 'FAIL: conflict merge must preserve the upstream rule order before appending local-only entries\n' >&2
	exit 1
}
grep -q '^# merged unique local rules from router-test$' "$merged_file" || {
	printf 'FAIL: conflict merge must mark appended router-local additions clearly\n' >&2
	exit 1
}
grep -q '^local-only.example$' "$merged_file" || {
	printf 'FAIL: conflict merge must preserve unique router-local rules\n' >&2
	exit 1
}
grep -q '^# local note$' "$merged_file" || {
	printf 'FAIL: conflict merge must preserve unique router-local comments\n' >&2
	exit 1
}

printf 'ok\n'
