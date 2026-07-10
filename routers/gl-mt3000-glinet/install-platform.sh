#!/bin/sh

set -eu

SELF_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)"
SOURCE_DIR="$ROOT_DIR"
PREFLIGHT_ONLY='0'
RESUME_MODE='0'

while [ "$#" -gt 0 ]; do
	case "$1" in
		--source-dir)
			[ "$#" -ge 2 ] || {
				echo "Missing value for --source-dir" >&2
				exit 1
			}
			SOURCE_DIR="$2"
			shift 2
			;;
		--preflight)
			PREFLIGHT_ONLY='1'
			shift
			;;
		--resume)
			RESUME_MODE='1'
			shift
			;;
		*)
			echo "Usage: $0 [--source-dir <repo-root>] [--preflight] [--resume]" >&2
			exit 1
			;;
	esac
done

PROFILE_DIR="$SOURCE_DIR/routers/gl-mt3000-glinet"
COMMON_DIR="$SOURCE_DIR/routers/common"
VPS_DIR="$SOURCE_DIR/vps"
CONFIG_READY_FILE='/etc/xray/codex-xray.ready'
ROUTER_CONFIG='/etc/xray/codex-xray.json'
ROUTER_BIN='/usr/local/bin/codex-xray-core'
PLATFORM_DIR='/etc/vpn-xray'
PLATFORM_ENV="${PLATFORM_DIR}/platform.env"
WORK_DIR="/tmp/vpn-xray-platform.$$"
DOWNLOAD_DIR="${WORK_DIR}/downloads"
EXTRACT_DIR="${WORK_DIR}/extract"
OPKG_UPDATE_OK='0'
BUNDLED_PAYLOAD_DIR="${PROFILE_DIR}/packages"
OPENWRT_FALLBACK_RELEASE='21.02.3'

[ -f "$PROFILE_DIR/profile.env" ] || {
	echo "Missing router profile defaults: $PROFILE_DIR/profile.env" >&2
	exit 1
}

# shellcheck disable=SC1090
. "$PROFILE_DIR/profile.env"

: "${IPKG_INSTROOT:=}"
export IPKG_INSTROOT

mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_DIR"

cleanup() {
	rm -rf "$WORK_DIR"
}

trap cleanup EXIT INT TERM

INSTALL_PROGRESS_FILE="/tmp/vpn-xray-install-progress"
FILES_CHANGED=0

mark_done() { printf '%s\n' "$1" >> "$INSTALL_PROGRESS_FILE"; }
is_done() { [ -f "$INSTALL_PROGRESS_FILE" ] && grep -Fxq "$1" "$INSTALL_PROGRESS_FILE" 2>/dev/null; }


# Function groups extracted to sibling libs (AGENTS.md 500-line rule).
# They define functions only and share this scope; sourced here after the
# constants/env above and before install_platform runs below.
. "$SELF_DIR/install-platform-lib-a.sh"
. "$SELF_DIR/install-platform-lib-b.sh"
install_platform() {
	local archive binary libevent_pkg redsocks_pkg redsocks_rendered router_rules_rendered existing_ready switch_state

	if [ "$RESUME_MODE" != '1' ]; then
		rm -f "$INSTALL_PROGRESS_FILE"
	fi

	info "Running router platform preflight..."
	preflight

	if [ "$PREFLIGHT_ONLY" = '1' ]; then
		info "Router platform preflight passed."
		return 0
	fi

	if ! is_done packages; then
		info "Preparing router package manager..."
		install_bundled_opkg_packages || true
		# Air-gap default: rely on the bundled payload only. `opkg update`
		# pulls package indexes from the configured feeds (typically
		# fw.gl-inet.com) and counts as workstation-side network from the
		# operator's vantage point, so gate it behind the same explicit flag
		# as direct package downloads.
		if [ "${VPN_XRAY_ALLOW_NETWORK_PKG:-0}" = "1" ]; then
			if opkg update >/tmp/vpn-xray-opkg-update.log 2>&1; then
				OPKG_UPDATE_OK='1'
			else
				warn "opkg update did not fully complete. Continuing with already-present commands and package lists."
				warn "See /tmp/vpn-xray-opkg-update.log on the router for feed errors."
			fi
		else
			info "Skipping opkg update (air-gap default). Set VPN_XRAY_ALLOW_NETWORK_PKG=1 to refresh feeds."
		fi
		ensure_pkg_installed ca-bundle
		ensure_pkg_installed ca-certificates
		ensure_cmd_via_package curl curl
		ensure_cmd_via_package unzip unzip
		ensure_vps_ssh_dependencies
		try_pkg_install git "Git-backed shared rules sync" || true
		try_pkg_install git-http "Git-backed shared rules sync" || true
		ensure_git_sync_dependencies
		ensure_python3_runtime
		mark_done packages
	fi

	archive="$DOWNLOAD_DIR/$XRAY_CORE_ARCHIVE"
	stage_bundled_or_download "$XRAY_CORE_ARCHIVE" "$archive" "$XRAY_CORE_URL" "$XRAY_CORE_ARCHIVE_SHA256"
	unzip -oq "$archive" -d "$EXTRACT_DIR"
	binary="$EXTRACT_DIR/xray"
	[ -f "$binary" ] || fail "Xray archive unpacked, but the xray binary was not found."
	[ "$(sha256_file "$binary")" = "$XRAY_CORE_BINARY_SHA256" ] || fail "Xray binary sha256 mismatch after unpack."

	libevent_pkg="$DOWNLOAD_DIR/$LIBEVENT_PACKAGE"
	redsocks_pkg="$DOWNLOAD_DIR/$REDSOCKS_PACKAGE"
	stage_bundled_or_download "$LIBEVENT_PACKAGE" "$libevent_pkg" "$LIBEVENT_URL" "$LIBEVENT_SHA256"
	stage_bundled_or_download "$REDSOCKS_PACKAGE" "$redsocks_pkg" "$REDSOCKS_URL" "$REDSOCKS_SHA256"

	if ! is_done deps; then
		info "Stopping vpn-xray runtime before file updates..."
		/etc/init.d/xray-switch-watchdog stop >/dev/null 2>&1 || true
		/etc/init.d/router-rules-sync stop >/dev/null 2>&1 || true
		/etc/init.d/codex-transproxy stop >/dev/null 2>&1 || true
		/etc/init.d/codex-xray stop >/dev/null 2>&1 || true
		killall codex-xray-core 2>/dev/null || true

		info "Installing router-side dependencies..."
		opkg install "$libevent_pkg" "$redsocks_pkg" >/dev/null 2>&1 || fail "Could not install the router-side redsocks dependencies."
		command -v redsocks >/dev/null 2>&1 || fail "redsocks is still unavailable after package install."
		mark_done deps
	fi

	mkdir -p /usr/local/bin /etc/xray /var/log/xray /etc/router-rules/generated /etc/router-rules/ssh /usr/share/vpn-xray /www/cgi-bin /etc/gl-switch.d "$PLATFORM_DIR"
	if [ -f "$ROUTER_BIN" ]; then
		local old_h new_h
		old_h="$(sha256_file "$ROUTER_BIN")"
		new_h="$(sha256_file "$binary")"
		if [ "$old_h" != "$new_h" ]; then
			info "Xray binary changed; stopping runtime before replacement..."
			/etc/init.d/codex-xray stop >/dev/null 2>&1 || true
			killall codex-xray-core 2>/dev/null || true
		fi
	fi
	copy_if_changed "$binary" "$ROUTER_BIN"
	chmod 755 "$ROUTER_BIN"

	redsocks_rendered="$WORK_DIR/redsocks.conf"
	router_rules_rendered="$WORK_DIR/router-rules.config"
	render_redsocks_conf "$redsocks_rendered"
	render_router_rules_conf "$router_rules_rendered"
	cp "$redsocks_rendered" /etc/redsocks.conf
	chmod 600 /etc/redsocks.conf
	if [ ! -f /etc/config/router_rules ]; then
		cp "$router_rules_rendered" /etc/config/router_rules
		chmod 600 /etc/config/router_rules
	fi
	uci -q batch <<EOF
set router_rules.global=global
set router_rules.global.git_sync_enabled='$(effective_router_rules_bool_value git_sync_enabled "${RULES_GIT_SYNC_ENABLED:-}")'
set router_rules.global.repo_fetch_url='$(effective_router_rules_text_value repo_fetch_url "${RULES_REPO_FETCH_URL:-}")'
set router_rules.global.repo_push_url='$(effective_router_rules_text_value repo_push_url "${RULES_REPO_PUSH_URL:-}")'
set router_rules.global.repo_branch='$(effective_router_rules_text_value repo_branch "${RULES_REPO_BRANCH:-main}")'
set router_rules.global.git_auth_mode='$(effective_git_auth_mode)'
set router_rules.global.git_http_username='$(effective_router_rules_text_value git_http_username "${RULES_GIT_HTTP_USERNAME:-}")'
set router_rules.global.git_http_password='$(effective_router_rules_text_value git_http_password "${RULES_GIT_HTTP_PASSWORD:-}")'
set router_rules.global.git_user_name='${RULES_GIT_USER_NAME:-router-rules}'
set router_rules.global.git_user_email='${RULES_GIT_USER_EMAIL:-router-rules@example.invalid}'
set router_rules.global.dns_resolver='${RULES_DNS_RESOLVER:-9.9.9.9 208.67.222.222}'
set router_rules.global.local_device_id='${RULES_DEVICE_ID:-gl-router}'
set router_rules.global.enable_push='$(effective_router_rules_bool_value enable_push "${RULES_ENABLE_PUSH:-0}")'
set router_rules.global.xray_mode='$(effective_xray_rules_mode)'
set router_rules.global.sync_interval='${RULES_SYNC_INTERVAL:-30}'
set router_rules.global.external_source_enabled='$(effective_external_source_enabled)'
set router_rules.global.external_source_url='$(effective_external_source_url)'
set router_rules.global.external_source_interval='$(effective_external_source_interval)'
EOF
	uci commit router_rules
	chmod 600 /etc/config/router_rules
	if [ -n "${RULES_GIT_SSH_PRIVATE_KEY_B64:-}" ] || [ -n "${RULES_GIT_SSH_PRIVATE_KEY:-}" ]; then
		if [ -n "${RULES_GIT_SSH_PRIVATE_KEY_B64:-}" ]; then
			# Decode the b64-encoded private key. Busybox on this router has no
			# `base64` applet, so use python3 (which is already required for the
			# external rules importer) — same dependency, no extra package.
			command -v python3 >/dev/null 2>&1 || fail "python3 is required to decode RULES_GIT_SSH_PRIVATE_KEY_B64."
			if ! printf '%s' "$RULES_GIT_SSH_PRIVATE_KEY_B64" | python3 -c 'import base64, sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read()))' > /etc/router-rules/ssh/routerRules_ed25519 2>/dev/null; then
				fail "Provided RULES_GIT_SSH_PRIVATE_KEY_B64 is invalid."
			fi
		else
			printf '%s\n' "$RULES_GIT_SSH_PRIVATE_KEY" > /etc/router-rules/ssh/routerRules_ed25519
		fi
		chmod 600 /etc/router-rules/ssh/routerRules_ed25519
		if ! ssh-keygen -y -f /etc/router-rules/ssh/routerRules_ed25519 > /etc/router-rules/ssh/routerRules_ed25519.pub 2>/dev/null; then
			fail "Provided RULES_GIT_SSH_PRIVATE_KEY is invalid."
		fi
		chmod 644 /etc/router-rules/ssh/routerRules_ed25519.pub
	fi

	mkdir -p /etc/hotplug.d/iface
	# Pinned VPS cert used by VLESS+WS+TLS outbound (self-signed). Lives
	# next to codex-xray.json so the runtime can verify the upstream pin.
	if [ -f "$PROFILE_DIR/files/server.crt" ]; then
		copy_if_changed "$PROFILE_DIR/files/server.crt" /etc/xray/server.crt
		chmod 644 /etc/xray/server.crt
	fi
	copy_if_changed "$PROFILE_DIR/files/codex-xray.init" /etc/init.d/codex-xray
	copy_if_changed "$PROFILE_DIR/files/codex-transproxy.init" /etc/init.d/codex-transproxy
	copy_if_changed "$PROFILE_DIR/files/codex-xray-uplink.hotplug" /etc/hotplug.d/iface/95-codex-xray-uplink
	copy_if_changed "$PROFILE_DIR/files/xray-switch-watchdog.init" /etc/init.d/xray-switch-watchdog
	copy_if_changed "$PROFILE_DIR/files/xray-health-monitor.init" /etc/init.d/xray-health-monitor
	copy_if_changed "$COMMON_DIR/files/router-rules-sync.init" /etc/init.d/router-rules-sync
	copy_if_changed "$COMMON_DIR/files/lib-common.sh" /usr/share/vpn-xray/lib-common.sh
	copy_if_changed "$COMMON_DIR/files/xray-admin-probe.sh" /usr/share/vpn-xray/xray-admin-probe.sh
	copy_if_changed "$COMMON_DIR/files/xray-admin-status.sh" /usr/share/vpn-xray/xray-admin-status.sh
	copy_if_changed "$COMMON_DIR/files/xray-rules-jobs.sh" /usr/share/vpn-xray/xray-rules-jobs.sh
	copy_if_changed "$COMMON_DIR/files/xray-rules-actions.sh" /usr/share/vpn-xray/xray-rules-actions.sh
	copy_if_changed "$COMMON_DIR/files/xray-rules-scripts.sh" /usr/share/vpn-xray/xray-rules-scripts.sh
	copy_if_changed "$COMMON_DIR/files/xray-vps-profile.sh xray-vps-ssh.sh xray-vps-render.sh xray-vps-inspect.sh xray-vps-actions.sh xray-vps-setup.sh xray-vps-repair.sh" /usr/share/vpn-xray/xray-vps-profile.sh xray-vps-ssh.sh xray-vps-render.sh xray-vps-inspect.sh xray-vps-actions.sh xray-vps-setup.sh xray-vps-repair.sh
	copy_if_changed "$COMMON_DIR/files/router-rules-external.py" /usr/share/vpn-xray/router-rules-external.py
	copy_if_changed "$COMMON_DIR/files/router-rules-config.sh" /usr/share/vpn-xray/router-rules-config.sh
	copy_if_changed "$COMMON_DIR/files/router-rules-git.sh" /usr/share/vpn-xray/router-rules-git.sh
	copy_if_changed "$COMMON_DIR/files/router-rules-repo.sh" /usr/share/vpn-xray/router-rules-repo.sh
	copy_if_changed "$COMMON_DIR/files/router-rules-remote.sh" /usr/share/vpn-xray/router-rules-remote.sh
	copy_if_changed "$COMMON_DIR/files/router-rules-rulestree.sh" /usr/share/vpn-xray/router-rules-rulestree.sh
	copy_if_changed "$COMMON_DIR/files/router-rules-external-a.sh" /usr/share/vpn-xray/router-rules-external-a.sh
	copy_if_changed "$COMMON_DIR/files/router-rules-external-b.sh" /usr/share/vpn-xray/router-rules-external-b.sh
	copy_if_changed "$COMMON_DIR/files/router-rules-ipset.sh" /usr/share/vpn-xray/router-rules-ipset.sh
	copy_if_changed "$COMMON_DIR/files/router-rules-apply.sh" /usr/share/vpn-xray/router-rules-apply.sh
	copy_if_changed "$COMMON_DIR/files/router-rules-status.sh" /usr/share/vpn-xray/router-rules-status.sh
	copy_if_changed "$PROFILE_DIR/files/gl-switch-xray.sh" /etc/gl-switch.d/xray.sh
	copy_if_changed "$COMMON_DIR/files/router-rules" /usr/bin/router-rules
	copy_if_changed "$PROFILE_DIR/files/vpn-xray-repin-cert" /usr/bin/vpn-xray-repin-cert
	copy_if_changed "$PROFILE_DIR/files/xray.html" /www/xray.html
	copy_if_changed "$COMMON_DIR/files/xray-base.css" /www/xray-base.css
	copy_if_changed "$COMMON_DIR/files/xray-components.css" /www/xray-components.css
	copy_if_changed "$COMMON_DIR/files/xray-app-1.js" /www/xray-app-1.js
	copy_if_changed "$COMMON_DIR/files/xray-app-2.js" /www/xray-app-2.js
	copy_if_changed "$COMMON_DIR/files/xray-app-3.js" /www/xray-app-3.js
	copy_if_changed "$COMMON_DIR/files/xray-app-4.js" /www/xray-app-4.js
	copy_if_changed "$COMMON_DIR/files/xray-app-5.js" /www/xray-app-5.js
	copy_if_changed "$COMMON_DIR/files/xray-app-6.js" /www/xray-app-6.js
	copy_if_changed "$COMMON_DIR/files/xray-app-7.js" /www/xray-app-7.js
	copy_if_changed "$PROFILE_DIR/files/xray-admin.cgi" /www/cgi-bin/xray-admin
	copy_if_changed "$PROFILE_DIR/files/xray-vps.cgi" /www/cgi-bin/xray-vps
	copy_if_changed "$PROFILE_DIR/files/xray-rules.cgi" /www/cgi-bin/xray-rules
	normalize_installed_text_files \
		/etc/init.d/codex-xray \
		/etc/init.d/codex-transproxy \
		/etc/hotplug.d/iface/95-codex-xray-uplink \
		/etc/init.d/xray-switch-watchdog \
		/etc/init.d/xray-health-monitor \
		/etc/init.d/router-rules-sync \
		/etc/gl-switch.d/xray.sh \
		/usr/bin/router-rules \
		/usr/share/vpn-xray/lib-common.sh \
		/usr/share/vpn-xray/xray-admin-probe.sh \
		/usr/share/vpn-xray/xray-admin-status.sh \
		/usr/share/vpn-xray/xray-rules-jobs.sh \
		/usr/share/vpn-xray/xray-rules-actions.sh \
		/usr/share/vpn-xray/xray-rules-scripts.sh \
		/usr/share/vpn-xray/xray-vps-profile.sh \
		/usr/share/vpn-xray/xray-vps-ssh.sh \
		/usr/share/vpn-xray/xray-vps-render.sh \
		/usr/share/vpn-xray/xray-vps-inspect.sh \
		/usr/share/vpn-xray/xray-vps-actions.sh \
		/usr/share/vpn-xray/xray-vps-setup.sh \
		/usr/share/vpn-xray/xray-vps-repair.sh \
		/usr/share/vpn-xray/router-rules-external.py \
		/usr/share/vpn-xray/router-rules-config.sh \
		/usr/share/vpn-xray/router-rules-git.sh \
		/usr/share/vpn-xray/router-rules-repo.sh \
		/usr/share/vpn-xray/router-rules-remote.sh \
		/usr/share/vpn-xray/router-rules-rulestree.sh \
		/usr/share/vpn-xray/router-rules-external-a.sh \
		/usr/share/vpn-xray/router-rules-external-b.sh \
		/usr/share/vpn-xray/router-rules-ipset.sh \
		/usr/share/vpn-xray/router-rules-apply.sh \
		/usr/share/vpn-xray/router-rules-status.sh \
		/www/cgi-bin/xray-admin \
		/www/cgi-bin/xray-vps \
		/www/cgi-bin/xray-rules \
		/www/xray-base.css \
		/www/xray-components.css \
		/www/xray-app-1.js \
		/www/xray-app-2.js \
		/www/xray-app-3.js \
		/www/xray-app-4.js \
		/www/xray-app-5.js \
		/www/xray-app-6.js \
		/www/xray-app-7.js \
		/www/xray.html
	chmod 755 /etc/init.d/codex-xray /etc/init.d/codex-transproxy /etc/hotplug.d/iface/95-codex-xray-uplink /etc/init.d/xray-switch-watchdog /etc/init.d/xray-health-monitor /etc/init.d/router-rules-sync /etc/gl-switch.d/xray.sh /usr/bin/router-rules /usr/bin/vpn-xray-repin-cert /usr/share/vpn-xray/lib-common.sh /usr/share/vpn-xray/xray-admin-probe.sh /usr/share/vpn-xray/xray-admin-status.sh /usr/share/vpn-xray/xray-rules-jobs.sh /usr/share/vpn-xray/xray-rules-actions.sh /usr/share/vpn-xray/xray-rules-scripts.sh /usr/share/vpn-xray/xray-vps-profile.sh xray-vps-ssh.sh xray-vps-render.sh xray-vps-inspect.sh xray-vps-actions.sh xray-vps-setup.sh xray-vps-repair.sh /usr/share/vpn-xray/router-rules-external.py /usr/share/vpn-xray/router-rules-config.sh /usr/share/vpn-xray/router-rules-git.sh /usr/share/vpn-xray/router-rules-repo.sh /usr/share/vpn-xray/router-rules-remote.sh /usr/share/vpn-xray/router-rules-rulestree.sh /usr/share/vpn-xray/router-rules-external-a.sh /usr/share/vpn-xray/router-rules-external-b.sh /usr/share/vpn-xray/router-rules-ipset.sh /usr/share/vpn-xray/router-rules-apply.sh /usr/share/vpn-xray/router-rules-status.sh /www/cgi-bin/xray-admin /www/cgi-bin/xray-vps /www/cgi-bin/xray-rules
	chmod 644 /www/xray.html /www/xray-base.css /www/xray-components.css /www/xray-app-1.js /www/xray-app-2.js /www/xray-app-3.js /www/xray-app-4.js /www/xray-app-5.js /www/xray-app-6.js /www/xray-app-7.js

	rm -rf /usr/share/vpn-xray/vps
	mkdir -p /usr/share/vpn-xray
	cp -R "$VPS_DIR" /usr/share/vpn-xray/vps

	rm -rf /tmp/router-rules.lock.d /tmp/xray-vps-locks

	info "Applying router integration settings..."
	uci -q delete firewall.codex_wan_http_proxy_prod >/dev/null 2>&1 || true
	uci -q delete firewall.codex_wan_redsocks_drop >/dev/null 2>&1 || true
	uci set firewall.codex_wan_http_proxy_prod=rule
	uci set firewall.codex_wan_http_proxy_prod.name='codex_wan_http_proxy_prod'
	uci set firewall.codex_wan_http_proxy_prod.src='wan'
	uci set firewall.codex_wan_http_proxy_prod.family='ipv4'
	uci set firewall.codex_wan_http_proxy_prod.proto='tcp'
	uci set firewall.codex_wan_http_proxy_prod.src_ip="$HOME_SUBNET"
	uci set firewall.codex_wan_http_proxy_prod.dest_port="$PROXY_PORT"
	uci set firewall.codex_wan_http_proxy_prod.target='ACCEPT'
	uci set firewall.codex_wan_redsocks_drop=rule
	uci set firewall.codex_wan_redsocks_drop.name='codex_wan_redsocks_drop'
	uci set firewall.codex_wan_redsocks_drop.src='wan'
	uci set firewall.codex_wan_redsocks_drop.family='ipv4'
	uci set firewall.codex_wan_redsocks_drop.proto='tcp'
	uci set firewall.codex_wan_redsocks_drop.dest_port="$REDSOCKS_PORT"
	uci set firewall.codex_wan_redsocks_drop.target='DROP'
	uci commit firewall

	uci -q delete dhcp.lan.dhcp_option >/dev/null 2>&1 || true
	uci set dhcp.lan.ra='disabled'
	uci set dhcp.lan.dhcpv6='disabled'
	uci set dhcp.lan.ndp='disabled'
	uci -q delete dhcp.@dnsmasq[0].noresolv >/dev/null 2>&1 || true
	uci set dhcp.@dnsmasq[0].resolvfile='/tmp/resolv.conf.d/resolv.conf.auto'
	uci set dhcp.@dnsmasq[0].filter_aaaa='1'
	# Reset the upstream list then add explicit public resolvers so dnsmasq
	# has working DNS even when the WAN-provided resolv.conf is empty or
	# slow. dnsmasq still consults resolvfile in parallel (noresolv is off).
	uci -q delete dhcp.@dnsmasq[0].server >/dev/null 2>&1 || true
	uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
	uci add_list dhcp.@dnsmasq[0].server='8.8.4.4'
	uci commit dhcp
	uci set network.lan.ip6assign='0'
	uci set stubby.global.enabled='0'
	uci commit network
	uci commit stubby
	uci set switch-button.@main[0].func='xray'
	uci -q delete switch-button.@main[0].sub_func >/dev/null 2>&1 || true
	uci commit switch-button

	configure_lan_bridge_ports
	stabilize_wireless_bssid
	uci commit network
	uci commit wireless

	write_platform_metadata

	# Kernel tuning for stability on a no-swap 512 MB system:
	#  - min_free_kbytes: reserve pages for interrupt handlers and OOM-killer
	#  - softlockup_panic: dump stack to ramoops on soft lockup
	#  - panic: auto-reboot 10s after kernel panic (don't hang forever)
	#  - nf_conntrack_max: headroom so conntrack table doesn't silently drop
	#  - netdev_budget: process more packets per softirq cycle (less spinlock contention)
	mkdir -p /etc/sysctl.d
	cat > /etc/sysctl.d/99-xray-stability.conf <<-'SYSCTL'
	vm.min_free_kbytes=16384
	kernel.softlockup_panic=1
	kernel.panic=10
	net.netfilter.nf_conntrack_max=16384
	net.core.netdev_budget=600
	SYSCTL
	sysctl -w vm.min_free_kbytes=16384 >/dev/null 2>&1 || true
	sysctl -w kernel.softlockup_panic=1 >/dev/null 2>&1 || true
	sysctl -w kernel.panic=10 >/dev/null 2>&1 || true
	sysctl -w net.netfilter.nf_conntrack_max=16384 >/dev/null 2>&1 || true
	sysctl -w net.core.netdev_budget=600 >/dev/null 2>&1 || true

	# Balance NET_RX softirqs across both CPUs.  By default CPU0 handles
	# ~87 % of all RX interrupts, which concentrates spinlock contention
	# in the packet-processing path on a single core.
	if [ -d /proc/irq ]; then
		for d in /proc/irq/*/; do
			action="$(cat "${d}actions" 2>/dev/null || true)"
			case "$action" in
				*eth0*)
					echo 3 > "${d}smp_affinity" 2>/dev/null || true
					;;
			esac
		done
	fi

	if valid_router_config_present; then
		touch "$CONFIG_READY_FILE"
		chmod 600 "$CONFIG_READY_FILE"
		existing_ready='1'
	else
		rm -f "$CONFIG_READY_FILE"
		existing_ready='0'
	fi

	exec </dev/null
	if [ "$FILES_CHANGED" = '1' ] || ! is_done services; then
		info "Restarting router services..."
		/etc/init.d/xray-switch-watchdog stop >/dev/null 2>&1 || true
		/etc/init.d/router-rules-sync stop >/dev/null 2>&1 || true
		/etc/init.d/firewall reload >/dev/null 2>&1 || true
		/etc/init.d/stubby stop >/dev/null 2>&1 || true
		/etc/init.d/stubby disable >/dev/null 2>&1 || true
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
		/etc/init.d/odhcpd restart >/dev/null 2>&1 || true
		/etc/init.d/codex-xray enable >/dev/null 2>&1 || true
		/etc/init.d/codex-transproxy enable >/dev/null 2>&1 || true
		/etc/init.d/xray-switch-watchdog enable >/dev/null 2>&1 || true
		/etc/init.d/xray-health-monitor enable >/dev/null 2>&1 || true
		/etc/init.d/xray-health-monitor start >/dev/null 2>&1 || true
		/etc/init.d/router-rules-sync enable >/dev/null 2>&1 || true
		/etc/init.d/gl_switch_button_check stop >/dev/null 2>&1 || true
		/etc/init.d/gl_switch_button_check disable >/dev/null 2>&1 || true
		/usr/bin/router-rules ensure-git-key >/dev/null 2>&1 || true
		if defer_xray_activation; then
			info "Deferred Xray runtime activation; router path will stay off until a profile is explicitly applied."
		else
			/usr/bin/router-rules sync-apply-xray >/dev/null 2>&1 || true
			/etc/init.d/xray-switch-watchdog start >/dev/null 2>&1 || true
		fi
		/etc/init.d/router-rules-sync start >/dev/null 2>&1 || true
		mark_done services
	else
		info "No file changes detected; skipping service restart."
	fi

	switch_state="$(current_switch_state)"
	info "Router platform is installed."
	if [ "$existing_ready" = '1' ]; then
		info "A valid router Xray config was already present and has been preserved."
		info "Hardware switch state: $switch_state"
	else
		info "No active VPS profile is configured on this router yet."
		info "Open https://192.168.8.1/xray.html, enter VPS SSH details, and click 'Sync Router + VPS'."
	fi
}

install_platform
