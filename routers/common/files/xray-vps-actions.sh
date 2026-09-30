#!/bin/sh
# xray-vps-actions.sh — profile/key/inspect/apply request actions
# Deployed to /usr/share/vpn-xray/xray-vps-actions.sh
# Sourced by /www/cgi-bin/xray-vps after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

save_profile_from_request() {
	local current requested_id profile_id label vps_profile auth_mode ssh_host ssh_port ssh_user bootstrap_key managed_key_path

	SAVE_PROFILE_ERROR=''
	SAVE_PROFILE_ID=''

	current="$(active_profile_id)"
	requested_id="$(sanitize_id "$(request_value profile_id)")"
	[ -n "$requested_id" ] || requested_id="$current"
	profile_id="$requested_id"
	label="$(request_value label)"
	vps_profile="$(normalize_vps_profile "$(request_value vps_profile)")"
	auth_mode="$(request_value auth_mode)"
	ssh_host="$(request_value ssh_host)"
	ssh_port="$(request_value ssh_port)"
	ssh_user="$(request_value ssh_user)"
	bootstrap_key="$(request_value bootstrap_private_key)"
	[ -n "$label" ] || label='VPS Profile'
	[ -n "$vps_profile" ] || vps_profile="$(normalize_vps_profile "$(profile_get "$profile_id" vps_profile)")"
	[ -n "$auth_mode" ] || auth_mode="$(profile_get "$profile_id" auth_mode)"
	[ -n "$auth_mode" ] || auth_mode='managed_key'
	[ -n "$ssh_port" ] || ssh_port='22'
	[ -n "$ssh_user" ] || ssh_user='root'
	[ -n "$ssh_host" ] || {
		save_profile_fail 'VPS host / address is required.'
		return 1
	}
	valid_port "$ssh_port" || {
		save_profile_fail 'SSH port must be in the range 1-65535.'
		return 1
	}

	if ! profile_exists "$profile_id"; then
		uci -q set "${PROFILE_PACKAGE}.${profile_id}=profile"
		profile_set "$profile_id" last_inspect_status 'never'
		profile_set "$profile_id" last_inspect_at ''
	fi

	profile_set "$profile_id" label "$label"
	profile_set "$profile_id" vps_profile "$vps_profile"
	profile_set "$profile_id" auth_mode "$auth_mode"
	profile_set "$profile_id" ssh_host "$ssh_host"
	profile_set "$profile_id" ssh_port "$ssh_port"
	profile_set "$profile_id" ssh_user "$ssh_user"
	# The Xray identity is VPS-authoritative (DIAGNOSTIC-TREE 8.1). The
	# Xray address is the SSH host; port/SNI/UUID/keys are never accepted
	# from browser form state and are refreshed by remote inspection.
	profile_set "$profile_id" server_address "$ssh_host"
	managed_key_path="$(profile_get "$profile_id" managed_key_path)"
	[ -n "$managed_key_path" ] || managed_key_path="${KEY_DIR}/${profile_id}_ed25519"
	profile_set "$profile_id" managed_key_path "$managed_key_path"
	profile_set "$profile_id" bootstrap_key_path "${KEY_DIR}/${profile_id}_bootstrap"
	profile_del "$profile_id" ssh_password

	if ! ensure_profile_keypair "$profile_id"; then
		return 1
	fi
	save_bootstrap_key "$profile_id" "$bootstrap_key"
	set_active_profile "$profile_id"
	uci commit "$PROFILE_PACKAGE"
	SAVE_PROFILE_ID="$profile_id"
	printf '%s' "$profile_id"
}

create_profile_action() {
	local base profile_id suffix

	base="vps_$(date +%Y%m%d_%H%M%S)"
	profile_id="$base"
	suffix=1
	while profile_exists "$profile_id"; do
		profile_id="${base}_${suffix}"
		suffix=$((suffix + 1))
	done

	uci -q set "${PROFILE_PACKAGE}.${profile_id}=profile"
	profile_set "$profile_id" label 'New VPS'
	profile_set "$profile_id" vps_profile "$(default_vps_profile)"
	profile_set "$profile_id" auth_mode 'password'
	profile_set "$profile_id" ssh_host ''
	profile_set "$profile_id" ssh_port '22'
	profile_set "$profile_id" ssh_user 'root'
	profile_set "$profile_id" server_address ''
	profile_del "$profile_id" ssh_password
	profile_set "$profile_id" managed_key_path "${KEY_DIR}/${profile_id}_ed25519"
	profile_set "$profile_id" bootstrap_key_path "${KEY_DIR}/${profile_id}_bootstrap"
	profile_set "$profile_id" managed_pubkey ''
	profile_set "$profile_id" last_inspect_status 'never'
	profile_set "$profile_id" last_inspect_at ''
	if ! ensure_profile_keypair "$profile_id"; then
		emit_error create_profile 'Router could not generate profile key pair.'
		return 0
	fi
	set_active_profile "$profile_id"
	uci commit "$PROFILE_PACKAGE"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"create_profile",'
	printf '"created_profile_id":"%s",' "$(json_escape "$profile_id")"
	printf '"status":'
	status_json
	printf '}'
}

save_profile_action() {
	if ! save_profile_from_request >/dev/null; then
		emit_error save_profile "${SAVE_PROFILE_ERROR:-Router could not initialize profile material.}"
		return 0
	fi
	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"save_profile",'
	printf '"status":'
	status_json
	printf '}'
}

ensure_sshpass_available() {
	command -v sshpass >/dev/null 2>&1 && return 0
	with_lock_dir "$LOCK_ROOT/opkg.lock.d" sh -c '
		command -v sshpass >/dev/null 2>&1 && exit 0
		rm -f /var/lock/opkg.lock
		timeout 60 opkg update >/tmp/xray-vps-opkg-update.log 2>&1 || exit 1
		timeout 60 opkg install sshpass >/tmp/xray-vps-opkg-install.log 2>&1 || exit 1
	' >/dev/null 2>&1 || return 1
	command -v sshpass >/dev/null 2>&1
}

install_managed_key_via_current_auth() {
	local profile_id="$1"
	local pub tmp_pub remote_cmd

	pub="$(profile_get "$profile_id" managed_pubkey)"
	tmp_pub="/tmp/xray-managed-key.$$"
	printf '%s\n' "$pub" > "$tmp_pub"
	remote_cmd="sh -c 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; PUB=\$(cat); grep -qxF \"\$PUB\" ~/.ssh/authorized_keys || printf \"%s\n\" \"\$PUB\" >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'"
	ssh_stdin_cmd "$profile_id" "$remote_cmd" "$tmp_pub" >/dev/null 2>&1 || {
		rm -f "$tmp_pub"
		return 1
	}
	rm -f "$tmp_pub"
	profile_set "$profile_id" auth_mode 'managed_key'
	profile_del "$profile_id" ssh_password
	uci commit "$PROFILE_PACKAGE"
	return 0
}

install_managed_key_with_password() {
	local profile_id="$1"
	local host port user password pub tmp_pub

	ensure_sshpass_available || return 1
	host="$(profile_get "$profile_id" ssh_host)"
	port="$(profile_get "$profile_id" ssh_port)"
	user="$(profile_get "$profile_id" ssh_user)"
	password="$(request_value ssh_password)"
	[ -n "$password" ] || password="$(profile_get "$profile_id" ssh_password)"
	pub="$(profile_get "$profile_id" managed_pubkey)"

	[ -n "$host" ] || return 1
	[ -n "$user" ] || user='root'
	[ -n "$port" ] || port='22'
	[ -n "$password" ] || return 1

	tmp_pub="/tmp/xray-managed-key-pass.$$"
	printf '%s\n' "$pub" > "$tmp_pub"
	# DIAGNOSTIC-TREE 5.1: the remote command not only appends the managed
	# key, it also normalizes ownership and mode of the login home,
	# ~/.ssh and authorized_keys. This is essential: after a VPS
	# reprovision the home directory can end up owned by a service user
	# (observed: /root owned by xray:xray, 2026-07-09). With StrictModes
	# on — the sshd default — an authorized_keys that root does not own is
	# silently ignored, so key auth fails no matter how many times the
	# key is re-appended. Re-appending was the entire fix before, which
	# is why "repair with the root password" never actually worked. We do
	# the chown in this same password session because it is the only
	# context where we hold write access without the key that is broken.
	# $HOME is expanded remotely; `id -gn` picks the login user's primary
	# group so we don't hard-code root.
	SSHPASS="$password" sshpass -e ssh \
		-o StrictHostKeyChecking=accept-new \
		-o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o ConnectTimeout=6 \
		-p "$port" \
		"$user@$host" \
		"sh -c 'set -e; umask 077; mkdir -p \"\$HOME/.ssh\"; touch \"\$HOME/.ssh/authorized_keys\"; PUB=\$(cat); grep -qxF \"\$PUB\" \"\$HOME/.ssh/authorized_keys\" || printf \"%s\n\" \"\$PUB\" >> \"\$HOME/.ssh/authorized_keys\"; U=\$(id -un); G=\$(id -gn); chown \"\$U:\$G\" \"\$HOME\" \"\$HOME/.ssh\" \"\$HOME/.ssh/authorized_keys\"; chmod 700 \"\$HOME/.ssh\"; chmod 600 \"\$HOME/.ssh/authorized_keys\"'" \
		< "$tmp_pub" >/dev/null 2>&1 || {
			rm -f "$tmp_pub"
			return 1
		}
	rm -f "$tmp_pub"
	profile_set "$profile_id" auth_mode 'managed_key'
	profile_del "$profile_id" ssh_password
	uci commit "$PROFILE_PACKAGE"
	return 0
}

ensure_ssh_ready() {
	local profile_id="$1"
	local mode

	if ssh_works "$profile_id"; then
		profile_set "$profile_id" auth_mode 'managed_key'
		profile_del "$profile_id" ssh_password
		uci commit "$PROFILE_PACKAGE"
		return 0
	fi

	mode="$(profile_get "$profile_id" auth_mode)"
	case "$mode" in
		password)
			install_managed_key_with_password "$profile_id" || return 1
			;;
		private_key|key)
			install_managed_key_via_current_auth "$profile_id" || return 1
			;;
		managed_key|'')
			return 1
			;;
	esac

	ssh_works "$profile_id"
}

inspect_profile_ready() {
	local profile_id="$1"
	ensure_ssh_ready "$profile_id" || return 1
	refresh_remote_cache "$profile_id"
}

inspect_profile_retry_locked() {
	local profile_id="$1"
	local attempts="$2"
	local delay="$3"
	local try=1

	while [ "$try" -le "$attempts" ]; do
		if inspect_profile_ready "$profile_id"; then
			return 0
		fi
		[ "$try" -lt "$attempts" ] && sleep "$delay"
		try=$((try + 1))
	done
	return 1
}

inspect_profile_with_retry() {
	local profile_id="$1"
	local attempts="${2:-3}"
	local delay="${3:-1}"

	with_lock_dir "$LOCK_ROOT/inspect.lock.d" inspect_profile_retry_locked "$profile_id" "$attempts" "$delay"
}

adopt_remote_into_profile() {
	local profile_id="$1"
	local cache value remote_value

	cache="$(profile_cache_path "$profile_id")"
	for value in server_port server_name uuid public_key short_id flow dial_mode; do
		remote_value="$(cache_get "$cache" "REMOTE_${value}")"
		[ -n "$remote_value" ] && profile_set "$profile_id" "$value" "$remote_value"
	done
	remote_value="$(private_cache_get "$profile_id")"
	[ -n "$remote_value" ] && profile_set "$profile_id" private_key "$remote_value"
	profile_set "$profile_id" last_inspect_status 'ok'
	uci commit "$PROFILE_PACKAGE"
}

prepare_profile_from_vps() {
	local profile_id="$1" cache remote_uuid server_port

	# Every render/write starts with an authoritative remote read. The cache
	# refresh adopts a non-empty VPS identity. Generation is allowed only
	# after that read proves the VPS has no UUID of its own.
	refresh_remote_cache "$profile_id" >/dev/null 2>&1 || return 1
	cache="$(profile_cache_path "$profile_id")"
	remote_uuid="$(cache_get "$cache" REMOTE_uuid)"
	if [ -z "$remote_uuid" ]; then
		profile_set "$profile_id" server_address "$(profile_get "$profile_id" ssh_host)"
		server_port="$(vps_profile_value "$(selected_vps_profile "$profile_id")" XRAY_PORT)"
		profile_set "$profile_id" server_port "${server_port:-443}"
		profile_set "$profile_id" server_name "$(default_server_name_for_profile "$(selected_vps_profile "$profile_id")")"
		ensure_profile_material "$profile_id"
		uci commit "$PROFILE_PACKAGE"
	fi
	return 0
}

adopt_vps_action() {
	local profile_id

	profile_id="$(active_profile_id)"
	if profile_cache_fresh "$profile_id" 120; then
		adopt_remote_into_profile "$profile_id"
		emit_status_response adopt_vps
		return 0
	fi

	if ! inspect_profile_with_retry "$profile_id" 3 1; then
		emit_error adopt_vps 'Router cannot inspect the selected VPS yet.'
		return 0
	fi

	adopt_remote_into_profile "$profile_id"
	emit_status_response adopt_vps
}

select_profile_action() {
	local profile_id

	profile_id="$(sanitize_id "$(request_value profile_id)")"
	if ! profile_exists "$profile_id"; then
		emit_error select_profile 'Profile not found.'
		return 0
	fi

	set_active_profile "$profile_id"
	uci commit "$PROFILE_PACKAGE"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"select_profile",'
	printf '"status":'
	status_json
	printf '}'
}

generate_key_action() {
	local profile_id

	profile_id="$(active_profile_id)"
	if ! ensure_profile_keypair "$profile_id"; then
		emit_error generate_key 'Router could not generate SSH key pair.'
		return 0
	fi
	uci commit "$PROFILE_PACKAGE"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"generate_key",'
	printf '"status":'
	status_json
	printf '}'
}

install_key_action() {
	local profile_id

	profile_id="$(active_profile_id)"
	if ! ensure_profile_keypair "$profile_id"; then
		emit_error install_key 'Router could not prepare SSH key pair.'
		return 0
	fi
	uci commit "$PROFILE_PACKAGE"

	if ! ensure_ssh_ready "$profile_id"; then
		emit_error install_key 'Router could not establish SSH to the selected VPS with the current auth settings.'
		return 0
	fi

	emit_status_response install_key
}

inspect_action() {
	local profile_id

	profile_id="$(active_profile_id)"
	if ! inspect_profile_with_retry "$profile_id" 3 1; then
		emit_error inspect_vps 'Router cannot SSH into the selected VPS yet or remote inspection failed.'
		return 0
	fi

	emit_status_response inspect_vps
}

check_profile_action() {
	local profile_id backup

	backup="$(backup_profile_store)"
	if ! save_profile_from_request >/dev/null; then
		restore_profile_store "$backup"
		emit_error check_profile "${SAVE_PROFILE_ERROR:-Could not save profile settings before inspection.}"
		return 0
	fi
	profile_id="$SAVE_PROFILE_ID"
	if ! inspect_profile_with_retry "$profile_id" 3 1; then
		restore_profile_store "$backup"
		emit_error check_profile 'Router could not establish SSH to the selected VPS with the current auth settings.'
		return 0
	fi

	if [ "$(cache_get "$(profile_cache_path "$profile_id")" REMOTE_XRAY_PRESENT)" = '1' ]; then
		adopt_remote_into_profile "$profile_id"
	fi

	drop_profile_store_backup "$backup"
	emit_status_response check_profile
}
