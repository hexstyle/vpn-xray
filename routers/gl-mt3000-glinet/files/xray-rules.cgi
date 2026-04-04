#!/bin/sh

set -e

PATH='/usr/sbin:/usr/bin:/sbin:/bin'
REQUEST_DATA=''

emit_header() {
	printf 'Content-Type: application/json\r\n'
	printf 'Cache-Control: no-store\r\n'
	printf '\r\n'
}

json_escape() {
	printf '%s' "${1:-}" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r/\\r/g;s/\t/\\t/g;s/\n/\\n/g'
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

request_has_key() {
	printf '%s' "$REQUEST_DATA" | tr '&' '\n' | grep -q "^$1="
}

status_action() {
	emit_header
	/usr/bin/router-rules status-json
}

sync_action() {
	local tmp rules_text base_repo_head
	tmp="$(mktemp)"
	base_repo_head=''

	if request_has_key rules_text; then
		rules_text="$(request_value rules_text)"
		printf '%s\n' "$rules_text" > "$tmp"
	fi
	if request_has_key base_repo_head; then
		base_repo_head="$(request_value base_repo_head)"
	fi

	/usr/bin/router-rules ensure-git-key >/dev/null 2>&1 || true
	if command -v timeout >/dev/null 2>&1; then
		if request_has_key rules_text; then
			ROUTER_RULES_BASE_HEAD="$base_repo_head" ROUTER_RULES_SYNC_ACTOR='ui-sync' timeout 180 /usr/bin/router-rules save-sync-apply-xray "$tmp" >/dev/null 2>&1 || {
				rm -f "$tmp"
				emit_error sync_rules 'Rules sync/apply failed.'
				return 0
			}
		else
			ROUTER_RULES_BASE_HEAD="$base_repo_head" ROUTER_RULES_SYNC_ACTOR='ui-sync' timeout 180 /usr/bin/router-rules sync-apply-xray >/dev/null 2>&1 || {
				rm -f "$tmp"
				emit_error sync_rules 'Rules sync/apply failed.'
				return 0
			}
		fi
	else
		if request_has_key rules_text; then
			ROUTER_RULES_BASE_HEAD="$base_repo_head" ROUTER_RULES_SYNC_ACTOR='ui-sync' /usr/bin/router-rules save-sync-apply-xray "$tmp" >/dev/null 2>&1 || {
				rm -f "$tmp"
				emit_error sync_rules 'Rules sync/apply failed.'
				return 0
			}
		else
			ROUTER_RULES_BASE_HEAD="$base_repo_head" ROUTER_RULES_SYNC_ACTOR='ui-sync' /usr/bin/router-rules sync-apply-xray >/dev/null 2>&1 || {
				rm -f "$tmp"
				emit_error sync_rules 'Rules sync/apply failed.'
				return 0
			}
		fi
	fi

	rm -f "$tmp"
	status_action
}

set_mode_action() {
	local mode

	mode="$(request_value mode)"
	case "$mode" in
		full|selective)
			;;
		*)
			emit_error set_mode 'Invalid xray mode.'
			return 0
			;;
	esac

	if command -v timeout >/dev/null 2>&1; then
		ROUTER_RULES_SYNC_ACTOR='ui-mode-toggle' timeout 20 /usr/bin/router-rules set-xray-mode "$mode" >/dev/null 2>&1 || {
			emit_error set_mode 'Failed to store local routing mode.'
			return 0
		}
		ROUTER_RULES_SYNC_ACTOR='ui-mode-toggle' timeout 45 /usr/bin/router-rules cutover-xray >/dev/null 2>&1 || {
			emit_error set_mode 'Failed to apply routing mode on this router.'
			return 0
		}
	else
		ROUTER_RULES_SYNC_ACTOR='ui-mode-toggle' /usr/bin/router-rules set-xray-mode "$mode" >/dev/null 2>&1 || {
			emit_error set_mode 'Failed to store local routing mode.'
			return 0
		}
		ROUTER_RULES_SYNC_ACTOR='ui-mode-toggle' /usr/bin/router-rules cutover-xray >/dev/null 2>&1 || {
			emit_error set_mode 'Failed to apply routing mode on this router.'
			return 0
		}
	fi

	status_action
}

REQUEST_DATA="$(load_request_data)"

case "$(request_value action)" in
	''|status)
		status_action
		;;
	sync_rules)
		sync_action
		;;
	set_mode)
		set_mode_action
		;;
	*)
		emit_error "$(request_value action)" 'Unknown action.'
		;;
esac
