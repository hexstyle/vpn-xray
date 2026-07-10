#!/bin/sh
# router-rules-config.sh — extracted from router-rules (AGENTS.md 500-line
# rule). Deployed to /usr/share/vpn-xray/. Sourced by /usr/bin/router-rules
# after lib-common.sh, before the LIB_ONLY guard. Functions only; runs no code.

rr_mktemp()  { mktemp /tmp/rr-XXXXXXXX; }
rr_mktempd() { mktemp -d /tmp/rrd-XXXXXXXX; }

status_include_rules_text() {
	[ "${ROUTER_RULES_STATUS_INCLUDE_RULES_TEXT:-1}" = '1' ]
}

is_placeholder_value() {
	case "${1:-}" in
		''|REPLACE_WITH*|CHANGE_ME*|CHANGEME*|YOUR_*)
			return 0
			;;
	esac
	return 1
}

cfg_get() {
	local key="$1"
	local default="$2"
	local value=''

	value="$(uci -q get "${CONFIG_PKG}.${CONFIG_SECTION}.${key}" 2>/dev/null || true)"
	if [ -n "$value" ]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$default"
	fi
}

cfg_has_option() {
	uci -q get "${CONFIG_PKG}.${CONFIG_SECTION}.$1" >/dev/null 2>&1
}

repo_path() { cfg_get repo_path "$DEFAULT_REPO_PATH"; }

repo_origin_url_from_clone() {
	local repo value

	repo="$(repo_path)"
	[ -d "$repo/.git" ] || return 1
	value="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
	[ -n "$value" ] || return 1
	printf '%s\n' "$value"
}

repo_fetch_url() {
	local value rest owner repo

	value="$(cfg_get repo_fetch_url "$DEFAULT_REPO_FETCH_URL")"
	if is_placeholder_value "$value"; then
		value=''
	fi
	if [ -z "$value" ]; then
		value="$(repo_origin_url_from_clone || true)"
	fi
	# When auth mode is ssh, rewrite an HTTPS GitHub URL to its SSH form so
	# `git fetch` actually uses the configured SSH key instead of falling
	# through to anonymous HTTPS readonly. This mirrors what repo_push_url
	# does and lets a single HTTPS URL in install.env work end-to-end once
	# the user opts into SSH auth.
	if [ -n "$value" ] && [ "$(git_auth_mode_raw)" = 'ssh' ]; then
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
}

repo_push_url_raw() { cfg_get repo_push_url "$DEFAULT_REPO_PUSH_URL"; }
repo_branch() { cfg_get repo_branch "$DEFAULT_REPO_BRANCH"; }
rules_relpath() { cfg_get rules_relpath "$DEFAULT_RULES_RELPATH"; }
generated_dir() { cfg_get generated_dir "$DEFAULT_GENERATED_DIR"; }
ssh_key_path() { cfg_get ssh_key_path "$DEFAULT_SSH_KEY_PATH"; }
known_hosts_path() { cfg_get known_hosts_path "$DEFAULT_KNOWN_HOSTS"; }
git_user_name() { cfg_get git_user_name "$DEFAULT_GIT_USER_NAME"; }
git_user_email() { cfg_get git_user_email "$DEFAULT_GIT_USER_EMAIL"; }
dns_resolver() { cfg_get dns_resolver "$DEFAULT_DNS_RESOLVER"; }
device_id() { cfg_get local_device_id "$DEFAULT_DEVICE_ID"; }
enable_push() { cfg_get enable_push "$DEFAULT_ENABLE_PUSH"; }
xray_mode() { cfg_get xray_mode "$DEFAULT_XRAY_MODE"; }
xray_ipset() { cfg_get xray_ipset "$DEFAULT_XRAY_IPSET"; }
xray_dnsmasq_conf() { cfg_get xray_dnsmasq_conf "$DEFAULT_XRAY_DNSMASQ_CONF"; }
xray_dnsmasq_server_conf() { cfg_get xray_dnsmasq_server_conf "$DEFAULT_XRAY_DNSMASQ_SERVER_CONF"; }
sync_interval() { cfg_get sync_interval "$DEFAULT_SYNC_INTERVAL"; }
external_source_interval() { cfg_get external_source_interval "$DEFAULT_EXTERNAL_SOURCE_INTERVAL"; }
rules_backup_dir() { cfg_get rules_backup_dir "$DEFAULT_RULES_BACKUP_DIR"; }
rules_backup_keep() { cfg_get rules_backup_keep "$DEFAULT_RULES_BACKUP_KEEP"; }
pidfile_running() {
	local pidfile="$1"
	local pid=''

	pid="$(cat "$pidfile" 2>/dev/null || true)"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

listen_present() {
	local port="$1"

	netstat -ltnp 2>/dev/null | grep -q ":$port "
}

xray_runtime_healthy() {
	pidfile_running /var/run/codex-xray.pid || return 1
	listen_present 1083 || return 1
	listen_present 1084 || return 1
	return 0
}

transproxy_runtime_healthy() {
	pidfile_running /var/run/redsocks.pid || return 1
	listen_present 12345 || return 1
	iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'CODEX_TRANSPROXY' || return 1
	return 0
}
git_sync_enabled_raw() { cfg_get git_sync_enabled ''; }
git_auth_mode_raw() { cfg_get git_auth_mode "$DEFAULT_GIT_AUTH_MODE"; }
git_http_username() { cfg_get git_http_username "$DEFAULT_GIT_HTTP_USERNAME"; }
git_http_password() { cfg_get git_http_password "$DEFAULT_GIT_HTTP_PASSWORD"; }
git_askpass_path() { cfg_get git_askpass_path "$DEFAULT_GIT_ASKPASS"; }

scripts_dir() {
	printf '%s/%s\n' "$(repo_path)" "$SCRIPTS_DIR_RELPATH"
}

external_source_catalog_from_scripts() {
	local sdir="$1" f id label url
	for f in "$sdir"/*.json; do
		[ -f "$f" ] || continue
		id="$(basename "$f" .json)"
		label="$(jsonfilter -i "$f" -e '@.label' 2>/dev/null || echo "$id")"
		[ -n "$label" ] || label="$id"
		url="$(jsonfilter -i "$f" -e '@.url' 2>/dev/null || true)"
		printf '%s|%s|%s\n' "$id" "$label" "$url"
	done
}

external_source_catalog() {
	local sdir
	sdir="$(scripts_dir)"
	# Read from JSON scripts if available
	if [ -d "$sdir" ] && ls "$sdir"/*.json >/dev/null 2>&1; then
		external_source_catalog_from_scripts "$sdir"
		return 0
	fi
	# Auto-migrate hardcoded catalog to scripts when repo exists
	if [ -d "$(repo_path)" ]; then
		migrate_external_catalog_internal >/dev/null 2>&1 || true
		if [ -d "$sdir" ] && ls "$sdir"/*.json >/dev/null 2>&1; then
			external_source_catalog_from_scripts "$sdir"
			return 0
		fi
	fi
	# First-boot fallback: repo not cloned yet
	cat <<'EOF'
microsoft_service_tags|Microsoft Service Tags|https://www.microsoft.com/en-us/download/details.aspx?id=56519
cloudflare_ipv4|Cloudflare IPv4|https://www.cloudflare.com/ips-v4
google_ipv4|Google IPv4 Ranges|https://www.gstatic.com/ipranges/goog.json
aws_ipv4|AWS IPv4 Ranges|https://ip-ranges.amazonaws.com/ip-ranges.json
EOF
}

external_source_record() {
	local wanted="$1"
	local id label url

	while IFS='|' read -r id label url || [ -n "$id" ]; do
		[ -n "$id" ] || continue
		if [ "$id" = "$wanted" ]; then
			printf '%s|%s|%s\n' "$id" "$label" "$url"
			return 0
		fi
	done <<EOF
$(external_source_catalog)
EOF

	return 1
}

external_source_label() {
	external_source_record "$1" | cut -d '|' -f 2
}

external_source_url_by_id() {
	external_source_record "$1" | cut -d '|' -f 3
}

legacy_external_source_enabled() { cfg_get external_source_enabled "$DEFAULT_EXTERNAL_SOURCE_ENABLED"; }
legacy_external_source_url() { cfg_get external_source_url "$DEFAULT_EXTERNAL_SOURCE_URL"; }

flag_is_enabled() {
	case "${1:-0}" in
		1|true|yes|on)
			return 0
			;;
	esac
	return 1
}

external_source_refresh_enabled() {
	if flag_is_enabled "$(legacy_external_source_enabled)"; then
		printf '1\n'
	else
		printf '0\n'
	fi
}

legacy_external_source_selected() {
	local wanted="$1"
	local url list item oldifs

	url="$(external_source_url_by_id "$wanted" 2>/dev/null || true)"
	[ -n "$url" ] || return 1
	list="$(legacy_external_source_url | sed 's/\\n/\
/g')"
	[ -n "$list" ] || return 1

	oldifs="$IFS"
	IFS='
,	 '
	for item in $list; do
		if [ "$item" = "$url" ]; then
			IFS="$oldifs"
			return 0
		fi
	done
	IFS="$oldifs"
	return 1
}

external_source_enabled_by_id() {
	local id="$1"
	local key raw

	external_source_record "$id" >/dev/null 2>&1 || {
		printf '0\n'
		return 1
	}

	key="external_source_${id}_enabled"
	if cfg_has_option "$key"; then
		raw="$(cfg_get "$key" '0')"
	else
		# No per-source flag stored yet.
		raw='0'
		if [ "$(legacy_external_source_enabled)" = '1' ]; then
			if legacy_external_source_selected "$id" 2>/dev/null; then
				# Migration: source URL was in the legacy URL list
				raw='1'
			elif [ -z "$(legacy_external_source_url)" ]; then
				# Fresh install: global flag on, no legacy URL list
				# → default all sources to enabled
				raw='1'
			fi
		fi
	fi

	case "$raw" in
		1|true|yes|on)
			printf '1\n'
			;;
		*)
			printf '0\n'
			;;
	esac
}

external_source_enabled() {
	external_source_refresh_enabled
}

external_source_interval_seconds() {
	local raw

	raw="$(external_source_interval)"
	case "$raw" in
		''|*[!0-9]*)
			raw="$DEFAULT_EXTERNAL_SOURCE_INTERVAL"
			;;
	esac
	[ "$raw" -ge 3600 ] 2>/dev/null || raw="$DEFAULT_EXTERNAL_SOURCE_INTERVAL"
	printf '%s\n' "$raw"
}

external_source_script() {
	printf '%s\n' "$EXTERNAL_SOURCE_SCRIPT"
}

external_source_timeout() {
	printf '%s\n' "$DEFAULT_EXTERNAL_SOURCE_TIMEOUT"
}

