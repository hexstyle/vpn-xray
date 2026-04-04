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
ROUTER_SSH_OPTS=(
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o StrictHostKeyChecking=accept-new
)

router_ssh() {
  ssh "${ROUTER_SSH_OPTS[@]}" "$ROUTER_SSH" "$@"
}

require_vars ROUTER_SSH ROUTER_HOST PROXY_PORT
reject_placeholder_vars ROUTER_SSH ROUTER_HOST

proxy="http://$ROUTER_HOST:$PROXY_PORT"
warning_count=0

warn_verify() {
  printf 'WARNING: %s\n' "$1" >&2
  warning_count=$((warning_count + 1))
}

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
router_ssh ". /lib/functions/gl_util.sh; echo switch-button=\$(get_switch_button_status 2>/dev/null || echo unknown); pid=\$(cat /var/run/codex-xray.pid 2>/dev/null || true); if [ -n \"\$pid\" ] && kill -0 \"\$pid\" 2>/dev/null; then echo codex-xray running pid=\$pid; else echo codex-xray stopped; fi; redpid=\$(cat /var/run/redsocks.pid 2>/dev/null || true); if [ -n \"\$redpid\" ] && kill -0 \"\$redpid\" 2>/dev/null; then echo redsocks running pid=\$redpid; else echo redsocks stopped; fi; /etc/init.d/codex-xray enabled || true; /etc/init.d/codex-transproxy enabled || true; uci -q get switch-button.@main[0].func || true; sysctl net.mptcp.enabled; netstat -ltnp 2>/dev/null | grep ':$PROXY_PORT' || true; iptables -t nat -S CODEX_TRANSPROXY 2>/dev/null || true; iptables -t nat -S PREROUTING | grep CODEX_TRANSPROXY || true; iptables -S FORWARD | grep 'br-lan.*udp.*REJECT' || true"

echo
echo "== https browsing through proxy =="
curl -I -m 25 -x "$proxy" https://www.google.com

echo
echo "== egress ip through proxy =="
curl -m 25 -x "$proxy" https://ifconfig.me/ip
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
curl -m 25 -x "$proxy" https://ipinfo.io/ip
echo

if [[ "$warning_count" -gt 0 ]]; then
  echo
  echo "Verification completed with $warning_count warning(s)." >&2
  echo "Deployment succeeded, but one or more advisory checks need attention." >&2
else
  echo
  echo "Verification passed."
fi
