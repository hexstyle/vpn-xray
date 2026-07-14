#!/bin/sh
# VPS repair / install pipeline. Runs a series of check → fix → verify steps
# and emits one JSON object per step to stdout (JSONL). Each line is:
#   {"id":"binary","status":"ok|fixed|failed","message":"..."}
# If REPAIR_REPORT_PATH is set (a writable file path), each JSON line is also
# appended to that file so that callers can pick up the report even when
# stdout is being consumed by something else. Exit code is 0 when every
# check passes (either ok or fixed) and non-zero when at least one step
# ends in status=failed.
#
# The variables below are templated in by the caller (installer /
# xray-vps CGI) via render_template. Anything using this file must render
# these placeholders before uploading.

set -u

XRAY_BIN='${VPS_XRAY_BINARY}'
XRAY_CONFIG_DIR='${VPS_XRAY_CONFIG_DIR}'
XRAY_CONFIG_PATH='${VPS_XRAY_CONFIG_PATH}'
XRAY_LOG_DIR='${VPS_XRAY_LOG_DIR}'
XRAY_SERVICE='${VPS_XRAY_SERVICE}'
REMOTE_META_PATH='${VPS_REMOTE_META_PATH}'
XRAY_PORT='${XRAY_PORT}'
TLS_CERT_PATH='${VPS_TLS_CERT_PATH}'
TLS_KEY_PATH='${VPS_TLS_KEY_PATH}'
TLS_CN='${XRAY_SERVER_NAME}'

REPORT_PATH="${REPAIR_REPORT_PATH:-}"
FAILED=0

# -------- helpers --------

json_escape() {
	# Escape a shell string for embedding into a JSON string value. Handles
	# the characters that would break the JSON parser (backslash, quote,
	# control chars). Newlines are turned into spaces because our messages
	# are single-line summaries.
	printf '%s' "$1" \
		| sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
		| tr -d '\r' \
		| tr '\n' ' ' \
		| sed -e 's/[[:cntrl:]]/ /g' -e 's/  */ /g' -e 's/ $//'
}

report() {
	# report <id> <status> <message> [<details>]
	local id status message details line
	id="$1"
	status="$2"
	message="$3"
	details="${4:-}"

	if [ -n "$details" ]; then
		line="{\"id\":\"$(json_escape "$id")\",\"status\":\"$status\",\"message\":\"$(json_escape "$message")\",\"details\":\"$(json_escape "$details")\"}"
	else
		line="{\"id\":\"$(json_escape "$id")\",\"status\":\"$status\",\"message\":\"$(json_escape "$message")\"}"
	fi

	printf '%s\n' "$line"
	if [ -n "$REPORT_PATH" ]; then
		printf '%s\n' "$line" >> "$REPORT_PATH" 2>/dev/null || true
	fi

	[ "$status" = 'failed' ] && FAILED=1
	return 0
}

service_user() {
	local user
	user="$(systemctl show -p User --value "$XRAY_SERVICE" 2>/dev/null || true)"
	[ -n "$user" ] || user='root'
	printf '%s\n' "$user"
}

service_group() {
	local user="$1"
	local group
	group="$(systemctl show -p Group --value "$XRAY_SERVICE" 2>/dev/null || true)"
	if [ -z "$group" ]; then
		group="$(id -gn "$user" 2>/dev/null || true)"
	fi
	[ -n "$group" ] || group="$user"
	printf '%s\n' "$group"
}

user_can_write() {
	# Try to have the given user append a byte to the given path. Returns 0
	# when the user can, 1 otherwise. Uses runuser or su -s; if neither
	# exists (barebones systems), assumes chown+chmod is enough and returns
	# 0. This is a best-effort probe, not a hard gate.
	local user="$1"
	local path="$2"
	if command -v runuser >/dev/null 2>&1; then
		runuser -u "$user" -- sh -c ": >> \"$path\"" 2>/dev/null && return 0
		return 1
	fi
	if command -v su >/dev/null 2>&1; then
		su -s /bin/sh "$user" -c ": >> \"$path\"" 2>/dev/null && return 0
		return 1
	fi
	return 0
}

extract_bundled_xray() {
	local bundled='/tmp/xray-bundled.zip'
	[ -f "$bundled" ] || return 1
	mkdir -p /tmp/xray-extract
	rm -rf /tmp/xray-extract/*
	if command -v unzip >/dev/null 2>&1; then
		unzip -oq "$bundled" -d /tmp/xray-extract 2>/dev/null || return 1
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
			"$bundled" /tmp/xray-extract 2>/dev/null || return 1
	else
		return 1
	fi
	[ -f /tmp/xray-extract/xray ] || return 1
	install -m 755 /tmp/xray-extract/xray "$XRAY_BIN" || return 1
	"$XRAY_BIN" version >/dev/null 2>&1 || return 1
	rm -rf /tmp/xray-extract "$bundled"
	return 0
}

create_service_unit() {
	# Emit a minimal, functional systemd unit. Existing drop-ins (User=xray
	# etc.) still apply via /etc/systemd/system/xray.service.d/. If the
	# distro package will later reinstall its own unit, that also fine —
	# ours is not marked with any [Install] Alias.
	cat > "/etc/systemd/system/$XRAY_SERVICE.service" <<UNIT
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG_PATH
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
UNIT
	systemctl daemon-reload >/dev/null 2>&1 || true
}

# -------- cleanup trap --------

_cleanup_tmp() { rm -f /tmp/codex-router-vps-config.json /tmp/codex-router-meta.env; }
trap _cleanup_tmp EXIT

# -------- steps --------

step_binary() {
	if [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version >/dev/null 2>&1; then
		report binary ok "xray binary is present and runnable"
		return 0
	fi

	if extract_bundled_xray; then
		report binary fixed "installed xray from bundled archive"
		return 0
	fi

	# Last-resort: try official install script if the VPS has internet.
	# TODO: pin _install_url to a known-good commit hash, e.g.:
	#   https://github.com/XTLS/Xray-install/raw/<commit>/install-release.sh
	# The sha256 printed below helps identify the exact version that ran.
	local _install_url='https://github.com/XTLS/Xray-install/raw/main/install-release.sh'
	local tmp='/tmp/install-xray-fallback.sh'
	if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL "$_install_url" -o "$tmp" 2>/dev/null || rm -f "$tmp"
		else
			wget -qO "$tmp" "$_install_url" 2>/dev/null || rm -f "$tmp"
		fi
		if [ -s "$tmp" ]; then
			echo "install-release.sh sha256: $(sha256sum "$tmp" | cut -d' ' -f1)" >&2
			bash "$tmp" install >/dev/null 2>&1
			rm -f "$tmp"
		fi
	fi
	if [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version >/dev/null 2>&1; then
		report binary fixed "installed xray via network fallback"
		return 0
	fi

	report binary failed "xray binary missing and neither the bundled archive nor the network installer worked"
	return 1
}

step_service_unit() {
	local unit="/etc/systemd/system/$XRAY_SERVICE.service"
	if [ -f "$unit" ]; then
		report service_unit ok "systemd unit present at $unit"
		return 0
	fi

	create_service_unit
	if [ -f "$unit" ]; then
		report service_unit fixed "created systemd unit at $unit"
		return 0
	fi

	report service_unit failed "cannot create systemd unit at $unit"
	return 1
}

step_directories() {
	local user group
	user="$(service_user)"
	group="$(service_group "$user")"

	install -d -m 750 "$XRAY_CONFIG_DIR" 2>/dev/null || {
		report directories failed "cannot create $XRAY_CONFIG_DIR"
		return 1
	}
	install -d -m 750 "$XRAY_LOG_DIR" 2>/dev/null || {
		report directories failed "cannot create $XRAY_LOG_DIR"
		return 1
	}
	chown "$user:$group" "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR" 2>/dev/null || true
	chmod 750 "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR" 2>/dev/null || true

	report directories ok "config and log dirs owned by $user:$group"
	return 0
}

step_permissions() {
	local user group total fixed misowned f owner
	user="$(service_user)"
	group="$(service_group "$user")"
	total=0
	fixed=0
	misowned=0

	touch "$XRAY_LOG_DIR/access.log" "$XRAY_LOG_DIR/error.log" 2>/dev/null || true

	# stat -c is GNU coreutils; fall back to BusyBox if that fails.
	for f in "$XRAY_LOG_DIR"/access.log "$XRAY_LOG_DIR"/error.log \
		"$XRAY_LOG_DIR"/access.log.* "$XRAY_LOG_DIR"/error.log.* \
		"$XRAY_LOG_DIR"/*.gz; do
		[ -f "$f" ] || continue
		total=$((total + 1))
		owner="$(stat -c '%U:%G' "$f" 2>/dev/null || stat -f '%Su:%Sg' "$f" 2>/dev/null || echo '?:?')"
		if [ "$owner" != "$user:$group" ]; then
			misowned=$((misowned + 1))
			chown "$user:$group" "$f" 2>/dev/null && fixed=$((fixed + 1))
		fi
		chmod 640 "$f" 2>/dev/null || true
	done

	if ! user_can_write "$user" "$XRAY_LOG_DIR/error.log"; then
		report permissions failed "service user $user still cannot write $XRAY_LOG_DIR/error.log after chown"
		return 1
	fi

	if [ "$misowned" -gt 0 ] && [ "$fixed" -eq "$misowned" ]; then
		report permissions fixed "chowned $fixed of $total log files to $user:$group"
		return 0
	fi
	if [ "$misowned" -gt 0 ]; then
		report permissions failed "$misowned log files had the wrong owner and only $fixed could be fixed"
		return 1
	fi
	report permissions ok "$total log files owned by $user:$group"
	return 0
}

step_certs() {
	local user group cert_dir
	user="$(service_user)"
	group="$(service_group "$user")"

	# CRITICAL GUARD (root cause of the 2026-07-09 /root ownership
	# corruption): if TLS_CERT_PATH is empty or not absolute, dirname
	# yields "." and the `chown -R "$user:$group" "$cert_dir"` below would
	# recursively chown the *current working directory* — which, when the
	# repair runs over SSH as root, is /root. That silently reassigned
	# /root to xray:xray and, with sshd StrictModes, broke key auth on
	# every run (DIAGNOSTIC-TREE 5.1b). Never operate on a non-absolute
	# cert path. A missing path is a render/profile gap, not something to
	# "fix" by chowning the CWD.
	case "$TLS_CERT_PATH" in
		/*) : ;;
		*)
			report certs skipped "TLS cert path is empty or not absolute (\"$TLS_CERT_PATH\"); refusing to touch the filesystem — fix the VPS profile's VPS_TLS_CERT_PATH"
			return 0
			;;
	esac
	cert_dir="$(dirname "$TLS_CERT_PATH")"

	install -d -m 750 "$cert_dir" 2>/dev/null || {
		report certs failed "cannot create certificate directory $cert_dir"
		return 1
	}

	if [ -s "$TLS_CERT_PATH" ] && [ -s "$TLS_KEY_PATH" ]; then
		chmod 640 "$TLS_CERT_PATH" 2>/dev/null || true
		chmod 600 "$TLS_KEY_PATH" 2>/dev/null || true
		chown -R "$user:$group" "$cert_dir" 2>/dev/null || true
		report certs ok "TLS cert and key present at $cert_dir"
		return 0
	fi

	# Certs missing. We can only generate a new one if TLS_CN is set — an
	# empty CN produces an unusable cert. Refuse rather than emitting a
	# broken failure.
	if [ -z "$TLS_CN" ]; then
		report certs skipped "TLS cert missing and no CN available from the router profile; existing cert (if any) is left untouched"
		return 0
	fi

	if ! command -v openssl >/dev/null 2>&1; then
		if command -v apt-get >/dev/null 2>&1; then
			apt-get update -qq >/dev/null 2>&1 || true
			apt-get install -y -qq openssl >/dev/null 2>&1 || true
		fi
	fi
	if ! command -v openssl >/dev/null 2>&1; then
		report certs failed "openssl is not installed and cannot be installed automatically"
		return 1
	fi

	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
		-keyout "$TLS_KEY_PATH" -out "$TLS_CERT_PATH" \
		-subj "/CN=$TLS_CN" \
		-addext "subjectAltName=DNS:$TLS_CN" >/dev/null 2>&1 || {
		report certs failed "openssl failed to generate a self-signed cert for CN=$TLS_CN"
		return 1
	}
	chmod 640 "$TLS_CERT_PATH" 2>/dev/null || true
	chmod 600 "$TLS_KEY_PATH" 2>/dev/null || true
	chown -R "$user:$group" "$cert_dir" 2>/dev/null || true
	report certs fixed "generated self-signed TLS cert for CN=$TLS_CN"
	return 0
}

step_config() {
	local user group staged existing_ok=0
	user="$(service_user)"
	group="$(service_group "$user")"
	staged='/tmp/codex-router-vps-config.json'

	# Is the currently-deployed config valid on its own? If so we treat
	# it as the source of truth when the staged config is missing or
	# invalid, rather than reporting a fake "config failed" that would
	# scare the operator into overwriting a working setup.
	if [ -s "$XRAY_CONFIG_PATH" ] && "$XRAY_BIN" run -test -config "$XRAY_CONFIG_PATH" >/dev/null 2>&1; then
		existing_ok=1
	fi

	if [ ! -f "$staged" ]; then
		if [ "$existing_ok" = '1' ]; then
			report config ok "no new config staged; existing $XRAY_CONFIG_PATH is valid"
			return 0
		fi
		report config failed "no config staged at $staged and existing $XRAY_CONFIG_PATH is missing or invalid"
		return 1
	fi

	# Reject a staged config that still contains an unsubstituted
	# dollar-brace template placeholder. It passes `xray -test` (a
	# placeholder is a valid string literal) but silently breaks the
	# tunnel — e.g. a WS path left as the literal placeholder instead of
	# the real /cdn. A render bug must never overwrite a working config
	# (DIAGNOSTIC-TREE 8.3).
	if grep -q '[$][{][A-Z_][A-Z0-9_]*[}]' "$staged"; then
		if [ "$existing_ok" = '1' ]; then
			report config skipped "staged config has unsubstituted template placeholders (render bug); existing $XRAY_CONFIG_PATH is valid and left in place"
			return 0
		fi
		report config failed "staged config has unsubstituted template placeholders and no valid config already deployed"
		return 1
	fi

	if ! "$XRAY_BIN" run -test -config "$staged" >/dev/null 2>&1; then
		if [ "$existing_ok" = '1' ]; then
			report config skipped "staged config failed validation (likely incomplete router profile); existing $XRAY_CONFIG_PATH is valid and left in place"
			return 0
		fi
		report config failed "staged config $staged failed xray -test validation and no valid config already deployed"
		return 1
	fi

	if [ -f "$XRAY_CONFIG_PATH" ]; then
		# Keep the previous config as a rollback point.
		cp "$XRAY_CONFIG_PATH" "$XRAY_CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
	fi
	cat "$staged" > "$XRAY_CONFIG_PATH" || {
		report config failed "cannot write $XRAY_CONFIG_PATH"
		return 1
	}
	chown "$user:$group" "$XRAY_CONFIG_PATH" 2>/dev/null || true
	chmod 640 "$XRAY_CONFIG_PATH" 2>/dev/null || true

	if [ -f /tmp/codex-router-meta.env ]; then
		cat /tmp/codex-router-meta.env > "$REMOTE_META_PATH" 2>/dev/null || true
		chmod 600 "$REMOTE_META_PATH" 2>/dev/null || true
	fi

	report config fixed "installed staged xray config to $XRAY_CONFIG_PATH"
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
	local dropin_dir="/etc/systemd/system/${XRAY_SERVICE}.service.d"
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
step_firewall     || true
step_runtime      || true

if [ "$FAILED" -eq 0 ]; then
	report overall ok "all repair steps completed successfully"
	exit 0
fi
report overall failed "one or more repair steps failed; see prior status entries"
exit 1

