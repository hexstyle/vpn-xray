#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/common/lib/env.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/common/lib/install-progress.sh"

# install_progress_init writes a workstation-side status file. The router-
# side file under /tmp/vpn-xray-install-status.json is updated separately
# by install-platform.sh once the bundle lands on the device.
install_progress_init "$ROOT_DIR/tmp/install-status.json"

# Mirror each step to the router so the UI banner can render live progress.
# Override the per-step hook from install-progress.sh.
ROUTER_INSTALL_STATUS_FILE='/tmp/vpn-xray-install-status.json'
install_progress_after_update() {
  # Hook called by install-progress.sh after every transition. Mirror the
  # JSON to the router so the UI banner can render live progress. Failures
  # are intentionally swallowed — telemetry must not break the install.
  [ -n "${ROUTER_SSH:-}" ] || return 0
  [ -n "${INSTALLER_KNOWN_HOSTS:-}" ] || return 0
  [ -f "${_VX_PROGRESS_STATUS_FILE:-}" ] || return 0
  ssh \
    -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS" \
    "$ROUTER_SSH" "cat > $ROUTER_INSTALL_STATUS_FILE.tmp && mv $ROUTER_INSTALL_STATUS_FILE.tmp $ROUTER_INSTALL_STATUS_FILE" \
    < "$_VX_PROGRESS_STATUS_FILE" >/dev/null 2>&1 || true
}

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
ROUTER_PROFILE="${ROUTER_PROFILE:-gl-mt3000-glinet}"
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

router_ssh() {
  local err rc attempt max_retries=3

  for (( attempt = 1; attempt <= max_retries; attempt++ )); do
    err="$(mktemp)"
    if ssh "${ROUTER_SSH_OPTS[@]}" "$ROUTER_SSH" "$@" 2>"$err"; then
      rm -f "$err"
      return 0
    fi

    rc=$?

    if grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$err"; then
      cat "$err" >&2
      echo "Installer SSH cache has a stale host key for $ROUTER_HOST. Refreshing and retrying once..." >&2
      remove_hostkey_entry "$INSTALLER_KNOWN_HOSTS" "$ROUTER_HOST"
      rm -f "$err"
      continue
    fi

    # Retry on transient connection failures (network reload, WiFi blip)
    if grep -qiE 'Connection reset|Broken pipe|Connection refused|Connection timed out|No route to host' "$err" && (( attempt < max_retries )); then
      echo "Router SSH attempt $attempt/$max_retries failed (transient). Retrying in 3s..." >&2
      rm -f "$err"
      sleep 3
      continue
    fi

    cat "$err" >&2
    rm -f "$err"
    break
  done

  echo "Router SSH failed for $ROUTER_SSH." >&2
  echo "Checks: the router should be reachable at $ROUTER_HOST, SSH must accept the current admin password, and the installer uses its own host-key cache at $INSTALLER_KNOWN_HOSTS." >&2
  echo "If the router was factory-reset or replaced, rerun the install. The stale key in ~/.ssh/known_hosts is no longer relevant to this installer." >&2
  return "$rc"
}

router_ssh_ready() {
  ssh \
    -o ConnectTimeout="$ROUTER_RELOAD_PROBE_TIMEOUT" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS" \
    "$ROUTER_SSH" "true" >/dev/null 2>&1
}

wait_for_router_after_network_reload() {
  local deadline

  deadline=$((SECONDS + ROUTER_RELOAD_WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if router_ssh_ready; then
      return 0
    fi
    sleep 2
  done
  return 1
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

current_router_rules_mode() {
  local mode

  mode="$(router_ssh "uci -q get router_rules.global.xray_mode 2>/dev/null || true" | tr -d '\r' | sed -n '1p')"
  case "$mode" in
    full|selective)
      printf '%s\n' "$mode"
      ;;
  esac
}

current_router_external_source_config() {
  router_ssh "printf 'ENABLED=%s\n' \"\$(uci -q get router_rules.global.external_source_enabled 2>/dev/null || true)\"; printf 'URL=%s\n' \"\$(uci -q get router_rules.global.external_source_url 2>/dev/null || true)\"; printf 'INTERVAL=%s\n' \"\$(uci -q get router_rules.global.external_source_interval 2>/dev/null || true)\""
}

current_vps_xray_meta() {
  [[ -n "${VPS_SSH:-}" ]] || return 1
  ssh "${VPS_SSH_OPTS[@]}" "$VPS_SSH" "meta='/usr/local/etc/xray/codex-router-meta.env'; [ -f \"\$meta\" ] || exit 1; sed -n '1,200p' \"\$meta\""
}

current_vps_xray_runtime_facts() {
  [[ -n "${VPS_SSH:-}" ]] || return 1
  ssh "${VPS_SSH_OPTS[@]}" "$VPS_SSH" "CONFIG_PATH=$(shell_quote "${VPS_XRAY_CONFIG_PATH:-/usr/local/etc/xray/config.json}") sh -s" <<'EOF'
config_path="${CONFIG_PATH:-/usr/local/etc/xray/config.json}"
[ -f "$config_path" ] || exit 1
config_port="$(sed -n 's/^[[:space:]]*"port":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$config_path" | sed -n '1p')"
[ -n "$config_port" ] && printf 'CONFIG_PORT=%s\n' "$config_port"
EOF
}

wait_for_router_runtime_ready() {
  local attempt max_attempts sleep_seconds

  max_attempts="${ROUTER_RUNTIME_READY_ATTEMPTS:-30}"
  sleep_seconds="${ROUTER_RUNTIME_READY_INTERVAL:-2}"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if router_ssh "pgrep -af codex-xray-core >/dev/null 2>&1 && pgrep -af redsocks >/dev/null 2>&1"; then
      return 0
    fi
    sleep "$sleep_seconds"
  done

  return 1
}

wait_for_router_background_services_ready() {
  local attempt max_attempts sleep_seconds

  max_attempts="${ROUTER_BACKGROUND_READY_ATTEMPTS:-20}"
  sleep_seconds="${ROUTER_BACKGROUND_READY_INTERVAL:-1}"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if router_ssh "/etc/init.d/xray-switch-watchdog running >/dev/null 2>&1 && /etc/init.d/router-rules-sync running >/dev/null 2>&1"; then
      return 0
    fi
    sleep "$sleep_seconds"
  done

  return 1
}

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
model="$(cat /proc/gl-hw-info/model 2>/dev/null | sed -n '1p')"
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
cleanup() {
  rm -rf "$tmpdir"
}
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

render_template() {
  local input="$1"
  local output="$2"
  MSYS2_ENV_CONV_EXCL='*' python3 - <<'PY' "$input" "$output"
import os, pathlib, re, sys

template_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
template = template_path.read_text()

def repl(match):
    key = match.group(1)
    try:
        return os.environ[key]
    except KeyError:
        raise SystemExit(f"Template {template_path} requires env variable {key}, but it is missing")

with output_path.open("w", encoding="utf-8", newline="\n") as fh:
    fh.write(re.sub(r"\$\{([A-Z0-9_]+)\}", repl, template))
PY
}

source_bundle="$tmpdir/router-source.tar"
json_cfg="$tmpdir/codex-xray.json"
redsocks_cfg="$tmpdir/redsocks.conf"
router_rules_cfg="$tmpdir/router-rules.config"

install_progress_begin "Render router config templates"
tar -C "$ROOT_DIR" -cf "$source_bundle" common routers vps
render_template "$ROUTER_PROFILE_DIR/files/codex-xray.json.template" "$json_cfg"
render_template "$ROUTER_PROFILE_DIR/files/redsocks.conf.template" "$redsocks_cfg"
render_template "$ROUTER_COMMON_DIR/files/router-rules.config.template" "$router_rules_cfg"

PLATFORM_RESUME_FLAG=''
if router_ssh "[ -f /tmp/vpn-xray-install-progress ]" >/dev/null 2>&1; then
  PLATFORM_RESUME_FLAG=' --resume'
fi

remote_source_root='/tmp/vpn-xray-local-src'
remote_source_tar='/tmp/vpn-xray-local-src.tar'
remote_platform_cmd=$(
  cat <<EOF
RULES_GIT_SYNC_ENABLED=$(shell_quote "$RULES_GIT_SYNC_ENABLED") \
RULES_REPO_FETCH_URL=$(shell_quote "$RULES_REPO_FETCH_URL") \
RULES_REPO_PUSH_URL=$(shell_quote "$RULES_REPO_PUSH_URL") \
RULES_REPO_BRANCH=$(shell_quote "$RULES_REPO_BRANCH") \
RULES_GIT_AUTH_MODE=$(shell_quote "$RULES_GIT_AUTH_MODE") \
RULES_GIT_HTTP_USERNAME=$(shell_quote "$RULES_GIT_HTTP_USERNAME") \
RULES_GIT_HTTP_PASSWORD=$(shell_quote "$RULES_GIT_HTTP_PASSWORD") \
RULES_GIT_SSH_PRIVATE_KEY_B64=$(shell_quote "$RULES_GIT_SSH_PRIVATE_KEY_B64") \
RULES_DEVICE_ID=$(shell_quote "$RULES_DEVICE_ID") \
RULES_ENABLE_PUSH=$(shell_quote "${RULES_ENABLE_PUSH:-0}") \
RULES_SYNC_INTERVAL=$(shell_quote "${RULES_SYNC_INTERVAL:-30}") \
RULES_EXTERNAL_SOURCE_ENABLED=$(shell_quote "${RULES_EXTERNAL_SOURCE_ENABLED:-0}") \
RULES_EXTERNAL_SOURCE_URL=$(shell_quote "${RULES_EXTERNAL_SOURCE_URL:-}") \
RULES_EXTERNAL_SOURCE_INTERVAL=$(shell_quote "${RULES_EXTERNAL_SOURCE_INTERVAL:-86400}") \
RULES_GIT_USER_NAME=$(shell_quote "${RULES_GIT_USER_NAME:-router-rules}") \
RULES_GIT_USER_EMAIL=$(shell_quote "${RULES_GIT_USER_EMAIL:-router-rules@example.invalid}") \
RULES_DNS_RESOLVER=$(shell_quote "${RULES_DNS_RESOLVER:-9.9.9.9 208.67.222.222}") \
XRAY_RULES_MODE=$(shell_quote "${XRAY_RULES_MODE:-full}") \
ISOLATE_WIFI_LAN_ONLY=$(shell_quote "${ISOLATE_WIFI_LAN_ONLY:-0}") \
VPN_XRAY_REPO_SLUG=$(shell_quote "local-source-bundle") \
VPN_XRAY_REF=$(shell_quote "local-install") \
sh $(shell_quote "$remote_source_root/routers/$ROUTER_PROFILE/install-platform.sh") --source-dir $(shell_quote "$remote_source_root")${PLATFORM_RESUME_FLAG}
EOF
)

install_progress_begin "Stage source bundle on router"
router_ssh "rm -rf $remote_source_root && mkdir -p $remote_source_root"
router_ssh "cat > $remote_source_tar" < "$source_bundle"
router_ssh "tar -xf $remote_source_tar -C $remote_source_root && rm -f $remote_source_tar"
router_ssh "sed -i 's/\r$//' $remote_source_root/routers/$ROUTER_PROFILE/install-platform.sh"

# Deploy configs BEFORE install-platform.sh so they survive if the router
# reboots during platform setup (e.g. network/wireless reload).
router_ssh 'mkdir -p /etc/xray /var/log/xray'
router_ssh 'cat > /etc/xray/codex-xray.json && chmod 600 /etc/xray/codex-xray.json' < "$json_cfg"
router_ssh 'cat > /etc/redsocks.conf && chmod 600 /etc/redsocks.conf' < "$redsocks_cfg"
# Only seed /etc/config/router_rules from the rendered template when the file
# is missing or empty. The template only enumerates a fixed set of options;
# overwriting an existing file would wipe per-source enable flags
# (external_source_<id>_enabled), the layout-version marker, and any other
# state the UI / router-rules has stored. install-platform.sh then reconciles
# the template-known options via `uci batch`, so the existing file gets the
# desired values without losing user state.
if router_ssh '[ -s /etc/config/router_rules ]'; then
  echo "Existing /etc/config/router_rules detected; install-platform will reconcile via uci batch."
else
  router_ssh 'cat > /etc/config/router_rules && chmod 600 /etc/config/router_rules' < "$router_rules_cfg"
fi

install_progress_begin "Install router platform packages and runtime"
router_ssh "$remote_platform_cmd"

install_progress_begin "Validate Xray config and apply runtime"
# install-platform.sh already restarted services (codex-xray, codex-
# transproxy, router-rules-sync, xray-switch-watchdog) and ran
# sync-apply-xray as part of the services step. Re-stopping and re-
# applying everything here previously cost ~127s on a no-op deploy
# because we tore xray down and forced sync-apply-xray to do a full
# cutover from scratch. Keep this step lightweight: validate the
# uploaded config (mostly defensive — install-platform.sh already
# started xray with it), make sure the ready marker reflects success,
# and clean the remote staging dir.
router_ssh "
  exec </dev/null
  /usr/local/bin/codex-xray-core run -test -config /etc/xray/codex-xray.json >/dev/null 2>&1 || {
    echo 'Router Xray config validation failed after upload.' >&2
    exit 1
  }
  touch /etc/xray/codex-xray.ready
  chmod 600 /etc/xray/codex-xray.ready
  rm -rf $remote_source_root
"

# Surface the live switch state for the operator. The init scripts
# already start in the right state via install-platform.sh; this is just
# a re-trigger of the gl-switch hook so a hardware switch toggle that
# happened during the deploy is honoured immediately.
router_ssh "
  switch_state=off
  if [ -f /lib/functions/gl_util.sh ]; then
    . /lib/functions/gl_util.sh
    switch_state=\$(get_switch_button_status 2>/dev/null || echo off)
  fi
  /etc/gl-switch.d/xray.sh \"\$switch_state\" >/dev/null 2>&1 || true
"

if ! wait_for_router_background_services_ready; then
  echo "Warning: router background supervisors did not report ready before installer exit." >&2
fi

if ! wait_for_router_runtime_ready; then
  echo "Warning: router runtime did not report ready before installer exit." >&2
fi

install_progress_begin "Provision VPS profile for admin UI"
# Bootstrap VPS profile on the router so the admin panel VPS sync works
# out of the box: create the xray_vps UCI config from the deployed xray
# client config and register the router's managed SSH key on the VPS.
# Runs BEFORE network reload — reload drops SSH connections.
if [[ -n "${VPS_SSH:-}" && -n "${VPS_HOST:-}" ]]; then
  echo "Bootstrapping router VPS profile for admin panel..."

  # Force fresh profile creation from the just-deployed xray config.
  # Any stale xray_vps from a previous install would have wrong values.
  router_ssh "rm -f /etc/config/xray_vps"

  # Invoke the VPS CGI to initialize the profile store: creates a
  # 'default' profile from the router config, generates x25519 material,
  # and creates a managed SSH key pair for router→VPS access.
  router_ssh "QUERY_STRING='action=generate_key' REQUEST_METHOD='GET' /www/cgi-bin/xray-vps >/dev/null 2>&1 || true"

  # Retrieve the router's managed SSH public key
  router_pubkey="$(router_ssh "cat /etc/xray/ssh-keys/default_ed25519.pub 2>/dev/null" || true)"

  if [[ -n "$router_pubkey" ]]; then
    echo "Registering router managed SSH key on VPS ($VPS_HOST)..."
    printf '%s\n' "$router_pubkey" | ssh "${VPS_SSH_OPTS[@]}" "$VPS_SSH" "
      mkdir -p ~/.ssh && chmod 700 ~/.ssh
      touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
      PUB=\$(cat)
      grep -qxF \"\$PUB\" ~/.ssh/authorized_keys 2>/dev/null || printf '%s\n' \"\$PUB\" >> ~/.ssh/authorized_keys
    " 2>/dev/null || echo "Warning: could not register router SSH key on VPS. Admin panel VPS sync will need manual key setup." >&2
  else
    echo "Warning: router did not produce a managed SSH public key. Admin panel VPS sync will need manual key setup." >&2
  fi
else
  echo "VPS_SSH is not configured; skipping admin panel VPS profile bootstrap."
fi

install_progress_begin "Reload router network"
# Network reload is the last step — it drops all active SSH connections
# to the router, so no SSH commands should follow it.
if [[ "$NETWORK_RELOAD" == "1" ]]; then
  router_ssh "nohup sh -c 'sleep 1; /etc/init.d/network reload >/tmp/vpn-xray-network-reload.log 2>&1 || true' >/dev/null 2>&1 &" >/dev/null 2>&1 || true
  echo "Queued async network reload on $ROUTER_HOST"
  echo "Waiting for router SSH to recover after network reload..."
  sleep 3
  if wait_for_router_after_network_reload; then
    echo "Router is reachable again over SSH after network reload"
  else
    install_progress_fail "Router did not come back over SSH after network reload" "Verify both wired and Wi-Fi management access before re-running the install."
    exit 1
  fi
fi

install_progress_begin "Verify management plane reachable"
if ! router_ssh_ready; then
  install_progress_fail "Router SSH is not reachable after deploy" "Power-cycle the router and re-run the installer. If SSH still fails, restore the previous config from /etc/config backups."
  exit 1
fi

install_progress_begin "Verify selective routing health"
# Surface the live xray mode, ipset count, and last sync state so the
# operator immediately sees whether selective is up or pulling failed.
selective_health="$(router_ssh "
  mode=\$(uci -q get router_rules.global.xray_mode 2>/dev/null)
  ipset_n=\$(ipset list xray_selective_dst 2>/dev/null | sed -n 's/^Number of entries: //p')
  last=\$(/usr/bin/router-rules status-json 2>/dev/null | sed -n 's/.*\"last_sync_status\":\"\\([^\"]*\\)\".*/\\1/p')
  msg=\$(/usr/bin/router-rules status-json 2>/dev/null | sed -n 's/.*\"last_sync_message\":\"\\([^\"]*\\)\".*/\\1/p')
  echo \"mode=\${mode:-unknown}\"
  echo \"ipset=\${ipset_n:-0}\"
  echo \"sync=\${last:-unknown}\"
  echo \"sync_msg=\${msg:-}\"
" || true)"
selective_mode="$(printf '%s\n' "$selective_health" | sed -n 's/^mode=//p' | sed -n '1p')"
selective_ipset="$(printf '%s\n' "$selective_health" | sed -n 's/^ipset=//p' | sed -n '1p')"
selective_sync="$(printf '%s\n' "$selective_health" | sed -n 's/^sync=//p' | sed -n '1p')"
selective_sync_msg="$(printf '%s\n' "$selective_health" | sed -n 's/^sync_msg=//p' | sed -n '1p')"
echo "Routing mode: ${selective_mode:-unknown}, ipset entries: ${selective_ipset:-0}, last sync: ${selective_sync:-unknown}"

# Selective→FULL fallback: when install.env asked for selective but the
# rules repo did not pull cleanly, drop into FULL temporarily so the
# user keeps working internet, and let the router-rules-sync background
# loop promote us back to selective the moment the network recovers.
# Only activate when the request was selective; if XRAY_RULES_MODE=full,
# nothing extra is needed.
if [[ "${XRAY_RULES_MODE:-full}" == "selective" ]] \
   && [[ "$selective_sync" != "ok" ]] \
   && [[ -n "$selective_sync_msg" || "${selective_ipset:-0}" == "0" ]]; then
  fallback_reason="${selective_sync_msg:-Initial rules sync failed: status=${selective_sync}}"
  echo "Selective rules sync failed (${selective_sync}). Activating FULL fallback; background-tick will retry every sync interval."
  echo "  Reason: $fallback_reason"
  router_ssh "/usr/bin/router-rules enable-selective-fallback $(shell_quote "$fallback_reason") >/dev/null 2>&1; /usr/bin/router-rules sync-apply-xray >/dev/null 2>&1 || true"
fi

install_progress_begin "End-to-end probe through router proxy"
# Verify the data plane works the way the user actually consumes it.
# Two-stage probe through the router HTTP-proxy port:
#  1. Reachability: any HTTP response from chatgpt.com proves TCP+TLS+HTTP
#     all completed end-to-end; antibot 4xx pages still count as "the
#     proxy chain works". Only timeouts / connection refused are failures.
#  2. Chain identity: query an IP echo endpoint and confirm the visible
#     egress IP matches the VPS host, which is the only way to be sure
#     traffic is actually leaving through xray and not, say, the router's
#     direct WAN.
e2e_target="${VPN_XRAY_E2E_TARGET:-https://chatgpt.com}"
e2e_timeout="${VPN_XRAY_E2E_TIMEOUT:-15}"
e2e_proxy="http://${ROUTER_LAN_IP}:${PROXY_PORT}"
e2e_ip_target="${VPN_XRAY_E2E_IP_TARGET:-https://api.ipify.org}"

set +e
e2e_status=''
e2e_curl_err=''
if command -v curl >/dev/null 2>&1; then
  e2e_curl_err="$(mktemp)"
  e2e_status="$(curl --proxy "$e2e_proxy" -ksS -o /dev/null -m "$e2e_timeout" \
    -w '%{http_code}' "$e2e_target" 2>"$e2e_curl_err" || true)"
fi

case "$e2e_status" in
  '')
    e2e_msg="$(sed -n '1p' "$e2e_curl_err" 2>/dev/null || true)"
    install_progress_fail \
      "Could not reach ${e2e_target} through ${e2e_proxy}${e2e_msg:+ (${e2e_msg})}" \
      "Check that the router HTTP proxy on port ${PROXY_PORT} is listening and the VPS Xray endpoint is reachable. Run: ssh $ROUTER_SSH 'logread -e codex-xray | tail'"
    e2e_ok=0
    ;;
  000)
    install_progress_fail \
      "Router proxy did not respond for ${e2e_target} (curl reported HTTP 000)" \
      "Confirm xray-core is running and listening on ${PROXY_PORT}. Run: ssh $ROUTER_SSH 'pgrep -af codex-xray-core; netstat -ltn | grep ${PROXY_PORT}'"
    e2e_ok=0
    ;;
  *)
    echo "  Reachability: ${e2e_target} responded HTTP ${e2e_status} via ${e2e_proxy}"
    e2e_ok=1
    ;;
esac
[ -f "$e2e_curl_err" ] && rm -f "$e2e_curl_err"

if [[ "${e2e_ok:-0}" == "1" ]]; then
  e2e_egress_ip=''
  if command -v curl >/dev/null 2>&1; then
    e2e_egress_ip="$(curl --proxy "$e2e_proxy" -ksS -m "$e2e_timeout" \
      "$e2e_ip_target" 2>/dev/null | tr -d '[:space:]')"
  fi
  if [[ -z "$e2e_egress_ip" ]]; then
    echo "  Egress IP probe to ${e2e_ip_target} returned no data; chain identity not confirmed (proxy still answered ${e2e_target})."
  elif [[ "$e2e_egress_ip" == "${XRAY_SERVER:-}" ]]; then
    echo "✓ End-to-end OK: ${e2e_target} reachable and egress IP ${e2e_egress_ip} matches VPS ${XRAY_SERVER}"
  else
    install_progress_fail \
      "Egress IP ${e2e_egress_ip} does not match VPS ${XRAY_SERVER:-unknown}" \
      "Traffic answered the proxy but is not leaving through the VPS. Verify that xray-core's outbound is connecting to ${XRAY_SERVER}:${XRAY_PORT} and that the firewall allows it."
    e2e_ok=0
  fi
fi
set -e
[[ "${e2e_ok:-0}" == "1" ]] || exit 1

install_progress_complete

echo "Deployed to $ROUTER_HOST"
echo "LAN proxy:  http://$ROUTER_LAN_IP:$PROXY_PORT"
echo "WAN proxy:  http://$ROUTER_HOST:$PROXY_PORT"
echo "Web UI:     https://$ROUTER_HOST/xray.html"
echo "Rules key:  ssh $ROUTER_SSH 'cat /etc/router-rules/ssh/routerRules_ed25519.pub'"
