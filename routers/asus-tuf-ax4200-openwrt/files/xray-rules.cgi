#!/bin/sh

set -e

PATH='/usr/sbin:/usr/bin:/sbin:/bin'
REQUEST_DATA=''
CONFIG_PKG='router_rules'
CONFIG_SECTION='global'
DEFAULT_SSH_KEY_PATH='/etc/router-rules/ssh/routerRules_ed25519'
RULES_MODE_LOCK_WAIT='120'
RULES_MODE_TIMEOUT='150'
RULES_EXTERNAL_LOCK_WAIT='300'
RULES_EXTERNAL_PREVIEW_TIMEOUT='360'
RULES_EXTERNAL_VALIDATE_TIMEOUT='90'
RULES_EXTERNAL_SYNC_TIMEOUT='600'
RULES_TEXT_PREVIEW_LINES='400'
UI_JOB_CONSOLE_FILE='/tmp/router-rules.ui-job.console'

. "${VX_LIB_COMMON:-/usr/share/vpn-xray/lib-common.sh}"

request_has_key() {
	printf '%s' "$REQUEST_DATA" | tr '&' '\n' | grep -q "^$1="
}

cfg_get() {
	uci -q get "${CONFIG_PKG}.${CONFIG_SECTION}.$1" 2>/dev/null || true
}

# Job/status, action, and external-script function groups live in sourced
# libs (AGENTS.md 500-line rule). They define functions only and share
# this scope; the config/sync helpers below stay inline. Call-time
# resolution makes sourcing order vs those helpers immaterial.
. "${VX_RULES_JOBS_LIB:-/usr/share/vpn-xray/xray-rules-jobs.sh}"
. "${VX_RULES_ACTIONS_LIB:-/usr/share/vpn-xray/xray-rules-actions.sh}"
. "${VX_RULES_SCRIPTS_LIB:-/usr/share/vpn-xray/xray-rules-scripts.sh}"
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

normalize_git_source_input() {
	local raw="$1"
	local rest owner repo branch rel

	case "$raw" in
		https://github.com/*/blob/*)
			rest="${raw#https://github.com/}"
			owner="${rest%%/*}"
			rest="${rest#*/}"
			repo="${rest%%/*}"
			rest="${rest#*/}"
			[ "$rest" = "${rest#blob/}" ] && return 1
			rest="${rest#blob/}"
			branch="${rest%%/*}"
			rel="${rest#*/}"
			[ -n "$owner" ] && [ -n "$repo" ] && [ -n "$branch" ] && [ -n "$rel" ] || return 1
			printf '%s\n%s\n%s\n' "https://github.com/${owner}/${repo}.git" "$branch" "$rel"
			return 0
			;;
		https://raw.githubusercontent.com/*)
			rest="${raw#https://raw.githubusercontent.com/}"
			owner="${rest%%/*}"
			rest="${rest#*/}"
			repo="${rest%%/*}"
			rest="${rest#*/}"
			branch="${rest%%/*}"
			rel="${rest#*/}"
			[ -n "$owner" ] && [ -n "$repo" ] && [ -n "$branch" ] && [ -n "$rel" ] || return 1
			printf '%s\n%s\n%s\n' "https://github.com/${owner}/${repo}.git" "$branch" "$rel"
			return 0
			;;
	esac
	return 1
}

external_source_ids() {
	/usr/bin/router-rules external-source-ids 2>/dev/null || cat <<'EOF'
microsoft_service_tags
cloudflare_ipv4
google_ipv4
aws_ipv4
EOF
}

source_ids_csv_contains() {
	local csv="$1"
	local wanted="$2"
	local normalized

	normalized=",$(printf '%s' "$csv" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'),"
	case "$normalized" in
		*",$wanted,"*)
			return 0
			;;
	esac
	return 1
}

status_action() {
	local include_rules_text

	ui_job_reconcile
	include_rules_text='0'
	if request_has_key include_rules_text; then
		include_rules_text="$(request_value include_rules_text)"
	fi
	emit_header
	case "$include_rules_text" in
		1)
			ROUTER_RULES_STATUS_INCLUDE_RULES_TEXT='1' /usr/bin/router-rules status-json
			;;
		*)
			ROUTER_RULES_STATUS_INCLUDE_RULES_TEXT='0' /usr/bin/router-rules status-json
			;;
	esac
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

sync_error_message() {
	local log_file="$1"
	local rc="$2"
	local prev_last_sync_at="$3"
	local prev_sync_phase_at="$4"
	local message current_last_sync_at current_sync_phase_at

	message=''
	if [ -f "$log_file" ]; then
		message="$(sed '/^[[:space:]]*$/d' "$log_file" | sed -n '1p')"
	fi

	current_last_sync_at="$(status_file_value last_sync_at)"
	current_sync_phase_at="$(status_file_value sync_phase_at)"
	if [ -z "$message" ] && [ "$current_last_sync_at" != "$prev_last_sync_at" ]; then
		message="$(status_file_value last_sync_message)"
	fi
	if [ -z "$message" ] && [ "$current_sync_phase_at" != "$prev_sync_phase_at" ]; then
		message="$(status_file_value sync_phase_message)"
	fi
	case "$message" in
		'router-rules lock timeout')
			message='Another router-rules operation is still running; sync timed out waiting for the lock.'
			;;
	esac
	if [ -z "$message" ] && [ "$rc" -eq 124 ]; then
		message='Rules sync/apply timed out.'
	fi
	[ -n "$message" ] || message='Rules sync/apply failed.'
	printf '%s\n' "$message"
}

mode_error_message() {
	local log_file="$1"
	local rc="$2"
	local prev_last_cutover_at="$3"
	local prev_sync_phase_at="$4"
	local message current_last_cutover_at current_sync_phase_at

	message=''
	if [ -f "$log_file" ]; then
		message="$(sed '/^[[:space:]]*$/d' "$log_file" | sed -n '1p')"
	fi

	current_last_cutover_at="$(status_file_value last_cutover_at)"
	current_sync_phase_at="$(status_file_value sync_phase_at)"
	if [ -z "$message" ] && [ "$current_last_cutover_at" != "$prev_last_cutover_at" ]; then
		message="$(status_file_value last_cutover_message)"
	fi
	if [ -z "$message" ] && [ "$current_sync_phase_at" != "$prev_sync_phase_at" ]; then
		message="$(status_file_value sync_phase_message)"
	fi
	case "$message" in
		'router-rules lock timeout')
			message='Another router-rules operation is still running; mode change timed out waiting for the lock.'
			;;
	esac
	if [ -z "$message" ] && [ "$rc" -eq 124 ]; then
		message='Routing mode change timed out on this router.'
	fi
	[ -n "$message" ] || message='Failed to change routing mode on this router.'
	printf '%s\n' "$message"
}

REQUEST_DATA="$(load_request_data)"

case "$(request_value action)" in
	''|status)
		status_action
		;;
	mode_status)
		# Fast, lock-free routing-mode probe for the toggle (see router-rules
		# mode-json). Lets the UI paint the real mode in a few ms instead of
		# waiting on the ~3.5s full status.
		emit_header
		/usr/bin/router-rules mode-json
		;;
	save_config)
		save_config_action
		;;
	sync_rules)
		sync_action
		;;
	preview_external_source)
		preview_external_source_action
		;;
	read_external_source)
		read_external_source_action
		;;
	sync_external_source)
		sync_external_source_action
		;;
	set_mode)
		set_mode_action
		;;
	save_external_script)
		save_external_script_action
		;;
	delete_external_script)
		delete_external_script_action
		;;
	read_external_script)
		read_external_script_action
		;;
	download_external_file)
		download_external_file_action
		;;
	*)
		emit_error "$(request_value action)" 'Unknown action.'
		;;
esac
