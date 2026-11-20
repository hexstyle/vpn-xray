#!/bin/sh
# Isolated pre-cutover verification for a VPS profile (DIAGNOSTIC-TREE 8.2).
# Sourced by xray-vps.cgi; defines functions only.

stop_candidate_tunnel() {
	local pidfile="$1"
	[ -f "$pidfile" ] || return 0
	start-stop-daemon -K -p "$pidfile" >/dev/null 2>&1 || true
	rm -f "$pidfile"
}

tunnel_fields_valid() {
	local host="$1" user="$2" key="$3" address="$4"
	case "$host:$address" in ''|*[!A-Za-z0-9._:-]*) return 1;; esac
	case "$host$address" in *:*) return 1;; esac
	case "$user" in ''|*[!A-Za-z0-9._-]*) return 1;; esac
	case "$key" in /etc/xray/ssh-keys/*) ;; *) return 1;; esac
	case "$key" in *[!A-Za-z0-9._/-]*) return 1;; esac
	return 0
}

start_candidate_tunnel() {
	local profile_id="$1" pidfile="$2" ssh_host ssh_port ssh_user ssh_key remote_port i
	[ "$(profile_get "$profile_id" dial_mode)" = 'ssh_tunnel' ] || return 0
	ssh_host="$(profile_get "$profile_id" ssh_host)"; ssh_port="$(profile_get "$profile_id" ssh_port)"
	ssh_user="$(profile_get "$profile_id" ssh_user)"; ssh_key="$(profile_get "$profile_id" managed_key_path)"
	remote_port="$(profile_get "$profile_id" server_port)"
	case "$ssh_port:$remote_port" in *[!0-9:]*) APPLY_ROUTER_ERROR='invalid SSH-tunnel port'; return 1;; esac
	tunnel_fields_valid "$ssh_host" "$ssh_user" "$ssh_key" "$(profile_get "$profile_id" server_address)" \
		&& [ -s "$ssh_key" ] || {
		APPLY_ROUTER_ERROR='managed SSH coordinates are incomplete for tunnel mode'; return 1;
	}
	if ! start-stop-daemon -S -b -m -p "$pidfile" -x /usr/bin/ssh -- -NT \
		-o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
		-p "$ssh_port" -i "$ssh_key" -L "127.0.0.1:18444:127.0.0.1:${remote_port}" "${ssh_user}@${ssh_host}" 6>&- 8>&- 9>&-; then
		APPLY_ROUTER_ERROR='isolated SSH transport could not be launched'
		return 1
	fi
	i=0
	while [ "$i" -lt 10 ]; do
		netstat -lnt 2>/dev/null | grep -q ':18444 ' && return 0
		i=$((i + 1)); sleep 1
	done
	stop_candidate_tunnel "$pidfile"
	APPLY_ROUTER_ERROR='isolated SSH transport did not start'
	return 1
}

write_profile_tunnel_config() {
	local profile_id="$1" path="$2" address remote_port ssh_host ssh_port ssh_user ssh_key
	address="$(profile_get "$profile_id" server_address)"; remote_port="$(profile_get "$profile_id" server_port)"
	ssh_host="$(profile_get "$profile_id" ssh_host)"; ssh_port="$(profile_get "$profile_id" ssh_port)"
	ssh_user="$(profile_get "$profile_id" ssh_user)"; ssh_key="$(profile_get "$profile_id" managed_key_path)"
	case "$remote_port:$ssh_port" in *[!0-9:]*) APPLY_ROUTER_ERROR='invalid managed SSH-tunnel port'; return 1;; esac
	tunnel_fields_valid "$ssh_host" "$ssh_user" "$ssh_key" "$address" || {
		APPLY_ROUTER_ERROR='unsafe managed SSH-tunnel coordinate'; return 1;
	}
	cat > "$path" <<EOF
DIAL_MODE=ssh_tunnel
SERVER_ADDRESS=$address
REMOTE_PORT=$remote_port
LOCAL_PORT=18443
SSH_HOST=$ssh_host
SSH_PORT=$ssh_port
SSH_USER=$ssh_user
SSH_KEY=$ssh_key
EOF
	chmod 600 "$path"
}

activate_profile_tunnel() {
	local profile_id="$1" i tmp
	vx_run_with_timeout 5 /etc/init.d/codex-xray-tunnel stop >/dev/null 2>&1 || return 1
	if [ "$(profile_get "$profile_id" dial_mode)" != 'ssh_tunnel' ]; then
		rm -f "$ROUTER_TUNNEL_CONFIG"
		return $?
	fi
	tmp="${ROUTER_TUNNEL_CONFIG}.new.$$"
	write_profile_tunnel_config "$profile_id" "$tmp" || return 1
	mv "$tmp" "$ROUTER_TUNNEL_CONFIG" || return 1
	vx_run_with_timeout 5 /etc/init.d/codex-xray-tunnel start >/dev/null 2>&1 || return 1
	i=0
	while [ "$i" -lt 12 ]; do
		netstat -lnt 2>/dev/null | grep -q ':18443 ' && return 0
		i=$((i + 1)); sleep 1
	done
	APPLY_ROUTER_ERROR='managed SSH transport did not become ready'
	return 1
}

restore_profile_tunnel() {
	local backup="$1"
	/etc/init.d/codex-xray-tunnel stop >/dev/null 2>&1 || true
	if [ -n "$backup" ] && [ -f "$backup" ]; then
		cp "$backup" "$ROUTER_TUNNEL_CONFIG"
	else
		rm -f "$ROUTER_TUNNEL_CONFIG"
	fi
	/etc/init.d/codex-xray-tunnel start >/dev/null 2>&1 || true
}

# Fixed public probe URLs only. Never log config, identity, headers or bodies.
# A 200 response whose body times out is still a failed transfer.
profile_probe_request() {
	local port="$1" url="$2" seconds="$3" result="$4" body="${5:-/dev/null}"
	local metrics rc=0 code limit
	limit="$(vps_time_left "$seconds")" || {
		printf '%s curl_exit=124 http=000 bytes=0 error=job deadline exhausted\n' "$url" > "$result"
		return 1
	}
	metrics="$(curl -4sS -m "$limit" --socks5-hostname "127.0.0.1:$port" \
		-o "$body" -w '%{http_code} %{size_download}' "$url" 2> "$result.error")" || rc=$?
	code="${metrics%% *}"
	printf '%s curl_exit=%s http=%s bytes=%s error=%s\n' "$url" "$rc" "$code" "${metrics#* }" \
		"$(head -c 512 "$result.error" | tr '\r\n' '  ')" > "$result"
	rm -f "$result.error"
	[ "$rc" -eq 0 ] || return 1
	case "$code" in 2??|3??) return 0;; *) return 1;; esac
}

verify_profile_candidate() {
	local rc=0
	PROFILE_VERIFY_LOG=''
	APPLY_ROUTER_ERROR='another selected-profile verification is running; retry after it finishes'
	mkdir -p "$LOCK_ROOT"
	exec 8>"$LOCK_ROOT/candidate.flock"
	if ! flock -n 8; then exec 8>&-; return 1; fi
	verify_profile_candidate_locked "$@" || rc=$?
	exec 8>&-
	return "$rc"
}

verify_profile_candidate_locked() {
	local profile_id="$1" cert="$2" base config pidfile old_http old_socks old_access old_error
	local expected egress i url failures pids="" pid
	PROFILE_VERIFY_LOG=""
	APPLY_ROUTER_ERROR=''
	if [ "$(vps_time_left 20)" != 20 ]; then
		APPLY_ROUTER_ERROR='job deadline leaves insufficient time to start candidate verification'
		return 1
	fi
	base="/tmp/codex-xray.candidate.$$"
	config="$base.json"
	pidfile="$base.pid"
	if netstat -lnt 2>/dev/null | grep -Eq ':(11883|11884|18444) '; then
		APPLY_ROUTER_ERROR='candidate verification ports are already in use'
		return 1
	fi
	start_candidate_tunnel "$profile_id" "$base.tunnel.pid" || return 1
	old_http="$ROUTER_HTTP_PORT"; old_socks="$ROUTER_SOCKS_PORT"
	old_access="$ROUTER_ACCESS_LOG"; old_error="$ROUTER_ERROR_LOG"
	ROUTER_HTTP_PORT=11883; ROUTER_SOCKS_PORT=11884
	ROUTER_ACCESS_LOG="$base.access.log"; ROUTER_ERROR_LOG="$base.error.log"
	ROUTER_TUNNEL_PORT_OVERRIDE=18444 render_router_config "$config" "$profile_id"
	ROUTER_HTTP_PORT="$old_http"; ROUTER_SOCKS_PORT="$old_socks"
	ROUTER_ACCESS_LOG="$old_access"; ROUTER_ERROR_LOG="$old_error"
	sed -i \
		-e 's/"listen": "0.0.0.0"/"listen": "127.0.0.1"/' \
		-e "s#/etc/xray/server\.crt#$cert#" "$config"
	"$ROUTER_XRAY_BIN" run -test -config "$config" >/dev/null 2>&1 || {
		APPLY_ROUTER_ERROR='isolated candidate config failed xray validation'; stop_candidate_tunnel "$base.tunnel.pid"; rm -f "$base"*; return 1;
	}
	if ! start-stop-daemon -S -b -m -p "$pidfile" -x "$ROUTER_XRAY_BIN" -- run -config "$config" 6>&- 8>&- 9>&-; then
		APPLY_ROUTER_ERROR='isolated candidate proxy could not be launched'; stop_candidate_tunnel "$base.tunnel.pid"; rm -f "$base"*; return 1
	fi
	i=0
	while [ "$i" -lt 10 ]; do
		netstat -lnt 2>/dev/null | grep -q ':11884 ' && break
		i=$((i + 1)); sleep 1
	done
	if ! netstat -lnt 2>/dev/null | grep -q ':11884 '; then
		APPLY_ROUTER_ERROR='isolated candidate proxy did not start'; start-stop-daemon -K -p "$pidfile" >/dev/null 2>&1 || true; stop_candidate_tunnel "$base.tunnel.pid"; rm -f "$base"*; return 1
	fi
	expected="$(cache_get "$(profile_cache_path "$profile_id")" REMOTE_PUBLIC_IP)"
	[ -n "$expected" ] || expected="$(profile_get "$profile_id" server_address)"
	failures=0
	profile_probe_request 11884 https://ident.me 10 "$base.request.0" "$base.egress" || failures=$((failures + 1))
	egress="$(head -c 128 "$base.egress" 2>/dev/null)"
	[ "$egress" = "$expected" ] || failures=$((failures + 1))
	i=1
	while [ "$i" -le 6 ]; do
		case $((i % 3)) in 0) url=https://ident.me;; 1) url=https://github.com;; 2) url=https://chatgpt.com;; esac
		profile_probe_request 11884 "$url" 8 "$base.request.seq.$i" \
			|| failures=$((failures + 1))
		i=$((i + 1))
	done
	i=1
	while [ "$i" -le 12 ]; do
		case $((i % 3)) in 0) url=https://ident.me;; 1) url=https://github.com;; 2) url=https://chatgpt.com;; esac
		profile_probe_request 11884 "$url" 10 "$base.request.parallel.$i" &
		pids="$pids $!"
		i=$((i + 1))
	done
	for pid in $pids; do wait "$pid" || failures=$((failures + 1)); done
	PROFILE_VERIFY_LOG="$(cat "$base".request.* | head -c 16384)"
	if [ "$egress" != "$expected" ]; then
		PROFILE_VERIFY_LOG="egress did not match selected VPS
$PROFILE_VERIFY_LOG"
	fi
	start-stop-daemon -K -p "$pidfile" >/dev/null 2>&1 || true
	stop_candidate_tunnel "$base.tunnel.pid"
	rm -f "$base"*
	[ "$failures" -eq 0 ] || {
		APPLY_ROUTER_ERROR="isolated candidate lost $failures real proxy requests"; return 1;
	}
	return 0
}

fetch_profile_tls_cert() {
	local profile_id="$1" destination="$2" vps_profile cert_path server_name
	vps_profile="$(selected_vps_profile "$profile_id")"
	cert_path="$(vps_profile_value "$vps_profile" VPS_TLS_CERT_PATH)"
	server_name="$(profile_get "$profile_id" server_name)"
	case "$cert_path" in
		/*) ;;
		*) return 1 ;;
	esac
	case "$cert_path" in *[!A-Za-z0-9_./-]*) return 1 ;; esac
	ssh_read_cmd "$profile_id" "cat '$cert_path'" 15 </dev/null > "$destination" 2>/dev/null || return 1
	[ -s "$destination" ] || return 1
	openssl x509 -in "$destination" -noout -checkhost "$server_name" >/dev/null 2>&1 &&
		openssl x509 -in "$destination" -noout -checkend 0 >/dev/null 2>&1
}

verify_applied_profile_path() {
	local profile_id="$1" expected egress base rc=0
	base="/tmp/codex-xray.applied.$$"
	expected="$(cache_get "$(profile_cache_path "$profile_id")" REMOTE_PUBLIC_IP)"
	[ -n "$expected" ] || expected="$(profile_get "$profile_id" server_address)"
	if ! profile_probe_request "$ROUTER_SOCKS_PORT" https://ident.me 12 "$base.ident" "$base.body"; then
		profile_probe_request "$ROUTER_SOCKS_PORT" https://api.ipify.org 12 "$base.ipify" "$base.body" || rc=1
	fi
	egress="$(head -c 128 "$base.body" 2>/dev/null)"
	if [ "$rc" -ne 0 ] || [ "$egress" != "$expected" ]; then
		APPLY_ROUTER_ERROR='new router path did not return a complete matching VPS egress response'
		rc=1
	elif ! profile_probe_request "$ROUTER_SOCKS_PORT" https://chatgpt.com 15 "$base.chatgpt"; then
		APPLY_ROUTER_ERROR='ChatGPT transfer did not complete with HTTP 2xx/3xx through the new router path'
		rc=1
	fi
	PROFILE_VERIFY_LOG="$PROFILE_VERIFY_LOG
$(cat "$base.ident" "$base.ipify" "$base.chatgpt" 2>/dev/null)"
	rm -f "$base".*
	[ "$rc" -eq 0 ] || return 1
	APPLY_ROUTER_EGRESS="$egress"
}


# Tree 8.2: validate actual server identity, not just a syntactically valid client.
validate_selected_profile() {
	local id="$1" cache key value port path
	cache="$(profile_cache_path "$id")"
	APPLY_ROUTER_ERROR='selected VPS identity, transport or listener does not match inspection'
	for key in server_address server_name uuid server_port; do
		value="$(profile_get "$id" "$key")"
		[ -n "$value" ] || return 1
		case "$value" in *[!A-Za-z0-9._:-]*) return 1;; esac
	done
	port="$(profile_get "$id" server_port)"
	valid_port "$port" || return 1
	[ "$port" = "$(cache_get "$cache" REMOTE_LIVE_PORT)" ] || return 1
	[ "$(profile_get "$id" uuid)" = "$(cache_get "$cache" REMOTE_LIVE_UUID)" ] || return 1
	[ "$(cache_get "$cache" REMOTE_XRAY_SERVICE)" = active ] || return 1
	[ -n "$(cache_get "$cache" REMOTE_LISTENER_PORT)" ] || return 1
	[ "$(cache_get "$cache" REMOTE_TRANSPORT_NET)" = ws ] || return 1
	[ "$(cache_get "$cache" REMOTE_TRANSPORT_SEC)" = tls ] || return 1
	path="$(profile_get "$id" ws_path)"; [ -n "$path" ] || path=/cdn
	[ "$path" = "$(cache_get "$cache" REMOTE_LIVE_WS_PATH)" ] || return 1
	APPLY_ROUTER_ERROR=''
}

local_profile_runtime_ready() {
	local port
	if [ "$(current_switch_state)" = on ]; then
		router_config_ready && router_path_active || return 1
		for port in "$ROUTER_HTTP_PORT" "$ROUTER_SOCKS_PORT" 12345; do
			netstat -lnt 2>/dev/null | grep -q ":$port " || return 1
		done
	else
		# The real hardware-off state must remain off (ASUS always reports on).
		! router_path_active || return 1
		for port in "$ROUTER_HTTP_PORT" "$ROUTER_SOCKS_PORT" 12345; do
			netstat -lnt 2>/dev/null | grep -q ":$port " && return 1
		done
	fi
	curl -4fsS --max-time 3 -o /dev/null http://127.0.0.1/xray.html
}

restart_profile_runtime() {
	vx_run_with_timeout 5 /etc/init.d/codex-transproxy stop >/dev/null 2>&1 6>&- || return 1
	vx_run_with_timeout 5 /etc/init.d/codex-xray stop >/dev/null 2>&1 6>&- || return 1
	resync_runtime_to_switch 6>&- && local_profile_runtime_ready
}

backup_apply_file() {
	if [ -e "$1" ]; then cp -p "$1" "$2" && chmod 600 "$2"; else : > "$2.absent"; fi
}

restore_apply_file() {
	if [ -f "$2.absent" ]; then rm -f "$1"; else cp -p "$2" "$1"; fi
}

rollback_router_profile() {
	local config_backup="$1" cert_backup="$2" tunnel_backup="$3"
	restore_apply_file "$ROUTER_CONFIG" "$config_backup" &&
		restore_apply_file "$ROUTER_CERT" "$cert_backup" &&
		restore_apply_file "$ROUTER_READY_FILE" "$config_backup.ready" &&
		restore_apply_file "$ROUTER_TUNNEL_CONFIG" "$tunnel_backup" || return 1
	vx_run_with_timeout 5 /etc/init.d/codex-xray-tunnel stop >/dev/null 2>&1 6>&- || return 1
	if [ -f "$ROUTER_TUNNEL_CONFIG" ]; then
		vx_run_with_timeout 5 /etc/init.d/codex-xray-tunnel start >/dev/null 2>&1 6>&- || return 1
	fi
	restart_profile_runtime
}

router_apply_message() {
	local message
	case "${APPLY_ROUTER_PHASE:-unknown}" in
		applied) message='Selected configuration applied';;
		unchanged) message='Router configuration unchanged';;
		rolled_back) message='Local runtime failed; previous configuration restored and verified';;
		*) message='Application state unknown; inspect live configuration and runtime';;
	esac
	printf '%s; health=%s%s\n' "$message" "${APPLY_PATH_HEALTH:-unknown}" "${APPLY_ROUTER_ERROR:+: $APPLY_ROUTER_ERROR}" | tr '\n=' '  '
}
