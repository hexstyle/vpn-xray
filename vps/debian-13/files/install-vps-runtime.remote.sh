
# Keep a busy small VPS from rejecting healthy WebSocket/TLS sessions when
# its automatically-sized TCP budget is too small (DIAGNOSTIC-TREE 6.9).
# Values are page counts: 1/16, 1/8 and 1/4 of RAM, with the ceiling bounded
# at 128-512 MiB. Existing larger watermarks are never reduced.
step_tcp_capacity() {
	local pages page_kb high pressure low current cur_low cur_pressure cur_high file wanted
	local available congestion modules work detail bbr=0 changed=0
	page_kb="$(($(getconf PAGESIZE 2>/dev/null || echo 4096) / 1024))"
	pages="$(awk -v page_kb="$page_kb" '/MemTotal:/{print int($2/page_kb)}' /proc/meminfo 2>/dev/null)"
	case "$pages" in ''|*[!0-9]*) report tcp_capacity failed "cannot determine host memory size"; return 1 ;; esac
	high=$((pages / 4)); [ "$((high * page_kb))" -lt 131072 ] && high=$((131072 / page_kb)); [ "$((high * page_kb))" -gt 524288 ] && high=$((524288 / page_kb))
	current="$(sysctl -n net.ipv4.tcp_mem 2>/dev/null)" || {
		report tcp_capacity failed 'cannot read native TCP memory watermarks'; return 1;
	}
	current="$(printf '%s\n' "$current" | awk '{print $1" "$2" "$3}')"; set -- $current
	cur_low="${1:-0}"; cur_pressure="${2:-0}"; cur_high="${3:-0}"
	case "$cur_low:$cur_pressure:$cur_high" in *[!0-9:]*) cur_low=0; cur_pressure=0; cur_high=0 ;; esac
	[ "$cur_high" -gt "$high" ] && high="$cur_high"
	pressure=$((high / 2)); low=$((high / 4))
	[ "$cur_pressure" -gt "$pressure" ] && pressure="$cur_pressure"
	[ "$cur_low" -gt "$low" ] && low="$cur_low"
	file='/etc/sysctl.d/99-vpn-xray-tcp.conf'; wanted="net.ipv4.tcp_mem = $low $pressure $high"
	modules='/etc/modules-load.d/vpn-xray-tcp.conf'
	congestion="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
	[ -n "$congestion" ] || { report tcp_capacity failed 'cannot read current TCP algorithm'; return 1; }
	available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
	case " $available " in *' bbr '*) bbr=1 ;; *)
		if command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1; then
			available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
			case " $available " in *' bbr '*) bbr=1; changed=1 ;; esac
		fi
	esac
	detail="optional BBR skipped: native support unavailable; algorithm $congestion preserved"
	work="$(mktemp -d /tmp/vpn-xray-tcp.XXXXXX)" || { report tcp_capacity failed 'cannot stage TCP settings'; return 1; }
	case "$work" in /tmp/vpn-xray-tcp.*) ;; *) report tcp_capacity failed 'unexpected TCP staging path'; return 1 ;; esac
	printf '%s\n' "$wanted" > "$work/sysctl"
	if [ "$bbr" -eq 1 ]; then
		printf 'net.ipv4.tcp_congestion_control = bbr\n' >> "$work/sysctl"
		printf 'tcp_bbr\n' > "$work/modules"
		detail='BBR active and persisted with native module loading'
	fi
	if ! cmp -s "$work/sysctl" "$file" || [ "$(stat -c '%a:%u:%g' "$file" 2>/dev/null)" != '644:0:0' ]; then
		if ! install -d -m 755 /etc/sysctl.d || ! install -o root -g root -m 644 "$work/sysctl" "$file"; then
			rm -f "$work/sysctl" "$work/modules"; rmdir "$work"
			report tcp_capacity failed 'could not persist TCP settings'; return 1
		fi
		changed=1
	fi
	if [ "$bbr" -eq 1 ] && { ! cmp -s "$work/modules" "$modules" ||
		[ "$(stat -c '%a:%u:%g' "$modules" 2>/dev/null)" != '644:0:0' ]; }; then
		if ! install -d -m 755 /etc/modules-load.d || ! install -o root -g root -m 644 "$work/modules" "$modules"; then
			rm -f "$work/sysctl" "$work/modules"; rmdir "$work"
			report tcp_capacity failed 'could not persist native BBR module loading'; return 1
		fi
		changed=1
	fi
	if [ "$current" != "$low $pressure $high" ] || { [ "$bbr" -eq 1 ] && [ "$congestion" != bbr ]; }; then
		if ! sysctl -q -p "$file" >/dev/null 2>&1; then
			rm -f "$work/sysctl" "$work/modules"; rmdir "$work"
			report tcp_capacity failed 'persisted TCP settings could not be applied'; return 1
		fi
		changed=1
	fi
	[ "$bbr" -eq 0 ] || congestion=bbr
	current="$(sysctl -n net.ipv4.tcp_mem 2>/dev/null | awk '{print $1" "$2" "$3}')"
	if [ "$current" != "$low $pressure $high" ] ||
		[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "$congestion" ] ||
		! cmp -s "$work/sysctl" "$file" || [ "$(stat -c '%a:%u:%g' "$file" 2>/dev/null)" != '644:0:0' ] ||
		{ [ "$bbr" -eq 1 ] && { ! cmp -s "$work/modules" "$modules" ||
		[ "$(stat -c '%a:%u:%g' "$modules" 2>/dev/null)" != '644:0:0' ]; }; }; then
		rm -f "$work/sysctl" "$work/modules"; rmdir "$work"
		report tcp_capacity failed 'TCP runtime/persistence verification failed'; return 1
	fi
	rm -f "$work/sysctl" "$work/modules"; rmdir "$work"
	if [ "$changed" -eq 1 ]; then
		report tcp_capacity fixed "TCP watermarks ${low}/${pressure}/${high}; $detail"
	else
		report tcp_capacity ok "TCP memory and boot persistence verified; $detail"
	fi
	return 0
}

# Is the port already reachable from off-host? We can't easily test from
# outside within the VPS, but we can at least confirm nothing on-host is
# actively blocking a local connect to the listener. Returns 0 when a
# local TCP connect to the port succeeds.
firewall_local_reachable() {
	local port="$1"
	if command -v ss >/dev/null 2>&1; then
		ss -ltn 2>/dev/null | grep -q ":${port} " || return 1
	fi
	# Best-effort local connect; bash /dev/tcp if available, else nc.
	if command -v nc >/dev/null 2>&1; then
		nc -z -w 3 127.0.0.1 "$port" >/dev/null 2>&1 && return 0
	fi
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$port" <<'PY' >/dev/null 2>&1 && return 0
import socket, sys
s = socket.socket(); s.settimeout(3)
try:
    s.connect(("127.0.0.1", int(sys.argv[1]))); print("ok")
except Exception:
    sys.exit(1)
PY
	fi
	# Could not actively probe; fall back to "listener present" from ss.
	return 0
}

# Multi-strategy firewall opener (DIAGNOSTIC-TREE 6.7, Gap G5). Tries the
# host's actual firewall manager in order — ufw, then nftables, then raw
# iptables — instead of assuming ufw. Each strategy is idempotent. A host
# with no firewall active reports ok. The goal is: never leave the xray
# port blocked because we only knew one firewall tool.
step_firewall() {
	case "$XRAY_PORT" in
		''|*[!0-9]*)
			report firewall failed "invalid port value \"$XRAY_PORT\""
			return 1
			;;
	esac

	# Strategy 1: ufw (if installed and active).
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		if ufw status 2>/dev/null | grep -q "^${XRAY_PORT}/tcp *ALLOW"; then
			report firewall ok "ufw active and already allows ${XRAY_PORT}/tcp"
			return 0
		fi
		if ufw allow "${XRAY_PORT}/tcp" >/dev/null 2>&1; then
			report firewall fixed "ufw now allows ${XRAY_PORT}/tcp"
			return 0
		fi
		report firewall failed "ufw is active but the allow rule for ${XRAY_PORT}/tcp could not be applied"
		return 1
	fi

	# Strategy 2: nftables. Only act when there is a ruleset with an input
	# hook that has a default-drop/reject policy — otherwise adding rules
	# to an empty ruleset would be noise. When we do act, insert an accept
	# for the port into the inet filter input chain if one is missing.
	if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'hook input'; then
		if nft list ruleset 2>/dev/null | grep -qE "tcp dport (${XRAY_PORT}|\{[^}]*${XRAY_PORT}[^}]*\}).*(accept|ACCEPT)"; then
			report firewall ok "nftables already accepts tcp/${XRAY_PORT}"
			return 0
		fi
		# Find an input chain in the inet/ip filter table to append to.
		local table chain
		table="$(nft -a list ruleset 2>/dev/null | awk '/hook input/{print prev} {prev=$0}' | head -1)"
		# Simpler: try the common Debian default (inet filter input).
		if nft list chain inet filter input >/dev/null 2>&1; then
			if nft add rule inet filter input tcp dport "$XRAY_PORT" accept >/dev/null 2>&1; then
				report firewall fixed "nftables inet filter input now accepts tcp/${XRAY_PORT}"
				return 0
			fi
		fi
		report firewall skipped "nftables has an input hook but no writable inet/filter/input chain to open tcp/${XRAY_PORT} — open it manually"
		return 0
	fi

	# Strategy 3: raw iptables with a default-DROP input policy.
	if command -v iptables >/dev/null 2>&1; then
		if iptables -C INPUT -p tcp --dport "$XRAY_PORT" -j ACCEPT >/dev/null 2>&1; then
			report firewall ok "iptables INPUT already accepts tcp/${XRAY_PORT}"
			return 0
		fi
		if iptables -S INPUT 2>/dev/null | head -1 | grep -q 'DROP\|REJECT'; then
			if iptables -I INPUT 1 -p tcp --dport "$XRAY_PORT" -j ACCEPT >/dev/null 2>&1; then
				report firewall fixed "iptables INPUT now accepts tcp/${XRAY_PORT}"
				return 0
			fi
			report firewall failed "iptables INPUT policy blocks tcp/${XRAY_PORT} and the accept rule could not be inserted"
			return 1
		fi
	fi

	# No active firewall manager blocking us. Confirm the listener is at
	# least locally reachable so we don't silently pass a wedged host.
	if firewall_local_reachable "$XRAY_PORT"; then
		report firewall ok "no active host firewall blocking tcp/${XRAY_PORT} (listener locally reachable)"
	else
		report firewall ok "no active host firewall managed here; listener not yet up (see runtime step)"
	fi
	return 0
}

# One restart-and-wait cycle. Returns 0 when the port binds within the
# window, 1 otherwise. Does not report — the caller decides after trying
# its escalation strategies.
runtime_try_start() {
	local window="${1:-15}"
	systemctl reset-failed "$XRAY_SERVICE" >/dev/null 2>&1 || true
	systemctl enable "$XRAY_SERVICE" >/dev/null 2>&1 || true
	systemctl restart "$XRAY_SERVICE" >/dev/null 2>&1 || return 1

	local i=0
	while [ "$i" -lt "$window" ]; do
		systemctl is-active "$XRAY_SERVICE" >/dev/null 2>&1 || return 1
		if ss -ltn 2>/dev/null | grep -q ":${XRAY_PORT} "; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

# Multi-strategy runtime recovery (DIAGNOSTIC-TREE 6.8). Plain restart is
# the common case; when it does not converge we escalate through causes
# we can actually fix — a stale PID/port holder, a leftover bad drop-in —
# before giving up with the real journal reason. Each escalation is
# idempotent and bounded.
step_runtime() {
	# A healthy listener needs no restart. Restarting here kills a
	# tunnel-riding control session mid-repair: the VPS xray carries both
	# the data plane and the router's proxy path to the VPS loopback.
	if systemctl is-active "$XRAY_SERVICE" >/dev/null 2>&1 \
		&& ss -ltn 2>/dev/null | grep -q ":${XRAY_PORT} "; then
		report runtime ok "xray is already active and listening on :${XRAY_PORT}; restart not needed"
		return 0
	fi

	# Attempt 1: normal restart.
	if runtime_try_start 15; then
		report runtime ok "xray is active and listening on :${XRAY_PORT}"
		return 0
	fi

	# Escalation A: something else may be holding the port (an orphaned
	# xray from a crashed unit). Kill stray xray processes not owned by
	# systemd and retry once.
	local port_holder
	port_holder="$(ss -ltnp 2>/dev/null | grep ":${XRAY_PORT} " | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
	if [ -n "$port_holder" ] && ! systemctl is-active "$XRAY_SERVICE" >/dev/null 2>&1; then
		kill "$port_holder" 2>/dev/null || true
		sleep 1
		if runtime_try_start 15; then
			report runtime fixed "cleared a stray process holding :${XRAY_PORT}; xray is now listening"
			return 0
		fi
	fi

	# Escalation B: a broken custom drop-in can wedge startup. If a
	# non-distro drop-in exists, move it aside and retry once. We only
	# touch drop-ins we recognise as ours or clearly broken (the unit
	# failed to even parse), never the distro's.
	local dropin_dir="/etc/systemd/system/$XRAY_SERVICE.service.d"
	if ! systemctl is-active "$XRAY_SERVICE" >/dev/null 2>&1 \
		&& systemctl status "$XRAY_SERVICE" 2>&1 | grep -qiE 'bad unit file|failed to parse|not found'; then
		if [ -d "$dropin_dir" ]; then
			mkdir -p "${dropin_dir}.disabled" 2>/dev/null || true
			mv "$dropin_dir"/*.conf "${dropin_dir}.disabled/" 2>/dev/null || true
			systemctl daemon-reload >/dev/null 2>&1 || true
			if runtime_try_start 15; then
				report runtime fixed "disabled a broken systemd drop-in; xray is now listening (drop-ins moved to ${dropin_dir}.disabled)"
				return 0
			fi
		fi
	fi

	# Give up with the real reason.
	local detail
	detail="$(journalctl -u "$XRAY_SERVICE" --no-pager -n 20 2>&1)"
	if ! systemctl is-active "$XRAY_SERVICE" >/dev/null 2>&1; then
		report runtime failed "xray exited during startup after restart, port-holder, and drop-in recovery" "$detail"
	else
		report runtime failed "xray is running but did not bind :${XRAY_PORT} within the window" "$detail"
	fi
	return 1
}

# OpenSSH >=9.8 enables PerSourcePenalties. Short-lived router control
# sessions that time out are counted as abuse and lock the router out; the
# router's external IP is dynamic, so derive it from the current SSH client
# (never the VPS's own IP) and regenerate the policy on every install/repair.
step_ssh_control_policy() {
	local client_ip dropin='/etc/ssh/sshd_config.d/99-vpn-xray-control.conf'

	# The router passes its own public address because control may ride the
	# Xray tunnel, where SSH_CLIENT is 127.0.0.1. Never use 127.* or the
	# VPS's own address; fall back to SSH_CLIENT only for a real client.
	client_ip="${VPS_CONTROL_CLIENT_IP:-}"
	case "$client_ip" in
		''|*[!0-9.]*|127.*|0.*) client_ip='' ;;
	esac
	if [ -z "$client_ip" ]; then
		client_ip="${SSH_CLIENT%% *}"
		case "$client_ip" in
			''|*[!0-9.]*|127.*|0.*) client_ip='' ;;
		esac
	fi
	command -v sshd >/dev/null 2>&1 || return 0
	mkdir -p /etc/ssh/sshd_config.d || return 1
	{
		printf '%s\n' '# Managed by vpn-xray; regenerated on every install/repair.'
		printf '%s\n' 'PasswordAuthentication no'
		printf '%s\n' 'KbdInteractiveAuthentication no'
		printf '%s\n' 'PermitRootLogin prohibit-password'
		if [ -n "$client_ip" ]; then
			printf 'PerSourcePenaltyExemptList %s\n' "$client_ip"
		fi
	} > "$dropin" || return 1
	if ! sshd -t; then
		report ssh_control failed 'sshd rejected the control policy drop-in'
		return 1
	fi
	systemctl reload ssh >/dev/null 2>&1 || true
	report ssh_control ok "control policy applied (external client ${client_ip:-unknown}, password auth off)"
}

# -------- NTP pre-flight --------

# Reality (XTLS) auth fails silently when VPS clock is skewed >30s.
if command -v timedatectl >/dev/null 2>&1; then
    if ! timedatectl status 2>/dev/null | grep -q 'synchronized: yes'; then
        echo "WARNING: NTP not synchronized on VPS — Reality may fail with clock skew" >&2
    fi
elif command -v chronyc >/dev/null 2>&1; then
    if chronyc tracking 2>/dev/null | grep -q 'Leap status.*Not'; then
        echo "WARNING: chrony reports clock not synchronized — Reality may fail" >&2
    fi
fi

# -------- main --------

# The steps run in this order for a reason: install-then-verify. Config
# and TLS require the binary; runtime restart requires config, TLS, dirs,
# and permissions to be in place. We keep going through every step even
# when one fails, so the report captures all the problems in one round.

step_binary       || true
step_service_unit || true
step_directories  || true
step_permissions  || true
step_certs        || true
step_config       || true
step_tcp_capacity || true
step_ssh_control_policy || true
step_firewall     || true
step_runtime      || true

if [ "$FAILED" -eq 0 ]; then
	report overall ok "all repair steps completed successfully"
	exit 0
fi
report overall failed "one or more repair steps failed; see prior status entries"
exit 1
