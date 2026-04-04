#!/bin/sh

set -e

PATH='/usr/sbin:/usr/bin:/sbin:/bin'
BIN='/usr/local/bin/codex-xray-core'
XRAY_CONFIG='/etc/xray/codex-xray.json'
XRAY_PID='/var/run/codex-xray.pid'
REDSOCKS_PID='/var/run/redsocks.pid'
PROBE_CONFIG='/tmp/codex-xray-probe.json'
PROBE_PID='/var/run/codex-xray-probe.pid'
PROBE_STDOUT='/tmp/codex-xray-probe.stdout'
PROBE_HTTP_PORT='18083'
PROBE_SOCKS_PORT='18084'
LOCAL_HTTP_PROXY='http://127.0.0.1:1083'
LIVE_HTTP_PORT='1083'
LIVE_SOCKS_PORT='1084'
CONFIG_READY_FILE='/etc/xray/codex-xray.ready'

REQUEST_DATA=''

json_escape() {
	printf '%s' "${1:-}" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r/\\r/g;s/\t/\\t/g;s/\n/\\n/g'
}

json_bool() {
	if [ "${1:-0}" = "1" ]; then
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

	if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
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

service_running() {
	local pidfile="$1"
	local pid=''
	pid="$(cat "$pidfile" 2>/dev/null || true)"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

listen_present() {
	local port="$1"
	netstat -ltnp 2>/dev/null | grep -q ":$port "
}

nat_rule_present() {
	iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'CODEX_TRANSPROXY'
}

config_ready() {
	[ -f "$CONFIG_READY_FILE" ] && [ -s "$XRAY_CONFIG" ]
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

	if [ "$model" = "mt3000" ]; then
		status="$(grep "switch" /sys/kernel/debug/gpio 2>/dev/null | grep "hi" || true)"
	elif [ "$model" = "axt1800" ] || [ "$model" = "be3600" ]; then
		status="$(grep "$gpio" /sys/kernel/debug/gpio 2>/dev/null | grep "hi" || true)"
	elif [ "$model" = "a1300" ]; then
		status="$(grep "gpio0" /sys/kernel/debug/gpio 2>/dev/null | grep "lo" || true)"
	else
		status="$(grep "switch" /sys/kernel/debug/gpio 2>/dev/null | grep "lo" || true)"
	fi

	if [ -n "$status" ]; then
		echo 'on'
	else
		echo 'off'
	fi
}

config_value() {
	local expr="$1"
	jsonfilter -i "$XRAY_CONFIG" -e "$expr" 2>/dev/null | sed -n '1p'
}

live_http_port() {
	jsonfilter -i "$XRAY_CONFIG" -e '@.inbounds[0].port' 2>/dev/null | sed -n '1p'
}

live_socks_port() {
	jsonfilter -i "$XRAY_CONFIG" -e '@.inbounds[1].port' 2>/dev/null | sed -n '1p'
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
      "settings": {}
    },
    {
      "listen": "127.0.0.1",
      "port": ${socks_port},
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
                "encryption": "none"
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
	[ -n "$public_key" ] || { echo 'Reality public key is required.'; return 1; }

	validate_pattern "$server_address" '^[A-Za-z0-9._:-]+$' || { echo 'Server address contains unsupported characters.'; return 1; }
	validate_port "$server_port" || { echo 'Server port must be a number from 1 to 65535.'; return 1; }
	validate_pattern "$server_name" '^[A-Za-z0-9.-]+$' || { echo 'Server name contains unsupported characters.'; return 1; }
	validate_pattern "$uuid" '^[A-Za-z0-9-]+$' || { echo 'UUID contains unsupported characters.'; return 1; }
	validate_pattern "$public_key" '^[A-Za-z0-9_-]+$' || { echo 'Public key contains unsupported characters.'; return 1; }
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
	/etc/gl-switch.d/xray.sh "$(current_switch_state)" >/dev/null 2>&1
}

restart_runtime_from_saved_config() {
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

	if "$BIN" run -test -config "$PROBE_CONFIG" >/dev/null 2>&1; then
		PROBE_CONFIG_VALID=1
	else
		return 0
	fi

	probe_cleanup
	"$BIN" run -config "$PROBE_CONFIG" >"$PROBE_STDOUT" 2>&1 &
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

status_json() {
	local switch_state switch_func xray_running redsocks_running http_listen socks_listen redsocks_listen transproxy
	local server_address server_port server_name public_key short_id flow uuid access_log error_log
	local path_requested path_active ready path_state

	switch_state="$(current_switch_state)"
	switch_func="$(uci -q get switch-button.@main[0].func 2>/dev/null || true)"
	config_ready && ready=1 || ready=0

	service_running "$XRAY_PID" && xray_running=1 || xray_running=0
	service_running "$REDSOCKS_PID" && redsocks_running=1 || redsocks_running=0
	listen_present 1083 && http_listen=1 || http_listen=0
	listen_present 1084 && socks_listen=1 || socks_listen=0
	listen_present 12345 && redsocks_listen=1 || redsocks_listen=0
	nat_rule_present && transproxy=1 || transproxy=0

	if [ "$switch_state" = 'on' ]; then
		path_requested=1
	else
		path_requested=0
	fi

	if [ "$xray_running" = '1' ] && [ "$redsocks_running" = '1' ] && [ "$transproxy" = '1' ]; then
		path_active=1
	else
		path_active=0
	fi

	if [ "$switch_state" != 'on' ]; then
		path_state='switch_off'
	elif [ "$ready" != '1' ]; then
		path_state='needs_vps_profile'
	elif [ "$path_active" = '1' ]; then
		path_state='active'
	else
		path_state='inactive'
	fi

	server_address="$(config_value '@.outbounds[0].settings.vnext[0].address')"
	server_port="$(config_value '@.outbounds[0].settings.vnext[0].port')"
	server_name="$(config_value '@.outbounds[0].streamSettings.realitySettings.serverName')"
	public_key="$(config_value '@.outbounds[0].streamSettings.realitySettings.publicKey')"
	short_id="$(config_value '@.outbounds[0].streamSettings.realitySettings.shortId')"
	flow="$(config_value '@.outbounds[0].settings.vnext[0].users[0].flow')"
	uuid="$(config_value '@.outbounds[0].settings.vnext[0].users[0].id')"
	access_log="$(config_value '@.log.access')"
	error_log="$(config_value '@.log.error')"

	printf '{'
	printf '"switch_state":"%s",' "$(json_escape "$switch_state")"
	printf '"switch_func":"%s",' "$(json_escape "$switch_func")"
	printf '"config_ready":'; json_bool "$ready"; printf ','
	printf '"path_state":"%s",' "$(json_escape "$path_state")"
	printf '"path_requested":'; json_bool "$path_requested"; printf ','
	printf '"path_active":'; json_bool "$path_active"; printf ','
	printf '"xray_running":'; json_bool "$xray_running"; printf ','
	printf '"redsocks_running":'; json_bool "$redsocks_running"; printf ','
	printf '"proxy_http_listen":'; json_bool "$http_listen"; printf ','
	printf '"proxy_socks_listen":'; json_bool "$socks_listen"; printf ','
	printf '"redsocks_listen":'; json_bool "$redsocks_listen"; printf ','
	printf '"transproxy_rule":'; json_bool "$transproxy"; printf ','
	printf '"server_address":"%s",' "$(json_escape "$server_address")"
	printf '"server_port":"%s",' "$(json_escape "$server_port")"
	printf '"server_name":"%s",' "$(json_escape "$server_name")"
	printf '"public_key":"%s",' "$(json_escape "$public_key")"
	printf '"short_id":"%s",' "$(json_escape "$short_id")"
	printf '"flow":"%s",' "$(json_escape "$flow")"
	printf '"uuid":"%s",' "$(json_escape "$uuid")"
	printf '"access_log":"%s",' "$(json_escape "$access_log")"
	printf '"error_log":"%s"' "$(json_escape "$error_log")"
	printf '}'
}

logs_json() {
	local switch_logs access_logs error_logs
	switch_logs="$(logread | grep -E 'gl-switch|gl-switch-xray' | tail -n 40 || true)"
	access_logs="$(tail -n 40 /var/log/xray/codex-xray-access.log 2>/dev/null || true)"
	error_logs="$(tail -n 60 /var/log/xray/codex-xray-error.log 2>/dev/null || true)"

	printf '{'
	printf '"switch_logs":"%s",' "$(json_escape "$switch_logs")"
	printf '"access_logs":"%s",' "$(json_escape "$access_logs")"
	printf '"error_logs":"%s"' "$(json_escape "$error_logs")"
	printf '}'
}

smoke_json() {
	local https_test_output egress_output api_output

	https_test_output="$(curl -ksS -I -m 12 -x "$LOCAL_HTTP_PROXY" https://example.com 2>&1 | sed -n '1,20p' || true)"
	egress_output="$(curl -ksS -m 12 -x "$LOCAL_HTTP_PROXY" https://ipinfo.io/ip 2>&1 | sed -n '1,8p' || true)"
	api_output="$(curl -ksS -I -m 12 -x "$LOCAL_HTTP_PROXY" https://api.openai.com/v1/models 2>&1 | sed -n '1,20p' || true)"

	printf '{'
	printf '"https_test":"%s",' "$(json_escape "$https_test_output")"
	printf '"egress":"%s",' "$(json_escape "$egress_output")"
	printf '"openai_api":"%s"' "$(json_escape "$api_output")"
	printf '}'
}

emit_ok_with_status() {
	local action="$1"
	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"%s",' "$(json_escape "$action")"
	printf '"status":'
	status_json
	printf '}'
}

action_sync() {
	if sync_to_hardware_switch; then
		sleep 2
		emit_ok_with_status sync
	else
		emit_error sync 'Failed to resync runtime state from the hardware switch.'
	fi
}

action_restart() {
	if restart_runtime_from_saved_config; then
		sleep 2
		emit_ok_with_status restart
	else
		emit_error restart 'Failed to restart runtime and reapply the current hardware-switch state.'
	fi
}

action_probe() {
	local server_address server_port server_name uuid public_key short_id flow

	server_address="$(request_value server_address)"
	server_port="$(request_value server_port)"
	server_name="$(request_value server_name)"
	uuid="$(request_value uuid)"
	public_key="$(request_value public_key)"
	short_id="$(request_value short_id)"
	flow="$(request_value flow)"

	run_candidate_probe "$server_address" "$server_port" "$server_name" "$uuid" "$public_key" "$short_id" "$flow"

	emit_header
	probe_json
}

action_save() {
	local server_address server_port server_name uuid public_key short_id flow
	local live_http_port_value live_socks_port_value backup target test_output

	server_address="$(request_value server_address)"
	server_port="$(request_value server_port)"
	server_name="$(request_value server_name)"
	uuid="$(request_value uuid)"
	public_key="$(request_value public_key)"
	short_id="$(request_value short_id)"
	flow="$(request_value flow)"

	run_candidate_probe "$server_address" "$server_port" "$server_name" "$uuid" "$public_key" "$short_id" "$flow"

	if [ "$PROBE_SUITABLE" != '1' ]; then
		emit_header
		printf '{'
		printf '"ok":false,'
		printf '"action":"save",'
		printf '"error":"%s",' "$(json_escape 'Candidate server did not pass validation and probe. Nothing was applied.')"
		printf '"probe":'
		probe_json
		printf '}'
		return 0
	fi

	live_http_port_value="$LIVE_HTTP_PORT"
	live_socks_port_value="$LIVE_SOCKS_PORT"
	backup="${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
	target="/etc/xray/codex-xray.tmp.json"
	mkdir -p /etc/xray /var/log/xray

	build_config_file \
		"$target" \
		"$live_http_port_value" \
		"$live_socks_port_value" \
		"$server_address" \
		"$server_port" \
		"$server_name" \
		"$uuid" \
		"$public_key" \
		"$short_id" \
		"$flow" \
		'/var/log/xray/codex-xray-access.log' \
		'/var/log/xray/codex-xray-error.log'

	test_output="$("$BIN" run -test -config "$target" 2>&1 || true)"
	if ! printf '%s' "$test_output" | grep -q 'Configuration OK.'; then
		rm -f "$target"
		emit_error save "Rendered config failed local xray validation: $test_output"
		return 0
	fi

	cp "$XRAY_CONFIG" "$backup"
	mv "$target" "$XRAY_CONFIG"
	chmod 600 "$XRAY_CONFIG"

	if ! restart_runtime_from_saved_config; then
		emit_error save "Saved config, but failed to reapply runtime state. Backup: $backup"
		return 0
	fi

	sleep 2
	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"save",'
	printf '"backup":"%s",' "$(json_escape "$backup")"
	printf '"status":'
	status_json
	printf ','
	printf '"probe":'
	probe_json
	printf '}'
}

REQUEST_DATA="$(load_request_data)"

case "$(request_value action)" in
	''|status)
		emit_header
		status_json
		;;
	sync)
		action_sync
		;;
	restart)
		action_restart
		;;
	logs)
		emit_header
		logs_json
		;;
	smoke)
		emit_header
		smoke_json
		;;
	probe)
		action_probe
		;;
	save)
		action_save
		;;
	on|off)
		emit_error "$(request_value action)" 'Manual enable/disable from the web page is intentionally disabled. Use the hardware switch instead.'
		;;
	*)
		emit_error "$(request_value action)" 'Unknown action.'
		;;
esac
