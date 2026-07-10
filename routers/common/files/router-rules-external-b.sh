#!/bin/sh
# router-rules-external-b.sh — extracted from router-rules (AGENTS.md 500-line
# rule). Deployed to /usr/share/vpn-xray/. Sourced by /usr/bin/router-rules
# after lib-common.sh, before the LIB_ONLY guard. Functions only; runs no code.

prepare_rules_file_for_local_edit_internal() {
	ensure_dirs
	if repo_configured; then
		repo_bootstrap || return 1
	else
		mkdir -p "$(repo_path)" "$(dirname "$(repo_rules_path)")" "$(repo_rules_tree_path)/external"
		[ -f "$(repo_rules_path)" ] || : > "$(repo_rules_path)"
	fi
}

prepare_external_source_files_for_update_internal() {
	ensure_dirs
	if repo_configured; then
		repo_bootstrap || return 1
	else
		mkdir -p "$(repo_path)" "$(repo_rules_tree_path)/external"
	fi
}

append_rule_lines_internal() {
	local dst="$1"
	local src="$2"

	[ -s "$src" ] || return 0
	if [ -s "$dst" ]; then
		printf '\n' >> "$dst"
	fi
	cat "$src" >> "$dst"
}

compute_unique_rule_additions_internal() {
	local base_file="$1"
	local candidate_file="$2"
	local out_file="$3"

	awk '
		function trim(s) {
			sub(/\r$/, "", s)
			sub(/^[[:space:]]+/, "", s)
			sub(/[[:space:]]+$/, "", s)
			return s
		}
		FILENAME == ARGV[1] {
			line = trim($0)
			if (line == "" || line ~ /^#/) {
				next
			}
			seen[tolower(line)] = 1
			next
		}
		{
			line = trim($0)
			if (line == "" || line ~ /^#/) {
				next
			}
			norm = tolower(line)
			if (!(norm in seen) && !(norm in emitted)) {
				print line
				emitted[norm] = 1
			}
		}
	' "$base_file" "$candidate_file" > "$out_file"
}

refresh_external_source_internal() {
	local id="$1"
	local generated_file="$2"
	local generated_count="$3"
	local current_file source_file previous_count updated_count added_count removed_count message changed_flag
	local generated_signature stored_signature updated_signature now

	current_file="$(rr_mktemp)"
	source_file="$(external_source_path "$id")"
	mkdir -p "$(dirname "$source_file")"
	[ -f "$source_file" ] || : > "$source_file"

	grep -v '^[[:space:]]*$' "$source_file" > "$current_file" 2>/dev/null || : > "$current_file"
	previous_count="$(rule_count "$current_file")"
	[ -n "$previous_count" ] || previous_count='0'
	stored_signature="$(file_signature "$source_file")"
	generated_signature="$(file_signature "$generated_file")"
	now="$(date +%s)"

	if [ "$generated_count" = '0' ]; then
		set_external_source_status "$id" no_change 'Source returned no targets.' "$generated_count" '0'
		external_source_status_set "$id" last_checked_at "$now"
		external_source_status_set "$id" last_file_signature "$stored_signature"
		external_source_status_set "$id" last_stored_count "$previous_count"
		rm -f "$current_file"
		printf '0|0\n'
		return 0
	fi

	if [ "$stored_signature" = "$generated_signature" ]; then
		set_external_source_status "$id" no_change 'Stored normalized snapshot is already up to date.' "$generated_count" '0'
		external_source_status_set "$id" last_checked_at "$now"
		external_source_status_set "$id" last_file_signature "$stored_signature"
		external_source_status_set "$id" last_stored_count "$previous_count"
		rm -f "$current_file"
		printf '0|0\n'
		return 0
	fi

	cp "$generated_file" "$source_file"
	updated_count="$generated_count"
	changed_flag='1'
	updated_signature="$(file_signature "$source_file")"
	if [ "$updated_count" -gt "$previous_count" ] 2>/dev/null; then
		added_count=$((updated_count - previous_count))
	else
		added_count='0'
	fi
	if [ "$previous_count" -gt "$updated_count" ] 2>/dev/null; then
		removed_count=$((previous_count - updated_count))
	else
		removed_count='0'
	fi
	message="Stored ${updated_count} normalized targets in $(external_source_relpath "$id") (delta +${added_count}/-${removed_count})."
	set_external_source_status "$id" updated "$message" "$generated_count" "$added_count"
	external_source_status_set "$id" last_checked_at "$now"
	external_source_status_set "$id" last_changed_at "$now"
	external_source_status_set "$id" last_file_signature "$updated_signature"
	external_source_status_set "$id" last_stored_count "$updated_count"
	rm -f "$current_file"
	printf '%s|%s\n' "$changed_flag" "$added_count"
}

refresh_external_sources_internal() {
	local source_meta error_file enabled_count total_generated total_added changed_any summary
	local id label url generated_file generated_count message removed_count result changed_flag added_count

	source_meta="$(rr_mktemp)"
	error_file="$(rr_mktemp)"
	enabled_count=0
	total_generated=0
	total_added=0
	changed_any=0
	summary=''

	if [ "$(external_source_refresh_enabled)" != '1' ]; then
		rm -f "$EXTERNAL_SYNC_PID_FILE"
		status_set last_external_pid ''
		set_external_status no_change 'Managed source snapshot refresh is disabled.' '0' '0'
		rm -f "$source_meta" "$error_file"
		return 0
	fi

	while IFS='|' read -r id label url || [ -n "$id" ]; do
		[ -n "$id" ] || continue
		enabled_count=$((enabled_count + 1))
		generated_file="$(rr_mktemp)"
		if ! generate_external_source_internal "$id" > "$generated_file" 2> "$error_file"; then
			message="$(sed '/^[[:space:]]*$/d' "$error_file" | head -5 | tr '\n' '|' | sed 's/|$//;s/|/ | /g')"
			[ -n "$message" ] || message="External source fetch failed for $id."
			set_external_source_status "$id" error "$message" '0' '0'
			status_trace_add sync_trace "external $id skipped: $message"
			rm -f "$generated_file"
			summary="${summary}${summary:+; }${id}: FAILED"
			continue
		fi
		generated_count="$(rule_count "$generated_file")"
		[ -n "$generated_count" ] || generated_count='0'
		printf '%s|%s|%s\n' "$id" "$generated_count" "$generated_file" >> "$source_meta"
	done <<EOF
$(external_source_catalog)
EOF

	if [ "$enabled_count" -eq 0 ]; then
		rm -f "$EXTERNAL_SYNC_PID_FILE"
		status_set last_external_pid ''
		set_external_status no_change 'No managed external source files are enabled.' '0' '0'
		rm -f "$source_meta" "$error_file"
		return 0
	fi

	if ! prepare_external_source_files_for_update_internal 2> "$error_file"; then
		message="$(sed '/^[[:space:]]*$/d' "$error_file" | sed -n '1p')"
		[ -n "$message" ] || message='Could not prepare the managed external source files for updates.'
		rm -f "$EXTERNAL_SYNC_PID_FILE"
		status_set last_external_pid ''
		set_external_status error "$message" '0' '0'
		set_status_error "$message"
		while IFS='|' read -r _ _ stale_file || [ -n "$stale_file" ]; do
			[ -n "$stale_file" ] || continue
			rm -f "$stale_file"
		done < "$source_meta"
		rm -f "$source_meta" "$error_file"
		return 1
	fi

	while IFS='|' read -r id generated_count generated_file || [ -n "$id" ]; do
		[ -n "$id" ] || continue
		total_generated=$((total_generated + generated_count))
		result="$(refresh_external_source_internal "$id" "$generated_file" "$generated_count")"
		changed_flag="${result%%|*}"
		added_count="${result#*|}"
		[ "$added_count" != "$result" ] || changed_flag='0'
		[ -n "$changed_flag" ] || changed_flag='0'
		[ -n "$added_count" ] || added_count='0'
		total_added=$((total_added + added_count))
		if [ "$changed_flag" = '1' ]; then
			changed_any=1
		fi
		summary="${summary}${summary:+; }$(external_source_label "$id"): ${generated_count} normalized targets"
		rm -f "$generated_file"
	done < "$source_meta"

	removed_count="$(maybe_migrate_external_repo_layout_internal)"
	[ -n "$removed_count" ] || removed_count='0'
	if [ "$removed_count" -gt 0 ] 2>/dev/null; then
		changed_any=1
		summary="${summary}${summary:+; }manual migrated -${removed_count}"
	fi

	if [ "$changed_any" = '1' ]; then
		set_external_status updated "$summary" "$total_generated" "$total_added"
	else
		set_external_status no_change "$summary" "$total_generated" "$total_added"
	fi

	rm -f "$EXTERNAL_SYNC_PID_FILE"
	status_set last_external_pid ''
	rm -f "$source_meta" "$error_file"
	printf '%s\n' "$changed_any"
}

sync_external_source_internal() {
	# Phase 1: fetch external sources WITHOUT the global lock.
	# HTTP fetches can take tens of seconds; holding the lock blocks the UI.
	local changed_any
	changed_any="$(refresh_external_sources_internal)" || return 1

	# Phase 2: apply under lock only if something changed.
	if [ "$changed_any" != '0' ]; then
		with_lock sync_apply_xray_internal
	else
		status_set last_verified_at "$(date +%s)"
	fi
}

fast_resolve_refresh_due_internal() {
	# Fast UI applies intentionally skip the expensive full collapse/re-resolve.
	# Do not run that work from background-tick under the global lock; normal
	# sync/external refresh paths will rebuild fully when they actually change
	# the shared rules snapshot.
	return 1
}

background_tick_internal() {
	background_external_refresh_running_internal || true
	if should_refresh_external_source_internal; then
		queue_background_external_refresh_internal || true
	fi
	if git_circuit_open; then
		status_set last_verified_at "$(date +%s)"
		set_sync_phase verified 'Git circuit breaker is open; skipping remote probe'
		return 0
	fi
	quick_remote_probe_internal || true
	# Try to recover from a selective-fallback temporary state on every tick.
	# When the install switched the router to FULL because the rules repo
	# was unreachable, this retry promotes us back to selective the moment
	# the network is healthy again — no manual UI intervention required.
	selective_fallback_retry_internal || true
	status_set last_verified_at "$(date +%s)"
	[ "$(status_get sync_phase)" = 'error' ] || set_sync_phase verified 'Remote probe completed within the loop budget'
}

