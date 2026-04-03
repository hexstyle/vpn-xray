#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/required-env.sh"

ENV_FILE="${ENV_FILE:-$(default_router_env_file "$ROOT_DIR")}"

if [[ -f "$ENV_FILE" ]]; then
  load_env_file "$ENV_FILE" "$ROOT_DIR/config/router.env.example"
fi

ROUTER_SSH="${ROUTER_SSH:-root@${ROUTER_HOST:-}}"
ROUTER_HOST="${ROUTER_HOST:-$(host_from_ssh_target "$ROUTER_SSH")}"

REPO="${REPO:-}"
if [[ -z "$REPO" ]]; then
  REPO="$(derive_github_repo_slug "${RULES_REPO_PUSH_URL:-}" || true)"
fi

require_vars ROUTER_HOST REPO
reject_placeholder_vars ROUTER_SSH ROUTER_HOST REPO
TITLE="${TITLE:-routerRules-${ROUTER_HOST}}"

pubkey="$(ssh "$ROUTER_SSH" '/usr/bin/router-rules ensure-git-key >/dev/null 2>&1 || true; cat /etc/router-rules/ssh/routerRules_ed25519.pub')"

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
