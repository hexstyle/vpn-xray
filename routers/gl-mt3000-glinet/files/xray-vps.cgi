#!/bin/sh

set -e

PATH='/usr/sbin:/usr/bin:/sbin:/bin'
PROFILE_PACKAGE='xray_vps'
PROFILE_STATE='main'
PROFILE_DIR='/etc/xray'
KEY_DIR='/etc/xray/ssh-keys'
KNOWN_HOSTS='/etc/xray/known_hosts'
INSPECT_DIR='/etc/xray/vps-inspect'
ROUTER_CONFIG='/etc/xray/codex-xray.json'
ROUTER_READY_FILE='/etc/xray/codex-xray.ready'
ROUTER_XRAY_BIN='/usr/local/bin/codex-xray-core'
ROUTER_HTTP_PORT='1083'
ROUTER_SOCKS_PORT='1084'
ROUTER_ACCESS_LOG='/var/log/xray/codex-xray-access.log'
ROUTER_ERROR_LOG='/var/log/xray/codex-xray-error.log'
VPS_PROFILE_ROOT='/usr/share/vpn-xray/vps'
LOCK_ROOT='/tmp/xray-vps-locks'
SWITCH_SYNC_WAIT_SECONDS='25'
SAVE_PROFILE_ERROR=''
SAVE_PROFILE_ID=''

REQUEST_DATA=''

VX_CONFIG="$ROUTER_CONFIG"
VX_CONFIG_READY="$ROUTER_READY_FILE"
. "${VX_LIB_COMMON:-/usr/share/vpn-xray/lib-common.sh}"

valid_port() {
	local value="$1"

	case "$value" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	[ "$value" -ge 1 ] && [ "$value" -le 65535 ]
}

save_profile_fail() {
	SAVE_PROFILE_ERROR="$1"
	return 1
}

config_value() {
	local expr="$1"
	jsonfilter -i "$ROUTER_CONFIG" -e "$expr" 2>/dev/null | sed -n '1p'
}

router_live_value() {
	local key="$1" _sn
	case "$key" in
		server_address)
			config_value '@.outbounds[0].settings.vnext[0].address'
			;;
		server_port)
			config_value '@.outbounds[0].settings.vnext[0].port'
			;;
		server_name)
			# WS+TLS keeps the SNI in tlsSettings; realitySettings is the legacy
			# path (empty in a WS+TLS config, which read as permanent false drift).
			_sn="$(config_value '@.outbounds[0].streamSettings.tlsSettings.serverName')"
			[ -n "$_sn" ] || _sn="$(config_value '@.outbounds[0].streamSettings.realitySettings.serverName')"
			printf '%s' "$_sn"
			;;
		uuid)
			config_value '@.outbounds[0].settings.vnext[0].users[0].id'
			;;
		public_key)
			config_value '@.outbounds[0].streamSettings.realitySettings.publicKey'
			;;
		short_id)
			config_value '@.outbounds[0].streamSettings.realitySettings.shortId'
			;;
		flow)
			config_value '@.outbounds[0].settings.vnext[0].users[0].flow'
			;;
	esac
}

router_current_json() {
	local ready _rc_sa _rc_sp _rc_sn _rc_snr _rc_uu _rc_pk _rc_si _rc_fl _rc_net _rc_sec
	router_config_ready && ready=1 || ready=0
	eval "$(jsonfilter -i "$ROUTER_CONFIG" \
		-e '_rc_sa=@.outbounds[0].settings.vnext[0].address' \
		-e '_rc_sp=@.outbounds[0].settings.vnext[0].port' \
		-e '_rc_sn=@.outbounds[0].streamSettings.tlsSettings.serverName' \
		-e '_rc_snr=@.outbounds[0].streamSettings.realitySettings.serverName' \
		-e '_rc_uu=@.outbounds[0].settings.vnext[0].users[0].id' \
		-e '_rc_pk=@.outbounds[0].streamSettings.realitySettings.publicKey' \
		-e '_rc_si=@.outbounds[0].streamSettings.realitySettings.shortId' \
		-e '_rc_fl=@.outbounds[0].settings.vnext[0].users[0].flow' \
		-e '_rc_net=@.outbounds[0].streamSettings.network' \
		-e '_rc_sec=@.outbounds[0].streamSettings.security' \
		2>/dev/null)" 2>/dev/null || true
	# serverName lives in tlsSettings for WS+TLS; fall back to the legacy
	# reality field so an unconverted config still reports something.
	[ -n "${_rc_sn:-}" ] || _rc_sn="${_rc_snr:-}"
	printf '{'
	printf '"config_ready":'; json_bool "$ready"; printf ','
	printf '"server_address":"%s",' "$(json_escape "${_rc_sa:-}")"
	printf '"server_port":"%s",' "$(json_escape "${_rc_sp:-}")"
	printf '"server_name":"%s",' "$(json_escape "${_rc_sn:-}")"
	printf '"uuid":"%s",' "$(json_escape "${_rc_uu:-}")"
	printf '"public_key":"%s",' "$(json_escape "${_rc_pk:-}")"
	printf '"short_id":"%s",' "$(json_escape "${_rc_si:-}")"
	printf '"transport_net":"%s",' "$(json_escape "${_rc_net:-}")"
	printf '"transport_sec":"%s",' "$(json_escape "${_rc_sec:-}")"
	printf '"flow":"%s"' "$(json_escape "${_rc_fl:-}")"
	printf '}'
}

router_config_ready() {
	[ -f "$ROUTER_READY_FILE" ] && [ -s "$ROUTER_CONFIG" ] && [ -x "$ROUTER_XRAY_BIN" ]
}

router_path_active() {
	local xpid rpid

	xpid="$(cat /var/run/codex-xray.pid 2>/dev/null || true)"
	rpid="$(cat /var/run/redsocks.pid 2>/dev/null || true)"
	[ -n "$xpid" ] && kill -0 "$xpid" 2>/dev/null || return 1
	[ -n "$rpid" ] && kill -0 "$rpid" 2>/dev/null || return 1
	iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'CODEX_TRANSPROXY' || return 1
	return 0
}

ensure_dirs() {
	mkdir -p "$PROFILE_DIR" "$KEY_DIR" "$INSPECT_DIR" "$LOCK_ROOT"
	touch "/etc/config/${PROFILE_PACKAGE}"
	touch "$KNOWN_HOSTS"
	chmod 600 "$KNOWN_HOSTS"
}

with_lock_dir() {
	local lock_dir="$1"
	local cmd="$2"
	shift 2
	with_flock "${lock_dir%.lock.d}.flock" 60 "$cmd" "$@"
}

# Implementation split into sourced libs (AGENTS.md 500-line rule).
# Each defines functions only and shares this scope; the core helpers
# above and the top-level job-mode/dispatch below stay inline. Call-time
# resolution makes sourcing order immaterial.
. "${VX_VPS_PROFILE_LIB:-/usr/share/vpn-xray/xray-vps-profile.sh}"
. "${VX_VPS_SSH_LIB:-/usr/share/vpn-xray/xray-vps-ssh.sh}"
. "${VX_VPS_RENDER_LIB:-/usr/share/vpn-xray/xray-vps-render.sh}"
. "${VX_VPS_INSPECT_LIB:-/usr/share/vpn-xray/xray-vps-inspect.sh}"
. "${VX_VPS_ACTIONS_LIB:-/usr/share/vpn-xray/xray-vps-actions.sh}"
. "${VX_VPS_SETUP_LIB:-/usr/share/vpn-xray/xray-vps-setup.sh}"
. "${VX_VPS_REPAIR_LIB:-/usr/share/vpn-xray/xray-vps-repair.sh}"

# Internal job mode: a detached re-exec of this CGI (no HTTP context).
# Must sit after all function definitions and before request parsing.
if [ -n "${XRAY_VPS_JOB:-}" ]; then
	case "$XRAY_VPS_JOB" in
		apply_router)
			run_router_apply_job "${XRAY_VPS_JOB_PROFILE:-$(active_profile_id)}"
			exit $?
			;;
	esac
	exit 1
fi

REQUEST_DATA="$(load_request_data)"

case "$(request_value action)" in
	''|status)
		ensure_profile_store_light
		emit_header
		status_json
		;;
	save_profile)
		ensure_profile_store
		save_profile_action
		;;
	select_profile)
		ensure_profile_store
		select_profile_action
		;;
	create_profile)
		ensure_profile_store
		create_profile_action
		;;
	generate_key)
		ensure_profile_store
		generate_key_action
		;;
	install_key)
		ensure_profile_store
		install_key_action
		;;
	inspect_vps)
		ensure_profile_store
		inspect_action
		;;
	check_profile)
		ensure_profile_store
		check_profile_action
		;;
	adopt_vps)
		ensure_profile_store
		adopt_vps_action
		;;
	apply_router)
		ensure_profile_store
		apply_profile_to_router_action
		;;
	setup_vps)
		ensure_profile_store
		setup_vps_action
		;;
	apply_profile)
		ensure_profile_store
		apply_everything_action
		;;
	diagnose_repair)
		ensure_profile_store
		diagnose_repair_action
		;;
	*)
		emit_error "$(request_value action)" 'Unknown action.'
		;;
esac
