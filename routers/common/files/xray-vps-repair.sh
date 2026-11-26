#!/bin/sh
# xray-vps-repair.sh — diagnose+repair pipeline and its response emitters
# Deployed to /usr/share/vpn-xray/xray-vps-repair.sh
# Sourced by /www/cgi-bin/xray-vps after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

# Return 0 when the current request carries any profile access field that
# save_profile_from_request expects. Used to
# decide whether an incoming diagnose_repair call is being made from the
# UI (form-based, edit-then-submit) or from a headless caller that only
# wants to trigger repair on the already-selected profile.
request_has_profile_edit() {
	local key
	for key in profile_id label vps_profile ssh_host ssh_port ssh_user \
		auth_mode bootstrap_private_key; do
		if request_has_key "$key"; then
			return 0
		fi
	done
	return 1
}

# The cache must describe exactly the executable consumed by provisioning.
inspected_provision_binary_ready() {
	local id="$1" cache expected
	cache="$(profile_cache_path "$id")"
	expected="$(vps_profile_value "$(selected_vps_profile "$id")" VPS_XRAY_BINARY)"
	[ -n "$expected" ] && [ "$(cache_get "$cache" REMOTE_XRAY_BINARY)" = "$expected" ] &&
		[ "$(cache_get "$cache" REMOTE_XRAY_RUNNABLE)" = 1 ]
}

# Run the VPS repair pipeline over an established SSH connection. Stages
# the rendered config + meta + repair script into /tmp on the VPS, runs
# the script with REPAIR_REPORT_PATH pointing at a report file, then
# reads the report back and streams it as the "steps" array of the CGI
# response. The report format is defined in install-vps.remote.sh.
run_repair_pipeline() {
	local profile_id="$1"
	local vps_profile install_script_rel install_script_path remote_meta_path
	local rendered meta rendered_install cache vps_arch vps_pkg_dir bundled_xray
	local report_local report_remote='/tmp/codex-router-vps-repair.jsonl'
	local raw_log_file
	REPAIR_FATAL=''; REPAIR_ERROR=pipeline_setup_failed

	# SSH_RAW_LOG_PATH tells ssh_exec_with_identity / ssh_stdin_with_identity
	# to append their stderr to this file. Fcgiwrap keeps fd 3+ busy for
	# its FastCGI channel so we cannot use `exec 3>>file` here — the
	# path-based redirect below is portable across those environments.
	raw_log_file="/tmp/codex-router-vps-repair-raw.$$.log"
	: > "$raw_log_file"
	SSH_RAW_LOG_PATH="$raw_log_file"
	export SSH_RAW_LOG_PATH

	log_step() {
		printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >> "$raw_log_file"
	}

	vps_profile="$(selected_vps_profile "$profile_id")"
	install_script_rel="$(vps_profile_value "$vps_profile" VPS_INSTALL_SCRIPT)"
	install_script_path="$(vps_profile_file_path "$vps_profile" "$install_script_rel")"
	remote_meta_path="$(vps_profile_value "$vps_profile" VPS_REMOTE_META_PATH)"
	[ -f "$install_script_path" ] || {
		log_step "FATAL repair script template missing on router at $install_script_path"
		REPAIR_REPORT='[]'
		REPAIR_FATAL='Repair script template is not available on the router.'
		REPAIR_RAW_LOG_PATH="$raw_log_file"
		unset SSH_RAW_LOG_PATH
		return 1
	}
	[ -n "$remote_meta_path" ] || remote_meta_path='/usr/local/etc/xray/codex-router-meta.env'

	rendered='/tmp/codex-router-vps-config.json'
	meta='/tmp/codex-router-vps-meta.env'
	rendered_install='/tmp/codex-router-install.remote.sh'
	report_local="/tmp/codex-router-vps-repair.$$.jsonl"

	log_step "rendering server config, meta, and repair script templates"
	if ! render_server_config "$rendered" "$profile_id" ||
		! render_remote_meta "$meta" "$profile_id" ||
		! render_vps_profile_template "$profile_id" "$install_script_path" "$rendered_install"; then
		log_step 'FAILED to assemble/render VPS repair inputs; nothing uploaded'
		REPAIR_REPORT='[]'; REPAIR_FATAL='VPS repair source parts or rendered inputs are invalid.'
		REPAIR_RAW_LOG_PATH="$raw_log_file"
		unset SSH_RAW_LOG_PATH
		rm -f "$rendered" "$meta" "$rendered_install"
		return 1
	fi

	# Single-round-trip upload (DIAGNOSTIC-TREE 3.4 resilience): the old
	# path opened 3-6 separate SSH connections (config, meta, script, an
	# xray-present test, a uname, then execute). On a rate-limited WiFi
	# repeater uplink the later connections in that burst get refused, so
	# the whole repair failed even though the VPS was fine. We now stage
	# the three files under the exact names the remote script expects,
	# tar them, and hand the tar to a single SSH that extracts and runs
	# the pipeline in one session (see the execute step below). Result:
	# one connection instead of many, well within the burst limit.
	local stage="/tmp/codex-repair-stage.$$"
	local bundle_tar="/tmp/codex-repair-bundle.$$.tar"
	rm -rf "$stage"; mkdir -p "$stage"
	cp "$rendered" "$stage/codex-router-vps-config.json"
	cp "$meta" "$stage/codex-router-meta.env"
	chmod 600 "$stage/codex-router-meta.env"
	cp "$rendered_install" "$stage/install-vps.remote.sh"
	# DIAGNOSTIC-TREE 6.1 / install air-gap contract: a clean VPS must not
	# depend on GitHub or package mirrors for the Xray binary. The preceding
	# inspection recorded the architecture, so add the matching repo-bundled
	# archive to the same single-session tar used by the repair pipeline.
	cache="$(profile_cache_path "$profile_id")"
	vps_arch="$(cache_get "$cache" REMOTE_ARCH)"
	vps_pkg_dir="/usr/share/vpn-xray/vps/${vps_profile}/packages"
	bundled_xray=''
	case "$vps_arch" in
		x86_64|amd64) bundled_xray="${vps_pkg_dir}/$(vps_profile_value "$vps_profile" VPS_XRAY_ARCHIVE_X64)" ;;
		aarch64|arm64) bundled_xray="${vps_pkg_dir}/$(vps_profile_value "$vps_profile" VPS_XRAY_ARCHIVE_ARM64)" ;;
	esac
	if inspected_provision_binary_ready "$profile_id"; then
		log_step "inspected VPS binary is runnable; no archive upload needed"
	elif [ -n "$bundled_xray" ] && [ -f "$bundled_xray" ]; then
		cp "$bundled_xray" "$stage/xray-bundled.zip"
		log_step "staged bundled Xray archive for ${vps_arch}"
	else
		log_step "WARNING no bundled Xray archive for remote architecture ${vps_arch:-unknown}"
	fi
	if ! tar -C "$stage" -cf "$bundle_tar" . 2>/dev/null; then
		log_step "FAILED to build the upload bundle tar"
		REPAIR_REPORT='[]'
		REPAIR_FATAL='Failed to stage the repair upload bundle on the router.'
		REPAIR_RAW_LOG_PATH="$raw_log_file"
		rm -rf "$stage"; rm -f "$bundle_tar" "$rendered" "$meta" "$rendered_install" "$report_local"
		unset SSH_RAW_LOG_PATH
		return 1
	fi

	log_step "executing repair pipeline on VPS (single-session upload+run)"
	REPAIR_ERROR=pipeline_report_failed
	local ssh_rc=0
	# The remote service pipeline keeps its 90s cap; upload, SSH and
	# live checks also share the detached job's 170s deadline.
	# The script runs under set -e, so a non-zero ssh_cmd exit would kill
	# the whole CGI silently before we get to record it. Guard with an
	# if-block so a failed repair pipeline surfaces as a proper report
	# rather than a truncated response with no body.
	#
	# A lost report does not prove non-execution. Never replay this mutation.
	local exec_cmd remote_limit control_client_ip
	ssh_rc=124
	control_client_ip="$(router_external_ip)"
	remote_limit="$(vps_time_left 170)" || remote_limit=0
	if [ "$remote_limit" -gt 15 ]; then
		remote_limit=$((remote_limit - 15))
		exec_cmd="timeout $remote_limit sh -c 'cd /tmp && tar -xf - && chmod 755 /tmp/install-vps.remote.sh && rm -f $report_remote && { VPS_CONTROL_CLIENT_IP=\"\$2\" VPS_REMOTE_META_PATH=\"\$1\" REPAIR_REPORT_PATH=\"$report_remote\" timeout 90 sh /tmp/install-vps.remote.sh >/dev/null 2>&1; ec=\$?; cat $report_remote 2>/dev/null; exit \$ec; }' sh '$remote_meta_path' '$control_client_ip'"
		if ssh_stdin_cmd "$profile_id" "$exec_cmd" "$bundle_tar" > "$report_local"; then
			ssh_rc=0
		else
			ssh_rc=$?
		fi
	fi
	rm -rf "$stage"; rm -f "$bundle_tar"
	if [ ! -s "$report_local" ]; then
		# The installer may still restart the VPS xray (config change or a
		# failed health check). A tunnel-riding control session then loses
		# transport before the report is read, although the report file on
		# the VPS is complete. Re-read it over a fresh session before
		# declaring the pipeline incomplete; never replay the mutation.
		ssh_read_cmd "$profile_id" "cat '$report_remote' 2>/dev/null" 20 </dev/null > "$report_local" 2>/dev/null || true
	fi
	log_step "repair pipeline finished with exit=$ssh_rc"

	# A lost report cannot distinguish failed delivery from remote execution
	# whose response was lost. Do not claim that nothing ran on the VPS.
	if [ ! -s "$report_local" ]; then
		REPAIR_FATAL='No repair report arrived before transport or the job budget ended. Remote execution may have started; inspect the VPS and raw log before retrying.'
		REPAIR_REPORT='[]'
		REPAIR_RAW_LOG_PATH="$raw_log_file"
		unset SSH_RAW_LOG_PATH
		rm -f "$rendered" "$meta" "$rendered_install" "$report_local"
		return 1
	fi

	# Validate and canonicalize each row, including a final line without LF.
	REPAIR_REPORT='['
	local first=1 line row
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		if [ "$(jsonfilter -s "[$line]" -t '@[0]' 2>/dev/null)" != object ] ||
			[ -n "$(jsonfilter -s "[$line]" -t '@[1]' 2>/dev/null)" ] ||
			! row="$(jsonfilter -s "[$line]" -e '@[0]' 2>/dev/null)"; then
			REPAIR_FATAL='Malformed or truncated VPS repair report; remote execution may have started. No mutation replayed.'
			log_step "$REPAIR_FATAL"
			head -c 8192 "$report_local" >> "$raw_log_file"
			REPAIR_REPORT='[]'; REPAIR_RAW_LOG_PATH="$raw_log_file"
			unset SSH_RAW_LOG_PATH
			rm -f "$rendered" "$meta" "$rendered_install" "$report_local"
			return 1
		fi
		if [ "$first" = '1' ]; then
			first=0
		else
			REPAIR_REPORT="${REPAIR_REPORT},"
		fi
		row="$(printf '%s' "$row" | sed 's/"id"[[:space:]]*:[[:space:]]*"overall"/"id":"server_overall"/')"
		REPAIR_REPORT="${REPAIR_REPORT}${row}"
	done < "$report_local"
	REPAIR_REPORT="${REPAIR_REPORT}]"

	REPAIR_RAW_LOG_PATH="$raw_log_file"
	unset SSH_RAW_LOG_PATH
	rm -f "$rendered" "$meta" "$rendered_install" "$report_local"
	return "$ssh_rc"
}

# Server repair, router application and live-path health have separate results.
# Trim, escape, and cap the raw log so a long transcript does not blow
# up the JSON response. Returns the JSON string value (without the outer
# quotes) via stdout; empty string when the log file is missing.
raw_log_payload() {
	local path="$1"
	local size max=32768 content
	[ -n "$path" ] || return 0
	[ -f "$path" ] || return 0
	size="$(wc -c < "$path" 2>/dev/null || echo 0)"
	if [ "$size" -gt "$max" ]; then
		content="[log truncated to last ${max} bytes]
$(tail -c "$max" "$path" 2>/dev/null)"
	else
		content="$(cat "$path" 2>/dev/null)"
	fi
	json_escape "$content"
}

emit_repair_response() {
	local ok="$1"
	local report="$2"
	local raw_log="${3:-}"
	local router_apply="${4:-unchanged}"
	emit_header
	printf '{'
	printf '"ok":'
	json_bool "$ok"
	printf ','
	printf '"action":"diagnose_repair",'
	printf '"steps":%s,' "$report"
	printf '"raw_log":"%s",' "$raw_log"
	printf '"router_apply":"%s","path_health":"%s","profile_id":"%s","origin":"diagnose_repair",' "$(json_escape "$router_apply")" "${APPLY_PATH_HEALTH:-not_checked}" "$(json_escape "${VPS_JOB_PROFILE:-}")"
	printf '"applied":'
	case "$router_apply" in applied) printf true;; unknown|'') printf null;; *) printf false;; esac
	printf ','
	printf '"status":'
	status_json
	printf '}'
}

emit_repair_credentials_required() {
	local reason="$1"
	local raw_log="${2:-}"
	case "${SSH_FAILURE_KIND:-auth}" in auth|missing_key) ;; *)
		emit_header
		printf '{"ok":false,"action":"diagnose_repair","error":"ssh_%s","reason":"Control SSH failed; see transport/host-key diagnostics. Credentials were not requested.","router_apply":"unchanged","path_health":"not_checked","applied":false,"steps":[],"raw_log":"%s"}' "$(json_escape "$SSH_FAILURE_KIND")" "$raw_log"
		return 0;; esac
	emit_header
	printf '{'
	printf '"ok":false,'
	printf '"action":"diagnose_repair",'
	printf '"error":"credentials_required","router_apply":"unchanged","path_health":"not_checked","applied":false,'
	printf '"reason":"%s",' "$(json_escape "$reason")"
	printf '"raw_log":"%s",' "$raw_log"
	# Fields the UI should collect and re-submit. If the profile has a
	# bootstrap key slot filled we still keep it as a fallback option.
	printf '"need":["ssh_password"],'
	printf '"steps":[]'
	printf '}'
}

diagnose_repair_action() {
	# The repair pipeline contains many "risky" commands whose non-zero
	# exit codes are meaningful data (SSH refused, wc on a missing file,
	# etc.) — the calling contract of set -e in this CGI would abort the
	# whole response before we could serialize a report. Turn it off for
	# the duration of this action and re-enable at the very end.
	set +e
	REPAIR_TERMINAL_RAW_LOG=''

	# Accepted profile is fixed by the scheduler under the shared transaction lock.
	local profile_id="${VPS_JOB_PROFILE:-}"
	[ -n "$profile_id" ] || { emit_error diagnose_repair 'Missing accepted profile'; return 1; }
	# One-shot SSH password from the UI: install_managed_key_with_password
	# already reads ssh_password from the request. Stash it into the
	# profile just long enough for ensure_ssh_ready to use; the helpers
	# themselves clear it once the managed key install succeeds.
	local one_shot_password
	one_shot_password="$(request_value ssh_password)"
	if [ -n "$one_shot_password" ]; then
		profile_set "$profile_id" auth_mode 'password'
		profile_set "$profile_id" ssh_password "$one_shot_password"
		uci commit "$PROFILE_PACKAGE"
	fi

	# Capture SSH stderr from the credential-check probe into a dedicated
	# log so the credentials_required response can show the actual reason
	# (Connection refused, permission denied, unreachable, etc.) instead
	# of a generic message.
	local creds_raw_log="/tmp/codex-router-vps-creds-raw.$$.log"
	: > "$creds_raw_log"
	SSH_RAW_LOG_PATH="$creds_raw_log"
	export SSH_RAW_LOG_PATH
	printf '[%s] probing SSH with current credentials\n' "$(date +%H:%M:%S)" >> "$creds_raw_log"
	if ! ensure_ssh_ready "$profile_id"; then
		unset SSH_RAW_LOG_PATH
		local raw_payload
		raw_payload="$(raw_log_payload "$creds_raw_log")"
		REPAIR_TERMINAL_RAW_LOG="$raw_payload"
		rm -f "$creds_raw_log"
		emit_repair_credentials_required \
			'Router could not establish SSH to the VPS with the current credentials. Check the raw log below; if the reason is "Connection refused" or "timed out", the VPS is unreachable — not a credentials problem. Otherwise provide the VPS root password once so the router can re-install its managed key.' \
			"$raw_payload"
		return 0
	fi
	unset SSH_RAW_LOG_PATH
	# Fold the credential-probe log into the same file we hand back so
	# the operator sees the whole story in one place.
	local combined_raw_log="/tmp/codex-router-vps-combined-raw.$$.log"
	cat "$creds_raw_log" > "$combined_raw_log" 2>/dev/null || : > "$combined_raw_log"
	rm -f "$creds_raw_log"

	# DIAGNOSTIC-TREE 8.1: inspect and adopt before any render/write. Do not
	# fall back to stale local Xray values when authoritative inspection fails.
	SSH_RAW_LOG_PATH="$combined_raw_log"
	export SSH_RAW_LOG_PATH
	if ! prepare_profile_from_vps "$profile_id"; then
		unset SSH_RAW_LOG_PATH
		REPAIR_TERMINAL_RAW_LOG="$(raw_log_payload "$combined_raw_log")"
		emit_header
		printf '{"ok":false,"action":"diagnose_repair","error":"inspection_failed","router_apply":"unchanged","path_health":"not_checked","applied":false,"reason":"Could not read authoritative Xray settings from the VPS; refusing to render from stale local values.","steps":[],"raw_log":"%s"}' "$REPAIR_TERMINAL_RAW_LOG"
		rm -f "$combined_raw_log"
		return 0
	fi
	unset SSH_RAW_LOG_PATH

	local repair_rc=0
	run_repair_pipeline "$profile_id"
	repair_rc=$?

	# Append the pipeline log to the combined log.
	if [ -n "${REPAIR_RAW_LOG_PATH:-}" ] && [ -f "$REPAIR_RAW_LOG_PATH" ]; then
		cat "$REPAIR_RAW_LOG_PATH" >> "$combined_raw_log" 2>/dev/null || true
		rm -f "$REPAIR_RAW_LOG_PATH"
	fi

	local raw_payload

	if [ -n "${REPAIR_FATAL:-}" ] && [ "${REPAIR_REPORT:-[]}" = '[]' ]; then
		raw_payload="$(raw_log_payload "$combined_raw_log")"
		REPAIR_TERMINAL_RAW_LOG="$raw_payload"
		rm -f "$combined_raw_log"
		emit_header
		printf '{'
		printf '"ok":false,'
		printf '"action":"diagnose_repair",'
		printf '"error":"%s","router_apply":"unchanged","path_health":"not_checked","applied":false,' "${REPAIR_ERROR:-pipeline_setup_failed}"
		printf '"reason":"%s",' "$(json_escape "$REPAIR_FATAL")"
		printf '"raw_log":"%s",' "$raw_payload"
		printf '"steps":[]'
		printf '}'
		return 0
	fi

	local path_status='failed' path_message
	PROFILE_VERIFY_LOG=''
	APPLY_ROUTER_PHASE='unchanged'; APPLY_PATH_HEALTH='not_checked'
	APPLY_ROUTER_ERROR='server repair or authoritative re-inspection failed'
	SSH_RAW_LOG_PATH="$combined_raw_log"; export SSH_RAW_LOG_PATH
	if [ "$repair_rc" -eq 0 ]; then
		if refresh_remote_cache "$profile_id" >/dev/null 2>&1; then
			if apply_profile_to_router_internal "$profile_id"; then path_status=ok; fi
		else
			APPLY_ROUTER_ERROR="post-repair inspection failed: ${INSPECTION_ERROR:-control read failed; see raw log}"
		fi
	fi
	unset SSH_RAW_LOG_PATH
	path_message="$(router_apply_message)"
	printf '%s\n' "$PROFILE_VERIFY_LOG" >> "$combined_raw_log"
	raw_payload="$(raw_log_payload "$combined_raw_log")"
	REPAIR_TERMINAL_RAW_LOG="$raw_payload"
	rm -f "$combined_raw_log"
	[ "$path_status" = ok ] || repair_rc=1
	local separator=','
	[ "$REPAIR_REPORT" != '[]' ] || separator=''
	REPAIR_REPORT="${REPAIR_REPORT%]}${separator}$(printf '{"id":"selected_path","status":"%s","message":"%s"}' "$path_status" "$(json_escape "$path_message")")]"
	if [ "$repair_rc" -eq 0 ]; then
		emit_repair_response 1 "$REPAIR_REPORT" "$raw_payload" "$APPLY_ROUTER_PHASE"
	else
		emit_repair_response 0 "$REPAIR_REPORT" "$raw_payload" "$APPLY_ROUTER_PHASE"
	fi
	return 0
}
