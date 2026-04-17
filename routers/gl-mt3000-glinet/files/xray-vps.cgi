#!/bin/sh

set -e

PATH='/usr/sbin:/usr/bin:/sbin:/bin'
PROFILE_PACKAGE='xray_vps'
PROFILE_STATE='main'
PROFILE_DIR='/etc/xray'
KEY_DIR='/etc/xray/ssh-keys'
KNOWN_HOSTS='/etc/xray/known_hosts'
INSPECT_DIR='/etc/xray/vps-inspect'
ROUTER_CONFIG='/etc/xray/codex-xray.json'
ROUTER_READY_FILE='/etc/xray/codex-xray.ready'
ROUTER_XRAY_BIN='/usr/local/bin/codex-xray-core'
ROUTER_HTTP_PORT='1083'
ROUTER_SOCKS_PORT='1084'
ROUTER_ACCESS_LOG='/var/log/xray/codex-xray-access.log'
ROUTER_ERROR_LOG='/var/log/xray/codex-xray-error.log'
VPS_PROFILE_ROOT='/usr/share/vpn-xray/vps'
LOCK_ROOT='/tmp/xray-vps-locks'
SAVE_PROFILE_ERROR=''
SAVE_PROFILE_ID=''

REQUEST_DATA=''

json_escape() {
	local data="${1:-}"
	data="${data//\\/\\\\}"
	data="${data//\"/\\\"}"
	data="${data//	/\\t}"
	printf '%s' "$data" | tr '\r' ' ' | tr '\n' ' ' | sed 's/  */ /g'
}

json_bool() {
	if [ "${1:-0}" = '1' ]; then
		printf 'true'
	else
		printf 'false'
	fi
}

url_decode() {
	local data="${1:-}"
	data="${data//+/ }"
	printf '%b' "$(printf '%s' "$data" | sed 's/%/\\x/g')"
}

load_request_data() {
	local len

	if [ "${REQUEST_METHOD:-GET}" = 'POST' ]; then
		len="${CONTENT_LENGTH:-0}"
		case "$len" in
			''|*[!0-9]*)
				len=0
				;;
		esac
		if [ "$len" -gt 0 ]; then
			dd bs=1 count="$len" 2>/dev/null || true
		fi
	else
		printf '%s' "${QUERY_STRING:-}"
	fi
}

request_value() {
	local key="$1"
	local raw=''

	raw="$(printf '%s' "$REQUEST_DATA" | tr '&' '\n' | sed -n "s/^${key}=//p" | sed -n '1p')"
	url_decode "$raw"
}

valid_port() {
	local value="$1"

	case "$value" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	[ "$value" -ge 1 ] && [ "$value" -le 65535 ]
}

save_profile_fail() {
	SAVE_PROFILE_ERROR="$1"
	return 1
}

emit_header() {
	printf 'Content-Type: application/json\r\n'
	printf 'Cache-Control: no-store\r\n'
	printf '\r\n'
}

emit_error() {
	local action="$1"
	local message="$2"

	emit_header
	printf '{'
	printf '"ok":false,'
	printf '"action":"%s",' "$(json_escape "$action")"
	printf '"error":"%s"' "$(json_escape "$message")"
	printf '}'
}

config_value() {
	local expr="$1"
	jsonfilter -i "$ROUTER_CONFIG" -e "$expr" 2>/dev/null | sed -n '1p'
}

router_live_value() {
	local key="$1"
	case "$key" in
		server_address)
			config_value '@.outbounds[0].settings.vnext[0].address'
			;;
		server_port)
			config_value '@.outbounds[0].settings.vnext[0].port'
			;;
		server_name)
			config_value '@.outbounds[0].streamSettings.realitySettings.serverName'
			;;
		uuid)
			config_value '@.outbounds[0].settings.vnext[0].users[0].id'
			;;
		public_key)
			config_value '@.outbounds[0].streamSettings.realitySettings.publicKey'
			;;
		short_id)
			config_value '@.outbounds[0].streamSettings.realitySettings.shortId'
			;;
		flow)
			config_value '@.outbounds[0].settings.vnext[0].users[0].flow'
			;;
	esac
}

current_switch_state() {
	local model gpio status

	if [ ! -f /proc/gl-hw-info/switch-button ] || [ ! -f /proc/gl-hw-info/model ]; then
		echo 'unknown'
		return
	fi

	model="$(cat /proc/gl-hw-info/model 2>/dev/null || true)"
	gpio="$(cat /proc/gl-hw-info/switch-button 2>/dev/null || true)"
	if [ -z "$model" ] || [ -z "$gpio" ]; then
		echo 'unknown'
		return
	fi

	if [ "$model" = 'mt3000' ]; then
		status="$(grep 'switch' /sys/kernel/debug/gpio 2>/dev/null | grep 'hi' || true)"
	elif [ "$model" = 'axt1800' ] || [ "$model" = 'be3600' ]; then
		status="$(grep "$gpio" /sys/kernel/debug/gpio 2>/dev/null | grep 'hi' || true)"
	elif [ "$model" = 'a1300' ]; then
		status="$(grep 'gpio0' /sys/kernel/debug/gpio 2>/dev/null | grep 'lo' || true)"
	else
		status="$(grep 'switch' /sys/kernel/debug/gpio 2>/dev/null | grep 'lo' || true)"
	fi

	if [ -n "$status" ]; then
		echo 'on'
	else
		echo 'off'
	fi
}

router_current_json() {
	local ready
	router_config_ready && ready=1 || ready=0
	printf '{'
	printf '"config_ready":'; json_bool "$ready"; printf ','
	printf '"server_address":"%s",' "$(json_escape "$(router_live_value server_address)")"
	printf '"server_port":"%s",' "$(json_escape "$(router_live_value server_port)")"
	printf '"server_name":"%s",' "$(json_escape "$(router_live_value server_name)")"
	printf '"uuid":"%s",' "$(json_escape "$(router_live_value uuid)")"
	printf '"public_key":"%s",' "$(json_escape "$(router_live_value public_key)")"
	printf '"short_id":"%s",' "$(json_escape "$(router_live_value short_id)")"
	printf '"flow":"%s"' "$(json_escape "$(router_live_value flow)")"
	printf '}'
}

router_config_ready() {
	[ -f "$ROUTER_READY_FILE" ] && [ -s "$ROUTER_CONFIG" ] && [ -x "$ROUTER_XRAY_BIN" ]
}

router_path_active() {
	local xpid rpid

	xpid="$(cat /var/run/codex-xray.pid 2>/dev/null || true)"
	rpid="$(cat /var/run/redsocks.pid 2>/dev/null || true)"
	[ -n "$xpid" ] && kill -0 "$xpid" 2>/dev/null || return 1
	[ -n "$rpid" ] && kill -0 "$rpid" 2>/dev/null || return 1
	iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'CODEX_TRANSPROXY' || return 1
	return 0
}

ensure_dirs() {
	mkdir -p "$PROFILE_DIR" "$KEY_DIR" "$INSPECT_DIR" "$LOCK_ROOT"
	touch "/etc/config/${PROFILE_PACKAGE}"
	touch "$KNOWN_HOSTS"
	chmod 600 "$KNOWN_HOSTS"
}

with_lock_dir() {
	local lock_dir="$1"
	local cmd="$2"
	local holder tries rc

	shift 2
	holder=''
	tries=0

	while ! mkdir "$lock_dir" 2>/dev/null; do
		holder=''
		[ -f "$lock_dir/pid" ] && holder="$(cat "$lock_dir/pid" 2>/dev/null | sed -n '1p')"
		if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
			rm -rf "$lock_dir"
			continue
		fi
		tries=$((tries + 1))
		if [ "$tries" -ge 60 ]; then
			return 1
		fi
		sleep 1
	done

	printf '%s\n' "$$" > "$lock_dir/pid"
	trap 'rm -rf "$lock_dir"' EXIT INT TERM
	"$cmd" "$@"
	rc=$?
	trap - EXIT INT TERM
	rm -rf "$lock_dir"
	return "$rc"
}

sanitize_id() {
	local raw="$1"
	local out

	out="$(printf '%s' "$raw" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_-')"
	[ -n "$out" ] || out='profile'
	printf '%s' "$out"
}

vps_profile_env_path() {
	printf '%s/%s/profile.env\n' "$VPS_PROFILE_ROOT" "$1"
}

vps_profile_exists() {
	[ -f "$(vps_profile_env_path "$1")" ]
}

vps_profile_value() {
	local profile="$1"
	local key="$2"
	local env_file value

	env_file="$(vps_profile_env_path "$profile")"
	[ -f "$env_file" ] || return 0
	value="$(sh -c '. "$1"; eval "printf %s \"\${'"$key"':-}\""' sh "$env_file" 2>/dev/null || true)"
	printf '%s' "$value"
}

vps_profile_ids() {
	local dir item

	[ -d "$VPS_PROFILE_ROOT" ] || return 0
	for item in "$VPS_PROFILE_ROOT"/*; do
		[ -d "$item" ] || continue
		[ -f "$item/profile.env" ] || continue
		dir="${item##*/}"
		printf '%s\n' "$dir"
	done | sort
}

default_vps_profile() {
	local profile

	for profile in $(vps_profile_ids); do
		printf '%s' "$profile"
		return 0
	done

	printf ''
}

default_server_name_for_profile() {
	local profile="$1"
	local value

	profile="$(normalize_vps_profile "$profile")"
	value="$(vps_profile_value "$profile" VPS_DEFAULT_SERVER_NAME)"
	printf '%s' "$value"
}

normalize_vps_profile() {
	local profile="$1"
	[ -n "$profile" ] || profile="$(default_vps_profile)"
	if vps_profile_exists "$profile"; then
		printf '%s' "$profile"
	else
		printf '%s' "$(default_vps_profile)"
	fi
}

vps_profiles_json() {
	local first=1 profile label
	printf '['
	for profile in $(vps_profile_ids); do
		label="$(vps_profile_value "$profile" VPS_PROFILE_LABEL)"
		[ -n "$label" ] || label="$profile"
		[ "$first" = '1' ] || printf ','
		first=0
		printf '{'
		printf '"id":"%s",' "$(json_escape "$profile")"
		printf '"label":"%s"' "$(json_escape "$label")"
		printf '}'
	done
	printf ']'
}

profile_ids() {
	uci -q show "$PROFILE_PACKAGE" | sed -n "s/^${PROFILE_PACKAGE}\.\([^.=]*\)=profile$/\1/p"
}

profile_exists() {
	uci -q get "${PROFILE_PACKAGE}.$1" >/dev/null 2>&1
}

profile_get() {
	uci -q get "${PROFILE_PACKAGE}.$1.$2" 2>/dev/null || true
}

profile_set() {
	local profile_id="$1"
	local key="$2"
	local value="$3"
	uci -q set "${PROFILE_PACKAGE}.${profile_id}.${key}=${value}"
}

profile_del() {
	uci -q delete "${PROFILE_PACKAGE}.$1.$2" >/dev/null 2>&1 || true
}

active_profile_id() {
	uci -q get "${PROFILE_PACKAGE}.${PROFILE_STATE}.active_profile" 2>/dev/null || true
}

set_active_profile() {
	uci -q set "${PROFILE_PACKAGE}.${PROFILE_STATE}.active_profile=$1"
}

now_epoch() {
	date +%s
}

generate_uuid() {
	"$ROUTER_XRAY_BIN" uuid 2>/dev/null | sed -n '1p'
}

generate_short_id() {
	openssl rand -hex 8 2>/dev/null | sed -n '1p'
}

generate_key_pair() {
	"$ROUTER_XRAY_BIN" x25519 2>/dev/null
}

derive_public_from_private() {
	local private_key="$1"
	"$ROUTER_XRAY_BIN" x25519 -i "$private_key" 2>/dev/null | sed -n 's/^Password (PublicKey): //p' | sed -n '1p'
}

ensure_profile_material() {
	local profile_id="$1"
	local uuid public_key private_key short_id flow keypair

	uuid="$(profile_get "$profile_id" uuid)"
	public_key="$(profile_get "$profile_id" public_key)"
	private_key="$(profile_get "$profile_id" private_key)"
	short_id="$(profile_get "$profile_id" short_id)"
	flow="$(profile_get "$profile_id" flow)"

	if [ -z "$uuid" ]; then
		profile_set "$profile_id" uuid "$(generate_uuid)"
	fi

	if [ -n "$private_key" ] && [ -z "$public_key" ]; then
		public_key="$(derive_public_from_private "$private_key")"
		[ -n "$public_key" ] && profile_set "$profile_id" public_key "$public_key"
	fi

	if [ -z "$private_key" ] && [ -z "$public_key" ]; then
		keypair="$(generate_key_pair)"
		private_key="$(printf '%s\n' "$keypair" | sed -n 's/^PrivateKey: //p' | sed -n '1p')"
		public_key="$(printf '%s\n' "$keypair" | sed -n 's/^Password (PublicKey): //p' | sed -n '1p')"
		[ -n "$private_key" ] && profile_set "$profile_id" private_key "$private_key"
		[ -n "$public_key" ] && profile_set "$profile_id" public_key "$public_key"
	fi

	if [ -z "$short_id" ]; then
		profile_set "$profile_id" short_id "$(generate_short_id)"
	fi

	if [ -z "$flow" ]; then
		profile_set "$profile_id" flow ''
	fi
}

ensure_profile_keypair() {
	local profile_id="$1"
	local key_path pub

	key_path="$(profile_get "$profile_id" managed_key_path)"
	[ -n "$key_path" ] || key_path="${KEY_DIR}/${profile_id}_ed25519"
	mkdir -p "$KEY_DIR"
	if [ ! -f "$key_path" ] || [ ! -f "${key_path}.pub" ] || ! sed -n '1p' "${key_path}.pub" | grep -q '^ssh-rsa ' || ! ssh-keygen -y -f "$key_path" >/dev/null 2>&1; then
		rm -f "$key_path" "${key_path}.pub"
		ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -f "$key_path" >/dev/null 2>&1 || return 1
	fi
	chmod 600 "$key_path"
	chmod 644 "${key_path}.pub"
	pub="$(cat "${key_path}.pub" 2>/dev/null || true)"
	[ -n "$pub" ] || return 1
	profile_set "$profile_id" managed_key_path "$key_path"
	profile_set "$profile_id" managed_pubkey "$pub"
}

save_bootstrap_key() {
	local profile_id="$1"
	local key_text="$2"
	local path

	path="$(profile_get "$profile_id" bootstrap_key_path)"
	[ -n "$path" ] || path="${KEY_DIR}/${profile_id}_bootstrap"
	if [ -n "$key_text" ]; then
		printf '%s\n' "$key_text" > "$path"
		chmod 600 "$path"
		profile_set "$profile_id" bootstrap_key_path "$path"
	fi
}

for_each_identity() {
	local profile_id="$1"
	local callback="$2"
	local arg="$3"
	local managed bootstrap identity used=''

	managed="$(profile_get "$profile_id" managed_key_path)"
	bootstrap="$(profile_get "$profile_id" bootstrap_key_path)"

	for identity in "$managed" "$bootstrap"; do
		[ -n "$identity" ] || continue
		[ -f "$identity" ] || continue
		[ "$identity" = "$used" ] && continue
		"$callback" "$identity" "$arg" && return 0
		used="$identity"
	done
	return 1
}

ssh_exec_with_identity() {
	local identity="$1"
	local packed="$2"
	local cmd host port user

	cmd="$(printf '%s' "$packed" | cut -d '|' -f 1)"
	host="$(printf '%s' "$packed" | cut -d '|' -f 2)"
	port="$(printf '%s' "$packed" | cut -d '|' -f 3)"
	user="$(printf '%s' "$packed" | cut -d '|' -f 4)"

	ssh -i "$identity" \
		-o BatchMode=yes \
		-o ConnectTimeout=8 \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$KNOWN_HOSTS" \
		-p "$port" \
		"$user@$host" "$cmd"
}

ssh_stdin_with_identity() {
	local identity="$1"
	local packed="$2"
	local remote_cmd stdin_path host port user

	remote_cmd="$(printf '%s' "$packed" | cut -d '|' -f 1)"
	stdin_path="$(printf '%s' "$packed" | cut -d '|' -f 2)"
	host="$(printf '%s' "$packed" | cut -d '|' -f 3)"
	port="$(printf '%s' "$packed" | cut -d '|' -f 4)"
	user="$(printf '%s' "$packed" | cut -d '|' -f 5)"

	ssh -i "$identity" \
		-o BatchMode=yes \
		-o ConnectTimeout=8 \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$KNOWN_HOSTS" \
		-p "$port" \
		"$user@$host" "$remote_cmd" < "$stdin_path"
}

ssh_cmd() {
	local profile_id="$1"
	local cmd="$2"
	local host port user packed

	host="$(profile_get "$profile_id" ssh_host)"
	port="$(profile_get "$profile_id" ssh_port)"
	user="$(profile_get "$profile_id" ssh_user)"

	[ -n "$host" ] || return 1
	[ -n "$user" ] || user='root'
	[ -n "$port" ] || port='22'
	packed="${cmd}|${host}|${port}|${user}"
	for_each_identity "$profile_id" ssh_exec_with_identity "$packed"
}

ssh_stdin_cmd() {
	local profile_id="$1"
	local remote_cmd="$2"
	local stdin_path="$3"
	local host port user packed

	host="$(profile_get "$profile_id" ssh_host)"
	port="$(profile_get "$profile_id" ssh_port)"
	user="$(profile_get "$profile_id" ssh_user)"

	[ -n "$host" ] || return 1
	[ -n "$user" ] || user='root'
	[ -n "$port" ] || port='22'
	packed="${remote_cmd}|${stdin_path}|${host}|${port}|${user}"
	for_each_identity "$profile_id" ssh_stdin_with_identity "$packed"
}

ssh_works() {
	ssh_cmd "$1" 'echo ok' >/dev/null 2>&1
}

profile_cache_path() {
	printf '%s/%s.env\n' "$INSPECT_DIR" "$1"
}

profile_private_cache_path() {
	printf '%s/%s.private\n' "$INSPECT_DIR" "$1"
}

cache_get() {
	local cache="$1"
	local key="$2"
	[ -f "$cache" ] || return 0
	sed -n "s/^${key}=//p" "$cache" | sed -n '1p'
}

private_cache_get() {
	local profile_id="$1"
	local cache

	cache="$(profile_private_cache_path "$profile_id")"
	[ -f "$cache" ] || return 0
	cat "$cache" 2>/dev/null || true
}

private_cache_set() {
	local profile_id="$1"
	local value="$2"
	local cache

	cache="$(profile_private_cache_path "$profile_id")"
	if [ -n "$value" ]; then
		printf '%s' "$value" > "$cache"
		chmod 600 "$cache"
	else
		rm -f "$cache"
	fi
}

profile_cache_fresh() {
	local profile_id="$1"
	local max_age="${2:-90}"
	local last status now age

	last="$(profile_get "$profile_id" last_inspect_at)"
	status="$(profile_get "$profile_id" last_inspect_status)"
	[ "$status" = 'ok' ] || return 1
	case "$last" in
		''|*[!0-9]*)
			return 1
			;;
	esac
	now="$(now_epoch)"
	age=$((now - last))
	[ "$age" -ge 0 ] || age=999999
	[ "$age" -le "$max_age" ]
}

write_cache() {
	local profile_id="$1"
	local content="$2"
	printf '%s\n' "$content" > "$(profile_cache_path "$profile_id")"
	chmod 600 "$(profile_cache_path "$profile_id")"
}

render_router_config() {
	local path="$1"
	local profile_id="$2"
	local server_address server_port server_name uuid public_key short_id flow user_flow_line

	server_address="$(profile_get "$profile_id" server_address)"
	server_port="$(profile_get "$profile_id" server_port)"
	server_name="$(profile_get "$profile_id" server_name)"
	uuid="$(profile_get "$profile_id" uuid)"
	public_key="$(profile_get "$profile_id" public_key)"
	short_id="$(profile_get "$profile_id" short_id)"
	flow="$(profile_get "$profile_id" flow)"
	user_flow_line=''
	if [ -n "$flow" ]; then
		user_flow_line="$(printf ',\n                "flow": "%s"' "$flow")"
	fi

	cat > "$path" <<EOF
{
  "log": {
    "loglevel": "info",
    "access": "${ROUTER_ACCESS_LOG}",
    "error": "${ROUTER_ERROR_LOG}"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${ROUTER_HTTP_PORT},
      "protocol": "http",
      "settings": {}
    },
    {
      "listen": "127.0.0.1",
      "port": ${ROUTER_SOCKS_PORT},
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": false
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${server_address}",
            "port": ${server_port},
            "users": [
              {
                "id": "${uuid}",
                "encryption": "none"${user_flow_line}
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "${server_name}",
          "publicKey": "${public_key}",
          "shortId": "${short_id}",
          "spiderX": "/"
        }
      }
    }
  ]
}
EOF
}

template_escape() {
	printf '%s' "${1:-}" | sed 's/[\/&]/\\&/g'
}

selected_vps_profile() {
	normalize_vps_profile "$(profile_get "$1" vps_profile)"
}

vps_profile_file_path() {
	local profile="$1"
	local relpath="$2"
	printf '%s/%s/%s\n' "$VPS_PROFILE_ROOT" "$profile" "$relpath"
}

render_vps_profile_template() {
	local profile_id="$1"
	local template_path="$2"
	local output="$3"
	local vps_profile xray_port xray_flow xray_uuid xray_server_name xray_private_key xray_short_id
	local vps_xray_binary vps_xray_config_dir vps_xray_config_path vps_xray_log_dir vps_xray_service vps_remote_meta_path
	local xray_client_flow_block

	vps_profile="$(selected_vps_profile "$profile_id")"
	xray_port="$(profile_get "$profile_id" server_port)"
	[ -n "$xray_port" ] || xray_port='443'
	xray_flow="$(profile_get "$profile_id" flow)"
	xray_uuid="$(profile_get "$profile_id" uuid)"
	xray_server_name="$(profile_get "$profile_id" server_name)"
	xray_private_key="$(profile_get "$profile_id" private_key)"
	xray_short_id="$(profile_get "$profile_id" short_id)"
	vps_xray_binary="$(vps_profile_value "$vps_profile" VPS_XRAY_BINARY)"
	vps_xray_config_dir="$(vps_profile_value "$vps_profile" VPS_XRAY_CONFIG_DIR)"
	vps_xray_config_path="$(vps_profile_value "$vps_profile" VPS_XRAY_CONFIG_PATH)"
	vps_xray_log_dir="$(vps_profile_value "$vps_profile" VPS_XRAY_LOG_DIR)"
	vps_xray_service="$(vps_profile_value "$vps_profile" VPS_XRAY_SERVICE)"
	vps_remote_meta_path="$(vps_profile_value "$vps_profile" VPS_REMOTE_META_PATH)"
	xray_client_flow_block=''
	if [ -n "$xray_flow" ]; then
		xray_client_flow_block="$(printf ',\n            "flow": "%s"' "$xray_flow")"
	fi

	sed \
		-e "s|\${XRAY_PORT}|$(template_escape "$xray_port")|g" \
		-e "s|\${XRAY_FLOW}|$(template_escape "$xray_flow")|g" \
		-e "s|\${XRAY_CLIENT_FLOW_BLOCK}|$(template_escape "$xray_client_flow_block")|g" \
		-e "s|\${XRAY_UUID}|$(template_escape "$xray_uuid")|g" \
		-e "s|\${XRAY_SERVER_NAME}|$(template_escape "$xray_server_name")|g" \
		-e "s|\${XRAY_PRIVATE_KEY}|$(template_escape "$xray_private_key")|g" \
		-e "s|\${XRAY_SHORT_ID}|$(template_escape "$xray_short_id")|g" \
		-e "s|\${VPS_XRAY_BINARY}|$(template_escape "$vps_xray_binary")|g" \
		-e "s|\${VPS_XRAY_CONFIG_DIR}|$(template_escape "$vps_xray_config_dir")|g" \
		-e "s|\${VPS_XRAY_CONFIG_PATH}|$(template_escape "$vps_xray_config_path")|g" \
		-e "s|\${VPS_XRAY_LOG_DIR}|$(template_escape "$vps_xray_log_dir")|g" \
		-e "s|\${VPS_XRAY_SERVICE}|$(template_escape "$vps_xray_service")|g" \
		-e "s|\${VPS_REMOTE_META_PATH}|$(template_escape "$vps_remote_meta_path")|g" \
		"$template_path" > "$output"
}

render_server_config() {
	local path="$1"
	local profile_id="$2"
	local vps_profile template_rel template_path

	vps_profile="$(selected_vps_profile "$profile_id")"
	template_rel="$(vps_profile_value "$vps_profile" VPS_SERVER_CONFIG_TEMPLATE)"
	template_path="$(vps_profile_file_path "$vps_profile" "$template_rel")"
	[ -f "$template_path" ] || return 1
	render_vps_profile_template "$profile_id" "$template_path" "$path"
}

render_remote_meta() {
	local path="$1"
	local profile_id="$2"

	cat > "$path" <<EOF
PROFILE_ID=${profile_id}
XRAY_HOST=$(profile_get "$profile_id" server_address)
XRAY_PORT=$(profile_get "$profile_id" server_port)
XRAY_UUID=$(profile_get "$profile_id" uuid)
XRAY_SERVER_NAME=$(profile_get "$profile_id" server_name)
XRAY_SHORT_ID=$(profile_get "$profile_id" short_id)
XRAY_PRIVATE_KEY=$(profile_get "$profile_id" private_key)
XRAY_PUBLIC_KEY=$(profile_get "$profile_id" public_key)
XRAY_FLOW=$(profile_get "$profile_id" flow)
EOF
}

remote_install_support() {
	local profile_id="$1"
	local cache="$2"
	local vps_profile label os_id os_version pkg_mgr systemd arch xray_present
	local expected_os_id expected_os_version expected_pkg expected_systemd expected_arch
	local supported='0'
	local notes='Selected VPS profile is not ready for automatic install.'

	vps_profile="$(normalize_vps_profile "$(profile_get "$profile_id" vps_profile)")"
	label="$(vps_profile_value "$vps_profile" VPS_PROFILE_LABEL)"
	expected_os_id="$(vps_profile_value "$vps_profile" VPS_OS_ID)"
	expected_os_version="$(vps_profile_value "$vps_profile" VPS_OS_VERSION_PREFIX)"
	expected_pkg="$(vps_profile_value "$vps_profile" VPS_REQUIRED_PKG_MGR)"
	expected_systemd="$(vps_profile_value "$vps_profile" VPS_REQUIRES_SYSTEMD)"
	expected_arch="$(vps_profile_value "$vps_profile" VPS_SUPPORTED_ARCH_REGEX)"

	os_id="$(cache_get "$cache" REMOTE_OS_ID)"
	os_version="$(cache_get "$cache" REMOTE_OS_VERSION)"
	pkg_mgr="$(cache_get "$cache" REMOTE_PKG_MGR)"
	systemd="$(cache_get "$cache" REMOTE_SYSTEMD)"
	arch="$(cache_get "$cache" REMOTE_ARCH)"
	xray_present="$(cache_get "$cache" REMOTE_XRAY_PRESENT)"

	if [ "$xray_present" = '1' ]; then
		supported='1'
		notes='Xray already installed on the selected VPS.'
	elif [ -n "$expected_os_id" ] && [ "$os_id" != "$expected_os_id" ]; then
		notes="Selected VPS profile expects ${label:-$vps_profile}; remote host reports ${os_id:-unknown}."
	elif [ -n "$expected_os_version" ] && [ "${os_version#${expected_os_version}}" = "$os_version" ]; then
		notes="Selected VPS profile expects version ${expected_os_version}*; remote host reports ${os_version:-unknown}."
	elif [ -n "$expected_pkg" ] && [ "$pkg_mgr" != "$expected_pkg" ]; then
		notes="Selected VPS profile expects package manager ${expected_pkg}; remote host reports ${pkg_mgr:-unknown}."
	elif [ "$expected_systemd" = '1' ] && [ "$systemd" != '1' ]; then
		notes='Selected VPS profile requires systemd.'
	elif [ -n "$expected_arch" ] && ! printf '%s' "$arch" | grep -Eq "$expected_arch"; then
		notes="Selected VPS profile expects architecture matching ${expected_arch}; remote host reports ${arch:-unknown}."
	else
		supported='1'
		notes="Automatic install path available for ${label:-$vps_profile}."
	fi

	printf '%s|%s|%s|%s\n' "$vps_profile" "${label:-$vps_profile}" "$supported" "$notes"
}

profile_diff_fields() {
	local profile_id="$1"
	local source="$2"
	local diffs=''
	local keys key expected actual

	if [ "$source" = 'router' ]; then
		keys='server_address server_port server_name uuid public_key short_id flow'
	else
		keys='server_port server_name uuid public_key short_id flow'
	fi

	for key in $keys; do
		expected="$(profile_get "$profile_id" "$key")"
		if [ "$source" = 'router' ]; then
			actual="$(router_live_value "$key")"
		else
			actual="$(cache_get "$(profile_cache_path "$profile_id")" "REMOTE_${key}")"
		fi
		[ "$expected" = "$actual" ] || diffs="${diffs}${key},"
	done

	printf '%s' "${diffs%,}"
}

install_command_for_profile() {
	local profile_id="$1"
	local pub escaped

	pub="$(profile_get "$profile_id" managed_pubkey)"
	escaped="$(printf '%s' "$pub" | sed "s/'/'\\\\''/g")"
	printf "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%%s\\n' '%s' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" "$escaped"
}

remote_cache_json() {
	local cache_path="$1"
	printf '{'
	printf '"status":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_STATUS)")"
	printf '"ssh_ok":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_SSH_OK)")"
	printf '"hostname":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_HOSTNAME)")"
	printf '"fqdn":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_FQDN)")"
	printf '"kernel":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_KERNEL)")"
	printf '"arch":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_ARCH)")"
	printf '"pretty_name":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_PRETTY_NAME)")"
	printf '"os_id":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_OS_ID)")"
	printf '"os_version":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_OS_VERSION)")"
	printf '"virt":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_VIRT)")"
	printf '"systemd":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_SYSTEMD)")"
	printf '"pkg_mgr":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_PKG_MGR)")"
	printf '"install_profile":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_INSTALL_PROFILE)")"
	printf '"install_label":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_INSTALL_LABEL)")"
	printf '"install_supported":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_INSTALL_SUPPORTED)")"
	printf '"install_notes":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_INSTALL_NOTES)")"
	printf '"memory":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_MEMORY)")"
	printf '"disk_root":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_DISK_ROOT)")"
	printf '"uptime":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_UPTIME)")"
	printf '"public_ip":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_PUBLIC_IP)")"
	printf '"ipinfo_json":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_IPINFO_JSON)")"
	printf '"xray_present":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_XRAY_PRESENT)")"
	printf '"xray_version":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_XRAY_VERSION)")"
	printf '"xray_service":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_XRAY_SERVICE)")"
	printf '"listener_port":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_LISTENER_PORT)")"
	printf '"listener_443":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_LISTENER_443)")"
	printf '"managed_meta":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_MANAGED_META)")"
	printf '"server_port":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_server_port)")"
	printf '"server_name":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_server_name)")"
	printf '"uuid":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_uuid)")"
	printf '"public_key":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_public_key)")"
	printf '"short_id":"%s",' "$(json_escape "$(cache_get "$cache_path" REMOTE_short_id)")"
	printf '"flow":"%s"' "$(json_escape "$(cache_get "$cache_path" REMOTE_flow)")"
	printf '}'
}

profile_json() {
	local profile_id="$1"
	local cache_path managed_path bootstrap_path managed_present bootstrap_present router_diff remote_diff endpoint_host

	cache_path="$(profile_cache_path "$profile_id")"
	managed_path="$(profile_get "$profile_id" managed_key_path)"
	bootstrap_path="$(profile_get "$profile_id" bootstrap_key_path)"
	[ -n "$managed_path" ] && [ -f "$managed_path" ] && managed_present=1 || managed_present=0
	[ -n "$bootstrap_path" ] && [ -f "$bootstrap_path" ] && bootstrap_present=1 || bootstrap_present=0
	router_diff="$(profile_diff_fields "$profile_id" router)"
	remote_diff="$(profile_diff_fields "$profile_id" remote)"
	endpoint_host="$(profile_get "$profile_id" server_address)"
	[ -n "$endpoint_host" ] || endpoint_host="$(profile_get "$profile_id" ssh_host)"

	printf '{'
	printf '"id":"%s",' "$(json_escape "$profile_id")"
	printf '"label":"%s",' "$(json_escape "$(profile_get "$profile_id" label)")"
	printf '"vps_profile":"%s",' "$(json_escape "$(normalize_vps_profile "$(profile_get "$profile_id" vps_profile)")")"
	printf '"auth_mode":"%s",' "$(json_escape "$(profile_get "$profile_id" auth_mode)")"
	printf '"endpoint_host":"%s",' "$(json_escape "$endpoint_host")"
	printf '"ssh_host":"%s",' "$(json_escape "$(profile_get "$profile_id" ssh_host)")"
	printf '"ssh_port":"%s",' "$(json_escape "$(profile_get "$profile_id" ssh_port)")"
	printf '"ssh_user":"%s",' "$(json_escape "$(profile_get "$profile_id" ssh_user)")"
	printf '"server_address":"%s",' "$(json_escape "$(profile_get "$profile_id" server_address)")"
	printf '"server_port":"%s",' "$(json_escape "$(profile_get "$profile_id" server_port)")"
	printf '"server_name":"%s",' "$(json_escape "$(profile_get "$profile_id" server_name)")"
	printf '"uuid":"%s",' "$(json_escape "$(profile_get "$profile_id" uuid)")"
	printf '"public_key":"%s",' "$(json_escape "$(profile_get "$profile_id" public_key)")"
	printf '"short_id":"%s",' "$(json_escape "$(profile_get "$profile_id" short_id)")"
	printf '"flow":"%s",' "$(json_escape "$(profile_get "$profile_id" flow)")"
	printf '"managed_key_path":"%s",' "$(json_escape "$managed_path")"
	printf '"managed_pubkey":"%s",' "$(json_escape "$(profile_get "$profile_id" managed_pubkey)")"
	printf '"managed_key_present":'; json_bool "$managed_present"; printf ','
	printf '"bootstrap_key_present":'; json_bool "$bootstrap_present"; printf ','
	printf '"last_inspect_status":"%s",' "$(json_escape "$(profile_get "$profile_id" last_inspect_status)")"
	printf '"last_inspect_at":"%s",' "$(json_escape "$(profile_get "$profile_id" last_inspect_at)")"
	printf '"router_diff":"%s",' "$(json_escape "$router_diff")"
	printf '"remote_diff":"%s",' "$(json_escape "$remote_diff")"
	printf '"remote_cache":'
	remote_cache_json "$cache_path"
	printf '}'
}

profiles_json() {
	local first=1 profile_id
	printf '['
	for profile_id in $(profile_ids); do
		[ "$first" = '1' ] || printf ','
		first=0
		profile_json "$profile_id"
	done
	printf ']'
}

status_json() {
	local active
	active="$(active_profile_id)"
	printf '{'
	printf '"ok":true,'
	printf '"active_profile_id":"%s",' "$(json_escape "$active")"
	printf '"vps_profiles":'
	vps_profiles_json
	printf ','
	printf '"router_current":'
	router_current_json
	printf ','
	printf '"profiles":'
	profiles_json
	printf '}'
}

ensure_profile_store() {
	local active profile_id

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
ipinfo_v="$(curl -4fsS https://ipinfo.io/json 2>/dev/null | tr -d '\n' || true)"
public_ip_v="$(curl -4fsS https://api.ipify.org 2>/dev/null || true)"
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

server_name = ''
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
	while [ "$tries" -lt 8 ]; do
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

save_profile_from_request() {
	local current requested_id profile_id label vps_profile auth_mode ssh_host ssh_port ssh_user server_address server_port server_name existing_server_name uuid public_key private_key short_id flow bootstrap_key

	SAVE_PROFILE_ERROR=''
	SAVE_PROFILE_ID=''

	current="$(active_profile_id)"
	requested_id="$(sanitize_id "$(request_value profile_id)")"
	[ -n "$requested_id" ] || requested_id="$current"
	profile_id="$requested_id"
	label="$(request_value label)"
	vps_profile="$(normalize_vps_profile "$(request_value vps_profile)")"
	auth_mode="$(request_value auth_mode)"
	ssh_host="$(request_value ssh_host)"
	ssh_port="$(request_value ssh_port)"
	ssh_user="$(request_value ssh_user)"
	server_address="$(request_value server_address)"
	server_port="$(request_value server_port)"
	server_name="$(request_value server_name)"
	uuid="$(request_value uuid)"
	public_key="$(request_value public_key)"
	private_key="$(request_value private_key)"
	short_id="$(request_value short_id)"
	flow="$(request_value flow)"
	bootstrap_key="$(request_value bootstrap_private_key)"
	[ -n "$label" ] || label='VPS Profile'
	[ -n "$vps_profile" ] || vps_profile="$(normalize_vps_profile "$(profile_get "$profile_id" vps_profile)")"
	[ -n "$auth_mode" ] || auth_mode="$(profile_get "$profile_id" auth_mode)"
	[ -n "$auth_mode" ] || auth_mode='managed_key'
	[ -n "$ssh_host" ] || ssh_host="$server_address"
	[ -n "$server_address" ] || server_address="$ssh_host"
	[ -n "$ssh_port" ] || ssh_port='22'
	[ -n "$ssh_user" ] || ssh_user='root'
	[ -n "$server_port" ] || server_port='443'
	valid_port "$ssh_port" || {
		save_profile_fail 'SSH port must be in the range 1-65535.'
		return 1
	}
	valid_port "$server_port" || {
		save_profile_fail 'Xray server port must be in the range 1-65535.'
		return 1
	}
	existing_server_name="$(profile_get "$profile_id" server_name)"
	[ -n "$server_name" ] || server_name="$existing_server_name"
	[ -n "$server_name" ] || server_name="$(default_server_name_for_profile "$vps_profile")"

	if ! profile_exists "$profile_id"; then
		uci -q set "${PROFILE_PACKAGE}.${profile_id}=profile"
		profile_set "$profile_id" last_inspect_status 'never'
		profile_set "$profile_id" last_inspect_at ''
	fi

	profile_set "$profile_id" label "$label"
	profile_set "$profile_id" vps_profile "$vps_profile"
	profile_set "$profile_id" auth_mode "$auth_mode"
	profile_set "$profile_id" ssh_host "$ssh_host"
	profile_set "$profile_id" ssh_port "$ssh_port"
	profile_set "$profile_id" ssh_user "$ssh_user"
	profile_set "$profile_id" server_address "$server_address"
	profile_set "$profile_id" server_port "$server_port"
	profile_set "$profile_id" server_name "$server_name"
	[ -n "$uuid" ] && profile_set "$profile_id" uuid "$uuid" || profile_del "$profile_id" uuid
	[ -n "$public_key" ] && profile_set "$profile_id" public_key "$public_key" || profile_del "$profile_id" public_key
	[ -n "$private_key" ] && profile_set "$profile_id" private_key "$private_key" || true
	[ -n "$short_id" ] && profile_set "$profile_id" short_id "$short_id" || profile_del "$profile_id" short_id
	profile_set "$profile_id" flow "$flow"
	profile_set "$profile_id" managed_key_path "${KEY_DIR}/${profile_id}_ed25519"
	profile_set "$profile_id" bootstrap_key_path "${KEY_DIR}/${profile_id}_bootstrap"
	profile_del "$profile_id" ssh_password

	ensure_profile_material "$profile_id"
	if ! ensure_profile_keypair "$profile_id"; then
		return 1
	fi
	save_bootstrap_key "$profile_id" "$bootstrap_key"
	set_active_profile "$profile_id"
	uci commit "$PROFILE_PACKAGE"
	SAVE_PROFILE_ID="$profile_id"
	printf '%s' "$profile_id"
}

create_profile_action() {
	local base profile_id suffix

	base="vps_$(date +%Y%m%d_%H%M%S)"
	profile_id="$base"
	suffix=1
	while profile_exists "$profile_id"; do
		profile_id="${base}_${suffix}"
		suffix=$((suffix + 1))
	done

	uci -q set "${PROFILE_PACKAGE}.${profile_id}=profile"
	profile_set "$profile_id" label 'New VPS'
	profile_set "$profile_id" vps_profile "$(default_vps_profile)"
	profile_set "$profile_id" auth_mode 'password'
	profile_set "$profile_id" ssh_host ''
	profile_set "$profile_id" ssh_port '22'
	profile_set "$profile_id" ssh_user 'root'
	profile_set "$profile_id" server_address ''
	profile_set "$profile_id" server_port '443'
	profile_set "$profile_id" server_name "$(default_server_name_for_profile "$(default_vps_profile)")"
	profile_set "$profile_id" flow ''
	profile_del "$profile_id" ssh_password
	profile_set "$profile_id" private_key ''
	profile_set "$profile_id" managed_key_path "${KEY_DIR}/${profile_id}_ed25519"
	profile_set "$profile_id" bootstrap_key_path "${KEY_DIR}/${profile_id}_bootstrap"
	profile_set "$profile_id" managed_pubkey ''
	profile_set "$profile_id" last_inspect_status 'never'
	profile_set "$profile_id" last_inspect_at ''
	ensure_profile_material "$profile_id"
	if ! ensure_profile_keypair "$profile_id"; then
		emit_error create_profile 'Router could not generate profile key pair.'
		return 0
	fi
	set_active_profile "$profile_id"
	uci commit "$PROFILE_PACKAGE"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"create_profile",'
	printf '"created_profile_id":"%s",' "$(json_escape "$profile_id")"
	printf '"status":'
	status_json
	printf '}'
}

save_profile_action() {
	if ! save_profile_from_request >/dev/null; then
		emit_error save_profile "${SAVE_PROFILE_ERROR:-Router could not initialize profile material.}"
		return 0
	fi
	emit_status_response save_profile
}

ensure_sshpass_available() {
	command -v sshpass >/dev/null 2>&1 && return 0
	with_lock_dir "$LOCK_ROOT/opkg.lock.d" sh -c '
		command -v sshpass >/dev/null 2>&1 && exit 0
		rm -f /var/lock/opkg.lock
		timeout 60 opkg update >/tmp/xray-vps-opkg-update.log 2>&1 || exit 1
		timeout 60 opkg install sshpass >/tmp/xray-vps-opkg-install.log 2>&1 || exit 1
	' >/dev/null 2>&1 || return 1
	command -v sshpass >/dev/null 2>&1
}

install_managed_key_via_current_auth() {
	local profile_id="$1"
	local pub tmp_pub remote_cmd

	pub="$(profile_get "$profile_id" managed_pubkey)"
	tmp_pub="/tmp/xray-managed-key.$$"
	printf '%s\n' "$pub" > "$tmp_pub"
	remote_cmd="sh -c 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; PUB=\$(cat); grep -qxF \"\$PUB\" ~/.ssh/authorized_keys || printf \"%s\n\" \"\$PUB\" >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'"
	ssh_stdin_cmd "$profile_id" "$remote_cmd" "$tmp_pub" >/dev/null 2>&1 || {
		rm -f "$tmp_pub"
		return 1
	}
	rm -f "$tmp_pub"
	profile_set "$profile_id" auth_mode 'managed_key'
	profile_del "$profile_id" ssh_password
	uci commit "$PROFILE_PACKAGE"
	return 0
}

install_managed_key_with_password() {
	local profile_id="$1"
	local host port user password pub tmp_pub

	ensure_sshpass_available || return 1
	host="$(profile_get "$profile_id" ssh_host)"
	port="$(profile_get "$profile_id" ssh_port)"
	user="$(profile_get "$profile_id" ssh_user)"
	password="$(request_value ssh_password)"
	[ -n "$password" ] || password="$(profile_get "$profile_id" ssh_password)"
	pub="$(profile_get "$profile_id" managed_pubkey)"

	[ -n "$host" ] || return 1
	[ -n "$user" ] || user='root'
	[ -n "$port" ] || port='22'
	[ -n "$password" ] || return 1

	tmp_pub="/tmp/xray-managed-key-pass.$$"
	printf '%s\n' "$pub" > "$tmp_pub"
	SSHPASS="$password" sshpass -e ssh \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o ConnectTimeout=8 \
		-p "$port" \
		"$user@$host" \
		"sh -c 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; PUB=\$(cat); grep -qxF \"\$PUB\" ~/.ssh/authorized_keys || printf \"%s\n\" \"\$PUB\" >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'" \
		< "$tmp_pub" >/dev/null 2>&1 || {
			rm -f "$tmp_pub"
			return 1
		}
	rm -f "$tmp_pub"
	profile_set "$profile_id" auth_mode 'managed_key'
	profile_del "$profile_id" ssh_password
	uci commit "$PROFILE_PACKAGE"
	return 0
}

ensure_ssh_ready() {
	local profile_id="$1"
	local mode

	if ssh_works "$profile_id"; then
		profile_set "$profile_id" auth_mode 'managed_key'
		profile_del "$profile_id" ssh_password
		uci commit "$PROFILE_PACKAGE"
		return 0
	fi

	mode="$(profile_get "$profile_id" auth_mode)"
	case "$mode" in
		password)
			install_managed_key_with_password "$profile_id" || return 1
			;;
		private_key|key)
			install_managed_key_via_current_auth "$profile_id" || return 1
			;;
		managed_key|'')
			return 1
			;;
	esac

	ssh_works "$profile_id"
}

inspect_profile_ready() {
	local profile_id="$1"
	ensure_ssh_ready "$profile_id" || return 1
	refresh_remote_cache "$profile_id"
}

inspect_profile_retry_locked() {
	local profile_id="$1"
	local attempts="$2"
	local delay="$3"
	local try=1

	while [ "$try" -le "$attempts" ]; do
		if inspect_profile_ready "$profile_id"; then
			return 0
		fi
		[ "$try" -lt "$attempts" ] && sleep "$delay"
		try=$((try + 1))
	done
	return 1
}

inspect_profile_with_retry() {
	local profile_id="$1"
	local attempts="${2:-3}"
	local delay="${3:-1}"

	with_lock_dir "$LOCK_ROOT/inspect.lock.d" inspect_profile_retry_locked "$profile_id" "$attempts" "$delay"
}

adopt_remote_into_profile() {
	local profile_id="$1"
	local cache value remote_value

	cache="$(profile_cache_path "$profile_id")"
	for value in server_port server_name uuid public_key short_id flow; do
		remote_value="$(cache_get "$cache" "REMOTE_${value}")"
		[ -n "$remote_value" ] && profile_set "$profile_id" "$value" "$remote_value"
	done
	remote_value="$(private_cache_get "$profile_id")"
	[ -n "$remote_value" ] && profile_set "$profile_id" private_key "$remote_value"
	profile_set "$profile_id" last_inspect_status 'ok'
	uci commit "$PROFILE_PACKAGE"
}

adopt_vps_action() {
	local profile_id

	profile_id="$(active_profile_id)"
	if profile_cache_fresh "$profile_id" 120; then
		adopt_remote_into_profile "$profile_id"
		emit_status_response adopt_vps
		return 0
	fi

	if ! inspect_profile_with_retry "$profile_id" 3 1; then
		emit_error adopt_vps 'Router cannot inspect the selected VPS yet.'
		return 0
	fi

	adopt_remote_into_profile "$profile_id"
	emit_status_response adopt_vps
}

select_profile_action() {
	local profile_id

	profile_id="$(sanitize_id "$(request_value profile_id)")"
	if ! profile_exists "$profile_id"; then
		emit_error select_profile 'Profile not found.'
		return 0
	fi

	set_active_profile "$profile_id"
	uci commit "$PROFILE_PACKAGE"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"select_profile",'
	printf '"status":'
	status_json
	printf '}'
}

generate_key_action() {
	local profile_id

	profile_id="$(active_profile_id)"
	if ! ensure_profile_keypair "$profile_id"; then
		emit_error generate_key 'Router could not generate SSH key pair.'
		return 0
	fi
	uci commit "$PROFILE_PACKAGE"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"generate_key",'
	printf '"status":'
	status_json
	printf '}'
}

install_key_action() {
	local profile_id

	profile_id="$(active_profile_id)"
	if ! ensure_profile_keypair "$profile_id"; then
		emit_error install_key 'Router could not prepare SSH key pair.'
		return 0
	fi
	uci commit "$PROFILE_PACKAGE"

	if ! ensure_ssh_ready "$profile_id"; then
		emit_error install_key 'Router could not establish SSH to the selected VPS with the current auth settings.'
		return 0
	fi

	emit_status_response install_key
}

inspect_action() {
	local profile_id

	profile_id="$(active_profile_id)"
	if ! inspect_profile_with_retry "$profile_id" 3 1; then
		emit_error inspect_vps 'Router cannot SSH into the selected VPS yet or remote inspection failed.'
		return 0
	fi

	emit_status_response inspect_vps
}

check_profile_action() {
	local profile_id backup

	backup="$(backup_profile_store)"
	if ! save_profile_from_request >/dev/null; then
		restore_profile_store "$backup"
		emit_error check_profile "${SAVE_PROFILE_ERROR:-Could not save profile settings before inspection.}"
		return 0
	fi
	profile_id="$SAVE_PROFILE_ID"
	if ! inspect_profile_with_retry "$profile_id" 3 1; then
		restore_profile_store "$backup"
		emit_error check_profile 'Router could not establish SSH to the selected VPS with the current auth settings.'
		return 0
	fi

	if [ "$(cache_get "$(profile_cache_path "$profile_id")" REMOTE_XRAY_PRESENT)" = '1' ]; then
		adopt_remote_into_profile "$profile_id"
	fi

	drop_profile_store_backup "$backup"
	emit_status_response check_profile
}

apply_profile_to_router_internal() {
	local profile_id="$1"
	local rendered backup test_output

	ensure_profile_material "$profile_id"
	uci commit "$PROFILE_PACKAGE"

	rendered='/tmp/codex-xray.profile.json'
	render_router_config "$rendered" "$profile_id"
	test_output="$("$ROUTER_XRAY_BIN" run -test -config "$rendered" 2>&1 || true)"
	printf '%s' "$test_output" | grep -q 'Configuration OK.' || {
		rm -f "$rendered"
		return 1
	}

	backup="${ROUTER_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
	if [ -f "$ROUTER_CONFIG" ]; then
		cp "$ROUTER_CONFIG" "$backup"
	else
		backup=''
	fi
	mv "$rendered" "$ROUTER_CONFIG"
	chmod 600 "$ROUTER_CONFIG"
	touch "$ROUTER_READY_FILE"
	chmod 600 "$ROUTER_READY_FILE"
	/etc/init.d/codex-transproxy stop >/dev/null 2>&1 || true
	/etc/init.d/codex-xray stop >/dev/null 2>&1 || true
	sleep 1
	resync_runtime_to_switch || return 1
	printf '%s' "$backup"
}

apply_profile_to_router_action() {
	local profile_id backup

	profile_id="$(active_profile_id)"
	backup="$(apply_profile_to_router_internal "$profile_id")" || {
		emit_error apply_router 'Rendered router config failed validation or could not be applied.'
		return 0
	}

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"apply_router",'
	printf '"backup":"%s",' "$(json_escape "$backup")"
	printf '"status":'
	status_json
	printf '}'
}

setup_vps_internal() {
	local profile_id="$1"
	local rendered meta rendered_install vps_profile install_script_rel install_script_path remote_meta_path

	if [ -z "$(profile_get "$profile_id" private_key)" ]; then
		return 1
	fi

	if ! ensure_ssh_ready "$profile_id"; then
		return 1
	fi

	vps_profile="$(selected_vps_profile "$profile_id")"
	install_script_rel="$(vps_profile_value "$vps_profile" VPS_INSTALL_SCRIPT)"
	install_script_path="$(vps_profile_file_path "$vps_profile" "$install_script_rel")"
	remote_meta_path="$(vps_profile_value "$vps_profile" VPS_REMOTE_META_PATH)"
	[ -f "$install_script_path" ] || return 1
	[ -n "$remote_meta_path" ] || remote_meta_path='/usr/local/etc/xray/codex-router-meta.env'

	rendered='/tmp/codex-router-vps-config.json'
	meta='/tmp/codex-router-vps-meta.env'
	rendered_install='/tmp/codex-router-install.remote.sh'
	render_server_config "$rendered" "$profile_id"
	render_remote_meta "$meta" "$profile_id"
	render_vps_profile_template "$profile_id" "$install_script_path" "$rendered_install"

	ssh_stdin_cmd "$profile_id" 'cat > /tmp/codex-router-vps-config.json' "$rendered" >/dev/null 2>&1 || {
		rm -f "$rendered" "$meta" "$rendered_install"
		return 1
	}
	ssh_stdin_cmd "$profile_id" 'cat > /tmp/codex-router-meta.env' "$meta" >/dev/null 2>&1 || {
		rm -f "$rendered" "$meta" "$rendered_install"
		return 1
	}
	ssh_stdin_cmd "$profile_id" 'cat > /tmp/install-vps.remote.sh && chmod 755 /tmp/install-vps.remote.sh' "$rendered_install" >/dev/null 2>&1 || {
		rm -f "$rendered" "$meta" "$rendered_install"
		return 1
	}

	ssh_cmd "$profile_id" "VPS_REMOTE_META_PATH='$remote_meta_path' sh /tmp/install-vps.remote.sh" >/dev/null 2>&1 || {
		rm -f "$rendered" "$meta" "$rendered_install"
		return 1
	}

	rm -f "$rendered" "$meta" "$rendered_install"
	refresh_remote_cache "$profile_id" >/dev/null 2>&1 || true
	return 0
}

setup_vps_action() {
	local profile_id

	profile_id="$(active_profile_id)"
	setup_vps_internal "$profile_id" || {
		emit_error setup_vps 'Failed to install or sync VPS Xray config.'
		return 0
	}

	emit_status_response setup_vps
}

apply_everything_action() {
	local profile_id cache remote_xray_present remote_managed_meta requested_material

	if ! save_profile_from_request >/dev/null; then
		emit_error apply_profile "${SAVE_PROFILE_ERROR:-Router could not initialize profile settings.}"
		return 0
	fi
	profile_id="$SAVE_PROFILE_ID"
	requested_material="$(request_value uuid)$(request_value public_key)$(request_value private_key)$(request_value short_id)"

	if [ -z "$requested_material" ]; then
		if ! inspect_profile_with_retry "$profile_id" 3 1; then
			emit_error apply_profile 'Router could not establish SSH to the selected VPS with the current auth settings.'
			return 0
		fi

		cache="$(profile_cache_path "$profile_id")"
		remote_xray_present="$(cache_get "$cache" REMOTE_XRAY_PRESENT)"
		remote_managed_meta="$(cache_get "$cache" REMOTE_MANAGED_META)"

		if [ "$remote_xray_present" = '1' ] && [ -z "$(profile_get "$profile_id" private_key)" ]; then
			adopt_remote_into_profile "$profile_id"
		elif [ "$remote_xray_present" = '1' ] && [ "$remote_managed_meta" != '1' ]; then
			adopt_remote_into_profile "$profile_id"
			apply_profile_to_router_internal "$profile_id" >/dev/null || {
				emit_error apply_profile 'VPS was detected and adopted, but applying the router profile failed.'
				return 0
			}
			emit_status_response apply_profile
			return 0
		fi
	fi

	setup_vps_internal "$profile_id" || {
		emit_error apply_profile 'Failed to sync the selected VPS.'
		return 0
	}
	apply_profile_to_router_internal "$profile_id" >/dev/null || {
		emit_error apply_profile 'VPS was synced, but applying the profile to the router failed.'
		return 0
	}

	emit_status_response apply_profile
}

REQUEST_DATA="$(load_request_data)"
ensure_profile_store

case "$(request_value action)" in
	''|status)
		emit_header
		status_json
		;;
	save_profile)
		save_profile_action
		;;
	select_profile)
		select_profile_action
		;;
	create_profile)
		create_profile_action
		;;
	generate_key)
		generate_key_action
		;;
	install_key)
		install_key_action
		;;
	inspect_vps)
		inspect_action
		;;
	check_profile)
		check_profile_action
		;;
	adopt_vps)
		adopt_vps_action
		;;
	apply_router)
		apply_profile_to_router_action
		;;
	setup_vps)
		setup_vps_action
		;;
	apply_profile)
		apply_everything_action
		;;
	*)
		emit_error "$(request_value action)" 'Unknown action.'
		;;
esac
