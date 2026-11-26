#!/bin/sh
# xray-vps-setup.sh — VPS setup + apply-everything + router-apply job
# Deployed to /usr/share/vpn-xray/xray-vps-setup.sh
# Sourced by /www/cgi-bin/xray-vps after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

# Both settings and repair use the same detached apply owner (tree 8.1d/8.2).
setup_vps_action() { schedule_router_apply_action_for setup_vps "$(active_profile_id)"; }

apply_everything_action() {
	if ! save_profile_from_request >/dev/null; then
		emit_error apply_profile "${SAVE_PROFILE_ERROR:-Could not save VPS access.}"
		return 0
	fi
	schedule_router_apply_action_for apply_profile "$SAVE_PROFILE_ID"
}

# FD6 belongs to the complete transaction, unlike helper locks on FD9.
profile_operation_lock() {
	mkdir -p "$LOCK_ROOT"
	exec 6>"$LOCK_ROOT/router-apply.flock"
	flock -n 6 && return 0
	exec 6>&-
	return 1
}

profile_request_guard() {
	profile_operation_lock || return 1
	if router_apply_job_running || repair_job_running; then exec 6>&-; return 1; fi
}

# Only accepted workers wait: a concurrent request may briefly hold FD6 before
# returning busy. Use supported flock -n, not optional firmware timeout flags.
profile_worker_lock() {
	local status="$1" scheduled now until
	now="$(date +%s)"
	scheduled="$(sed -n 's/^scheduled_at=//p' "$status" 2>/dev/null)"
	case "$scheduled" in ''|*[!0-9]*) scheduled="$now";; esac
	VPS_JOB_DEADLINE=$((scheduled + 170))
	until=$((now + 5))
	# Finish failure publication before the existing 10s scheduled grace expires.
	[ "$until" -le "$((scheduled + 9))" ] || until=$((scheduled + 9))
	while ! profile_operation_lock; do
		[ "$(date +%s)" -lt "$until" ] && vps_time_left 1 >/dev/null || return 1
		sleep 1
	done
	vps_time_left 1 >/dev/null || { exec 6>&-; return 1; }
}

profile_job_start_failed() {
	local status="$1" request="$2" result="$3" reason="$4"
	# Atomic request ownership: a running worker or another terminal writer wins.
	mv "$request" "$request.failed.$$" 2>/dev/null || return 0
	rm -f "$request.failed.$$"
	if [ -n "$result" ]; then
		printf '{"ok":false,"error":"job_start_failed","reason":"%s","router_apply":"unchanged","applied":false,"path_health":"not_checked","steps":[]}' \
			"$(json_escape "$reason")" > "$result.tmp"
		mv "$result.tmp" "$result"
	else
		: > "$status.log"; printf '[]\n' > "$status.steps"
	fi
	{
		sed '/^state=/d; /^message=/d; /^router_apply=/d; /^path_health=/d' "$status"
		printf 'state=failed\nexit_code=1\nfinished_at=%s\n' "$(date +%s)"
		printf 'router_apply=unchanged\npath_health=not_checked\nmessage=%s\n' "$reason"
	} > "$status.tmp"
	mv "$status.tmp" "$status"
}

ROUTER_APPLY_STATUS_FILE='/tmp/xray-vps-repair-apply.status'
ROUTER_CERT=${ROUTER_CERT:-/etc/xray/server.crt}
router_apply_status_path() { readlink "$ROUTER_APPLY_STATUS_FILE" 2>/dev/null || printf '%s\n' "$ROUTER_APPLY_STATUS_FILE"; }

apply_profile_to_router_internal() {
	local profile_id="$1" base rendered fetched tunnel backup cert_backup tunnel_backup rc=0
	APPLY_ROUTER_ERROR=''; APPLY_ROUTER_EGRESS=''
	APPLY_ROUTER_PHASE='unchanged'; APPLY_PATH_HEALTH='not_checked'
	base="/tmp/codex-xray.profile.$$"
	rendered="$base.json"; fetched="$base.crt"; tunnel="$base.tunnel"
	if ! validate_selected_profile "$profile_id"; then return 1; fi
	umask 077
	if ! render_router_config "$rendered" "$profile_id"; then
		APPLY_ROUTER_ERROR='rendered router config failed validation'
		rm -f "$base".*; return 1
	fi
	if ! fetch_profile_tls_cert "$profile_id" "$fetched"; then
		APPLY_ROUTER_ERROR='selected VPS certificate failed validation'
		rm -f "$base".*; return 1
	fi
	sed "s#/etc/xray/server.crt#$fetched#g" "$rendered" > "$base.test.json"
	if ! "$ROUTER_XRAY_BIN" run -test -config "$base.test.json" >/dev/null 2>&1; then
		APPLY_ROUTER_ERROR='rendered router config/certificate failed validation'
		rm -f "$base".*; return 1
	fi
	if [ "$(profile_get "$profile_id" dial_mode)" = ssh_tunnel ]; then
		write_profile_tunnel_config "$profile_id" "$tunnel" || { rm -f "$base".*; return 1; }
	fi
	if cmp -s "$rendered" "$ROUTER_CONFIG" && cmp -s "$fetched" "$ROUTER_CERT" &&
		{ cmp -s "$tunnel" "$ROUTER_TUNNEL_CONFIG" || { [ ! -e "$tunnel" ] && [ ! -e "$ROUTER_TUNNEL_CONFIG" ]; }; } &&
		local_profile_runtime_ready; then
		rm -f "$base".*
	else
		# Reserve 120s: tunnel <=22s, new runtime <=41s, rollback <=51s, file writes.
		if [ "$(vps_time_left 120)" != 120 ]; then
			APPLY_ROUTER_ERROR='insufficient job budget for safe cutover and rollback'
			rm -f "$base".*; return 1
		fi
		backup="${ROUTER_CONFIG}.bak.$(date +%s).$$"
		cert_backup="${ROUTER_CERT}.bak.$(date +%s).$$"
		tunnel_backup="${ROUTER_TUNNEL_CONFIG}.bak.$(date +%s).$$"
		backup_apply_file "$ROUTER_CONFIG" "$backup" &&
			backup_apply_file "$ROUTER_CERT" "$cert_backup" &&
			backup_apply_file "$ROUTER_TUNNEL_CONFIG" "$tunnel_backup" &&
			backup_apply_file "$ROUTER_READY_FILE" "$backup.ready" || {
			APPLY_ROUTER_ERROR='backup failed; live config unchanged'; rm -f "$base".*; return 1;
		}
		APPLY_ROUTER_PHASE='unknown'
		if ! activate_profile_tunnel "$profile_id" 6>&- ||
			! mv "$rendered" "$ROUTER_CONFIG" || ! mv "$fetched" "$ROUTER_CERT" ||
			! chmod 600 "$ROUTER_CONFIG" "$ROUTER_CERT" || ! touch "$ROUTER_READY_FILE" ||
			! chmod 600 "$ROUTER_READY_FILE" || ! restart_profile_runtime; then rc=1; fi
		rm -f "$base".*
		if [ "$rc" -ne 0 ]; then
			APPLY_ROUTER_ERROR='selected configuration could not start locally'
			if rollback_router_profile "$backup" "$cert_backup" "$tunnel_backup"; then
				APPLY_ROUTER_PHASE='rolled_back'
			else
				APPLY_ROUTER_ERROR='local apply and rollback failed; inspect runtime and preserved backups'
			fi
			return 1
		fi
		APPLY_ROUTER_PHASE='applied'
	fi
	# External reachability is health, never a reason to restore the old target.
	# Hardware OFF and software OFF both leave the path down on purpose.
	if ! path_allowed; then
		APPLY_PATH_HEALTH='not_checked'
		return 0
	fi
	APPLY_PATH_HEALTH='failed'
	verify_applied_profile_path "$profile_id" || return 1
	APPLY_PATH_HEALTH='ok'
}

router_apply_job_running() {
	local state pid
	local ROUTER_APPLY_STATUS_FILE="$(router_apply_status_path)"
	[ -f "$ROUTER_APPLY_STATUS_FILE" ] || return 1
	state="$(sed -n 's/^state=//p' "$ROUTER_APPLY_STATUS_FILE" | sed -n '1p')"
	if [ "$state" = scheduled ]; then
		local scheduled
		scheduled="$(sed -n 's/^scheduled_at=//p' "$ROUTER_APPLY_STATUS_FILE")"
		[ "$(($(date +%s) - ${scheduled:-0}))" -lt 10 ] && return 0
		profile_job_start_failed "$ROUTER_APPLY_STATUS_FILE" "$ROUTER_APPLY_STATUS_FILE.request" '' 'Accepted apply did not start within its scheduled grace period.'
		return 1
	fi
	[ "$state" = 'running' ] || return 1
	pid="$(sed -n 's/^pid=//p' "$ROUTER_APPLY_STATUS_FILE" | sed -n '1p')"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Spawn a detached copy of this CGI in job mode. start-stop-daemon -b
# double-forks and detaches from the fcgiwrap process group, so the job
# survives the end of the HTTP request that scheduled it.
schedule_router_apply_job() {
	local profile_id="$1" origin="$2" accepted="$(date +%s)-$$" request_id
	local current_status="$ROUTER_APPLY_STATUS_FILE"
	request_id="$(request_value request_id)"

	if router_apply_job_running || repair_job_running; then
		return 2
	fi
	umask 077
	# Reuse the existing job store; only this locked scheduler changes the pointer.
	mkdir -p "$VPS_REPAIR_JOB_DIR/$accepted" || return 1
	chmod 700 "$VPS_REPAIR_JOB_DIR" "$VPS_REPAIR_JOB_DIR/$accepted" || return 1
	local ROUTER_APPLY_STATUS_FILE="$VPS_REPAIR_JOB_DIR/$accepted/status"
	printf '%s' "$REQUEST_DATA" > "$ROUTER_APPLY_STATUS_FILE.request" || return 1
	{
		printf 'state=scheduled\n'
		printf 'profile=%s\n' "$profile_id"
		printf 'origin=%s\naccepted=%s\nrequest_id=%s\n' "$origin" "$accepted" "$request_id"
		printf 'scheduled_at=%s\n' "$(date +%s)"
	} > "$ROUTER_APPLY_STATUS_FILE.tmp"
	mv "$ROUTER_APPLY_STATUS_FILE.tmp" "$ROUTER_APPLY_STATUS_FILE"
	ln -s "$ROUTER_APPLY_STATUS_FILE" "$current_status.new.$$" &&
		mv -f "$current_status.new.$$" "$current_status" || {
		rm -f "$current_status.new.$$"
		profile_job_start_failed "$ROUTER_APPLY_STATUS_FILE" "$ROUTER_APPLY_STATUS_FILE.request" '' 'Could not publish the accepted apply job.'; return 1;
	}
	ROUTER_APPLY_ACCEPTED="$accepted"
	exec 6>&-
	XRAY_VPS_JOB='apply_router' XRAY_VPS_JOB_PROFILE="$profile_id" XRAY_VPS_JOB_ORIGIN="$origin" XRAY_VPS_JOB_ACCEPTED="$accepted" \
		start-stop-daemon -S -b -x /www/cgi-bin/xray-vps </dev/null >/dev/null 2>&1 6>&- 9>&- || {
			profile_job_start_failed "$ROUTER_APPLY_STATUS_FILE" "$ROUTER_APPLY_STATUS_FILE.request" '' 'Router could not start the detached apply process.'
			case "$(sed -n 's/^state=//p' "$ROUTER_APPLY_STATUS_FILE")" in running|done) return 0;; esac
			return 1
		}
}

schedule_router_apply_action_for() {
	local action="$1" profile_id="$2" rc=0
	schedule_router_apply_job "$profile_id" "$action" || rc=$?
	case "$rc" in
		2) emit_error "$action" 'A router profile apply job is already running.'; return 0 ;;
		1) emit_error "$action" 'Router could not start the detached profile apply job.'; return 0 ;;
	esac
	emit_header
	printf '{"ok":true,"action":"%s","job_state":"scheduled","profile_id":"%s","job_id":"%s"}' \
		"$(json_escape "$action")" "$(json_escape "$profile_id")" "$ROUTER_APPLY_ACCEPTED"
}

schedule_router_apply_action() {
	local profile_id
	profile_id="$(active_profile_id)"
	[ -n "$profile_id" ] || { emit_error apply_router 'No active VPS profile is selected.'; return 0; }
	schedule_router_apply_action_for apply_router "$profile_id"
}

run_router_apply_job() {
	local profile_id="$1" origin="${XRAY_VPS_JOB_ORIGIN:-apply_router}" rc=0 message request_id
	local ROUTER_APPLY_STATUS_FILE="$(router_apply_status_path)"
	[ -z "${XRAY_VPS_JOB_ACCEPTED:-}" ] || ROUTER_APPLY_STATUS_FILE="$VPS_REPAIR_JOB_DIR/$XRAY_VPS_JOB_ACCEPTED/status"
	set +e
	umask 077
	APPLY_ROUTER_PHASE='unchanged'; APPLY_PATH_HEALTH='not_checked'; PROFILE_VERIFY_LOG=''
	if ! profile_worker_lock "$ROUTER_APPLY_STATUS_FILE"; then
		if [ -z "${XRAY_VPS_JOB_ACCEPTED:-}" ] || [ "$XRAY_VPS_JOB_ACCEPTED" = "$(sed -n 's/^accepted=//p' "$ROUTER_APPLY_STATUS_FILE")" ]; then
			profile_job_start_failed "$ROUTER_APPLY_STATUS_FILE" "$ROUTER_APPLY_STATUS_FILE.request" '' 'Detached apply could not acquire the transaction lock within its handoff budget.'
		fi
		return 1
	fi
	if [ -n "${XRAY_VPS_JOB_ACCEPTED:-}" ] &&
		{ [ "$XRAY_VPS_JOB_ACCEPTED" != "$(sed -n 's/^accepted=//p' "$ROUTER_APPLY_STATUS_FILE")" ] || [ ! -f "$ROUTER_APPLY_STATUS_FILE.request" ]; }; then
		exec 6>&-; return 2
	fi
	VPS_JOB_PROFILE="$profile_id"
	VPS_JOB_REQUEST="$ROUTER_APPLY_STATUS_FILE.request.running"
	trap 'profile_job_cleanup "$VPS_JOB_PROFILE"' EXIT
	trap 'exit 143' TERM INT
	mv "$ROUTER_APPLY_STATUS_FILE.request" "$VPS_JOB_REQUEST" 2>/dev/null || { trap - EXIT TERM INT; profile_job_cleanup "$profile_id"; return 2; }
	REQUEST_DATA="$(cat "$VPS_JOB_REQUEST" 2>/dev/null)"
	request_id="$(request_value request_id)"
	rm -f "$VPS_JOB_REQUEST"
	printf 'state=running\nprofile=%s\norigin=%s\npid=%s\nrequest_id=%s\n' "$profile_id" "$origin" "$$" "$request_id" > "$ROUTER_APPLY_STATUS_FILE.tmp"
	printf 'accepted=%s\n' "${XRAY_VPS_JOB_ACCEPTED:-}" >> "$ROUTER_APPLY_STATUS_FILE.tmp"
	mv "$ROUTER_APPLY_STATUS_FILE.tmp" "$ROUTER_APPLY_STATUS_FILE"
	: > "$ROUTER_APPLY_STATUS_FILE.log"
	printf '[]\n' > "$ROUTER_APPLY_STATUS_FILE.steps"
	REPAIR_REPORT='[]'; REPAIR_FATAL=''
	SSH_RAW_LOG_PATH="$ROUTER_APPLY_STATUS_FILE.log"
	export SSH_RAW_LOG_PATH
	APPLY_ROUTER_ERROR='could not inspect authoritative VPS settings'
	if [ "$origin" = apply_router ]; then
		refresh_remote_cache "$profile_id" >/dev/null 2>&1 && adopt_remote_into_profile "$profile_id" || rc=1
	else
		if ! ensure_ssh_ready "$profile_id"; then
			APPLY_ROUTER_ERROR="SSH access failed (${SSH_FAILURE_KIND:-authentication/bootstrap}); see control diagnostics"; rc=1
		elif ! prepare_profile_from_vps "$profile_id"; then
			rc=1
		elif ! run_repair_pipeline "$profile_id"; then
			APPLY_ROUTER_ERROR="server repair failed; see step report${REPAIR_FATAL:+: $REPAIR_FATAL}"; rc=1
		else
			SSH_RAW_LOG_PATH="$ROUTER_APPLY_STATUS_FILE.log"
			export SSH_RAW_LOG_PATH
			refresh_remote_cache "$profile_id" && adopt_remote_into_profile "$profile_id" || rc=1
		fi
		printf '%s\n' "$REPAIR_REPORT" > "$ROUTER_APPLY_STATUS_FILE.steps.tmp"
		mv "$ROUTER_APPLY_STATUS_FILE.steps.tmp" "$ROUTER_APPLY_STATUS_FILE.steps"
		if [ -f "${REPAIR_RAW_LOG_PATH:-}" ]; then
			cat "$REPAIR_RAW_LOG_PATH" >> "$ROUTER_APPLY_STATUS_FILE.log"
			rm -f "$REPAIR_RAW_LOG_PATH"
		fi
	fi
	SSH_RAW_LOG_PATH="$ROUTER_APPLY_STATUS_FILE.log"
	export SSH_RAW_LOG_PATH
	[ "$rc" -ne 0 ] || apply_profile_to_router_internal "$profile_id" || rc=1
	unset SSH_RAW_LOG_PATH
	message="$(router_apply_message)"
	printf '%s\n' "$PROFILE_VERIFY_LOG" >> "$ROUTER_APPLY_STATUS_FILE.log"
	{
		if [ "$rc" -eq 0 ]; then printf 'state=done\n'; else printf 'state=failed\n'; fi
		printf 'profile=%s\norigin=%s\nfinished_at=%s\nrequest_id=%s\n' "$profile_id" "$origin" "$(date +%s)" "$request_id"
		printf 'accepted=%s\n' "${XRAY_VPS_JOB_ACCEPTED:-}"
		printf 'router_apply=%s\npath_health=%s\nmessage=%s\n' "$APPLY_ROUTER_PHASE" "$APPLY_PATH_HEALTH" "$message"
	} > "$ROUTER_APPLY_STATUS_FILE.tmp"
	mv "$ROUTER_APPLY_STATUS_FILE.tmp" "$ROUTER_APPLY_STATUS_FILE"
	trap - EXIT TERM INT
	profile_job_cleanup "$VPS_JOB_PROFILE"
	return "$rc"
}

# --- Detached VPS check/configure job (DIAGNOSTIC-TREE 8.1d) ---
# The repair pipeline can restart the VPS daemon and must not occupy a CGI
# worker. The request payload is mode 0600 and removed as soon as the detached
# process reads it; this is especially important for the one-shot password.
VPS_REPAIR_JOB_DIR='/tmp/xray-vps-repair-jobs'

repair_job_valid_id() {
	case "$1" in ''|*[!0-9-]*) return 1 ;; esac
}

repair_job_running() {
	local job_id state pid
	job_id="$(cat "$VPS_REPAIR_JOB_DIR/active" 2>/dev/null || true)"
	repair_job_valid_id "$job_id" || return 1
	state="$(sed -n 's/^state=//p' "$VPS_REPAIR_JOB_DIR/$job_id/status" 2>/dev/null | sed -n '1p')"
	if [ "$state" = scheduled ]; then
		local scheduled
		scheduled="$(sed -n 's/^scheduled_at=//p' "$VPS_REPAIR_JOB_DIR/$job_id/status")"
		[ "$(($(date +%s) - ${scheduled:-0}))" -lt 10 ] && return 0
		profile_job_start_failed "$VPS_REPAIR_JOB_DIR/$job_id/status" "$VPS_REPAIR_JOB_DIR/$job_id/request" "$VPS_REPAIR_JOB_DIR/$job_id/result" 'Accepted repair did not start within its scheduled grace period.'
		return 1
	fi
	[ "$state" = 'running' ] || return 1
	pid="$(sed -n 's/^pid=//p' "$VPS_REPAIR_JOB_DIR/$job_id/status" 2>/dev/null | sed -n '1p')"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

schedule_vps_repair_job_action() {
	mkdir -p "$VPS_REPAIR_JOB_DIR"
	schedule_vps_repair_job_locked
}

schedule_vps_repair_job_locked() {
	local job_id job_dir profile_id origin=diagnose_repair
	chmod 700 "$VPS_REPAIR_JOB_DIR"
	if repair_job_running || router_apply_job_running; then
		emit_error diagnose_repair 'A VPS check/configure job is already running.'
		return 0
	fi
	profile_id="$(active_profile_id)"
	if request_has_profile_edit; then
		save_profile_from_request >/dev/null || { emit_error diagnose_repair "$SAVE_PROFILE_ERROR"; return 0; }
		profile_id="$SAVE_PROFILE_ID"
	fi
	[ -n "$profile_id" ] || { emit_error diagnose_repair 'No selected profile'; return 0; }
	job_id="$(date +%s)-$$"
	job_dir="$VPS_REPAIR_JOB_DIR/$job_id"
	mkdir -p "$job_dir"
	chmod 700 "$job_dir"
	printf '%s\n' "$profile_id" > "$job_dir/profile"
	(umask 077; printf '%s' "$REQUEST_DATA" > "$job_dir/request")
	{
		printf 'state=scheduled\norigin=diagnose_repair\nprofile=%s\nrequest_id=%s\n' "$profile_id" "$(request_value request_id)"
		printf 'scheduled_at=%s\n' "$(date +%s)"
	} > "$job_dir/status.tmp"
	mv "$job_dir/status.tmp" "$job_dir/status"
	printf '%s\n' "$job_id" > "$VPS_REPAIR_JOB_DIR/active"
	exec 6>&-
	if ! XRAY_VPS_JOB='diagnose_repair' XRAY_VPS_JOB_ID="$job_id" \
		start-stop-daemon -S -b -x /www/cgi-bin/xray-vps </dev/null >/dev/null 2>&1 6>&- 9>&-; then
		profile_job_start_failed "$job_dir/status" "$job_dir/request" "$job_dir/result" 'Router could not start the detached VPS job.'
		case "$(sed -n 's/^state=//p' "$job_dir/status")" in running|done) ;; *)
		emit_error diagnose_repair 'Router could not start the detached VPS job.'
		return 0
		esac
	fi
	emit_header
	printf '{"ok":true,"action":"diagnose_repair","job_state":"scheduled","job_id":"%s"}' "$(json_escape "$job_id")"
}

run_vps_repair_job() {
	local job_id="$1" job_dir raw body request_id rc=0
	repair_job_valid_id "$job_id" || return 2
	job_dir="$VPS_REPAIR_JOB_DIR/$job_id"
	raw="$job_dir/response.raw"
	body="$job_dir/result.tmp"
	[ -f "$job_dir/request" ] || return 2
	umask 077
	if ! profile_worker_lock "$job_dir/status"; then
		profile_job_start_failed "$job_dir/status" "$job_dir/request" "$job_dir/result" 'Detached repair could not acquire the transaction lock within its handoff budget.'
		return 1
	fi
	[ -f "$job_dir/request" ] || { exec 6>&-; return 2; }
	if [ -f "$VPS_REPAIR_JOB_DIR/active" ] && [ "$(cat "$VPS_REPAIR_JOB_DIR/active")" != "$job_id" ]; then
		rm -f "$job_dir/request"; exec 6>&-; return 2
	fi
	VPS_JOB_PROFILE="$(cat "$job_dir/profile")"
	VPS_JOB_REQUEST="$job_dir/request.running"
	trap 'profile_job_cleanup "$VPS_JOB_PROFILE"' EXIT
	trap 'exit 143' TERM INT
	APPLY_ROUTER_PHASE=unchanged; APPLY_PATH_HEALTH=not_checked
	mv "$job_dir/request" "$job_dir/request.running" 2>/dev/null || { exec 6>&-; return 2; }
	REQUEST_DATA="$(cat "$job_dir/request.running")"
	request_id="$(request_value request_id)"
	rm -f "$job_dir/request.running"
	{
		printf 'state=running\nprofile=%s\norigin=diagnose_repair\nrequest_id=%s\n' "$VPS_JOB_PROFILE" "$request_id"
		printf 'pid=%s\n' "$$"
		printf 'started_at=%s\n' "$(date +%s)"
	} > "$job_dir/status.tmp"
	mv "$job_dir/status.tmp" "$job_dir/status"
	set +e
	diagnose_repair_action > "$raw" 2>&1 || rc=$?
	if ! vps_time_left 1 >/dev/null; then
		emit_header > "$raw"
		printf '{"ok":false,"action":"diagnose_repair","error":"deadline_exceeded","reason":"Recovery exhausted its shared budget; inspect the application and health result before retrying.","router_apply":"%s","path_health":"%s","profile_id":"%s","steps":%s,"raw_log":"%s"}' \
			"$APPLY_ROUTER_PHASE" "$APPLY_PATH_HEALTH" "$(json_escape "$VPS_JOB_PROFILE")" \
			"${REPAIR_REPORT:-[]}" "${REPAIR_TERMINAL_RAW_LOG:-$(json_escape "${PROFILE_VERIFY_LOG:-}")}" >> "$raw"
		rc=124
	fi
	tr -d '\r' < "$raw" | sed '1,/^$/d' > "$body"
	if [ "$(jsonfilter -s "[$(cat "$body")]" -t '@[0].ok' 2>/dev/null)" != boolean ] ||
		[ -n "$(jsonfilter -s "[$(cat "$body")]" -t '@[1]' 2>/dev/null)" ]; then
		printf '{"ok":false,"action":"diagnose_repair","error":"job_failed","reason":"Detached VPS job returned no valid response; inspect actual runtime.","router_apply":"unknown","path_health":"unknown","steps":[]}' > "$body"
	fi
	[ "$(jsonfilter -i "$body" -e '@.ok')" = false ] && [ "$rc" -ne 124 ] && rc=1
	chmod 600 "$body"
	mv "$body" "$job_dir/result"
	rm -f "$raw"
	{
		printf 'state=done\norigin=diagnose_repair\nprofile=%s\nrequest_id=%s\n' "$VPS_JOB_PROFILE" "$request_id"
		printf 'finished_at=%s\n' "$(date +%s)"
		printf 'exit_code=%s\n' "$rc"
	} > "$job_dir/status.tmp"
	mv "$job_dir/status.tmp" "$job_dir/status"
	trap - EXIT TERM INT
	profile_job_cleanup "$VPS_JOB_PROFILE"
	return "$rc"
}

vps_repair_job_status_action() {
	local job_id job_dir state pid scheduled
	job_id="$(request_value job_id)"
	repair_job_valid_id "$job_id" || {
		emit_error diagnose_repair_status 'Invalid or missing VPS job ID.'
		return 0
	}
	job_dir="$VPS_REPAIR_JOB_DIR/$job_id"
	if [ -s "$job_dir/result" ]; then
		emit_header
		cat "$job_dir/result"
		return 0
	fi
	state="$(sed -n 's/^state=//p' "$job_dir/status" 2>/dev/null | sed -n '1p')"
	pid="$(sed -n 's/^pid=//p' "$job_dir/status" 2>/dev/null | sed -n '1p')"
	scheduled="$(sed -n 's/^scheduled_at=//p' "$job_dir/status" 2>/dev/null)"
	if { [ "$state" = scheduled ] && [ "$(($(date +%s) - ${scheduled:-0}))" -lt 10 ]; } || { [ "$state" = running ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }; then
		emit_header
		printf '{"ok":true,"action":"diagnose_repair_status","job_state":"%s","job_id":"%s"}' "$(json_escape "$state")" "$(json_escape "$job_id")"
		return 0
	fi
	profile_job_start_failed "$job_dir/status" "$job_dir/request" "$job_dir/result" 'Accepted repair ended before claiming its request.'
	if [ -s "$job_dir/result" ]; then emit_header; cat "$job_dir/result"; return; fi
	emit_header
	printf '{"ok":false,"error":"job_interrupted","router_apply":"unknown","path_health":"unknown","reason":"Job ended without a result; inspect actual target and runtime before retrying."}'
}

profile_job_cleanup() {
	# Run on ordinary exit and interruption; SIGKILL is reported unknown by polling.
	profile_del "$1" ssh_password
	uci commit "$PROFILE_PACKAGE"
	rm -f "/tmp/codex-xray.profile.$$".*
	[ -z "${VPS_JOB_REQUEST:-}" ] || rm -f "$VPS_JOB_REQUEST"
	exec 6>&-
}
