#!/bin/sh
# router-rules-rulestree.sh — extracted from router-rules (AGENTS.md 500-line
# rule). Deployed to /usr/share/vpn-xray/. Sourced by /usr/bin/router-rules
# after lib-common.sh, before the LIB_ONLY guard. Functions only; runs no code.

merge_rules_tree_for_mode_internal() {
	local mode="$1"
	local remote_root="$2"
	local local_root="$3"
	local repo_root="$4"
	local rel remote_file local_file out_file

	while IFS= read -r rel || [ -n "$rel" ]; do
		[ -n "$rel" ] || continue
		remote_file="${remote_root}/${rel}"
		local_file="${local_root}/${rel}"
		out_file="${repo_root}/${rel}"
		mkdir -p "$(dirname "$out_file")"
		if [ "$rel" = "$(rules_relpath)" ]; then
			if [ -f "$remote_file" ] && [ -f "$local_file" ]; then
				merge_remote_preferred "$remote_file" "$local_file" "$out_file"
			elif [ -f "$local_file" ]; then
				cp "$local_file" "$out_file"
			elif [ -f "$remote_file" ]; then
				cp "$remote_file" "$out_file"
			else
				rm -f "$out_file"
			fi
			continue
		fi
		case "$mode" in
			push)
				if [ -f "$local_file" ]; then
					cp "$local_file" "$out_file"
				elif [ -f "$remote_file" ]; then
					cp "$remote_file" "$out_file"
				else
					rm -f "$out_file"
				fi
				;;
			*)
				if [ -f "$remote_file" ]; then
					cp "$remote_file" "$out_file"
				elif [ -f "$local_file" ]; then
					cp "$local_file" "$out_file"
				else
					rm -f "$out_file"
				fi
				;;
		esac
	done <<EOF
$(tracked_rules_relpaths)
EOF
}

allow_empty_manual_rules_internal() {
	[ "${ROUTER_RULES_ALLOW_EMPTY_MANUAL:-0}" = '1' ]
}

rules_backup_keep_count_internal() {
	local keep

	keep="$(rules_backup_keep)"
	case "$keep" in
		''|*[!0-9]*)
			keep="$DEFAULT_RULES_BACKUP_KEEP"
			;;
	esac
	[ "$keep" -ge 3 ] 2>/dev/null || keep="$DEFAULT_RULES_BACKUP_KEEP"
	printf '%s\n' "$keep"
}

prune_rules_backups_internal() {
	local backup_root keep count old

	backup_root="$(rules_backup_dir)"
	[ -d "$backup_root" ] || return 0
	keep="$(rules_backup_keep_count_internal)"
	count=0
	for old in $(ls -1dt "$backup_root"/* 2>/dev/null); do
		[ -d "$old" ] || continue
		count=$((count + 1))
		[ "$count" -le "$keep" ] && continue
		rm -rf "$old"
	done
}

backup_rules_tree_internal() {
	local reason="${1:-unspecified}" backup_root backup_dir stamp repo head mode

	backup_root="$(rules_backup_dir)"
	repo="$(repo_path)"
	mkdir -p "$backup_root"
	stamp="$(date '+%Y%m%d-%H%M%S')-$$"
	backup_dir="${backup_root}/${stamp}"
	mkdir -p "${backup_dir}/tree"
	if [ -d "$repo" ]; then
		snapshot_rules_tree_from_worktree_internal "$repo" "${backup_dir}/tree" || true
	fi
	head=''
	[ -d "$repo/.git" ] && head="$(git_cmd -C "$repo" rev-parse --verify HEAD 2>/dev/null || true)"
	mode="$(xray_mode)"
	{
		printf 'epoch=%s\n' "$(date +%s)"
		printf 'reason=%s\n' "$reason"
		printf 'mode=%s\n' "$mode"
		printf 'repo_head=%s\n' "$head"
		printf 'rules_relpath=%s\n' "$(rules_relpath)"
		printf 'signature=%s\n' "$(tracked_rules_signature)"
	} > "${backup_dir}/meta"
	prune_rules_backups_internal || true
	printf '%s\n' "$backup_dir"
}

restore_manual_rules_from_origin_internal() {
	local repo branch rel main_file tmp count

	repo="$(repo_path)"
	branch="$(repo_branch)"
	rel="$(rules_relpath)"
	main_file="$(repo_rules_path)"
	[ -d "$repo/.git" ] || return 1
	tmp="$(rr_mktemp)"
	if ! git_cmd -C "$repo" show "origin/${branch}:${rel}" > "$tmp" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	count="$(rule_count "$tmp")"
	if [ "${count:-0}" -le 0 ] 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	backup_rules_tree_internal 'before-restore-manual-from-origin' >/dev/null 2>&1 || true
	mkdir -p "$(dirname "$main_file")"
	cp "$tmp" "$main_file"
	rm -f "$tmp"
	status_trace_add sync_trace "rules recovered: restored $(rules_relpath) from origin/${branch}"
	return 0
}

restore_manual_rules_from_latest_backup_internal() {
	local backup_root rel main_file backup src count

	backup_root="$(rules_backup_dir)"
	rel="$(rules_relpath)"
	main_file="$(repo_rules_path)"
	[ -d "$backup_root" ] || return 1
	for backup in $(ls -1dt "$backup_root"/* 2>/dev/null); do
		src="${backup}/tree/${rel}"
		[ -f "$src" ] || continue
		count="$(rule_count "$src")"
		[ "${count:-0}" -gt 0 ] 2>/dev/null || continue
		mkdir -p "$(dirname "$main_file")"
		cp "$src" "$main_file"
		status_trace_add sync_trace "rules recovered: restored $(rules_relpath) from backup $(basename "$backup")"
		return 0
	done
	return 1
}

recover_empty_manual_rules_internal() {
	local reason="${1:-empty-manual-rules}" main_file count

	allow_empty_manual_rules_internal && return 0
	main_file="$(repo_rules_path)"
	count="$(rule_count "$main_file")"
	[ "${count:-0}" -eq 0 ] 2>/dev/null || return 0
	restore_manual_rules_from_origin_internal && return 0
	restore_manual_rules_from_latest_backup_internal && return 0
	status_trace_add sync_trace "rules recovery skipped: $(rules_relpath) is empty and no non-empty origin/backup snapshot is available (${reason})"
	return 1
}

guard_manual_rules_write_internal() {
	local src="$1"
	local dst="$2"
	local reason="${3:-write}"
	local src_count dst_count tmp remote_count

	allow_empty_manual_rules_internal && return 0
	src_count="$(rule_count "$src")"
	[ "${src_count:-0}" -eq 0 ] 2>/dev/null || return 0

	dst_count="$(rule_count "$dst")"
	remote_count=0
	if [ -d "$(repo_path)/.git" ]; then
		tmp="$(rr_mktemp)"
		if git_cmd -C "$(repo_path)" show "origin/$(repo_branch):$(rules_relpath)" > "$tmp" 2>/dev/null; then
			remote_count="$(rule_count "$tmp")"
		fi
		rm -f "$tmp"
	fi

	if [ "${dst_count:-0}" -gt 0 ] 2>/dev/null || [ "${remote_count:-0}" -gt 0 ] 2>/dev/null; then
		backup_rules_tree_internal "blocked-empty-manual-${reason}" >/dev/null 2>&1 || true
		set_status_error "refusing to overwrite non-empty shared rules with an empty $(rules_relpath); set ROUTER_RULES_ALLOW_EMPTY_MANUAL=1 only for an intentional wipe"
		return 1
	fi
	return 0
}

rule_count() {
	local file="$1"

	[ -f "$file" ] || {
		printf '0\n'
		return 0
	}

	awk '
		{
			line = $0
			sub(/\r$/, "", line)
			sub(/^[[:space:]]+/, "", line)
			sub(/[[:space:]]+$/, "", line)
			if (line == "" || line ~ /^#/) {
				next
			}
			count++
		}
		END { print count + 0 }
	' "$file"
}

external_source_status_key() {
	printf 'external_%s_%s\n' "$1" "$2"
}

external_source_status_get() {
	status_get "$(external_source_status_key "$1" "$2")"
}

external_source_status_set() {
	status_set "$(external_source_status_key "$1" "$2")" "$3"
}

external_source_due_by_id() {
	local id="$1"
	local last now interval

	[ "$(external_source_refresh_enabled)" = '1' ] || return 1
	interval="$(external_source_interval_seconds)"
	last="$(external_source_status_get "$id" last_run_at)"
	[ -n "$last" ] || return 0
	now="$(date +%s)"
	[ $((now - last)) -ge "$interval" ]
}

external_source_due_now() {
	local id label url

	while IFS='|' read -r id label url || [ -n "$id" ]; do
		[ -n "$id" ] || continue
		if external_source_due_by_id "$id"; then
			return 0
		fi
	done <<EOF
$(external_source_catalog)
EOF

	return 1
}

should_refresh_external_source_internal() {
	if [ "${ROUTER_RULES_EXTERNAL_FORCE:-0}" = '1' ]; then
		[ "$(external_source_enabled)" = '1' ]
		return $?
	fi
	[ "$(sync_actor)" = 'background' ] || return 1
	external_source_due_now
}

background_external_refresh_running_internal() {
	local pid stale_message

	pid="$(status_get last_external_pid)"
	[ -n "$pid" ] || pid="$(cat "$EXTERNAL_SYNC_PID_FILE" 2>/dev/null || true)"
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		return 0
	fi
	if [ -n "$pid" ] || [ "$(status_get last_external_status)" = 'running' ]; then
		rm -f "$EXTERNAL_SYNC_PID_FILE"
		status_set last_external_pid ''
		stale_message="$(sed '/^[[:space:]]*$/d' /tmp/router-rules-external-sync.log 2>/dev/null | sed -n '1p')"
		[ -n "$stale_message" ] || stale_message='Background managed-source refresh stopped before completion.'
		status_set last_external_status 'error'
		status_set last_external_message "$stale_message"
		status_set last_external_run_at "$(date +%s)"
		status_set last_external_actor "$(sync_actor)"
		status_trace_add sync_trace "external error: ${stale_message}"
	fi
	return 1
}

queue_background_external_refresh_internal() {
	local pid log_file

	[ "$(external_source_refresh_enabled)" = '1' ] || return 0
	if [ "${ROUTER_RULES_EXTERNAL_FORCE:-0}" != '1' ]; then
		external_source_due_now || return 0
	fi
	if background_external_refresh_running_internal; then
		return 0
	fi

	log_file='/tmp/router-rules-external-sync.log'
	rm -f "$EXTERNAL_SYNC_PID_FILE"
	status_set last_external_status 'running'
	status_set last_external_message 'Managed source snapshot refresh is running in the background.'
	status_set last_external_run_at "$(date +%s)"
	status_set last_external_actor 'background-external'
	status_trace_add sync_trace 'external running: scheduled background snapshot refresh started'

	if command -v start-stop-daemon >/dev/null 2>&1; then
		start-stop-daemon -S -b -m -p "$EXTERNAL_SYNC_PID_FILE" -x /bin/sh -- -c \
			"sleep 1; export ROUTER_RULES_SYNC_ACTOR='background-external'; export ROUTER_RULES_EXTERNAL_FORCE='1'; export ROUTER_RULES_LOCK_WAIT='10'; if command -v timeout >/dev/null 2>&1; then timeout 1800 /usr/bin/router-rules sync-external-source >'$log_file' 2>&1 || true; else /usr/bin/router-rules sync-external-source >'$log_file' 2>&1 || true; fi" \
			>/dev/null 2>&1 || return 1
		pid="$(cat "$EXTERNAL_SYNC_PID_FILE" 2>/dev/null || true)"
	else
		(
			export ROUTER_RULES_SYNC_ACTOR='background-external'
			export ROUTER_RULES_EXTERNAL_FORCE='1'
			export ROUTER_RULES_LOCK_WAIT='10'
			sleep 1
			if command -v timeout >/dev/null 2>&1; then
				timeout 1800 /usr/bin/router-rules sync-external-source >"$log_file" 2>&1 || true
			else
				/usr/bin/router-rules sync-external-source >"$log_file" 2>&1 || true
			fi
		) &
		pid=$!
	fi
	status_set last_external_pid "$pid"
	return 0
}

set_external_status() {
	local status="$1"
	local message="$2"
	local generated_count="${3:-0}"
	local added_count="${4:-0}"

	status_set last_external_run_at "$(date +%s)"
	status_set last_external_status "$status"
	status_set last_external_message "$message"
	status_set last_external_generated_count "$generated_count"
	status_set last_external_added_count "$added_count"
	status_set last_external_actor "$(sync_actor)"
	status_trace_add sync_trace "external ${status}: ${message}"
}

set_external_source_status() {
	local id="$1"
	local status="$2"
	local message="$3"
	local generated_count="${4:-0}"
	local added_count="${5:-0}"

	external_source_status_set "$id" last_run_at "$(date +%s)"
	external_source_status_set "$id" last_status "$status"
	external_source_status_set "$id" last_message "$message"
	external_source_status_set "$id" last_generated_count "$generated_count"
	external_source_status_set "$id" last_added_count "$added_count"
	external_source_status_set "$id" last_actor "$(sync_actor)"
	status_trace_add sync_trace "external ${id} ${status}: ${message}"
}

tracked_rules_signature() {
	local signature id label url path

	signature="main:$(file_signature "$(repo_rules_path)")"
	while IFS='|' read -r id label url || [ -n "$id" ]; do
		[ -n "$id" ] || continue
		path="$(external_source_path "$id")"
		signature="${signature}|${id}:$(file_signature "$path")"
	done <<EOF
$(external_source_catalog)
EOF
	printf '%s\n' "$signature"
}

managed_external_sources_present_internal() {
	local id label url

	while IFS='|' read -r id label url || [ -n "$id" ]; do
		[ -n "$id" ] || continue
		if [ -f "$(external_source_path "$id")" ]; then
			return 0
		fi
	done <<EOF
$(external_source_catalog)
EOF

	return 1
}

collect_managed_external_sources_internal() {
	local out_file="$1"
	local id label url path

	: > "$out_file"
	while IFS='|' read -r id label url || [ -n "$id" ]; do
		[ -n "$id" ] || continue
		path="$(external_source_path "$id")"
		[ -s "$path" ] || continue
		if [ -s "$out_file" ]; then
			printf '\n' >> "$out_file"
		fi
		cat "$path" >> "$out_file"
	done <<EOF
$(external_source_catalog)
EOF
}

