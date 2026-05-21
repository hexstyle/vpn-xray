#!/bin/sh
# lib-common.sh — shared functions for vpn-xray router components
# Deployed to /usr/share/vpn-xray/lib-common.sh
# Source with: . /usr/share/vpn-xray/lib-common.sh

# Path defaults — override before sourcing if needed
: "${VX_CONFIG_READY:=/etc/xray/codex-xray.ready}"
: "${VX_CONFIG:=/etc/xray/codex-xray.json}"
: "${VX_BIN:=/usr/local/bin/codex-xray-core}"
: "${VX_FAILSAFE_CHAIN:=CODEX_XRAY_FAILSAFE}"
: "${VX_FAILSAFE_STATE:=/var/run/codex-xray-failsafe}"
: "${VX_FAILSAFE_HOLD:=/var/run/codex-xray-failsafe.hold}"

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
	printf '%s' "${1:-}" | awk '
		BEGIN { ORS="" }
		{
			gsub(/\\/, "\\\\")
			gsub(/"/, "\\\"")
			gsub(/\t/, "\\t")
			gsub(/\r/, "\\r")
			if (NR > 1) printf "\\n"
			printf "%s", $0
		}
	'
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

# --- Client fail-safe kill switch ---

xray_failsafe_state_value() {
	local key="$1"
	local file="${2:-$VX_FAILSAFE_STATE}"

	sed -n "s/^${key}=//p" "$file" 2>/dev/null | sed -n '1p'
}

xray_failsafe_hold_clear() {
	rm -f "$VX_FAILSAFE_HOLD"
}

xray_failsafe_hold_set() {
	local reason="${1:-runtime unavailable}"
	local seconds="${2:-300}"
	local now until

	case "$seconds" in
		''|*[!0-9]*) seconds=300 ;;
	esac
	now="$(date +%s)"
	until=$((now + seconds))
	mkdir -p "$(dirname "$VX_FAILSAFE_HOLD")"
	{
		printf 'since=%s\n' "$now"
		printf 'until=%s\n' "$until"
		printf 'reason=%s\n' "$reason"
	} > "$VX_FAILSAFE_HOLD"
}

xray_failsafe_hold_active() {
	local until now

	[ -f "$VX_FAILSAFE_HOLD" ] || return 1
	until="$(xray_failsafe_state_value until "$VX_FAILSAFE_HOLD")"
	case "$until" in
		''|*[!0-9]*)
			rm -f "$VX_FAILSAFE_HOLD"
			return 1
			;;
	esac
	now="$(date +%s)"
	if [ "$now" -lt "$until" ] 2>/dev/null; then
		return 0
	fi
	rm -f "$VX_FAILSAFE_HOLD"
	return 1
}

xray_failsafe_enable() {
	local reason="${1:-xray path unavailable}"
	local lan_if

	lan_if="$(lan_device)"
	[ -n "$lan_if" ] || lan_if='br-lan'

	iptables -N "$VX_FAILSAFE_CHAIN" 2>/dev/null || true
	iptables -F "$VX_FAILSAFE_CHAIN" 2>/dev/null || true
	iptables -A "$VX_FAILSAFE_CHAIN" -j REJECT --reject-with icmp-net-unreachable 2>/dev/null \
		|| iptables -A "$VX_FAILSAFE_CHAIN" -j REJECT 2>/dev/null \
		|| true
	iptables -C FORWARD -i "$lan_if" -j "$VX_FAILSAFE_CHAIN" >/dev/null 2>&1 \
		|| iptables -I FORWARD 1 -i "$lan_if" -j "$VX_FAILSAFE_CHAIN" 2>/dev/null \
		|| true

	ip6tables -N "$VX_FAILSAFE_CHAIN" 2>/dev/null || true
	ip6tables -F "$VX_FAILSAFE_CHAIN" 2>/dev/null || true
	ip6tables -A "$VX_FAILSAFE_CHAIN" -j REJECT 2>/dev/null || true
	ip6tables -C FORWARD -i "$lan_if" -j "$VX_FAILSAFE_CHAIN" >/dev/null 2>&1 \
		|| ip6tables -I FORWARD 1 -i "$lan_if" -j "$VX_FAILSAFE_CHAIN" 2>/dev/null \
		|| true

	mkdir -p "$(dirname "$VX_FAILSAFE_STATE")"
	{
		printf 'active=1\n'
		printf 'since=%s\n' "$(date +%s)"
		printf 'lan_if=%s\n' "$lan_if"
		printf 'reason=%s\n' "$reason"
	} > "$VX_FAILSAFE_STATE"
	logger -t codex-xray-failsafe "enabled reason=$reason lan_if=$lan_if" 2>/dev/null || true
}

xray_failsafe_disable_for_iface() {
	local lan_if="$1"

	[ -n "$lan_if" ] || return 0
	while iptables -D FORWARD -i "$lan_if" -j "$VX_FAILSAFE_CHAIN" >/dev/null 2>&1; do :; done
	while ip6tables -D FORWARD -i "$lan_if" -j "$VX_FAILSAFE_CHAIN" >/dev/null 2>&1; do :; done
}

xray_failsafe_disable() {
	local stored_if current_if

	stored_if="$(xray_failsafe_state_value lan_if)"
	current_if="$(lan_device)"
	xray_failsafe_disable_for_iface "$stored_if"
	xray_failsafe_disable_for_iface "$current_if"
	xray_failsafe_disable_for_iface br-lan
	iptables -F "$VX_FAILSAFE_CHAIN" 2>/dev/null || true
	iptables -X "$VX_FAILSAFE_CHAIN" 2>/dev/null || true
	ip6tables -F "$VX_FAILSAFE_CHAIN" 2>/dev/null || true
	ip6tables -X "$VX_FAILSAFE_CHAIN" 2>/dev/null || true
	rm -f "$VX_FAILSAFE_STATE"
	logger -t codex-xray-failsafe 'disabled' 2>/dev/null || true
}

xray_failsafe_active() {
	local lan_if

	[ -f "$VX_FAILSAFE_STATE" ] && return 0
	lan_if="$(lan_device)"
	iptables -C FORWARD -i "$lan_if" -j "$VX_FAILSAFE_CHAIN" >/dev/null 2>&1
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
