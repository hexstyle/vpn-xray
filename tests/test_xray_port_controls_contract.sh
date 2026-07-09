#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
XRAY_UI="$ROOT/routers/gl-mt3000-glinet/files/xray.html"
VPS_CGI="$ROOT/routers/gl-mt3000-glinet/files/xray-vps.cgi"
VPS_INSTALL="$ROOT/vps/debian-13/files/install-vps.remote.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q '<input id="sshPort" type="number"' "$XRAY_UI" \
	|| fail "xray.html must expose SSH port as an editable numeric field"

grep -q '<input id="serverPort" type="number"' "$XRAY_UI" \
	|| fail "xray.html must expose Xray server port as an editable numeric field"

if grep -q '<input id="serverPort".*readonly' "$XRAY_UI"; then
	fail "xray.html must not keep the Xray server port field read-only"
fi

grep -q '^valid_port() {$' "$VPS_CGI" \
	|| fail "xray-vps.cgi must validate user-supplied port values"

grep -q 'valid_port "\$ssh_port" || {' "$VPS_CGI" \
	|| fail "xray-vps.cgi must reject invalid SSH ports"

grep -q 'valid_port "\$server_port" || {' "$VPS_CGI" \
	|| fail "xray-vps.cgi must reject invalid Xray server ports"

grep -q "SSH port must be in the range 1-65535." "$VPS_CGI" \
	|| fail "xray-vps.cgi must report an explicit SSH port validation error"

grep -q "Xray server port must be in the range 1-65535." "$VPS_CGI" \
	|| fail "xray-vps.cgi must report an explicit Xray server port validation error"

grep -q 'if ! save_profile_from_request >/dev/null; then' "$VPS_CGI" \
	|| fail "xray-vps.cgi callers must preserve save_profile validation errors without subshell command substitution"

# listener_port is exposed through the awk-based remote-cache JSON builder
# (REMOTE_LISTENER_PORT -> listener_port), not a standalone printf. Assert
# the field is both collected and mapped into the JSON key.
grep -q 'REMOTE_LISTENER_PORT listener_port' "$VPS_CGI" \
	|| fail "xray-vps.cgi must map REMOTE_LISTENER_PORT to the listener_port JSON key in the remote cache"

grep -q 'line REMOTE_LISTENER_PORT "\$listener_port_v"' "$VPS_CGI" \
	|| fail "xray-vps.cgi must collect the selected-port listener state (listener_port_v) during remote inspection"

grep -q "EXPECTED_SERVER_PORT='\\\$expected_server_port'" "$VPS_CGI" \
	|| fail "xray-vps.cgi must pass the profile's expected Xray port into remote inspection"

grep -q 'listener_target_port="\${remote_server_port:-\${EXPECTED_SERVER_PORT:-443}}"' "$VPS_CGI" \
	|| fail "xray-vps.cgi must resolve the inspected listener port from VPS metadata or the selected profile port"

grep -q 'line REMOTE_LISTENER_PORT "\$listener_port_v"' "$VPS_CGI" \
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
