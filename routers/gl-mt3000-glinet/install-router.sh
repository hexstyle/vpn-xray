#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/common/lib/env.sh"

ENV_FILE="${ENV_FILE:-$(default_install_env_file "$ROOT_DIR")}"
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

ROUTER_SSH="${ROUTER_SSH:-root@${ROUTER_HOST:-}}"
ROUTER_HOST="${ROUTER_HOST:-$(host_from_ssh_target "$ROUTER_SSH")}"
ROUTER_LAN_IP="${ROUTER_LAN_IP:-$ROUTER_HOST}"

RULES_REPO_FETCH_URL="${RULES_REPO_FETCH_URL:-}"
RULES_REPO_PUSH_URL="${RULES_REPO_PUSH_URL:-}"
RULES_DEVICE_ID="${RULES_DEVICE_ID:-gl-router}"

require_vars \
  ROUTER_SSH \
  ROUTER_HOST \
  ROUTER_EXPECTED_MODEL \
  ROUTER_REQUIRED_COMMANDS \
  ROUTER_REQUIRES_DNSMASQ_IPSET \
  XRAY_CORE_ARCHIVE \
  XRAY_CORE_URL \
  XRAY_CORE_ARCHIVE_SHA256 \
  XRAY_CORE_BINARY_SHA256 \
  REDSOCKS_PACKAGE \
  REDSOCKS_URL \
  REDSOCKS_SHA256 \
  LIBEVENT_PACKAGE \
  LIBEVENT_URL \
  LIBEVENT_SHA256 \
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
  ssh "$ROUTER_SSH" ROUTER_REQUIRED_COMMANDS="$ROUTER_REQUIRED_COMMANDS" 'sh -s' <<'EOF'
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

if [[ "${ISOLATE_WIFI_LAN_ONLY:-0}" == "1" && "$ROUTER_HOST" == "$ROUTER_LAN_IP" ]]; then
  echo "Warning: ROUTER_HOST matches ROUTER_LAN_IP while ISOLATE_WIFI_LAN_ONLY=1." >&2
  echo "Deploy may remove the wired LAN port from br-lan and drop the current management path." >&2
fi

tmpdir="$(mktemp -d)"
cache_dir="$ROOT_DIR/artifacts"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

archive="$tmpdir/$XRAY_CORE_ARCHIVE"
cached_archive="$cache_dir/$XRAY_CORE_ARCHIVE"
extract_dir="$tmpdir/extract"
binary="$extract_dir/xray"
libevent_pkg="$cache_dir/$LIBEVENT_PACKAGE"
redsocks_pkg="$cache_dir/$REDSOCKS_PACKAGE"
vps_bundle_tar="$tmpdir/vps-bundles.tar"
vps_bundle_root="$tmpdir/router-vps-bundles"

mkdir -p "$cache_dir"
if [[ -f "$cached_archive" ]]; then
  cp "$cached_archive" "$archive"
else
  curl --http1.1 --retry 3 --retry-delay 1 -fL --max-time 180 -o "$archive" "$XRAY_CORE_URL"
fi

archive_sha="$(python3 - <<'PY' "$archive"
import hashlib, pathlib, sys
p = pathlib.Path(sys.argv[1])
print(hashlib.sha256(p.read_bytes()).hexdigest())
PY
)"
if [[ "$archive_sha" != "$XRAY_CORE_ARCHIVE_SHA256" ]]; then
  curl --http1.1 --retry 3 --retry-delay 1 -fL --max-time 180 -o "$archive" "$XRAY_CORE_URL"
  archive_sha="$(python3 - <<'PY' "$archive"
import hashlib, pathlib, sys
p = pathlib.Path(sys.argv[1])
print(hashlib.sha256(p.read_bytes()).hexdigest())
PY
)"
  if [[ "$archive_sha" != "$XRAY_CORE_ARCHIVE_SHA256" ]]; then
    echo "Archive sha256 mismatch: $archive_sha" >&2
    exit 1
  fi
fi

cp "$archive" "$cached_archive"
mkdir -p "$extract_dir"
unzip -oq "$archive" -d "$extract_dir"

binary_sha="$(python3 - <<'PY' "$binary"
import hashlib, pathlib, sys
p = pathlib.Path(sys.argv[1])
print(hashlib.sha256(p.read_bytes()).hexdigest())
PY
)"
if [[ "$binary_sha" != "$XRAY_CORE_BINARY_SHA256" ]]; then
  echo "Binary sha256 mismatch: $binary_sha" >&2
  exit 1
fi

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

json_cfg="$tmpdir/codex-xray.json"
redsocks_cfg="$tmpdir/redsocks.conf"
router_rules_cfg="$tmpdir/router-rules.config"
render_template "$ROUTER_PROFILE_DIR/files/codex-xray.json.template" "$json_cfg"
render_template "$ROUTER_PROFILE_DIR/files/redsocks.conf.template" "$redsocks_cfg"
render_template "$ROUTER_COMMON_DIR/files/router-rules.config.template" "$router_rules_cfg"

mkdir -p "$vps_bundle_root/vps"
for profile_dir in "$ROOT_DIR"/vps/*; do
  [[ -d "$profile_dir" ]] || continue
  [[ -f "$profile_dir/profile.env" ]] || continue
  profile_name="$(basename "$profile_dir")"
  mkdir -p "$vps_bundle_root/vps/$profile_name"
  cp "$profile_dir/profile.env" "$vps_bundle_root/vps/$profile_name/profile.env"
  if [[ -f "$profile_dir/README.md" ]]; then
    cp "$profile_dir/README.md" "$vps_bundle_root/vps/$profile_name/README.md"
  fi
  if [[ -d "$profile_dir/files" ]]; then
    mkdir -p "$vps_bundle_root/vps/$profile_name/files"
    cp -R "$profile_dir/files/." "$vps_bundle_root/vps/$profile_name/files/"
  fi
done
tar -C "$vps_bundle_root" -cf "$vps_bundle_tar" vps

fetch_pkg() {
  local url="$1"
  local path="$2"
  local expected="$3"
  if [[ ! -f "$path" ]]; then
    curl --http1.1 --retry 3 --retry-delay 1 -fL --max-time 180 -o "$path" "$url"
  fi
  local got
  got="$(python3 - <<'PY' "$path"
import hashlib, pathlib, sys
p = pathlib.Path(sys.argv[1])
print(hashlib.sha256(p.read_bytes()).hexdigest())
PY
)"
  if [[ "$got" != "$expected" ]]; then
    rm -f "$path"
    curl --http1.1 --retry 3 --retry-delay 1 -fL --max-time 180 -o "$path" "$url"
    got="$(python3 - <<'PY' "$path"
import hashlib, pathlib, sys
p = pathlib.Path(sys.argv[1])
print(hashlib.sha256(p.read_bytes()).hexdigest())
PY
)"
    [[ "$got" == "$expected" ]] || {
      echo "Package sha256 mismatch for $path: $got" >&2
      exit 1
    }
  fi
}

fetch_pkg "$LIBEVENT_URL" "$libevent_pkg" "$LIBEVENT_SHA256"
fetch_pkg "$REDSOCKS_URL" "$redsocks_pkg" "$REDSOCKS_SHA256"

ssh "$ROUTER_SSH" '
  /etc/init.d/xray-switch-watchdog stop >/dev/null 2>&1 || true
  /etc/init.d/router-rules-sync stop >/dev/null 2>&1 || true
  /etc/init.d/codex-transproxy stop >/dev/null 2>&1 || true
  /etc/init.d/codex-xray stop >/dev/null 2>&1 || true
  killall codex-xray-core 2>/dev/null || true
  killall git nslookup dig curl 2>/dev/null || true
  for pid in $(ps w | awk '\''$5=="/bin/sh" && $6=="/usr/bin/router-rules" {print $1}'\''); do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf /root/xray-staging /usr/share/vpn-xray 2>/dev/null || true
  rm -f /usr/bin/xray /usr/local/bin/sing-box /usr/local/bin/sing-box-1.12.22 /usr/local/bin/sing-box-1.8.0 /usr/local/bin/sing-box-xray 2>/dev/null || true
  mkdir -p /usr/local/bin /etc/xray /var/log/xray /etc/router-rules/generated /etc/router-rules/ssh /usr/share/vpn-xray
'
ssh "$ROUTER_SSH" "cat > /tmp/$LIBEVENT_PACKAGE" < "$libevent_pkg"
ssh "$ROUTER_SSH" "cat > /tmp/$REDSOCKS_PACKAGE" < "$redsocks_pkg"
ssh "$ROUTER_SSH" 'opkg install /tmp/'"$LIBEVENT_PACKAGE"' /tmp/'"$REDSOCKS_PACKAGE"' >/dev/null 2>&1 || true; command -v redsocks >/dev/null'
ssh "$ROUTER_SSH" 'opkg install git git-http curl ca-bundle ca-certificates >/dev/null 2>&1 || true'
ssh "$ROUTER_SSH" 'cat > /usr/local/bin/codex-xray-core && chmod 755 /usr/local/bin/codex-xray-core' < "$binary"
ssh "$ROUTER_SSH" 'cat > /etc/xray/codex-xray.json && chmod 600 /etc/xray/codex-xray.json' < "$json_cfg"
ssh "$ROUTER_SSH" 'cat > /etc/redsocks.conf && chmod 600 /etc/redsocks.conf' < "$redsocks_cfg"
ssh "$ROUTER_SSH" 'cat > /etc/config/router_rules && chmod 600 /etc/config/router_rules' < "$router_rules_cfg"
ssh "$ROUTER_SSH" 'cat > /etc/init.d/codex-xray && chmod 755 /etc/init.d/codex-xray' < "$ROUTER_PROFILE_DIR/files/codex-xray.init"
ssh "$ROUTER_SSH" 'cat > /etc/init.d/codex-transproxy && chmod 755 /etc/init.d/codex-transproxy' < "$ROUTER_PROFILE_DIR/files/codex-transproxy.init"
ssh "$ROUTER_SSH" 'cat > /etc/init.d/xray-switch-watchdog && chmod 755 /etc/init.d/xray-switch-watchdog' < "$ROUTER_PROFILE_DIR/files/xray-switch-watchdog.init"
ssh "$ROUTER_SSH" 'cat > /etc/init.d/router-rules-sync && chmod 755 /etc/init.d/router-rules-sync' < "$ROUTER_COMMON_DIR/files/router-rules-sync.init"
ssh "$ROUTER_SSH" 'cat > /etc/gl-switch.d/xray.sh && chmod 755 /etc/gl-switch.d/xray.sh' < "$ROUTER_PROFILE_DIR/files/gl-switch-xray.sh"
ssh "$ROUTER_SSH" 'cat > /usr/bin/router-rules && chmod 755 /usr/bin/router-rules' < "$ROUTER_COMMON_DIR/files/router-rules"
ssh "$ROUTER_SSH" 'cat > /www/xray.html && chmod 644 /www/xray.html' < "$ROUTER_PROFILE_DIR/files/xray.html"
ssh "$ROUTER_SSH" 'cat > /www/cgi-bin/xray-admin && chmod 755 /www/cgi-bin/xray-admin' < "$ROUTER_PROFILE_DIR/files/xray-admin.cgi"
ssh "$ROUTER_SSH" 'cat > /www/cgi-bin/xray-vps && chmod 755 /www/cgi-bin/xray-vps' < "$ROUTER_PROFILE_DIR/files/xray-vps.cgi"
ssh "$ROUTER_SSH" 'cat > /www/cgi-bin/xray-rules && chmod 755 /www/cgi-bin/xray-rules' < "$ROUTER_PROFILE_DIR/files/xray-rules.cgi"
ssh "$ROUTER_SSH" 'cat > /tmp/vpn-xray-vps.tar' < "$vps_bundle_tar"
ssh "$ROUTER_SSH" 'mkdir -p /usr/share/vpn-xray && tar -xf /tmp/vpn-xray-vps.tar -C /usr/share/vpn-xray && rm -f /tmp/vpn-xray-vps.tar'

ssh "$ROUTER_SSH" "
  killall sing-box 2>/dev/null || true
  killall sing-box-1.8.0 2>/dev/null || true
  killall sing-box-1.12.22 2>/dev/null || true
  killall xray-test 2>/dev/null || true
  killall codex-xray-core 2>/dev/null || true
  pids=\$(netstat -ltnp 2>/dev/null | awk '/:18081 / {print \$7}' | cut -d/ -f1 | sort -u)
  [ -n \"\$pids\" ] && kill \$pids 2>/dev/null || true
  uci -q delete firewall.codex_wan_socks_test
  uci -q delete firewall.codex_wan_httpd_test
  uci -q delete firewall.codex_wan_http_proxy_test
  uci -q delete firewall.codex_wan_http_proxy_prod
  uci -q set firewall.codex_wan_http_proxy_prod=rule
  uci set firewall.codex_wan_http_proxy_prod.name='codex_wan_http_proxy_prod'
  uci set firewall.codex_wan_http_proxy_prod.src='wan'
  uci set firewall.codex_wan_http_proxy_prod.family='ipv4'
  uci set firewall.codex_wan_http_proxy_prod.proto='tcp'
  uci set firewall.codex_wan_http_proxy_prod.src_ip='$HOME_SUBNET'
  uci set firewall.codex_wan_http_proxy_prod.dest_port='$PROXY_PORT'
  uci set firewall.codex_wan_http_proxy_prod.target='ACCEPT'
  uci commit firewall
  uci -q delete dhcp.lan.dhcp_option
  uci set dhcp.lan.ra='disabled'
  uci set dhcp.lan.dhcpv6='disabled'
  uci set dhcp.lan.ndp='disabled'
  uci -q delete dhcp.@dnsmasq[0].noresolv
  uci set dhcp.@dnsmasq[0].resolvfile='/tmp/resolv.conf.d/resolv.conf.auto'
  uci -q delete dhcp.@dnsmasq[0].server
  uci commit dhcp
  uci set network.lan.ip6assign='0'
  uci set stubby.global.enabled='0'
  uci commit stubby
  uci set switch-button.@main[0].func='xray'
  uci -q delete switch-button.@main[0].sub_func
  uci commit switch-button
"

if [[ "${ISOLATE_WIFI_LAN_ONLY:-0}" == "1" ]]; then
  ssh "$ROUTER_SSH" "
    uci del_list network.@device[0].ports='eth1' 2>/dev/null || true
    uci commit network
  "
else
  ssh "$ROUTER_SSH" "
    uci add_list network.@device[0].ports='eth1' 2>/dev/null || true
    uci commit network
  "
fi

ssh "$ROUTER_SSH" "
  /etc/init.d/firewall reload >/dev/null 2>&1
  /etc/init.d/stubby stop >/dev/null 2>&1 || true
  /etc/init.d/stubby disable >/dev/null 2>&1 || true
  /etc/init.d/dnsmasq restart >/dev/null 2>&1
  /etc/init.d/odhcpd restart >/dev/null 2>&1 || true
  /etc/init.d/codex-xray stop >/dev/null 2>&1 || true
  /etc/init.d/codex-xray disable >/dev/null 2>&1 || true
  /etc/init.d/codex-transproxy stop >/dev/null 2>&1 || true
  /etc/init.d/codex-transproxy disable >/dev/null 2>&1 || true
  /etc/init.d/xray-switch-watchdog stop >/dev/null 2>&1 || true
  /etc/init.d/xray-switch-watchdog enable >/dev/null 2>&1 || true
  /etc/init.d/xray-switch-watchdog start >/dev/null 2>&1 || true
  /etc/init.d/router-rules-sync stop >/dev/null 2>&1 || true
  /etc/init.d/router-rules-sync enable >/dev/null 2>&1 || true
  /usr/bin/router-rules ensure-git-key >/dev/null 2>&1 || true
  repo=/etc/router-rules/repo
  export GIT_SSH_COMMAND='ssh -i /etc/router-rules/ssh/routerRules_ed25519 -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no'
  if [ -d \"\$repo/.git\" ]; then
    git -C \"\$repo\" fetch origin main >/dev/null 2>&1 || true
    git -C \"\$repo\" reset --hard origin/main >/dev/null 2>&1 || true
    git -C \"\$repo\" clean -fd >/dev/null 2>&1 || true
  fi
  /usr/bin/router-rules sync-apply-xray >/dev/null 2>&1 || true
  /etc/init.d/router-rules-sync start >/dev/null 2>&1 || true
  /etc/init.d/gl_switch_button_check start >/dev/null 2>&1 || true
"

if [[ "$NETWORK_RELOAD" == "1" ]]; then
  ssh "$ROUTER_SSH" '/etc/init.d/network reload >/dev/null 2>&1 || true'
fi

echo "Deployed to $ROUTER_HOST"
echo "LAN proxy:  http://$ROUTER_LAN_IP:$PROXY_PORT"
echo "WAN proxy:  http://$ROUTER_HOST:$PROXY_PORT"
echo "Web UI:     https://$ROUTER_HOST/xray.html"
echo "Rules key:  ssh $ROUTER_SSH 'cat /etc/router-rules/ssh/routerRules_ed25519.pub'"
