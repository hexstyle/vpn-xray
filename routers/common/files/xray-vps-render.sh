#!/bin/sh
# xray-vps-render.sh — router/VPS config + profile/status JSON rendering
# Deployed to /usr/share/vpn-xray/xray-vps-render.sh
# Sourced by /www/cgi-bin/xray-vps after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

# effective_server_name <profile_id> — the SNI to actually use: the profile's
# server_name, or the VPS-profile default (www.cloudflare.com) when the profile
# left it blank. Renders must never emit an empty serverName (empty SNI fails
# cert validation — node 8.2), and an unset profile SNI must not read as drift
# against a router already running the default.
effective_server_name() {
	local v
	v="$(profile_get "$1" server_name)"
	[ -n "$v" ] || v="$(default_server_name_for_profile "$(default_vps_profile)")"
	printf '%s' "$v"
}

render_router_config() {
	local path="$1"
	local profile_id="$2"
	local server_address server_port server_name uuid public_key short_id flow user_flow_line ws_path

	server_address="$(profile_get "$profile_id" server_address)"
	server_port="$(profile_get "$profile_id" server_port)"
	server_name="$(effective_server_name "$profile_id")"
	uuid="$(profile_get "$profile_id" uuid)"
	public_key="$(profile_get "$profile_id" public_key)"
	short_id="$(profile_get "$profile_id" short_id)"
	flow="$(profile_get "$profile_id" flow)"
	ws_path="$(profile_get "$profile_id" ws_path)"
	[ -n "$ws_path" ] || ws_path='/cdn'
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
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${server_name}",
          "alpn": ["h2", "http/1.1"],
          "fingerprint": "chrome",
          "certificates": [
            {"usage": "verify", "certificateFile": "/etc/xray/server.crt"}
          ]
        },
        "wsSettings": {
          "path": "${ws_path}",
          "host": "${server_name}"
        }
      },
      "mux": {
        "enabled": true,
        "concurrency": 8,
        "xudpConcurrency": 16
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
	xray_server_name="$(effective_server_name "$profile_id")"
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
	chmod 600 "$path"
}

render_remote_meta() {
	local path="$1"
	local profile_id="$2"

	cat > "$path" <<EOF
PROFILE_ID=${profile_id}
XRAY_HOST=$(profile_get "$profile_id" server_address)
XRAY_PORT=$(profile_get "$profile_id" server_port)
XRAY_UUID=$(profile_get "$profile_id" uuid)
XRAY_SERVER_NAME=$(effective_server_name "$profile_id")
XRAY_SHORT_ID=$(profile_get "$profile_id" short_id)
XRAY_PRIVATE_KEY=$(profile_get "$profile_id" private_key)
XRAY_PUBLIC_KEY=$(profile_get "$profile_id" public_key)
XRAY_FLOW=$(profile_get "$profile_id" flow)
EOF
	chmod 600 "$path"
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

	# public_key / short_id are Reality-only fields. The whole stack is WS+TLS,
	# where they are unused and always empty on the router and VPS — but a
	# profile can still carry stale Reality values from before the migration.
	# Comparing them reads a permanent false "needs sync"; a real transport
	# difference is caught separately by node 8.5. So they are NOT identity
	# fields for coherence.
	if [ "$source" = 'router' ]; then
		keys='server_address server_port server_name uuid flow'
	else
		keys='server_port server_name uuid flow'
	fi

	for key in $keys; do
		expected="$(profile_get "$profile_id" "$key")"
		# An unset SNI resolves to the default at render time, so compare the
		# effective value — otherwise a blank profile SNI reads as permanent drift.
		if [ "$key" = 'server_name' ] && [ -z "$expected" ]; then
			expected="$(default_server_name_for_profile "$(default_vps_profile)")"
		fi
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
		printf '{"status":"","ssh_ok":"","hostname":"","fqdn":"","kernel":"","arch":"","pretty_name":"","os_id":"","os_version":"","virt":"","systemd":"","pkg_mgr":"","install_profile":"","install_label":"","install_supported":"","install_notes":"","memory":"","disk_root":"","uptime":"","public_ip":"","ipinfo_json":"","xray_present":"","xray_version":"","xray_service":"","listener_port":"","listener_443":"","managed_meta":"","server_port":"","server_name":"","uuid":"","public_key":"","short_id":"","flow":"","transport_net":"","transport_sec":""}'
		return 0
	fi
	awk '
	BEGIN {
		FS="="
		ORS=""
		split("REMOTE_STATUS status REMOTE_SSH_OK ssh_ok REMOTE_HOSTNAME hostname REMOTE_FQDN fqdn REMOTE_KERNEL kernel REMOTE_ARCH arch REMOTE_PRETTY_NAME pretty_name REMOTE_OS_ID os_id REMOTE_OS_VERSION os_version REMOTE_VIRT virt REMOTE_SYSTEMD systemd REMOTE_PKG_MGR pkg_mgr REMOTE_INSTALL_PROFILE install_profile REMOTE_INSTALL_LABEL install_label REMOTE_INSTALL_SUPPORTED install_supported REMOTE_INSTALL_NOTES install_notes REMOTE_MEMORY memory REMOTE_DISK_ROOT disk_root REMOTE_UPTIME uptime REMOTE_PUBLIC_IP public_ip REMOTE_IPINFO_JSON ipinfo_json REMOTE_XRAY_PRESENT xray_present REMOTE_XRAY_VERSION xray_version REMOTE_XRAY_SERVICE xray_service REMOTE_LISTENER_PORT listener_port REMOTE_LISTENER_443 listener_443 REMOTE_MANAGED_META managed_meta REMOTE_server_port server_port REMOTE_server_name server_name REMOTE_uuid uuid REMOTE_public_key public_key REMOTE_short_id short_id REMOTE_flow flow REMOTE_TRANSPORT_NET transport_net REMOTE_TRANSPORT_SEC transport_sec", pairs, " ")
		for (i = 1; i in pairs; i += 2) {
			key_map[pairs[i]] = pairs[i+1]
		}
		order_str = "status ssh_ok hostname fqdn kernel arch pretty_name os_id os_version virt systemd pkg_mgr install_profile install_label install_supported install_notes memory disk_root uptime public_ip ipinfo_json xray_present xray_version xray_service listener_port listener_443 managed_meta server_port server_name uuid public_key short_id flow transport_net transport_sec"
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
