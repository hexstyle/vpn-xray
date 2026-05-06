#!/usr/bin/env bash

set -euo pipefail

# Local-checkout-only bootstrap. The whole repo is on the workstation, so
# install-router.sh tars it and SCPs it onto the router — there is no need
# to ever pull anything from GitHub from the workstation. The router itself
# can still pull the rules repo at runtime, that is a separate concern.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -x "$ROOT_DIR/install.sh" || ! -f "$ROOT_DIR/routers/gl-mt3000-glinet/install-router.sh" ]]; then
  printf 'ERROR: bootstrap-router-ssh.sh must be run from inside the vpn-xray checkout.\n' >&2
  printf '       Expected install.sh next to this script at: %s\n' "$ROOT_DIR" >&2
  exit 1
fi

ROUTER_SSH_TARGET="${1:-${ROUTER_SSH:-root@192.168.8.1}}"

printf 'Local checkout detected at %s — using autonomous install path.\n' "$ROOT_DIR"
printf 'Target router: %s\n' "$ROUTER_SSH_TARGET"

export ROUTER_SSH="$ROUTER_SSH_TARGET"

# Forward rules-related env transparently so callers retain the same
# semantics. install.env stays the source of truth when nothing is set on
# the CLI.
export \
  RULES_GIT_SYNC_ENABLED="${RULES_GIT_SYNC_ENABLED:-}" \
  RULES_REPO_FETCH_URL="${RULES_REPO_FETCH_URL:-}" \
  RULES_REPO_PUSH_URL="${RULES_REPO_PUSH_URL:-}" \
  RULES_REPO_BRANCH="${RULES_REPO_BRANCH:-}" \
  RULES_GIT_AUTH_MODE="${RULES_GIT_AUTH_MODE:-}" \
  RULES_GIT_HTTP_USERNAME="${RULES_GIT_HTTP_USERNAME:-}" \
  RULES_GIT_HTTP_PASSWORD="${RULES_GIT_HTTP_PASSWORD:-}" \
  RULES_GIT_SSH_PRIVATE_KEY="${RULES_GIT_SSH_PRIVATE_KEY:-}" \
  RULES_GIT_SSH_PRIVATE_KEY_FILE="${RULES_GIT_SSH_PRIVATE_KEY_FILE:-}" \
  RULES_DEVICE_ID="${RULES_DEVICE_ID:-}" \
  RULES_ENABLE_PUSH="${RULES_ENABLE_PUSH:-}" \
  RULES_SYNC_INTERVAL="${RULES_SYNC_INTERVAL:-}" \
  XRAY_RULES_MODE="${XRAY_RULES_MODE:-}"

exec "$ROOT_DIR/routers/gl-mt3000-glinet/install-router.sh"
