#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/common/lib/env.sh"

ENV_FILE="${ENV_FILE:-$(default_install_env_file "$ROOT_DIR")}"
load_env_file "$ENV_FILE" "$(default_install_env_example "$ROOT_DIR")"
load_profile_defaults "$(router_profile_dir "$ROOT_DIR" "${ROUTER_PROFILE:-gl-mt3000-glinet}")/profile.env"

ROUTER_SSH="${ROUTER_SSH:-root@${ROUTER_HOST:-}}"
ROUTER_HOST="${ROUTER_HOST:-$(host_from_ssh_target "$ROUTER_SSH")}"
PROXY_PORT="${PROXY_PORT:-1083}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
ensure_installer_ssh_state "$ROOT_DIR"
INSTALLER_KNOWN_HOSTS="$(installer_known_hosts_file "$ROOT_DIR")"
ROUTER_SSH_OPTS=(
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS"
)

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
  echo "Checks: the router should be reachable, SSH must accept the current admin password, and the installer uses its own host-key cache at $INSTALLER_KNOWN_HOSTS." >&2
  rm -f "$err"
  return "$rc"
}

require_vars ROUTER_SSH ROUTER_HOST PROXY_PORT
reject_placeholder_vars ROUTER_SSH ROUTER_HOST

proxy="http://$ROUTER_HOST:$PROXY_PORT"
warning_count=0

warn_verify() {
  printf 'WARNING: %s\n' "$1" >&2
  warning_count=$((warning_count + 1))
}

config_ready="$(router_ssh '[ -f /etc/xray/codex-xray.ready ] && [ -s /etc/xray/codex-xray.json ] && echo 1 || echo 0' | sed -n '1p')"
if [[ "$config_ready" != "1" ]]; then
  echo "The vpn-xray platform is installed, but this router does not have an active VPS client profile yet." >&2
  echo "Open https://$ROUTER_HOST/xray.html, add VPS SSH details, click 'Sync Router + VPS', and then rerun verify." >&2
  exit 21
fi

switch_state="$(router_ssh ". /lib/functions/gl_util.sh; get_switch_button_status 2>/dev/null || echo unknown" | sed -n '1p')"

if [[ "$switch_state" != "on" ]]; then
  echo "Router hardware switch is '$switch_state'." >&2
  echo "Turn the physical switch to ON before running verify, then rerun this script." >&2
  exit 20
fi

echo "== waiting for proxy path =="
proxy_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if router_ssh "pid=\$(cat /var/run/codex-xray.pid 2>/dev/null || true); [ -n \"\$pid\" ] && kill -0 \"\$pid\" 2>/dev/null && netstat -ltnp 2>/dev/null | grep -q ':$PROXY_PORT '" >/dev/null 2>&1; then
    proxy_ready=1
    break
  fi
  sleep 1
done

if [[ "$proxy_ready" != "1" ]]; then
  echo "Timed out waiting for the router proxy path to start listening on port $PROXY_PORT." >&2
  exit 1
fi

echo "== remote service status =="
router_ssh "PROXY_PORT='$PROXY_PORT' sh -s" <<'EOF'
. /lib/functions/gl_util.sh 2>/dev/null || true

lan_dev="$(uci -q get network.lan.device 2>/dev/null || uci -q get network.lan.ifname 2>/dev/null || true)"
case "$lan_dev" in
  ''|*' '*)
    lan_dev='br-lan'
    ;;
esac

wwan_dev="$(ifstatus wwan 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null | sed -n '1p')"
[ -n "$wwan_dev" ] || wwan_dev="$(ifstatus wwan 2>/dev/null | jsonfilter -e '@.device' 2>/dev/null | sed -n '1p')"
selected_repeater_section="$(uci -q show repeater 2>/dev/null | sed -n "s/^\(repeater\.[^.]*\)\.selected='1'$/\1/p" | sed -n '1p')"
selected_repeater_ssid=''
if [ -n "$selected_repeater_section" ]; then
  selected_repeater_ssid="$(uci -q get "${selected_repeater_section}.ssid" 2>/dev/null || true)"
fi

same_radio_risk='none-detected'
case "$wwan_dev" in
  apcli0)
    same_radio_risk='2.4GHz uplink shares radio with 2.4GHz AP clients; reassociation can drop management clients'
    ;;
  apclix0)
    same_radio_risk='5GHz uplink shares radio with 5GHz AP clients; reassociation can drop management clients'
    ;;
esac

server_addr="$(jsonfilter -i /etc/xray/codex-xray.json -e '@.outbounds[0].settings.vnext[0].address' 2>/dev/null | sed -n '1p')"
server_target=''
case "$server_addr" in
  '')
    ;;
  *[!0-9.]*)
    if command -v nslookup >/dev/null 2>&1; then
      server_target="$(nslookup "$server_addr" 2>/dev/null | sed -n 's/^Address [0-9]*: //p' | grep -E '^[0-9]+(\.[0-9]+){3}$' | sed -n '1p')"
    fi
    ;;
  *)
    server_target="$server_addr"
    ;;
esac

echo "switch-button=$(get_switch_button_status 2>/dev/null || echo unknown)"
echo "xray-mode=$(uci -q get router_rules.global.xray_mode 2>/dev/null || echo unknown)"
echo "lan-device=$lan_dev"
echo "lan-ipv4=$(ip -4 addr show dev "$lan_dev" 2>/dev/null | awk '/inet / {print $2; exit}')"
echo "default-route=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $0}')"
echo "wwan-device=${wwan_dev:-none}"
echo "repeater-selected-ssid=${selected_repeater_ssid:-none}"
echo "same-radio-uplink-risk=$same_radio_risk"
[ -n "$server_target" ] && echo "vps-route=$(ip -4 route get "$server_target" 2>/dev/null | sed -n '1p')"
/etc/init.d/codex-xray best_uplink 2>/dev/null || true

pid="$(cat /var/run/codex-xray.pid 2>/dev/null || true)"
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  echo "codex-xray running pid=$pid"
else
  echo "codex-xray stopped"
fi

redpid="$(cat /var/run/redsocks.pid 2>/dev/null || true)"
if [ -n "$redpid" ] && kill -0 "$redpid" 2>/dev/null; then
  echo "redsocks running pid=$redpid"
else
  echo "redsocks stopped"
fi

/etc/init.d/codex-xray enabled || true
/etc/init.d/codex-transproxy enabled || true
uci -q get switch-button.@main[0].func || true
sysctl net.mptcp.enabled
netstat -ltnp 2>/dev/null | grep ":$PROXY_PORT" || true
echo '-- nat chain rules --'
iptables -t nat -S CODEX_TRANSPROXY 2>/dev/null || true
echo '-- nat counters --'
iptables -t nat -vnL CODEX_TRANSPROXY 2>/dev/null || true
echo '-- local xray mss guard --'
iptables -t mangle -S CODEX_XRAY_LOCAL 2>/dev/null || true
iptables -t mangle -vnL CODEX_XRAY_LOCAL 2>/dev/null || true
echo '-- prerouting counters --'
iptables -t nat -vnL PREROUTING 2>/dev/null | grep -A2 -B2 'CODEX_TRANSPROXY' || true
echo '-- forward counters --'
iptables -vnL FORWARD 2>/dev/null | grep "$lan_dev" || true
EOF

echo
echo "== https browsing through proxy =="
curl -I -m 25 -x "$proxy" https://www.google.com || true

echo
echo "== router-local transparent socks path =="
router_ssh "curl -I -m 25 --socks5-hostname 127.0.0.1:1084 https://example.com" || true

echo
echo "== router-local transparent socks egress ip =="
router_ssh "curl -m 25 --socks5-hostname 127.0.0.1:1084 https://ipinfo.io/ip" || true
echo

echo
echo "== egress ip through proxy =="
curl -m 25 -x "$proxy" https://ifconfig.me/ip || true
echo

echo "== api reachability through proxy (advisory) =="
if ! curl -I -m 25 -x "$proxy" https://api.openai.com/v1/models; then
  warn_verify "api.openai.com did not answer through the proxy."
  warn_verify "This does not prove the transport is broken: OpenAI may reject the current VPS IP or region."
  warn_verify "If Google and the egress IP checks above succeeded, the proxy path itself is likely healthy."
  warn_verify "Immediate options: keep using the stack, switch to another saved VPS in the router UI, or reprovision a new VPS profile."
fi

echo
echo "== secondary egress ip check through proxy =="
curl -m 25 -x "$proxy" https://ipinfo.io/ip || true
echo

echo "== coverage notes =="
echo "Covered here: router control-plane reachability, router-local HTTP proxy smoke, router-local transparent SOCKS smoke, runtime processes, firewall/NAT counters, and the router-local route chosen for the VPS path."
echo "Not covered automatically here: LAN-client traffic checks for VPN off/full/selective, Wi-Fi-only management reachability after unplugging Ethernet, and same-radio AP/uplink reassociation behavior on the active client band."
echo "Run those from a device behind the router when validating routing changes."

if [[ "$warning_count" -gt 0 ]]; then
  echo
  echo "Verification completed with $warning_count warning(s)." >&2
  echo "Deployment succeeded, but one or more advisory checks need attention." >&2
else
  echo
  echo "Verification passed."
fi
