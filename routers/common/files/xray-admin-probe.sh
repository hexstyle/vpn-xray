#!/bin/sh
# xray-admin-probe.sh — candidate probe, config build, and runtime control
# for the xray-admin CGI. Deployed to /usr/share/vpn-xray/xray-admin-probe.sh
# Sourced by /www/cgi-bin/xray-admin after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

build_config_file() {
	local outfile="$1"
	local http_port="$2"
	local socks_port="$3"
	local server_address="$4"
	local server_port="$5"
	local server_name="$6"
	local uuid="$7"
	local public_key="$8"
	local short_id="$9"
	local flow="${10}"
	local access_log="${11}"
	local error_log="${12}"
	local user_flow_line ws_path

	# WS+TLS transport (matches the VPS + codex-xray.json.template). The
	# public_key/short_id params are legacy Reality fields, now unused in
	# the rendered output — kept in the signature so callers do not change.
	# ws_path defaults to the stack default; the admin form has no ws-path
	# field, and the whole stack uses /cdn.
	ws_path='/cdn'
	user_flow_line=''
	if [ -n "$flow" ]; then
		user_flow_line="$(printf ',\n                "flow": "%s"' "$flow")"
	fi

	cat > "$outfile" <<EOF
{
  "log": {
    "loglevel": "info",
    "access": "${access_log}",
    "error": "${error_log}"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${http_port},
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
      "port": ${socks_port},
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

validate_port() {
	local value="$1"
	case "$value" in
		''|*[!0-9]*)
			return 1
			;;
	esac
	[ "$value" -ge 1 ] && [ "$value" -le 65535 ]
}

validate_pattern() {
	local value="$1"
	local pattern="$2"
	printf '%s' "$value" | grep -Eq "$pattern"
}

validate_candidate() {
	local server_address="$1"
	local server_port="$2"
	local server_name="$3"
	local uuid="$4"
	local public_key="$5"
	local short_id="$6"
	local flow="$7"

	[ -n "$server_address" ] || { echo 'Server address is required.'; return 1; }
	[ -n "$server_name" ] || { echo 'Server name (SNI) is required.'; return 1; }
	[ -n "$uuid" ] || { echo 'UUID is required.'; return 1; }
	# public_key/short_id are legacy Reality fields — not required for the
	# WS+TLS transport this stack uses. Validate only if present.

	validate_pattern "$server_address" '^[A-Za-z0-9._:-]+$' || { echo 'Server address contains unsupported characters.'; return 1; }
	validate_port "$server_port" || { echo 'Server port must be a number from 1 to 65535.'; return 1; }
	validate_pattern "$server_name" '^[A-Za-z0-9.-]+$' || { echo 'Server name contains unsupported characters.'; return 1; }
	validate_pattern "$uuid" '^[A-Za-z0-9-]+$' || { echo 'UUID contains unsupported characters.'; return 1; }
	if [ -n "$public_key" ]; then
		validate_pattern "$public_key" '^[A-Za-z0-9_-]+$' || { echo 'Public key contains unsupported characters.'; return 1; }
	fi
	if [ -n "$short_id" ]; then
		validate_pattern "$short_id" '^[A-Za-z0-9]*$' || { echo 'Short ID contains unsupported characters.'; return 1; }
	fi
	if [ -n "$flow" ]; then
		validate_pattern "$flow" '^[A-Za-z0-9._-]*$' || { echo 'Flow contains unsupported characters.'; return 1; }
	fi
}

probe_cleanup() {
	local pid=''
	pid="$(cat "$PROBE_PID" 2>/dev/null || true)"
	if [ -n "$pid" ]; then
		kill "$pid" 2>/dev/null || true
		sleep 1
		kill -9 "$pid" 2>/dev/null || true
	fi
	rm -f "$PROBE_PID" "$PROBE_CONFIG" "$PROBE_STDOUT"
}

sync_to_hardware_switch() {
	local switch_state tries

	switch_state="$(current_switch_state)"
	[ "$switch_state" = 'on' ] || switch_state='off'
	/etc/gl-switch.d/xray.sh "$switch_state" >/dev/null 2>&1 || return 1
	tries=0
	while [ "$tries" -lt "$SWITCH_SYNC_WAIT_SECONDS" ]; do
		if [ "$switch_state" = 'on' ]; then
			if runtime_path_active; then
				return 0
			fi
		else
			if ! runtime_path_active; then
				return 0
			fi
		fi
		tries=$((tries + 1))
		sleep 1
	done
	return 1
}

restart_runtime_from_saved_config() {
	xray_failsafe_hold_clear
	xray_failsafe_enable 'manual runtime recovery requested'
	/etc/init.d/codex-transproxy stop >/dev/null 2>&1 || true
	/etc/init.d/codex-xray stop >/dev/null 2>&1 || true
	sleep 1
	sync_to_hardware_switch
}

run_candidate_probe() {
	local server_address="$1"
	local server_port="$2"
	local server_name="$3"
	local uuid="$4"
	local public_key="$5"
	local short_id="$6"
	local flow="$7"

	PROBE_VALID=0
	PROBE_TCP_REACHABLE=0
	PROBE_CONFIG_VALID=0
	PROBE_PROCESS_RUNNING=0
	PROBE_SUITABLE=0
	PROBE_VALIDATION_ERROR=''
	PROBE_TCP_OUTPUT=''
	PROBE_HTTPS_OUTPUT=''
	PROBE_EGRESS_OUTPUT=''
	PROBE_OPENAI_OUTPUT=''

	PROBE_VALIDATION_ERROR="$(validate_candidate "$server_address" "$server_port" "$server_name" "$uuid" "$public_key" "$short_id" "$flow" 2>/dev/null || true)"
	if [ -n "$PROBE_VALIDATION_ERROR" ]; then
		return 0
	fi
	PROBE_VALID=1

	PROBE_TCP_OUTPUT='TCP preflight on this firmware is inferred from the full temporary Xray probe below.'

	build_config_file \
		"$PROBE_CONFIG" \
		"$PROBE_HTTP_PORT" \
		"$PROBE_SOCKS_PORT" \
		"$server_address" \
		"$server_port" \
		"$server_name" \
		"$uuid" \
		"$public_key" \
		"$short_id" \
		"$flow" \
		'/tmp/codex-xray-probe-access.log' \
		'/tmp/codex-xray-probe-error.log'

	if timeout 10 "$BIN" run -test -config "$PROBE_CONFIG" >/dev/null 2>&1; then
		PROBE_CONFIG_VALID=1
	else
		return 0
	fi

	probe_cleanup
	timeout 45 "$BIN" run -config "$PROBE_CONFIG" >"$PROBE_STDOUT" 2>&1 &
	echo "$!" > "$PROBE_PID"
	sleep 2

	if listen_present "$PROBE_HTTP_PORT"; then
		PROBE_PROCESS_RUNNING=1
	fi

	if [ "$PROBE_PROCESS_RUNNING" = "1" ]; then
		PROBE_HTTPS_OUTPUT="$(curl -ksS -I -m 10 -x "http://127.0.0.1:${PROBE_HTTP_PORT}" https://example.com 2>&1 | sed -n '1,20p' || true)"
		PROBE_EGRESS_OUTPUT="$(curl -ksS -m 10 -x "http://127.0.0.1:${PROBE_HTTP_PORT}" https://ipinfo.io/ip 2>&1 | sed -n '1,8p' || true)"
		PROBE_OPENAI_OUTPUT="$(curl -ksS -I -m 10 -x "http://127.0.0.1:${PROBE_HTTP_PORT}" https://api.openai.com/v1/models 2>&1 | sed -n '1,20p' || true)"

		if printf '%s' "$PROBE_HTTPS_OUTPUT" | grep -Eq 'HTTP/[0-9.]+ 200'; then
			PROBE_TCP_REACHABLE=1
		fi

		if [ "$PROBE_TCP_REACHABLE" = '1' ] && \
		   ! printf '%s' "$PROBE_EGRESS_OUTPUT" | grep -q 'curl:' && \
		   [ -n "$PROBE_EGRESS_OUTPUT" ]; then
			PROBE_SUITABLE=1
		fi
	fi

	probe_cleanup
}

probe_json() {
	printf '{'
	printf '"validation_ok":'; json_bool "$PROBE_VALID"; printf ','
	printf '"tcp_reachable":'; json_bool "$PROBE_TCP_REACHABLE"; printf ','
	printf '"config_valid":'; json_bool "$PROBE_CONFIG_VALID"; printf ','
	printf '"probe_process_running":'; json_bool "$PROBE_PROCESS_RUNNING"; printf ','
	printf '"suitable":'; json_bool "$PROBE_SUITABLE"; printf ','
	printf '"validation_error":"%s",' "$(json_escape "$PROBE_VALIDATION_ERROR")"
	printf '"tcp_probe":"%s",' "$(json_escape "$PROBE_TCP_OUTPUT")"
	printf '"https_test":"%s",' "$(json_escape "$PROBE_HTTPS_OUTPUT")"
	printf '"egress":"%s",' "$(json_escape "$PROBE_EGRESS_OUTPUT")"
	printf '"openai_api":"%s"' "$(json_escape "$PROBE_OPENAI_OUTPUT")"
	printf '}'
}
