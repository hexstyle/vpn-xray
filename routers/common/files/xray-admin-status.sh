#!/bin/sh
# xray-admin-status.sh — status, logs, smoke, and health JSON for the
# xray-admin CGI. Deployed to /usr/share/vpn-xray/xray-admin-status.sh
# Sourced by /www/cgi-bin/xray-admin after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

status_json() {
	local switch_state switch_func xray_running redsocks_running http_listen socks_listen redsocks_listen transproxy
	local server_address server_port server_name public_key short_id flow uuid access_log error_log
	local path_requested path_active ready path_state path_smoke_checked path_effective path_degraded
	local last_smoke_at last_smoke_status last_smoke_message last_smoke_http_ok last_smoke_https_ok last_smoke_egress_ok last_smoke_openai_ok
	local failsafe_active failsafe_reason failsafe_since failsafe_hold_active failsafe_hold_until failsafe_hold_reason

	switch_state="$(current_switch_state)"
	switch_func="$(uci -q get switch-button.@main[0].func 2>/dev/null || true)"
	config_ready && ready=1 || ready=0

	service_running "$XRAY_PID" && xray_running=1 || xray_running=0
	service_running "$REDSOCKS_PID" && redsocks_running=1 || redsocks_running=0
	listen_present 1083 && http_listen=1 || http_listen=0
	listen_present 1084 && socks_listen=1 || socks_listen=0
	listen_present 12345 && redsocks_listen=1 || redsocks_listen=0
	nat_rule_present && transproxy=1 || transproxy=0
	xray_failsafe_active && failsafe_active=1 || failsafe_active=0
	xray_failsafe_hold_active && failsafe_hold_active=1 || failsafe_hold_active=0
	failsafe_reason="$(xray_failsafe_state_value reason)"
	failsafe_since="$(xray_failsafe_state_value since)"
	failsafe_hold_until="$(xray_failsafe_state_value until "$VX_FAILSAFE_HOLD")"
	failsafe_hold_reason="$(xray_failsafe_state_value reason "$VX_FAILSAFE_HOLD")"

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

	server_address="$(config_value '@.outbounds[0].settings.vnext[0].address')"
	server_port="$(config_value '@.outbounds[0].settings.vnext[0].port')"
	# WS+TLS transport: serverName lives in tlsSettings. Fall back to
	# realitySettings for a config still on the legacy transport so an
	# in-place upgrade reads the old value before re-rendering as WS+TLS.
	server_name="$(config_value '@.outbounds[0].streamSettings.tlsSettings.serverName')"
	[ -n "$server_name" ] || server_name="$(config_value '@.outbounds[0].streamSettings.realitySettings.serverName')"
	public_key="$(config_value '@.outbounds[0].streamSettings.realitySettings.publicKey')"
	short_id="$(config_value '@.outbounds[0].streamSettings.realitySettings.shortId')"
	flow="$(config_value '@.outbounds[0].settings.vnext[0].users[0].flow')"
	uuid="$(config_value '@.outbounds[0].settings.vnext[0].users[0].id')"
	access_log="$(config_value '@.log.access')"
	error_log="$(config_value '@.log.error')"
	last_smoke_at="$(status_file_value last_smoke_at)"
	last_smoke_status="$(status_file_value last_smoke_status)"
	last_smoke_message="$(status_file_value last_smoke_message)"
	last_smoke_http_ok="$(status_file_value last_smoke_http_ok)"
	last_smoke_https_ok="$(status_file_value last_smoke_https_ok)"
	last_smoke_egress_ok="$(status_file_value last_smoke_egress_ok)"
	last_smoke_openai_ok="$(status_file_value last_smoke_openai_ok)"

	case "$last_smoke_at" in
		''|*[!0-9]*)
			path_smoke_checked=0
			;;
		*)
			if [ "$last_smoke_at" -gt 0 ]; then
				path_smoke_checked=1
			else
				path_smoke_checked=0
			fi
			;;
	esac

	if [ "$path_active" = '1' ] && [ "$path_smoke_checked" = '1' ] && [ "$last_smoke_status" != 'ok' ]; then
		path_degraded=1
	else
		path_degraded=0
	fi

	if [ "$path_active" = '1' ] && [ "$path_smoke_checked" = '1' ] && [ "$last_smoke_status" = 'ok' ]; then
		path_effective=1
	else
		path_effective=0
	fi

	if [ "$switch_state" != 'on' ]; then
		path_state='switch_off'
	elif [ "$ready" != '1' ]; then
		path_state='needs_vps_profile'
	elif [ "$failsafe_active" = '1' ]; then
		path_state='failsafe'
	elif [ "$path_degraded" = '1' ]; then
		path_state='degraded'
	elif [ "$path_active" = '1' ]; then
		path_state='active'
	else
		path_state='inactive'
	fi

	printf '{'
	printf '"switch_state":"%s",' "$(json_escape "$switch_state")"
	printf '"switch_func":"%s",' "$(json_escape "$switch_func")"
	printf '"config_ready":'; json_bool "$ready"; printf ','
	printf '"path_state":"%s",' "$(json_escape "$path_state")"
	printf '"path_requested":'; json_bool "$path_requested"; printf ','
	printf '"path_active":'; json_bool "$path_active"; printf ','
	printf '"path_smoke_checked":'; json_bool "$path_smoke_checked"; printf ','
	printf '"path_effective":'; json_bool "$path_effective"; printf ','
	printf '"path_degraded":'; json_bool "$path_degraded"; printf ','
	printf '"failsafe_active":'; json_bool "$failsafe_active"; printf ','
	printf '"failsafe_reason":"%s",' "$(json_escape "$failsafe_reason")"
	printf '"failsafe_since":"%s",' "$(json_escape "$failsafe_since")"
	printf '"failsafe_hold_active":'; json_bool "$failsafe_hold_active"; printf ','
	printf '"failsafe_hold_until":"%s",' "$(json_escape "$failsafe_hold_until")"
	printf '"failsafe_hold_reason":"%s",' "$(json_escape "$failsafe_hold_reason")"
	printf '"xray_running":'; json_bool "$xray_running"; printf ','
	printf '"redsocks_running":'; json_bool "$redsocks_running"; printf ','
	printf '"proxy_http_listen":'; json_bool "$http_listen"; printf ','
	printf '"proxy_socks_listen":'; json_bool "$socks_listen"; printf ','
	printf '"redsocks_listen":'; json_bool "$redsocks_listen"; printf ','
	printf '"transproxy_rule":'; json_bool "$transproxy"; printf ','
	printf '"last_smoke_at":"%s",' "$(json_escape "$last_smoke_at")"
	printf '"last_smoke_status":"%s",' "$(json_escape "$last_smoke_status")"
	printf '"last_smoke_message":"%s",' "$(json_escape "$last_smoke_message")"
	printf '"last_smoke_http_ok":'; json_bool "${last_smoke_http_ok:-0}"; printf ','
	printf '"last_smoke_https_ok":'; json_bool "${last_smoke_https_ok:-0}"; printf ','
	printf '"last_smoke_egress_ok":'; json_bool "${last_smoke_egress_ok:-0}"; printf ','
	printf '"last_smoke_openai_ok":'; json_bool "${last_smoke_openai_ok:-0}"; printf ','
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

smoke_output_has_final_http_status() {
	local value="$1"

	printf '%s\n' "$value" \
		| grep -v '^HTTP/[0-9.][0-9.]* 200 Connection established$' \
		| grep -Eq '^HTTP/[0-9.][0-9.]* [1-5][0-9][0-9]'
}

smoke_output_has_success_like_http_status() {
	local value="$1"

	printf '%s\n' "$value" \
		| grep -v '^HTTP/[0-9.][0-9.]* 200 Connection established$' \
		| grep -Eq '^HTTP/[0-9.][0-9.]* (200|204|301|302|307|308|401|403)'
}

smoke_output_has_ip() {
	local value="$1"

	printf '%s\n' "$value" | grep -Eq '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}($|[^0-9])'
}

record_smoke_status() {
	local overall="$1"
	local message="$2"
	local http_ok="$3"
	local https_ok="$4"
	local egress_ok="$5"
	local openai_ok="$6"
	local now

	now="$(date +%s)"
	status_file_set last_smoke_at "$now"
	status_file_set last_smoke_status "$overall"
	status_file_set last_smoke_message "$message"
	status_file_set last_smoke_http_ok "$http_ok"
	status_file_set last_smoke_https_ok "$https_ok"
	status_file_set last_smoke_egress_ok "$egress_ok"
	status_file_set last_smoke_openai_ok "$openai_ok"
}

health_json() {
	local health_log='/tmp/xray-health.tsv'
	local alert_log='/tmp/xray-health-alerts.log'
	local crash_log='/etc/xray-crash-log'
	local mem_total

	mem_total="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
	printf '{"mem_total_kb":%s,' "${mem_total:-0}"
	printf '"samples":['
	if [ -f "$health_log" ]; then
		awk -F'\t' '
		BEGIN { first=1 }
		NF>=11 {
			if (!first) printf ","
			printf "{\"t\":%s,\"ma\":%s,\"la\":\"%s\",\"xr\":%s,\"xf\":%s,\"xt\":%s,\"ct\":%s,\"rx\":%s,\"xu\":%s,\"ru\":%s,\"co\":%s}",
				$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11
			first=0
		}' "$health_log"
	fi
	printf '],"alerts":['
	if [ -f "$alert_log" ]; then
		awk -F'\t' '
		BEGIN { first=1 }
		NF>=2 {
			if (!first) printf ","
			gsub(/"/, "\\\"", $2)
			printf "{\"t\":%s,\"msg\":\"%s\"}", $1, $2
			first=0
		}' "$alert_log"
	fi
	printf '],"crashes":['
	if [ -f "$crash_log" ]; then
		awk -F'\t' '
		BEGIN { first=1 }
		NF>=2 {
			if (!first) printf ","
			gsub(/"/, "\\\"", $2)
			printf "{\"t\":%s,\"msg\":\"%s\"}", $1, $2
			first=0
		}' "$crash_log"
	fi
	printf ']}'
}

smoke_json() {
	local http_test_output https_test_output egress_output api_output
	local http_ok https_ok egress_ok openai_ok overall_status overall_message

	http_test_output="$(curl -ksS -I -m 5 -x "$LOCAL_HTTP_PROXY" https://example.com 2>&1 | sed -n '1,20p' || true)"
	https_test_output="$(curl -ksS -I -m 5 --socks5-hostname "127.0.0.1:${LIVE_SOCKS_PORT}" https://example.com 2>&1 | sed -n '1,20p' || true)"
	egress_output="$(curl -ksS -m 5 --socks5-hostname "127.0.0.1:${LIVE_SOCKS_PORT}" https://ipinfo.io/ip 2>&1 | sed -n '1,8p' || true)"
	api_output="$(curl -ksS -I -m 5 --socks5-hostname "127.0.0.1:${LIVE_SOCKS_PORT}" https://api.openai.com/v1/models 2>&1 | sed -n '1,20p' || true)"

	http_ok=0
	if ! printf '%s' "$http_test_output" | grep -q 'curl:' && smoke_output_has_success_like_http_status "$http_test_output"; then
		http_ok=1
	fi

	https_ok=0
	egress_ok=0
	openai_ok=0
	if ! printf '%s' "$https_test_output" | grep -q 'curl:' && smoke_output_has_success_like_http_status "$https_test_output"; then
		https_ok=1
	fi
	if ! printf '%s' "$egress_output" | grep -q 'curl:' && smoke_output_has_ip "$egress_output"; then
		egress_ok=1
	fi
	if ! printf '%s' "$api_output" | grep -q 'curl:' && smoke_output_has_final_http_status "$api_output"; then
		openai_ok=1
	fi

	if [ "$https_ok" = '1' ] && [ "$egress_ok" = '1' ] && [ "$openai_ok" = '1' ]; then
		overall_status='ok'
		if [ "$http_ok" = '1' ]; then
			overall_message='Live transparent proxy path is healthy.'
		else
			overall_message='Transparent proxy path is healthy, but the local HTTP proxy probe failed.'
		fi
	else
		overall_status='error'
		if [ "$https_ok" != '1' ]; then
			overall_message='Smoke HTTPS probe failed through the local SOCKS/transparent path.'
		elif [ "$egress_ok" != '1' ]; then
			overall_message='Smoke egress IP probe failed through the local SOCKS/transparent path.'
		else
			overall_message='Smoke OpenAI API probe failed through the local SOCKS/transparent path.'
		fi
	fi
	record_smoke_status "$overall_status" "$overall_message" "$http_ok" "$https_ok" "$egress_ok" "$openai_ok"

	printf '{'
	printf '"ok":'; json_bool "$([ "$overall_status" = 'ok' ] && printf 1 || printf 0)"; printf ','
	printf '"status":"%s",' "$(json_escape "$overall_status")"
	printf '"message":"%s",' "$(json_escape "$overall_message")"
	printf '"http_ok":'; json_bool "$http_ok"; printf ','
	printf '"https_ok":'; json_bool "$https_ok"; printf ','
	printf '"egress_ok":'; json_bool "$egress_ok"; printf ','
	printf '"openai_ok":'; json_bool "$openai_ok"; printf ','
	printf '"http_test":"%s",' "$(json_escape "$http_test_output")"
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
