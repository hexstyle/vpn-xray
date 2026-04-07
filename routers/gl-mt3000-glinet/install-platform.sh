#!/bin/sh

set -eu

SELF_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)"
SOURCE_DIR="$ROOT_DIR"
PREFLIGHT_ONLY='0'

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
		*)
			echo "Usage: $0 [--source-dir <repo-root>] [--preflight]" >&2
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
OPENWRT_FALLBACK_PACKAGES_BASE='https://downloads.openwrt.org/releases/21.02.3/packages'

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

info() {
	printf '%s\n' "$*"
}

warn() {
	printf 'WARNING: %s\n' "$*" >&2
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

have_cmd() {
	command -v "$1" >/dev/null 2>&1
}

require_cmd() {
	have_cmd "$1" || fail "Missing required router command: $1"
}

ensure_pkg_installed() {
	local package="$1"

	opkg list-installed "$package" >/dev/null 2>&1 && return 0
	opkg install "$package" >/dev/null 2>&1 || fail "Could not install package '$package' with opkg. Check router internet access and package feeds."
}

ensure_cmd_via_package() {
	local cmd="$1"
	local package="$2"

	have_cmd "$cmd" && return 0
	ensure_pkg_installed "$package"
	have_cmd "$cmd" || fail "Command '$cmd' is still unavailable after installing package '$package'."
}

try_pkg_install() {
	local package="$1"
	local purpose="$2"

	opkg list-installed "$package" >/dev/null 2>&1 && return 0
	opkg install "$package" >/dev/null 2>&1 || {
		warn "Could not install optional package '$package' for $purpose. The core VPN path can still work, but the related feature may stay unavailable."
		return 1
	}
	return 0
}

router_package_arch() {
	local arch=''

	if [ -f /etc/openwrt_release ]; then
		# shellcheck disable=SC1091
		. /etc/openwrt_release
		arch="${DISTRIB_ARCH:-}"
	fi

	if [ -z "$arch" ]; then
		arch="$(opkg print-architecture 2>/dev/null | awk '/^arch / && $2 != "all" && $2 != "noarch" {if ($3 > best) {best=$3; arch=$2}} END {print arch}')"
	fi

	[ -n "$arch" ] || return 1
	printf '%s\n' "$arch"
}

openwrt_fallback_repo_url() {
	local arch

	arch="$(router_package_arch)" || return 1
	printf '%s/%s/packages\n' "$OPENWRT_FALLBACK_PACKAGES_BASE" "$arch"
}

openwrt_fallback_index_path() {
	local arch

	arch="$(router_package_arch)" || return 1
	printf '%s/openwrt-packages-%s.gz\n' "$DOWNLOAD_DIR" "$arch"
}

openwrt_fallback_package_filename() {
	local package="$1"
	local repo_url index_path filename

	repo_url="$(openwrt_fallback_repo_url)" || return 1
	index_path="$(openwrt_fallback_index_path)" || return 1

	if [ ! -f "$index_path" ]; then
		download_to_file "$repo_url/Packages.gz" "$index_path" || return 1
	fi

	filename="$(gzip -dc "$index_path" 2>/dev/null | awk -v pkg="$package" '
		/^Package: / { found = ($2 == pkg); next }
		found && /^Filename: / { print $2; exit }
	')"
	[ -n "$filename" ] || return 1
	printf '%s\n' "$filename"
}

install_pkg_via_openwrt_fallback() {
	local package="$1"
	local repo_url filename target

	repo_url="$(openwrt_fallback_repo_url)" || return 1
	filename="$(openwrt_fallback_package_filename "$package")" || return 1
	target="${DOWNLOAD_DIR}/$(basename "$filename")"
	download_to_file "$repo_url/$filename" "$target" || return 1
	opkg install "$target" >/dev/null 2>&1
}

ensure_pkg_installed_or_fallback() {
	local package="$1"
	local purpose="$2"

	opkg list-installed "$package" >/dev/null 2>&1 && return 0
	opkg install "$package" >/dev/null 2>&1 && return 0

	warn "Could not install package '$package' from configured feeds for $purpose. Trying the official OpenWrt 21.02.3 package mirror."
	install_pkg_via_openwrt_fallback "$package" || fail "Could not install package '$package' for $purpose from either opkg feeds or the official OpenWrt package mirror."
	opkg list-installed "$package" >/dev/null 2>&1 || fail "Package '$package' is still unavailable after fallback install."
}

git_sync_requested() {
	[ "${RULES_GIT_SYNC_ENABLED:-0}" = '1' ]
}

ensure_git_sync_dependencies() {
	git_sync_requested || return 0

	info "Ensuring Git sync dependencies..."
	ensure_pkg_installed_or_fallback openssh-client "Git-backed shared rules sync"
	ensure_pkg_installed_or_fallback openssh-keygen "Git-backed shared rules sync"
	ensure_pkg_installed_or_fallback git "Git-backed shared rules sync"
	ensure_pkg_installed_or_fallback git-http "Git-backed shared rules sync"

	ssh -V 2>&1 | grep -q 'OpenSSH_' || fail "ssh is still not provided by OpenSSH after installing openssh-client."
	command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is still unavailable after installing openssh-keygen."
	command -v git >/dev/null 2>&1 || fail "git is still unavailable after installing git."
}

download_to_file() {
	local url="$1"
	local target="$2"

	if have_cmd curl; then
		curl -fsSL --connect-timeout 15 --max-time 300 -o "$target" "$url" || return 1
		return 0
	fi

	if have_cmd wget; then
		wget -qO "$target" "$url" || return 1
		return 0
	fi

	return 1
}

sha256_file() {
	local path="$1"
	if have_cmd sha256sum; then
		sha256sum "$path" | awk '{print $1}'
		return 0
	fi
	if have_cmd openssl; then
		openssl dgst -sha256 "$path" | sed 's/^.*= //'
		return 0
	fi
	fail "No SHA-256 tool is available on the router."
}

ensure_file_sha256() {
	local path="$1"
	local url="$2"
	local expected="$3"
	local got=''

	if [ ! -f "$path" ]; then
		download_to_file "$url" "$path" || fail "Could not download $url. Check router uplink and HTTPS reachability."
	fi

	got="$(sha256_file "$path")"
	if [ "$got" != "$expected" ]; then
		rm -f "$path"
		download_to_file "$url" "$path" || fail "Could not re-download $url after sha256 mismatch."
		got="$(sha256_file "$path")"
	fi

	[ "$got" = "$expected" ] || fail "sha256 mismatch for $path: expected $expected, got $got"
}

stage_bundled_or_download() {
	local filename="$1"
	local target="$2"
	local url="$3"
	local expected="$4"
	local bundled_path got

	bundled_path="${BUNDLED_PAYLOAD_DIR}/${filename}"
	if [ -f "$bundled_path" ]; then
		cp "$bundled_path" "$target"
		got="$(sha256_file "$target")"
		[ "$got" = "$expected" ] || fail "Bundled payload sha256 mismatch for $filename: expected $expected, got $got"
		return 0
	fi

	ensure_file_sha256 "$target" "$url" "$expected"
}

escape_sed_replacement() {
	printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

render_redsocks_conf() {
	local output="$1"
	local redsocks_port socks_port

	redsocks_port="$(escape_sed_replacement "$REDSOCKS_PORT")"
	socks_port="$(escape_sed_replacement "$LOCAL_SOCKS_PORT")"

	sed \
		-e "s|\${REDSOCKS_PORT}|$redsocks_port|g" \
		-e "s|\${LOCAL_SOCKS_PORT}|$socks_port|g" \
		"$PROFILE_DIR/files/redsocks.conf.template" > "$output"
}

render_router_rules_conf() {
	local output="$1"
	local sync_enabled fetch_url push_url branch auth_mode http_username http_password user_name user_email dns_resolver device_id enable_push mode sync_interval

	sync_enabled="$(escape_sed_replacement "${RULES_GIT_SYNC_ENABLED:-}")"
	fetch_url="$(escape_sed_replacement "${RULES_REPO_FETCH_URL:-}")"
	push_url="$(escape_sed_replacement "${RULES_REPO_PUSH_URL:-}")"
	branch="$(escape_sed_replacement "${RULES_REPO_BRANCH:-main}")"
	auth_mode="$(escape_sed_replacement "${RULES_GIT_AUTH_MODE:-auto}")"
	http_username="$(escape_sed_replacement "${RULES_GIT_HTTP_USERNAME:-}")"
	http_password="$(escape_sed_replacement "${RULES_GIT_HTTP_PASSWORD:-}")"
	user_name="$(escape_sed_replacement "${RULES_GIT_USER_NAME:-router-rules}")"
	user_email="$(escape_sed_replacement "${RULES_GIT_USER_EMAIL:-router-rules@example.invalid}")"
	dns_resolver="$(escape_sed_replacement "${RULES_DNS_RESOLVER:-1.1.1.1 9.9.9.9}")"
	device_id="$(escape_sed_replacement "${RULES_DEVICE_ID:-gl-router}")"
	enable_push="$(escape_sed_replacement "${RULES_ENABLE_PUSH:-0}")"
	mode="$(escape_sed_replacement "${XRAY_RULES_MODE:-full}")"
	sync_interval="$(escape_sed_replacement "${RULES_SYNC_INTERVAL:-30}")"

	sed \
		-e "s|\${RULES_GIT_SYNC_ENABLED}|$sync_enabled|g" \
		-e "s|\${RULES_REPO_FETCH_URL}|$fetch_url|g" \
		-e "s|\${RULES_REPO_PUSH_URL}|$push_url|g" \
		-e "s|\${RULES_REPO_BRANCH}|$branch|g" \
		-e "s|\${RULES_GIT_AUTH_MODE}|$auth_mode|g" \
		-e "s|\${RULES_GIT_HTTP_USERNAME}|$http_username|g" \
		-e "s|\${RULES_GIT_HTTP_PASSWORD}|$http_password|g" \
		-e "s|\${RULES_GIT_USER_NAME}|$user_name|g" \
		-e "s|\${RULES_GIT_USER_EMAIL}|$user_email|g" \
		-e "s|\${RULES_DNS_RESOLVER}|$dns_resolver|g" \
		-e "s|\${RULES_DEVICE_ID}|$device_id|g" \
		-e "s|\${RULES_ENABLE_PUSH}|$enable_push|g" \
		-e "s|\${XRAY_RULES_MODE}|$mode|g" \
		-e "s|\${RULES_SYNC_INTERVAL}|$sync_interval|g" \
		"$COMMON_DIR/files/router-rules.config.template" > "$output"
}

current_switch_state() {
	if [ -f /lib/functions/gl_util.sh ]; then
		# shellcheck disable=SC1091
		. /lib/functions/gl_util.sh
		get_switch_button_status 2>/dev/null && return 0
	fi

	[ -n "$(cat /proc/gl-hw-info/model 2>/dev/null || true)" ] || {
		echo off
		return 0
	}
	echo off
}

valid_router_config_present() {
	[ -x "$ROUTER_BIN" ] || return 1
	[ -s "$ROUTER_CONFIG" ] || return 1
	"$ROUTER_BIN" run -test -config "$ROUTER_CONFIG" >/dev/null 2>&1
}

write_platform_metadata() {
	mkdir -p "$PLATFORM_DIR"
	cat > "$PLATFORM_ENV" <<EOF
ROUTER_PROFILE=gl-mt3000-glinet
VPN_XRAY_REPO_SLUG=${VPN_XRAY_REPO_SLUG:-hexstyle/vpn-xray}
VPN_XRAY_REF=${VPN_XRAY_REF:-main}
INSTALLED_AT=$(date +%s)
EOF
	chmod 600 "$PLATFORM_ENV"
}

preflight() {
	local model now_year cmd

	for cmd in $ROUTER_REQUIRED_COMMANDS tar awk sed; do
		require_cmd "$cmd"
	done

	model="$(cat /proc/gl-hw-info/model 2>/dev/null | sed -n '1p' || true)"
	[ -n "$model" ] || fail "Could not detect the GL.iNet hardware model on the router."
	[ "$model" = "$ROUTER_EXPECTED_MODEL" ] || fail "Unsupported router model '$model'. This profile expects '$ROUTER_EXPECTED_MODEL'."

	if [ "${ROUTER_REQUIRES_DNSMASQ_IPSET:-0}" = '1' ]; then
		dnsmasq --help 2>/dev/null | grep -qi 'ipset' || fail "This router firmware does not expose dnsmasq ipset support, which selective routing requires."
	fi

	now_year="$(date +%Y 2>/dev/null || echo 1970)"
	case "$now_year" in
		''|*[!0-9]*)
			now_year=1970
			;;
	esac
	[ "$now_year" -ge 2024 ] || warn "Router system time looks old ($now_year). If GitHub downloads fail, connect the router to the internet and wait for time/NTP to settle."
}

install_platform() {
	local archive binary libevent_pkg redsocks_pkg redsocks_rendered router_rules_rendered existing_ready switch_state

	info "Running router platform preflight..."
	preflight

	if [ "$PREFLIGHT_ONLY" = '1' ]; then
		info "Router platform preflight passed."
		return 0
	fi

	info "Preparing router package manager..."
	if opkg update >/tmp/vpn-xray-opkg-update.log 2>&1; then
		OPKG_UPDATE_OK='1'
	else
		warn "opkg update did not fully complete. Continuing with already-present commands and package lists."
		warn "See /tmp/vpn-xray-opkg-update.log on the router for feed errors."
	fi
	ensure_pkg_installed ca-bundle
	ensure_pkg_installed ca-certificates
	ensure_cmd_via_package curl curl
	ensure_cmd_via_package unzip unzip
	try_pkg_install git "Git-backed shared rules sync" || true
	try_pkg_install git-http "Git-backed shared rules sync" || true
	ensure_git_sync_dependencies

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

	info "Stopping vpn-xray runtime before file updates..."
	/etc/init.d/xray-switch-watchdog stop >/dev/null 2>&1 || true
	/etc/init.d/router-rules-sync stop >/dev/null 2>&1 || true
	/etc/init.d/codex-transproxy stop >/dev/null 2>&1 || true
	/etc/init.d/codex-xray stop >/dev/null 2>&1 || true
	killall codex-xray-core 2>/dev/null || true

	info "Installing router-side dependencies..."
	opkg install "$libevent_pkg" "$redsocks_pkg" >/dev/null 2>&1 || fail "Could not install the router-side redsocks dependencies."
	command -v redsocks >/dev/null 2>&1 || fail "redsocks is still unavailable after package install."

	mkdir -p /usr/local/bin /etc/xray /var/log/xray /etc/router-rules/generated /etc/router-rules/ssh /usr/share/vpn-xray /www/cgi-bin /etc/gl-switch.d "$PLATFORM_DIR"
	cp "$binary" "$ROUTER_BIN"
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
set router_rules.global.git_sync_enabled='${RULES_GIT_SYNC_ENABLED:-}'
set router_rules.global.repo_fetch_url='${RULES_REPO_FETCH_URL:-}'
set router_rules.global.repo_push_url='${RULES_REPO_PUSH_URL:-}'
set router_rules.global.repo_branch='${RULES_REPO_BRANCH:-main}'
set router_rules.global.git_auth_mode='${RULES_GIT_AUTH_MODE:-auto}'
set router_rules.global.git_http_username='${RULES_GIT_HTTP_USERNAME:-}'
set router_rules.global.git_http_password='${RULES_GIT_HTTP_PASSWORD:-}'
set router_rules.global.git_user_name='${RULES_GIT_USER_NAME:-router-rules}'
set router_rules.global.git_user_email='${RULES_GIT_USER_EMAIL:-router-rules@example.invalid}'
set router_rules.global.dns_resolver='${RULES_DNS_RESOLVER:-1.1.1.1 9.9.9.9}'
set router_rules.global.local_device_id='${RULES_DEVICE_ID:-gl-router}'
set router_rules.global.enable_push='${RULES_ENABLE_PUSH:-0}'
set router_rules.global.xray_mode='${XRAY_RULES_MODE:-full}'
set router_rules.global.sync_interval='${RULES_SYNC_INTERVAL:-30}'
EOF
	uci commit router_rules
	chmod 600 /etc/config/router_rules
	if [ -n "${RULES_GIT_SSH_PRIVATE_KEY_B64:-}" ] || [ -n "${RULES_GIT_SSH_PRIVATE_KEY:-}" ]; then
		if [ -n "${RULES_GIT_SSH_PRIVATE_KEY_B64:-}" ]; then
			command -v base64 >/dev/null 2>&1 || fail "base64 is required to decode RULES_GIT_SSH_PRIVATE_KEY_B64."
			if ! printf '%s' "$RULES_GIT_SSH_PRIVATE_KEY_B64" | base64 -d > /etc/router-rules/ssh/routerRules_ed25519 2>/dev/null; then
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

	cp "$PROFILE_DIR/files/codex-xray.init" /etc/init.d/codex-xray
	cp "$PROFILE_DIR/files/codex-transproxy.init" /etc/init.d/codex-transproxy
	cp "$PROFILE_DIR/files/xray-switch-watchdog.init" /etc/init.d/xray-switch-watchdog
	cp "$COMMON_DIR/files/router-rules-sync.init" /etc/init.d/router-rules-sync
	cp "$PROFILE_DIR/files/gl-switch-xray.sh" /etc/gl-switch.d/xray.sh
	cp "$COMMON_DIR/files/router-rules" /usr/bin/router-rules
	cp "$PROFILE_DIR/files/xray.html" /www/xray.html
	cp "$PROFILE_DIR/files/xray-admin.cgi" /www/cgi-bin/xray-admin
	cp "$PROFILE_DIR/files/xray-vps.cgi" /www/cgi-bin/xray-vps
	cp "$PROFILE_DIR/files/xray-rules.cgi" /www/cgi-bin/xray-rules
	chmod 755 /etc/init.d/codex-xray /etc/init.d/codex-transproxy /etc/init.d/xray-switch-watchdog /etc/init.d/router-rules-sync /etc/gl-switch.d/xray.sh /usr/bin/router-rules /www/cgi-bin/xray-admin /www/cgi-bin/xray-vps /www/cgi-bin/xray-rules
	chmod 644 /www/xray.html

	rm -rf /usr/share/vpn-xray/vps
	mkdir -p /usr/share/vpn-xray
	cp -R "$VPS_DIR" /usr/share/vpn-xray/vps

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
	uci -q delete dhcp.@dnsmasq[0].server >/dev/null 2>&1 || true
	uci commit dhcp
	uci set network.lan.ip6assign='0'
	uci set stubby.global.enabled='0'
	uci commit network
	uci commit stubby
	uci set switch-button.@main[0].func='xray'
	uci -q delete switch-button.@main[0].sub_func >/dev/null 2>&1 || true
	uci commit switch-button

	if [ "${ISOLATE_WIFI_LAN_ONLY:-0}" = '1' ]; then
		uci del_list network.@device[0].ports='eth1' 2>/dev/null || true
	else
		uci add_list network.@device[0].ports='eth1' 2>/dev/null || true
	fi
	uci commit network

	write_platform_metadata

	if valid_router_config_present; then
		touch "$CONFIG_READY_FILE"
		chmod 600 "$CONFIG_READY_FILE"
		existing_ready='1'
	else
		rm -f "$CONFIG_READY_FILE"
		existing_ready='0'
	fi

	info "Restarting router services..."
	/etc/init.d/firewall reload >/dev/null 2>&1 || true
	/etc/init.d/stubby stop >/dev/null 2>&1 || true
	/etc/init.d/stubby disable >/dev/null 2>&1 || true
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	/etc/init.d/odhcpd restart >/dev/null 2>&1 || true
	/etc/init.d/codex-xray disable >/dev/null 2>&1 || true
	/etc/init.d/codex-transproxy disable >/dev/null 2>&1 || true
	/etc/init.d/xray-switch-watchdog enable >/dev/null 2>&1 || true
	/etc/init.d/router-rules-sync enable >/dev/null 2>&1 || true
	/etc/init.d/gl_switch_button_check stop >/dev/null 2>&1 || true
	/etc/init.d/gl_switch_button_check disable >/dev/null 2>&1 || true
	/usr/bin/router-rules ensure-git-key >/dev/null 2>&1 || true
	/etc/init.d/router-rules-sync start >/dev/null 2>&1 || true
	/usr/bin/router-rules sync-apply-xray >/dev/null 2>&1 || true
	/etc/init.d/xray-switch-watchdog start >/dev/null 2>&1 || true

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
