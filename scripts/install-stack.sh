#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_VERIFY="${SKIP_VERIFY:-0}"

source "$ROOT_DIR/scripts/lib/required-env.sh"

"$ROOT_DIR/scripts/init-config.sh"
"$ROOT_DIR/scripts/validate-env.sh" vps
"$ROOT_DIR/scripts/validate-env.sh" router
"$ROOT_DIR/scripts/deploy-vps-config.sh"
"$ROOT_DIR/scripts/deploy-child-router.sh"

if [[ "$SKIP_VERIFY" != "1" ]]; then
  "$ROOT_DIR/scripts/verify-child-router.sh"
fi

load_env_file "$ROOT_DIR/config/router.env" "$ROOT_DIR/config/router.env.example"
ROUTER_SSH="${ROUTER_SSH:-root@${ROUTER_HOST:-}}"
ROUTER_HOST="${ROUTER_HOST:-$(host_from_ssh_target "$ROUTER_SSH")}"

echo
echo "Stack install completed."
echo "Open the router UI at: https://$ROUTER_HOST/xray.html"
