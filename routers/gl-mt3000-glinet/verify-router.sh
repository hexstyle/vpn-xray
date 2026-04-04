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

require_vars ROUTER_SSH ROUTER_HOST PROXY_PORT
reject_placeholder_vars ROUTER_SSH ROUTER_HOST

proxy="http://$ROUTER_HOST:$PROXY_PORT"
switch_state="$(ssh "$ROUTER_SSH" ". /lib/functions/gl_util.sh; get_switch_button_status 2>/dev/null || echo unknown" | sed -n '1p')"

if [[ "$switch_state" != "on" ]]; then
  echo "Router hardware switch is '$switch_state'." >&2
  echo "Turn the physical switch to ON before running verify, then rerun this script." >&2
  exit 1
fi

echo "== remote service status =="
ssh "$ROUTER_SSH" ". /lib/functions/gl_util.sh; echo switch-button=\$(get_switch_button_status 2>/dev/null || echo unknown); pid=\$(cat /var/run/codex-xray.pid 2>/dev/null || true); if [ -n \"\$pid\" ] && kill -0 \"\$pid\" 2>/dev/null; then echo codex-xray running pid=\$pid; else echo codex-xray stopped; fi; redpid=\$(cat /var/run/redsocks.pid 2>/dev/null || true); if [ -n \"\$redpid\" ] && kill -0 \"\$redpid\" 2>/dev/null; then echo redsocks running pid=\$redpid; else echo redsocks stopped; fi; /etc/init.d/codex-xray enabled || true; /etc/init.d/codex-transproxy enabled || true; uci -q get switch-button.@main[0].func || true; sysctl net.mptcp.enabled; netstat -ltnp 2>/dev/null | grep ':$PROXY_PORT' || true; iptables -t nat -S CODEX_TRANSPROXY 2>/dev/null || true; iptables -t nat -S PREROUTING | grep CODEX_TRANSPROXY || true; iptables -S FORWARD | grep 'br-lan.*udp.*REJECT' || true"

echo
echo "== https browsing through proxy =="
curl -I -m 25 -x "$proxy" https://www.google.com

echo
echo "== egress ip through proxy =="
curl -m 25 -x "$proxy" https://ifconfig.me/ip
echo

echo "== api reachability through proxy =="
curl -I -m 25 -x "$proxy" https://api.openai.com/v1/models

echo
echo "== secondary egress ip check through proxy =="
curl -m 25 -x "$proxy" https://ipinfo.io/ip
echo
