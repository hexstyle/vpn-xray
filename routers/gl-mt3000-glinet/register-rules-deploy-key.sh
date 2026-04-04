#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/common/lib/env.sh"

ENV_FILE="${ENV_FILE:-$(default_install_env_file "$ROOT_DIR")}"
if [[ -f "$ENV_FILE" ]]; then
  load_env_file "$ENV_FILE" "$(default_install_env_example "$ROOT_DIR")"
fi

ROUTER_SSH="${ROUTER_SSH:-root@${ROUTER_HOST:-}}"
ROUTER_HOST="${ROUTER_HOST:-$(host_from_ssh_target "$ROUTER_SSH")}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
ensure_installer_ssh_state "$ROOT_DIR"
INSTALLER_KNOWN_HOSTS="$(installer_known_hosts_file "$ROOT_DIR")"
ROUTER_SSH_OPTS=(
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS"
)

router_ssh() {
  local err rc

  err="$(mktemp)"
  if ssh "${ROUTER_SSH_OPTS[@]}" "$ROUTER_SSH" "$@" 2>"$err"; then
    rm -f "$err"
    return 0
  fi

  rc=$?
  cat "$err" >&2

  if grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$err"; then
    echo "Installer SSH cache has a stale host key for $ROUTER_HOST. Refreshing and retrying once..." >&2
    remove_hostkey_entry "$INSTALLER_KNOWN_HOSTS" "$ROUTER_HOST"
    if ssh "${ROUTER_SSH_OPTS[@]}" "$ROUTER_SSH" "$@" 2>"$err"; then
      rm -f "$err"
      return 0
    fi
    rc=$?
    cat "$err" >&2
  fi

  echo "Router SSH failed for $ROUTER_SSH while reading the Git deploy key." >&2
  echo "Installer SSH cache: $INSTALLER_KNOWN_HOSTS" >&2
  rm -f "$err"
  return "$rc"
}

REPO="${REPO:-}"
if [[ -z "$REPO" ]]; then
  REPO="$(derive_github_repo_slug "${RULES_REPO_PUSH_URL:-}" || true)"
fi

require_vars ROUTER_HOST REPO
reject_placeholder_vars ROUTER_SSH ROUTER_HOST REPO
TITLE="${TITLE:-routerRules-${ROUTER_HOST}}"

command -v gh >/dev/null 2>&1 || {
  echo "GitHub CLI 'gh' is required for this helper." >&2
  exit 1
}

pubkey="$(router_ssh '/usr/bin/router-rules ensure-git-key >/dev/null 2>&1 || true; cat /etc/router-rules/ssh/routerRules_ed25519.pub')"

if [[ -z "$pubkey" ]]; then
  echo "Failed to read router deploy key from $ROUTER_HOST" >&2
  exit 1
fi

existing_id="$(gh api "repos/$REPO/keys" --paginate --jq ".[] | select(.key == \"$pubkey\") | .id" | head -n1 || true)"

if [[ -n "$existing_id" ]]; then
  echo "Deploy key already present: $existing_id"
  exit 0
fi

gh api "repos/$REPO/keys" \
  --method POST \
  -f title="$TITLE" \
  -f key="$pubkey" \
  -F read_only=false >/dev/null

echo "Added deploy key for $ROUTER_HOST to $REPO"
