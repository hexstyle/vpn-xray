#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/required-env.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/validate-env.sh router [ENV_FILE]
  scripts/validate-env.sh vps [ENV_FILE]
  scripts/validate-env.sh asus [ENV_FILE]
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage

target="$1"
env_file="${2:-}"

case "$target" in
  router)
    env_file="${env_file:-$ROOT_DIR/config/router.env}"
    load_env_file "$env_file" "$ROOT_DIR/config/router.env.example"
    require_vars \
      ROUTER_HOST ROUTER_LAN_IP HOME_SUBNET PROXY_PORT LOCAL_SOCKS_PORT REDSOCKS_PORT \
      XRAY_SERVER XRAY_PORT XRAY_UUID XRAY_SERVER_NAME XRAY_PUBLIC_KEY XRAY_SHORT_ID \
      RULES_REPO_FETCH_URL RULES_REPO_PUSH_URL RULES_REPO_BRANCH RULES_DEVICE_ID \
      RULES_ENABLE_PUSH RULES_CONSUMER RULES_SYNC_INTERVAL XRAY_RULES_MODE
    reject_placeholder_vars \
      ROUTER_HOST ROUTER_LAN_IP HOME_SUBNET XRAY_SERVER XRAY_UUID XRAY_SERVER_NAME \
      XRAY_PUBLIC_KEY XRAY_SHORT_ID RULES_REPO_FETCH_URL RULES_REPO_PUSH_URL RULES_DEVICE_ID
    ;;
  vps)
    env_file="${env_file:-$ROOT_DIR/config/vps.env}"
    load_env_file "$env_file" "$ROOT_DIR/config/vps.env.example"
    require_vars VPS_HOST XRAY_UUID XRAY_SERVER_NAME XRAY_SHORT_ID XRAY_PRIVATE_KEY
    reject_placeholder_vars VPS_HOST XRAY_UUID XRAY_SERVER_NAME XRAY_SHORT_ID XRAY_PRIVATE_KEY
    ;;
  asus)
    env_file="${env_file:-$ROOT_DIR/config/asus-router.env}"
    load_env_file "$env_file" "$ROOT_DIR/config/asus-router.env.example"
    require_vars \
      ROUTER_HOST RULES_REPO_FETCH_URL RULES_REPO_PUSH_URL RULES_REPO_BRANCH \
      RULES_DEVICE_ID RULES_ENABLE_PUSH RULES_CONSUMER RULES_SYNC_INTERVAL XRAY_RULES_MODE
    reject_placeholder_vars ROUTER_HOST RULES_REPO_FETCH_URL RULES_REPO_PUSH_URL RULES_DEVICE_ID
    ;;
  *)
    usage
    ;;
esac

echo "OK: $target config is present and placeholders were replaced ($env_file)"
