#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
XRAY_UI="$ROOT/routers/gl-mt3000-glinet/files/xray.html"
# xray.html inline CSS/JS extracted to sibling assets (AGENTS.md 500-line
# rule); grep the whole UI implementation set for moved content.
XRAY_UI_IMPL="$XRAY_UI $ROOT/routers/common/files/xray-base.css $ROOT/routers/common/files/xray-components.css $ROOT/routers/common/files/xray-app-1.js $ROOT/routers/common/files/xray-app-2.js $ROOT/routers/common/files/xray-app-3.js $ROOT/routers/common/files/xray-app-4.js $ROOT/routers/common/files/xray-app-5.js $ROOT/routers/common/files/xray-app-6.js $ROOT/routers/common/files/xray-app-7.js"
VPS_CGI="$ROOT/routers/gl-mt3000-glinet/files/xray-vps.cgi"
# xray-vps.cgi sources its logic from shared libs (AGENTS.md 500-line split):
# port validation lives in xray-vps-actions.sh (save_profile_from_request),
# the remote listener probe in xray-vps-inspect.sh. Grep the whole set for
# moved content; the valid_port definition itself stays in the CGI.
VPS_IMPL="$VPS_CGI $ROOT/routers/common/files/xray-vps-actions.sh $ROOT/routers/common/files/xray-vps-inspect.sh $ROOT/routers/common/files/xray-vps-render.sh"
VPS_INSTALL="$ROOT/vps/debian-13/files/install-vps.remote.sh"
ROUTER_INSTALLERS="$ROOT/routers/gl-mt3000-glinet/install-router.sh $ROOT/routers/asus-tuf-ax4200-openwrt/install-router.sh"
VPS_WORKSTATION_INSTALLER="$ROOT/vps/debian-13/install-vps.sh"
ADOPT_VPS_META="$ROOT/common/adopt-vps-meta.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q '<input id="sshPort" type="number"' $XRAY_UI_IMPL \
	|| fail "xray.html must expose SSH port as an editable numeric field"

grep -q '<input id="serverPort" type="number"' $XRAY_UI_IMPL \
	|| fail "xray.html must expose the VPS-derived Xray server port"
grep -q 'serverPortField.readOnly = true' $XRAY_UI_IMPL \
	|| fail "the Xray server port must be read-only because the VPS is authoritative"

grep -q '^valid_port() {$' "$VPS_CGI" \
	|| fail "xray-vps.cgi must validate user-supplied port values"

grep -q 'valid_port "\$ssh_port" || {' $VPS_IMPL \
	|| fail "xray-vps.cgi must reject invalid SSH ports"

grep -q "SSH port must be in the range 1-65535." $VPS_IMPL \
	|| fail "xray-vps.cgi must report an explicit SSH port validation error"

for installer in $ROUTER_INSTALLERS; do
	grep -q 'VPS_SSH_PORT="${VPS_SSH_PORT:-22}"' "$installer" \
		|| fail "$installer must default the VPS SSH port explicitly"
	grep -q 'VPS_SSH_OPTS+=( -p "$VPS_SSH_PORT" )' "$installer" \
		|| fail "$installer must use VPS_SSH_PORT for every direct VPS SSH call"
	grep -q 'xray_vps.default.ssh_port=.*VPS_SSH_PORT' "$installer" \
		|| fail "$installer must persist VPS_SSH_PORT in the bootstrapped UI profile"
done

grep -q 'VPS_SSH_PORT="${VPS_SSH_PORT:-22}"' "$VPS_WORKSTATION_INSTALLER" \
	|| fail "the workstation VPS installer must default VPS_SSH_PORT explicitly"
grep -q -- '-p "$VPS_SSH_PORT"' "$VPS_WORKSTATION_INSTALLER" \
	|| fail "the workstation VPS installer must dial VPS_SSH_PORT for every SSH call"

grep -q 'VPS_SSH_PORT="${VPS_SSH_PORT:-22}"' "$ADOPT_VPS_META" \
	|| fail "adopt-vps-meta.sh must default the VPS SSH port explicitly"
grep -q 'VPS_SSH_OPTS+=( -p "$VPS_SSH_PORT" )' "$ADOPT_VPS_META" \
	|| fail "adopt-vps-meta.sh must read authoritative metadata through VPS_SSH_PORT"

grep -q 'if ! save_profile_from_request >/dev/null; then' $VPS_IMPL \
	|| fail "xray-vps.cgi callers must preserve save_profile validation errors without subshell command substitution"

# listener_port is exposed through the awk-based remote-cache JSON builder
# (REMOTE_LISTENER_PORT -> listener_port), not a standalone printf. Assert
# the field is both collected and mapped into the JSON key.
grep -q 'REMOTE_LISTENER_PORT listener_port' $VPS_IMPL \
	|| fail "xray-vps.cgi must map REMOTE_LISTENER_PORT to the listener_port JSON key in the remote cache"

grep -q 'line REMOTE_LISTENER_PORT "\$listener_port_v"' $VPS_IMPL \
	|| fail "xray-vps.cgi must collect the selected-port listener state (listener_port_v) during remote inspection"

grep -q "EXPECTED_SERVER_PORT='\\\$expected_server_port'" $VPS_IMPL \
	|| fail "xray-vps.cgi must pass the profile's expected Xray port into remote inspection"

grep -q 'listener_target_port="\${remote_server_port:-\${EXPECTED_SERVER_PORT:-443}}"' $VPS_IMPL \
	|| fail "xray-vps.cgi must resolve the inspected listener port from VPS metadata or the selected profile port"

grep -q 'line REMOTE_LISTENER_PORT "\$listener_port_v"' $VPS_IMPL \
	|| fail "xray-vps.cgi must persist the selected-port listener probe result"

# Firewall management is the step_firewall repair step (DIAGNOSTIC-TREE
# 6.7). It is multi-strategy (ufw -> nftables -> iptables) rather than the
# old ufw-only ensure_xray_firewall_port, but must still open the selected
# Xray port and must only touch a firewall that is actually active.
grep -q '^step_firewall() {$' "$VPS_INSTALL" \
	|| fail "install-vps.remote.sh must manage firewall access for the selected Xray port (step_firewall, node 6.7)"

grep -q 'ufw allow "\${XRAY_PORT}/tcp"' "$VPS_INSTALL" \
	|| fail "install-vps.remote.sh step_firewall must open the selected Xray port on ufw"

grep -q "ufw status 2>/dev/null | grep -q '^Status: active'" "$VPS_INSTALL" \
	|| fail "install-vps.remote.sh must only modify UFW when it is active"

grep -q 'ufw allow "\${XRAY_PORT}/tcp"' "$VPS_INSTALL" \
	|| fail "install-vps.remote.sh must allow the selected Xray TCP port through UFW"

printf 'ok\n'
