#!/usr/bin/env bash
set -euo pipefail

# The VPS managed meta (codex-router-meta.env) is the authoritative source
# for the Xray endpoint identity. When the VPS already carries provisioned
# keys, install.env must adopt them instead of pushing locally generated
# ones over a live endpoint. Local values are used only when the VPS has
# no managed meta yet (fresh VPS) or is unreachable at this stage — the
# later preflight/install steps surface real SSH problems on their own.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/common/lib/env.sh"

ENV_FILE="${1:-${ENV_FILE:-$(default_install_env_file "$ROOT_DIR")}}"
export ENV_FILE

load_env_file "$ENV_FILE" "$(default_install_env_example "$ROOT_DIR")"

VPS_PROFILE="${VPS_PROFILE:-debian-13}"
load_profile_defaults "$(vps_profile_dir "$ROOT_DIR" "$VPS_PROFILE")/profile.env"

VPS_SSH="${VPS_SSH:-root@${VPS_HOST:-}}"
if is_placeholder_value "${VPS_SSH#root@}"; then
  echo "adopt-vps-meta: VPS_SSH is not set yet; keeping local Xray values."
  exit 0
fi

ensure_installer_ssh_state "$ROOT_DIR"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
VPS_SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$(installer_known_hosts_file "$ROOT_DIR")"
)
VPS_SSH_PORT="${VPS_SSH_PORT:-22}"
VPS_SSH_OPTS+=( -p "$VPS_SSH_PORT" )
# Share the multiplexed master connection so the meta probe reuses (or opens)
# the same VPS ssh session as the rest of the install — avoids a rate-limit trip.
VPS_SSH_OPTS+=( $(ssh_mux_opts) )

meta=''
if ! meta="$(ssh "${VPS_SSH_OPTS[@]}" "$VPS_SSH" \
  "cat '${VPS_REMOTE_META_PATH:?}' 2>/dev/null || true" 2>/dev/null)"; then
  echo "adopt-vps-meta: VPS is not reachable with key auth; keeping local Xray values."
  echo "  (Real SSH problems will be reported by the VPS preflight step.)"
  exit 0
fi

meta_value() {
  META_DATA="$meta" python3 - "$1" <<'PYMETA'
import os, shlex, sys
raw = next((line.split('=', 1)[1] for line in os.environ['META_DATA'].splitlines()
            if line.startswith(sys.argv[1] + '=')), '')
try:
    values = shlex.split(raw, comments=False)
except ValueError:
    raise SystemExit('adopt-vps-meta: invalid quoted metadata field ' + sys.argv[1])
if len(values) > 1:
    raise SystemExit('adopt-vps-meta: invalid metadata field ' + sys.argv[1])
print(values[0] if values else '')
PYMETA
}

meta_uuid="$(meta_value XRAY_UUID)"
meta_private_key="$(meta_value XRAY_PRIVATE_KEY)"
meta_public_key="$(meta_value XRAY_PUBLIC_KEY)"
meta_short_id="$(meta_value XRAY_SHORT_ID)"
meta_server_name="$(meta_value XRAY_SERVER_NAME)"
meta_port="$(meta_value XRAY_PORT)"

if [[ -z "$meta_uuid" || -z "$meta_private_key" || -z "$meta_short_id" ]]; then
  echo "adopt-vps-meta: VPS has no managed meta yet; local Xray values will be provisioned."
  exit 0
fi

meta_dial_mode="$(meta_value XRAY_DIAL_MODE)"
meta_dial_mode="${meta_dial_mode:-direct}"
case "$meta_dial_mode" in direct|ssh_tunnel) ;; *) echo 'adopt-vps-meta: invalid remote XRAY_DIAL_MODE' >&2; exit 1 ;; esac
meta_ws_path="$(meta_value XRAY_WS_PATH)"
if [[ -z "$meta_ws_path" ]]; then
  live_config="$(ssh "${VPS_SSH_OPTS[@]}" "$VPS_SSH" "cat '${VPS_XRAY_CONFIG_PATH:?}' 2>/dev/null || true")"
  meta_ws_path="$(LIVE_CONFIG="$live_config" python3 - <<'PYPATH'
import json, os
raw = os.environ['LIVE_CONFIG']
try:
    cfg = json.loads(raw) if raw.strip() else {}
    print((((cfg.get('inbounds') or [{}])[0].get('streamSettings') or {}).get('wsSettings') or {}).get('path') or '/cdn')
except (ValueError, AttributeError, TypeError):
    raise SystemExit('adopt-vps-meta: cannot read live WS path')
PYPATH
)"
fi
case "$meta_ws_path" in /*) ;; *) echo 'adopt-vps-meta: invalid remote XRAY_WS_PATH' >&2; exit 1 ;; esac
[[ "$meta_ws_path" != *$'\n'* && "$meta_ws_path" != *$'\r'* ]] || { echo 'adopt-vps-meta: multiline WS path rejected' >&2; exit 1; }

adopted=0
adopt() {
  local name="$1" value="$2" current
  [[ -n "$value" ]] || return 0
  # Persist shell syntax only after quoting the data; never source remote meta.
  value="$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$value")"
  current="$(sed -n "s/^${name}=//p" "$ENV_FILE" | sed -n '1p')"
  if [[ "$current" != "$value" ]]; then
    python3 - "$ENV_FILE" "$name" "$value" <<'PYSAVE'
import pathlib, sys
path, key, value = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = path.read_text().splitlines()
updated = [key + '=' + value if line.startswith(key + '=') else line for line in lines]
if not any(line.startswith(key + '=') for line in lines): updated.append(key + '=' + value)
path.write_text('\n'.join(updated) + '\n')
PYSAVE
    adopted=1
  fi
}

adopt XRAY_DIAL_MODE "$meta_dial_mode"
adopt XRAY_WS_PATH "$meta_ws_path"
adopt XRAY_UUID "$meta_uuid"
adopt XRAY_PRIVATE_KEY "$meta_private_key"
adopt XRAY_PUBLIC_KEY "$meta_public_key"
adopt XRAY_SHORT_ID "$meta_short_id"
adopt XRAY_SERVER_NAME "$meta_server_name"
adopt XRAY_PORT "$meta_port"

if [[ "$adopted" == "1" ]]; then
  echo "adopt-vps-meta: adopted existing VPS keys into $ENV_FILE:"
  echo "  Endpoint identity, dial mode and WS path preserved from VPS."
else
  echo "adopt-vps-meta: install.env already matches the VPS managed meta."
fi
