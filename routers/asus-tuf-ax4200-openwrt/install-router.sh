#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/common/lib/env.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/common/lib/install-progress.sh"

# Helpers + the deploy/verify flow live in a sibling lib (AGENTS.md 500-line rule).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-router-lib.sh"

# install_progress_init writes a workstation-side status file. The router-
# side file under /tmp/vpn-xray-install-status.json is updated separately
# by install-platform.sh once the bundle lands on the device.
install_progress_init "$ROOT_DIR/tmp/install-status.json"

# Mirror each step to the router so the UI banner can render live progress.
# Override the per-step hook from install-progress.sh.
ROUTER_INSTALL_STATUS_FILE='/tmp/vpn-xray-install-status.json'

ENV_FILE="${ENV_FILE:-$(default_install_env_file "$ROOT_DIR")}"
PREFLIGHT_ONLY=0
if [[ "${1:-}" == "--preflight" ]]; then
  PREFLIGHT_ONLY=1
fi

ENV_ROUTER_SSH="${ROUTER_SSH:-}"
ENV_ROUTER_HOST="${ROUTER_HOST:-}"
ENV_ROUTER_LAN_IP="${ROUTER_LAN_IP:-}"
ENV_VPS_SSH="${VPS_SSH:-}"
ENV_VPS_HOST="${VPS_HOST:-}"
NETWORK_RELOAD="${NETWORK_RELOAD:-1}"

load_env_file "$ENV_FILE" "$(default_install_env_example "$ROOT_DIR")"
ROUTER_PROFILE="${ROUTER_PROFILE:-asus-tuf-ax4200-openwrt}"
require_supported_profile router "$ROOT_DIR" "$ROUTER_PROFILE"
ROUTER_PROFILE_DIR="$(router_profile_dir "$ROOT_DIR" "$ROUTER_PROFILE")"
ROUTER_COMMON_DIR="$(router_common_dir "$ROOT_DIR")"
load_profile_defaults "$ROUTER_PROFILE_DIR/profile.env"
VPS_PROFILE="${VPS_PROFILE:-debian-13}"
require_supported_profile vps "$ROOT_DIR" "$VPS_PROFILE"
VPS_PROFILE_DIR="$(vps_profile_dir "$ROOT_DIR" "$VPS_PROFILE")"
load_profile_defaults "$VPS_PROFILE_DIR/profile.env"

if [[ -n "$ENV_ROUTER_SSH" ]]; then
  ROUTER_SSH="$ENV_ROUTER_SSH"
fi
if [[ -n "$ENV_ROUTER_HOST" ]]; then
  ROUTER_HOST="$ENV_ROUTER_HOST"
fi

# Prompt the operator for the values that cannot be derived from anywhere
# else when running interactively. On a non-TTY (CI, scripted runs) these
# fall through to the existing require_vars hard-fail check below.
ensure_input_var ROUTER_SSH "Router SSH target, e.g. root@192.168.8.1"
ensure_input_var VPS_SSH    "VPS SSH target,    e.g. root@203.0.113.10"
if [[ -n "$ENV_ROUTER_LAN_IP" ]]; then
  ROUTER_LAN_IP="$ENV_ROUTER_LAN_IP"
fi
if [[ -n "$ENV_VPS_SSH" ]]; then
  VPS_SSH="$ENV_VPS_SSH"
fi
if [[ -n "$ENV_VPS_HOST" ]]; then
  VPS_HOST="$ENV_VPS_HOST"
fi

require_local_commands bash ssh ssh-keygen tar python3

ROUTER_SSH="${ROUTER_SSH:-root@${ROUTER_HOST:-}}"
ROUTER_HOST="${ROUTER_HOST:-$(host_from_ssh_target "$ROUTER_SSH")}"
ROUTER_LAN_IP="${ROUTER_LAN_IP:-$ROUTER_HOST}"
VPS_HOST="${VPS_HOST:-${XRAY_SERVER:-}}"
VPS_SSH="${VPS_SSH:-root@${VPS_HOST:-}}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
ROUTER_RELOAD_WAIT_SECONDS="${ROUTER_RELOAD_WAIT_SECONDS:-45}"
ROUTER_RELOAD_PROBE_TIMEOUT="${ROUTER_RELOAD_PROBE_TIMEOUT:-5}"
ensure_installer_ssh_state "$ROOT_DIR"
INSTALLER_KNOWN_HOSTS="$(installer_known_hosts_file "$ROOT_DIR")"
ROUTER_SSH_OPTS=(
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS"
)
VPS_SSH_OPTS=(
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS"
)
# Reuse the shared master SSH connection to the VPS (managed-key push + meta
# sync) so this stage does not add fresh connections that trip its rate limit.
VPS_SSH_OPTS+=( $(ssh_mux_opts) )

RULES_GIT_SYNC_ENABLED="${RULES_GIT_SYNC_ENABLED:-}"
RULES_REPO_FETCH_URL="${RULES_REPO_FETCH_URL:-}"
RULES_REPO_PUSH_URL="${RULES_REPO_PUSH_URL:-}"
RULES_REPO_BRANCH="${RULES_REPO_BRANCH:-main}"
RULES_GIT_AUTH_MODE="${RULES_GIT_AUTH_MODE:-auto}"
RULES_GIT_HTTP_USERNAME="${RULES_GIT_HTTP_USERNAME:-}"
RULES_GIT_HTTP_PASSWORD="${RULES_GIT_HTTP_PASSWORD:-}"
RULES_GIT_SSH_PRIVATE_KEY="${RULES_GIT_SSH_PRIVATE_KEY:-}"
RULES_GIT_SSH_PRIVATE_KEY_FILE="${RULES_GIT_SSH_PRIVATE_KEY_FILE:-}"
RULES_DEVICE_ID="${RULES_DEVICE_ID:-gl-router}"
RULES_EXTERNAL_SOURCE_ENABLED="${RULES_EXTERNAL_SOURCE_ENABLED:-0}"
RULES_EXTERNAL_SOURCE_URL="${RULES_EXTERNAL_SOURCE_URL:-}"
RULES_EXTERNAL_SOURCE_INTERVAL="${RULES_EXTERNAL_SOURCE_INTERVAL:-86400}"

# Auto-detect a local SSH key when nothing was specified explicitly. The user
# wants the workstation key to be copied onto the router rather than having
# the router invent its own key (which would then need a separate deploy-key
# registration on GitHub). Try the common defaults; the first readable one
# wins. Setting RULES_GIT_SSH_PRIVATE_KEY_FILE on the CLI still overrides.
if [[ -z "${RULES_GIT_SSH_PRIVATE_KEY:-}" && -z "${RULES_GIT_SSH_PRIVATE_KEY_FILE:-}" ]]; then
  for candidate in "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_ecdsa" "${HOME}/.ssh/id_rsa"; do
    if [[ -r "$candidate" ]]; then
      RULES_GIT_SSH_PRIVATE_KEY_FILE="$candidate"
      echo "Using local SSH key for router git access: $candidate"
      # When the local key is auto-detected, default to ssh auth so the
      # router actually uses the key for both pull and push.
      if [[ "${RULES_GIT_AUTH_MODE:-auto}" == "auto" ]]; then
        RULES_GIT_AUTH_MODE='ssh'
      fi
      break
    fi
  done
fi

# Build RULES_GIT_SSH_PRIVATE_KEY_B64 directly from the key file (or from
# RULES_GIT_SSH_PRIVATE_KEY) without going through `$(cat …)` — command
# substitution strips trailing newlines, which would corrupt the key on the
# router (`ssh-keygen -y` then refuses to load it). Reading the bytes via
# python preserves the file exactly.
RULES_GIT_SSH_PRIVATE_KEY_B64=''
if [[ -n "${RULES_GIT_SSH_PRIVATE_KEY_FILE:-}" ]]; then
  [[ -r "$RULES_GIT_SSH_PRIVATE_KEY_FILE" ]] || {
    echo "RULES_GIT_SSH_PRIVATE_KEY_FILE is not readable: $RULES_GIT_SSH_PRIVATE_KEY_FILE" >&2
    exit 1
  }
  RULES_GIT_SSH_PRIVATE_KEY_B64="$(python3 -c 'import base64, sys; sys.stdout.write(base64.b64encode(open(sys.argv[1], "rb").read()).decode("ascii"))' "$RULES_GIT_SSH_PRIVATE_KEY_FILE")"
elif [[ -n "${RULES_GIT_SSH_PRIVATE_KEY:-}" ]]; then
  RULES_GIT_SSH_PRIVATE_KEY_B64="$(printf '%s\n' "$RULES_GIT_SSH_PRIVATE_KEY" | python3 -c 'import base64, sys; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode("ascii"))')"
fi











if [[ "${PREFER_LIVE_VPS_META:-1}" == "1" ]]; then
  current_vps_meta="$(current_vps_xray_meta 2>/dev/null || true)"
  current_vps_runtime_facts="$(current_vps_xray_runtime_facts 2>/dev/null || true)"
  current_vps_config_port="$(printf '%s\n' "$current_vps_runtime_facts" | sed -n 's/^CONFIG_PORT=//p' | sed -n '1p')"
  if [[ -n "$current_vps_meta" ]]; then
    current_vps_xray_host="$(printf '%s\n' "$current_vps_meta" | sed -n 's/^XRAY_HOST=//p' | sed -n '1p')"
    current_vps_xray_port="$(printf '%s\n' "$current_vps_meta" | sed -n 's/^XRAY_PORT=//p' | sed -n '1p')"
    current_vps_xray_uuid="$(printf '%s\n' "$current_vps_meta" | sed -n 's/^XRAY_UUID=//p' | sed -n '1p')"
    current_vps_xray_server_name="$(printf '%s\n' "$current_vps_meta" | sed -n 's/^XRAY_SERVER_NAME=//p' | sed -n '1p')"
    current_vps_xray_short_id="$(printf '%s\n' "$current_vps_meta" | sed -n 's/^XRAY_SHORT_ID=//p' | sed -n '1p')"
    current_vps_xray_public_key="$(printf '%s\n' "$current_vps_meta" | sed -n 's/^XRAY_PUBLIC_KEY=//p' | sed -n '1p')"

    if [[ -n "$current_vps_xray_host" ]]; then
      XRAY_SERVER="$current_vps_xray_host"
    fi
    if [[ "$current_vps_xray_port" =~ ^[0-9]+$ ]]; then
      XRAY_PORT="$current_vps_xray_port"
    fi
    if [[ -n "$current_vps_xray_uuid" ]]; then
      XRAY_UUID="$current_vps_xray_uuid"
    fi
    if [[ -n "$current_vps_xray_server_name" ]]; then
      XRAY_SERVER_NAME="$current_vps_xray_server_name"
    fi
    if [[ -n "$current_vps_xray_short_id" ]]; then
      XRAY_SHORT_ID="$current_vps_xray_short_id"
    fi
    if [[ -n "$current_vps_xray_public_key" ]]; then
      XRAY_PUBLIC_KEY="$current_vps_xray_public_key"
    fi
    if [[ "$current_vps_config_port" =~ ^[0-9]+$ ]]; then
      if [[ "$current_vps_xray_port" =~ ^[0-9]+$ && "$current_vps_xray_port" != "$current_vps_config_port" ]]; then
        echo "Live VPS meta port ($current_vps_xray_port) differs from active VPS config port ($current_vps_config_port); using active config port."
      fi
      XRAY_PORT="$current_vps_config_port"
    fi
    echo "Synced router Xray client profile from live VPS meta: $VPS_SSH"
  fi
fi

require_vars \
  ROUTER_SSH \
  ROUTER_HOST \
  ROUTER_EXPECTED_MODEL \
  ROUTER_REQUIRED_COMMANDS \
  ROUTER_REQUIRES_DNSMASQ_IPSET \
  XRAY_SERVER \
  XRAY_PORT \
  XRAY_UUID \
  XRAY_SERVER_NAME \
  XRAY_PUBLIC_KEY \
  XRAY_SHORT_ID

reject_placeholder_vars \
  ROUTER_SSH \
  ROUTER_HOST \
  XRAY_SERVER \
  XRAY_UUID \
  XRAY_SERVER_NAME \
  XRAY_PUBLIC_KEY \
  XRAY_SHORT_ID

router_facts="$(
  router_ssh "ROUTER_REQUIRED_COMMANDS=$(shell_quote "$ROUTER_REQUIRED_COMMANDS") sh -s" <<'EOF'
model="$(cat /tmp/sysinfo/board_name 2>/dev/null | sed -n '1p')"
missing=''
for c in $ROUTER_REQUIRED_COMMANDS; do
  command -v "$c" >/dev/null 2>&1 || missing="${missing}${c} "
done
dnsmasq_ipset='0'
if dnsmasq --help 2>/dev/null | grep -qi 'ipset'; then
  dnsmasq_ipset='1'
fi
printf 'MODEL=%s\n' "$model"
printf 'MISSING=%s\n' "$missing"
printf 'DNSMASQ_IPSET=%s\n' "$dnsmasq_ipset"
EOF
)"

router_model="$(printf '%s\n' "$router_facts" | sed -n 's/^MODEL=//p' | sed -n '1p')"
router_missing="$(printf '%s\n' "$router_facts" | sed -n 's/^MISSING=//p' | sed -n '1p')"
router_dnsmasq_ipset="$(printf '%s\n' "$router_facts" | sed -n 's/^DNSMASQ_IPSET=//p' | sed -n '1p')"

if [[ "$router_model" != "$ROUTER_EXPECTED_MODEL" ]]; then
  echo "Unsupported router model for profile $ROUTER_PROFILE: expected $ROUTER_EXPECTED_MODEL, got ${router_model:-unknown}" >&2
  exit 1
fi

if [[ -n "${router_missing// }" ]]; then
  echo "Router is missing required commands for profile $ROUTER_PROFILE: $router_missing" >&2
  exit 1
fi

if [[ "$ROUTER_REQUIRES_DNSMASQ_IPSET" == "1" && "$router_dnsmasq_ipset" != "1" ]]; then
  echo "Router dnsmasq does not expose ipset support, which this profile requires for selective routing." >&2
  exit 1
fi

if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
  echo "Router preflight passed for profile $ROUTER_PROFILE on $ROUTER_HOST"
  exit 0
fi

# All required parameters and the router preflight have already passed by
# this point. Announce the plan so the operator (and the UI banner that
# tails the status file) sees what is about to happen.
install_progress_reset
install_progress_plan \
  "Resolve router profile and runtime context" \
  "Render router config templates" \
  "Stage source bundle on router" \
  "Install router platform packages and runtime" \
  "Validate Xray config and apply runtime" \
  "Provision VPS profile for admin UI" \
  "Reload router network" \
  "Verify management plane reachable" \
  "Verify selective routing health" \
  "End-to-end probe through router proxy"

install_progress_begin "Resolve router profile and runtime context"

if [[ "${PRESERVE_XRAY_RULES_MODE:-1}" == "1" ]]; then
  current_mode="$(current_router_rules_mode || true)"
  case "$current_mode" in
    full|selective)
      XRAY_RULES_MODE="$current_mode"
      echo "Preserving router xray mode: $XRAY_RULES_MODE"
      ;;
  esac
fi

if [[ "${PRESERVE_EXTERNAL_SOURCE_SETTINGS:-1}" == "1" ]]; then
  current_external_cfg="$(current_router_external_source_config || true)"
  current_external_enabled="$(printf '%s\n' "$current_external_cfg" | sed -n 's/^ENABLED=//p' | sed -n '1p')"
  current_external_url="$(printf '%s\n' "$current_external_cfg" | sed -n 's/^URL=//p' | sed -n '1p')"
  current_external_interval="$(printf '%s\n' "$current_external_cfg" | sed -n 's/^INTERVAL=//p' | sed -n '1p')"
  case "$current_external_enabled" in
    0|1)
      RULES_EXTERNAL_SOURCE_ENABLED="$current_external_enabled"
      ;;
  esac
  if [[ -n "$current_external_url" ]]; then
    RULES_EXTERNAL_SOURCE_URL="$current_external_url"
  fi
  if [[ "$current_external_interval" =~ ^[0-9]+$ ]]; then
    RULES_EXTERNAL_SOURCE_INTERVAL="$current_external_interval"
  fi
fi

if [[ "${ISOLATE_WIFI_LAN_ONLY:-0}" == "1" && "$ROUTER_HOST" == "$ROUTER_LAN_IP" ]]; then
  echo "Warning: ROUTER_HOST matches ROUTER_LAN_IP while ISOLATE_WIFI_LAN_ONLY=1." >&2
  echo "Deploy may remove the wired LAN port from br-lan and drop the current management path." >&2
fi

tmpdir="$(mktemp -d)"
trap cleanup EXIT

export \
  PROXY_PORT \
  LOCAL_SOCKS_PORT \
  REDSOCKS_PORT \
  TPROXY_UDP_PORT \
  XRAY_SERVER \
  XRAY_PORT \
  XRAY_UUID \
  XRAY_SERVER_NAME \
  XRAY_PUBLIC_KEY \
  XRAY_SHORT_ID \
  XRAY_WS_PATH \
  RULES_GIT_SYNC_ENABLED \
  RULES_REPO_FETCH_URL \
  RULES_REPO_PUSH_URL \
  RULES_REPO_BRANCH \
  RULES_GIT_AUTH_MODE \
  RULES_GIT_HTTP_USERNAME \
  RULES_GIT_HTTP_PASSWORD \
  RULES_GIT_USER_NAME \
  RULES_GIT_USER_EMAIL \
  RULES_DNS_RESOLVER \
  RULES_DEVICE_ID \
  RULES_ENABLE_PUSH \
  RULES_SYNC_INTERVAL \
  RULES_EXTERNAL_SOURCE_ENABLED \
  RULES_EXTERNAL_SOURCE_URL \
  RULES_EXTERNAL_SOURCE_INTERVAL \
  XRAY_RULES_MODE

if [[ -n "${XRAY_FLOW:-}" ]]; then
  printf -v XRAY_USER_FLOW_BLOCK ',\n                "flow": "%s"' "$XRAY_FLOW"
  printf -v XRAY_CLIENT_FLOW_BLOCK ',\n            "flow": "%s"' "$XRAY_FLOW"
else
  XRAY_USER_FLOW_BLOCK=""
  XRAY_CLIENT_FLOW_BLOCK=""
fi
export XRAY_USER_FLOW_BLOCK XRAY_CLIENT_FLOW_BLOCK

install_router_main
