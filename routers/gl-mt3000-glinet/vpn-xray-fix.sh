#!/bin/sh
# vpn-xray-fix.sh — recover the router->VPS egress path after a WAN change or a
# stale pinned route ("dial VPS:443: no route to host"). Run ON THE ROUTER.
#
# SAFE & IDEMPOTENT. It does NOT: unload kernel modules (never touches
# mtk_warp_proxy), reload the whole network (never bounces the WAN), or change
# any persistent config. Re-runnable as many times as you like.
#
# How to run (from your Mac, on the router's LAN — no router internet needed):
#   ssh root@192.168.8.1 'sh -s' < vpn-xray-fix.sh
# or copy it over and run on the router:
#   sh /tmp/vpn-xray-fix.sh
#
# Exit codes: 0 = tunnel restored, 1 = route fixed but egress still not via VPS,
#             2 = upstream internet is dead (nothing a script can fix).

PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

CONFIG="/etc/xray/codex-xray.json"
UPLINK_STATE="/var/run/codex-xray.uplink"
ROUTE_STATE="/var/run/codex-xray.server-routes"
PROXY_PORT="1083"

say(){ printf '%s\n' "$*"; }
hr(){ printf -- '------------------------------------------------------------\n'; }
ping_ok(){ ping -c1 -W2 "$1" >/dev/null 2>&1; }

# Pin every VPS IP via the path that ACTUALLY reaches the internet. This is the
# authoritative route fix and is always run LAST so nothing overwrites it.
pin_vps_routes(){
  for ip in $vps_ips; do
    if [ -n "$egr_gw" ]; then
      ip -4 route replace "$ip/32" via "$egr_gw" dev "$egr_dev" >/dev/null 2>&1 \
        || ip -4 route replace "$ip/32" dev "$egr_dev" >/dev/null 2>&1
    else
      ip -4 route replace "$ip/32" dev "$egr_dev" >/dev/null 2>&1
    fi
  done
  ip -4 route flush cache >/dev/null 2>&1
}

egress_via_proxy(){
  curl -ksS -m 12 -x "http://127.0.0.1:${PROXY_PORT}" https://api.ipify.org 2>/dev/null
}

hr; say "VPN-XRAY route recovery"; hr

# ---- resolve the VPS IP(s) from the live config -----------------------------
[ -s "$CONFIG" ] || { say "ERROR: $CONFIG missing — xray not installed here."; exit 1; }
vps_host="$(jsonfilter -i "$CONFIG" -e '@.outbounds[0].settings.vnext[0].address' 2>/dev/null | sed -n '1p')"
[ -n "$vps_host" ] || { say "ERROR: could not read VPS address from config."; exit 1; }
case "$vps_host" in
  *[!0-9.]*) vps_ips="$(nslookup "$vps_host" 2>/dev/null | sed -n 's/^Address [0-9]*: //p' | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u)";;
  *)         vps_ips="$vps_host";;
esac
[ -n "$vps_ips" ] || vps_ips="$vps_host"
vps_first="$(echo $vps_ips | awk '{print $1}')"
say "VPS host : $vps_host"
say "VPS IP(s): $(echo $vps_ips | tr '\n' ' ')"

# ---- 1. diagnose ------------------------------------------------------------
say "Default route: $(ip route show default 2>/dev/null | sed -n '1p' | sed 's/^/  /;s/^  $/<none>/')"

# The path that ACTUALLY reaches the internet (empirical, not config-guessed).
egr="$(ip route get 1.1.1.1 2>/dev/null | sed -n '1p')"
egr_gw="$(printf '%s' "$egr"  | sed -n 's/.*via \([0-9.][0-9.]*\).*/\1/p')"
egr_dev="$(printf '%s' "$egr" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
say "Working egress: dev=${egr_dev:-?} gw=${egr_gw:-none}"

up_net=no; ping_ok 1.1.1.1 && up_net=yes
say "Internet (1.1.1.1) reachable: $up_net"
say "Route to VPS now: $(ip route get "$vps_first" 2>/dev/null | sed -n '1p')"

# ---- 2. classify: dead upstream vs fixable route ----------------------------
if [ "$up_net" = no ]; then
  hr
  say "DIAGNOSIS: the router's WAN cannot reach the internet at all."
  say "This is your UPSTREAM connection (hotspot / cable / repeater), NOT the"
  say "tunnel — no script can fix a dead uplink. Reconnect the router's WAN,"
  say "then re-run this script. (State cleared so it re-pins the moment the"
  say "uplink returns.)"
  rm -f "$UPLINK_STATE" "$ROUTE_STATE" 2>/dev/null
  [ -x /etc/init.d/codex-xray ] && /etc/init.d/codex-xray refresh_egress_route >/dev/null 2>&1
  exit 2
fi
say "-> Internet works; the VPS host-route is the suspect. Fixing it."; hr

# ---- 3. fix the egress route ------------------------------------------------
# 3a. drop stale /32 host-routes to the VPS (tracked ones + any direct ones)
if [ -f "$ROUTE_STATE" ]; then
  sed -n 's/^target=//p' "$ROUTE_STATE" 2>/dev/null | while IFS= read -r t; do
    [ -n "$t" ] && ip -4 route del "$t" >/dev/null 2>&1
  done
fi
for ip in $vps_ips; do
  ip -4 route del "$ip/32" >/dev/null 2>&1
  ip -4 route del "$ip"    >/dev/null 2>&1
done
# 3b. make the service forget its cached uplink signature so it re-pins fresh
rm -f "$UPLINK_STATE" "$ROUTE_STATE" 2>/dev/null
# 3c. let the service reconcile its state first (may pin its own way)...
[ -x /etc/init.d/codex-xray ] && /etc/init.d/codex-xray refresh_egress_route >/dev/null 2>&1
# 3d. ...then OUR empirical pin wins as the final, authoritative route.
pin_vps_routes
say "Re-pinned VPS route -> $(ip route get "$vps_first" 2>/dev/null | sed -n '1p')"

# ---- 4. re-assert transparent path if it is down ----------------------------
rs_up=no; nat_up=no
netstat -ltn 2>/dev/null | grep -q ":12345 " && rs_up=yes
iptables -t nat -S PREROUTING 2>/dev/null | grep -q CODEX_TRANSPROXY && nat_up=yes
if [ "$rs_up" = no ] || [ "$nat_up" = no ]; then
  say "Transparent path down (redsocks=$rs_up nat=$nat_up) — re-asserting..."
  [ -x /etc/init.d/codex-transproxy ] && /etc/init.d/codex-transproxy restart >/dev/null 2>&1
  [ -x /etc/gl-switch.d/xray.sh ] && /etc/gl-switch.d/xray.sh on >/dev/null 2>&1
  pin_vps_routes   # codex-transproxy touches nat; keep our route authoritative
  sleep 2
else
  say "Transparent path already up (redsocks + nat)."
fi

# ---- 5. verify (xray auto-reconnects over the fixed route) ------------------
hr; say "Verification (xray reconnects on its own over the fixed route):"
egress_ip=""
i=1
while [ "$i" -le 6 ]; do
  egress_ip="$(egress_via_proxy)"
  [ -n "$egress_ip" ] && break
  say "  waiting for xray to reconnect... ($i/6)"; sleep 3; i=$((i+1))
done

# If still nothing, ONE clean xray restart as a last resort, then re-pin + recheck.
ok=no
for ip in $vps_ips; do [ "$egress_ip" = "$ip" ] && ok=yes; done
if [ "$ok" = no ]; then
  say "  still not through; restarting xray once and re-checking..."
  [ -x /etc/init.d/codex-xray ] && /etc/init.d/codex-xray restart >/dev/null 2>&1
  sleep 3
  pin_vps_routes   # restart re-pins its own way; ours wins again
  i=1
  while [ "$i" -le 5 ]; do
    egress_ip="$(egress_via_proxy)"
    [ -n "$egress_ip" ] && break
    sleep 3; i=$((i+1))
  done
  ok=no
  for ip in $vps_ips; do [ "$egress_ip" = "$ip" ] && ok=yes; done
fi

say "  egress IP via proxy: ${egress_ip:-<none>}"
hr
if [ "$ok" = yes ]; then
  say "SUCCESS: traffic now leaves through the VPS ($egress_ip). Tunnel restored."
  exit 0
fi
say "NOT FULLY RESTORED (egress='${egress_ip:-none}')."
say " - empty egress   -> upstream is likely blocking the VPS on :443 (try another uplink)."
say " - your local IP  -> the GL.iNet VPN switch is OFF; turn it ON, then re-run."
exit 1
