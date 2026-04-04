#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/common/lib/env.sh"

ENV_FILE="${ENV_FILE:-$(default_install_env_file "$ROOT_DIR")}"
load_env_file "$ENV_FILE" "$(default_install_env_example "$ROOT_DIR")"

VPS_PROFILE="${VPS_PROFILE:-debian-13}"
VPS_PROFILE_DIR="$(vps_profile_dir "$ROOT_DIR" "$VPS_PROFILE")"
require_supported_profile vps "$ROOT_DIR" "$VPS_PROFILE"
load_profile_defaults "$VPS_PROFILE_DIR/profile.env"

VPS_SSH="${VPS_SSH:-root@${VPS_HOST:-}}"
VPS_HOST="${VPS_HOST:-$(host_from_ssh_target "$VPS_SSH")}"

require_vars \
  VPS_SSH VPS_HOST XRAY_UUID XRAY_SERVER_NAME XRAY_SHORT_ID XRAY_PRIVATE_KEY XRAY_PUBLIC_KEY \
  VPS_INSTALL_SCRIPT VPS_SERVER_CONFIG_TEMPLATE VPS_REMOTE_META_PATH \
  VPS_XRAY_BINARY VPS_XRAY_CONFIG_DIR VPS_XRAY_CONFIG_PATH VPS_XRAY_LOG_DIR VPS_XRAY_SERVICE

reject_placeholder_vars VPS_SSH VPS_HOST XRAY_UUID XRAY_SERVER_NAME XRAY_SHORT_ID XRAY_PRIVATE_KEY

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

render_template() {
  local input="$1"
  local output="$2"
  python3 - <<'PY' "$input" "$output"
import os, pathlib, re, sys
template = pathlib.Path(sys.argv[1]).read_text()
def repl(match):
    key = match.group(1)
    return os.environ[key]
pathlib.Path(sys.argv[2]).write_text(re.sub(r"\$\{([A-Z0-9_]+)\}", repl, template))
PY
}

rendered_config="$tmpdir/xray-config.json"
rendered_meta="$tmpdir/codex-router-meta.env"
rendered_install="$tmpdir/install-vps.remote.sh"

render_template "$VPS_PROFILE_DIR/$VPS_SERVER_CONFIG_TEMPLATE" "$rendered_config"
cat > "$rendered_meta" <<EOF
PROFILE_ID=${VPS_PROFILE}
XRAY_HOST=${XRAY_SERVER:-$VPS_HOST}
XRAY_PORT=${XRAY_PORT:-443}
XRAY_UUID=${XRAY_UUID}
XRAY_SERVER_NAME=${XRAY_SERVER_NAME}
XRAY_SHORT_ID=${XRAY_SHORT_ID}
XRAY_PRIVATE_KEY=${XRAY_PRIVATE_KEY}
XRAY_PUBLIC_KEY=${XRAY_PUBLIC_KEY}
XRAY_FLOW=${XRAY_FLOW:-}
EOF
render_template "$VPS_PROFILE_DIR/$VPS_INSTALL_SCRIPT" "$rendered_install"

ssh "$VPS_SSH" 'cat > /tmp/codex-router-vps-config.json && chmod 600 /tmp/codex-router-vps-config.json' < "$rendered_config"
ssh "$VPS_SSH" 'cat > /tmp/codex-router-meta.env && chmod 600 /tmp/codex-router-meta.env' < "$rendered_meta"
ssh "$VPS_SSH" 'cat > /tmp/install-vps.remote.sh && chmod 755 /tmp/install-vps.remote.sh' < "$rendered_install"
ssh "$VPS_SSH" 'sh /tmp/install-vps.remote.sh'

echo "Deployed Xray server config to $VPS_HOST using VPS profile $VPS_PROFILE"
