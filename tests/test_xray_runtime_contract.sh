#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ADMIN_CGI="$ROOT/routers/gl-mt3000-glinet/files/xray-admin.cgi"
VPS_CGI="$ROOT/routers/gl-mt3000-glinet/files/xray-vps.cgi"
XRAY_INIT="$ROOT/routers/gl-mt3000-glinet/files/codex-xray.init"
TRANSPROXY_INIT="$ROOT/routers/gl-mt3000-glinet/files/codex-transproxy.init"
INSTALL_PLATFORM="$ROOT/routers/gl-mt3000-glinet/install-platform.sh"
XRAY_UI="$ROOT/routers/gl-mt3000-glinet/files/xray.html"
ROUTER_RULES="$ROOT/routers/common/files/router-rules"
SWITCH_HELPER="$ROOT/routers/gl-mt3000-glinet/files/gl-switch-xray.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q 'runtime_path_active()' "$ADMIN_CGI" \
	|| fail "xray-admin.cgi must expose an explicit runtime path health check"

grep -q '/etc/gl-switch.d/xray.sh "\$switch_state" >/dev/null 2>&1 || return 1' "$ADMIN_CGI" \
	|| fail "xray-admin.cgi must not swallow switch-sync failures"

grep -q "path_state='degraded'" "$ADMIN_CGI" \
	|| fail "xray-admin.cgi must mark runtime as degraded when smoke health says the path is broken"

grep -q '"path_effective":' "$ADMIN_CGI" \
	|| fail "xray-admin.cgi must expose whether the active runtime is still effective after smoke checks"

grep -q 'router_path_active()' "$VPS_CGI" \
	|| fail "xray-vps.cgi must expose an explicit router path health check"

grep -q 'resync_runtime_to_switch || return 1' "$VPS_CGI" \
	|| fail "xray-vps.cgi must fail apply_profile when runtime does not come back"

grep -q '"sniffing": {' "$VPS_CGI" \
	|| fail "xray-vps.cgi must preserve inbound sniffing when it renders router configs from saved VPS profiles"

grep -q 'LOCAL_MANGLE_CHAIN="CODEX_XRAY_LOCAL"' "$XRAY_INIT" \
	|| fail "codex-xray.init must manage a dedicated local mangle chain for Xray server traffic"

grep -q -- '--clamp-mss-to-pmtu' "$XRAY_INIT" \
	|| fail "codex-xray.init must clamp MSS for router-local Xray traffic to the VPS"

grep -q 'path_requested()' "$XRAY_INIT" \
	|| fail "codex-xray.init must gate boot startup behind switch/config readiness"

grep -q 'path_requested || return 0' "$XRAY_INIT" \
	|| fail "codex-xray.init must no-op when boot startup is not requested"

grep -q '"sniffing": {' "$ROOT/routers/gl-mt3000-glinet/files/codex-xray.json.template" \
	|| fail "codex-xray.json template must enable sniffing so transparent traffic can recover hostnames from TLS/HTTP metadata"

grep -q '"destOverride": \[' "$ROOT/routers/gl-mt3000-glinet/files/codex-xray.json.template" \
	|| fail "codex-xray.json template must override HTTP/TLS destinations for transparent traffic"

grep -q 'path_requested()' "$TRANSPROXY_INIT" \
	|| fail "codex-transproxy.init must gate boot startup behind switch/config readiness"

grep -q 'path_requested || return 0' "$TRANSPROXY_INIT" \
	|| fail "codex-transproxy.init must no-op when boot startup is not requested"

grep -q 'wait_for_xray_runtime()' "$TRANSPROXY_INIT" \
	|| fail "codex-transproxy.init must wait for Xray listeners before keeping transproxy enabled"

grep -q '/etc/init.d/codex-xray stop >/dev/null 2>&1 || true' "$TRANSPROXY_INIT" \
	|| fail "codex-transproxy.init must roll back codex-xray when the runtime never becomes ready"

grep -q 'ROUTER_RULES_USE_CACHED_RESOLVED=1 /usr/bin/router-rules build-xray-ipset' "$TRANSPROXY_INIT" \
	|| fail "codex-transproxy.init must restore selective ipset from cached resolutions before full refresh completes"

grep -q 'ROUTER_RULES_SYNC_ACTOR=boot' "$ROOT/routers/common/files/router-rules-sync.init" \
	|| fail "router-rules-sync init must run an immediate boot-time apply-xray refresh"

grep -q 'xray_path_requested()' "$ROUTER_RULES" \
	|| fail "router-rules must gate runtime drift recovery behind the active switch/config state"

grep -q 'xray_runtime_healthy || return 0' "$ROUTER_RULES" \
	|| fail "router-rules must treat a dead codex-xray runtime as actionable drift"

grep -q 'transproxy_runtime_healthy || return 0' "$ROUTER_RULES" \
	|| fail "router-rules must treat a dead transparent proxy runtime as actionable drift"

grep -q 'RUNNER_ACTION=' "$SWITCH_HELPER" \
	|| fail "gl-switch-xray.sh must persist the in-flight action so repeated watchdog retries do not kill the same helper"

grep -q 'helper already processing action=\$ACTION' "$SWITCH_HELPER" \
	|| fail "gl-switch-xray.sh must ignore duplicate on/off retries while the same helper action is already running"

grep -q '/etc/init.d/codex-xray enable' "$INSTALL_PLATFORM" \
	|| fail "install-platform must enable codex-xray on boot for fast post-reboot restore"

grep -q '/etc/init.d/codex-transproxy enable' "$INSTALL_PLATFORM" \
	|| fail "install-platform must enable codex-transproxy on boot for fast post-reboot restore"

grep -q 'data.path_state === "degraded"' "$XRAY_UI" \
	|| fail "xray.html must surface degraded runtime state instead of showing it as healthy active path"

grep -q -- '--socks5-hostname "127.0.0.1:${LIVE_SOCKS_PORT}"' "$ADMIN_CGI" \
	|| fail "xray-admin.cgi smoke must verify the local SOCKS path used by transparent traffic"

grep -q 'run_https_probe()' "$ADMIN_CGI" \
	|| fail "xray-admin.cgi smoke must use a reusable HTTPS probe helper instead of a single hard-coded oracle"

grep -q 'https://www.microsoft.com https://example.com' "$ADMIN_CGI" \
	|| fail "xray-admin.cgi smoke must try a stable HTTPS oracle before falling back to example.com"

grep -q '"last_smoke_http_ok":' "$ADMIN_CGI" \
	|| fail "xray-admin.cgi status must expose whether the local HTTP proxy path also passed smoke checks"

printf 'ok\n'
