#!/bin/sh
# router-rules-git.sh — extracted from router-rules (AGENTS.md 500-line
# rule). Deployed to /usr/share/vpn-xray/. Sourced by /usr/bin/router-rules
# after lib-common.sh, before the LIB_ONLY guard. Functions only; runs no code.

repo_push_url() {
	local value fetch_url rest owner repo

	value="$(repo_push_url_raw)"
	if is_placeholder_value "$value"; then
		value=''
	fi
	if [ -n "$value" ]; then
		if [ "$(git_auth_mode)" = 'ssh' ]; then
			case "$value" in
				https://github.com/*)
					rest="${value#https://github.com/}"
					owner="${rest%%/*}"
					rest="${rest#*/}"
					repo="${rest%%.git*}"
					repo="${repo%%/*}"
					if [ -n "$owner" ] && [ -n "$repo" ]; then
						printf 'git@github.com:%s/%s.git\n' "$owner" "$repo"
						return 0
					fi
					;;
			esac
		fi
		printf '%s\n' "$value"
		return 0
	fi

	fetch_url="$(repo_fetch_url)"
	if [ "$(git_auth_mode)" = 'ssh' ]; then
		case "$fetch_url" in
			https://github.com/*)
				rest="${fetch_url#https://github.com/}"
				owner="${rest%%/*}"
				rest="${rest#*/}"
				repo="${rest%%.git*}"
				repo="${repo%%/*}"
				if [ -n "$owner" ] && [ -n "$repo" ]; then
					printf 'git@github.com:%s/%s.git\n' "$owner" "$repo"
					return 0
				fi
				;;
		esac
	fi

	printf '%s\n' "$fetch_url"
}

repo_browser_rules_url() {
	local url branch rel rest owner repo

	url="$(repo_fetch_url)"
	branch="$(repo_branch)"
	rel="$(rules_relpath)"
	case "$url" in
		https://github.com/*)
			rest="${url#https://github.com/}"
			owner="${rest%%/*}"
			rest="${rest#*/}"
			repo="${rest%%.git*}"
			repo="${repo%%/*}"
			[ -n "$owner" ] && [ -n "$repo" ] || return 1
			printf 'https://github.com/%s/%s/blob/%s/%s\n' "$owner" "$repo" "$branch" "$rel"
			return 0
			;;
		git@github.com:*)
			rest="${url#git@github.com:}"
			owner="${rest%%/*}"
			rest="${rest#*/}"
			repo="${rest%%.git*}"
			repo="${repo%%/*}"
			[ -n "$owner" ] && [ -n "$repo" ] || return 1
			printf 'https://github.com/%s/%s/blob/%s/%s\n' "$owner" "$repo" "$branch" "$rel"
			return 0
			;;
	esac
	return 1
}

remote_rules_ref() {
	printf 'origin/%s:%s\n' "$(repo_branch)" "$(rules_relpath)"
}

git_auth_mode() {
	local raw url

	raw="$(git_auth_mode_raw)"
	case "$raw" in
		none|readonly)
			printf 'readonly\n'
			return 0
			;;
		https|ssh)
			printf '%s\n' "$raw"
			return 0
			;;
	esac

	url="$(repo_fetch_url)"
	case "$url" in
		git@*|ssh://*)
			printf 'ssh\n'
			;;
		http://*|https://*)
			if [ -n "$(git_http_username)" ] || [ -n "$(git_http_password)" ]; then
				printf 'https\n'
			else
				printf 'readonly\n'
			fi
			;;
		*)
			printf 'readonly\n'
			;;
	esac
}

git_readonly_mode() {
	git_push_auth_configured && return 1
	[ "$(git_auth_mode)" = 'readonly' ]
}

git_push_auth_configured() {
	local url

	url="$(repo_push_url)"
	case "$url" in
		git@*|ssh://*)
			[ -s "$(ssh_key_path)" ]
			;;
		http://*|https://*)
			[ -n "$(git_http_username)" ] || [ -n "$(git_http_password)" ]
			;;
		*)
			return 1
			;;
	esac
}

repo_fetch_url_available() {
	if is_placeholder_value "$(repo_fetch_url)"; then
		return 1
	fi
	if is_placeholder_value "$(device_id)"; then
		return 1
	fi
	return 0
}

git_sync_enabled() {
	local raw

	raw="$(git_sync_enabled_raw)"
	case "$raw" in
		0|1)
			printf '%s\n' "$raw"
			return 0
			;;
	esac

	if repo_fetch_url_available; then
		printf '1\n'
	else
		printf '0\n'
	fi
}

repo_fetch_configured() {
	[ "$(git_sync_enabled)" = '1' ] || return 1
	repo_fetch_url_available
}

repo_push_configured() {
	repo_fetch_configured || return 1
	if is_placeholder_value "$(repo_push_url)"; then
		return 1
	fi
	git_push_auth_configured || return 1
	return 0
}

git_push_status_fields() {
	local fetch_ready push_enabled push_url auth_mode status message next_step effective_auth

	fetch_ready='0'
	repo_fetch_configured && fetch_ready='1'
	push_enabled="$(enable_push)"
	push_url="$(repo_push_url)"
	auth_mode="$(git_auth_mode)"
	status='ready'
	message='Push is configured.'
	next_step='Use Push To Git after editing the shared rules list.'
	effective_auth='unknown'

	case "$push_url" in
		git@*|ssh://*) effective_auth='ssh' ;;
		http://*|https://*) effective_auth='https' ;;
	esac

	if [ "$fetch_ready" != '1' ]; then
		status='missing_repo'
		message='Git sync is not configured, so push cannot run.'
		next_step='Enable Git sync and save a valid repository URL first.'
	elif [ "$push_enabled" != '1' ]; then
		status='disabled'
		message='Push is disabled by router policy.'
		next_step='Turn on "Allow Push To Git" in Git Sync Settings, choose HTTPS token or SSH key auth, then save settings.'
	elif is_placeholder_value "$push_url"; then
		status='missing_push_url'
		message='Push URL is missing.'
		next_step='Set Push URL, or leave it empty only when the fetch URL is also a writable remote.'
	elif [ "$effective_auth" = 'https' ] && ! git_push_auth_configured; then
		status='missing_https_token'
		message='Push URL uses HTTPS, but no HTTPS write credentials are stored.'
		next_step='Set Git Auth to HTTPS and save a GitHub token/password with write access.'
	elif [ "$effective_auth" = 'ssh' ] && ! git_push_auth_configured; then
		status='missing_ssh_key'
		message='Push URL uses SSH, but the router has no SSH private key.'
		next_step='Set Git Auth to SSH, generate or paste the router key, then register the public key as a writable deploy key on GitHub.'
	elif ! repo_push_configured; then
		status='not_ready'
		message='Push is not ready.'
		next_step='Check Push URL and write credentials.'
	fi

	printf 'status=%s\n' "$status"
	printf 'message=%s\n' "$message"
	printf 'next_step=%s\n' "$next_step"
	printf 'effective_auth=%s\n' "$effective_auth"
}

repo_configured() {
	repo_fetch_configured
}

repo_rules_path() {
	printf '%s/%s\n' "$(repo_path)" "$(rules_relpath)"
}

rules_tree_relpath() {
	printf '%s\n' "$(dirname "$(rules_relpath)")"
}

repo_rules_tree_path() {
	printf '%s/%s\n' "$(repo_path)" "$(rules_tree_relpath)"
}

external_source_relpath() {
	printf '%s/external/%s.txt\n' "$(rules_tree_relpath)" "$1"
}

external_source_path() {
	printf '%s/%s\n' "$(repo_path)" "$(external_source_relpath "$1")"
}

effective_rules_file() {
	printf '%s/effective_shared_targets.txt\n' "$(generated_dir)"
}

effective_rules_signature_file() {
	printf '%s/effective_shared_targets.sig\n' "$(generated_dir)"
}

external_source_repo_layout_version() {
	cfg_get external_source_repo_layout_version '0'
}

resolved_file() {
	printf '%s/resolved_ipv4.txt\n' "$(generated_dir)"
}

mapping_file() {
	printf '%s/resolution_map.tsv\n' "$(generated_dir)"
}

domain_file() {
	printf '%s/domains.txt\n' "$(generated_dir)"
}

literal_file() {
	printf '%s/literals_ipv4.txt\n' "$(generated_dir)"
}

status_get() {
	local key="$1"
	[ -f "$STATUS_FILE" ] || return 0
	sed -n "s/^${key}=//p" "$STATUS_FILE" | sed -n '1p'
}

status_set() {
	local key="$1"
	local value="$2"
	local tmp

	tmp="$(rr_mktemp)"
	if [ -f "$STATUS_FILE" ]; then
		grep -v "^${key}=" "$STATUS_FILE" > "$tmp" || true
	fi
	printf '%s=%s\n' "$key" "$value" >> "$tmp"
	mv "$tmp" "$STATUS_FILE"
}

sync_actor() {
	printf '%s\n' "${ROUTER_RULES_SYNC_ACTOR:-manual}"
}

sync_mode() {
	case "${ROUTER_RULES_SYNC_MODE:-sync}" in
		pull|push|apply|sync)
			printf '%s\n' "${ROUTER_RULES_SYNC_MODE:-sync}"
			;;
		*)
			printf 'sync\n'
			;;
	esac
}

sync_push_requested() {
	case "$(sync_mode)" in
		push)
			printf '1\n'
			;;
		*)
			if [ "$(enable_push)" = '1' ]; then
				printf '1\n'
			else
				printf '0\n'
			fi
			;;
	esac
}

git_circuit_open() {
	local until_epoch now

	[ "${ROUTER_RULES_FORCE_GIT:-0}" = '1' ] && return 1
	until_epoch="$(status_get git_circuit_breaker_until)"
	[ -n "$until_epoch" ] || return 1
	now="$(date +%s)"
	[ "$now" -lt "$until_epoch" ] 2>/dev/null
}

git_record_failure() {
	local count cooldown_until

	count="$(status_get git_consecutive_failures)"
	count="$((${count:-0} + 1))"
	status_set git_consecutive_failures "$count"
	if [ "$count" -ge 3 ]; then
		cooldown_until="$(( $(date +%s) + 300 ))"
		status_set git_circuit_breaker_until "$cooldown_until"
	fi
}

git_record_success() {
	status_set git_consecutive_failures '0'
	status_set git_circuit_breaker_until ''
}

status_trace_add() {
	local key="$1"
	local message="$2"
	local existing item combined count oldifs
	local stamp

	stamp="$(date '+%H:%M:%S')"
	existing="$(status_get "$key")"
	combined="${stamp} ${message}"
	count=1
	oldifs="$IFS"
	IFS='
'
	for item in $(printf '%s' "$existing" | sed 's/ || /\n/g'); do
		[ -n "$item" ] || continue
		combined="${combined} || ${item}"
		count=$((count + 1))
		[ "$count" -ge 6 ] && break
	done
	IFS="$oldifs"
	status_set "$key" "$combined"
}

set_sync_phase() {
	local phase="$1"
	local message="$2"
	status_set sync_phase "$phase"
	status_set sync_phase_message "$message"
	status_set sync_phase_at "$(date +%s)"
	status_set sync_actor "$(sync_actor)"
	status_trace_add sync_trace "${phase}: ${message}"
}

set_status_ok() {
	local message="$1"
	status_set last_sync_status 'ok'
	status_set last_sync_message "$message"
	status_set last_sync_at "$(date +%s)"
	status_set last_sync_actor "$(sync_actor)"
}

set_status_error() {
	local message="$1"
	status_set last_sync_status 'error'
	status_set last_sync_message "$message"
	status_set last_sync_at "$(date +%s)"
	status_set last_sync_actor "$(sync_actor)"
	set_sync_phase error "$message"
}

set_remote_probe_status() {
	local status="$1"
	local message="$2"
	local head="$3"
	local update_available="${4:-0}"

	status_set last_remote_probe_status "$status"
	status_set last_remote_probe_message "$message"
	status_set last_remote_probe_head "$head"
	status_set last_remote_probe_update_available "$update_available"
	status_set last_remote_probe_at "$(date +%s)"
}

set_apply_status() {
	local consumer="$1"
	local message="$2"
	status_set "last_apply_${consumer}" "$(date +%s)"
	status_set "last_apply_${consumer}_message" "$message"
}

