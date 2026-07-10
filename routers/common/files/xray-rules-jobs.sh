#!/bin/sh
# xray-rules-jobs.sh — UI job lifecycle + status-file helpers
# for the xray-rules CGI.
# Deployed to /usr/share/vpn-xray/xray-rules-jobs.sh
# Sourced by /www/cgi-bin/xray-rules after lib-common.sh (shares its scope).
# Defines functions only; runs no code.

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
