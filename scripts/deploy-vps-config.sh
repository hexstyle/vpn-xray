#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/required-env.sh"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/vps.env}"
TEMPLATE_FILE="${TEMPLATE_FILE:-$ROOT_DIR/server-files/xray-vps-config.template.json}"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Missing template file: $TEMPLATE_FILE" >&2
  exit 1
fi

load_env_file "$ENV_FILE" "$ROOT_DIR/config/vps.env.example"

required_vars=(
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

ssh "root@$VPS_HOST" 'cat > /tmp/xray-config.json && /usr/local/bin/xray run -test -config /tmp/xray-config.json' < "$rendered"
ssh "root@$VPS_HOST" '
  set -e
  install -d -m 750 /usr/local/etc/xray /var/log/xray
  if [ -f /usr/local/etc/xray/config.json ]; then
    cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.bak.$(date +%Y%m%d%H%M%S)
  fi
  cat /tmp/xray-config.json > /usr/local/etc/xray/config.json
  chmod 600 /usr/local/etc/xray/config.json
  systemctl restart xray
  systemctl is-active xray
'

echo "Deployed Xray server config to $VPS_HOST"
