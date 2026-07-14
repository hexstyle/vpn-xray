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
LOCAL_HTTP_PROXY="${LOCAL_HTTP_PROXY:-http://127.0.0.1:1083}"
LIVE_HTTP_PORT='1083'
LIVE_SOCKS_PORT='1084'
CONFIG_READY_FILE='/etc/xray/codex-xray.ready'
STATUS_FILE='/tmp/xray-admin.status'
SWITCH_SYNC_WAIT_SECONDS='25'

REQUEST_DATA=''

VX_CONFIG="$XRAY_CONFIG"
VX_CONFIG_READY="$CONFIG_READY_FILE"
. "${VX_LIB_COMMON:-/usr/share/vpn-xray/lib-common.sh}"

status_file_value() {
	sed -n "s/^$1=//p" "$STATUS_FILE" 2>/dev/null | sed -n '1p'
}

status_file_set() {
	local key="$1"
	local value="$2"
	local tmp

	tmp="$(mktemp)"
	if [ -f "$STATUS_FILE" ]; then
		grep -v "^${key}=" "$STATUS_FILE" > "$tmp" || true
	fi
	printf '%s=%s\n' "$key" "$value" >> "$tmp"
	mv "$tmp" "$STATUS_FILE"
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

runtime_path_active() {
	service_running "$XRAY_PID" || return 1
	service_running "$REDSOCKS_PID" || return 1
	nat_rule_present || return 1
	return 0
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

# Probe/build/runtime and status/smoke/health function groups live in
# sourced libs (AGENTS.md 500-line rule). They define functions only and
# share this scope, so ordering vs the helpers above does not matter.
. "${VX_ADMIN_PROBE_LIB:-/usr/share/vpn-xray/xray-admin-probe.sh}"
. "${VX_ADMIN_STATUS_LIB:-/usr/share/vpn-xray/xray-admin-status.sh}"
. "${VX_ADMIN_TREE_LIB:-/usr/share/vpn-xray/xray-admin-tree.sh}"

_wait_for_xray_pid() {
	_i=0
	while [ "$_i" -lt 5 ]; do
		_pid="$(cat /var/run/codex-xray.pid 2>/dev/null || true)"
		[ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null && return 0
		sleep 1
		_i=$((_i + 1))
	done
}

action_sync() {
	if sync_to_hardware_switch; then
		_wait_for_xray_pid
		emit_ok_with_status sync
	else
		emit_error sync 'Failed to resync runtime state from the hardware switch.'
	fi
}

action_restart() {
	if restart_runtime_from_saved_config; then
		_wait_for_xray_pid
		emit_ok_with_status restart
	else
		emit_error restart 'Failed to restart runtime and reapply the current hardware-switch state.'
	fi
}

action_recover() {
	if restart_runtime_from_saved_config; then
		_wait_for_xray_pid
		emit_ok_with_status recover
	else
		emit_error recover 'Failed to clear fail-safe hold and restart the Xray path.'
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

	_wait_for_xray_pid
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

install_status_json() {
	local payload=''

	# /tmp/vpn-xray-install-status.json is written by install-router.sh and
	# install-platform.sh through common/lib/install-progress.sh. The UI
	# polls this endpoint to render a live banner while a deploy is in
	# progress and to keep a failed-state banner visible until the install
	# finishes successfully.
	if [ -s /tmp/vpn-xray-install-status.json ]; then
		payload="$(cat /tmp/vpn-xray-install-status.json 2>/dev/null || true)"
	fi

	if [ -z "$payload" ]; then
		printf '{"schema":1,"state":"idle"}'
	else
		printf '%s' "$payload"
	fi
}

case "$(request_value action)" in
	''|status)
		emit_header
		status_json
		;;
	install_status)
		emit_header
		install_status_json
		;;
	sync)
		action_sync
		;;
	restart)
		action_restart
		;;
	recover)
		action_recover
		;;
	logs)
		emit_header
		logs_json
		;;
	smoke)
		emit_header
		smoke_json
		;;
	health)
		emit_header
		health_json
		;;
	tree)
		emit_header
		tree_json
		;;
	node_repair)
		emit_header
		node_repair_json "$(request_value node)"
		;;
	tree_repair)
		emit_header
		tree_repair_json
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
