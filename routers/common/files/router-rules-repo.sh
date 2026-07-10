#!/bin/sh
# router-rules-repo.sh — extracted from router-rules (AGENTS.md 500-line
# rule). Deployed to /usr/share/vpn-xray/. Sourced by /usr/bin/router-rules
# after lib-common.sh, before the LIB_ONLY guard. Functions only; runs no code.

file_signature() {
	local file="$1"
	[ -f "$file" ] || {
		printf 'missing\n'
		return 0
	}
	if command -v md5sum >/dev/null 2>&1; then
		md5sum "$file" | awk '{print $1}'
	else
		cksum "$file" | awk '{print $1 ":" $2}'
	fi
}

xray_state_signature() {
	local mode effective_sig
	mode="$(xray_mode)"
	case "$mode" in
		full)
			printf 'full\n'
			return 0
			;;
	esac
	effective_sig="$(file_signature "$(compose_effective_rules_internal)")"
	printf '%s|effective:%s\n' "$mode" "$effective_sig"
}

xray_state_signature_quick_internal() {
	local mode effective_sig current_tracked_sig stored_tracked_sig

	mode="$(xray_mode)"
	case "$mode" in
		full)
			printf 'full\n'
			return 0
			;;
	esac
	current_tracked_sig="$(tracked_rules_signature)"
	stored_tracked_sig="$(cat "$(effective_rules_signature_file)" 2>/dev/null || true)"
	case "$stored_tracked_sig" in
		"${current_tracked_sig}|collapse_skipped:0"|"${current_tracked_sig}|collapse_skipped:1")
			effective_sig="$(file_signature "$(effective_rules_file)")"
			printf '%s|effective:%s\n' "$mode" "$effective_sig"
			return 0
			;;
	esac
	printf '%s|effective:stale:%s\n' "$mode" "$(file_signature "$(repo_rules_path)")"
}

resolved_state_signature() {
	file_signature "$(resolved_file)"
}

lan_ipv4_cidr() {
	local lan_if

	lan_if="$(lan_device)"
	ip -4 route show dev "$lan_if" proto kernel scope link 2>/dev/null | awk 'NR==1 {print $1}'
}

ensure_dirs() {
	mkdir -p "$(repo_path)" "$(repo_rules_tree_path)" "$(repo_rules_tree_path)/external" "$(generated_dir)" "$(dirname "$(ssh_key_path)")"
	touch "$(known_hosts_path)"
	chmod 600 "$(known_hosts_path)"
}

write_git_askpass() {
	local path

	path="$(git_askpass_path)"
	cat > "$path" <<'EOF'
#!/bin/sh
case "$1" in
	*Username*|*username*)
		printf '%s\n' "${ROUTER_RULES_GIT_USERNAME:-git}"
		;;
	*Password*|*password*)
		printf '%s\n' "${ROUTER_RULES_GIT_PASSWORD:-}"
		;;
	*)
		printf '\n'
		;;
esac
EOF
	chmod 700 "$path"
}

git_env_setup() {
	unset GIT_SSH_COMMAND GIT_ASKPASS GIT_TERMINAL_PROMPT ROUTER_RULES_GIT_USERNAME ROUTER_RULES_GIT_PASSWORD

	case "$(git_auth_mode)" in
		ssh)
			if [ -f "$(ssh_key_path)" ]; then
				export GIT_SSH_COMMAND="ssh -i $(ssh_key_path) -o BatchMode=yes -o StrictHostKeyChecking=no"
			fi
			;;
		https)
			export ROUTER_RULES_GIT_USERNAME="$(git_http_username)"
			export ROUTER_RULES_GIT_PASSWORD="$(git_http_password)"
			[ -n "$ROUTER_RULES_GIT_USERNAME" ] || export ROUTER_RULES_GIT_USERNAME='git'
			export GIT_TERMINAL_PROMPT=0
			write_git_askpass
			export GIT_ASKPASS="$(git_askpass_path)"
			;;
	esac
}

git_push_env_setup() {
	local url

	unset GIT_SSH_COMMAND GIT_ASKPASS GIT_TERMINAL_PROMPT ROUTER_RULES_GIT_USERNAME ROUTER_RULES_GIT_PASSWORD
	url="$(repo_push_url)"
	case "$url" in
		git@*|ssh://*)
			if [ -f "$(ssh_key_path)" ]; then
				export GIT_SSH_COMMAND="ssh -i $(ssh_key_path) -o BatchMode=yes -o StrictHostKeyChecking=no"
			fi
			;;
		http://*|https://*)
			export ROUTER_RULES_GIT_USERNAME="$(git_http_username)"
			export ROUTER_RULES_GIT_PASSWORD="$(git_http_password)"
			[ -n "$ROUTER_RULES_GIT_USERNAME" ] || export ROUTER_RULES_GIT_USERNAME='git'
			export GIT_TERMINAL_PROMPT=0
			write_git_askpass
			export GIT_ASKPASS="$(git_askpass_path)"
			;;
	esac
}

git_cmd() {
	git_env_setup
	git "$@"
}

git_push_cmd() {
	git_push_env_setup
	git "$@"
}

repo_is_healthy() {
	local repo="$1"

	[ -d "$repo/.git" ] || return 1
	git_cmd -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
	git_cmd -C "$repo" status --short >/dev/null 2>&1 || return 1
	git_cmd -C "$repo" remote get-url origin >/dev/null 2>&1 || return 1
	return 0
}

repo_bootstrap() {
	local repo branch rel rules_abs preserved_snapshot

	repo="$(repo_path)"
	branch="$(repo_branch)"
	rel="$(rules_relpath)"
	rules_abs="$(repo_rules_path)"
	preserved_snapshot=''

	ensure_dirs
	git_env_setup

	if ! repo_fetch_configured; then
		echo "router-rules is not configured yet; fill router_rules UCI values from local env first" >&2
		return 1
	fi

	if [ -d "$repo" ]; then
		preserved_snapshot="$(rr_mktempd)"
		snapshot_rules_tree_from_worktree_internal "$repo" "$preserved_snapshot"
	fi

	if [ -d "$repo/.git" ]; then
		find "$repo/.git" -name '*.lock' -mmin +5 -delete 2>/dev/null || true
	fi

	if [ -d "$repo/.git" ] && ! repo_is_healthy "$repo"; then
		rm -rf "$repo"
	fi

	if [ ! -d "$repo/.git" ]; then
		rm -rf "$repo"
		if ! git_cmd clone --branch "$branch" --depth=1 "$(repo_fetch_url)" "$repo" >/dev/null 2>&1; then
			mkdir -p "$repo/.git" "$(dirname "$rules_abs")" "$(repo_rules_tree_path)/external"
			git_cmd -C "$repo" init -b "$branch" >/dev/null 2>&1 || return 1
		fi
	fi

	git_cmd -C "$repo" config user.name "$(git_user_name)" || return 1
	git_cmd -C "$repo" config user.email "$(git_user_email)" || return 1
	if git_cmd -C "$repo" remote get-url origin >/dev/null 2>&1; then
		git_cmd -C "$repo" remote set-url origin "$(repo_fetch_url)" || return 1
	else
		git_cmd -C "$repo" remote add origin "$(repo_fetch_url)" || return 1
	fi
	if repo_push_configured; then
		git_cmd -C "$repo" remote set-url --push origin "$(repo_push_url)" || return 1
	else
		git_cmd -C "$repo" config --unset-all remote.origin.pushurl >/dev/null 2>&1 || true
	fi
	mkdir -p "$(dirname "$rules_abs")" "$(repo_rules_tree_path)/external"
	[ -f "$rules_abs" ] || : > "$rules_abs"
	if [ -n "$preserved_snapshot" ] && [ -d "$preserved_snapshot" ]; then
		restore_missing_rules_tree_from_snapshot_internal "$preserved_snapshot" "$repo"
		rm -rf "$preserved_snapshot"
	fi
}

