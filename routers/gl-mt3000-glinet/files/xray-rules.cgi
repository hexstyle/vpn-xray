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

status_file_value() {
	sed -n "s/^$1=//p" /tmp/router-rules.status 2>/dev/null | sed -n '1p'
}

status_file_set() {
	local key="$1"
	local value="$2"
	local file tmp

	file='/tmp/router-rules.status'
	tmp="$(mktemp)"
	if [ -f "$file" ]; then
		grep -v "^${key}=" "$file" > "$tmp" || true
	fi
	printf '%s=%s\n' "$key" "$value" >> "$tmp"
	mv "$tmp" "$file"
}

status_file_delete() {
	local key="$1"
	local file tmp

	file='/tmp/router-rules.status'
	[ -f "$file" ] || return 0
	tmp="$(mktemp)"
	grep -v "^${key}=" "$file" > "$tmp" || true
	mv "$tmp" "$file"
}

ui_job_reconcile() {
	local state pid now

	state="$(status_file_value ui_job_state)"
	[ "$state" = 'running' ] || return 0
	pid="$(status_file_value ui_job_pid)"
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		return 0
	fi

	now="$(date +%s)"
	status_file_set ui_job_state 'error'
	status_file_set ui_job_finished_at "$now"
	status_file_set ui_job_message 'The previous UI operation ended unexpectedly before reporting its final status.'
	status_file_set ui_job_suggestion 'Inspect the router status and console output from the last failed operation, then retry once the stuck job is cleared.'
	status_file_delete ui_job_pid
}

ui_job_running() {
	ui_job_reconcile
	[ "$(status_file_value ui_job_state)" = 'running' ]
}

ui_job_clear_feedback() {
	status_file_delete ui_job_suggestion
	status_file_delete ui_job_console_path
	rm -f "$UI_JOB_CONSOLE_FILE"
}

ui_job_store_console_output() {
	local log_file="$1"

	status_file_delete ui_job_console_path
	rm -f "$UI_JOB_CONSOLE_FILE"
	[ -f "$log_file" ] || return 0
	sed 's/\r$//' "$log_file" | sed -n '1,160p' > "$UI_JOB_CONSOLE_FILE"
	if [ -s "$UI_JOB_CONSOLE_FILE" ]; then
		status_file_set ui_job_console_path "$UI_JOB_CONSOLE_FILE"
	else
		rm -f "$UI_JOB_CONSOLE_FILE"
	fi
}

job_suggestion_from_log() {
	local log_file="$1"
	local context="${2:-operation}"
	local text

	text="$(tr '\r\n' '  ' < "$log_file" 2>/dev/null | tr -s ' ')"
	case "$text" in
		*Permission\ denied*|*Authentication\ failed*|*publickey*|*Repository\ not\ found*|*could\ not\ read\ Username*|*403\ Forbidden*|*401\ Unauthorized*)
			case "$context" in
				push)
					printf 'Check the push URL and write credentials on the router. HTTPS push needs a valid token/password, and SSH push needs the router public key allowed on the repository.\n'
					;;
				pull|sync)
					printf 'Check the fetch URL and Git credentials. If the router is meant to pull anonymously, the remote rules file must be reachable without write credentials.\n'
					;;
				*)
					printf 'Check the Git URL and credentials on the router, then retry the operation.\n'
					;;
			esac
			return 0
			;;
		*non-fast-forward*|*fetch\ first*|*failed\ to\ push\ some\ refs*|*Updates\ were\ rejected*)
			printf 'Remote Git changed while the router still had local edits. Run Pull first, review the merged file that preserves both unique sides, then push again.\n'
			return 0
			;;
		*Connection\ timed\ out*|*Operation\ timed\ out*|*Failed\ to\ connect*|*Could\ not\ resolve\ host*|*Name\ or\ service\ not\ known*|*No\ route\ to\ host*|*Network\ is\ unreachable*|*Connection\ refused*)
			printf 'The router cannot reach the Git remote within the timeout. Check WAN connectivity, DNS, proxy routing and firewall, then retry.\n'
			return 0
			;;
		*read-only*)
			printf 'This router is currently in read-only Git mode. Switch Git auth to HTTPS or SSH write access before using Push.\n'
			return 0
			;;
		*router-rules\ lock\ timeout*)
			printf 'Another router-side rules job is still holding the lock. Wait for it to finish, or clear the stuck job before retrying.\n'
			return 0
			;;
	esac

	case "$context" in
		push)
			printf 'Inspect the console output below, fix the push-side problem on the router, then retry Push.\n'
			;;
		pull|sync)
			printf 'Inspect the console output below, fix the fetch/merge problem on the router, then retry Pull.\n'
			;;
		external)
			printf 'Inspect the parser or network error below, then retry the managed-source refresh.\n'
			;;
		mode)
			printf 'Inspect the router-side cutover error below, then retry the routing mode change.\n'
			;;
		*)
			printf 'Inspect the console output below, fix the router-side error, then retry.\n'
			;;
	esac
}

ui_job_begin() {
	local kind="$1"
	local message="$2"
	local target_mode="${3:-}"
	local job_id now

	now="$(date +%s)"
	job_id="${now}-$$"
	status_file_set ui_job_id "$job_id"
	status_file_set ui_job_kind "$kind"
	status_file_set ui_job_state 'running'
	status_file_set ui_job_message "$message"
	status_file_set ui_job_started_at "$now"
	status_file_delete ui_job_finished_at
	status_file_delete ui_job_pid
	ui_job_clear_feedback
	if [ -n "$target_mode" ]; then
		status_file_set ui_job_target_mode "$target_mode"
	else
		status_file_delete ui_job_target_mode
	fi
	printf '%s\n' "$job_id"
}

ui_job_attach_pid() {
	local job_id="$1"
	local pid="$2"

	[ "$(status_file_value ui_job_id)" = "$job_id" ] || return 0
	status_file_set ui_job_pid "$pid"
}

ui_job_finish() {
	local job_id="$1"
	local final_state="$2"
	local message="$3"
	local suggestion="${4:-}"
	local console_log="${5:-}"
	local now

	[ "$(status_file_value ui_job_id)" = "$job_id" ] || return 0
	now="$(date +%s)"
	status_file_set ui_job_state "$final_state"
	status_file_set ui_job_message "$message"
	status_file_set ui_job_finished_at "$now"
	status_file_delete ui_job_pid
	if [ -n "$suggestion" ]; then
		status_file_set ui_job_suggestion "$suggestion"
	else
		status_file_delete ui_job_suggestion
	fi
	ui_job_store_console_output "$console_log"
}

ui_job_error_from_log() {
	local log_file="$1"
	local fallback="$2"
	local message

	message=''
	if [ -f "$log_file" ]; then
		message="$(sed '/^[[:space:]]*$/d' "$log_file" | sed -n '1p')"
	fi
	[ -n "$message" ] || message="$fallback"
	printf '%s\n' "$message"
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

save_config_action() {
	local fetch_url push_url branch auth_mode username password enable_push sync_interval ssh_private_key key_path
	local sync_enabled check_error tmp_key external_enabled_ids external_interval source_id normalized_fetch
	local normalized_branch normalized_rules_relpath

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
	external_enabled_ids=''
	external_interval=''

	ensure_config_section

	if request_has_key repo_fetch_url; then
		fetch_url="$(request_value repo_fetch_url)"
		if normalized_fetch="$(normalize_git_source_input "$fetch_url" 2>/dev/null || true)"; then
			fetch_url="$(printf '%s\n' "$normalized_fetch" | sed -n '1p')"
			normalized_branch="$(printf '%s\n' "$normalized_fetch" | sed -n '2p')"
			normalized_rules_relpath="$(printf '%s\n' "$normalized_fetch" | sed -n '3p')"
			[ -n "$normalized_branch" ] && cfg_set_or_delete repo_branch "$normalized_branch"
			[ -n "$normalized_rules_relpath" ] && cfg_set_or_delete rules_relpath "$normalized_rules_relpath"
		fi
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

	if request_has_key external_source_enabled_ids; then
		external_enabled_ids="$(request_value external_source_enabled_ids)"
		while IFS= read -r source_id || [ -n "$source_id" ]; do
			[ -n "$source_id" ] || continue
			if source_ids_csv_contains "$external_enabled_ids" "$source_id"; then
				cfg_set_or_delete "external_source_${source_id}_enabled" '1'
			else
				cfg_set_or_delete "external_source_${source_id}_enabled" '0'
			fi
		done <<EOF
$(external_source_ids)
EOF
	fi

	if request_has_key external_source_interval; then
		external_interval="$(request_value external_source_interval)"
		case "$external_interval" in
			''|*[!0-9]*)
				emit_error save_config 'Invalid external source interval.'
				return 0
				;;
		esac
		if [ "$external_interval" -lt 3600 ] 2>/dev/null; then
			emit_error save_config 'External source interval must be at least 3600 seconds.'
			return 0
		fi
		cfg_set_or_delete external_source_interval "$external_interval"
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
			auto|none|readonly|https|ssh)
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
	auth_mode="$(cfg_get git_auth_mode)"
	if [ "$sync_enabled" = '1' ] && [ -z "$fetch_url" ]; then
		emit_error save_config 'Repository URL is required when Git sync is enabled.'
		return 0
	fi

	cfg_set_or_delete ssh_key_path "$(ssh_key_path)"
	uci commit "$CONFIG_PKG"

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

preview_external_source_action() {
	local source_id preview_file error_file rc message preview_text preview_count preview_total preview_truncated

	source_id=''
	preview_file="$(mktemp)"
	error_file="$(mktemp)"
	rc=0
	if request_has_key source_id; then
		source_id="$(request_value source_id)"
	fi

	if command -v timeout >/dev/null 2>&1; then
		ROUTER_RULES_LOCK_WAIT="$RULES_EXTERNAL_LOCK_WAIT" ROUTER_RULES_SYNC_ACTOR='ui-external-preview' timeout "$RULES_EXTERNAL_PREVIEW_TIMEOUT" /usr/bin/router-rules preview-external-source "$source_id" > "$preview_file" 2> "$error_file" || rc=$?
	else
		ROUTER_RULES_LOCK_WAIT="$RULES_EXTERNAL_LOCK_WAIT" ROUTER_RULES_SYNC_ACTOR='ui-external-preview' /usr/bin/router-rules preview-external-source "$source_id" > "$preview_file" 2> "$error_file" || rc=$?
	fi

	if [ "$rc" -ne 0 ]; then
		message="$(sed '/^[[:space:]]*$/d' "$error_file" | sed -n '1p')"
		[ -n "$message" ] || message='External source preview failed.'
		rm -f "$preview_file" "$error_file"
		emit_error preview_external_source "$message"
		return 0
	fi

	preview_total="$(sed '/^[[:space:]]*$/d' "$preview_file" | wc -l | awk '{print $1}')"
	preview_count="$preview_total"
	preview_text="$(sed -n "1,${RULES_TEXT_PREVIEW_LINES}p" "$preview_file")"
	preview_truncated='0'
	if [ "${preview_total:-0}" -gt "$RULES_TEXT_PREVIEW_LINES" ] 2>/dev/null; then
		preview_truncated='1'
	fi
	rm -f "$preview_file" "$error_file"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"preview_external_source",'
	printf '"generated_count":"%s",' "$(json_escape "$preview_count")"
	printf '"generated_total":"%s",' "$(json_escape "$preview_total")"
	printf '"generated_truncated":'; json_bool "$preview_truncated"; printf ','
	printf '"generated_text":"%s"' "$(json_escape "$preview_text")"
	printf '}'
}

read_external_source_action() {
	local source_id read_file error_file rc message output_text output_count output_total output_truncated

	source_id=''
	read_file="$(mktemp)"
	error_file="$(mktemp)"
	rc=0
	if request_has_key source_id; then
		source_id="$(request_value source_id)"
	fi

	if command -v timeout >/dev/null 2>&1; then
		ROUTER_RULES_LOCK_WAIT="$RULES_EXTERNAL_LOCK_WAIT" ROUTER_RULES_SYNC_ACTOR='ui-external-read' timeout "$RULES_EXTERNAL_PREVIEW_TIMEOUT" /usr/bin/router-rules read-external-source "$source_id" > "$read_file" 2> "$error_file" || rc=$?
	else
		ROUTER_RULES_LOCK_WAIT="$RULES_EXTERNAL_LOCK_WAIT" ROUTER_RULES_SYNC_ACTOR='ui-external-read' /usr/bin/router-rules read-external-source "$source_id" > "$read_file" 2> "$error_file" || rc=$?
	fi

	if [ "$rc" -ne 0 ]; then
		message="$(sed '/^[[:space:]]*$/d' "$error_file" | sed -n '1p')"
		[ -n "$message" ] || message='Managed external source file read failed.'
		rm -f "$read_file" "$error_file"
		emit_error read_external_source "$message"
		return 0
	fi

	output_total="$(sed '/^[[:space:]]*$/d' "$read_file" | wc -l | awk '{print $1}')"
	output_count="$output_total"
	output_text="$(sed -n "1,${RULES_TEXT_PREVIEW_LINES}p" "$read_file")"
	output_truncated='0'
	if [ "${output_total:-0}" -gt "$RULES_TEXT_PREVIEW_LINES" ] 2>/dev/null; then
		output_truncated='1'
	fi
	rm -f "$read_file" "$error_file"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"read_external_source",'
	printf '"file_count":"%s",' "$(json_escape "$output_count")"
	printf '"file_total":"%s",' "$(json_escape "$output_total")"
	printf '"file_truncated":'; json_bool "$output_truncated"; printf ','
	printf '"file_text":"%s"' "$(json_escape "$output_text")"
	printf '}'
}

sync_action() {
	local tmp run_log rules_text base_repo_head job_id bg_pid sync_mode job_kind start_message
	local error_message error_suggestion
	tmp="$(mktemp)"
	run_log="$(mktemp)"
	base_repo_head=''
	sync_mode='sync'

	if ui_job_running; then
		rm -f "$tmp" "$run_log"
		emit_error sync_rules 'Another router rules operation is already running. Wait for it to finish before starting a new sync.'
		return 0
	fi

	if request_has_key sync_mode; then
		sync_mode="$(request_value sync_mode)"
	fi
	case "$sync_mode" in
		sync|pull|push|apply)
			;;
		*)
			rm -f "$tmp" "$run_log"
			emit_error sync_rules 'Invalid rules sync mode.'
			return 0
			;;
	esac

	if request_has_key rules_text; then
		rules_text="$(request_value rules_text)"
		printf '%s\n' "$rules_text" > "$tmp"
	fi
	if request_has_key base_repo_head; then
		base_repo_head="$(request_value base_repo_head)"
	fi

	case "$sync_mode" in
		pull)
			job_kind='pull_rules'
			start_message='Starting Git pull, merge and apply on the router'
			;;
		push)
			job_kind='push_rules'
			start_message='Starting Git push and apply on the router'
			;;
		apply)
			job_kind='apply_rules'
			start_message='Saving the local rules file and applying it on the router'
			;;
		*)
			job_kind='sync_rules'
			start_message='Starting rules sync and apply on the router'
			;;
	esac

	job_id="$(ui_job_begin "$job_kind" "$start_message")"
	(
		rc=0
		prev_last_sync_at="$(status_file_value last_sync_at)"
		prev_sync_phase_at="$(status_file_value sync_phase_at)"
		/usr/bin/router-rules ensure-git-key >/dev/null 2>&1 || true
		if command -v timeout >/dev/null 2>&1; then
			if [ -s "$tmp" ]; then
				ROUTER_RULES_FORCE_GIT=1 ROUTER_RULES_SYNC_MODE="$sync_mode" ROUTER_RULES_BASE_HEAD="$base_repo_head" ROUTER_RULES_SYNC_ACTOR='ui-sync' timeout 180 /usr/bin/router-rules save-sync-apply-xray "$tmp" >"$run_log" 2>&1 || rc=$?
			else
				ROUTER_RULES_FORCE_GIT=1 ROUTER_RULES_SYNC_MODE="$sync_mode" ROUTER_RULES_BASE_HEAD="$base_repo_head" ROUTER_RULES_SYNC_ACTOR='ui-sync' timeout 180 /usr/bin/router-rules sync-apply-xray >"$run_log" 2>&1 || rc=$?
			fi
		else
			if [ -s "$tmp" ]; then
				ROUTER_RULES_FORCE_GIT=1 ROUTER_RULES_SYNC_MODE="$sync_mode" ROUTER_RULES_BASE_HEAD="$base_repo_head" ROUTER_RULES_SYNC_ACTOR='ui-sync' /usr/bin/router-rules save-sync-apply-xray "$tmp" >"$run_log" 2>&1 || rc=$?
			else
				ROUTER_RULES_FORCE_GIT=1 ROUTER_RULES_SYNC_MODE="$sync_mode" ROUTER_RULES_BASE_HEAD="$base_repo_head" ROUTER_RULES_SYNC_ACTOR='ui-sync' /usr/bin/router-rules sync-apply-xray >"$run_log" 2>&1 || rc=$?
			fi
		fi
		if [ "$rc" -eq 0 ]; then
			ui_job_finish "$job_id" success "$(status_file_value last_sync_message)"
		else
			error_message="$(sync_error_message "$run_log" "$rc" "$prev_last_sync_at" "$prev_sync_phase_at")"
			error_suggestion="$(job_suggestion_from_log "$run_log" "$sync_mode")"
			ui_job_finish "$job_id" error "$error_message" "$error_suggestion" "$run_log"
		fi
		rm -f "$tmp" "$run_log"
	) </dev/null >/dev/null 2>&1 &
	bg_pid="$!"
	ui_job_attach_pid "$job_id" "$bg_pid"
	status_action
}

sync_external_source_action() {
	local run_log job_id bg_pid error_message error_suggestion

	run_log="$(mktemp)"

	if ui_job_running; then
		rm -f "$run_log"
		emit_error sync_external_source 'Another router rules operation is already running. Wait for it to finish before starting a managed-source refresh.'
		return 0
	fi

	job_id="$(ui_job_begin sync_external_source 'Refreshing managed source files on the router')"
	(
		rc=0
		prev_last_sync_at="$(status_file_value last_sync_at)"
		prev_sync_phase_at="$(status_file_value sync_phase_at)"
		if command -v timeout >/dev/null 2>&1; then
			ROUTER_RULES_LOCK_WAIT="$RULES_EXTERNAL_LOCK_WAIT" ROUTER_RULES_EXTERNAL_FORCE=1 ROUTER_RULES_SYNC_ACTOR='ui-external' timeout "$RULES_EXTERNAL_SYNC_TIMEOUT" /usr/bin/router-rules sync-external-source >"$run_log" 2>&1 || rc=$?
		else
			ROUTER_RULES_LOCK_WAIT="$RULES_EXTERNAL_LOCK_WAIT" ROUTER_RULES_EXTERNAL_FORCE=1 ROUTER_RULES_SYNC_ACTOR='ui-external' /usr/bin/router-rules sync-external-source >"$run_log" 2>&1 || rc=$?
		fi
		if [ "$rc" -eq 0 ]; then
			ui_job_finish "$job_id" success "$(status_file_value last_external_message)"
		else
			error_message="$(sync_error_message "$run_log" "$rc" "$prev_last_sync_at" "$prev_sync_phase_at")"
			error_suggestion="$(job_suggestion_from_log "$run_log" external)"
			ui_job_finish "$job_id" error "$error_message" "$error_suggestion" "$run_log"
		fi
		rm -f "$run_log"
	) </dev/null >/dev/null 2>&1 &
	bg_pid="$!"
	ui_job_attach_pid "$job_id" "$bg_pid"
	status_action
}

set_mode_action() {
	local mode run_log job_id bg_pid error_message error_suggestion

	mode="$(request_value mode)"
	case "$mode" in
		full|selective)
			;;
		*)
			emit_error set_mode 'Invalid xray mode.'
			return 0
			;;
	esac

	run_log="$(mktemp)"

	if ui_job_running; then
		rm -f "$run_log"
		emit_error set_mode 'Another router rules operation is already running. Wait for it to finish before changing routing mode.'
		return 0
	fi

	job_id="$(ui_job_begin set_mode "Starting hard cutover to ${mode} routing mode" "$mode")"
	(
		rc=0
		prev_last_cutover_at="$(status_file_value last_cutover_at)"
		prev_sync_phase_at="$(status_file_value sync_phase_at)"
		if command -v timeout >/dev/null 2>&1; then
			ROUTER_RULES_LOCK_WAIT="$RULES_MODE_LOCK_WAIT" ROUTER_RULES_SYNC_ACTOR='ui-mode-toggle' timeout "$RULES_MODE_TIMEOUT" /usr/bin/router-rules set-mode-cutover "$mode" >"$run_log" 2>&1 || rc=$?
		else
			ROUTER_RULES_LOCK_WAIT="$RULES_MODE_LOCK_WAIT" ROUTER_RULES_SYNC_ACTOR='ui-mode-toggle' /usr/bin/router-rules set-mode-cutover "$mode" >"$run_log" 2>&1 || rc=$?
		fi
		if [ "$rc" -eq 0 ]; then
			ui_job_finish "$job_id" success "$(status_file_value last_cutover_message)"
		else
			error_message="$(mode_error_message "$run_log" "$rc" "$prev_last_cutover_at" "$prev_sync_phase_at")"
			error_suggestion="$(job_suggestion_from_log "$run_log" mode)"
			ui_job_finish "$job_id" error "$error_message" "$error_suggestion" "$run_log"
		fi
		rm -f "$run_log"
	) </dev/null >/dev/null 2>&1 &
	bg_pid="$!"
	ui_job_attach_pid "$job_id" "$bg_pid"
	status_action
}

save_external_script_action() {
	local source_id label url script_text max_targets tmp_json validate_out error_file rc line_count message

	source_id="$(request_value source_id)"
	label="$(request_value label)"
	url="$(request_value url)"
	script_text="$(request_value script_text)"
	max_targets="$(request_value max_targets)"

	[ -n "$source_id" ] || {
		emit_error save_external_script 'Source ID is required.'
		return 0
	}
	case "$source_id" in
		*[!a-z0-9_]*)
			emit_error save_external_script 'Source ID must contain only lowercase letters, digits and underscores.'
			return 0
			;;
	esac
	[ -n "$label" ] || label="$source_id"
	[ -n "$url" ] || {
		emit_error save_external_script 'Source URL is required.'
		return 0
	}
	[ -n "$script_text" ] || {
		emit_error save_external_script 'Script text is required.'
		return 0
	}
	case "$max_targets" in
		''|*[!0-9]*) max_targets='5000' ;;
	esac

	tmp_json="$(mktemp)"
	python3 -c "
import json, sys
data = {
    'id': sys.argv[1],
    'label': sys.argv[2],
    'url': sys.argv[3],
    'script': sys.stdin.read(),
    'max_targets': int(sys.argv[4])
}
json.dump(data, open(sys.argv[5], 'w'), indent=2, ensure_ascii=False)
" "$source_id" "$label" "$url" "$max_targets" "$tmp_json" <<SCRIPT_EOF
$script_text
SCRIPT_EOF

	validate_out="$(mktemp)"
	error_file="$(mktemp)"
	rc=0
	if command -v timeout >/dev/null 2>&1; then
		timeout "$RULES_EXTERNAL_VALIDATE_TIMEOUT" /usr/bin/router-rules validate-external-script "$tmp_json" > "$validate_out" 2> "$error_file" || rc=$?
	else
		/usr/bin/router-rules validate-external-script "$tmp_json" > "$validate_out" 2> "$error_file" || rc=$?
	fi

	if [ "$rc" -ne 0 ]; then
		message="$(sed '/^[[:space:]]*$/d' "$error_file" | sed -n '1p')"
		[ -n "$message" ] || message='Script validation failed.'
		rm -f "$tmp_json" "$validate_out" "$error_file"
		emit_error save_external_script "$message"
		return 0
	fi

	line_count="$(awk '{print $2}' "$validate_out")"

	ROUTER_RULES_SYNC_ACTOR='ui-save-script' /usr/bin/router-rules save-external-script "$tmp_json" >/dev/null 2>&1 || {
		rm -f "$tmp_json" "$validate_out" "$error_file"
		emit_error save_external_script 'Failed to save script to git.'
		return 0
	}

	rm -f "$tmp_json" "$validate_out" "$error_file"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"save_external_script",'
	printf '"source_id":"%s",' "$(json_escape "$source_id")"
	printf '"validated_lines":"%s"' "$(json_escape "$line_count")"
	printf '}'
}

delete_external_script_action() {
	local source_id error_file rc message

	source_id="$(request_value source_id)"
	[ -n "$source_id" ] || {
		emit_error delete_external_script 'Source ID is required.'
		return 0
	}

	error_file="$(mktemp)"
	rc=0
	ROUTER_RULES_SYNC_ACTOR='ui-delete-script' /usr/bin/router-rules delete-external-script "$source_id" >/dev/null 2> "$error_file" || rc=$?

	if [ "$rc" -ne 0 ]; then
		message="$(sed '/^[[:space:]]*$/d' "$error_file" | sed -n '1p')"
		[ -n "$message" ] || message='Failed to delete external source script.'
		rm -f "$error_file"
		emit_error delete_external_script "$message"
		return 0
	fi
	rm -f "$error_file"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"delete_external_script",'
	printf '"source_id":"%s"' "$(json_escape "$source_id")"
	printf '}'
}

read_external_script_action() {
	local source_id script_json error_file rc message

	source_id="$(request_value source_id)"
	[ -n "$source_id" ] || {
		emit_error read_external_script 'Source ID is required.'
		return 0
	}

	script_json="$(mktemp)"
	error_file="$(mktemp)"
	rc=0
	/usr/bin/router-rules read-external-script "$source_id" > "$script_json" 2> "$error_file" || rc=$?

	if [ "$rc" -ne 0 ]; then
		message="$(sed '/^[[:space:]]*$/d' "$error_file" | sed -n '1p')"
		[ -n "$message" ] || message='Script not found.'
		rm -f "$script_json" "$error_file"
		emit_error read_external_script "$message"
		return 0
	fi

	local label url script_text max_targets
	label="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('label',''))" "$script_json" 2>/dev/null || true)"
	url="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('url',''))" "$script_json" 2>/dev/null || true)"
	script_text="$(python3 -c "import json,sys; sys.stdout.write(json.load(open(sys.argv[1])).get('script',''))" "$script_json" 2>/dev/null || true)"
	max_targets="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('max_targets',5000))" "$script_json" 2>/dev/null || echo 5000)"
	rm -f "$script_json" "$error_file"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"read_external_script",'
	printf '"source_id":"%s",' "$(json_escape "$source_id")"
	printf '"label":"%s",' "$(json_escape "$label")"
	printf '"url":"%s",' "$(json_escape "$url")"
	printf '"max_targets":"%s",' "$(json_escape "$max_targets")"
	printf '"script_text":"%s"' "$(json_escape "$script_text")"
	printf '}'
}

download_external_file_action() {
	local source_id download_type output_file error_file rc message filename

	source_id="$(request_value source_id)"
	download_type="$(request_value type)"
	[ -n "$source_id" ] || {
		emit_error download_external_file 'Source ID is required.'
		return 0
	}
	[ -n "$download_type" ] || download_type='stored'

	output_file="$(mktemp)"
	error_file="$(mktemp)"
	rc=0

	case "$download_type" in
		preview)
			filename="${source_id}_preview.txt"
			if command -v timeout >/dev/null 2>&1; then
				ROUTER_RULES_LOCK_WAIT="$RULES_EXTERNAL_LOCK_WAIT" ROUTER_RULES_SYNC_ACTOR='ui-download-preview' timeout "$RULES_EXTERNAL_PREVIEW_TIMEOUT" /usr/bin/router-rules preview-external-source "$source_id" > "$output_file" 2> "$error_file" || rc=$?
			else
				ROUTER_RULES_LOCK_WAIT="$RULES_EXTERNAL_LOCK_WAIT" ROUTER_RULES_SYNC_ACTOR='ui-download-preview' /usr/bin/router-rules preview-external-source "$source_id" > "$output_file" 2> "$error_file" || rc=$?
			fi
			;;
		*)
			filename="${source_id}.txt"
			/usr/bin/router-rules read-external-source "$source_id" > "$output_file" 2> "$error_file" || rc=$?
			;;
	esac

	if [ "$rc" -ne 0 ]; then
		message="$(sed '/^[[:space:]]*$/d' "$error_file" | sed -n '1p')"
		[ -n "$message" ] || message='External file download failed.'
		rm -f "$output_file" "$error_file"
		emit_error download_external_file "$message"
		return 0
	fi
	rm -f "$error_file"

	printf 'Content-Type: text/plain\r\n'
	printf 'Content-Disposition: attachment; filename="%s"\r\n' "$filename"
	printf 'Cache-Control: no-store\r\n'
	printf '\r\n'
	cat "$output_file"
	rm -f "$output_file"
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
