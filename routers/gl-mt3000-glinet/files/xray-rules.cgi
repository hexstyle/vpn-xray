#!/bin/sh

set -e

PATH='/usr/sbin:/usr/bin:/sbin:/bin'
REQUEST_DATA=''
CONFIG_PKG='router_rules'
CONFIG_SECTION='global'
DEFAULT_SSH_KEY_PATH='/etc/router-rules/ssh/routerRules_ed25519'

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

cfg_get() {
	uci -q get "${CONFIG_PKG}.${CONFIG_SECTION}.$1" 2>/dev/null || true
}

cfg_set_or_delete() {
	local key="$1"
	local value="$2"

	if [ -n "$value" ]; then
		uci -q set "${CONFIG_PKG}.${CONFIG_SECTION}.${key}=${value}"
	else
		uci -q delete "${CONFIG_PKG}.${CONFIG_SECTION}.${key}" >/dev/null 2>&1 || true
	fi
}

ensure_config_section() {
	if ! uci -q get "${CONFIG_PKG}.${CONFIG_SECTION}" >/dev/null 2>&1; then
		uci -q set "${CONFIG_PKG}.${CONFIG_SECTION}=global"
	fi
}

ssh_key_path() {
	local value

	value="$(cfg_get ssh_key_path)"
	if [ -n "$value" ]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$DEFAULT_SSH_KEY_PATH"
	fi
}

status_action() {
	emit_header
	/usr/bin/router-rules status-json
}

restart_sync_service() {
	/etc/init.d/router-rules-sync stop >/dev/null 2>&1 || true
	/etc/init.d/router-rules-sync start >/dev/null 2>&1 || true
}

check_remote_rules() {
	local tmp rc message

	tmp="$(mktemp)"
	rc=0
	if command -v timeout >/dev/null 2>&1; then
		ROUTER_RULES_SYNC_ACTOR='ui-config-check' timeout 60 /usr/bin/router-rules check-remote-rules >"$tmp" 2>&1 || rc=$?
	else
		ROUTER_RULES_SYNC_ACTOR='ui-config-check' /usr/bin/router-rules check-remote-rules >"$tmp" 2>&1 || rc=$?
	fi
	if [ "$rc" -eq 0 ]; then
		rm -f "$tmp"
		return 0
	fi

	message="$(sed -n '1p' "$tmp")"
	rm -f "$tmp"
	[ -n "$message" ] || message='Git sync check failed.'
	printf '%s\n' "$message"
	return 1
}

save_config_action() {
	local fetch_url push_url branch auth_mode username password enable_push sync_interval ssh_private_key key_path
	local sync_enabled check_error tmp_key

	fetch_url=''
	push_url=''
	branch=''
	auth_mode=''
	username=''
	password=''
	enable_push=''
	sync_interval=''
	ssh_private_key=''
	sync_enabled=''

	ensure_config_section

	if request_has_key repo_fetch_url; then
		fetch_url="$(request_value repo_fetch_url)"
		cfg_set_or_delete repo_fetch_url "$fetch_url"
		if [ -z "$fetch_url" ]; then
			cfg_set_or_delete repo_push_url ''
			cfg_set_or_delete enable_push '0'
			cfg_set_or_delete git_sync_enabled '0'
		fi
	fi

	if request_has_key repo_push_url; then
		push_url="$(request_value repo_push_url)"
		cfg_set_or_delete repo_push_url "$push_url"
	fi

	if request_has_key repo_branch; then
		branch="$(request_value repo_branch)"
		cfg_set_or_delete repo_branch "$branch"
	fi

	if request_has_key enable_push; then
		enable_push="$(request_value enable_push)"
		case "$enable_push" in
			0|1)
				cfg_set_or_delete enable_push "$enable_push"
				;;
			*)
				emit_error save_config 'Invalid push mode.'
				return 0
				;;
		esac
	fi

	if request_has_key sync_interval; then
		sync_interval="$(request_value sync_interval)"
		case "$sync_interval" in
			''|*[!0-9]*)
				emit_error save_config 'Invalid sync interval.'
				return 0
				;;
		esac
		cfg_set_or_delete sync_interval "$sync_interval"
	fi

	if request_has_key git_sync_enabled; then
		sync_enabled="$(request_value git_sync_enabled)"
		case "$sync_enabled" in
			0|1)
				cfg_set_or_delete git_sync_enabled "$sync_enabled"
				;;
			*)
				emit_error save_config 'Invalid Git sync mode.'
				return 0
				;;
		esac
	fi

	if request_has_key git_auth_mode; then
		auth_mode="$(request_value git_auth_mode)"
		case "$auth_mode" in
			auto|none|https|ssh)
				cfg_set_or_delete git_auth_mode "$auth_mode"
				;;
			*)
				emit_error save_config 'Invalid git auth mode.'
				return 0
				;;
		esac
	fi

	if request_has_key git_http_username; then
		username="$(request_value git_http_username)"
		cfg_set_or_delete git_http_username "$username"
	fi

	if request_has_key git_http_password; then
		password="$(request_value git_http_password)"
		cfg_set_or_delete git_http_password "$password"
	fi

	if request_has_key git_ssh_private_key; then
		ssh_private_key="$(request_value git_ssh_private_key)"
		key_path="$(ssh_key_path)"
		if [ -n "$ssh_private_key" ]; then
			tmp_key="$(mktemp)"
			printf '%s\n' "$ssh_private_key" > "$tmp_key"
			chmod 600 "$tmp_key"
			if ! ssh-keygen -y -f "$tmp_key" > "${tmp_key}.pub" 2>/dev/null; then
				rm -f "$tmp_key" "${tmp_key}.pub"
				emit_error save_config 'Invalid SSH private key.'
				return 0
			fi
			mkdir -p "$(dirname "$key_path")"
			mv "$tmp_key" "$key_path"
			mv "${tmp_key}.pub" "${key_path}.pub"
			chmod 600 "$key_path"
			chmod 644 "${key_path}.pub"
		fi
	fi

	sync_enabled="$(cfg_get git_sync_enabled)"
	fetch_url="$(cfg_get repo_fetch_url)"
	if [ "$sync_enabled" = '1' ] && [ -z "$fetch_url" ]; then
		emit_error save_config 'Repository URL is required when Git sync is enabled.'
		return 0
	fi

	cfg_set_or_delete ssh_key_path "$(ssh_key_path)"
	uci commit "$CONFIG_PKG"

	auth_mode="$(cfg_get git_auth_mode)"
	if [ "$auth_mode" = 'ssh' ]; then
		/usr/bin/router-rules ensure-git-key >/dev/null 2>&1 || true
	fi
	if [ "$sync_enabled" = '1' ]; then
		check_error="$(check_remote_rules || true)"
		if [ -n "$check_error" ]; then
			cfg_set_or_delete git_sync_enabled '0'
			uci commit "$CONFIG_PKG"
			restart_sync_service
			emit_error save_config "$check_error"
			return 0
		fi
	fi
	restart_sync_service

	status_action
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
		ROUTER_RULES_LOCK_WAIT=120 ROUTER_RULES_SYNC_ACTOR='ui-mode-toggle' timeout 120 /usr/bin/router-rules set-mode-cutover "$mode" >/dev/null 2>&1 || {
			emit_error set_mode 'Failed to change routing mode on this router.'
			return 0
		}
	else
		ROUTER_RULES_LOCK_WAIT=120 ROUTER_RULES_SYNC_ACTOR='ui-mode-toggle' /usr/bin/router-rules set-mode-cutover "$mode" >/dev/null 2>&1 || {
			emit_error set_mode 'Failed to change routing mode on this router.'
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
	save_config)
		save_config_action
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
