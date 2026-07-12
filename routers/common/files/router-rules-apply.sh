#!/bin/sh
# router-rules-apply.sh — extracted from router-rules (AGENTS.md 500-line
# rule). Deployed to /usr/share/vpn-xray/. Sourced by /usr/bin/router-rules
# after lib-common.sh, before the LIB_ONLY guard. Functions only; runs no code.

apply_xray_internal() {
	local mode count setname signature resolved_sig need_restart last_mode final_rule conf lan_if

	mode="$(xray_mode)"
	if path_requested && xray_failsafe_hold_active; then
		xray_failsafe_enable "recovery hold active: $(xray_failsafe_state_value reason "$VX_FAILSAFE_HOLD")"
		set_status_error 'Xray recovery is on fail-safe hold; use manual recovery to retry immediately'
		return 1
	fi
	if [ "$mode" = 'selective' ] && ! recover_empty_manual_rules_internal "apply-xray-${mode}"; then
		xray_failsafe_enable "selective rules file is empty and recovery failed"
		set_status_error "selective rules file is empty and no non-empty origin/backup snapshot is available"
		return 1
	fi
	setname="$(xray_ipset)"
	conf="$(xray_dnsmasq_conf)"
	lan_if="$(lan_device)"
	ensure_ipv4_only_dns_internal
	last_mode="$(status_get last_apply_xray_mode)"
	split_rules_internal
	build_xray_dnsmasq_server_conf_internal
	if [ "$mode" = 'selective' ]; then
		build_xray_ipset_internal
	else
		clear_xray_dnsmasq_internal
		ipset create "$setname" hash:net family inet maxelem 65536 -exist
		ipset flush "$setname"
		status_set xray_ipset_count '0'
	fi

	need_restart=0
	[ "${ROUTER_RULES_FORCE_RESTART:-0}" = '1' ] && need_restart=1
	[ "$last_mode" = "$mode" ] || need_restart=1
	final_rule="$(iptables -t nat -S CODEX_TRANSPROXY 2>/dev/null | tail -n 1)"
	if [ "$mode" = 'selective' ]; then
		xray_dnsmasq_ready_internal || need_restart=1
		ipset list "$setname" >/dev/null 2>&1 || need_restart=1
		printf '%s\n' "$final_rule" | grep -q -- "-m set --match-set ${setname} dst -j REDIRECT" || need_restart=1
		iptables -t nat -C PREROUTING -i "$lan_if" -p udp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || need_restart=1
		iptables -t nat -C PREROUTING -i "$lan_if" -p tcp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || need_restart=1
	else
		[ ! -e "$conf" ] || need_restart=1
		printf '%s\n' "$final_rule" | grep -q -- "-p tcp -j REDIRECT --to-ports 12345" || need_restart=1
		iptables -t nat -C PREROUTING -i "$lan_if" -p udp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || need_restart=1
		iptables -t nat -C PREROUTING -i "$lan_if" -p tcp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || need_restart=1
		iptables -t mangle -C PREROUTING -i "$lan_if" -p udp -j CODEX_TPROXY >/dev/null 2>&1 || need_restart=1
		iptables -t mangle -S CODEX_TPROXY 2>/dev/null | grep -q -- "-p udp -j TPROXY" || need_restart=1
	fi
	if [ "$need_restart" = '1' ]; then
		if [ "${ROUTER_RULES_FORCE_XRAY_RESTART:-0}" = '1' ]; then
			/etc/init.d/codex-xray restart 9>&- >/dev/null 2>&1 || true
		fi
		ROUTER_RULES_SKIP_BUILD_IPSET=1 /etc/init.d/codex-transproxy restart 9>&- >/dev/null 2>&1 || true
	fi
	if path_requested; then
		if ! xray_runtime_healthy || ! transproxy_runtime_healthy; then
			xray_failsafe_enable "apply-xray did not converge to an active Xray path"
			set_status_error 'Xray runtime did not converge; client internet is blocked by fail-safe'
			return 1
		fi
		xray_failsafe_disable
	fi
	count="$(status_get xray_ipset_count)"
	set_apply_status xray "mode=${mode} applied ${count} targets"
	signature="$(xray_state_signature)"
	if [ "$mode" = 'selective' ]; then
		resolved_sig="$(resolved_state_signature)"
	else
		resolved_sig=''
	fi
	status_set last_apply_xray_signature "$signature"
	status_set last_apply_xray_mode "$mode"
	status_set last_apply_resolved_signature "$resolved_sig"
	save_last_known_good
}

hard_cutover_xray_internal() {
	local signature mode subnet conntrack_flushed fast_resolve restart_xray

	fast_resolve="${ROUTER_RULES_FAST_RESOLVE:-0}"
	if [ "$fast_resolve" = '1' ]; then
		set_sync_phase cutover_in_progress 'Fast-applying local rules with cached DNS and resolving only new domains'
		restart_xray=0
		if path_requested && ! xray_runtime_healthy; then
			restart_xray=1
		fi
		if [ "$restart_xray" = '1' ]; then
			ROUTER_RULES_FORCE_RESTART=1 ROUTER_RULES_FORCE_XRAY_RESTART=1 ROUTER_RULES_REUSE_RESOLVED_CACHE=1 ROUTER_RULES_SKIP_EFFECTIVE_COLLAPSE=1 ROUTER_RULES_INCREMENTAL_IPSET=1 apply_xray_internal
		else
			ROUTER_RULES_FORCE_RESTART=1 ROUTER_RULES_REUSE_RESOLVED_CACHE=1 ROUTER_RULES_SKIP_EFFECTIVE_COLLAPSE=1 ROUTER_RULES_INCREMENTAL_IPSET=1 apply_xray_internal
		fi
		status_set last_fast_resolve_at "$(date +%s)"
	else
		set_sync_phase cutover_in_progress 'Resetting transparent path and clearing live sessions for the current ruleset'
		ROUTER_RULES_FORCE_RESTART=1 ROUTER_RULES_FORCE_XRAY_RESTART=1 apply_xray_internal
	fi
	subnet="$(lan_ipv4_cidr)"
	conntrack_flushed=0
	if [ -n "$subnet" ] && command -v conntrack >/dev/null 2>&1; then
		conntrack -D -f ipv4 -p tcp -s "$subnet" >/dev/null 2>&1 || true
		conntrack -D -f ipv4 -p udp -s "$subnet" >/dev/null 2>&1 || true
		conntrack_flushed=1
	fi
	if [ "$fast_resolve" = '1' ]; then
		signature="$(ROUTER_RULES_SKIP_EFFECTIVE_COLLAPSE=1 xray_state_signature)"
	else
		signature="$(xray_state_signature)"
	fi
	mode="$(xray_mode)"
	status_set last_cutover_at "$(date +%s)"
	status_set last_cutover_status 'ok'
	status_set last_cutover_message "hard cutover applied mode=${mode} conntrack_flushed=${conntrack_flushed}"
	status_set last_cutover_signature "$signature"
	status_set last_cutover_mode "$mode"
	status_set last_verified_at "$(date +%s)"
	if [ "$fast_resolve" = '1' ]; then
		set_sync_phase verified "Current ruleset is active after fast local cutover (mode=${mode}, conntrack_flushed=${conntrack_flushed})"
	else
		set_sync_phase verified "Current ruleset is active after hard cutover (mode=${mode}, conntrack_flushed=${conntrack_flushed})"
	fi
}

refresh_resolved_runtime_internal() {
	local mode

	mode="$(xray_mode)"
	set_sync_phase drift_detected 'Resolved domain targets changed for selective routing; refreshing runtime targets'
	apply_xray_internal
	status_set last_verified_at "$(date +%s)"
	set_sync_phase verified "Resolved selective targets refreshed without hard cutover (mode=${mode})"
}

xray_needs_apply_for_mode_internal() {
	case "${1:-$(sync_mode)}" in
		apply|push)
			ROUTER_RULES_SKIP_EFFECTIVE_COLLAPSE=1 xray_needs_apply_internal
			;;
		*)
			xray_needs_apply_internal
			;;
	esac
}

sync_apply_xray_internal() {
	local mode local_first_applied

	mode="$(sync_mode)"
	local_first_applied=0
	if [ "$mode" = 'apply' ]; then
		status_set last_sync_changed '0'
		status_set last_sync_strategy 'local-apply'
		status_set last_sync_actor "$(sync_actor)"
		set_status_ok 'Applied the local shared rules without Git pull/push.'
	elif ! repo_configured && [ "$(sync_actor)" = 'background' ]; then
		status_set last_sync_changed '0'
		status_set last_sync_strategy 'local-only'
		status_set last_sync_remote_head ''
		status_set last_sync_actor "$(sync_actor)"
		status_set last_sync_status 'local-only'
		status_set last_sync_message 'Git sync is not configured; background checks stay idle and the local router rules file remains authoritative.'
		status_set last_sync_at "$(date +%s)"
		if resolved_snapshot_needs_apply_internal; then
			refresh_resolved_runtime_internal
		elif xray_needs_apply_internal; then
			set_sync_phase drift_detected 'Found runtime drift against the current ruleset; starting cutover'
			hard_cutover_xray_internal
		else
			status_set last_verified_at "$(date +%s)"
			set_sync_phase verified 'Git sync is disabled; local router rules are authoritative.'
		fi
		return 0
	else
		if [ "$mode" = 'push' ] && [ "$(sync_actor)" != 'background' ] && xray_needs_apply_for_mode_internal "$mode"; then
			set_sync_phase local_apply_in_progress 'Applying local rules before Git push so routing changes take effect immediately'
			ROUTER_RULES_FAST_RESOLVE=1 hard_cutover_xray_internal
			local_first_applied=1
		fi
		set_sync_phase checking_remote 'Checking Git remote and local rules state'
		if ! sync_repo_internal; then
			set_sync_phase git_error 'Git sync failed; applying local rules'
		fi
	fi

	if xray_needs_apply_for_mode_internal "$mode"; then
		set_sync_phase drift_detected 'Found runtime drift against the current ruleset; starting cutover'
		if [ "$mode" = 'apply' ] || [ "$mode" = 'push' ]; then
			ROUTER_RULES_FAST_RESOLVE=1 hard_cutover_xray_internal
		else
			hard_cutover_xray_internal
		fi
	elif resolved_snapshot_needs_apply_internal; then
		refresh_resolved_runtime_internal
	else
		status_set last_verified_at "$(date +%s)"
		if [ "$local_first_applied" = '1' ]; then
			set_sync_phase verified 'Local routing was already applied before Git push; runtime still matches the active ruleset'
		elif [ "$mode" = 'apply' ]; then
			set_sync_phase verified 'Local rules are saved and the active runtime state already matches them'
		else
			set_sync_phase verified 'Everything is already synchronized with Git and active on the router'
		fi
	fi
}

save_sync_apply_xray_internal() {
	local src="$1"

	save_rules_file_internal "$src" || return 1
	sync_apply_xray_internal
}

xray_needs_apply_internal() {
	local mode conf setname final_rule signature last_signature lan_if

	mode="$(xray_mode)"
	conf="$(xray_dnsmasq_conf)"
	setname="$(xray_ipset)"
	lan_if="$(lan_device)"
	signature="$(xray_state_signature)"
	last_signature="$(status_get last_apply_xray_signature)"

	[ "$signature" = "$last_signature" ] || return 0

	if path_requested; then
		xray_failsafe_hold_active && return 1
		xray_failsafe_active && return 0
		xray_runtime_healthy || return 0
		transproxy_runtime_healthy || return 0
	fi

	final_rule="$(iptables -t nat -S CODEX_TRANSPROXY 2>/dev/null | tail -n 1)"
	if [ "$mode" = 'selective' ]; then
		xray_dnsmasq_ready_internal || return 0
		ipset list "$setname" >/dev/null 2>&1 || return 0
		printf '%s\n' "$final_rule" | grep -q -- "-m set --match-set ${setname} dst -j REDIRECT" || return 0
		iptables -t nat -C PREROUTING -i "$lan_if" -p udp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || return 0
		iptables -t nat -C PREROUTING -i "$lan_if" -p tcp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || return 0
	else
		[ ! -e "$conf" ] || return 0
		printf '%s\n' "$final_rule" | grep -q -- "-p tcp -j REDIRECT --to-ports 12345" || return 0
	fi

	return 1
}

resolved_snapshot_needs_apply_internal() {
	local mode current_sig last_sig

	mode="$(xray_mode)"
	[ "$mode" = 'selective' ] || return 1
	current_sig="$(resolved_state_signature)"
	last_sig="$(status_get last_apply_resolved_signature)"
	[ -n "$current_sig" ] || return 1
	[ "$current_sig" = "$last_sig" ] && return 1
	return 0
}

sync_repo_internal() {
	local repo rel tree_rel branch local_snapshot remote_snapshot changed pushed
	local local_head_before remote_head requested_base_head strategy repo_clean last_remote_head requested_push mode
	local git_error_log error_line pre_reset

	if ! repo_configured; then
		ensure_dirs
		mkdir -p "$(dirname "$(repo_rules_path)")" "$(repo_rules_tree_path)/external"
		[ -f "$(repo_rules_path)" ] || : > "$(repo_rules_path)"
		status_set last_sync_changed '0'
		status_set last_sync_strategy 'local-only'
		status_set last_sync_remote_head ''
		status_set last_sync_actor "$(sync_actor)"
		status_set last_sync_status 'local-only'
		status_set last_sync_message 'Git sync is not configured; using local router rules only.'
		status_set last_sync_at "$(date +%s)"
		return 0
	fi

	if git_circuit_open; then
		set_status_error 'git circuit breaker is open; skipping sync'
		return 1
	fi

	repo_bootstrap || {
		set_status_error 'git repository bootstrap failed'
		git_record_failure
		rm -rf "$local_snapshot" "$remote_snapshot"
		return 1
	}
	repo="$(repo_path)"
	rel="$(rules_relpath)"
	tree_rel="$(rules_tree_relpath)"
	branch="$(repo_branch)"
	mode="$(sync_mode)"
	requested_push="$(sync_push_requested)"
	local_snapshot="$(rr_mktempd)"
	remote_snapshot="$(rr_mktempd)"
	requested_base_head="${ROUTER_RULES_BASE_HEAD:-}"
	if [ -n "$requested_base_head" ]; then
		requested_base_head="$(git_cmd -C "$repo" rev-parse --verify "${requested_base_head}^{commit}" 2>/dev/null || printf '%s' "$requested_base_head")"
	fi
	git_error_log="$(rr_mktemp)"

	snapshot_rules_tree_from_worktree_internal "$repo" "$local_snapshot"
	local_head_before="$(git_cmd -C "$repo" rev-parse --verify HEAD 2>/dev/null || true)"
	if ! git_cmd -C "$repo" fetch origin "$branch" >/dev/null 2>"$git_error_log"; then
		error_line="$(sed '/^[[:space:]]*$/d' "$git_error_log" | sed -n '1p')"
		[ -n "$error_line" ] || error_line='git fetch failed'
		echo "$error_line" >&2
		cat "$git_error_log" >&2
		set_status_error "$error_line"
		git_record_failure
		rm -rf "$local_snapshot" "$remote_snapshot"
		rm -f "$git_error_log"
		return 1
	fi

	remote_head="$(git_cmd -C "$repo" rev-parse --verify "origin/$branch" 2>/dev/null || true)"
	repo_clean=1
	git_cmd -C "$repo" diff --quiet -- "$tree_rel" 2>/dev/null || repo_clean=0
	last_remote_head="$(status_get last_sync_remote_head)"
	if [ "$requested_push" != '1' ] \
		&& [ "$repo_clean" = '1' ] \
		&& [ -n "$local_head_before" ] \
		&& [ "$local_head_before" != "$remote_head" ] \
		&& [ -n "$last_remote_head" ] \
			&& [ "$last_remote_head" = "$remote_head" ]; then
		git_record_success
		set_status_ok 'synced changed=0 pushed=0 strategy=local-ahead'
		status_set last_sync_changed '0'
		status_set last_sync_strategy 'local-ahead'
		status_set last_sync_remote_head "$remote_head"
		rm -rf "$local_snapshot" "$remote_snapshot"
		rm -f "$git_error_log"
		return 0
	fi
	if ! snapshot_rules_tree_from_ref_internal "$repo" "origin/$branch" "$remote_snapshot"; then
		set_status_error "Remote rules file not found in origin/$branch: $rel"
		rm -rf "$local_snapshot" "$remote_snapshot"
		rm -f "$git_error_log"
		return 1
	fi

	pre_reset='/etc/router-rules/pre-reset-snapshot'
	strategy='remote'
	if rules_tree_matches_internal "$local_snapshot" "$remote_snapshot"; then
		:
	elif [ -n "$requested_base_head" ] && [ "$requested_base_head" = "$remote_head" ]; then
		strategy='exact-local'
	elif [ -z "$requested_base_head" ] && [ -n "$local_head_before" ] && [ "$local_head_before" = "$remote_head" ]; then
		strategy='exact-local'
	else
		strategy='merge-preserve-both'
	fi

	if [ "$strategy" = 'exact-local' ]; then
		rm -rf "$pre_reset"
		cp -R "$local_snapshot" "$pre_reset"
	elif [ "$strategy" = 'merge-preserve-both' ]; then
		rm -rf "$pre_reset"
		mkdir -p "$pre_reset"
		merge_rules_tree_for_mode_internal "$mode" "$remote_snapshot" "$local_snapshot" "$pre_reset"
	fi

	git_cmd -C "$repo" reset --hard "origin/$branch" >/dev/null 2>&1

	if [ -d "$pre_reset" ]; then
		restore_rules_tree_exact_local_internal "$pre_reset" "$repo"
		rm -rf "$pre_reset"
	fi

	# Keep the editable rules file free of entries already materialized into
	# managed external source files, even after remote-preferred merges.
	maybe_migrate_external_repo_layout_internal >/dev/null

	changed=0
	if ! git_cmd -C "$repo" diff --quiet -- "$tree_rel"; then
		changed=1
		git_cmd -C "$repo" add "$tree_rel"
		git_cmd -C "$repo" commit -m "Sync shared targets from $(device_id)" >/dev/null 2>&1 || true
	fi

	pushed=0
	if [ "$changed" = '1' ] && [ "$requested_push" = '1' ]; then
		if ! repo_push_configured; then
			set_status_error 'git push requested but RULES_REPO_PUSH_URL is not configured'
			rm -rf "$local_snapshot" "$remote_snapshot"
			rm -f "$git_error_log"
			return 1
		fi
		if git_push_cmd -C "$repo" push origin "$branch" >/dev/null 2>"$git_error_log"; then
			pushed=1
		else
			error_line="$(sed '/^[[:space:]]*$/d' "$git_error_log" | sed -n '1p')"
			[ -n "$error_line" ] || error_line='git push failed'
			echo "$error_line" >&2
			cat "$git_error_log" >&2
			set_status_error "$error_line"
			rm -rf "$local_snapshot" "$remote_snapshot"
			rm -f "$git_error_log"
			return 1
		fi
	fi

	git_record_success
	set_status_ok "synced changed=${changed} pushed=${pushed} strategy=${strategy} mode=${mode}"
	status_set last_sync_changed "$changed"
	status_set last_sync_strategy "$strategy"
	status_set last_sync_remote_head "$remote_head"
	rm -rf "$local_snapshot" "$remote_snapshot"
	rm -f "$git_error_log"
}

save_rules_file_internal() {
	local src="$1"
	local dst

	prepare_rules_file_for_local_edit_internal || return 1
	dst="$(repo_rules_path)"
	guard_manual_rules_write_internal "$src" "$dst" 'save-file' || return 1
	backup_rules_tree_internal 'before-save-file' >/dev/null 2>&1 || true
	cp "$src" "$dst"
}

ensure_git_key_internal() {
	local key pub

	key="$(ssh_key_path)"
	mkdir -p "$(dirname "$key")"
	[ -f "$key" ] || ssh-keygen -t ed25519 -f "$key" -N '' -C "routerRules@$(device_id)" >/dev/null 2>&1
	chmod 600 "$key"
	pub="${key}.pub"
	if [ ! -s "$pub" ]; then
		if ! ssh-keygen -y -f "$key" > "${pub}.tmp" 2>/dev/null; then
			rm -f "${pub}.tmp"
			return 1
		fi
		mv "${pub}.tmp" "$pub"
	fi
	chmod 644 "$pub"
}

set_xray_mode_internal() {
	local mode="$1"
	case "$mode" in
		full|selective)
			uci -q set "${CONFIG_PKG}.${CONFIG_SECTION}.xray_mode=${mode}"
			uci commit "$CONFIG_PKG"
			;;
		*)
			echo "invalid mode: $mode" >&2
			return 1
			;;
	esac
}

set_mode_cutover_internal() {
	local mode="$1"

	set_xray_mode_internal "$mode" || return 1
	# Must be a FULL cutover: switching full->selective has to (re)build the
	# complete selective ipset. The fast path (REUSE_RESOLVED_CACHE +
	# INCREMENTAL_IPSET) only adds diffs and leaves the set incomplete after a
	# mode change, which silently drops listed targets (e.g. 2ip.io) from
	# selective routing. Correctness over speed here.
	hard_cutover_xray_internal
}

