#!/bin/sh
# xray-vps-inspect.sh — remote inspection, cache refresh, store backup
# Deployed to /usr/share/vpn-xray/xray-vps-inspect.sh
# Sourced by /www/cgi-bin/xray-vps after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

ensure_profile_store_light() {
	local active

	ensure_dirs
	if ! uci -q get "${PROFILE_PACKAGE}.${PROFILE_STATE}" >/dev/null 2>&1; then
		uci -q set "${PROFILE_PACKAGE}.${PROFILE_STATE}=state"
		set_active_profile 'default'
		uci -q set "${PROFILE_PACKAGE}.default=profile"
		profile_set default label 'Current VPS'
		profile_set default vps_profile "$(default_vps_profile)"
		profile_set default auth_mode 'managed_key'
		profile_set default ssh_host "$(router_live_value server_address)"
		profile_set default ssh_port '22'
		profile_set default ssh_user 'root'
		profile_set default server_address "$(router_live_value server_address)"
			profile_set default server_port "$(router_live_value server_port)"
			profile_set default server_name "$(router_live_value server_name)"
			profile_set default uuid "$(router_live_value uuid)"
			profile_set default public_key "$(router_live_value public_key)"
			profile_set default short_id "$(router_live_value short_id)"
			profile_set default flow "$(router_live_value flow)"
			profile_set default private_key ''
			profile_set default managed_key_path "${KEY_DIR}/default_ed25519"
			profile_set default bootstrap_key_path "${KEY_DIR}/default_bootstrap"
			profile_set default managed_pubkey ''
			profile_del default ssh_password
			profile_set default last_inspect_status 'never'
			profile_set default last_inspect_at ''
			uci commit "$PROFILE_PACKAGE"
	fi

	active="$(active_profile_id)"
	if [ -z "$active" ] || ! profile_exists "$active"; then
		set_active_profile 'default'
	fi
}

ensure_profile_store() {
	local profile_id

	ensure_profile_store_light

	for profile_id in $(profile_ids); do
		profile_del "$profile_id" ssh_password
		ensure_profile_material "$profile_id"
		ensure_profile_keypair "$profile_id" || true
	done
	uci commit "$PROFILE_PACKAGE"
}

remote_inspect_output() {
	local profile_id="$1"
	local vps_profile meta_path config_path expected_server_port

	vps_profile="$(selected_vps_profile "$profile_id")"
	meta_path="$(vps_profile_value "$vps_profile" VPS_REMOTE_META_PATH)"
	config_path="$(vps_profile_value "$vps_profile" VPS_XRAY_CONFIG_PATH)"
	expected_server_port="$(profile_get "$profile_id" server_port)"
	[ -n "$meta_path" ] || meta_path='/usr/local/etc/xray/codex-router-meta.env'
	[ -n "$config_path" ] || config_path='/usr/local/etc/xray/config.json'

	ssh_cmd "$profile_id" "REMOTE_META_PATH='$meta_path' REMOTE_CONFIG_PATH='$config_path' EXPECTED_SERVER_PORT='$expected_server_port' sh -s" <<'EOF'
line() {
	printf '%s=%s\n' "$1" "$2"
}

one_line_file() {
	[ -f "$1" ] && tr '\n' ' ' < "$1" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//' || true
}

hostname_v="$(hostname 2>/dev/null || true)"
fqdn_v="$(hostname -f 2>/dev/null || true)"
kernel_v="$(uname -srmo 2>/dev/null || true)"
arch_v="$(uname -m 2>/dev/null || true)"
pretty_name_v="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"' | sed -n '1p')"
os_id_v="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | sed -n '1p')"
os_version_v="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | sed -n '1p')"
[ -n "$pretty_name_v" ] || pretty_name_v="$(one_line_file /etc/issue)"
virt_v="$(command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt 2>/dev/null || true)"
[ -n "$virt_v" ] || virt_v='none'
systemd_v='0'
command -v systemctl >/dev/null 2>&1 && systemd_v='1'
pkg_mgr_v=''
for c in apt-get dnf yum apk zypper; do
	command -v "$c" >/dev/null 2>&1 && {
		pkg_mgr_v="$c"
		break
	}
done
memory_v="$(free -h 2>/dev/null | sed -n '2p' | sed 's/[[:space:]]\+/ /g' || true)"
disk_root_v="$(df -h / 2>/dev/null | sed -n '2p' | sed 's/[[:space:]]\+/ /g' || true)"
uptime_v="$(uptime 2>/dev/null | sed 's/[[:space:]]\+/ /g' || true)"
ipinfo_v="$(timeout 10 curl -4fsS --max-time 8 https://ipinfo.io/json 2>/dev/null | tr -d '\n' || true)"
public_ip_v="$(timeout 10 curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
xray_bin=''
for p in /usr/local/bin/xray /usr/bin/xray; do
	[ -x "$p" ] && {
		xray_bin="$p"
		break
	}
done
xray_present='0'
[ -n "$xray_bin" ] && xray_present='1'
xray_version_v=''
[ -n "$xray_bin" ] && xray_version_v="$($xray_bin version 2>/dev/null | sed -n '1p')"
xray_service_v=''
command -v systemctl >/dev/null 2>&1 && xray_service_v="$(systemctl is-active xray 2>/dev/null || true)"
listener_443_v="$(ss -ltnp 2>/dev/null | grep ':443 ' | tr '\n' ';' || true)"
listener_port_v=''
managed_meta_v='0'
remote_server_port=''
remote_server_name=''
remote_uuid=''
remote_public_key=''
remote_private_key=''
remote_short_id=''
remote_flow=''
remote_transport_net=''
remote_transport_sec=''

# Always read the live transport the VPS serves from its config, even when
# meta.env supplies the identity fields — meta.env does not carry the
# transport, and the transport is what we compare against the router
# (DIAGNOSTIC-TREE 8.5 / G8).
if [ -f "$REMOTE_CONFIG_PATH" ] && command -v python3 >/dev/null 2>&1; then
	eval "$(REMOTE_CONFIG_PATH="$REMOTE_CONFIG_PATH" python3 - <<'PYT'
import json, os, shlex
try:
    with open(os.environ['REMOTE_CONFIG_PATH'], encoding='utf-8') as fh:
        cfg = json.load(fh)
    ib = (cfg.get('inbounds') or [{}])[0]
    st = ib.get('streamSettings') or {}
    print("remote_transport_net=%s" % shlex.quote(str(st.get('network') or '')))
    print("remote_transport_sec=%s" % shlex.quote(str(st.get('security') or '')))
except Exception:
    print("remote_transport_net=''")
    print("remote_transport_sec=''")
PYT
)"
fi

if [ -f "$REMOTE_META_PATH" ]; then
	managed_meta_v='1'
	. "$REMOTE_META_PATH"
	remote_server_port="${XRAY_PORT:-}"
	remote_server_name="${XRAY_SERVER_NAME:-}"
	remote_uuid="${XRAY_UUID:-}"
	remote_public_key="${XRAY_PUBLIC_KEY:-}"
	remote_private_key="${XRAY_PRIVATE_KEY:-}"
	remote_short_id="${XRAY_SHORT_ID:-}"
	remote_flow="${XRAY_FLOW:-}"
elif [ -f "$REMOTE_CONFIG_PATH" ]; then
	if command -v python3 >/dev/null 2>&1; then
		eval "$(python3 - <<'PY'
import json
import shlex

import os

with open(os.environ['REMOTE_CONFIG_PATH'], 'r', encoding='utf-8') as fh:
    cfg = json.load(fh)

inbounds = cfg.get('inbounds') or [{}]
inbound = inbounds[0] if inbounds else {}
settings = inbound.get('settings') or {}
clients = settings.get('clients') or [{}]
client = clients[0] if clients else {}
stream = inbound.get('streamSettings') or {}
reality = stream.get('realitySettings') or {}
tls = stream.get('tlsSettings') or {}
ws = stream.get('wsSettings') or {}

# Transport the VPS actually serves (DIAGNOSTIC-TREE 8.5 / G8). Compared
# against the router's outbound transport so a divergence (VPS ws/tls vs
# router raw/reality) is flagged before the tunnel silently fails.
net = stream.get('network') or ''
sec = stream.get('security') or ''

# serverName across transports: WS+TLS carries it in tlsSettings; the
# legacy reality shape used serverNames/target.
server_name = tls.get('serverName') or ''
if not server_name:
    target = reality.get('target') or reality.get('dest') or ''
    if target:
        server_name = str(target).split(':')[0]
if not server_name:
    names = reality.get('serverNames') or []
    if names:
        server_name = names[0]

short_ids = reality.get('shortIds') or []
short_id = short_ids[0] if short_ids else ''

def emit(name, value):
    if value is None:
        value = ''
    print(f"{name}={shlex.quote(str(value))}")

emit('remote_server_port', inbound.get('port', ''))
emit('remote_server_name', server_name)
emit('remote_uuid', client.get('id', ''))
emit('remote_private_key', reality.get('privateKey', ''))
emit('remote_short_id', short_id)
emit('remote_flow', client.get('flow', ''))
emit('remote_transport_net', net)
emit('remote_transport_sec', sec)
PY
)"
	else
		config_json_v="$(tr -d '\n' < "$REMOTE_CONFIG_PATH" 2>/dev/null || true)"
		remote_server_port="$(printf '%s' "$config_json_v" | sed -n 's/.*"port":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | sed -n '1p')"
		remote_server_name="$(printf '%s' "$config_json_v" | sed -n 's/.*"target":[[:space:]]*"\([^":]*\):443".*/\1/p' | sed -n '1p')"
		[ -n "$remote_server_name" ] || remote_server_name="$(printf '%s' "$config_json_v" | sed -n 's/.*"serverNames":[[:space:]]*\["\([^"]*\)".*/\1/p' | sed -n '1p')"
		remote_uuid="$(printf '%s' "$config_json_v" | sed -n 's/.*"id":[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"
		remote_private_key="$(printf '%s' "$config_json_v" | sed -n 's/.*"privateKey":[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"
		remote_short_id="$(printf '%s' "$config_json_v" | sed -n 's/.*"shortIds":[[:space:]]*\["\([^"]*\)".*/\1/p' | sed -n '1p')"
		remote_flow="$(printf '%s' "$config_json_v" | sed -n 's/.*"flow":[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"
	fi
fi

if [ -z "$remote_public_key" ] && [ -n "$remote_private_key" ] && [ -n "$xray_bin" ]; then
	remote_public_key="$($xray_bin x25519 -i "$remote_private_key" 2>/dev/null | sed -n 's/^Password (PublicKey): //p' | sed -n '1p')"
fi

listener_target_port="${remote_server_port:-${EXPECTED_SERVER_PORT:-443}}"
case "$listener_target_port" in
	''|*[!0-9]*)
		listener_target_port='443'
		;;
esac
listener_port_v="$(ss -ltnp 2>/dev/null | grep ":${listener_target_port} " | tr '\n' ';' || true)"

line REMOTE_STATUS ok
line REMOTE_SSH_OK 1
line REMOTE_HOSTNAME "$hostname_v"
line REMOTE_FQDN "$fqdn_v"
line REMOTE_KERNEL "$kernel_v"
line REMOTE_ARCH "$arch_v"
line REMOTE_PRETTY_NAME "$pretty_name_v"
line REMOTE_OS_ID "$os_id_v"
line REMOTE_OS_VERSION "$os_version_v"
line REMOTE_VIRT "$virt_v"
line REMOTE_SYSTEMD "$systemd_v"
line REMOTE_PKG_MGR "$pkg_mgr_v"
line REMOTE_MEMORY "$memory_v"
line REMOTE_DISK_ROOT "$disk_root_v"
line REMOTE_UPTIME "$uptime_v"
line REMOTE_PUBLIC_IP "$public_ip_v"
line REMOTE_IPINFO_JSON "$ipinfo_v"
line REMOTE_XRAY_PRESENT "$xray_present"
line REMOTE_XRAY_VERSION "$xray_version_v"
line REMOTE_XRAY_SERVICE "$xray_service_v"
line REMOTE_LISTENER_PORT "$listener_port_v"
line REMOTE_LISTENER_443 "$listener_443_v"
line REMOTE_MANAGED_META "$managed_meta_v"
line REMOTE_server_port "$remote_server_port"
line REMOTE_server_name "$remote_server_name"
line REMOTE_uuid "$remote_uuid"
line REMOTE_public_key "$remote_public_key"
line REMOTE_private_key "$remote_private_key"
line REMOTE_short_id "$remote_short_id"
line REMOTE_flow "$remote_flow"
line REMOTE_TRANSPORT_NET "$remote_transport_net"
line REMOTE_TRANSPORT_SEC "$remote_transport_sec"
EOF
}

refresh_remote_cache() {
	local profile_id="$1"
	local output public_output private_key cache install_profile install_label install_supported install_notes tmp_cache

	output="$(remote_inspect_output "$profile_id" 2>/dev/null || true)"
	if [ -z "$output" ] || ! printf '%s' "$output" | grep -q '^REMOTE_STATUS=ok'; then
		return 1
	fi

	private_key="$(printf '%s\n' "$output" | sed -n 's/^REMOTE_private_key=//p' | sed -n '1p')"
	public_output="$(printf '%s\n' "$output" | grep -v '^REMOTE_private_key=' || true)"
	private_cache_set "$profile_id" "$private_key"
	write_cache "$profile_id" "$public_output"
	cache="$(profile_cache_path "$profile_id")"
	IFS='|' read -r install_profile install_label install_supported install_notes <<EOF
$(remote_install_support "$profile_id" "$cache")
EOF
	tmp_cache="$(mktemp)"
	cat "$cache" > "$tmp_cache"
	printf 'REMOTE_INSTALL_PROFILE=%s\n' "$install_profile" >> "$tmp_cache"
	printf 'REMOTE_INSTALL_LABEL=%s\n' "$install_label" >> "$tmp_cache"
	printf 'REMOTE_INSTALL_SUPPORTED=%s\n' "$install_supported" >> "$tmp_cache"
	printf 'REMOTE_INSTALL_NOTES=%s\n' "$install_notes" >> "$tmp_cache"
	mv "$tmp_cache" "$cache"
	profile_set "$profile_id" last_inspect_status 'ok'
	profile_set "$profile_id" last_inspect_at "$(date +%s)"
	uci commit "$PROFILE_PACKAGE"
	return 0
}

resync_runtime_to_switch() {
	local switch_state tries

	switch_state="$(current_switch_state)"
	[ "$switch_state" = 'on' ] || switch_state='off'
	if [ -x /etc/gl-switch.d/xray.sh ]; then
		/etc/gl-switch.d/xray.sh "$switch_state" >/dev/null 2>&1 || return 1
	fi
	tries=0
	while [ "$tries" -lt "$SWITCH_SYNC_WAIT_SECONDS" ]; do
		if [ "$switch_state" = 'on' ]; then
			if router_path_active; then
				return 0
			fi
		else
			if ! router_path_active; then
				return 0
			fi
		fi
		tries=$((tries + 1))
		sleep 1
	done
	return 1
}

emit_status_response() {
	local action="$1"
	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"%s",' "$(json_escape "$action")"
	printf '"status":'
	status_json
	printf '}'
}

backup_profile_store() {
	local backup
	backup="/tmp/${PROFILE_PACKAGE}.backup.$$"
	cp "/etc/config/${PROFILE_PACKAGE}" "$backup"
	printf '%s' "$backup"
}

restore_profile_store() {
	local backup="$1"
	[ -f "$backup" ] || return 0
	cp "$backup" "/etc/config/${PROFILE_PACKAGE}"
	rm -f "$backup"
}

drop_profile_store_backup() {
	local backup="$1"
	rm -f "$backup"
}
