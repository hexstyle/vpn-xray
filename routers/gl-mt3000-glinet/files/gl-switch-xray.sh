#!/bin/sh

ACTION="$1"
TAG="gl-switch-xray"
RUNNER_PID="/var/run/gl-switch-xray-helper.pid"
RUNNER_ACTION="/var/run/gl-switch-xray-helper.action"
CONFIG_READY_FILE="/etc/xray/codex-xray.ready"
ROUTER_CONFIG="/etc/xray/codex-xray.json"

log() {
	logger -t "$TAG" "$*"
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
		start-stop-daemon -K -p "$RUNNER_PID" -x /bin/sh >/dev/null 2>&1 || true
	fi
	rm -f "$RUNNER_PID"
	printf '%s\n' "$ACTION" > "$RUNNER_ACTION"
	start-stop-daemon -S -b -m -p "$RUNNER_PID" -x /bin/sh -- -c "$1"
}

config_ready() {
	[ -f "$CONFIG_READY_FILE" ] && [ -s "$ROUTER_CONFIG" ]
}

case "$ACTION" in
	on)
		if ! config_ready; then
			log "path requested, but router config is not ready yet; waiting for VPS setup"
			exit 0
		fi
		log "enabling codex-xray path"
		run_async '
			/etc/init.d/codex-xray start >/dev/null 2>&1 || exit 1
			/etc/init.d/codex-transproxy start >/dev/null 2>&1 || {
				/etc/init.d/codex-xray stop >/dev/null 2>&1 || true
				exit 1
			}
		'
		;;
	off)
		log "disabling codex-xray path"
		run_async '
			/etc/init.d/codex-transproxy stop >/dev/null 2>&1 || true
			/etc/init.d/codex-xray stop >/dev/null 2>&1 || true
		'
		;;
	*)
		echo "usage: $0 {on|off}" >&2
		exit 1
		;;
esac
