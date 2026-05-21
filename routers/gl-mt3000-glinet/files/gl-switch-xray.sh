#!/bin/sh

ACTION="$1"
TAG="gl-switch-xray"
RUNNER_PID="/var/run/gl-switch-xray-helper.pid"
RUNNER_ACTION="/var/run/gl-switch-xray-helper.action"
CONFIG_READY_FILE="/etc/xray/codex-xray.ready"
ROUTER_CONFIG="/etc/xray/codex-xray.json"
WAIT_ACTIVE_SECONDS=25
WAIT_INACTIVE_SECONDS=15

. "${VX_LIB_COMMON:-/usr/share/vpn-xray/lib-common.sh}"

log() {
	logger -t "$TAG" "$*"
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

xray_runtime_ready() {
	service_running /var/run/codex-xray.pid || return 1
	listen_present 1083 || return 1
	listen_present 1084 || return 1
	return 0
}

transproxy_runtime_ready() {
	service_running /var/run/redsocks.pid || return 1
	listen_present 12345 || return 1
	nat_rule_present || return 1
	return 0
}

runtime_path_active() {
	xray_runtime_ready || return 1
	transproxy_runtime_ready || return 1
	return 0
}

runtime_path_inactive() {
	service_running /var/run/codex-xray.pid && return 1
	service_running /var/run/redsocks.pid && return 1
	listen_present 1083 && return 1
	listen_present 1084 && return 1
	listen_present 12345 && return 1
	nat_rule_present && return 1
	return 0
}

wait_for_runtime_state() {
	local wanted="$1"
	local max_wait="$2"
	local tries=0

	while [ "$tries" -lt "$max_wait" ]; do
		case "$wanted" in
			active)
				if runtime_path_active; then
					return 0
				fi
				;;
			inactive)
				if runtime_path_inactive; then
					return 0
				fi
				;;
		esac
		tries=$((tries + 1))
		sleep 1
	done

	return 1
}

cleanup_runner_state() {
	rm -f "$RUNNER_PID" "$RUNNER_ACTION"
}

helper_run_on() {
	trap cleanup_runner_state EXIT INT TERM

	if ! config_ready; then
		log "helper skipped on action because router config is not ready yet"
		exit 0
	fi
	if xray_failsafe_hold_active; then
		xray_failsafe_enable "recovery hold active: $(xray_failsafe_state_value reason "$VX_FAILSAFE_HOLD")"
		log "helper skipped on action because fail-safe hold is active"
		exit 1
	fi
	if runtime_path_active; then
		xray_failsafe_disable
		log "helper confirmed path already active"
		exit 0
	fi
	xray_failsafe_enable 'switch on requested; waiting for Xray path to become active'

	if ! xray_runtime_ready; then
		/etc/init.d/codex-xray start >/dev/null 2>&1 || true
		if ! xray_runtime_ready; then
			log "helper failed to start codex-xray"
			exit 1
		fi
	fi
	if ! transproxy_runtime_ready; then
		/etc/init.d/codex-transproxy start >/dev/null 2>&1 || true
		if ! transproxy_runtime_ready; then
			log "helper failed to start codex-transproxy"
			exit 1
		fi
	fi
	if wait_for_runtime_state active "$WAIT_ACTIVE_SECONDS"; then
		xray_failsafe_disable
		log "helper confirmed path is active"
		exit 0
	fi

	log "helper timed out waiting for active runtime"
	exit 1
}

helper_run_off() {
	trap cleanup_runner_state EXIT INT TERM

	if runtime_path_inactive; then
		log "helper confirmed path already inactive"
		exit 0
	fi

	/etc/init.d/codex-transproxy stop >/dev/null 2>&1 || true
	/etc/init.d/codex-xray stop >/dev/null 2>&1 || true
	if wait_for_runtime_state inactive "$WAIT_INACTIVE_SECONDS"; then
		if path_requested; then
			xray_failsafe_enable 'Xray path stopped while switch still requests protection'
		else
			xray_failsafe_disable
		fi
		log "helper confirmed path is inactive"
		exit 0
	fi

	log "helper timed out waiting for inactive runtime"
	exit 1
}

run_async() {
	local active_pid active_action

	active_pid="$(cat "$RUNNER_PID" 2>/dev/null || true)"
	active_action="$(cat "$RUNNER_ACTION" 2>/dev/null || true)"
	if [ -n "$active_pid" ] && kill -0 "$active_pid" 2>/dev/null; then
		if [ "$active_action" = "$ACTION" ]; then
			log "helper already processing action=$ACTION"
			return 0
		fi
		start-stop-daemon -K -p "$RUNNER_PID" -x "$0" >/dev/null 2>&1 || true
	fi
	rm -f "$RUNNER_PID"
	printf '%s\n' "$ACTION" > "$RUNNER_ACTION"
	start-stop-daemon -S -b -m -p "$RUNNER_PID" -x "$0" -- "$1"
}

case "$ACTION" in
	__run_on)
		helper_run_on
		;;
	__run_off)
		helper_run_off
		;;
	on)
		if ! config_ready; then
			log "path requested, but router config is not ready yet; waiting for VPS setup"
			exit 0
		fi
		if xray_failsafe_hold_active; then
			xray_failsafe_enable "recovery hold active: $(xray_failsafe_state_value reason "$VX_FAILSAFE_HOLD")"
			log "path requested, but fail-safe hold is active; use recover to retry immediately"
			exit 1
		fi
		if runtime_path_active; then
			xray_failsafe_disable
			log "path already active"
			exit 0
		fi
		log "enabling codex-xray path"
		run_async __run_on
		;;
	recover)
		if ! config_ready; then
			log "recover requested, but router config is not ready yet"
			exit 1
		fi
		xray_failsafe_hold_clear
		xray_failsafe_enable 'manual recovery requested; holding client traffic until Xray path is active'
		log "manual recovery requested"
		run_async __run_on
		;;
	off)
		if runtime_path_inactive; then
			if path_requested; then
				xray_failsafe_enable 'Xray path inactive while switch still requests protection'
			else
				xray_failsafe_disable
			fi
			log "path already inactive"
			exit 0
		fi
		log "disabling codex-xray path"
		run_async __run_off
		;;
	*)
		echo "usage: $0 {on|off|recover}" >&2
		exit 1
		;;
esac
