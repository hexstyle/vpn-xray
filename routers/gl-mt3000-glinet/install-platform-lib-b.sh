#!/bin/sh
# install-platform-lib-b.sh (gl-mt3000-glinet) — dependency bootstrap, config rendering,
# LAN/wireless setup, switch state, metadata, and preflight for
# install-platform.sh. Sourced via $SELF_DIR; defines functions only.

effective_git_auth_mode() {
	local existing

	# Env wins when explicit. Treat any valid mode in the env as authoritative
	# so install.env (or auto-detect that promotes auto→ssh after copying the
	# local workstation key) drives the final value.
	case "${RULES_GIT_AUTH_MODE:-}" in
		auto|none|readonly|https|ssh)
			printf '%s\n' "$RULES_GIT_AUTH_MODE"
			return
			;;
	esac

	existing="$(existing_router_rules_value git_auth_mode)"
	case "$existing" in
		auto|none|readonly|https|ssh)
			printf '%s\n' "$existing"
			;;
		*)
			printf 'auto\n'
			;;
	esac
}

defer_xray_activation() {
	[ "${DEFER_XRAY_ACTIVATION:-0}" = '1' ]
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

python3_supports_external_fetcher() {
	command -v python3 >/dev/null 2>&1 || return 1
	python3 - <<'PY' >/dev/null 2>&1
import html
import ipaddress
import json
import ssl
import urllib.request
PY
}

ensure_python3_runtime() {
	if python3_supports_external_fetcher; then
		return 0
	fi

	info "Ensuring Python 3 runtime for external shared-rules imports..."
	if ensure_pkg_installed_or_fallback python3-light "external shared-rules import"; then
		python3_supports_external_fetcher && return 0
	fi
	ensure_pkg_installed_or_fallback python3 "external shared-rules import"
	python3_supports_external_fetcher || fail "python3 is installed, but it still cannot import the modules required for external shared-rules imports."
}

ensure_vps_ssh_dependencies() {
	info "Ensuring router-managed VPS SSH dependencies..."
	ensure_pkg_installed_or_fallback openssh-client "router-managed VPS provisioning"
	ensure_pkg_installed_or_fallback openssh-keygen "router-managed VPS provisioning"
	ensure_pkg_installed_or_fallback sshpass "router-managed VPS password bootstrap"

	ssh -V 2>&1 | grep -q 'OpenSSH_' || fail "ssh is still not provided by OpenSSH after installing openssh-client."
	command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is still unavailable after installing openssh-keygen."
	command -v sshpass >/dev/null 2>&1 || fail "sshpass is still unavailable after installing sshpass."
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

	if [ "${VPN_XRAY_ALLOW_NETWORK_PKG:-0}" = "1" ]; then
		ensure_file_sha256 "$target" "$url" "$expected"
		return 0
	fi

	fail "Bundled payload missing: ${bundled_path}. Add it to the router profile (or run scripts/harvest-opkg-packages.sh) or set VPN_XRAY_ALLOW_NETWORK_PKG=1 to allow downloading from $url."
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

	RULES_GIT_SYNC_ENABLED="$(effective_router_rules_bool_value git_sync_enabled "${RULES_GIT_SYNC_ENABLED:-}")" \
	RULES_REPO_FETCH_URL="$(effective_router_rules_text_value repo_fetch_url "${RULES_REPO_FETCH_URL:-}")" \
	RULES_REPO_PUSH_URL="$(effective_router_rules_text_value repo_push_url "${RULES_REPO_PUSH_URL:-}")" \
	RULES_REPO_BRANCH="$(effective_router_rules_text_value repo_branch "${RULES_REPO_BRANCH:-main}")" \
	RULES_GIT_AUTH_MODE="$(effective_git_auth_mode)" \
	RULES_GIT_HTTP_USERNAME="$(effective_router_rules_text_value git_http_username "${RULES_GIT_HTTP_USERNAME:-}")" \
	RULES_GIT_HTTP_PASSWORD="$(effective_router_rules_text_value git_http_password "${RULES_GIT_HTTP_PASSWORD:-}")" \
	RULES_GIT_USER_NAME="${RULES_GIT_USER_NAME:-router-rules}" \
	RULES_GIT_USER_EMAIL="${RULES_GIT_USER_EMAIL:-router-rules@example.invalid}" \
	RULES_DNS_RESOLVER="${RULES_DNS_RESOLVER:-9.9.9.9 208.67.222.222}" \
	RULES_DEVICE_ID="${RULES_DEVICE_ID:-gl-router}" \
	RULES_ENABLE_PUSH="$(effective_router_rules_bool_value enable_push "${RULES_ENABLE_PUSH:-0}")" \
	XRAY_RULES_MODE="$(effective_xray_rules_mode)" \
	RULES_SYNC_INTERVAL="${RULES_SYNC_INTERVAL:-30}" \
	RULES_EXTERNAL_SOURCE_ENABLED="$(effective_external_source_enabled)" \
	RULES_EXTERNAL_SOURCE_URL="$(effective_external_source_url)" \
	RULES_EXTERNAL_SOURCE_INTERVAL="$(effective_external_source_interval)" \
	python3 - "$COMMON_DIR/files/router-rules.config.template" "$output" <<'PY'
import os
import pathlib
import re
import sys

template_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
template = template_path.read_text()

def repl(match):
    key = match.group(1)
    return os.environ.get(key, "")

output_path.write_text(re.sub(r"\$\{([A-Z0-9_]+)\}", repl, template))
PY
}

normalize_unix_text_file() {
	local path="$1"
	[ -f "$path" ] || return 0
	python3 - "$path" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
normalized = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
if normalized != data:
    path.write_bytes(normalized)
PY
}

normalize_installed_text_files() {
	local path
	for path in "$@"; do
		normalize_unix_text_file "$path"
	done
}

lan_device_name() {
	local value

	value="$(uci -q get network.lan.device 2>/dev/null || true)"
	[ -n "$value" ] || value="$(uci -q get network.lan.ifname 2>/dev/null || true)"
	case "$value" in
		''|*' '*)
			value='br-lan'
			;;
	esac
	printf '%s\n' "$value"
}

lan_device_section() {
	local wanted line section name

	wanted="$(lan_device_name)"
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			network.@device[*].name=*)
				section="${line#network.}"
				section="${section%%.name=*}"
				name="${line#*=}"
				name="${name#\'}"
				name="${name%\'}"
				if [ "$name" = "$wanted" ]; then
					printf '%s\n' "$section"
					return 0
				fi
				;;
		esac
	done <<EOF
$(uci -q show network 2>/dev/null || true)
EOF
	return 1
}

normalize_lan_bridge_ports() {
	local section lan_if raw_ports dedup_ports port

	section="${1:-}"
	lan_if="${2:-$(lan_device_name)}"
	[ -n "$section" ] || return 0

	raw_ports="$(uci -q get "network.${section}.ports" 2>/dev/null || true)"
	[ -n "$raw_ports" ] || return 0

	dedup_ports=''
	for port in $raw_ports; do
		case " $dedup_ports " in
			*" $port "*)
				continue
				;;
		esac
		dedup_ports="${dedup_ports:+$dedup_ports }$port"
	done

	[ "$dedup_ports" = "$raw_ports" ] && return 0

	info "Normalizing duplicate LAN bridge ports on ${lan_if}: ${raw_ports} -> ${dedup_ports}"
	uci -q delete "network.${section}.ports" 2>/dev/null || true
	for port in $dedup_ports; do
		uci add_list "network.${section}.ports=$port"
	done
}

configure_lan_bridge_ports() {
	local lan_if section

	lan_if="$(lan_device_name)"
	section="$(lan_device_section || true)"
	if [ "${ISOLATE_WIFI_LAN_ONLY:-0}" != '1' ]; then
		info "Preserving existing LAN bridge port topology on ${lan_if}."
		normalize_lan_bridge_ports "$section" "$lan_if"
		return 0
	fi

	if [ -z "$section" ]; then
		warn "ISOLATE_WIFI_LAN_ONLY=1 was requested, but the LAN bridge section for ${lan_if} could not be resolved. Skipping automatic port removal to protect router reachability."
		return 0
	fi

	warn "ISOLATE_WIFI_LAN_ONLY=1 is removing eth1 from ${lan_if} (${section}). Verify both wired and Wi-Fi management access after the next network reload."
	uci del_list "network.${section}.ports=eth1" 2>/dev/null || true
	normalize_lan_bridge_ports "$section" "$lan_if"
}

stabilize_wireless_bssid() {
	local line section random_bssid

	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			wireless.*=wifi-device)
				section="${line#wireless.}"
				section="${section%%=*}"
				random_bssid="$(uci -q get "wireless.${section}.random_bssid" 2>/dev/null || true)"
				[ -n "$random_bssid" ] || continue
				[ "$random_bssid" = '0' ] && continue
				info "Disabling random_bssid on wireless device ${section} to keep Wi-Fi management BSSIDs stable across reloads and reboots."
				uci set "wireless.${section}.random_bssid=0"
				;;
		esac
	done <<EOF
$(uci -q show wireless 2>/dev/null || true)
EOF
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

	# Bundled redsocks packages require GL.iNet firmware 3.x (OpenWrt 21.02.x).
	# On 4.x/5.x the libevent ABI changed; warn and let the operator decide.
	_fw_ver="$(grep DISTRIB_REVISION /etc/openwrt_release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo unknown)"
	[ -n "$_fw_ver" ] || _fw_ver=unknown
	case "$_fw_ver" in
		3.*|v3.*) : ;;  # known good
		unknown) warn "preflight: could not read firmware version — verify redsocks compatibility manually" ;;
		*) warn "preflight: firmware version $_fw_ver not validated against bundled redsocks packages (built for 3.x); redsocks may fail — check /tmp/vpn-xray-bundled-opkg.log after install" ;;
	esac

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

