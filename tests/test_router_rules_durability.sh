#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

VX_LIB_COMMON="$ROOT/routers/common/files/lib-common.sh" ROUTER_RULES_LIB_ONLY=1 . "$ROUTER_RULES_FILE"

repo_path() { printf '%s\n' "$TMPDIR/repo"; }
rules_relpath() { printf '%s\n' 'lists/shared-targets.txt'; }
rules_tree_relpath() { printf '%s\n' 'lists'; }
repo_rules_path() { printf '%s/%s\n' "$(repo_path)" "$(rules_relpath)"; }
external_source_catalog() { printf ''; }
rules_backup_dir() { printf '%s\n' "$TMPDIR/backups"; }
rules_backup_keep() { printf '%s\n' '5'; }
xray_mode() { printf '%s\n' 'selective'; }
prepare_rules_file_for_local_edit_internal() { :; }

STATUS_CAPTURE="$TMPDIR/status"
status_set() {
	grep -v "^$1=" "$STATUS_CAPTURE" > "${STATUS_CAPTURE}.tmp" 2>/dev/null || true
	printf '%s=%s\n' "$1" "$2" >> "${STATUS_CAPTURE}.tmp"
	mv "${STATUS_CAPTURE}.tmp" "$STATUS_CAPTURE"
}
status_get() {
	sed -n "s/^$1=//p" "$STATUS_CAPTURE" 2>/dev/null | sed -n '1p'
}
status_trace_add() { status_set "$1" "$2"; }

mkdir -p "$(dirname "$(repo_rules_path)")"
git init -b main "$(repo_path)" >/dev/null 2>&1
git -C "$(repo_path)" config user.name test
git -C "$(repo_path)" config user.email test@example.invalid
cat > "$(repo_rules_path)" <<'EOF'
chatgpt.com
openai.com
EOF
git -C "$(repo_path)" add "$(rules_relpath)"
git -C "$(repo_path)" commit -m initial >/dev/null 2>&1
git -C "$(repo_path)" update-ref refs/remotes/origin/main HEAD

: > "$(repo_rules_path)"
recover_empty_manual_rules_internal test-recovery
grep -Fxq 'chatgpt.com' "$(repo_rules_path)" \
	|| fail "empty manual rules file must recover from origin/main"

cat > "$(repo_rules_path)" <<'EOF'
manual.example
EOF
empty_file="$TMPDIR/empty"
: > "$empty_file"
if save_rules_file_internal "$empty_file" >/dev/null 2>&1; then
	fail "empty save must not overwrite a non-empty manual rules file"
fi
grep -Fxq 'manual.example' "$(repo_rules_path)" \
	|| fail "blocked empty save must preserve the previous manual rules"

fakebin="$TMPDIR/bin"
mkdir -p "$fakebin"
cat > "$fakebin/git" <<EOF
#!/bin/sh
printf '%s\n' "\${GIT_SSH_COMMAND:-}" > "$TMPDIR/git-env"
if [ "\${1:-}" = 'ls-remote' ]; then
	printf '%s\t%s\n' '0123456789abcdef0123456789abcdef01234567' 'refs/heads/main'
	exit 0
fi
exec $(command -v git) "\$@"
EOF
chmod 700 "$fakebin/git"

PATH="$fakebin:$PATH"
ssh_key_path() { printf '%s\n' "$TMPDIR/routerRules_ed25519"; }
repo_fetch_url() { printf '%s\n' 'git@github.com:hexstyle/routerRules.git'; }
git_auth_mode_raw() { printf '%s\n' 'ssh'; }
run_with_timeout() {
	shift
	"$@"
}
touch "$(ssh_key_path)"

quick_remote_probe_internal
grep -Fq "$(ssh_key_path)" "$TMPDIR/git-env" \
	|| fail "quick remote probe must use the configured SSH identity"
grep -q '^last_remote_probe_status=ok$' "$STATUS_CAPTURE" \
	|| fail "quick remote probe must report ok when ls-remote returns a head"

printf 'ok\n'
