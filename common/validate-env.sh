#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/common/lib/env.sh"

ENV_FILE="${1:-${ENV_FILE:-$(default_install_env_file "$ROOT_DIR")}}"
load_env_file "$ENV_FILE" "$(default_install_env_example "$ROOT_DIR")"

ROUTER_PROFILE="${ROUTER_PROFILE:-gl-mt3000-glinet}"
VPS_PROFILE="${VPS_PROFILE:-debian-13}"
require_supported_profile router "$ROOT_DIR" "$ROUTER_PROFILE"
require_supported_profile vps "$ROOT_DIR" "$VPS_PROFILE"
load_profile_defaults "$(router_profile_dir "$ROOT_DIR" "$ROUTER_PROFILE")/profile.env"
load_profile_defaults "$(vps_profile_dir "$ROOT_DIR" "$VPS_PROFILE")/profile.env"

ROUTER_SSH="${ROUTER_SSH:-root@${ROUTER_HOST:-}}"
ROUTER_HOST="${ROUTER_HOST:-$(host_from_ssh_target "$ROUTER_SSH")}"
ROUTER_LAN_IP="${ROUTER_LAN_IP:-$ROUTER_HOST}"
VPS_SSH="${VPS_SSH:-root@${VPS_HOST:-}}"
VPS_HOST="${VPS_HOST:-$(host_from_ssh_target "$VPS_SSH")}"
XRAY_SERVER="${XRAY_SERVER:-$VPS_HOST}"

require_vars \
  ROUTER_PROFILE ROUTER_SSH ROUTER_HOST ROUTER_LAN_IP \
  VPS_PROFILE VPS_SSH VPS_HOST \
  XRAY_SERVER XRAY_UUID XRAY_SERVER_NAME XRAY_PUBLIC_KEY XRAY_PRIVATE_KEY XRAY_SHORT_ID

reject_placeholder_vars \
  ROUTER_PROFILE ROUTER_SSH ROUTER_HOST ROUTER_LAN_IP \
  VPS_PROFILE VPS_SSH VPS_HOST \
  XRAY_SERVER XRAY_UUID XRAY_SERVER_NAME XRAY_PUBLIC_KEY XRAY_PRIVATE_KEY XRAY_SHORT_ID

echo "OK: install config is present and placeholders were replaced ($ENV_FILE)"
