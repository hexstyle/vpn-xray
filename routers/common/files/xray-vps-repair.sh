#!/bin/sh
# xray-vps-repair.sh — diagnose+repair pipeline and its response emitters
# Deployed to /usr/share/vpn-xray/xray-vps-repair.sh
# Sourced by /www/cgi-bin/xray-vps after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

# Return 0 when the current request carries any of the profile
# identity/routing fields that save_profile_from_request expects. Used to
# decide whether an incoming diagnose_repair call is being made from the
# UI (form-based, edit-then-submit) or from a headless caller that only
# wants to trigger repair on the already-selected profile.
request_has_profile_edit() {
	local key
	for key in profile_id label vps_profile ssh_host ssh_port ssh_user \
		server_address server_port server_name uuid public_key \
		private_key short_id flow auth_mode bootstrap_private_key; do
		if request_has_key "$key"; then
			return 0
		fi
	done
	return 1
}

# Run the VPS repair pipeline over an established SSH connection. Stages
# the rendered config + meta + repair script into /tmp on the VPS, runs
# the script with REPAIR_REPORT_PATH pointing at a report file, then
# reads the report back and streams it as the "steps" array of the CGI
# response. The report format is defined in install-vps.remote.sh.
run_repair_pipeline() {
	local profile_id="$1"
	local vps_profile install_script_rel install_script_path remote_meta_path
	local rendered meta rendered_install
	local report_local report_remote='/tmp/codex-router-vps-repair.jsonl'
	local raw_log_file

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
	render_server_config "$rendered" "$profile_id"
	render_remote_meta "$meta" "$profile_id"
	render_vps_profile_template "$profile_id" "$install_script_path" "$rendered_install"

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
	local ssh_rc=0
	# Wrap the remote script in `timeout 90` so a hanging step on the
	# VPS never leaves this CGI (and its fcgiwrap worker) blocked
	# indefinitely. 90 seconds is comfortably longer than the pipeline
	# itself needs but short enough that the browser still gets an
	# answer before nginx's 300s fastcgi_read_timeout hits.
	# The script runs under set -e, so a non-zero ssh_cmd exit would kill
	# the whole CGI silently before we get to record it. Guard with an
	# if-block so a failed repair pipeline surfaces as a proper report
	# rather than a truncated response with no body.
	#
	# Resilience (DIAGNOSTIC-TREE 3.4): the pipeline is the longest single
	# SSH op and lands after three uploads, so on a rate-limited repeater
	# uplink it is the most likely to hit a transient "Operation timed
	# out". A bare failure here would report a whole broken pipeline when
	# the VPS is actually fine. Retry the execute step up to 2 times, but
	# ONLY when the report file came back empty (a transport failure) —
	# never when the remote script actually ran and produced a report
	# (that exit code is real repair data, not a transport fault).
	# The remote command reads the staged tar from stdin, extracts the
	# three files to /tmp, then runs the repair pipeline and cats the
	# report. All in one SSH session fed by the bundle tar.
	local exec_cmd exec_try=0
	exec_cmd="cd /tmp && tar -xf - && chmod 755 /tmp/install-vps.remote.sh && rm -f $report_remote; VPS_REMOTE_META_PATH='$remote_meta_path' REPAIR_REPORT_PATH='$report_remote' timeout 90 sh /tmp/install-vps.remote.sh >/dev/null 2>&1; ec=\$?; cat $report_remote 2>/dev/null; exit \$ec"
	while [ "$exec_try" -lt 3 ]; do
		if ssh_stdin_cmd "$profile_id" "$exec_cmd" "$bundle_tar" > "$report_local"; then
			ssh_rc=0
		else
			ssh_rc=$?
		fi
		# If we got a non-empty report back, the remote script ran — done,
		# regardless of ssh_rc (that is the real repair verdict).
		if [ -s "$report_local" ]; then
			break
		fi
		exec_try=$((exec_try + 1))
		if [ "$exec_try" -lt 3 ]; then
			log_step "no report yet (likely a transient SSH timeout on the repeater uplink); retrying in 6s"
			sleep 6
		fi
	done
	rm -rf "$stage"; rm -f "$bundle_tar"
	log_step "repair pipeline finished with exit=$ssh_rc"

	# If no report came back after all retries, the remote script never
	# ran (SSH could not be established, or the tar extraction failed on
	# the VPS) — a transport/reach failure, not a repair-step failure.
	# Set REPAIR_FATAL so the caller reports a clear "could not reach the
	# VPS" instead of an empty steps list that reads like the repair ran
	# and everything silently failed. The raw log carries the exact SSH
	# error.
	if [ ! -s "$report_local" ]; then
		REPAIR_FATAL='Could not reach the VPS to run the repair after 3 attempts — a transient uplink timeout or the VPS is unreachable. See the raw log for the exact SSH error.'
		REPAIR_REPORT='[]'
		REPAIR_RAW_LOG_PATH="$raw_log_file"
		unset SSH_RAW_LOG_PATH
		rm -f "$rendered" "$meta" "$rendered_install" "$report_local"
		return 1
	fi

	# Fold the JSONL report into a JSON array. Each non-empty line should
	# already be a valid JSON object.
	REPAIR_REPORT='['
	local first=1 line
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		if [ "$first" = '1' ]; then
			first=0
		else
			REPAIR_REPORT="${REPAIR_REPORT},"
		fi
		REPAIR_REPORT="${REPAIR_REPORT}${line}"
	done < "$report_local"
	REPAIR_REPORT="${REPAIR_REPORT}]"

	REPAIR_RAW_LOG_PATH="$raw_log_file"
	unset SSH_RAW_LOG_PATH
	rm -f "$rendered" "$meta" "$rendered_install" "$report_local"
	return "$ssh_rc"
}

# Emit a structured response for the diagnose_repair action. Fields:
#   ok: boolean; false when SSH itself failed or the pipeline could not
#       run at all, true when the pipeline finished (whether some
#       individual steps failed or not — the caller reads status.overall).
#   error / need: present only when we need the operator to supply
#       credentials.
#   steps: JSON array of per-step reports (may be empty on hard errors).
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
	local router_apply="${4:-in_sync}"
	emit_header
	printf '{'
	printf '"ok":'
	json_bool "$ok"
	printf ','
	printf '"action":"diagnose_repair",'
	printf '"steps":%s,' "$report"
	printf '"raw_log":"%s",' "$raw_log"
	printf '"router_apply":"%s",' "$(json_escape "$router_apply")"
	printf '"status":'
	status_json
	printf '}'
}

emit_repair_credentials_required() {
	local reason="$1"
	local raw_log="${2:-}"
	emit_header
	printf '{'
	printf '"ok":false,'
	printf '"action":"diagnose_repair",'
	printf '"error":"credentials_required",'
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

	# Single-flight guard: two operators mashing the button — or the
	# same one impatiently re-clicking — must not spawn concurrent
	# repair pipelines. Each holds live SSH sessions and shovels config
	# writes at the VPS; overlapping them accumulates fcgiwrap workers
	# and can lock the router until reboot. flock exits non-zero when
	# it cannot acquire the lock, in which case we return a fast, safe
	# response instead of piling on top.
	local lockfile='/tmp/xray-vps-locks/diagnose_repair.flock'
	mkdir -p "$(dirname "$lockfile")"
	exec 9>"$lockfile"
	if ! flock -n 9; then
		emit_header
		printf '{'
		printf '"ok":false,'
		printf '"action":"diagnose_repair",'
		printf '"error":"busy",'
		printf '"reason":"A repair run is already in progress. Wait for it to finish before starting another.",'
		printf '"raw_log":"",'
		printf '"steps":[]'
		printf '}'
		return 0
	fi

	local profile_id save_err

	# The UI sends the full profile form when the user has changed any of
	# the identity/routing fields. When no such fields are in the request
	# we skip save_profile_from_request entirely, otherwise that helper
	# would allocate a fresh profile (label defaults to "profile") and
	# tear down the currently-selected one. This keeps direct calls from
	# curl / operator tooling well-behaved.
	if request_has_profile_edit; then
		if ! save_profile_from_request >/dev/null; then
			save_err="${SAVE_PROFILE_ERROR:-Could not persist profile settings before repair.}"
			emit_header
			printf '{'
			printf '"ok":false,'
			printf '"action":"diagnose_repair",'
			printf '"error":"save_profile_failed",'
			printf '"reason":"%s",' "$(json_escape "$save_err")"
			printf '"steps":[]'
			printf '}'
			return 0
		fi
		profile_id="$SAVE_PROFILE_ID"
	else
		profile_id="$(active_profile_id)"
		if [ -z "$profile_id" ]; then
			emit_header
			printf '{'
			printf '"ok":false,'
			printf '"action":"diagnose_repair",'
			printf '"error":"no_active_profile",'
			printf '"reason":"No active VPS profile is selected. Create one first.",'
			printf '"steps":[]'
			printf '}'
			return 0
		fi
	fi

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

	local repair_rc=0
	run_repair_pipeline "$profile_id"
	repair_rc=$?

	# Append the pipeline log to the combined log.
	if [ -n "${REPAIR_RAW_LOG_PATH:-}" ] && [ -f "$REPAIR_RAW_LOG_PATH" ]; then
		cat "$REPAIR_RAW_LOG_PATH" >> "$combined_raw_log" 2>/dev/null || true
		rm -f "$REPAIR_RAW_LOG_PATH"
	fi

	local raw_payload
	raw_payload="$(raw_log_payload "$combined_raw_log")"
	rm -f "$combined_raw_log"

	if [ -n "${REPAIR_FATAL:-}" ] && [ "${REPAIR_REPORT:-[]}" = '[]' ]; then
		emit_header
		printf '{'
		printf '"ok":false,'
		printf '"action":"diagnose_repair",'
		printf '"error":"pipeline_setup_failed",'
		printf '"reason":"%s",' "$(json_escape "$REPAIR_FATAL")"
		printf '"raw_log":"%s",' "$raw_payload"
		printf '"steps":[]'
		printf '}'
		return 0
	fi

	# Refresh our local cache view of the VPS so status polls after this
	# call reflect what actually runs on the VPS. Read-only side effect
	# only, does not touch the router runtime.
	refresh_remote_cache "$profile_id" >/dev/null 2>&1 || true

	# DIAGNOSTIC-TREE 8.1: profile empty, VPS authoritative — adopt the
	# live VPS identity into the profile. UCI-only, risk class `safe`, so
	# it may run synchronously. Only when the profile has no public_key of
	# its own; an operator-authored profile is never overwritten (8.4).
	if [ "$repair_rc" -eq 0 ] && [ -z "$(profile_get "$profile_id" public_key)" ]; then
		adopt_remote_into_profile "$profile_id" >/dev/null 2>&1 || true
	fi

	# DIAGNOSTIC-TREE 8.2 / meta-rule 5: diagnose_repair repairs the VPS.
	# It MUST NOT touch the router's live client config. An earlier build
	# auto-scheduled a router apply whenever the profile differed from the
	# router — which rendered a config from an incomplete profile (empty
	# server_name) and left the router dialing the VPS with an empty TLS
	# serverName, so the cert validated against the IP and every tunnel
	# dial failed (x509 "doesn't contain any IP SANs", 2026-07-09). The
	# router's working config is never overwritten as a side effect of a
	# VPS repair. We only *report* drift so the operator can decide; the
	# apply is a separate, explicit action. router_apply is always
	# 'not_touched' here.
	local router_apply='not_touched'
	if [ "$repair_rc" -eq 0 ] && [ -n "$(profile_diff_fields "$profile_id" router)" ]; then
		router_apply='drift_detected'
	fi

	if [ "$repair_rc" -eq 0 ]; then
		emit_repair_response 1 "$REPAIR_REPORT" "$raw_payload" "$router_apply"
	else
		emit_repair_response 0 "$REPAIR_REPORT" "$raw_payload" "$router_apply"
	fi
	return 0
}
