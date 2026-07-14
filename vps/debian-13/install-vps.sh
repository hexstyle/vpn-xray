#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/common/lib/env.sh"

ENV_FILE="${ENV_FILE:-$(default_install_env_file "$ROOT_DIR")}"
PREFLIGHT_ONLY=0
if [[ "${1:-}" == "--preflight" ]]; then
  PREFLIGHT_ONLY=1
fi
load_env_file "$ENV_FILE" "$(default_install_env_example "$ROOT_DIR")"

VPS_PROFILE="${VPS_PROFILE:-debian-13}"
VPS_PROFILE_DIR="$(vps_profile_dir "$ROOT_DIR" "$VPS_PROFILE")"
require_supported_profile vps "$ROOT_DIR" "$VPS_PROFILE"
load_profile_defaults "$VPS_PROFILE_DIR/profile.env"
XRAY_PORT="${XRAY_PORT:-24443}"
XRAY_FLOW="${XRAY_FLOW:-}"

VPS_SSH="${VPS_SSH:-root@${VPS_HOST:-}}"
VPS_HOST="${VPS_HOST:-$(host_from_ssh_target "$VPS_SSH")}"
VPS_PASSWORD="${VPS_PASSWORD:-}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
ensure_installer_ssh_state "$ROOT_DIR"
INSTALLER_KNOWN_HOSTS="$(installer_known_hosts_file "$ROOT_DIR")"
VPS_SSH_OPTS=(
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS"
)

vps_ssh_with_password() {
  local err="$1"
  shift
  local askpass_script rc

  [[ -n "$VPS_PASSWORD" ]] || return 1

  if command -v sshpass >/dev/null 2>&1; then
    SSHPASS="$VPS_PASSWORD" sshpass -e ssh \
      -o BatchMode=no \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      "${VPS_SSH_OPTS[@]}" "$VPS_SSH" "$@" 2>"$err"
    return $?
  fi

  askpass_script="$(mktemp "$tmpdir/vps-askpass.XXXXXX")"
  cat > "$askpass_script" <<EOF
#!/bin/sh
printf '%s\n' $(shell_quote "$VPS_PASSWORD")
EOF
  chmod 700 "$askpass_script"
  DISPLAY=1 SSH_ASKPASS="$askpass_script" SSH_ASKPASS_REQUIRE=force \
    ssh \
      -o BatchMode=no \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      "${VPS_SSH_OPTS[@]}" "$VPS_SSH" "$@" 2>"$err"
  rc=$?
  rm -f "$askpass_script"
  return "$rc"
}

vps_ssh() {
  local err rc

  err="$(mktemp)"
  if ssh "${VPS_SSH_OPTS[@]}" "$VPS_SSH" "$@" 2>"$err"; then
    rm -f "$err"
    return 0
  fi

  rc=$?
  cat "$err" >&2

  if grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$err"; then
    echo "Installer SSH cache has a stale host key for $VPS_HOST. Refreshing and retrying once..." >&2
    remove_hostkey_entry "$INSTALLER_KNOWN_HOSTS" "$VPS_HOST"
    if ssh "${VPS_SSH_OPTS[@]}" "$VPS_SSH" "$@" 2>"$err"; then
      rm -f "$err"
      return 0
    fi
    rc=$?
    cat "$err" >&2
  fi

  if [[ -n "$VPS_PASSWORD" ]]; then
    echo "Key-based SSH failed for $VPS_SSH. Falling back to password auth." >&2
    if vps_ssh_with_password "$err" "$@"; then
      rm -f "$err"
      return 0
    fi
    rc=$?
    cat "$err" >&2
  fi

  echo "VPS SSH failed for $VPS_SSH." >&2
  echo "Checks: the VPS must be reachable, root SSH must already work from this computer, and the installer uses its own host-key cache at $INSTALLER_KNOWN_HOSTS." >&2
  echo "If the VPS was recreated, rerun the install. The stale key in ~/.ssh/known_hosts is no longer relevant to this installer." >&2
  rm -f "$err"
  return "$rc"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

require_vars \
  VPS_SSH VPS_HOST XRAY_PORT XRAY_UUID XRAY_SERVER_NAME XRAY_SHORT_ID XRAY_PRIVATE_KEY XRAY_PUBLIC_KEY \
  VPS_INSTALL_SCRIPT VPS_SERVER_CONFIG_TEMPLATE VPS_REMOTE_META_PATH \
  VPS_XRAY_BINARY VPS_XRAY_CONFIG_DIR VPS_XRAY_CONFIG_PATH VPS_XRAY_LOG_DIR VPS_XRAY_SERVICE \
  VPS_OS_ID VPS_OS_VERSION_PREFIX VPS_REQUIRED_PKG_MGR VPS_REQUIRES_SYSTEMD VPS_SUPPORTED_ARCH_REGEX

reject_placeholder_vars VPS_SSH VPS_HOST XRAY_UUID XRAY_SERVER_NAME XRAY_SHORT_ID XRAY_PRIVATE_KEY

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

if [[ -n "${XRAY_FLOW:-}" ]]; then
  printf -v XRAY_USER_FLOW_BLOCK ',\n                "flow": "%s"' "$XRAY_FLOW"
  printf -v XRAY_CLIENT_FLOW_BLOCK ',\n            "flow": "%s"' "$XRAY_FLOW"
else
  XRAY_USER_FLOW_BLOCK=""
  XRAY_CLIENT_FLOW_BLOCK=""
fi

export \
  XRAY_PORT \
  XRAY_UUID \
  XRAY_SERVER_NAME \
  XRAY_SHORT_ID \
  XRAY_PRIVATE_KEY \
  XRAY_USER_FLOW_BLOCK \
  XRAY_CLIENT_FLOW_BLOCK \
  XRAY_WS_PATH \
  VPS_TLS_CERT_PATH \
  VPS_TLS_KEY_PATH \
  VPS_REMOTE_META_PATH \
  VPS_XRAY_BINARY \
  VPS_XRAY_CONFIG_DIR \
  VPS_XRAY_CONFIG_PATH \
  VPS_XRAY_LOG_DIR \
  VPS_XRAY_SERVICE

render_template() {
  local input="$1"
  local output="$2"
  python3 - <<'PY' "$input" "$output"
import os, pathlib, re, sys
template_path = pathlib.Path(sys.argv[1])
template = template_path.read_text()
def repl(match):
    key = match.group(1)
    try:
        return os.environ[key]
    except KeyError:
        raise SystemExit(f"Template {template_path} requires env variable {key}, but it is missing")
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
XRAY_PORT=${XRAY_PORT:-24443}
XRAY_UUID=${XRAY_UUID}
XRAY_SERVER_NAME=${XRAY_SERVER_NAME}
XRAY_SHORT_ID=${XRAY_SHORT_ID}
XRAY_PRIVATE_KEY=${XRAY_PRIVATE_KEY}
XRAY_PUBLIC_KEY=${XRAY_PUBLIC_KEY}
XRAY_FLOW=${XRAY_FLOW:-}
EOF
render_template "$VPS_PROFILE_DIR/$VPS_INSTALL_SCRIPT" "$rendered_install"

remote_facts="$(
  vps_ssh "XRAY_PORT=$(shell_quote "$XRAY_PORT") VPS_XRAY_BINARY=$(shell_quote "$VPS_XRAY_BINARY") sh -s" <<'EOF'
os_id="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | sed -n '1p')"
os_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | sed -n '1p')"
arch="$(uname -m 2>/dev/null || true)"
pkg_mgr=''
for c in apt-get dnf yum apk zypper; do
  command -v "$c" >/dev/null 2>&1 && {
    pkg_mgr="$c"
    break
  }
done
systemd='0'
command -v systemctl >/dev/null 2>&1 && systemd='1'
xray_present='0'
for p in ${VPS_XRAY_BINARY} /usr/local/bin/xray /usr/bin/xray; do
  if [ -x "$p" ]; then
    xray_present='1'
    break
  fi
done
ipv4_addr="$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1 || true)"
port_check="$(ss -ltnp 2>/dev/null | grep \":${XRAY_PORT} \" || true)"
port_owner='0'
printf '%s' "$port_check" | grep -qi 'xray' && port_owner='xray'
port_check_first="$(printf '%s\n' "$port_check" | sed -n '1p')"
outbound_https='0'
if curl -4fsSI --connect-timeout 8 https://github.com >/dev/null 2>&1 || wget -4 -q --spider --timeout=8 https://github.com >/dev/null 2>&1; then
  outbound_https='1'
fi
printf 'OS_ID=%s\n' "$os_id"
printf 'OS_VERSION=%s\n' "$os_version"
printf 'ARCH=%s\n' "$arch"
printf 'PKG_MGR=%s\n' "$pkg_mgr"
printf 'SYSTEMD=%s\n' "$systemd"
printf 'XRAY_PRESENT=%s\n' "$xray_present"
printf 'IPV4_ADDR=%s\n' "$ipv4_addr"
printf 'PORT_CHECK=%s\n' "$port_check_first"
printf 'PORT_OWNER=%s\n' "$port_owner"
printf 'OUTBOUND_HTTPS=%s\n' "$outbound_https"
EOF
)"

remote_os_id="$(printf '%s\n' "$remote_facts" | sed -n 's/^OS_ID=//p' | sed -n '1p')"
remote_os_version="$(printf '%s\n' "$remote_facts" | sed -n 's/^OS_VERSION=//p' | sed -n '1p')"
remote_arch="$(printf '%s\n' "$remote_facts" | sed -n 's/^ARCH=//p' | sed -n '1p')"
remote_pkg_mgr="$(printf '%s\n' "$remote_facts" | sed -n 's/^PKG_MGR=//p' | sed -n '1p')"
remote_systemd="$(printf '%s\n' "$remote_facts" | sed -n 's/^SYSTEMD=//p' | sed -n '1p')"
remote_xray_present="$(printf '%s\n' "$remote_facts" | sed -n 's/^XRAY_PRESENT=//p' | sed -n '1p')"
remote_ipv4_addr="$(printf '%s\n' "$remote_facts" | sed -n 's/^IPV4_ADDR=//p' | sed -n '1p')"
remote_port_check="$(printf '%s\n' "$remote_facts" | sed -n 's/^PORT_CHECK=//p' | sed -n '1p')"
remote_port_owner="$(printf '%s\n' "$remote_facts" | sed -n 's/^PORT_OWNER=//p' | sed -n '1p')"
remote_outbound_https="$(printf '%s\n' "$remote_facts" | sed -n 's/^OUTBOUND_HTTPS=//p' | sed -n '1p')"

if [[ "$remote_os_id" != "$VPS_OS_ID" ]]; then
  echo "Unsupported VPS OS for profile $VPS_PROFILE: expected $VPS_OS_ID, got ${remote_os_id:-unknown}" >&2
  exit 1
fi

if [[ "${remote_os_version:-}" != "$VPS_OS_VERSION_PREFIX"* ]]; then
  echo "Unsupported VPS OS version for profile $VPS_PROFILE: expected ${VPS_OS_VERSION_PREFIX}*, got ${remote_os_version:-unknown}" >&2
  exit 1
fi

if [[ "$remote_pkg_mgr" != "$VPS_REQUIRED_PKG_MGR" ]]; then
  echo "Unsupported package manager for profile $VPS_PROFILE: expected $VPS_REQUIRED_PKG_MGR, got ${remote_pkg_mgr:-unknown}" >&2
  exit 1
fi

if [[ "$VPS_REQUIRES_SYSTEMD" == "1" && "$remote_systemd" != "1" ]]; then
  echo "Profile $VPS_PROFILE requires systemd on the VPS." >&2
  exit 1
fi

if ! printf '%s' "$remote_arch" | grep -Eq "$VPS_SUPPORTED_ARCH_REGEX"; then
  echo "Unsupported VPS architecture for profile $VPS_PROFILE: got ${remote_arch:-unknown}, expected ${VPS_SUPPORTED_ARCH_REGEX}" >&2
  exit 1
fi

if [[ -z "$remote_ipv4_addr" ]]; then
  echo "VPS has no global IPv4 address. This stack requires IPv4 (redsocks/iptables are IPv4-only)." >&2
  exit 1
fi

if [[ -n "$remote_port_check" && "$remote_port_owner" != "xray" ]]; then
  echo "Port $XRAY_PORT is already in use on VPS: $remote_port_check" >&2
  exit 1
fi

vps_bundled_archive=''
if [[ "$remote_xray_present" != "1" && "$remote_outbound_https" != "1" ]]; then
  # VPS has no Xray and cannot download from GitHub — try bundled binary
  case "$remote_arch" in
    x86_64|amd64)
      vps_bundled_archive="$VPS_PROFILE_DIR/packages/${VPS_XRAY_ARCHIVE_X64:-Xray-linux-64.zip}"
      ;;
    aarch64|arm64)
      vps_bundled_archive="$VPS_PROFILE_DIR/packages/${VPS_XRAY_ARCHIVE_ARM64:-Xray-linux-arm64-v8a.zip}"
      [ -f "$vps_bundled_archive" ] || vps_bundled_archive="$ROOT_DIR/routers/gl-mt3000-glinet/packages/${VPS_XRAY_ARCHIVE_ARM64:-Xray-linux-arm64-v8a.zip}"
      ;;
  esac
  if [[ -z "$vps_bundled_archive" || ! -f "$vps_bundled_archive" ]]; then
    echo "VPS has no Xray and cannot reach GitHub. No bundled binary found for arch ${remote_arch:-unknown}." >&2
    exit 1
  fi
  echo "VPS has no internet; will upload bundled Xray binary."
fi

if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
  echo "VPS preflight passed for profile $VPS_PROFILE on $VPS_HOST"
  exit 0
fi

if [[ -n "$vps_bundled_archive" ]]; then
  # Verify local archive integrity before uploading
  expected_sha=''
  case "$remote_arch" in
    x86_64|amd64) expected_sha="${VPS_XRAY_ARCHIVE_X64_SHA256:-}" ;;
  esac
  if [[ -n "$expected_sha" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      local_sha="$(sha256sum "$vps_bundled_archive" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      local_sha="$(shasum -a 256 "$vps_bundled_archive" | awk '{print $1}')"
    else
      echo "WARNING: No sha256sum or shasum available; skipping archive integrity check." >&2
      local_sha="$expected_sha"
    fi
    if [[ "$local_sha" != "$expected_sha" ]]; then
      echo "Bundled VPS Xray archive SHA-256 mismatch: expected $expected_sha, got $local_sha" >&2
      exit 1
    fi
  fi
  echo "Uploading bundled Xray binary to VPS..."
  vps_ssh 'cat > /tmp/xray-bundled.zip' < "$vps_bundled_archive"
fi

vps_ssh 'cat > /tmp/codex-router-vps-config.json && chmod 600 /tmp/codex-router-vps-config.json' < "$rendered_config"
vps_ssh 'cat > /tmp/codex-router-meta.env && chmod 600 /tmp/codex-router-meta.env' < "$rendered_meta"
vps_ssh 'cat > /tmp/install-vps.remote.sh && chmod 755 /tmp/install-vps.remote.sh' < "$rendered_install"
vps_ssh 'sh /tmp/install-vps.remote.sh'

vps_ssh "\
EXPECTED_UUID=$(shell_quote "$XRAY_UUID") \
EXPECTED_PRIVATE_KEY=$(shell_quote "$XRAY_PRIVATE_KEY") \
EXPECTED_SHORT_ID=$(shell_quote "$XRAY_SHORT_ID") \
EXPECTED_SERVER_NAME=$(shell_quote "$XRAY_SERVER_NAME") \
EXPECTED_PORT=$(shell_quote "$XRAY_PORT") \
EXPECTED_SERVICE=$(shell_quote "$VPS_XRAY_SERVICE") \
REMOTE_META_PATH=$(shell_quote "$VPS_REMOTE_META_PATH") \
REMOTE_CONFIG_PATH=$(shell_quote "$VPS_XRAY_CONFIG_PATH") \
sh -s" <<'EOF'
service_state="$(systemctl is-active "$EXPECTED_SERVICE" 2>/dev/null || true)"
[ "$service_state" = 'active' ] || {
  echo "VPS Xray service is not active: ${service_state:-unknown}" >&2
  exit 1
}

ss -ltnp 2>/dev/null | grep -q ":${EXPECTED_PORT} " || {
  echo "VPS Xray is not listening on port ${EXPECTED_PORT}." >&2
  exit 1
}

[ -f "$REMOTE_META_PATH" ] || {
  echo "Managed meta file is missing on VPS: $REMOTE_META_PATH" >&2
  exit 1
}

meta_uuid="$(sed -n 's/^XRAY_UUID=//p' "$REMOTE_META_PATH" | sed -n '1p')"
meta_private_key="$(sed -n 's/^XRAY_PRIVATE_KEY=//p' "$REMOTE_META_PATH" | sed -n '1p')"
meta_short_id="$(sed -n 's/^XRAY_SHORT_ID=//p' "$REMOTE_META_PATH" | sed -n '1p')"
meta_server_name="$(sed -n 's/^XRAY_SERVER_NAME=//p' "$REMOTE_META_PATH" | sed -n '1p')"
[ "$meta_uuid" = "$EXPECTED_UUID" ] || {
  echo "Managed meta UUID mismatch on VPS." >&2
  exit 1
}
[ "$meta_private_key" = "$EXPECTED_PRIVATE_KEY" ] || {
  echo "Managed meta private key mismatch on VPS." >&2
  exit 1
}
[ "$meta_short_id" = "$EXPECTED_SHORT_ID" ] || {
  echo "Managed meta short ID mismatch on VPS." >&2
  exit 1
}
[ "$meta_server_name" = "$EXPECTED_SERVER_NAME" ] || {
  echo "Managed meta server name mismatch on VPS." >&2
  exit 1
}

python3 - <<'PY'
import json
import os
import sys

cfg = json.load(open(os.environ["REMOTE_CONFIG_PATH"], "r", encoding="utf-8"))
inbound = (cfg.get("inbounds") or [{}])[0]
client = ((inbound.get("settings") or {}).get("clients") or [{}])[0]
reality = (inbound.get("streamSettings") or {}).get("realitySettings") or {}
short_ids = reality.get("shortIds") or []
server_names = reality.get("serverNames") or []

def fail(msg: str) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(1)

if str(inbound.get("port", "")) != os.environ["EXPECTED_PORT"]:
    fail("VPS config port mismatch.")
if str(client.get("id", "")) != os.environ["EXPECTED_UUID"]:
    fail("VPS config UUID mismatch.")
if str(reality.get("privateKey", "")) != os.environ["EXPECTED_PRIVATE_KEY"]:
    fail("VPS config private key mismatch.")
if (short_ids[0] if short_ids else "") != os.environ["EXPECTED_SHORT_ID"]:
    fail("VPS config short ID mismatch.")
if (server_names[0] if server_names else "") != os.environ["EXPECTED_SERVER_NAME"]:
    fail("VPS config server name mismatch.")
PY
EOF

echo "Deployed Xray server config to $VPS_HOST using VPS profile $VPS_PROFILE"

# Pull the VPS-side public certificate down to tmp/ so subsequent router
# installs can pin it against the same VPS without operator action. The
# private key stays on the VPS — we only fetch the cert.
vps_cert_local="$ROOT_DIR/tmp/vps-server.crt"
mkdir -p "$(dirname "$vps_cert_local")"
if vps_ssh "cat $(shell_quote "$VPS_TLS_CERT_PATH") 2>/dev/null" > "$vps_cert_local.new" 2>/dev/null && [[ -s "$vps_cert_local.new" ]]; then
  mv "$vps_cert_local.new" "$vps_cert_local"
  echo "Fetched VPS TLS cert to $vps_cert_local"
else
  rm -f "$vps_cert_local.new"
fi
