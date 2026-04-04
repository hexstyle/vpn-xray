#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/common/lib/env.sh"

ENV_FILE="${ENV_FILE:-$(default_install_env_file "$ROOT_DIR")}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"
export ENV_FILE

"$ROOT_DIR/common/init-env.sh" "$ENV_FILE"
"$ROOT_DIR/common/validate-env.sh" "$ENV_FILE"

load_env_file "$ENV_FILE" "$(default_install_env_example "$ROOT_DIR")"
ROUTER_PROFILE="${ROUTER_PROFILE:-gl-mt3000-glinet}"
VPS_PROFILE="${VPS_PROFILE:-debian-13}"
require_supported_profile router "$ROOT_DIR" "$ROUTER_PROFILE"
require_supported_profile vps "$ROOT_DIR" "$VPS_PROFILE"

echo "Running router preflight..."
"$ROOT_DIR/routers/$ROUTER_PROFILE/install-router.sh" --preflight
echo "Running VPS preflight..."
"$ROOT_DIR/vps/$VPS_PROFILE/install-vps.sh" --preflight

if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
  echo
  echo "Preflight passed. No changes were made."
  exit 0
fi

"$ROOT_DIR/vps/$VPS_PROFILE/install-vps.sh"
"$ROOT_DIR/routers/$ROUTER_PROFILE/install-router.sh"

if [[ "$SKIP_VERIFY" != "1" ]]; then
  "$ROOT_DIR/routers/$ROUTER_PROFILE/verify-router.sh"
fi

ROUTER_SSH="${ROUTER_SSH:-root@${ROUTER_HOST:-}}"
ROUTER_HOST="${ROUTER_HOST:-$(host_from_ssh_target "$ROUTER_SSH")}"

echo
echo "Stack install completed."
echo "Open the router UI at: https://$ROUTER_HOST/xray.html"
