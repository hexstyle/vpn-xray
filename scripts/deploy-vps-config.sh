#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/required-env.sh"
ENV_FILE="${ENV_FILE:-$(default_vps_env_file "$ROOT_DIR")}"
ENV_VPS_SSH="${VPS_SSH:-}"
ENV_VPS_HOST="${VPS_HOST:-}"

load_env_file "$ENV_FILE" "$ROOT_DIR/config/vps.env.example"
VPS_PROFILE="${VPS_PROFILE:-debian-13}"
VPS_PROFILE_DIR="$(vps_profile_dir "$ROOT_DIR" "$VPS_PROFILE")"
[[ -f "$VPS_PROFILE_DIR/profile.env" ]] || { echo "Unsupported VPS profile: $VPS_PROFILE" >&2; exit 1; }
load_profile_defaults "$VPS_PROFILE_DIR/profile.env"
TEMPLATE_FILE="${TEMPLATE_FILE:-$VPS_PROFILE_DIR/files/xray-vps-config.template.json}"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Missing template file: $TEMPLATE_FILE" >&2
  exit 1
fi

if [[ -n "$ENV_VPS_SSH" ]]; then
  VPS_SSH="$ENV_VPS_SSH"
fi

if [[ -n "$ENV_VPS_HOST" ]]; then
  VPS_HOST="$ENV_VPS_HOST"
fi

VPS_SSH="${VPS_SSH:-root@${VPS_HOST:-}}"
VPS_HOST="${VPS_HOST:-$(host_from_ssh_target "$VPS_SSH")}"

required_vars=(
  VPS_SSH
  VPS_HOST
  XRAY_UUID
  XRAY_SERVER_NAME
  XRAY_SHORT_ID
  XRAY_PRIVATE_KEY
)

for name in "${required_vars[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required variable: $name" >&2
    exit 1
  fi
done

reject_placeholder_vars \
  VPS_SSH \
  VPS_HOST \
  XRAY_UUID \
  XRAY_SERVER_NAME \
  XRAY_SHORT_ID \
  XRAY_PRIVATE_KEY

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

rendered="$tmpdir/xray-config.json"
python3 - <<'PY' "$TEMPLATE_FILE" "$rendered"
import os, pathlib, re, sys
template = pathlib.Path(sys.argv[1]).read_text()
def repl(match):
    key = match.group(1)
    return os.environ[key]
out = re.sub(r"\$\{([A-Z0-9_]+)\}", repl, template)
pathlib.Path(sys.argv[2]).write_text(out)
PY

ssh "$VPS_SSH" "cat > /tmp/xray-config.json && $VPS_XRAY_BINARY run -test -config /tmp/xray-config.json" < "$rendered"
ssh "$VPS_SSH" '
  set -e
  install -d -m 750 '"$VPS_XRAY_CONFIG_DIR"' '"$VPS_XRAY_LOG_DIR"'
  if [ -f '"$VPS_XRAY_CONFIG_PATH"' ]; then
    cp '"$VPS_XRAY_CONFIG_PATH"' '"$VPS_XRAY_CONFIG_PATH"'.bak.$(date +%Y%m%d%H%M%S)
  fi
  cat /tmp/xray-config.json > '"$VPS_XRAY_CONFIG_PATH"'
  chmod 600 '"$VPS_XRAY_CONFIG_PATH"'
  systemctl restart '"$VPS_XRAY_SERVICE"'
  systemctl is-active '"$VPS_XRAY_SERVICE"'
'

echo "Deployed Xray server config to $VPS_HOST"
