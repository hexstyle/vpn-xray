#!/bin/sh
# router-rules-remote.sh — extracted from router-rules (AGENTS.md 500-line
# rule). Deployed to /usr/share/vpn-xray/. Sourced by /usr/bin/router-rules
# after lib-common.sh, before the LIB_ONLY guard. Functions only; runs no code.

check_remote_rules_internal() {
	local repo rel branch remote_head message

	repo_configured || {
		message='Git sync is disabled or the repository URL is not configured.'
		set_status_error "$message"
		echo "$message" >&2
		return 1
	}

	repo_bootstrap || {
		set_status_error 'git repository bootstrap failed'
		echo 'Git repository bootstrap failed.' >&2
		return 1
	}
	repo="$(repo_path)"
	rel="$(rules_relpath)"
	branch="$(repo_branch)"

	git_cmd -C "$repo" fetch origin "$branch" >/dev/null 2>&1 || {
		set_status_error 'git fetch failed'
		echo 'Git fetch failed.' >&2
		return 1
	}

	remote_head="$(git_cmd -C "$repo" rev-parse --verify "origin/$branch" 2>/dev/null || true)"
	status_set last_sync_remote_head "$remote_head"
	status_set last_sync_actor "$(sync_actor)"
	if ! git_cmd -C "$repo" show "origin/$branch:$rel" >/dev/null 2>&1; then
		message="Remote rules file not found in origin/$branch: $rel"
		set_status_error "$message"
		echo "$message" >&2
		return 1
	fi

	set_remote_probe_status ok 'Remote rules file is reachable.' "$remote_head" '0'

	return 0
}

quick_remote_probe_internal() {
	local repo branch remote_head current_remote_head rc message update_available probe_out probe_err

	if ! repo_configured; then
		set_remote_probe_status disabled 'Git sync is disabled or the repository URL is not configured.' '' '0'
		return 0
	fi

	repo="$(repo_path)"
	branch="$(repo_branch)"
	rc=0
	probe_out="$(rr_mktemp)"
	probe_err="$(rr_mktemp)"
	git_env_setup
	if run_with_timeout 5 git ls-remote "$(repo_fetch_url)" "refs/heads/${branch}" >"$probe_out" 2>"$probe_err"; then
		remote_head="$(awk 'NR==1 {print $1}' "$probe_out")"
	else
		rc=$?
	fi
	rm -f "$probe_out" "$probe_err"
	if [ "$rc" -ne 0 ]; then
		if [ "$rc" -eq 124 ]; then
			message='Git remote probe timed out after 5 seconds.'
			set_remote_probe_status timeout "$message" '' '0'
		else
			message='Git remote probe failed.'
			set_remote_probe_status error "$message" '' '0'
		fi
		return 1
	fi
	if [ -z "$remote_head" ]; then
		message="Could not determine the remote head for branch ${branch}."
		set_remote_probe_status error "$message" '' '0'
		return 1
	fi

	current_remote_head="$(status_get last_sync_remote_head)"
	[ -n "$current_remote_head" ] || current_remote_head="$(git_cmd -C "$repo" rev-parse --verify "origin/${branch}" 2>/dev/null || true)"
	update_available='0'
	message='No remote update detected.'
	if [ -n "$current_remote_head" ] && [ "$current_remote_head" != "$remote_head" ]; then
		update_available='1'
		message='Remote update is available. Run sync to pull and apply it.'
	fi
	set_remote_probe_status ok "$message" "$remote_head" "$update_available"
	return 0
}

trim_line() {
	printf '%s' "${1:-}" | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

is_comment_or_empty() {
	case "$1" in
		''|\#*)
			return 0
			;;
	esac
	return 1
}

normalized_line() {
	trim_line "$1" | tr 'A-Z' 'a-z'
}

rule_data_stream() {
	local file="$1"
	[ -f "$file" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		line="$(trim_line "$line")"
		is_comment_or_empty "$line" && continue
		printf '%s\n' "$line"
	done < "$file"
}

resolver_candidates() {
	local configured raw file ns

	configured="$(dns_resolver)"
	for raw in $configured; do
		raw="$(trim_line "$raw")"
		[ -n "$raw" ] && printf '%s\n' "$raw"
	done

	for file in /tmp/resolv.conf.auto /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf; do
		[ -f "$file" ] || continue
		sed -n 's/^nameserver[[:space:]]\+//p' "$file" | while IFS= read -r ns || [ -n "$ns" ]; do
			ns="$(trim_line "$ns")"
			[ -n "$ns" ] && printf '%s\n' "$ns"
		done
	done | awk '!seen[$0]++'
}

run_with_timeout() {
	local seconds="$1"
	shift

	if command -v timeout >/dev/null 2>&1; then
		timeout "$seconds" "$@"
	else
		"$@"
	fi
}

python_interpreter() {
	if command -v python3 >/dev/null 2>&1; then
		printf '%s\n' 'python3'
		return 0
	fi
	if command -v python >/dev/null 2>&1; then
		printf '%s\n' 'python'
		return 0
	fi
	return 1
}

resolve_via_dig() {
	local host="$1"
	local resolver="$2"

	command -v dig >/dev/null 2>&1 || return 1
	run_with_timeout 6 dig +short @"$resolver" "$host" A 2>/dev/null \
		| grep -E '^[0-9]+(\.[0-9]+){3}$' \
		| awk '!seen[$0]++'
}

resolve_via_nslookup() {
	local host="$1"
	local resolver="$2"

	command -v nslookup >/dev/null 2>&1 || return 1
	run_with_timeout 6 nslookup "$host" "$resolver" 2>/dev/null \
		| sed -n 's/^Address [0-9]*: //p; s/^Address: //p' \
		| grep -E '^[0-9]+(\.[0-9]+){3}$' \
		| grep -v "^${resolver}$" \
		| awk '!seen[$0]++'
}

resolve_via_resolveip() {
	local host="$1"

	command -v resolveip >/dev/null 2>&1 || return 1
	run_with_timeout 6 resolveip "$host" 2>/dev/null \
		| grep -E '^[0-9]+(\.[0-9]+){3}$' \
		| awk '!seen[$0]++'
}

resolve_via_doh() {
	local host="$1"
	local body=''

	if command -v curl >/dev/null 2>&1; then
		body="$(curl -fsS --max-time 8 --resolve dns.google:443:8.8.8.8 "https://dns.google/resolve?name=${host}&type=A" 2>/dev/null || true)"
		[ -n "$body" ] || body="$(curl -fsS --max-time 8 --resolve dns.google:443:8.8.4.4 "https://dns.google/resolve?name=${host}&type=A" 2>/dev/null || true)"
		[ -n "$body" ] || body="$(curl -fsS --max-time 8 --resolve cloudflare-dns.com:443:1.1.1.1 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=${host}&type=A" 2>/dev/null || true)"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		body="$(run_with_timeout 8 uclient-fetch -qO- "https://dns.google/resolve?name=${host}&type=A" 2>/dev/null || true)"
	elif command -v wget >/dev/null 2>&1; then
		body="$(run_with_timeout 8 wget -qO- "https://dns.google/resolve?name=${host}&type=A" 2>/dev/null || true)"
	fi

	[ -n "$body" ] || return 1
	printf '%s\n' "$body" \
		| tr -d '\r\n' \
		| grep -Eo '"data":"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
		| cut -d '"' -f4 \
		| awk '!seen[$0]++'
}

merge_base_preferred_unique_lines() {
	local base_file="$1"
	local extra_file="$2"
	local out_file="$3"
	local marker="$4"
	local appended_lines

	appended_lines="$(rr_mktemp)"
	cp "$base_file" "$out_file"

	awk '
		function trim(s) {
			sub(/\r$/, "", s)
			sub(/^[[:space:]]+/, "", s)
			sub(/[[:space:]]+$/, "", s)
			return s
		}
		function key_for(raw, trimmed) {
			trimmed = trim(raw)
			if (trimmed == "") {
				return ""
			}
			if (trimmed ~ /^#/) {
				return "comment:" trimmed
			}
			return "rule:" tolower(trimmed)
		}
		FILENAME == ARGV[1] {
			key = key_for($0)
			if (key != "") {
				seen[key] = 1
			}
			next
		}
		{
			line = $0
			sub(/\r$/, "", line)
			key = key_for(line)
			if (key == "") {
				next
			}
			if (!(key in seen) && !(key in emitted)) {
				print line
				emitted[key] = 1
			}
		}
	' "$base_file" "$extra_file" > "$appended_lines"

	if [ -s "$appended_lines" ]; then
		printf '\n%s\n' "$marker" >> "$out_file"
		cat "$appended_lines" >> "$out_file"
	fi

	rm -f "$appended_lines"
}

merge_remote_preferred() {
	local remote_file="$1"
	local local_file="$2"
	local out_file="$3"

	merge_base_preferred_unique_lines \
		"$remote_file" \
		"$local_file" \
		"$out_file" \
		"# merged unique local rules from $(device_id)"
}

merge_local_preferred() {
	local local_file="$1"
	local remote_file="$2"
	local out_file="$3"

	merge_base_preferred_unique_lines \
		"$local_file" \
		"$remote_file" \
		"$out_file" \
		"# merged unique remote rules from origin/$(repo_branch)"
}

tracked_rules_relpaths() {
	local id label url

	printf '%s\n' "$(rules_relpath)"
	while IFS='|' read -r id label url || [ -n "$id" ]; do
		[ -n "$id" ] || continue
		printf '%s\n' "$(external_source_relpath "$id")"
	done <<EOF
$(external_source_catalog)
EOF
}

rules_tree_matches_internal() {
	local left_root="$1"
	local right_root="$2"
	local rel left_file right_file

	while IFS= read -r rel || [ -n "$rel" ]; do
		[ -n "$rel" ] || continue
		left_file="${left_root}/${rel}"
		right_file="${right_root}/${rel}"
		if [ -f "$left_file" ] && [ -f "$right_file" ]; then
			cmp -s "$left_file" "$right_file" 2>/dev/null || return 1
		elif [ -f "$left_file" ] || [ -f "$right_file" ]; then
			return 1
		fi
	done <<EOF
$(tracked_rules_relpaths)
EOF

	return 0
}

snapshot_rules_tree_from_worktree_internal() {
	local repo_root="$1"
	local snapshot_root="$2"
	local rel src dst

	while IFS= read -r rel || [ -n "$rel" ]; do
		[ -n "$rel" ] || continue
		src="${repo_root}/${rel}"
		[ -f "$src" ] || continue
		dst="${snapshot_root}/${rel}"
		mkdir -p "$(dirname "$dst")"
		cp "$src" "$dst"
	done <<EOF
$(tracked_rules_relpaths)
EOF
}

snapshot_rules_tree_from_ref_internal() {
	local repo_root="$1"
	local ref="$2"
	local snapshot_root="$3"
	local rel dst found_main

	found_main=0
	while IFS= read -r rel || [ -n "$rel" ]; do
		[ -n "$rel" ] || continue
		dst="${snapshot_root}/${rel}"
		mkdir -p "$(dirname "$dst")"
		if git_cmd -C "$repo_root" show "${ref}:${rel}" > "$dst" 2>/dev/null; then
			[ "$rel" = "$(rules_relpath)" ] && found_main=1
		else
			rm -f "$dst"
		fi
	done <<EOF
$(tracked_rules_relpaths)
EOF

	[ "$found_main" = '1' ]
}

restore_rules_tree_exact_local_internal() {
	local snapshot_root="$1"
	local repo_root="$2"
	local rel src dst

	while IFS= read -r rel || [ -n "$rel" ]; do
		[ -n "$rel" ] || continue
		src="${snapshot_root}/${rel}"
		dst="${repo_root}/${rel}"
		if [ -f "$src" ]; then
			mkdir -p "$(dirname "$dst")"
			cp "$src" "$dst"
		else
			rm -f "$dst"
		fi
	done <<EOF
$(tracked_rules_relpaths)
EOF
}

restore_missing_rules_tree_from_snapshot_internal() {
	local snapshot_root="$1"
	local repo_root="$2"
	local rel src dst

	while IFS= read -r rel || [ -n "$rel" ]; do
		[ -n "$rel" ] || continue
		src="${snapshot_root}/${rel}"
		dst="${repo_root}/${rel}"
		[ -f "$src" ] || continue
		[ -f "$dst" ] && continue
		mkdir -p "$(dirname "$dst")"
		cp "$src" "$dst"
	done <<EOF
$(tracked_rules_relpaths)
EOF
}

