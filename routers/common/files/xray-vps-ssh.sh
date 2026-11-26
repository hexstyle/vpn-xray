#!/bin/sh
# xray-vps-ssh.sh — SSH identity fan-out, remote exec, profile cache
# Deployed to /usr/share/vpn-xray/xray-vps-ssh.sh
# Sourced by /www/cgi-bin/xray-vps after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

# The detached recovery has 170s of work inside the UI's 180s wait.
# Every blocking transport shares that deadline, including upload and retry.
vps_time_left() {
	local cap="$1" left
	if [ -n "${VPS_JOB_DEADLINE:-}" ]; then
		left=$((VPS_JOB_DEADLINE - $(date +%s)))
		[ "$left" -gt 0 ] || return 1
		[ "$left" -ge "$cap" ] || cap="$left"
	fi
	printf '%s\n' "$cap"
}

vps_run_bounded() {
	local limit
	limit="$(vps_time_left 170)" || return 124
	vx_run_with_timeout "$limit" "$@"
}

# Control/inspection sessions ride the existing Xray tunnel to the VPS's
# loopback when dial_mode=ssh_tunnel. External SSH sessions from the router
# can be throttled or penalised (OpenSSH >=9.8 PerSourcePenalties, ISP
# session policies); the tunnel's localhost path is the control plane that
# is already proven by the data plane.
ssh_control_proxy_opts() {
	local profile_id="$1" host="$2" mode script

	SSH_CONTROL_PROXY_CMD=''
	SSH_CONTROL_HOSTKEY_ALIAS=''
	mode="$(profile_get "$profile_id" dial_mode)"
	[ "$mode" = ssh_tunnel ] || return 0
	script="${XRAY_SSH_CONNECT_PY:-/usr/share/vpn-xray/xray-ssh-connect.py}"
	[ -x "$script" ] || return 0
	command -v python3 >/dev/null 2>&1 || return 0
	netstat -lnt 2>/dev/null | grep -q ':1083 ' || return 0
	SSH_CONTROL_PROXY_CMD="python3 $script %h %p"
	SSH_CONTROL_HOSTKEY_ALIAS="$host"
	return 0
}

# A second identity is safe only after explicit authentication refusal: other
# failures may follow remote execution, so must never replay a mutation.
for_each_identity() {
	local profile_id="$1" callback="$2" arg="$3" managed bootstrap identity used='' rc=1
	SSH_FAILURE_KIND=missing_key
	managed="$(profile_get "$profile_id" managed_key_path)"
	bootstrap="$(profile_get "$profile_id" bootstrap_key_path)"
	for identity in "$managed" "$bootstrap"; do
		[ -n "$identity" ] && [ -f "$identity" ] || continue
		[ "$identity" = "$used" ] && continue
		if "$callback" "$identity" "$arg"; then return 0; else rc=$?; fi
		[ "$SSH_FAILURE_KIND" = auth ] || return "$rc"
		used="$identity"
	done
	return "$rc"
}

ssh_exec_with_identity() {
	local identity="$1" packed="$2" cmd host port user cap
	cmd="$(printf '%s' "$packed" | cut -d '|' -f 1)"
	host="$(printf '%s' "$packed" | cut -d '|' -f 2)"
	port="$(printf '%s' "$packed" | cut -d '|' -f 3)"
	user="$(printf '%s' "$packed" | cut -d '|' -f 4)"
	cap="$(printf '%s' "$packed" | cut -d '|' -f 5)"
	ssh_control_run "${cap:-170}" key "$identity" "$host" "$port" "$user" "$cmd"
}

# Password bootstrap and key RPC share the same bounded native SSH outcome.
ssh_control_run() {
	local cap="$1" auth="$2" identity="$3" host="$4" port="$5" user="$6" cmd="$7"
	local limit err client_log rc=0 started log_level=ERROR auth_phase=unknown last_client_line
	if [ "$auth" = password ]; then
		log_level=DEBUG2
		set -- sshpass -e ssh -o BatchMode=no -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1
	else
		set -- ssh -i "$identity" -o BatchMode=yes
	fi
	if [ -n "${SSH_CONTROL_PROXY_CMD:-}" ]; then
		set -- "$@" -o "ProxyCommand=$SSH_CONTROL_PROXY_CMD" -o "HostKeyAlias=${SSH_CONTROL_HOSTKEY_ALIAS:-$host}"
	fi
	SSH_FAILURE_KIND=''
	limit="$(vps_time_left "${cap:-170}")" || { SSH_FAILURE_KIND=deadline; return 124; }
	err="$(mktemp)" || { SSH_FAILURE_KIND=local; return 1; }
	client_log="$(mktemp)" || { rm -f "$err"; SSH_FAILURE_KIND=local; return 1; }
	chmod 600 "$err" "$client_log" || { rm -f "$err" "$client_log"; SSH_FAILURE_KIND=local; return 1; }
	started="$(date +%s)"
	vx_run_with_timeout "$limit" "$@" \
		-E "$client_log" -o "LogLevel=$log_level" \
		-o ConnectTimeout=6 -o ConnectionAttempts=1 \
		-o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
		-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" \
		-p "$port" "$user@$host" "$cmd" 2>"$err" || rc=$?
	if [ "$auth" = password ]; then
		last_client_line="$(tail -n 1 "$client_log" 2>/dev/null | tr -d '\r')"
		# Missing/failed logging cannot establish a pre-authentication refusal.
		if [ ! -r "$client_log" ] || ! printf '\n' >> "$client_log"; then
			SSH_FAILURE_KIND=local; [ "$rc" -ne 0 ] || rc=1
		elif grep -q '^Authenticated to ' "$client_log"; then
			auth_phase=authenticated
		elif [ "$rc" -eq 5 ] &&
			printf '%s\n' "$last_client_line" | grep -qE '^debug2: input_userauth_info_req: num_prompts [1-9][0-9]*$' &&
			grep -q '^debug2: we sent a password packet, wait for reply' "$client_log" &&
			grep -q '^debug1: Next authentication method: keyboard-interactive' "$client_log"; then
			# sshpass rejected the next prompt before OpenSSH's terminal refusal.
			auth_phase=password_rejected
		fi
	fi
	if [ "$rc" -ne 0 ] && [ "$SSH_FAILURE_KIND" != local ]; then
		SSH_FAILURE_KIND=remote
		# Exit codes overlap remote command results. Only OpenSSH's separate
		# client log can prove refusal before execution; never parse remote stderr
		# (or a server-supplied disconnect reason) as permission to replay.
		if grep -q '^Host key verification failed\.' "$client_log"; then
			SSH_FAILURE_KIND=host_key
		elif [ "$auth_phase" = password_rejected ] || { [ "$auth_phase" != authenticated ] && grep -qE '^[^[:space:]]+@[^[:space:]]+: Permission denied \([^)]*\)\.[[:space:]]*$' "$client_log"; }; then
			SSH_FAILURE_KIND=auth
		elif [ "$rc" -eq 124 ]; then
			SSH_FAILURE_KIND=deadline
		elif [ "$rc" -eq 255 ] && grep -qiE 'timed out|Timeout, server|Connection (reset|closed|refused)|Broken pipe|No route to host|Network is unreachable' "$client_log"; then
			SSH_FAILURE_KIND=transport
		fi
	fi
	if [ -n "${SSH_RAW_LOG_PATH:-}" ]; then
		printf 'OpenSSH client diagnostics:\n' >> "$SSH_RAW_LOG_PATH"
		sed '/^debug[123]:/d; /^Authenticated to /d' "$client_log" | head -c 2048 >> "$SSH_RAW_LOG_PATH"
		printf 'Command/launcher stderr:\n' >> "$SSH_RAW_LOG_PATH"
		head -c 2048 "$err" >> "$SSH_RAW_LOG_PATH"
		printf 'control SSH elapsed=%ss exit=%s kind=%s auth_phase=%s\n' "$(($(date +%s)-started))" "$rc" "${SSH_FAILURE_KIND:-ok}" "$auth_phase" >> "$SSH_RAW_LOG_PATH"
	else
		sed '/^debug[123]:/d; /^Authenticated to /d' "$client_log" | head -c 2048 >&2
		head -c 2048 "$err" >&2
	fi
	rm -f "$err" "$client_log"
	return "$rc"
}

ssh_stdin_with_identity() {
	local identity="$1" packed="$2" remote_cmd stdin_path host port user
	remote_cmd="$(printf '%s' "$packed" | cut -d '|' -f 1)"
	stdin_path="$(printf '%s' "$packed" | cut -d '|' -f 2)"
	host="$(printf '%s' "$packed" | cut -d '|' -f 3)"
	port="$(printf '%s' "$packed" | cut -d '|' -f 4)"
	user="$(printf '%s' "$packed" | cut -d '|' -f 5)"
	ssh_exec_with_identity "$identity" "$remote_cmd|$host|$port|$user|170" < "$stdin_path"
}

ssh_cmd() {
	local profile_id="$1" cmd="$2" cap="${3:-170}" host port user
	host="$(profile_get "$profile_id" ssh_host)"
	port="$(profile_get "$profile_id" ssh_port)"
	user="$(profile_get "$profile_id" ssh_user)"
	[ -n "$host" ] || { SSH_FAILURE_KIND=local; return 1; }
	ssh_control_proxy_opts "$profile_id" "$host"
	for_each_identity "$profile_id" ssh_exec_with_identity "${cmd}|${host}|${port:-22}|${user:-root}|$cap"
}

ssh_stdin_cmd() {
	local profile_id="$1" remote_cmd="$2" stdin_path="$3" host port user
	host="$(profile_get "$profile_id" ssh_host)"
	port="$(profile_get "$profile_id" ssh_port)"
	user="$(profile_get "$profile_id" ssh_user)"
	[ -n "$host" ] || { SSH_FAILURE_KIND=local; return 1; }
	ssh_control_proxy_opts "$profile_id" "$host"
	for_each_identity "$profile_id" ssh_stdin_with_identity "${remote_cmd}|${stdin_path}|${host}|${port:-22}|${user:-root}"
}

# Explicit read-only call site: retain stdin for one fresh retry, publish only
# successful output, and never reset the accepted job's deadline (tree 3.4a).
ssh_read_cmd() {
	local profile_id="$1" cmd="$2" cap="${3:-35}" input output attempt=1 rc=1
	input="$(mktemp)" || return 1
	output="$(mktemp)" || { rm -f "$input"; return 1; }
	chmod 600 "$input" "$output"
	cat > "$input"
	while [ "$attempt" -le 2 ]; do
		if ssh_cmd "$profile_id" "$cmd" "$cap" < "$input" > "$output"; then
			cat "$output"; rm -f "$input" "$output"; return 0
		else rc=$?; fi
		[ "$SSH_FAILURE_KIND" = transport ] && [ "$attempt" -lt 2 ] || break
		[ "$(vps_time_left 8)" = 8 ] || break
		[ -z "${SSH_RAW_LOG_PATH:-}" ] || printf 'read-only SSH retry after transport loss\n' >> "$SSH_RAW_LOG_PATH"
		sleep 1
		attempt=$((attempt + 1))
	done
	rm -f "$input" "$output"
	return "$rc"
}

ssh_works() {
	ssh_read_cmd "$1" 'echo ok' 15 </dev/null >/dev/null 2>&1
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

# Both cache files are one inspection result. Prepare everything before either
# publication, and restore the old pair if either rename fails (set +e safe).
publish_inspection_cache() {
	local id="$1" staged="$2" secret="$3" cache private old_public=0 old_private=0 restored=1
	cache="$(profile_cache_path "$id")"; private="$(profile_private_cache_path "$id")"
	[ ! -e "$cache" ] || old_public=1
	[ ! -e "$private" ] || old_private=1
	if ! (umask 077
		printf '%s' "$secret" > "$private.new.$$" &&
		chmod 600 "$staged" "$private.new.$$" &&
		{ [ "$old_public" = 0 ] || cp -p "$cache" "$cache.old.$$"; } &&
		{ [ "$old_private" = 0 ] || cp -p "$private" "$private.old.$$"; }
	); then
		rm -f "$private.new.$$" "$cache.old.$$" "$private.old.$$"; return 1
	fi
	if mv "$private.new.$$" "$private" && mv "$staged" "$cache"; then
		rm -f "$cache.old.$$" "$private.old.$$"; return 0
	fi
	if [ "$old_public" = 1 ]; then cp -p "$cache.old.$$" "$cache" || restored=0; else rm -f "$cache" || restored=0; fi
	if [ "$old_private" = 1 ]; then cp -p "$private.old.$$" "$private" || restored=0; else rm -f "$private" || restored=0; fi
	# Never leave an uncertain mixed pair available for later adoption.
	[ "$restored" = 1 ] || rm -f "$cache" "$private"
	rm -f "$private.new.$$" "$cache.old.$$" "$private.old.$$"
	return 1
}
