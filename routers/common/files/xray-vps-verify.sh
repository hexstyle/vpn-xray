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
		-p "$ssh_port" -i "$ssh_key" -L "127.0.0.1:18444:127.0.0.1:${remote_port}" "${ssh_user}@${ssh_host}"; then
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
	/etc/init.d/codex-xray-tunnel stop >/dev/null 2>&1 || true
	if [ "$(profile_get "$profile_id" dial_mode)" != 'ssh_tunnel' ]; then
		rm -f "$ROUTER_TUNNEL_CONFIG"
		return 0
	fi
	tmp="${ROUTER_TUNNEL_CONFIG}.new.$$"
	write_profile_tunnel_config "$profile_id" "$tmp" || return 1
	mv "$tmp" "$ROUTER_TUNNEL_CONFIG"
	/etc/init.d/codex-xray-tunnel start >/dev/null 2>&1 || return 1
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

verify_profile_candidate() {
	local profile_id="$1" cert="$2" base config pidfile old_http old_socks old_access old_error
	local expected egress i url failures code
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
	if ! start-stop-daemon -S -b -m -p "$pidfile" -x "$ROUTER_XRAY_BIN" -- run -config "$config"; then
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
	egress="$(curl -4sS -m 10 --socks5-hostname 127.0.0.1:11884 https://ident.me 2>/dev/null || true)"
	failures=0
	[ "$egress" = "$expected" ] || failures=$((failures + 1))
	i=1
	while [ "$i" -le 6 ]; do
		case $((i % 3)) in 0) url=https://ident.me;; 1) url=https://github.com;; 2) url=https://chatgpt.com;; esac
		curl -4sS -o /dev/null -m 8 --socks5-hostname 127.0.0.1:11884 "$url" 2>/dev/null \
			|| failures=$((failures + 1))
		i=$((i + 1))
	done
	i=1
	while [ "$i" -le 12 ]; do
		case $((i % 3)) in 0) url=https://ident.me;; 1) url=https://github.com;; 2) url=https://chatgpt.com;; esac
		(curl -4sS -o /dev/null -m 10 --socks5-hostname 127.0.0.1:11884 "$url" 2>/dev/null && echo ok || echo fail) > "$base.result.$i" &
		i=$((i + 1))
	done
	wait
	for code in "$base".result.*; do grep -q '^ok$' "$code" || failures=$((failures + 1)); done
	start-stop-daemon -K -p "$pidfile" >/dev/null 2>&1 || true
	stop_candidate_tunnel "$base.tunnel.pid"
	rm -f "$base"*
	[ "$failures" -eq 0 ] || {
		APPLY_ROUTER_ERROR="isolated candidate lost $failures real proxy requests"; return 1;
	}
	return 0
}
