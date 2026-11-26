#!/bin/sh
# router-rules-mode.sh — routing-mode state + fast in-place cutover
# (DIAGNOSTIC-TREE 4.9/4.10). Deployed to /usr/share/vpn-xray/.
# Sourced by /usr/bin/router-rules after lib-common.sh, before the LIB_ONLY
# guard. Functions only; runs no code.

# Software OFF owns the whole path: no NAT/mangle/nft redirect, no redsocks,
# no Xray, no SSH tunnel. The selective ipset and DNS snapshot stay warm so
# switching back is a local operation, not a full resolve.
apply_software_off_internal() {
	local signature

	set_sync_phase mode_off 'Disabling transparent redirection; LAN traffic uses the direct WAN'
	/etc/init.d/codex-transproxy stop 9>&- >/dev/null 2>&1 || true
	/etc/init.d/codex-xray stop 9>&- >/dev/null 2>&1 || true
	/etc/init.d/codex-xray-tunnel stop 9>&- >/dev/null 2>&1 || true
	xray_failsafe_hold_clear
	xray_failsafe_disable
	signature="$(xray_state_signature)"
	status_set last_apply_xray_signature "$signature"
	status_set last_apply_xray_mode 'off'
	status_set last_apply_resolved_signature ''
	set_apply_status xray 'mode=off applied 0 targets (redirection disabled)'
	save_last_known_good
}

# Detached, single-flight warm job: resolve the ruleset and apply the result.
# It never blocks the mode switch; the switch already serves the warm snapshot.
schedule_selective_warm_internal() {
	local pidfile='/var/run/router-rules-warm.pid' pid

	pid="$(cat "$pidfile" 2>/dev/null || true)"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
	(
		# Drop the rules-lock FD inherited from the switch. Otherwise this
		# detached job holds the flock while its own build waits for it.
		exec 9>&-
		sleep 2
		ROUTER_RULES_LOCK_WAIT=30 /usr/bin/router-rules build-xray-ipset
		ROUTER_RULES_LOCK_WAIT=30 ROUTER_RULES_USE_CACHED_RESOLVED=1 /usr/bin/router-rules apply-xray
		rm -f "$pidfile"
	) >/dev/null 2>&1 &
	printf '%s\n' "$!" > "$pidfile"
}

# Restore selective data from the last resolved snapshot only. No DNS, no Git:
# the mode switch must stay inside its UI budget. When no snapshot exists yet,
# or it is older than the warm budget, a detached job refreshes it in the
# background while the switch already routes from the warm snapshot.
warm_selective_data_internal() {
	local setname conf resolved count last now stale=0

	setname="$(xray_ipset)"
	conf="$(xray_dnsmasq_conf)"
	resolved="$(resolved_file)"
	if ipset list "$setname" >/dev/null 2>&1 && [ -s "$conf" ]; then
		count="$(ipset list "$setname" 2>/dev/null | sed -n 's/^Number of entries: //p' | sed -n '1p')"
		status_set xray_ipset_count "${count:-0}"
	else
		# Cached build needs an existing resolved snapshot; without one it
		# would fall back to a full DNS resolve and blow the switch budget.
		if [ -s "$resolved" ]; then
			ROUTER_RULES_USE_CACHED_RESOLVED=1 build_xray_ipset_internal || return 1
		else
			schedule_selective_warm_internal
			return 0
		fi
	fi
	last="$(status_get last_full_resolve_at)"
	now="$(date +%s)"
	case "$last" in
		''|*[!0-9]*) stale=1 ;;
		*) [ $((now - last)) -le "${ROUTER_RULES_WARM_MAX_AGE:-900}" ] || stale=1 ;;
	esac
	if [ "$stale" = '1' ]; then
		schedule_selective_warm_internal
	fi
	return 0
}

set_xray_mode_internal() {
	local mode="$1"
	case "$mode" in
		full|selective|off)
			uci -q set "${CONFIG_PKG}.${CONFIG_SECTION}.xray_mode=${mode}"
			uci commit "$CONFIG_PKG"
			;;
		*)
			echo "invalid mode: $mode" >&2
			return 1
			;;
	esac
}

# Dataplane-only mode switch (DIAGNOSTIC-TREE 4.10). No Git, no DNS resolve,
# no Xray/redsocks/dnsmasq restart of healthy daemons: replace the firewall
# rules in place, start missing daemons only when leaving OFF, and keep the
# selective snapshot warm. The heavy full apply stays a separate action.
set_mode_cutover_internal() {
	local mode="$1" started signature resolved_sig warm_note=''

	started="$(date +%s)"
	set_xray_mode_internal "$mode" || return 1
	set_sync_phase cutover_in_progress "Switching routing mode to ${mode} (in-place)"
	if [ "$mode" = 'off' ]; then
		apply_software_off_internal || return 1
	else
		if [ "$mode" = 'selective' ]; then
			warm_selective_data_internal || true
		fi
		# Never let the in-place switch fall back to a synchronous DNS build;
		# a missing set is warmed by the detached job and applied next tick.
		ROUTER_RULES_SKIP_BUILD_IPSET=1 /etc/init.d/codex-transproxy apply_mode 9>&- >/dev/null 2>&1 || {
			set_status_error "transparent path could not switch to ${mode}"
			return 1
		}
		if path_requested; then
			if ! xray_runtime_healthy || ! transproxy_runtime_healthy; then
				xray_failsafe_enable "mode cutover did not converge to an active Xray path"
				set_status_error "Xray runtime did not converge after switching to ${mode}"
				return 1
			fi
			xray_failsafe_disable
		fi
		signature="$(xray_state_signature)"
		if [ "$mode" = 'selective' ]; then
			resolved_sig="$(resolved_state_signature)"
		else
			resolved_sig=''
		fi
		status_set last_apply_xray_signature "$signature"
		status_set last_apply_xray_mode "$mode"
		status_set last_apply_resolved_signature "$resolved_sig"
		set_apply_status xray "mode=${mode} switched in place"
	fi
	# The previous smoke belongs to the previous dataplane. Clear it so the
	# UI does not show a stale "degraded" until the next watchdog smoke.
	status_set last_smoke_at ''
	status_set last_smoke_status ''
	status_set last_smoke_message ''
	status_set last_smoke_http_ok ''
	status_set last_smoke_https_ok ''
	status_set last_smoke_egress_ok ''
	status_set last_smoke_openai_ok ''
	signature="$(xray_state_signature)"
	[ "$mode" = 'selective' ] && [ -f /var/run/router-rules-warm.pid ] && warm_note=' (targets warming in background)'
	status_set last_cutover_at "$(date +%s)"
	status_set last_cutover_status 'ok'
	status_set last_cutover_message "mode cutover applied mode=${mode} duration=$(( $(date +%s) - started ))s${warm_note}"
	status_set last_cutover_signature "$signature"
	status_set last_cutover_mode "$mode"
	status_set last_cutover_duration_ms "$(( ($(date +%s) - started) * 1000 ))"
	status_set last_verified_at "$(date +%s)"
	set_sync_phase verified "Routing mode ${mode} active (in-place switch)${warm_note}"
	return 0
}
