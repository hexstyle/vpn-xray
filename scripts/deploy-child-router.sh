#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/required-env.sh"
ENV_FILE="${ENV_FILE:-$(default_router_env_file "$ROOT_DIR")}"
ENV_ROUTER_HOST="${ROUTER_HOST:-}"
ENV_ROUTER_LAN_IP="${ROUTER_LAN_IP:-}"
NETWORK_RELOAD="${NETWORK_RELOAD:-0}"

load_env_file "$ENV_FILE" "$ROOT_DIR/config/router.env.example"

if [[ -n "$ENV_ROUTER_HOST" ]]; then
  ROUTER_HOST="$ENV_ROUTER_HOST"
fi

if [[ -n "$ENV_ROUTER_LAN_IP" ]]; then
  ROUTER_LAN_IP="$ENV_ROUTER_LAN_IP"
fi

require_vars \
  ROUTER_HOST \
  ROUTER_LAN_IP \
  HOME_SUBNET \
  PROXY_PORT \
  LOCAL_SOCKS_PORT \
  REDSOCKS_PORT \
  PUBLIC_DNS_1 \
  PUBLIC_DNS_2 \
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
  XRAY_SHORT_ID \
  RULES_REPO_FETCH_URL \
  RULES_REPO_PUSH_URL \
  RULES_REPO_BRANCH \
  RULES_GIT_USER_NAME \
  RULES_GIT_USER_EMAIL \
  RULES_DNS_RESOLVER \
  RULES_DEVICE_ID \
  RULES_ENABLE_PUSH \
  RULES_CONSUMER \
  RULES_SYNC_INTERVAL \
  XRAY_RULES_MODE

reject_placeholder_vars \
  ROUTER_HOST \
  ROUTER_LAN_IP \
  HOME_SUBNET \
  XRAY_SERVER \
  XRAY_UUID \
  XRAY_SERVER_NAME \
  XRAY_PUBLIC_KEY \
  XRAY_SHORT_ID \
  RULES_REPO_FETCH_URL \
  RULES_REPO_PUSH_URL \
  RULES_DEVICE_ID

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

json_cfg="$tmpdir/codex-xray.json"
python3 - <<'PY' "$ROOT_DIR/router-files/codex-xray.json.template" "$json_cfg"
import os, pathlib, re, sys
template = pathlib.Path(sys.argv[1]).read_text()
def repl(match):
    key = match.group(1)
    return os.environ[key]
out = re.sub(r"\$\{([A-Z0-9_]+)\}", repl, template)
pathlib.Path(sys.argv[2]).write_text(out)
PY

redsocks_cfg="$tmpdir/redsocks.conf"
python3 - <<'PY' "$ROOT_DIR/router-files/redsocks.conf.template" "$redsocks_cfg"
import os, pathlib, re, sys
template = pathlib.Path(sys.argv[1]).read_text()
def repl(match):
    key = match.group(1)
    return os.environ[key]
out = re.sub(r"\$\{([A-Z0-9_]+)\}", repl, template)
pathlib.Path(sys.argv[2]).write_text(out)
PY

router_rules_cfg="$tmpdir/router-rules.config"
python3 - <<'PY' "$ROOT_DIR/router-files/router-rules.config.template" "$router_rules_cfg"
import os, pathlib, re, sys
template = pathlib.Path(sys.argv[1]).read_text()
def repl(match):
    key = match.group(1)
    return os.environ[key]
out = re.sub(r"\$\{([A-Z0-9_]+)\}", repl, template)
pathlib.Path(sys.argv[2]).write_text(out)
PY

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

ssh "root@$ROUTER_HOST" '
  /etc/init.d/xray-switch-watchdog stop >/dev/null 2>&1 || true
  /etc/init.d/router-rules-sync stop >/dev/null 2>&1 || true
  /etc/init.d/codex-transproxy stop >/dev/null 2>&1 || true
  /etc/init.d/codex-xray stop >/dev/null 2>&1 || true
  killall codex-xray-core 2>/dev/null || true
  killall git nslookup dig curl 2>/dev/null || true
  for pid in $(ps w | awk '\''$5=="/bin/sh" && $6=="/usr/bin/router-rules" {print $1}'\''); do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf /root/xray-staging 2>/dev/null || true
  rm -f /usr/bin/xray /usr/local/bin/sing-box /usr/local/bin/sing-box-1.12.22 /usr/local/bin/sing-box-1.8.0 /usr/local/bin/sing-box-xray 2>/dev/null || true
  mkdir -p /usr/local/bin /etc/xray /var/log/xray /etc/router-rules/generated /etc/router-rules/ssh
'
ssh "root@$ROUTER_HOST" 'cat > /tmp/'"$LIBEVENT_PACKAGE" < "$libevent_pkg"
ssh "root@$ROUTER_HOST" 'cat > /tmp/'"$REDSOCKS_PACKAGE" < "$redsocks_pkg"
ssh "root@$ROUTER_HOST" 'opkg install /tmp/'"$LIBEVENT_PACKAGE"' /tmp/'"$REDSOCKS_PACKAGE"' >/dev/null 2>&1 || true; command -v redsocks >/dev/null'
ssh "root@$ROUTER_HOST" 'opkg install git git-http curl ca-bundle ca-certificates >/dev/null 2>&1 || true'
ssh "root@$ROUTER_HOST" 'cat > /usr/local/bin/codex-xray-core && chmod 755 /usr/local/bin/codex-xray-core' < "$binary"
ssh "root@$ROUTER_HOST" 'cat > /etc/xray/codex-xray.json && chmod 600 /etc/xray/codex-xray.json' < "$json_cfg"
ssh "root@$ROUTER_HOST" 'cat > /etc/redsocks.conf && chmod 600 /etc/redsocks.conf' < "$redsocks_cfg"
ssh "root@$ROUTER_HOST" 'cat > /etc/config/router_rules && chmod 600 /etc/config/router_rules' < "$router_rules_cfg"
ssh "root@$ROUTER_HOST" 'cat > /etc/init.d/codex-xray && chmod 755 /etc/init.d/codex-xray' < "$ROOT_DIR/router-files/codex-xray.init"
ssh "root@$ROUTER_HOST" 'cat > /etc/init.d/codex-transproxy && chmod 755 /etc/init.d/codex-transproxy' < "$ROOT_DIR/router-files/codex-transproxy.init"
ssh "root@$ROUTER_HOST" 'cat > /etc/init.d/xray-switch-watchdog && chmod 755 /etc/init.d/xray-switch-watchdog' < "$ROOT_DIR/router-files/xray-switch-watchdog.init"
ssh "root@$ROUTER_HOST" 'cat > /etc/init.d/router-rules-sync && chmod 755 /etc/init.d/router-rules-sync' < "$ROOT_DIR/router-files/router-rules-sync.init"
ssh "root@$ROUTER_HOST" 'cat > /etc/gl-switch.d/xray.sh && chmod 755 /etc/gl-switch.d/xray.sh' < "$ROOT_DIR/router-files/gl-switch-xray.sh"
ssh "root@$ROUTER_HOST" 'cat > /usr/bin/router-rules && chmod 755 /usr/bin/router-rules' < "$ROOT_DIR/router-files/router-rules"
ssh "root@$ROUTER_HOST" 'cat > /www/xray.html && chmod 644 /www/xray.html' < "$ROOT_DIR/router-files/xray.html"
ssh "root@$ROUTER_HOST" 'cat > /www/cgi-bin/xray-admin && chmod 755 /www/cgi-bin/xray-admin' < "$ROOT_DIR/router-files/xray-admin.cgi"
ssh "root@$ROUTER_HOST" 'cat > /www/cgi-bin/xray-vps && chmod 755 /www/cgi-bin/xray-vps' < "$ROOT_DIR/router-files/xray-vps.cgi"
ssh "root@$ROUTER_HOST" 'cat > /www/cgi-bin/xray-rules && chmod 755 /www/cgi-bin/xray-rules' < "$ROOT_DIR/router-files/xray-rules.cgi"

ssh "root@$ROUTER_HOST" "
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
  ssh "root@$ROUTER_HOST" "
    uci del_list network.@device[0].ports='eth1' 2>/dev/null || true
    uci commit network
  "
else
  ssh "root@$ROUTER_HOST" "
    uci add_list network.@device[0].ports='eth1' 2>/dev/null || true
    uci commit network
  "
fi

ssh "root@$ROUTER_HOST" "
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
  ssh "root@$ROUTER_HOST" '/etc/init.d/network reload >/dev/null 2>&1 || true'
fi

echo "Deployed to $ROUTER_HOST"
echo "LAN proxy:  http://$ROUTER_LAN_IP:$PROXY_PORT"
echo "WAN proxy:  http://$ROUTER_HOST:$PROXY_PORT"
echo "Web UI:     https://$ROUTER_HOST/xray.html"
echo "Rules key:  ssh root@$ROUTER_HOST 'cat /etc/router-rules/ssh/routerRules_ed25519.pub'"
