#!/bin/sh
# router-rules-status.sh — extracted from router-rules (AGENTS.md 500-line
# rule). Deployed to /usr/share/vpn-xray/. Sourced by /usr/bin/router-rules
# after lib-common.sh, before the LIB_ONLY guard. Functions only; runs no code.

external_sources_json() {
	local first id label url enabled due path count last_run_at last_status last_message generated_count added_count actor
	local file_signature_value last_checked_at last_changed_at stored_count health has_script max_targets

	first=1
	printf '['
	while IFS='|' read -r id label url || [ -n "$id" ]; do
		[ -n "$id" ] || continue
		enabled="$(external_source_enabled_by_id "$id")"
		due='0'
		external_source_due_by_id "$id" && due='1'
		path="$(external_source_path "$id")"
		count="$(rule_count "$path")"
		last_run_at="$(external_source_status_get "$id" last_run_at)"
		last_status="$(external_source_status_get "$id" last_status)"
		last_message="$(external_source_status_get "$id" last_message)"
		generated_count="$(external_source_status_get "$id" last_generated_count)"
		added_count="$(external_source_status_get "$id" last_added_count)"
		actor="$(external_source_status_get "$id" last_actor)"
		file_signature_value="$(external_source_status_get "$id" last_file_signature)"
		last_checked_at="$(external_source_status_get "$id" last_checked_at)"
		last_changed_at="$(external_source_status_get "$id" last_changed_at)"
		stored_count="$(external_source_status_get "$id" last_stored_count)"
		[ -n "$generated_count" ] || generated_count='0'
		[ -n "$added_count" ] || added_count='0'
		[ -n "$stored_count" ] || stored_count="$count"
		[ -n "$file_signature_value" ] || file_signature_value="$(file_signature "$path")"
		health='unknown'
		case "$last_status" in
			updated|no_change) health='ok' ;;
			error) health='error' ;;
		esac
		has_script=0
		[ -f "$(scripts_dir)/${id}.json" ] && has_script=1
		max_targets="$(external_source_max_targets "$id")"
		[ "$first" = '1' ] || printf ','
		first=0
		printf '{'
		printf '"id":"%s",' "$(json_escape "$id")"
		printf '"label":"%s",' "$(json_escape "$label")"
		printf '"url":"%s",' "$(json_escape "$url")"
		printf '"enabled":'; json_bool "$enabled"; printf ','
		printf '"due":'; json_bool "$due"; printf ','
		printf '"health":"%s",' "$(json_escape "$health")"
		printf '"has_script":'; json_bool "$has_script"; printf ','
		printf '"max_targets":"%s",' "$(json_escape "$max_targets")"
		printf '"file_relpath":"%s",' "$(json_escape "$(external_source_relpath "$id")")"
		printf '"file_present":'; if [ -f "$path" ]; then json_bool 1; else json_bool 0; fi; printf ','
		printf '"file_count":"%s",' "$(json_escape "$count")"
		printf '"last_run_at":"%s",' "$(json_escape "$last_run_at")"
		printf '"last_status":"%s",' "$(json_escape "$last_status")"
		printf '"last_message":"%s",' "$(json_escape "$last_message")"
		printf '"last_generated_count":"%s",' "$(json_escape "$generated_count")"
		printf '"last_added_count":"%s",' "$(json_escape "$added_count")"
		printf '"last_actor":"%s",' "$(json_escape "$actor")"
		printf '"file_signature":"%s",' "$(json_escape "$file_signature_value")"
		printf '"last_checked_at":"%s",' "$(json_escape "$last_checked_at")"
		printf '"last_changed_at":"%s",' "$(json_escape "$last_changed_at")"
		printf '"stored_count":"%s"' "$(json_escape "$stored_count")"
		printf '}'
	done <<EOF
$(external_source_catalog)
EOF
	printf ']'
}

status_json() {
	local repo rel tree_rel rules_file resolved map domains literals file_text profile_status repo_head repo_dirty mode
	local source_count effective_source_count managed_source_count managed_applied_source_count resolved_count domain_count literal_count xray_ipset_count last_sync_at last_sync_status last_sync_message last_apply_xray
	local setname current_signature last_cutover_at last_cutover_status last_cutover_message last_cutover_signature cutover_required
	local sync_phase sync_phase_at sync_phase_message sync_trace last_verified_at last_sync_actor last_sync_strategy rules_checksum last_apply_signature interval
	local fetch_url push_url_raw push_url_effective auth_mode http_username http_password_set ssh_key_present ssh_pub git_configured sync_enabled git_readonly
	local git_push_status_payload git_push_status git_push_message git_push_next_step git_push_effective_auth git_push_ready
	local external_enabled external_interval external_due last_external_run_at last_external_status last_external_message last_external_generated_count last_external_added_count last_external_actor
	local rules_text_included id label url path count external_sources_payload remote_ref browser_rules_url
	local last_remote_probe_at last_remote_probe_status last_remote_probe_message last_remote_probe_head last_remote_probe_update_available
	local ui_job_id ui_job_kind ui_job_state ui_job_message ui_job_started_at ui_job_finished_at ui_job_target_mode ui_job_suggestion
	local ui_job_console_path ui_job_console_output

	repo="$(repo_path)"
	rel="$(rules_relpath)"
	tree_rel="$(rules_tree_relpath)"
	rules_file="$(repo_rules_path)"
	resolved="$(resolved_file)"
	map="$(mapping_file)"
	domains="$(domain_file)"
	literals="$(literal_file)"
	mode="$(xray_mode)"
	file_text=''
	rules_text_included='0'
	if status_include_rules_text; then
		rules_text_included='1'
		[ -f "$rules_file" ] && file_text="$(cat "$rules_file")"
	fi
	interval="$(sync_interval)"
	external_enabled="$(external_source_enabled)"
	external_interval="$(external_source_interval_seconds)"
	fetch_url="$(repo_fetch_url)"
	push_url_raw="$(repo_push_url_raw)"
	push_url_effective="$(repo_push_url)"
	remote_ref="$(remote_rules_ref)"
	browser_rules_url="$(repo_browser_rules_url || true)"
	is_placeholder_value "$fetch_url" && fetch_url=''
	is_placeholder_value "$push_url_raw" && push_url_raw=''
	is_placeholder_value "$push_url_effective" && push_url_effective=''
	sync_enabled="$(git_sync_enabled)"
	auth_mode="$(git_auth_mode)"
	git_readonly=0
	git_readonly_mode && git_readonly=1
	http_username="$(git_http_username)"
	[ -n "$(git_http_password)" ] && http_password_set=1 || http_password_set=0
	[ -s "$(ssh_key_path)" ] && ssh_key_present=1 || ssh_key_present=0
	ssh_pub=''
	[ -f "$(ssh_key_path).pub" ] && ssh_pub="$(cat "$(ssh_key_path).pub" 2>/dev/null || true)"
	if [ -z "$ssh_pub" ] && [ "$ssh_key_present" = '1' ]; then
		ssh_pub="$(ssh-keygen -y -f "$(ssh_key_path)" 2>/dev/null || true)"
	fi
	repo_fetch_configured && git_configured=1 || git_configured=0
	git_push_status_payload="$(git_push_status_fields)"
	git_push_status="$(printf '%s\n' "$git_push_status_payload" | sed -n 's/^status=//p' | sed -n '1p')"
	git_push_message="$(printf '%s\n' "$git_push_status_payload" | sed -n 's/^message=//p' | sed -n '1p')"
	git_push_next_step="$(printf '%s\n' "$git_push_status_payload" | sed -n 's/^next_step=//p' | sed -n '1p')"
	git_push_effective_auth="$(printf '%s\n' "$git_push_status_payload" | sed -n 's/^effective_auth=//p' | sed -n '1p')"
	git_push_ready='0'
	[ "$git_push_status" = 'ready' ] && git_push_ready='1'

	repo_head=''
	repo_dirty='0'
	if [ -d "$repo/.git" ]; then
		repo_head="$(git_cmd -C "$repo" rev-parse --short HEAD 2>/dev/null || true)"
		if ! git_cmd -C "$repo" diff --quiet -- "$tree_rel" 2>/dev/null; then
			repo_dirty='1'
		fi
	fi

	source_count="$(rule_count "$rules_file")"
	managed_source_count='0'
	managed_applied_source_count='0'
	while IFS='|' read -r id label url || [ -n "$id" ]; do
		[ -n "$id" ] || continue
		path="$(external_source_path "$id")"
		count="$(rule_count "$path")"
		managed_source_count=$((managed_source_count + count))
		if [ "$(external_source_enabled_by_id "$id")" = '1' ]; then
			managed_applied_source_count=$((managed_applied_source_count + count))
		fi
	done <<EOF
$(external_source_catalog)
EOF
	effective_source_count="$(status_get effective_source_count)"
	[ -n "$effective_source_count" ] || effective_source_count="$source_count"
	resolved_count="$( [ -f "$resolved" ] && wc -l < "$resolved" | awk '{print $1}' || echo 0 )"
	domain_count="$( [ -f "$domains" ] && wc -l < "$domains" | awk '{print $1}' || echo 0 )"
	literal_count="$( [ -f "$literals" ] && wc -l < "$literals" | awk '{print $1}' || echo 0 )"
	setname="$(xray_ipset)"
	xray_ipset_count="$(ipset list "$setname" 2>/dev/null | sed -n 's/^Number of entries: //p' | sed -n '1p')"
	[ -n "$xray_ipset_count" ] || xray_ipset_count="$(status_get xray_ipset_count)"
	[ -n "$xray_ipset_count" ] || xray_ipset_count='0'

	last_sync_at="$(status_get last_sync_at)"
	last_sync_status="$(status_get last_sync_status)"
	last_sync_message="$(status_get last_sync_message)"
	last_apply_xray="$(status_get last_apply_xray)"
	last_sync_actor="$(status_get last_sync_actor)"
	last_sync_strategy="$(status_get last_sync_strategy)"
	current_signature="$(xray_state_signature_quick_internal)"
	rules_checksum="$(file_signature "$rules_file")"
	last_apply_signature="$(status_get last_apply_xray_signature)"
	last_cutover_at="$(status_get last_cutover_at)"
	last_cutover_status="$(status_get last_cutover_status)"
	last_cutover_message="$(status_get last_cutover_message)"
	last_cutover_signature="$(status_get last_cutover_signature)"
	ui_job_id="$(status_get ui_job_id)"
	ui_job_kind="$(status_get ui_job_kind)"
	ui_job_state="$(status_get ui_job_state)"
	ui_job_message="$(status_get ui_job_message)"
	ui_job_started_at="$(status_get ui_job_started_at)"
	ui_job_finished_at="$(status_get ui_job_finished_at)"
	ui_job_target_mode="$(status_get ui_job_target_mode)"
	ui_job_suggestion="$(status_get ui_job_suggestion)"
	ui_job_console_path="$(status_get ui_job_console_path)"
	ui_job_console_output=''
	if [ -n "$ui_job_console_path" ] && [ -f "$ui_job_console_path" ]; then
		ui_job_console_output="$(cat "$ui_job_console_path" 2>/dev/null || true)"
	fi
	last_verified_at="$(status_get last_verified_at)"
	sync_phase="$(status_get sync_phase)"
	sync_phase_at="$(status_get sync_phase_at)"
	sync_phase_message="$(status_get sync_phase_message)"
	sync_trace="$(status_get sync_trace)"
	last_external_run_at="$(status_get last_external_run_at)"
	last_external_status="$(status_get last_external_status)"
	last_external_message="$(status_get last_external_message)"
	last_external_generated_count="$(status_get last_external_generated_count)"
	last_external_added_count="$(status_get last_external_added_count)"
	last_external_actor="$(status_get last_external_actor)"
	last_remote_probe_at="$(status_get last_remote_probe_at)"
	last_remote_probe_status="$(status_get last_remote_probe_status)"
	last_remote_probe_message="$(status_get last_remote_probe_message)"
	last_remote_probe_head="$(status_get last_remote_probe_head)"
	last_remote_probe_update_available="$(status_get last_remote_probe_update_available)"
	external_due='0'
	external_source_due_now && external_due='1'
	external_sources_payload="$(external_sources_json)"
	cutover_required='0'
	[ "$current_signature" = "$last_cutover_signature" ] || cutover_required='1'

	printf '{'
	printf '"ok":true,'
	printf '"git_sync_enabled":'; json_bool "$sync_enabled"; printf ','
	printf '"git_configured":'; json_bool "$git_configured"; printf ','
	printf '"repo_ready":'
	if [ -d "$repo/.git" ]; then json_bool 1; else json_bool 0; fi
	printf ','
	printf '"repo_path":"%s",' "$(json_escape "$repo")"
	printf '"repo_fetch_url":"%s",' "$(json_escape "$fetch_url")"
	printf '"repo_push_url":"%s",' "$(json_escape "$push_url_raw")"
	printf '"repo_push_url_effective":"%s",' "$(json_escape "$push_url_effective")"
	printf '"repo_branch":"%s",' "$(json_escape "$(repo_branch)")"
	printf '"rules_relpath":"%s",' "$(json_escape "$rel")"
	printf '"remote_rules_ref":"%s",' "$(json_escape "$remote_ref")"
	printf '"repo_browser_rules_url":"%s",' "$(json_escape "$browser_rules_url")"
	printf '"repo_head":"%s",' "$(json_escape "$repo_head")"
	printf '"repo_dirty":'; json_bool "$repo_dirty"; printf ','
	printf '"git_auth_mode":"%s",' "$(json_escape "$auth_mode")"
	printf '"git_readonly":'; json_bool "$git_readonly"; printf ','
	printf '"git_push_ready":'; json_bool "$git_push_ready"; printf ','
	printf '"git_push_status":"%s",' "$(json_escape "$git_push_status")"
	printf '"git_push_message":"%s",' "$(json_escape "$git_push_message")"
	printf '"git_push_next_step":"%s",' "$(json_escape "$git_push_next_step")"
	printf '"git_push_effective_auth":"%s",' "$(json_escape "$git_push_effective_auth")"
	printf '"git_http_username":"%s",' "$(json_escape "$http_username")"
	printf '"git_http_password_set":'; json_bool "$http_password_set"; printf ','
	printf '"git_ssh_key_present":'; json_bool "$ssh_key_present"; printf ','
	printf '"git_ssh_public_key":"%s",' "$(json_escape "$ssh_pub")"
	printf '"xray_mode":"%s",' "$(json_escape "$mode")"
	printf '"sync_interval":"%s",' "$(json_escape "$interval")"
	printf '"external_source_enabled":'; json_bool "$external_enabled"; printf ','
	printf '"external_source_interval":"%s",' "$(json_escape "$external_interval")"
	printf '"external_source_due":'; json_bool "$external_due"; printf ','
	printf '"enable_push":'; json_bool "$(enable_push)"; printf ','
	printf '"source_count":"%s",' "$(json_escape "$source_count")"
	printf '"effective_source_count":"%s",' "$(json_escape "$effective_source_count")"
	printf '"managed_source_count":"%s",' "$(json_escape "$managed_source_count")"
	printf '"managed_applied_source_count":"%s",' "$(json_escape "$managed_applied_source_count")"
	printf '"domain_count":"%s",' "$(json_escape "$domain_count")"
	printf '"literal_count":"%s",' "$(json_escape "$literal_count")"
	printf '"resolved_count":"%s",' "$(json_escape "$resolved_count")"
	printf '"xray_ipset_count":"%s",' "$(json_escape "$xray_ipset_count")"
	printf '"last_sync_at":"%s",' "$(json_escape "$last_sync_at")"
	printf '"last_sync_actor":"%s",' "$(json_escape "$last_sync_actor")"
	printf '"last_sync_status":"%s",' "$(json_escape "$last_sync_status")"
	printf '"last_sync_message":"%s",' "$(json_escape "$last_sync_message")"
	printf '"last_sync_strategy":"%s",' "$(json_escape "$last_sync_strategy")"
	printf '"sync_phase":"%s",' "$(json_escape "$sync_phase")"
	printf '"sync_phase_at":"%s",' "$(json_escape "$sync_phase_at")"
	printf '"sync_phase_message":"%s",' "$(json_escape "$sync_phase_message")"
	printf '"sync_trace":"%s",' "$(json_escape "$sync_trace")"
	printf '"last_verified_at":"%s",' "$(json_escape "$last_verified_at")"
	printf '"last_external_run_at":"%s",' "$(json_escape "$last_external_run_at")"
	printf '"last_external_actor":"%s",' "$(json_escape "$last_external_actor")"
	printf '"last_external_status":"%s",' "$(json_escape "$last_external_status")"
	printf '"last_external_message":"%s",' "$(json_escape "$last_external_message")"
	printf '"last_external_generated_count":"%s",' "$(json_escape "$last_external_generated_count")"
	printf '"last_external_added_count":"%s",' "$(json_escape "$last_external_added_count")"
	printf '"last_remote_probe_at":"%s",' "$(json_escape "$last_remote_probe_at")"
	printf '"last_remote_probe_status":"%s",' "$(json_escape "$last_remote_probe_status")"
	printf '"last_remote_probe_message":"%s",' "$(json_escape "$last_remote_probe_message")"
	printf '"last_remote_probe_head":"%s",' "$(json_escape "$last_remote_probe_head")"
	printf '"last_remote_probe_update_available":'; json_bool "${last_remote_probe_update_available:-0}"; printf ','
	printf '"external_sources":%s,' "$external_sources_payload"
	printf '"rules_text_included":'; json_bool "$rules_text_included"; printf ','
	printf '"rules_checksum":"%s",' "$(json_escape "$rules_checksum")"
	printf '"last_apply_signature":"%s",' "$(json_escape "$last_apply_signature")"
	printf '"last_apply_xray":"%s",' "$(json_escape "$last_apply_xray")"
	printf '"last_cutover_at":"%s",' "$(json_escape "$last_cutover_at")"
	printf '"last_cutover_status":"%s",' "$(json_escape "$last_cutover_status")"
	printf '"last_cutover_message":"%s",' "$(json_escape "$last_cutover_message")"
	printf '"last_cutover_signature":"%s",' "$(json_escape "$last_cutover_signature")"
	printf '"ui_job_id":"%s",' "$(json_escape "$ui_job_id")"
	printf '"ui_job_kind":"%s",' "$(json_escape "$ui_job_kind")"
	printf '"ui_job_state":"%s",' "$(json_escape "$ui_job_state")"
	printf '"ui_job_message":"%s",' "$(json_escape "$ui_job_message")"
	printf '"ui_job_started_at":"%s",' "$(json_escape "$ui_job_started_at")"
	printf '"ui_job_finished_at":"%s",' "$(json_escape "$ui_job_finished_at")"
	printf '"ui_job_target_mode":"%s",' "$(json_escape "$ui_job_target_mode")"
	printf '"ui_job_suggestion":"%s",' "$(json_escape "$ui_job_suggestion")"
	printf '"ui_job_console_output":"%s",' "$(json_escape "$ui_job_console_output")"
	printf '"cutover_required":'; json_bool "$cutover_required"; printf ','
	printf '"git_circuit_breaker_open":'; if git_circuit_open; then json_bool 1; else json_bool 0; fi; printf ','
	printf '"git_consecutive_failures":"%s",' "$(json_escape "$(status_get git_consecutive_failures)")"
	printf '"selective_fallback_active":'; if selective_fallback_active; then json_bool 1; else json_bool 0; fi; printf ','
	printf '"selective_fallback_reason":"%s",' "$(json_escape "$(selective_fallback_reason)")"
	printf '"rules_text":"%s"' "$(json_escape "$file_text")"
	printf '}'
}

