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
generated_dir() { printf '%s\n' "$TMPDIR/generated"; }
ssh_key_path() { printf '%s\n' "$TMPDIR/ssh/routerRules_ed25519"; }
known_hosts_path() { printf '%s\n' "$TMPDIR/ssh/known_hosts"; }
repo_configured() { return 0; }
git_readonly_mode() { return 0; }
repo_bootstrap() {
	mkdir -p "$(dirname "$(repo_rules_path)")" "$(repo_rules_tree_path)/external"
	[ -f "$(repo_rules_path)" ] || : > "$(repo_rules_path)"
}

src="$TMPDIR/input.txt"
cat > "$src" <<'EOF'
# keep this explanation
example.com
203.0.113.0/24
EOF

save_rules_file_internal "$src" || {
	printf 'FAIL: pull-only Git mode must still allow saving the local shared rules file\n' >&2
	exit 1
}

cmp -s "$src" "$(repo_rules_path)" || {
	printf 'FAIL: saving the local shared rules file must preserve the exact operator text in pull-only Git mode\n' >&2
	exit 1
}

printf 'ok\n'
