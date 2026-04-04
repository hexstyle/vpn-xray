#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/common/lib/env.sh"

ENV_FILE="${ENV_FILE:-$(default_install_env_file "$ROOT_DIR")}"
PREFLIGHT_ONLY=0
if [[ "${1:-}" == "--preflight" ]]; then
  PREFLIGHT_ONLY=1
fi

ENV_ROUTER_SSH="${ROUTER_SSH:-}"
ENV_ROUTER_HOST="${ROUTER_HOST:-}"
ENV_ROUTER_LAN_IP="${ROUTER_LAN_IP:-}"
NETWORK_RELOAD="${NETWORK_RELOAD:-0}"

load_env_file "$ENV_FILE" "$(default_install_env_example "$ROOT_DIR")"
ROUTER_PROFILE="${ROUTER_PROFILE:-gl-mt3000-glinet}"
require_supported_profile router "$ROOT_DIR" "$ROUTER_PROFILE"
ROUTER_PROFILE_DIR="$(router_profile_dir "$ROOT_DIR" "$ROUTER_PROFILE")"
ROUTER_COMMON_DIR="$(router_common_dir "$ROOT_DIR")"
load_profile_defaults "$ROUTER_PROFILE_DIR/profile.env"

if [[ -n "$ENV_ROUTER_SSH" ]]; then
  ROUTER_SSH="$ENV_ROUTER_SSH"
fi
if [[ -n "$ENV_ROUTER_HOST" ]]; then
  ROUTER_HOST="$ENV_ROUTER_HOST"
fi
if [[ -n "$ENV_ROUTER_LAN_IP" ]]; then
  ROUTER_LAN_IP="$ENV_ROUTER_LAN_IP"
fi

require_local_commands bash ssh ssh-keygen tar python3

ROUTER_SSH="${ROUTER_SSH:-root@${ROUTER_HOST:-}}"
ROUTER_HOST="${ROUTER_HOST:-$(host_from_ssh_target "$ROUTER_SSH")}"
ROUTER_LAN_IP="${ROUTER_LAN_IP:-$ROUTER_HOST}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
ensure_installer_ssh_state "$ROOT_DIR"
INSTALLER_KNOWN_HOSTS="$(installer_known_hosts_file "$ROOT_DIR")"
ROUTER_SSH_OPTS=(
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS"
)

RULES_REPO_FETCH_URL="${RULES_REPO_FETCH_URL:-}"
RULES_REPO_PUSH_URL="${RULES_REPO_PUSH_URL:-}"
RULES_REPO_BRANCH="${RULES_REPO_BRANCH:-main}"
RULES_DEVICE_ID="${RULES_DEVICE_ID:-gl-router}"

router_ssh() {
  local err rc

  err="$(mktemp)"
  if ssh "${ROUTER_SSH_OPTS[@]}" "$ROUTER_SSH" "$@" 2>"$err"; then
    rm -f "$err"
    return 0
  fi

  rc=$?
  cat "$err" >&2

  if grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$err"; then
    echo "Installer SSH cache has a stale host key for $ROUTER_HOST. Refreshing and retrying once..." >&2
    remove_hostkey_entry "$INSTALLER_KNOWN_HOSTS" "$ROUTER_HOST"
    if ssh "${ROUTER_SSH_OPTS[@]}" "$ROUTER_SSH" "$@" 2>"$err"; then
      rm -f "$err"
      return 0
    fi
    rc=$?
    cat "$err" >&2
  fi

  echo "Router SSH failed for $ROUTER_SSH." >&2
  echo "Checks: the router should be reachable at $ROUTER_HOST, SSH must accept the current admin password, and the installer uses its own host-key cache at $INSTALLER_KNOWN_HOSTS." >&2
  echo "If the router was factory-reset or replaced, rerun the install. The stale key in ~/.ssh/known_hosts is no longer relevant to this installer." >&2
  rm -f "$err"
  return "$rc"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

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
  router_ssh ROUTER_REQUIRED_COMMANDS="$ROUTER_REQUIRED_COMMANDS" 'sh -s' <<'EOF'
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

if [[ "${ISOLATE_WIFI_LAN_ONLY:-0}" == "1" && "$ROUTER_HOST" == "$ROUTER_LAN_IP" ]]; then
  echo "Warning: ROUTER_HOST matches ROUTER_LAN_IP while ISOLATE_WIFI_LAN_ONLY=1." >&2
  echo "Deploy may remove the wired LAN port from br-lan and drop the current management path." >&2
fi

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

template_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
template = template_path.read_text()

def repl(match):
    key = match.group(1)
    try:
        return os.environ[key]
    except KeyError:
        raise SystemExit(f"Template {template_path} requires env variable {key}, but it is missing")

output_path.write_text(re.sub(r"\$\{([A-Z0-9_]+)\}", repl, template))
PY
}

source_bundle="$tmpdir/router-source.tar"
json_cfg="$tmpdir/codex-xray.json"
redsocks_cfg="$tmpdir/redsocks.conf"
router_rules_cfg="$tmpdir/router-rules.config"

tar -C "$ROOT_DIR" -cf "$source_bundle" common routers vps
render_template "$ROUTER_PROFILE_DIR/files/codex-xray.json.template" "$json_cfg"
render_template "$ROUTER_PROFILE_DIR/files/redsocks.conf.template" "$redsocks_cfg"
render_template "$ROUTER_COMMON_DIR/files/router-rules.config.template" "$router_rules_cfg"

remote_source_root='/tmp/vpn-xray-local-src'
remote_source_tar='/tmp/vpn-xray-local-src.tar'
remote_platform_cmd=$(
  cat <<EOF
RULES_REPO_FETCH_URL=$(shell_quote "$RULES_REPO_FETCH_URL") \
RULES_REPO_PUSH_URL=$(shell_quote "$RULES_REPO_PUSH_URL") \
RULES_REPO_BRANCH=$(shell_quote "$RULES_REPO_BRANCH") \
RULES_DEVICE_ID=$(shell_quote "$RULES_DEVICE_ID") \
RULES_ENABLE_PUSH=$(shell_quote "${RULES_ENABLE_PUSH:-0}") \
RULES_SYNC_INTERVAL=$(shell_quote "${RULES_SYNC_INTERVAL:-30}") \
RULES_GIT_USER_NAME=$(shell_quote "${RULES_GIT_USER_NAME:-router-rules}") \
RULES_GIT_USER_EMAIL=$(shell_quote "${RULES_GIT_USER_EMAIL:-router-rules@example.invalid}") \
RULES_DNS_RESOLVER=$(shell_quote "${RULES_DNS_RESOLVER:-1.1.1.1 9.9.9.9}") \
XRAY_RULES_MODE=$(shell_quote "${XRAY_RULES_MODE:-full}") \
ISOLATE_WIFI_LAN_ONLY=$(shell_quote "${ISOLATE_WIFI_LAN_ONLY:-0}") \
VPN_XRAY_REPO_SLUG=$(shell_quote "local-source-bundle") \
VPN_XRAY_REF=$(shell_quote "local-install") \
sh $(shell_quote "$remote_source_root/routers/$ROUTER_PROFILE/install-platform.sh") --source-dir $(shell_quote "$remote_source_root")
EOF
)

router_ssh "rm -rf $remote_source_root && mkdir -p $remote_source_root"
router_ssh "cat > $remote_source_tar" < "$source_bundle"
router_ssh "tar -xf $remote_source_tar -C $remote_source_root && rm -f $remote_source_tar"
router_ssh "$remote_platform_cmd"

router_ssh 'cat > /etc/xray/codex-xray.json && chmod 600 /etc/xray/codex-xray.json' < "$json_cfg"
router_ssh 'cat > /etc/redsocks.conf && chmod 600 /etc/redsocks.conf' < "$redsocks_cfg"
router_ssh 'cat > /etc/config/router_rules && chmod 600 /etc/config/router_rules' < "$router_rules_cfg"

router_ssh "
  /etc/init.d/xray-switch-watchdog stop >/dev/null 2>&1 || true
  /etc/init.d/router-rules-sync stop >/dev/null 2>&1 || true
  /usr/local/bin/codex-xray-core run -test -config /etc/xray/codex-xray.json >/dev/null 2>&1 || {
    echo 'Router Xray config validation failed after upload.' >&2
    exit 1
  }
  touch /etc/xray/codex-xray.ready
  chmod 600 /etc/xray/codex-xray.ready
  /etc/init.d/codex-transproxy stop >/dev/null 2>&1 || true
  /etc/init.d/codex-xray stop >/dev/null 2>&1 || true
  /usr/bin/router-rules ensure-git-key >/dev/null 2>&1 || true
  /usr/bin/router-rules sync-apply-xray >/dev/null 2>&1 || true
  /etc/init.d/router-rules-sync start >/dev/null 2>&1 || true
  /etc/init.d/xray-switch-watchdog start >/dev/null 2>&1 || true
  switch_state='off'
  if [ -f /lib/functions/gl_util.sh ]; then
    . /lib/functions/gl_util.sh
    switch_state=\$(get_switch_button_status 2>/dev/null || echo off)
  fi
  /etc/gl-switch.d/xray.sh \"\$switch_state\" >/dev/null 2>&1 || true
  rm -rf $remote_source_root
"

if [[ "$NETWORK_RELOAD" == "1" ]]; then
  router_ssh '/etc/init.d/network reload >/dev/null 2>&1 || true'
fi

echo "Deployed to $ROUTER_HOST"
echo "LAN proxy:  http://$ROUTER_LAN_IP:$PROXY_PORT"
echo "WAN proxy:  http://$ROUTER_HOST:$PROXY_PORT"
echo "Web UI:     https://$ROUTER_HOST/xray.html"
echo "Rules key:  ssh $ROUTER_SSH 'cat /etc/router-rules/ssh/routerRules_ed25519.pub'"
