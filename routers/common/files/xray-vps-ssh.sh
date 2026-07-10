#!/bin/sh
# xray-vps-ssh.sh — SSH identity fan-out, remote exec, profile cache
# Deployed to /usr/share/vpn-xray/xray-vps-ssh.sh
# Sourced by /www/cgi-bin/xray-vps after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

for_each_identity() {
	local profile_id="$1"
	local callback="$2"
	local arg="$3"
	local managed bootstrap identity used=''

	managed="$(profile_get "$profile_id" managed_key_path)"
	bootstrap="$(profile_get "$profile_id" bootstrap_key_path)"

	for identity in "$managed" "$bootstrap"; do
		[ -n "$identity" ] || continue
		[ -f "$identity" ] || continue
		[ "$identity" = "$used" ] && continue
		"$callback" "$identity" "$arg" && return 0
		used="$identity"
	done
	return 1
}

ssh_exec_with_identity() {
	local identity="$1"
	local packed="$2"
	local cmd host port user

	cmd="$(printf '%s' "$packed" | cut -d '|' -f 1)"
	host="$(printf '%s' "$packed" | cut -d '|' -f 2)"
	port="$(printf '%s' "$packed" | cut -d '|' -f 3)"
	user="$(printf '%s' "$packed" | cut -d '|' -f 4)"

	# ConnectionAttempts=3 handles intermittent SYN loss on WiFi repeater
	# uplinks (the GL.iNet apcli0 case). ServerAliveInterval keeps the
	# session alive when the pipeline uploads large files afterwards.
	# When SSH_RAW_LOG_PATH is set (repair pipeline sets it to a file),
	# stderr is appended to that file so the CGI can surface the actual
	# OpenSSH error to the operator instead of hiding it behind a generic
	# error. We can't use an fd here because fcgiwrap keeps fd 3+ busy
	# for its FastCGI protocol channel.
	if [ -n "${SSH_RAW_LOG_PATH:-}" ]; then
		ssh -i "$identity" \
			-o BatchMode=yes \
			-o ConnectTimeout=6 \
			-o ConnectionAttempts=2 \
			-o ServerAliveInterval=15 \
			-o ServerAliveCountMax=4 \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile="$KNOWN_HOSTS" \
			-p "$port" \
			"$user@$host" "$cmd" 2>>"$SSH_RAW_LOG_PATH"
	else
		ssh -i "$identity" \
			-o BatchMode=yes \
			-o ConnectTimeout=6 \
			-o ConnectionAttempts=2 \
			-o ServerAliveInterval=15 \
			-o ServerAliveCountMax=4 \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile="$KNOWN_HOSTS" \
			-p "$port" \
			"$user@$host" "$cmd"
	fi
}

ssh_stdin_with_identity() {
	local identity="$1"
	local packed="$2"
	local remote_cmd stdin_path host port user

	remote_cmd="$(printf '%s' "$packed" | cut -d '|' -f 1)"
	stdin_path="$(printf '%s' "$packed" | cut -d '|' -f 2)"
	host="$(printf '%s' "$packed" | cut -d '|' -f 3)"
	port="$(printf '%s' "$packed" | cut -d '|' -f 4)"
	user="$(printf '%s' "$packed" | cut -d '|' -f 5)"

	if [ -n "${SSH_RAW_LOG_PATH:-}" ]; then
		ssh -i "$identity" \
			-o BatchMode=yes \
			-o ConnectTimeout=6 \
			-o ConnectionAttempts=2 \
			-o ServerAliveInterval=15 \
			-o ServerAliveCountMax=4 \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile="$KNOWN_HOSTS" \
			-p "$port" \
			"$user@$host" "$remote_cmd" < "$stdin_path" 2>>"$SSH_RAW_LOG_PATH"
	else
		ssh -i "$identity" \
			-o BatchMode=yes \
			-o ConnectTimeout=6 \
			-o ConnectionAttempts=2 \
			-o ServerAliveInterval=15 \
			-o ServerAliveCountMax=4 \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile="$KNOWN_HOSTS" \
			-p "$port" \
			"$user@$host" "$remote_cmd" < "$stdin_path"
	fi
}

ssh_cmd() {
	local profile_id="$1"
	local cmd="$2"
	local host port user packed

	host="$(profile_get "$profile_id" ssh_host)"
	port="$(profile_get "$profile_id" ssh_port)"
	user="$(profile_get "$profile_id" ssh_user)"

	[ -n "$host" ] || return 1
	[ -n "$user" ] || user='root'
	[ -n "$port" ] || port='22'
	packed="${cmd}|${host}|${port}|${user}"
	for_each_identity "$profile_id" ssh_exec_with_identity "$packed"
}

ssh_stdin_cmd() {
	local profile_id="$1"
	local remote_cmd="$2"
	local stdin_path="$3"
	local host port user packed

	host="$(profile_get "$profile_id" ssh_host)"
	port="$(profile_get "$profile_id" ssh_port)"
	user="$(profile_get "$profile_id" ssh_user)"

	[ -n "$host" ] || return 1
	[ -n "$user" ] || user='root'
	[ -n "$port" ] || port='22'
	packed="${remote_cmd}|${stdin_path}|${host}|${port}|${user}"
	for_each_identity "$profile_id" ssh_stdin_with_identity "$packed"
}

ssh_works() {
	# Wrapper retry for the WiFi-repeater burst rate-limit (apcli0 on
	# GL.iNet, DIAGNOSTIC-TREE 3.4): a rejected/dropped SYN in a burst
	# looks like a failure, but a spaced retry succeeds. ssh's own
	# ConnectionAttempts handles in-invocation SYN loss; this wrapper
	# handles the "refused after too many recent connects" case. Two
	# attempts with a 2s gap bounds worst-case latency — a broken key
	# returns Permission denied immediately, so only genuine timeouts
	# cost the full ConnectTimeout — while still absorbing a single
	# burst rejection.
	local i=0
	while [ "$i" -lt 2 ]; do
		if ssh_cmd "$1" 'echo ok' >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		[ "$i" -lt 2 ] && sleep 2
	done
	return 1
}

profile_cache_path() {
	printf '%s/%s.env\n' "$INSPECT_DIR" "$1"
}

profile_private_cache_path() {
	printf '%s/%s.private\n' "$INSPECT_DIR" "$1"
}

cache_get() {
	local cache="$1"
	local key="$2"
	[ -f "$cache" ] || return 0
	sed -n "s/^${key}=//p" "$cache" | sed -n '1p'
}

private_cache_get() {
	local profile_id="$1"
	local cache

	cache="$(profile_private_cache_path "$profile_id")"
	[ -f "$cache" ] || return 0
	cat "$cache" 2>/dev/null || true
}

private_cache_set() {
	local profile_id="$1"
	local value="$2"
	local cache

	cache="$(profile_private_cache_path "$profile_id")"
	if [ -n "$value" ]; then
		printf '%s' "$value" > "$cache"
		chmod 600 "$cache"
	else
		rm -f "$cache"
	fi
}

profile_cache_fresh() {
	local profile_id="$1"
	local max_age="${2:-90}"
	local last status now age

	last="$(profile_get "$profile_id" last_inspect_at)"
	status="$(profile_get "$profile_id" last_inspect_status)"
	[ "$status" = 'ok' ] || return 1
	case "$last" in
		''|*[!0-9]*)
			return 1
			;;
	esac
	now="$(now_epoch)"
	age=$((now - last))
	[ "$age" -ge 0 ] || age=999999
	[ "$age" -le "$max_age" ]
}

write_cache() {
	local profile_id="$1"
	local content="$2"
	printf '%s\n' "$content" > "$(profile_cache_path "$profile_id")"
	chmod 600 "$(profile_cache_path "$profile_id")"
}
