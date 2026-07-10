#!/bin/sh
# xray-rules-actions.sh — save/sync/external-source actions
# for the xray-rules CGI.
# Deployed to /usr/share/vpn-xray/xray-rules-actions.sh
# Sourced by /www/cgi-bin/xray-rules after lib-common.sh (shares its scope).
# Defines functions only; runs no code.

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
		if normalized_fetch="$(normalize_git_source_input "$fetch_url" 2>/dev/null)"; then
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
