#!/bin/sh
# xray-vps-setup.sh — VPS setup + apply-everything + router-apply job
# Deployed to /usr/share/vpn-xray/xray-vps-setup.sh
# Sourced by /www/cgi-bin/xray-vps after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

setup_vps_internal() {
	local profile_id="$1"
	local rendered meta rendered_install vps_profile install_script_rel install_script_path remote_meta_path

	if ! ensure_ssh_ready "$profile_id"; then
		return 1
	fi
	prepare_profile_from_vps "$profile_id" || return 1
	[ -n "$(profile_get "$profile_id" private_key)" ] || return 1

	vps_profile="$(selected_vps_profile "$profile_id")"
	install_script_rel="$(vps_profile_value "$vps_profile" VPS_INSTALL_SCRIPT)"
	install_script_path="$(vps_profile_file_path "$vps_profile" "$install_script_rel")"
	remote_meta_path="$(vps_profile_value "$vps_profile" VPS_REMOTE_META_PATH)"
	[ -f "$install_script_path" ] || return 1
	[ -n "$remote_meta_path" ] || remote_meta_path='/usr/local/etc/xray/codex-router-meta.env'

	rendered='/tmp/codex-router-vps-config.json'
	meta='/tmp/codex-router-vps-meta.env'
	rendered_install='/tmp/codex-router-install.remote.sh'
	render_server_config "$rendered" "$profile_id"
	render_remote_meta "$meta" "$profile_id"
	render_vps_profile_template "$profile_id" "$install_script_path" "$rendered_install"

	ssh_stdin_cmd "$profile_id" 'cat > /tmp/codex-router-vps-config.json' "$rendered" >/dev/null 2>&1 || {
		rm -f "$rendered" "$meta" "$rendered_install"
		return 1
	}
	ssh_stdin_cmd "$profile_id" 'cat > /tmp/codex-router-meta.env' "$meta" >/dev/null 2>&1 || {
		rm -f "$rendered" "$meta" "$rendered_install"
		return 1
	}
	ssh_stdin_cmd "$profile_id" 'cat > /tmp/install-vps.remote.sh && chmod 755 /tmp/install-vps.remote.sh' "$rendered_install" >/dev/null 2>&1 || {
		rm -f "$rendered" "$meta" "$rendered_install"
		return 1
	}

	if ! ssh_cmd "$profile_id" 'test -x /usr/local/bin/xray' >/dev/null 2>&1; then
		local vps_arch bundled_xray vps_pkg_dir
		vps_arch="$(ssh_cmd "$profile_id" 'uname -m' 2>/dev/null || true)"
		vps_pkg_dir="/usr/share/vpn-xray/vps/${vps_profile}/packages"
		bundled_xray=''
		case "$vps_arch" in
			x86_64|amd64)  bundled_xray="${vps_pkg_dir}/Xray-linux-64.zip" ;;
			aarch64|arm64) bundled_xray="${vps_pkg_dir}/Xray-linux-arm64-v8a.zip" ;;
		esac
		if [ -n "$bundled_xray" ] && [ -f "$bundled_xray" ]; then
			ssh_stdin_cmd "$profile_id" 'cat > /tmp/xray-bundled.zip' "$bundled_xray" >/dev/null 2>&1 || true
		fi
	fi

	ssh_cmd "$profile_id" "VPS_REMOTE_META_PATH='$remote_meta_path' sh /tmp/install-vps.remote.sh" >/dev/null 2>&1 || {
		rm -f "$rendered" "$meta" "$rendered_install"
		return 1
	}

	rm -f "$rendered" "$meta" "$rendered_install"
	refresh_remote_cache "$profile_id" >/dev/null 2>&1 || true
	return 0
}

setup_vps_action() {
	local profile_id

	profile_id="$(active_profile_id)"
	setup_vps_internal "$profile_id" || {
		emit_error setup_vps 'Failed to install or sync VPS Xray config.'
		return 0
	}

	emit_status_response setup_vps
}

apply_everything_action() {
	local profile_id cache remote_xray_present remote_managed_meta requested_material

	if ! save_profile_from_request >/dev/null; then
		emit_error apply_profile "${SAVE_PROFILE_ERROR:-Router could not initialize profile settings.}"
		return 0
	fi
	profile_id="$SAVE_PROFILE_ID"
	requested_material="$(request_value uuid)$(request_value public_key)$(request_value private_key)$(request_value short_id)"

	if [ -z "$requested_material" ]; then
		if ! inspect_profile_with_retry "$profile_id" 3 1; then
			emit_error apply_profile 'Router could not establish SSH to the selected VPS with the current auth settings.'
			return 0
		fi

		cache="$(profile_cache_path "$profile_id")"
		remote_xray_present="$(cache_get "$cache" REMOTE_XRAY_PRESENT)"
		remote_managed_meta="$(cache_get "$cache" REMOTE_MANAGED_META)"

		if [ "$remote_xray_present" = '1' ] && [ -z "$(profile_get "$profile_id" private_key)" ]; then
			adopt_remote_into_profile "$profile_id"
		elif [ "$remote_xray_present" = '1' ] && [ "$remote_managed_meta" != '1' ]; then
			adopt_remote_into_profile "$profile_id"
			schedule_router_apply_action_for apply_profile "$profile_id"
			return 0
		fi
	fi

	setup_vps_internal "$profile_id" || {
		emit_error apply_profile 'Failed to sync the selected VPS.'
		return 0
	}
	schedule_router_apply_action_for apply_profile "$profile_id"
}

# --- Deferred router-apply job (DIAGNOSTIC-TREE 8.2) ---
# The apply is a hard cutover, so it runs as a detached process, never in
# the request path. State is exposed through a status file the UI polls
# via status_json. Known gap G3: if the job dies mid-cutover the status
# file stays "running" (the router itself recovers via failsafe).

ROUTER_APPLY_STATUS_FILE='/tmp/xray-vps-repair-apply.status'

fetch_profile_tls_cert() {
	local profile_id="$1" destination="$2" vps_profile cert_path server_name
	vps_profile="$(selected_vps_profile "$profile_id")"
	cert_path="$(vps_profile_value "$vps_profile" VPS_TLS_CERT_PATH)"
	server_name="$(profile_get "$profile_id" server_name)"
	case "$cert_path" in
		/*) ;;
		*) return 1 ;;
	esac
	case "$cert_path" in *[!A-Za-z0-9_./-]*) return 1 ;; esac
	ssh_cmd "$profile_id" "cat '$cert_path'" > "$destination" 2>/dev/null || return 1
	[ -s "$destination" ] || return 1
	openssl x509 -in "$destination" -noout -checkhost "$server_name" >/dev/null 2>&1
}

verify_applied_profile_path() {
	local profile_id="$1" expected egress code
	expected="$(cache_get "$(profile_cache_path "$profile_id")" REMOTE_PUBLIC_IP)"
	[ -n "$expected" ] || expected="$(profile_get "$profile_id" server_address)"
	egress="$(curl -4fsS -m 12 --socks5-hostname "127.0.0.1:${ROUTER_SOCKS_PORT}" https://ident.me 2>/dev/null || true)"
	[ -n "$egress" ] || egress="$(curl -4fsS -m 12 --socks5-hostname "127.0.0.1:${ROUTER_SOCKS_PORT}" https://api.ipify.org 2>/dev/null || true)"
	[ -n "$egress" ] && [ "$egress" = "$expected" ] || {
		APPLY_ROUTER_ERROR="new router path egress '${egress:-unavailable}' does not match VPS '$expected'"
		return 1
	}
	code="$(curl -4sS -o /dev/null -w '%{http_code}' -m 15 --socks5-hostname "127.0.0.1:${ROUTER_SOCKS_PORT}" https://chatgpt.com 2>/dev/null || true)"
	[ -n "$code" ] && [ "$code" != '000' ] || {
		APPLY_ROUTER_ERROR='ChatGPT did not respond through the newly applied router path'
		return 1
	}
	APPLY_ROUTER_EGRESS="$egress"
}

rollback_router_profile() {
	local config_backup="$1" cert_backup="$2"
	if [ -n "$config_backup" ] && [ -f "$config_backup" ]; then
		cp "$config_backup" "$ROUTER_CONFIG"
	else
		rm -f "$ROUTER_CONFIG" "$ROUTER_READY_FILE"
	fi
	if [ -n "$cert_backup" ] && [ -f "$cert_backup" ]; then
		cp "$cert_backup" /etc/xray/server.crt
	else
		rm -f /etc/xray/server.crt
	fi
	/etc/init.d/codex-transproxy stop >/dev/null 2>&1 || true
	/etc/init.d/codex-xray stop >/dev/null 2>&1 || true
	resync_runtime_to_switch >/dev/null 2>&1 || true
}

apply_profile_to_router_internal() {
	local profile_id="$1" rendered fetched test_output stamp backup cert_backup
	local sa sn su sp
	APPLY_ROUTER_ERROR=''
	APPLY_ROUTER_EGRESS=''
	ensure_profile_material "$profile_id"
	uci commit "$PROFILE_PACKAGE"
	sa="$(profile_get "$profile_id" server_address)"
	sn="$(profile_get "$profile_id" server_name)"
	su="$(profile_get "$profile_id" uuid)"
	sp="$(profile_get "$profile_id" server_port)"
	if [ -z "$sa" ] || [ -z "$sn" ] || [ -z "$su" ] || [ -z "$sp" ]; then
		APPLY_ROUTER_ERROR="profile is missing required endpoint, SNI, UUID, or port"
		return 2
	fi
	rendered="/tmp/codex-xray.profile.$$.json"
	fetched="/tmp/codex-xray.profile.$$.crt"
	render_router_config "$rendered" "$profile_id"
	test_output="$("$ROUTER_XRAY_BIN" run -test -config "$rendered" 2>&1 || true)"
	printf '%s' "$test_output" | grep -q 'Configuration OK.' || {
		APPLY_ROUTER_ERROR='rendered router config failed xray validation'
		rm -f "$rendered" "$fetched"
		return 1
	}
	if ! fetch_profile_tls_cert "$profile_id" "$fetched"; then
		APPLY_ROUTER_ERROR="could not fetch a TLS certificate for $sn from the selected VPS"
		rm -f "$rendered" "$fetched"
		return 1
	fi
	stamp="$(date +%Y%m%d%H%M%S).$$"
	backup="${ROUTER_CONFIG}.bak.${stamp}"
	cert_backup="/etc/xray/server.crt.bak.${stamp}"
	[ -f "$ROUTER_CONFIG" ] && cp "$ROUTER_CONFIG" "$backup" || backup=''
	[ -f /etc/xray/server.crt ] && cp /etc/xray/server.crt "$cert_backup" || cert_backup=''
	mv "$rendered" "$ROUTER_CONFIG"
	mv "$fetched" /etc/xray/server.crt
	chmod 600 "$ROUTER_CONFIG" /etc/xray/server.crt
	touch "$ROUTER_READY_FILE"
	chmod 600 "$ROUTER_READY_FILE"
	/etc/init.d/codex-transproxy stop >/dev/null 2>&1 || true
	/etc/init.d/codex-xray stop >/dev/null 2>&1 || true
	sleep 1
	if ! resync_runtime_to_switch || ! verify_applied_profile_path "$profile_id"; then
		[ -n "$APPLY_ROUTER_ERROR" ] || APPLY_ROUTER_ERROR='new router runtime did not become healthy'
		rollback_router_profile "$backup" "$cert_backup"
		return 1
	fi
	APPLY_ROUTER_BACKUP="$backup"
	return 0
}

router_apply_job_running() {
	local state pid
	[ -f "$ROUTER_APPLY_STATUS_FILE" ] || return 1
	state="$(sed -n 's/^state=//p' "$ROUTER_APPLY_STATUS_FILE" | sed -n '1p')"
	[ "$state" = 'scheduled' ] && return 0
	[ "$state" = 'running' ] || return 1
	pid="$(sed -n 's/^pid=//p' "$ROUTER_APPLY_STATUS_FILE" | sed -n '1p')"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Spawn a detached copy of this CGI in job mode. start-stop-daemon -b
# double-forks and detaches from the fcgiwrap process group, so the job
# survives the end of the HTTP request that scheduled it.
schedule_router_apply_job() {
	mkdir -p "$LOCK_ROOT"
	with_lock_dir "$LOCK_ROOT/router-apply.lock.d" schedule_router_apply_job_locked "$1"
}

schedule_router_apply_job_locked() {
	local profile_id="$1"

	if router_apply_job_running; then
		return 2
	fi
	{
		printf 'state=scheduled\n'
		printf 'profile=%s\n' "$profile_id"
		printf 'scheduled_at=%s\n' "$(date +%s)"
	} > "$ROUTER_APPLY_STATUS_FILE"
	XRAY_VPS_JOB='apply_router' XRAY_VPS_JOB_PROFILE="$profile_id" \
		start-stop-daemon -S -b -x /www/cgi-bin/xray-vps </dev/null >/dev/null 2>&1 9>&- || {
			printf 'state=failed\nprofile=%s\nmessage=Router could not start the detached apply process.\n' "$profile_id" > "$ROUTER_APPLY_STATUS_FILE"
			return 1
		}
}

schedule_router_apply_action_for() {
	local action="$1" profile_id="$2" rc=0
	schedule_router_apply_job "$profile_id" || rc=$?
	case "$rc" in
		2) emit_error "$action" 'A router profile apply job is already running.'; return 0 ;;
		1) emit_error "$action" 'Router could not start the detached profile apply job.'; return 0 ;;
	esac
	emit_header
	printf '{"ok":true,"action":"%s","job_state":"scheduled","profile_id":"%s"}' \
		"$(json_escape "$action")" "$(json_escape "$profile_id")"
}

schedule_router_apply_action() {
	local profile_id
	profile_id="$(active_profile_id)"
	[ -n "$profile_id" ] || { emit_error apply_router 'No active VPS profile is selected.'; return 0; }
	schedule_router_apply_action_for apply_router "$profile_id"
}

router_apply_status_json() {
	local state profile message pid
	state="$(sed -n 's/^state=//p' "$ROUTER_APPLY_STATUS_FILE" 2>/dev/null | sed -n '1p')"
	profile="$(sed -n 's/^profile=//p' "$ROUTER_APPLY_STATUS_FILE" 2>/dev/null | sed -n '1p')"
	message="$(sed -n 's/^message=//p' "$ROUTER_APPLY_STATUS_FILE" 2>/dev/null | sed -n '1p')"
	pid="$(sed -n 's/^pid=//p' "$ROUTER_APPLY_STATUS_FILE" 2>/dev/null | sed -n '1p')"
	if [ "$state" = 'running' ] && { [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; }; then
		state='failed'
		message='Router apply job ended without a final result.'
	fi
	[ -n "$state" ] || state='idle'
	printf '{"state":"%s","profile_id":"%s","message":"%s"}' \
		"$(json_escape "$state")" "$(json_escape "$profile")" "$(json_escape "$message")"
}

router_apply_status_action() {
	emit_header
	printf '{"ok":true,"action":"apply_router_status","job":'
	router_apply_status_json
	printf '}'
}

run_router_apply_job() {
	local profile_id="$1" message
	set +e
	APPLY_ROUTER_ERROR=''
	{
		printf 'state=running\n'
		printf 'profile=%s\n' "$profile_id"
		printf 'pid=%s\n' "$$"
		printf 'started_at=%s\n' "$(date +%s)"
	} > "$ROUTER_APPLY_STATUS_FILE"

	if refresh_remote_cache "$profile_id" >/dev/null 2>&1; then
		adopt_remote_into_profile "$profile_id"
	else
		APPLY_ROUTER_ERROR='could not re-inspect the selected VPS before cutover'
	fi
	if [ -z "${APPLY_ROUTER_ERROR:-}" ] && apply_profile_to_router_internal "$profile_id"; then
		{
			printf 'state=done\n'
			printf 'profile=%s\n' "$profile_id"
			printf 'finished_at=%s\n' "$(date +%s)"
			printf 'message=Router config applied; egress=%s; ChatGPT reachable.\n' "$APPLY_ROUTER_EGRESS"
		} > "$ROUTER_APPLY_STATUS_FILE"
		return 0
	fi
	message="$(printf '%s' "${APPLY_ROUTER_ERROR:-profile apply failed}" | tr '\n=' '  ')"
	{
		printf 'state=failed\n'
		printf 'profile=%s\n' "$profile_id"
		printf 'finished_at=%s\n' "$(date +%s)"
		printf 'message=Router apply failed and previous config was restored: %s\n' "$message"
	} > "$ROUTER_APPLY_STATUS_FILE"
	return 1
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
	[ "$state" = 'scheduled' ] && return 0
	[ "$state" = 'running' ] || return 1
	pid="$(sed -n 's/^pid=//p' "$VPS_REPAIR_JOB_DIR/$job_id/status" 2>/dev/null | sed -n '1p')"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

schedule_vps_repair_job_action() {
	mkdir -p "$VPS_REPAIR_JOB_DIR"
	with_lock_dir "$VPS_REPAIR_JOB_DIR/schedule.lock.d" schedule_vps_repair_job_locked
}

schedule_vps_repair_job_locked() {
	local job_id job_dir
	chmod 700 "$VPS_REPAIR_JOB_DIR"
	if repair_job_running; then
		emit_error diagnose_repair 'A VPS check/configure job is already running.'
		return 0
	fi
	job_id="$(date +%s)-$$"
	job_dir="$VPS_REPAIR_JOB_DIR/$job_id"
	mkdir -p "$job_dir"
	chmod 700 "$job_dir"
	(umask 077; printf '%s' "$REQUEST_DATA" > "$job_dir/request")
	{
		printf 'state=scheduled\n'
		printf 'scheduled_at=%s\n' "$(date +%s)"
	} > "$job_dir/status"
	printf '%s\n' "$job_id" > "$VPS_REPAIR_JOB_DIR/active"
	if ! XRAY_VPS_JOB='diagnose_repair' XRAY_VPS_JOB_ID="$job_id" \
		start-stop-daemon -S -b -x /www/cgi-bin/xray-vps </dev/null >/dev/null 2>&1 9>&-; then
		rm -rf "$job_dir"
		emit_error diagnose_repair 'Router could not start the detached VPS job.'
		return 0
	fi
	emit_header
	printf '{"ok":true,"action":"diagnose_repair","job_state":"scheduled","job_id":"%s"}' "$(json_escape "$job_id")"
}

run_vps_repair_job() {
	local job_id="$1" job_dir raw body rc=0
	repair_job_valid_id "$job_id" || return 2
	job_dir="$VPS_REPAIR_JOB_DIR/$job_id"
	raw="$job_dir/response.raw"
	body="$job_dir/result.tmp"
	[ -f "$job_dir/request" ] || return 2
	REQUEST_DATA="$(cat "$job_dir/request")"
	rm -f "$job_dir/request"
	{
		printf 'state=running\n'
		printf 'pid=%s\n' "$$"
		printf 'started_at=%s\n' "$(date +%s)"
	} > "$job_dir/status"
	set +e
	diagnose_repair_action > "$raw" 2>&1 || rc=$?
	tr -d '\r' < "$raw" | sed '1,/^$/d' > "$body"
	if ! grep -q '^{' "$body"; then
		printf '{"ok":false,"action":"diagnose_repair","error":"job_failed","reason":"Detached VPS job returned no valid response.","steps":[]}' > "$body"
	fi
	chmod 600 "$body"
	mv "$body" "$job_dir/result"
	rm -f "$raw"
	{
		printf 'state=done\n'
		printf 'finished_at=%s\n' "$(date +%s)"
		printf 'exit_code=%s\n' "$rc"
	} > "$job_dir/status"
	return "$rc"
}

vps_repair_job_status_action() {
	local job_id job_dir state pid
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
	if [ "$state" = 'scheduled' ] || { [ "$state" = 'running' ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }; then
		emit_header
		printf '{"ok":true,"action":"diagnose_repair_status","job_state":"%s","job_id":"%s"}' "$(json_escape "$state")" "$(json_escape "$job_id")"
		return 0
	fi
	emit_error diagnose_repair_status 'The detached VPS job ended without a result.'
}
