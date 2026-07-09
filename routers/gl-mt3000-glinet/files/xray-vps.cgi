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
SWITCH_SYNC_WAIT_SECONDS='25'
SAVE_PROFILE_ERROR=''
SAVE_PROFILE_ID=''

REQUEST_DATA=''

VX_CONFIG="$ROUTER_CONFIG"
VX_CONFIG_READY="$ROUTER_READY_FILE"
. "${VX_LIB_COMMON:-/usr/share/vpn-xray/lib-common.sh}"

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

router_current_json() {
	local ready _rc_sa _rc_sp _rc_sn _rc_uu _rc_pk _rc_si _rc_fl
	router_config_ready && ready=1 || ready=0
	eval "$(jsonfilter -i "$ROUTER_CONFIG" \
		-e '_rc_sa=@.outbounds[0].settings.vnext[0].address' \
		-e '_rc_sp=@.outbounds[0].settings.vnext[0].port' \
		-e '_rc_sn=@.outbounds[0].streamSettings.realitySettings.serverName' \
		-e '_rc_uu=@.outbounds[0].settings.vnext[0].users[0].id' \
		-e '_rc_pk=@.outbounds[0].streamSettings.realitySettings.publicKey' \
		-e '_rc_si=@.outbounds[0].streamSettings.realitySettings.shortId' \
		-e '_rc_fl=@.outbounds[0].settings.vnext[0].users[0].flow' \
		2>/dev/null)" 2>/dev/null || true
	printf '{'
	printf '"config_ready":'; json_bool "$ready"; printf ','
	printf '"server_address":"%s",' "$(json_escape "${_rc_sa:-}")"
	printf '"server_port":"%s",' "$(json_escape "${_rc_sp:-}")"
	printf '"server_name":"%s",' "$(json_escape "${_rc_sn:-}")"
	printf '"uuid":"%s",' "$(json_escape "${_rc_uu:-}")"
	printf '"public_key":"%s",' "$(json_escape "${_rc_pk:-}")"
	printf '"short_id":"%s",' "$(json_escape "${_rc_si:-}")"
	printf '"flow":"%s"' "$(json_escape "${_rc_fl:-}")"
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
	shift 2
	with_flock "${lock_dir%.lock.d}.flock" 60 "$cmd" "$@"
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

	# ConnectionAttempts=3 handles intermittent SYN loss on WiFi repeater
	# uplinks (the GL.iNet apcli0 case). ServerAliveInterval keeps the
	# session alive when the pipeline uploads large files afterwards.
	# When SSH_RAW_LOG_PATH is set (repair pipeline sets it to a file),
	# stderr is appended to that file so the CGI can surface the actual
	# OpenSSH error to the operator instead of hiding it behind a generic
	# error. We can't use an fd here because fcgiwrap keeps fd 3+ busy
	# for its FastCGI protocol channel.
	if [ -n "${SSH_RAW_LOG_PATH:-}" ]; then
		ssh -i "$identity" \
			-o BatchMode=yes \
			-o ConnectTimeout=6 \
			-o ConnectionAttempts=2 \
			-o ServerAliveInterval=15 \
			-o ServerAliveCountMax=4 \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile="$KNOWN_HOSTS" \
			-p "$port" \
			"$user@$host" "$cmd" 2>>"$SSH_RAW_LOG_PATH"
	else
		ssh -i "$identity" \
			-o BatchMode=yes \
			-o ConnectTimeout=6 \
			-o ConnectionAttempts=2 \
			-o ServerAliveInterval=15 \
			-o ServerAliveCountMax=4 \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile="$KNOWN_HOSTS" \
			-p "$port" \
			"$user@$host" "$cmd"
	fi
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

	if [ -n "${SSH_RAW_LOG_PATH:-}" ]; then
		ssh -i "$identity" \
			-o BatchMode=yes \
			-o ConnectTimeout=6 \
			-o ConnectionAttempts=2 \
			-o ServerAliveInterval=15 \
			-o ServerAliveCountMax=4 \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile="$KNOWN_HOSTS" \
			-p "$port" \
			"$user@$host" "$remote_cmd" < "$stdin_path" 2>>"$SSH_RAW_LOG_PATH"
	else
		ssh -i "$identity" \
			-o BatchMode=yes \
			-o ConnectTimeout=6 \
			-o ConnectionAttempts=2 \
			-o ServerAliveInterval=15 \
			-o ServerAliveCountMax=4 \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile="$KNOWN_HOSTS" \
			-p "$port" \
			"$user@$host" "$remote_cmd" < "$stdin_path"
	fi
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
	# Wrapper retry for the WiFi-repeater burst rate-limit (apcli0 on
	# GL.iNet, DIAGNOSTIC-TREE 3.4): a rejected/dropped SYN in a burst
	# looks like a failure, but a spaced retry succeeds. ssh's own
	# ConnectionAttempts handles in-invocation SYN loss; this wrapper
	# handles the "refused after too many recent connects" case. Two
	# attempts with a 2s gap bounds worst-case latency — a broken key
	# returns Permission denied immediately, so only genuine timeouts
	# cost the full ConnectTimeout — while still absorbing a single
	# burst rejection.
	local i=0
	while [ "$i" -lt 2 ]; do
		if ssh_cmd "$1" 'echo ok' >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		[ "$i" -lt 2 ] && sleep 2
	done
	return 1
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
      "settings": {},
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${ROUTER_SOCKS_PORT},
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": false
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
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
          "fingerprint": "edge",
          "serverName": "${server_name}",
          "publicKey": "${public_key}",
          "shortId": "${short_id}",
          "spiderX": "/"
        }
      },
      "mux": {
        "enabled": true,
        "concurrency": 8,
        "xudpConcurrency": -1
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
	local vps_tls_cert_path vps_tls_key_path xray_ws_path
	local xray_client_flow_block

	vps_profile="$(selected_vps_profile "$profile_id")"
	xray_port="$(profile_get "$profile_id" server_port)"
	[ -n "$xray_port" ] || xray_port='24443'
	# WS path must match what the router dials. Track it on the profile;
	# default to the stack's install default (/cdn) so a config is never
	# rendered with the literal ${XRAY_WS_PATH} placeholder (which passes
	# `xray -test` but silently breaks the tunnel because the server then
	# expects a path of exactly "${XRAY_WS_PATH}").
	xray_ws_path="$(profile_get "$profile_id" ws_path)"
	[ -n "$xray_ws_path" ] || xray_ws_path='/cdn'
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
	# TLS paths MUST be substituted: install-vps.remote.sh does a
	# `chown -R` on dirname(TLS_CERT_PATH). If left as the literal
	# ${VPS_TLS_CERT_PATH}, dirname is "." and the chown lands on the
	# SSH working directory (/root) — the 2026-07-09 corruption. Default
	# to the profile.env values so a missing profile field cannot produce
	# a relative path.
	vps_tls_cert_path="$(vps_profile_value "$vps_profile" VPS_TLS_CERT_PATH)"
	vps_tls_key_path="$(vps_profile_value "$vps_profile" VPS_TLS_KEY_PATH)"
	[ -n "$vps_tls_cert_path" ] || vps_tls_cert_path="${vps_xray_config_dir%/}/certs/server.crt"
	[ -n "$vps_tls_key_path" ] || vps_tls_key_path="${vps_xray_config_dir%/}/certs/server.key"
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
		-e "s|\${VPS_TLS_CERT_PATH}|$(template_escape "$vps_tls_cert_path")|g" \
		-e "s|\${VPS_TLS_KEY_PATH}|$(template_escape "$vps_tls_key_path")|g" \
		-e "s|\${XRAY_WS_PATH}|$(template_escape "$xray_ws_path")|g" \
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
	if [ ! -f "$cache_path" ]; then
		printf '{"status":"","ssh_ok":"","hostname":"","fqdn":"","kernel":"","arch":"","pretty_name":"","os_id":"","os_version":"","virt":"","systemd":"","pkg_mgr":"","install_profile":"","install_label":"","install_supported":"","install_notes":"","memory":"","disk_root":"","uptime":"","public_ip":"","ipinfo_json":"","xray_present":"","xray_version":"","xray_service":"","listener_port":"","listener_443":"","managed_meta":"","server_port":"","server_name":"","uuid":"","public_key":"","short_id":"","flow":""}'
		return 0
	fi
	awk '
	BEGIN {
		FS="="
		ORS=""
		split("REMOTE_STATUS status REMOTE_SSH_OK ssh_ok REMOTE_HOSTNAME hostname REMOTE_FQDN fqdn REMOTE_KERNEL kernel REMOTE_ARCH arch REMOTE_PRETTY_NAME pretty_name REMOTE_OS_ID os_id REMOTE_OS_VERSION os_version REMOTE_VIRT virt REMOTE_SYSTEMD systemd REMOTE_PKG_MGR pkg_mgr REMOTE_INSTALL_PROFILE install_profile REMOTE_INSTALL_LABEL install_label REMOTE_INSTALL_SUPPORTED install_supported REMOTE_INSTALL_NOTES install_notes REMOTE_MEMORY memory REMOTE_DISK_ROOT disk_root REMOTE_UPTIME uptime REMOTE_PUBLIC_IP public_ip REMOTE_IPINFO_JSON ipinfo_json REMOTE_XRAY_PRESENT xray_present REMOTE_XRAY_VERSION xray_version REMOTE_XRAY_SERVICE xray_service REMOTE_LISTENER_PORT listener_port REMOTE_LISTENER_443 listener_443 REMOTE_MANAGED_META managed_meta REMOTE_server_port server_port REMOTE_server_name server_name REMOTE_uuid uuid REMOTE_public_key public_key REMOTE_short_id short_id REMOTE_flow flow", pairs, " ")
		for (i = 1; i in pairs; i += 2) {
			key_map[pairs[i]] = pairs[i+1]
		}
		order_str = "status ssh_ok hostname fqdn kernel arch pretty_name os_id os_version virt systemd pkg_mgr install_profile install_label install_supported install_notes memory disk_root uptime public_ip ipinfo_json xray_present xray_version xray_service listener_port listener_443 managed_meta server_port server_name uuid public_key short_id flow"
		n = split(order_str, order, " ")
		for (i = 1; i <= n; i++) vals[order[i]] = ""
	}
	{
		k = $1
		sub(/^[^=]*=/, "")
		v = $0
		if (k in key_map) {
			gsub(/\\/, "\\\\", v)
			gsub(/"/, "\\\"", v)
			gsub(/\t/, "\\t", v)
			gsub(/\r/, "\\r", v)
			vals[key_map[k]] = v
		}
	}
	END {
		printf "{"
		for (i = 1; i <= n; i++) {
			if (i > 1) printf ","
			printf "\"%s\":\"%s\"", order[i], vals[order[i]]
		}
		printf "}"
	}
	' "$cache_path"
}

profile_json() {
	local profile_id="$1"
	local _pj_label _pj_vps_profile _pj_auth_mode _pj_ssh_host _pj_ssh_port _pj_ssh_user
	local _pj_server_address _pj_server_port _pj_server_name _pj_uuid _pj_public_key _pj_short_id _pj_flow
	local _pj_managed_key_path _pj_bootstrap_key_path _pj_managed_pubkey _pj_last_inspect_status _pj_last_inspect_at
	local _pj_managed_present _pj_bootstrap_present _pj_endpoint_host
	local _pj_cache_path _pj_router_diff _pj_remote_diff
	local _pj_line _pj_key _pj_val

	eval "$(uci -q show "${PROFILE_PACKAGE}.${profile_id}" 2>/dev/null | awk -F= -v pfx="${PROFILE_PACKAGE}.${profile_id}." '
		BEGIN { ORS="" }
		{
			k = $0
			sub(/=.*/, "", k)
			v = $0
			sub(/^[^=]*=/, "", v)
			if (index(k, pfx) != 1) next
			k = substr(k, length(pfx) + 1)
			if (k == "" || k ~ /\./) next
			# strip surrounding single quotes from uci output
			if (substr(v,1,1) == "\x27" && substr(v,length(v),1) == "\x27") {
				v = substr(v, 2, length(v)-2)
			}
			gsub(/\x27/, "\x27\"\x27\"\x27", v)
			printf "_pj_%s=\x27%s\x27\n", k, v
		}
	')"

	_pj_managed_key_path="${_pj_managed_key_path:-}"
	_pj_bootstrap_key_path="${_pj_bootstrap_key_path:-}"
	[ -n "$_pj_managed_key_path" ] && [ -f "$_pj_managed_key_path" ] && _pj_managed_present=1 || _pj_managed_present=0
	[ -n "$_pj_bootstrap_key_path" ] && [ -f "$_pj_bootstrap_key_path" ] && _pj_bootstrap_present=1 || _pj_bootstrap_present=0

	_pj_endpoint_host="${_pj_server_address:-}"
	[ -n "$_pj_endpoint_host" ] || _pj_endpoint_host="${_pj_ssh_host:-}"

	_pj_vps_profile="$(normalize_vps_profile "${_pj_vps_profile:-}")"

	_pj_cache_path="${INSPECT_DIR}/${profile_id}.env"
	_pj_router_diff="$(profile_diff_fields "$profile_id" router)"
	_pj_remote_diff="$(profile_diff_fields "$profile_id" remote)"

	printf '{'
	printf '"id":"%s",' "$(json_escape "$profile_id")"
	printf '"label":"%s",' "$(json_escape "${_pj_label:-}")"
	printf '"vps_profile":"%s",' "$(json_escape "$_pj_vps_profile")"
	printf '"auth_mode":"%s",' "$(json_escape "${_pj_auth_mode:-}")"
	printf '"endpoint_host":"%s",' "$(json_escape "$_pj_endpoint_host")"
	printf '"ssh_host":"%s",' "$(json_escape "${_pj_ssh_host:-}")"
	printf '"ssh_port":"%s",' "$(json_escape "${_pj_ssh_port:-}")"
	printf '"ssh_user":"%s",' "$(json_escape "${_pj_ssh_user:-}")"
	printf '"server_address":"%s",' "$(json_escape "${_pj_server_address:-}")"
	printf '"server_port":"%s",' "$(json_escape "${_pj_server_port:-}")"
	printf '"server_name":"%s",' "$(json_escape "${_pj_server_name:-}")"
	printf '"uuid":"%s",' "$(json_escape "${_pj_uuid:-}")"
	printf '"public_key":"%s",' "$(json_escape "${_pj_public_key:-}")"
	printf '"short_id":"%s",' "$(json_escape "${_pj_short_id:-}")"
	printf '"flow":"%s",' "$(json_escape "${_pj_flow:-}")"
	printf '"managed_key_path":"%s",' "$(json_escape "$_pj_managed_key_path")"
	printf '"managed_pubkey":"%s",' "$(json_escape "${_pj_managed_pubkey:-}")"
	printf '"managed_key_present":'; json_bool "$_pj_managed_present"; printf ','
	printf '"bootstrap_key_present":'; json_bool "$_pj_bootstrap_present"; printf ','
	printf '"last_inspect_status":"%s",' "$(json_escape "${_pj_last_inspect_status:-}")"
	printf '"last_inspect_at":"%s",' "$(json_escape "${_pj_last_inspect_at:-}")"
	printf '"router_diff":"%s",' "$(json_escape "$_pj_router_diff")"
	printf '"remote_diff":"%s",' "$(json_escape "$_pj_remote_diff")"
	printf '"remote_cache":'
	remote_cache_json "$_pj_cache_path"
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
	[ -n "$server_port" ] || server_port='24443'
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
	profile_set "$profile_id" server_port '24443'
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
	# DIAGNOSTIC-TREE 5.1: the remote command not only appends the managed
	# key, it also normalizes ownership and mode of the login home,
	# ~/.ssh and authorized_keys. This is essential: after a VPS
	# reprovision the home directory can end up owned by a service user
	# (observed: /root owned by xray:xray, 2026-07-09). With StrictModes
	# on — the sshd default — an authorized_keys that root does not own is
	# silently ignored, so key auth fails no matter how many times the
	# key is re-appended. Re-appending was the entire fix before, which
	# is why "repair with the root password" never actually worked. We do
	# the chown in this same password session because it is the only
	# context where we hold write access without the key that is broken.
	# $HOME is expanded remotely; `id -gn` picks the login user's primary
	# group so we don't hard-code root.
	SSHPASS="$password" sshpass -e ssh \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o ConnectTimeout=6 \
		-p "$port" \
		"$user@$host" \
		"sh -c 'set -e; umask 077; mkdir -p \"\$HOME/.ssh\"; touch \"\$HOME/.ssh/authorized_keys\"; PUB=\$(cat); grep -qxF \"\$PUB\" \"\$HOME/.ssh/authorized_keys\" || printf \"%s\n\" \"\$PUB\" >> \"\$HOME/.ssh/authorized_keys\"; U=\$(id -un); G=\$(id -gn); chown \"\$U:\$G\" \"\$HOME\" \"\$HOME/.ssh\" \"\$HOME/.ssh/authorized_keys\"; chmod 700 \"\$HOME/.ssh\"; chmod 600 \"\$HOME/.ssh/authorized_keys\"'" \
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

	if ! ssh_cmd "$profile_id" 'test -x /usr/local/bin/xray' >/dev/null 2>&1; then
		local vps_arch bundled_xray vps_pkg_dir
		vps_arch="$(ssh_cmd "$profile_id" 'uname -m' 2>/dev/null || true)"
		vps_pkg_dir="/usr/share/vpn-xray/vps/${vps_profile}/packages"
		bundled_xray=''
		case "$vps_arch" in
			x86_64|amd64)  bundled_xray="${vps_pkg_dir}/Xray-linux-64.zip" ;;
			aarch64|arm64) bundled_xray="${vps_pkg_dir}/Xray-linux-arm64-v8a.zip" ;;
		esac
		if [ -n "$bundled_xray" ] && [ -f "$bundled_xray" ]; then
			ssh_stdin_cmd "$profile_id" 'cat > /tmp/xray-bundled.zip' "$bundled_xray" >/dev/null 2>&1 || true
		fi
	fi

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

	local router_backup=''
	if [ -f "$ROUTER_CONFIG" ]; then
		router_backup="${ROUTER_CONFIG}.rollback.$$"
		cp "$ROUTER_CONFIG" "$router_backup"
	fi

	setup_vps_internal "$profile_id" || {
		rm -f "$router_backup"
		emit_error apply_profile 'Failed to sync the selected VPS.'
		return 0
	}
	if ! apply_profile_to_router_internal "$profile_id" >/dev/null; then
		if [ -n "$router_backup" ] && [ -f "$router_backup" ]; then
			cp "$router_backup" "$ROUTER_CONFIG"
			resync_runtime_to_switch || true
		fi
		rm -f "$router_backup"
		emit_error apply_profile 'VPS was synced, but applying the profile to the router failed. Router config rolled back.'
		return 0
	fi
	rm -f "$router_backup"

	emit_status_response apply_profile
}

# --- Deferred router-apply job (DIAGNOSTIC-TREE 8.2) ---
# The apply is a hard cutover, so it runs as a detached process, never in
# the request path. State is exposed through a status file the UI polls
# via status_json. Known gap G3: if the job dies mid-cutover the status
# file stays "running" (the router itself recovers via failsafe).

ROUTER_APPLY_STATUS_FILE='/tmp/xray-vps-repair-apply.status'

router_apply_job_running() {
	local pid
	[ -f "$ROUTER_APPLY_STATUS_FILE" ] || return 1
	pid="$(sed -n 's/^pid=//p' "$ROUTER_APPLY_STATUS_FILE" | sed -n '1p')"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Spawn a detached copy of this CGI in job mode. start-stop-daemon -b
# double-forks and detaches from the fcgiwrap process group, so the job
# survives the end of the HTTP request that scheduled it.
schedule_router_apply_job() {
	local profile_id="$1"

	if router_apply_job_running; then
		return 0
	fi
	{
		printf 'state=scheduled\n'
		printf 'profile=%s\n' "$profile_id"
		printf 'scheduled_at=%s\n' "$(date +%s)"
	} > "$ROUTER_APPLY_STATUS_FILE"
	XRAY_VPS_JOB='apply_router' XRAY_VPS_JOB_PROFILE="$profile_id" \
		start-stop-daemon -S -b -x /www/cgi-bin/xray-vps 2>/dev/null
}

run_router_apply_job() {
	local profile_id="$1"
	set +e
	{
		printf 'state=running\n'
		printf 'profile=%s\n' "$profile_id"
		printf 'pid=%s\n' "$$"
		printf 'started_at=%s\n' "$(date +%s)"
	} > "$ROUTER_APPLY_STATUS_FILE"

	if apply_profile_to_router_internal "$profile_id" >/dev/null 2>&1; then
		{
			printf 'state=done\n'
			printf 'profile=%s\n' "$profile_id"
			printf 'finished_at=%s\n' "$(date +%s)"
			printf 'message=Router config applied and runtime resynced.\n'
		} > "$ROUTER_APPLY_STATUS_FILE"
		return 0
	fi
	{
		printf 'state=failed\n'
		printf 'profile=%s\n' "$profile_id"
		printf 'finished_at=%s\n' "$(date +%s)"
		printf 'message=Router apply failed; previous config was restored by the apply guard.\n'
	} > "$ROUTER_APPLY_STATUS_FILE"
	return 1
}

# Return 0 when the current request carries any of the profile
# identity/routing fields that save_profile_from_request expects. Used to
# decide whether an incoming diagnose_repair call is being made from the
# UI (form-based, edit-then-submit) or from a headless caller that only
# wants to trigger repair on the already-selected profile.
request_has_profile_edit() {
	local key
	for key in profile_id label vps_profile ssh_host ssh_port ssh_user \
		server_address server_port server_name uuid public_key \
		private_key short_id flow auth_mode bootstrap_private_key; do
		if request_has_key "$key"; then
			return 0
		fi
	done
	return 1
}

# Run the VPS repair pipeline over an established SSH connection. Stages
# the rendered config + meta + repair script into /tmp on the VPS, runs
# the script with REPAIR_REPORT_PATH pointing at a report file, then
# reads the report back and streams it as the "steps" array of the CGI
# response. The report format is defined in install-vps.remote.sh.
run_repair_pipeline() {
	local profile_id="$1"
	local vps_profile install_script_rel install_script_path remote_meta_path
	local rendered meta rendered_install
	local report_local report_remote='/tmp/codex-router-vps-repair.jsonl'
	local raw_log_file

	# SSH_RAW_LOG_PATH tells ssh_exec_with_identity / ssh_stdin_with_identity
	# to append their stderr to this file. Fcgiwrap keeps fd 3+ busy for
	# its FastCGI channel so we cannot use `exec 3>>file` here — the
	# path-based redirect below is portable across those environments.
	raw_log_file="/tmp/codex-router-vps-repair-raw.$$.log"
	: > "$raw_log_file"
	SSH_RAW_LOG_PATH="$raw_log_file"
	export SSH_RAW_LOG_PATH

	log_step() {
		printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >> "$raw_log_file"
	}

	vps_profile="$(selected_vps_profile "$profile_id")"
	install_script_rel="$(vps_profile_value "$vps_profile" VPS_INSTALL_SCRIPT)"
	install_script_path="$(vps_profile_file_path "$vps_profile" "$install_script_rel")"
	remote_meta_path="$(vps_profile_value "$vps_profile" VPS_REMOTE_META_PATH)"
	[ -f "$install_script_path" ] || {
		log_step "FATAL repair script template missing on router at $install_script_path"
		REPAIR_REPORT='[]'
		REPAIR_FATAL='Repair script template is not available on the router.'
		REPAIR_RAW_LOG_PATH="$raw_log_file"
		unset SSH_RAW_LOG_PATH
		return 1
	}
	[ -n "$remote_meta_path" ] || remote_meta_path='/usr/local/etc/xray/codex-router-meta.env'

	rendered='/tmp/codex-router-vps-config.json'
	meta='/tmp/codex-router-vps-meta.env'
	rendered_install='/tmp/codex-router-install.remote.sh'
	report_local="/tmp/codex-router-vps-repair.$$.jsonl"

	log_step "rendering server config, meta, and repair script templates"
	render_server_config "$rendered" "$profile_id"
	render_remote_meta "$meta" "$profile_id"
	render_vps_profile_template "$profile_id" "$install_script_path" "$rendered_install"

	log_step "uploading rendered xray config to VPS"
	if ! ssh_stdin_cmd "$profile_id" 'cat > /tmp/codex-router-vps-config.json' "$rendered" >/dev/null; then
		log_step "FAILED to upload rendered xray config"
		REPAIR_REPORT='[]'
		REPAIR_FATAL='Failed to upload rendered xray config to the VPS.'
		REPAIR_RAW_LOG_PATH="$raw_log_file"
		rm -f "$rendered" "$meta" "$rendered_install" "$report_local"
		unset SSH_RAW_LOG_PATH
		return 1
	fi
	log_step "uploading router meta.env to VPS"
	if ! ssh_stdin_cmd "$profile_id" 'cat > /tmp/codex-router-meta.env' "$meta" >/dev/null; then
		log_step "FAILED to upload router meta.env"
		REPAIR_REPORT='[]'
		REPAIR_FATAL='Failed to upload router meta.env to the VPS.'
		REPAIR_RAW_LOG_PATH="$raw_log_file"
		rm -f "$rendered" "$meta" "$rendered_install" "$report_local"
		unset SSH_RAW_LOG_PATH
		return 1
	fi
	log_step "uploading repair script to VPS"
	if ! ssh_stdin_cmd "$profile_id" 'cat > /tmp/install-vps.remote.sh && chmod 755 /tmp/install-vps.remote.sh' "$rendered_install" >/dev/null; then
		log_step "FAILED to upload repair script"
		REPAIR_REPORT='[]'
		REPAIR_FATAL='Failed to upload the repair script to the VPS.'
		REPAIR_RAW_LOG_PATH="$raw_log_file"
		rm -f "$rendered" "$meta" "$rendered_install" "$report_local"
		unset SSH_RAW_LOG_PATH
		return 1
	fi

	# Ship a bundled xray archive iff the remote xray binary is missing.
	# The repair script picks it up automatically via extract_bundled_xray.
	if ! ssh_cmd "$profile_id" 'test -x /usr/local/bin/xray' >/dev/null 2>&1; then
		local vps_arch bundled_xray vps_pkg_dir
		vps_arch="$(ssh_cmd "$profile_id" 'uname -m' 2>/dev/null || true)"
		vps_pkg_dir="/usr/share/vpn-xray/vps/${vps_profile}/packages"
		bundled_xray=''
		case "$vps_arch" in
			x86_64|amd64)  bundled_xray="${vps_pkg_dir}/Xray-linux-64.zip" ;;
			aarch64|arm64) bundled_xray="${vps_pkg_dir}/Xray-linux-arm64-v8a.zip" ;;
		esac
		if [ -n "$bundled_xray" ] && [ -f "$bundled_xray" ]; then
			log_step "shipping bundled xray archive for arch $vps_arch"
			ssh_stdin_cmd "$profile_id" 'cat > /tmp/xray-bundled.zip' "$bundled_xray" >/dev/null 2>&1 || true
		fi
	fi

	log_step "executing repair pipeline on VPS"
	local ssh_rc=0
	# Wrap the remote script in `timeout 90` so a hanging step on the
	# VPS never leaves this CGI (and its fcgiwrap worker) blocked
	# indefinitely. 90 seconds is comfortably longer than the pipeline
	# itself needs but short enough that the browser still gets an
	# answer before nginx's 300s fastcgi_read_timeout hits.
	# The script runs under set -e, so a non-zero ssh_cmd exit would kill
	# the whole CGI silently before we get to record it. Guard with an
	# if-block so a failed repair pipeline surfaces as a proper report
	# rather than a truncated response with no body.
	if ssh_cmd "$profile_id" "rm -f $report_remote; VPS_REMOTE_META_PATH='$remote_meta_path' REPAIR_REPORT_PATH='$report_remote' timeout 90 sh /tmp/install-vps.remote.sh >/dev/null 2>&1; ec=\$?; cat $report_remote 2>/dev/null; exit \$ec" > "$report_local"; then
		ssh_rc=0
	else
		ssh_rc=$?
	fi
	log_step "repair pipeline finished with exit=$ssh_rc"

	# Fold the JSONL report into a JSON array. Each non-empty line should
	# already be a valid JSON object.
	REPAIR_REPORT='['
	local first=1 line
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		if [ "$first" = '1' ]; then
			first=0
		else
			REPAIR_REPORT="${REPAIR_REPORT},"
		fi
		REPAIR_REPORT="${REPAIR_REPORT}${line}"
	done < "$report_local"
	REPAIR_REPORT="${REPAIR_REPORT}]"

	REPAIR_RAW_LOG_PATH="$raw_log_file"
	unset SSH_RAW_LOG_PATH
	rm -f "$rendered" "$meta" "$rendered_install" "$report_local"
	return "$ssh_rc"
}

# Emit a structured response for the diagnose_repair action. Fields:
#   ok: boolean; false when SSH itself failed or the pipeline could not
#       run at all, true when the pipeline finished (whether some
#       individual steps failed or not — the caller reads status.overall).
#   error / need: present only when we need the operator to supply
#       credentials.
#   steps: JSON array of per-step reports (may be empty on hard errors).
# Trim, escape, and cap the raw log so a long transcript does not blow
# up the JSON response. Returns the JSON string value (without the outer
# quotes) via stdout; empty string when the log file is missing.
raw_log_payload() {
	local path="$1"
	local size max=32768 content
	[ -n "$path" ] || return 0
	[ -f "$path" ] || return 0
	size="$(wc -c < "$path" 2>/dev/null || echo 0)"
	if [ "$size" -gt "$max" ]; then
		content="[log truncated to last ${max} bytes]
$(tail -c "$max" "$path" 2>/dev/null)"
	else
		content="$(cat "$path" 2>/dev/null)"
	fi
	json_escape "$content"
}

emit_repair_response() {
	local ok="$1"
	local report="$2"
	local raw_log="${3:-}"
	local router_apply="${4:-in_sync}"
	emit_header
	printf '{'
	printf '"ok":'
	json_bool "$ok"
	printf ','
	printf '"action":"diagnose_repair",'
	printf '"steps":%s,' "$report"
	printf '"raw_log":"%s",' "$raw_log"
	printf '"router_apply":"%s",' "$(json_escape "$router_apply")"
	printf '"status":'
	status_json
	printf '}'
}

emit_repair_credentials_required() {
	local reason="$1"
	local raw_log="${2:-}"
	emit_header
	printf '{'
	printf '"ok":false,'
	printf '"action":"diagnose_repair",'
	printf '"error":"credentials_required",'
	printf '"reason":"%s",' "$(json_escape "$reason")"
	printf '"raw_log":"%s",' "$raw_log"
	# Fields the UI should collect and re-submit. If the profile has a
	# bootstrap key slot filled we still keep it as a fallback option.
	printf '"need":["ssh_password"],'
	printf '"steps":[]'
	printf '}'
}

diagnose_repair_action() {
	# The repair pipeline contains many "risky" commands whose non-zero
	# exit codes are meaningful data (SSH refused, wc on a missing file,
	# etc.) — the calling contract of set -e in this CGI would abort the
	# whole response before we could serialize a report. Turn it off for
	# the duration of this action and re-enable at the very end.
	set +e

	# Single-flight guard: two operators mashing the button — or the
	# same one impatiently re-clicking — must not spawn concurrent
	# repair pipelines. Each holds live SSH sessions and shovels config
	# writes at the VPS; overlapping them accumulates fcgiwrap workers
	# and can lock the router until reboot. flock exits non-zero when
	# it cannot acquire the lock, in which case we return a fast, safe
	# response instead of piling on top.
	local lockfile='/tmp/xray-vps-locks/diagnose_repair.flock'
	mkdir -p "$(dirname "$lockfile")"
	exec 9>"$lockfile"
	if ! flock -n 9; then
		emit_header
		printf '{'
		printf '"ok":false,'
		printf '"action":"diagnose_repair",'
		printf '"error":"busy",'
		printf '"reason":"A repair run is already in progress. Wait for it to finish before starting another.",'
		printf '"raw_log":"",'
		printf '"steps":[]'
		printf '}'
		return 0
	fi

	local profile_id save_err

	# The UI sends the full profile form when the user has changed any of
	# the identity/routing fields. When no such fields are in the request
	# we skip save_profile_from_request entirely, otherwise that helper
	# would allocate a fresh profile (label defaults to "profile") and
	# tear down the currently-selected one. This keeps direct calls from
	# curl / operator tooling well-behaved.
	if request_has_profile_edit; then
		if ! save_profile_from_request >/dev/null; then
			save_err="${SAVE_PROFILE_ERROR:-Could not persist profile settings before repair.}"
			emit_header
			printf '{'
			printf '"ok":false,'
			printf '"action":"diagnose_repair",'
			printf '"error":"save_profile_failed",'
			printf '"reason":"%s",' "$(json_escape "$save_err")"
			printf '"steps":[]'
			printf '}'
			return 0
		fi
		profile_id="$SAVE_PROFILE_ID"
	else
		profile_id="$(active_profile_id)"
		if [ -z "$profile_id" ]; then
			emit_header
			printf '{'
			printf '"ok":false,'
			printf '"action":"diagnose_repair",'
			printf '"error":"no_active_profile",'
			printf '"reason":"No active VPS profile is selected. Create one first.",'
			printf '"steps":[]'
			printf '}'
			return 0
		fi
	fi

	# One-shot SSH password from the UI: install_managed_key_with_password
	# already reads ssh_password from the request. Stash it into the
	# profile just long enough for ensure_ssh_ready to use; the helpers
	# themselves clear it once the managed key install succeeds.
	local one_shot_password
	one_shot_password="$(request_value ssh_password)"
	if [ -n "$one_shot_password" ]; then
		profile_set "$profile_id" auth_mode 'password'
		profile_set "$profile_id" ssh_password "$one_shot_password"
		uci commit "$PROFILE_PACKAGE"
	fi

	# Capture SSH stderr from the credential-check probe into a dedicated
	# log so the credentials_required response can show the actual reason
	# (Connection refused, permission denied, unreachable, etc.) instead
	# of a generic message.
	local creds_raw_log="/tmp/codex-router-vps-creds-raw.$$.log"
	: > "$creds_raw_log"
	SSH_RAW_LOG_PATH="$creds_raw_log"
	export SSH_RAW_LOG_PATH
	printf '[%s] probing SSH with current credentials\n' "$(date +%H:%M:%S)" >> "$creds_raw_log"
	if ! ensure_ssh_ready "$profile_id"; then
		unset SSH_RAW_LOG_PATH
		local raw_payload
		raw_payload="$(raw_log_payload "$creds_raw_log")"
		rm -f "$creds_raw_log"
		emit_repair_credentials_required \
			'Router could not establish SSH to the VPS with the current credentials. Check the raw log below; if the reason is "Connection refused" or "timed out", the VPS is unreachable — not a credentials problem. Otherwise provide the VPS root password once so the router can re-install its managed key.' \
			"$raw_payload"
		return 0
	fi
	unset SSH_RAW_LOG_PATH
	# Fold the credential-probe log into the same file we hand back so
	# the operator sees the whole story in one place.
	local combined_raw_log="/tmp/codex-router-vps-combined-raw.$$.log"
	cat "$creds_raw_log" > "$combined_raw_log" 2>/dev/null || : > "$combined_raw_log"
	rm -f "$creds_raw_log"

	local repair_rc=0
	run_repair_pipeline "$profile_id"
	repair_rc=$?

	# Append the pipeline log to the combined log.
	if [ -n "${REPAIR_RAW_LOG_PATH:-}" ] && [ -f "$REPAIR_RAW_LOG_PATH" ]; then
		cat "$REPAIR_RAW_LOG_PATH" >> "$combined_raw_log" 2>/dev/null || true
		rm -f "$REPAIR_RAW_LOG_PATH"
	fi

	local raw_payload
	raw_payload="$(raw_log_payload "$combined_raw_log")"
	rm -f "$combined_raw_log"

	if [ -n "${REPAIR_FATAL:-}" ] && [ "${REPAIR_REPORT:-[]}" = '[]' ]; then
		emit_header
		printf '{'
		printf '"ok":false,'
		printf '"action":"diagnose_repair",'
		printf '"error":"pipeline_setup_failed",'
		printf '"reason":"%s",' "$(json_escape "$REPAIR_FATAL")"
		printf '"raw_log":"%s",' "$raw_payload"
		printf '"steps":[]'
		printf '}'
		return 0
	fi

	# Refresh our local cache view of the VPS so status polls after this
	# call reflect what actually runs on the VPS. Read-only side effect
	# only, does not touch the router runtime.
	refresh_remote_cache "$profile_id" >/dev/null 2>&1 || true

	# DIAGNOSTIC-TREE 8.1: profile empty, VPS authoritative — adopt the
	# live VPS identity into the profile. UCI-only, risk class `safe`, so
	# it may run synchronously. Only when the profile has no public_key of
	# its own; an operator-authored profile is never overwritten (8.4).
	local router_apply='in_sync'
	if [ "$repair_rc" -eq 0 ] && [ -z "$(profile_get "$profile_id" public_key)" ]; then
		adopt_remote_into_profile "$profile_id" >/dev/null 2>&1 || true
	fi

	# DIAGNOSTIC-TREE 8.2: router stale vs profile. Applying performs a
	# hard cutover of the transparent path (stops codex-transproxy and
	# codex-xray) — risk class `disruptive`, which must NEVER run inside
	# this CGI request: the request itself may ride the path being cut,
	# which hung the router until reboot on 2026-07-09. Instead we
	# schedule a detached background job and report its status file.
	if [ "$repair_rc" -eq 0 ]; then
		if [ ! -s "$ROUTER_CONFIG" ] || [ -n "$(profile_diff_fields "$profile_id" router)" ]; then
			if schedule_router_apply_job "$profile_id"; then
				router_apply='scheduled'
			else
				router_apply='schedule_failed'
			fi
		fi
	else
		router_apply='skipped'
	fi

	if [ "$repair_rc" -eq 0 ]; then
		emit_repair_response 1 "$REPAIR_REPORT" "$raw_payload" "$router_apply"
	else
		emit_repair_response 0 "$REPAIR_REPORT" "$raw_payload" "$router_apply"
	fi
	return 0
}

# Internal job mode: a detached re-exec of this CGI (no HTTP context).
# Must sit after all function definitions and before request parsing.
if [ -n "${XRAY_VPS_JOB:-}" ]; then
	case "$XRAY_VPS_JOB" in
		apply_router)
			run_router_apply_job "${XRAY_VPS_JOB_PROFILE:-$(active_profile_id)}"
			exit $?
			;;
	esac
	exit 1
fi

REQUEST_DATA="$(load_request_data)"

case "$(request_value action)" in
	''|status)
		ensure_profile_store_light
		emit_header
		status_json
		;;
	save_profile)
		ensure_profile_store
		save_profile_action
		;;
	select_profile)
		ensure_profile_store
		select_profile_action
		;;
	create_profile)
		ensure_profile_store
		create_profile_action
		;;
	generate_key)
		ensure_profile_store
		generate_key_action
		;;
	install_key)
		ensure_profile_store
		install_key_action
		;;
	inspect_vps)
		ensure_profile_store
		inspect_action
		;;
	check_profile)
		ensure_profile_store
		check_profile_action
		;;
	adopt_vps)
		ensure_profile_store
		adopt_vps_action
		;;
	apply_router)
		ensure_profile_store
		apply_profile_to_router_action
		;;
	setup_vps)
		ensure_profile_store
		setup_vps_action
		;;
	apply_profile)
		ensure_profile_store
		apply_everything_action
		;;
	diagnose_repair)
		ensure_profile_store
		diagnose_repair_action
		;;
	*)
		emit_error "$(request_value action)" 'Unknown action.'
		;;
esac
