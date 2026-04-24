#!/bin/sh
# lib-common.sh — shared functions for vpn-xray router components
# Deployed to /usr/share/vpn-xray/lib-common.sh
# Source with: . /usr/share/vpn-xray/lib-common.sh

# Path defaults — override before sourcing if needed
: "${VX_CONFIG_READY:=/etc/xray/codex-xray.ready}"
: "${VX_CONFIG:=/etc/xray/codex-xray.json}"
: "${VX_BIN:=/usr/local/bin/codex-xray-core}"

# --- Hardware switch ---

current_switch_state() {
	local model gpio status

	if [ ! -f /proc/gl-hw-info/switch-button ] || [ ! -f /proc/gl-hw-info/model ]; then
		echo unknown
		return
	fi

	model="$(cat /proc/gl-hw-info/model 2>/dev/null || true)"
	gpio="$(cat /proc/gl-hw-info/switch-button 2>/dev/null || true)"

	if [ -z "$model" ] || [ -z "$gpio" ]; then
		echo unknown
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
		echo on
	else
		echo off
	fi
}

# --- Config readiness ---

config_ready() {
	[ -f "$VX_CONFIG_READY" ] && [ -s "$VX_CONFIG" ]
}

path_requested() {
	[ "$(current_switch_state)" = 'on' ] || return 1
	config_ready || return 1
	return 0
}

# --- JSON helpers ---

json_escape() {
	printf '%s' "${1:-}" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r/\\r/g;s/\t/\\t/g;s/\n/\\n/g'
}

json_bool() {
	if [ "${1:-0}" = '1' ]; then
		printf 'true'
	else
		printf 'false'
	fi
}

# --- CGI request helpers ---

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
			''|*[!0-9]*) len=0 ;;
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

# --- CGI response helpers ---

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

# --- Network helpers ---

lan_device() {
	local value

	value="$(uci -q get network.lan.device 2>/dev/null || true)"
	[ -n "$value" ] || value="$(uci -q get network.lan.ifname 2>/dev/null || true)"
	case "$value" in
		''|*' '*)
			value='br-lan'
			;;
	esac
	printf '%s\n' "$value"
}

# --- Locking ---

with_flock() {
	local lock_file="$1" max_wait="$2" cmd="$3" rc=0
	shift 3
	local waited=0
	exec 9>"$lock_file"
	while ! flock -n 9 2>/dev/null; do
		if [ "$waited" -ge "$max_wait" ]; then
			echo 'router-rules lock timeout' >&2
			exec 9>&-
			return 1
		fi
		sleep 1
		waited=$((waited + 1))
	done
	"$cmd" "$@" || rc=$?
	exec 9>&-
	return "$rc"
}
