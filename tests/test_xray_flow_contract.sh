#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_TEMPLATE="$ROOT/routers/gl-mt3000-glinet/files/codex-xray.json.template"
VPS_TEMPLATE="$ROOT/vps/debian-13/files/xray-vps-config.template.json"
VPS_CGI="$ROOT/routers/gl-mt3000-glinet/files/xray-vps.cgi"
ADMIN_CGI="$ROOT/routers/gl-mt3000-glinet/files/xray-admin.cgi"
INSTALL_ROUTER="$ROOT/routers/gl-mt3000-glinet/install-router.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q 'XRAY_USER_FLOW_BLOCK' "$ROUTER_TEMPLATE" \
	|| fail "router Xray template must preserve flow when it is configured"

grep -q 'XRAY_CLIENT_FLOW_BLOCK' "$VPS_TEMPLATE" \
	|| fail "VPS Xray template must preserve flow when it is configured"

grep -q 'user_flow_line' "$VPS_CGI" \
	|| fail "xray-vps.cgi must render flow into the router config when present"

grep -q 'user_flow_line' "$ADMIN_CGI" \
	|| fail "xray-admin.cgi must render flow into manual runtime configs when present"

grep -q 'XRAY_USER_FLOW_BLOCK' "$INSTALL_ROUTER" \
	|| fail "install-router must export the router flow placeholder block"

grep -q 'XRAY_CLIENT_FLOW_BLOCK' "$INSTALL_ROUTER" \
	|| fail "install-router must export the VPS flow placeholder block"

printf 'ok\n'
