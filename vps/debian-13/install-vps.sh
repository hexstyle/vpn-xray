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
  VPS_XRAY_BINARY VPS_XRAY_CONFIG_DIR VPS_XRAY_CONFIG_PATH VPS_XRAY_LOG_DIR VPS_XRAY_SERVICE \
  VPS_OS_ID VPS_OS_VERSION_PREFIX VPS_REQUIRED_PKG_MGR VPS_REQUIRES_SYSTEMD VPS_SUPPORTED_ARCH_REGEX

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

remote_facts="$(
  ssh "$VPS_SSH" 'sh -s' <<'EOF'
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
printf 'OS_ID=%s\n' "$os_id"
printf 'OS_VERSION=%s\n' "$os_version"
printf 'ARCH=%s\n' "$arch"
printf 'PKG_MGR=%s\n' "$pkg_mgr"
printf 'SYSTEMD=%s\n' "$systemd"
EOF
)"

remote_os_id="$(printf '%s\n' "$remote_facts" | sed -n 's/^OS_ID=//p' | sed -n '1p')"
remote_os_version="$(printf '%s\n' "$remote_facts" | sed -n 's/^OS_VERSION=//p' | sed -n '1p')"
remote_arch="$(printf '%s\n' "$remote_facts" | sed -n 's/^ARCH=//p' | sed -n '1p')"
remote_pkg_mgr="$(printf '%s\n' "$remote_facts" | sed -n 's/^PKG_MGR=//p' | sed -n '1p')"
remote_systemd="$(printf '%s\n' "$remote_facts" | sed -n 's/^SYSTEMD=//p' | sed -n '1p')"

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

ssh "$VPS_SSH" 'cat > /tmp/codex-router-vps-config.json && chmod 600 /tmp/codex-router-vps-config.json' < "$rendered_config"
ssh "$VPS_SSH" 'cat > /tmp/codex-router-meta.env && chmod 600 /tmp/codex-router-meta.env' < "$rendered_meta"
ssh "$VPS_SSH" 'cat > /tmp/install-vps.remote.sh && chmod 755 /tmp/install-vps.remote.sh' < "$rendered_install"
ssh "$VPS_SSH" 'sh /tmp/install-vps.remote.sh'

echo "Deployed Xray server config to $VPS_HOST using VPS profile $VPS_PROFILE"
