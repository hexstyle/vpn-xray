#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
INSTALL_PLATFORM="$ROOT/routers/gl-mt3000-glinet/install-platform.sh"
INSTALL_ROUTER="$ROOT/routers/gl-mt3000-glinet/install-router.sh"
TRANSPROXY="$ROOT/routers/gl-mt3000-glinet/files/codex-transproxy.init"
XRAY_INIT="$ROOT/routers/gl-mt3000-glinet/files/codex-xray.init"
WATCHDOG="$ROOT/routers/gl-mt3000-glinet/files/xray-switch-watchdog.init"
UPLINK_HOTPLUG="$ROOT/routers/gl-mt3000-glinet/files/codex-xray-uplink.hotplug"
ROUTER_RULES="$ROOT/routers/common/files/router-rules"
AGENTS_FILE="$ROOT/AGENTS.md"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q 'configure_lan_bridge_ports()' "$INSTALL_PLATFORM" \
	|| fail "install-platform must centralize LAN bridge mutation behind a dedicated guard"

grep -q 'normalize_lan_bridge_ports()' "$INSTALL_PLATFORM" \
	|| fail "install-platform must normalize duplicate LAN bridge ports after repeated deploys"

grep -q 'Preserving existing LAN bridge port topology' "$INSTALL_PLATFORM" \
	|| fail "install-platform must preserve existing LAN bridge topology by default"

grep -q 'stabilize_wireless_bssid()' "$INSTALL_PLATFORM" \
	|| fail "install-platform must stabilize Wi-Fi BSSIDs for management-plane reliability"

grep -q 'random_bssid=0' "$INSTALL_PLATFORM" \
	|| fail "install-platform must disable random_bssid so AP identities stay stable across reloads and reboots"

grep -q "uci set dhcp.@dnsmasq\\[0\\].filter_aaaa='1'" "$INSTALL_PLATFORM" \
	|| fail "install-platform must suppress AAAA answers because this stack is IPv4-only"

if grep -q "uci add_list network.@device\\[0\\].ports='eth1'" "$INSTALL_PLATFORM"; then
	fail "install-platform must not unconditionally add eth1 to the LAN bridge"
fi

grep -q 'Router is reachable again over SSH after network reload' "$INSTALL_ROUTER" \
	|| fail "install-router must confirm the router comes back after a network reload"

grep -q 'codex-xray-uplink.hotplug' "$INSTALL_PLATFORM" \
	|| fail "install-platform must deploy the Xray uplink hotplug guard"

grep -q '/etc/hotplug.d/iface/95-codex-xray-uplink' "$INSTALL_PLATFORM" \
	|| fail "install-platform must install the Xray uplink hotplug guard into iface hotplug hooks"

grep -q 'lan_device' "$TRANSPROXY" \
	|| fail "codex-transproxy must resolve the LAN device dynamically"

if grep -q '\-i br-lan' "$TRANSPROXY"; then
	fail "codex-transproxy must not hardcode br-lan in firewall rules"
fi

# Full-mode UDP is routed THROUGH Xray via TPROXY, not blanket-rejected
# (commit 13c3954 / DIAGNOSTIC-TREE 4.4). The old blanket UDP REJECT broke
# QUIC/WebRTC/etc. So the contract is now: DNS :53 returns early and all
# other UDP is TPROXY'd into the Xray UDP inbound. Assert the new shape
# and assert the old REJECT is GONE.
grep -q -- '-p udp --dport 53 -j RETURN' "$TRANSPROXY" \
	|| fail "codex-transproxy CODEX_TPROXY must RETURN DNS :53 before the blanket UDP TPROXY (DNS stays on local dnsmasq)"

grep -q -- '-j TPROXY --tproxy-mark' "$TRANSPROXY" \
	|| fail "codex-transproxy must TPROXY non-DNS UDP into the Xray inbound (not reject it)"

if grep -q 'iptables -I FORWARD 1 -i "\$lan_if" -p udp ! --dport 53 -j REJECT' "$TRANSPROXY"; then
	fail "codex-transproxy must NOT blanket-reject forwarded non-DNS UDP — that breaks QUIC/WebRTC; UDP goes through TPROXY now (commit 13c3954)"
fi

grep -q 'ip6tables -I FORWARD 1 -i "\$lan_if" -j REJECT' "$TRANSPROXY" \
	|| fail "codex-transproxy must still reject forwarded IPv6 while the IPv4-only Xray path is active"

grep -q 'lan_device' "$ROUTER_RULES" \
	|| fail "router-rules must resolve the LAN device dynamically"

if grep -q 'dev br-lan' "$ROUTER_RULES"; then
	fail "router-rules must not hardcode br-lan for LAN CIDR detection"
fi

grep -q 'refresh_egress_route()' "$XRAY_INIT" \
	|| fail "codex-xray must expose an egress-route refresh hook for uplink failover"

grep -q 'best_uplink()' "$XRAY_INIT" \
	|| fail "codex-xray must expose the selected uplink for failover verification"

grep -q 'ip -4 route replace "\$addr/32"' "$XRAY_INIT" \
	|| fail "codex-xray must pin VPS host routes to the preferred uplink"

grep -q '/etc/init.d/codex-xray refresh_egress_route' "$UPLINK_HOTPLUG" \
	|| fail "iface hotplug must refresh Xray egress routing after uplink changes"

grep -q 'refresh_egress_route' "$WATCHDOG" \
	|| fail "watchdog must refresh Xray egress routing as a fallback after uplink changes"

grep -q 'Management-plane reachability is part of router verification' "$AGENTS_FILE" \
	|| fail "AGENTS.md must require management-plane reachability checks"

grep -q 'Wi-Fi client reconnect after reboot or radio reload is part of management-plane verification' "$AGENTS_FILE" \
	|| fail "AGENTS.md must require Wi-Fi reconnect checks after reboot or wireless reloads"

grep -q 'verify that a client can reconnect to the saved SSID/BSSID without manual password re-entry' "$AGENTS_FILE" \
	|| fail "AGENTS.md must require Wi-Fi-only reconnect checks without manual re-auth"

grep -q 'eventual recovery alone is not sufficient' "$AGENTS_FILE" \
	|| fail "AGENTS.md must require timing-based reboot recovery verification"

grep -q 'Do not enable or re-enable `wireless.\*.random_bssid`' "$AGENTS_FILE" \
	|| fail "AGENTS.md must forbid random_bssid churn on management APs by default"

grep -q 'Do not disable `codex-xray` or `codex-transproxy` init services as a workaround for boot ordering' "$AGENTS_FILE" \
	|| fail "AGENTS.md must forbid disabling boot-time Xray services to mask ordering bugs"

grep -q 'Prefer restoring from the last resolved snapshot first, then refreshing in the background' "$AGENTS_FILE" \
	|| fail "AGENTS.md must require cached selective restore before background refresh"

grep -q 'verify that `ip route get <VPS IP>` follows the active uplink' "$AGENTS_FILE" \
	|| fail "AGENTS.md must require VPS route checks during uplink failover"

grep -q 'Treat same-radio repeater uplink plus client AP service as a management-plane risk' "$AGENTS_FILE" \
	|| fail "AGENTS.md must call out same-radio repeater/AP instability risk"

printf 'ok\n'
