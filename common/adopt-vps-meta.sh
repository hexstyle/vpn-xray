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
  printf '%s\n' "$meta" | sed -n "s/^$1=//p" | sed -n '1p'
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

adopted=0
adopt() {
  local name="$1" value="$2" current
  [[ -n "$value" ]] || return 0
  current="$(sed -n "s/^${name}=//p" "$ENV_FILE" | sed -n '1p')"
  if [[ "$current" != "$value" ]]; then
    persist_env_value "$name" "$value"
    adopted=1
  fi
}

adopt XRAY_UUID "$meta_uuid"
adopt XRAY_PRIVATE_KEY "$meta_private_key"
adopt XRAY_PUBLIC_KEY "$meta_public_key"
adopt XRAY_SHORT_ID "$meta_short_id"
adopt XRAY_SERVER_NAME "$meta_server_name"
adopt XRAY_PORT "$meta_port"

if [[ "$adopted" == "1" ]]; then
  echo "adopt-vps-meta: adopted existing VPS keys into $ENV_FILE:"
  echo "  XRAY_UUID=$meta_uuid"
  echo "  XRAY_SERVER_NAME=$meta_server_name"
  echo "  XRAY_PORT=$meta_port"
  echo "  XRAY_SHORT_ID=$meta_short_id"
  echo "  XRAY_PUBLIC_KEY=$meta_public_key"
  echo "  XRAY_PRIVATE_KEY=<taken from VPS managed meta>"
else
  echo "adopt-vps-meta: install.env already matches the VPS managed meta."
fi
