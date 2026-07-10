#!/bin/sh
# xray-vps-setup.sh — VPS setup + apply-everything + router-apply job
# Deployed to /usr/share/vpn-xray/xray-vps-setup.sh
# Sourced by /www/cgi-bin/xray-vps after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

setup_vps_internal() {
	local profile_id="$1"
	local rendered meta rendered_install vps_profile install_script_rel install_script_path remote_meta_path

	if [ -z "$(profile_get "$profile_id" private_key)" ]; then
		return 1
	fi

	if ! ensure_ssh_ready "$profile_id"; then
		return 1
	fi

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
			apply_profile_to_router_internal "$profile_id" >/dev/null || {
				emit_error apply_profile 'VPS was detected and adopted, but applying the router profile failed.'
				return 0
			}
			emit_status_response apply_profile
			return 0
		fi
	fi

	local router_backup=''
	if [ -f "$ROUTER_CONFIG" ]; then
		router_backup="${ROUTER_CONFIG}.rollback.$$"
		cp "$ROUTER_CONFIG" "$router_backup"
	fi

	setup_vps_internal "$profile_id" || {
		rm -f "$router_backup"
		emit_error apply_profile 'Failed to sync the selected VPS.'
		return 0
	}
	if ! apply_profile_to_router_internal "$profile_id" >/dev/null; then
		if [ -n "$router_backup" ] && [ -f "$router_backup" ]; then
			cp "$router_backup" "$ROUTER_CONFIG"
			resync_runtime_to_switch || true
		fi
		rm -f "$router_backup"
		emit_error apply_profile 'VPS was synced, but applying the profile to the router failed. Router config rolled back.'
		return 0
	fi
	rm -f "$router_backup"

	emit_status_response apply_profile
}

# --- Deferred router-apply job (DIAGNOSTIC-TREE 8.2) ---
# The apply is a hard cutover, so it runs as a detached process, never in
# the request path. State is exposed through a status file the UI polls
# via status_json. Known gap G3: if the job dies mid-cutover the status
# file stays "running" (the router itself recovers via failsafe).

ROUTER_APPLY_STATUS_FILE='/tmp/xray-vps-repair-apply.status'

router_apply_job_running() {
	local pid
	[ -f "$ROUTER_APPLY_STATUS_FILE" ] || return 1
	pid="$(sed -n 's/^pid=//p' "$ROUTER_APPLY_STATUS_FILE" | sed -n '1p')"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Spawn a detached copy of this CGI in job mode. start-stop-daemon -b
# double-forks and detaches from the fcgiwrap process group, so the job
# survives the end of the HTTP request that scheduled it.
schedule_router_apply_job() {
	local profile_id="$1"

	if router_apply_job_running; then
		return 0
	fi
	{
		printf 'state=scheduled\n'
		printf 'profile=%s\n' "$profile_id"
		printf 'scheduled_at=%s\n' "$(date +%s)"
	} > "$ROUTER_APPLY_STATUS_FILE"
	XRAY_VPS_JOB='apply_router' XRAY_VPS_JOB_PROFILE="$profile_id" \
		start-stop-daemon -S -b -x /www/cgi-bin/xray-vps 2>/dev/null
}

run_router_apply_job() {
	local profile_id="$1"
	set +e
	{
		printf 'state=running\n'
		printf 'profile=%s\n' "$profile_id"
		printf 'pid=%s\n' "$$"
		printf 'started_at=%s\n' "$(date +%s)"
	} > "$ROUTER_APPLY_STATUS_FILE"

	if apply_profile_to_router_internal "$profile_id" >/dev/null 2>&1; then
		{
			printf 'state=done\n'
			printf 'profile=%s\n' "$profile_id"
			printf 'finished_at=%s\n' "$(date +%s)"
			printf 'message=Router config applied and runtime resynced.\n'
		} > "$ROUTER_APPLY_STATUS_FILE"
		return 0
	fi
	{
		printf 'state=failed\n'
		printf 'profile=%s\n' "$profile_id"
		printf 'finished_at=%s\n' "$(date +%s)"
		printf 'message=Router apply failed; previous config was restored by the apply guard.\n'
	} > "$ROUTER_APPLY_STATUS_FILE"
	return 1
}
