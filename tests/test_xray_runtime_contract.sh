#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ADMIN_CGI="$ROOT/routers/gl-mt3000-glinet/files/xray-admin.cgi"
# xray-admin.cgi sources its probe/build and status/smoke/health logic from
# these shared libs (AGENTS.md 500-line split). Contracts on moved content
# grep the whole implementation set so they survive future re-splits.
ADMIN_PROBE_LIB="$ROOT/routers/common/files/xray-admin-probe.sh"
ADMIN_STATUS_LIB="$ROOT/routers/common/files/xray-admin-status.sh"
ADMIN_IMPL="$ADMIN_CGI $ADMIN_PROBE_LIB $ADMIN_STATUS_LIB"
VPS_CGI="$ROOT/routers/gl-mt3000-glinet/files/xray-vps.cgi"
# xray-vps.cgi sources profile/ssh/render/inspect/actions/setup/repair logic
# from shared libs (AGENTS.md 500-line split); the router-config renderers
# live in xray-vps-render.sh. Grep the whole set for moved content.
VPS_RENDER_LIB="$ROOT/routers/common/files/xray-vps-render.sh"
VPS_IMPL="$VPS_CGI $ROOT/routers/common/files/xray-vps-profile.sh $ROOT/routers/common/files/xray-vps-ssh.sh $VPS_RENDER_LIB $ROOT/routers/common/files/xray-vps-inspect.sh $ROOT/routers/common/files/xray-vps-actions.sh $ROOT/routers/common/files/xray-vps-setup.sh $ROOT/routers/common/files/xray-vps-repair.sh"
XRAY_INIT="$ROOT/routers/gl-mt3000-glinet/files/codex-xray.init"
TRANSPROXY_INIT="$ROOT/routers/gl-mt3000-glinet/files/codex-transproxy.init"
INSTALL_PLATFORM="$ROOT/routers/gl-mt3000-glinet/install-platform.sh"
XRAY_UI="$ROOT/routers/gl-mt3000-glinet/files/xray.html"
# xray.html inline CSS/JS extracted to sibling assets (AGENTS.md 500-line
# rule); grep the whole UI implementation set for moved content.
XRAY_UI_IMPL="$XRAY_UI $ROOT/routers/common/files/xray-base.css $ROOT/routers/common/files/xray-components.css $ROOT/routers/common/files/xray-app-1.js $ROOT/routers/common/files/xray-app-2.js $ROOT/routers/common/files/xray-app-3.js $ROOT/routers/common/files/xray-app-4.js $ROOT/routers/common/files/xray-app-5.js $ROOT/routers/common/files/xray-app-6.js $ROOT/routers/common/files/xray-app-7.js"
ROUTER_RULES="$ROOT/routers/common/files/router-rules"
# router-rules split into sourced libs (AGENTS.md 500-line rule); grep the
# whole implementation set for moved function content.
ROUTER_RULES_IMPL="$ROUTER_RULES $ROOT/routers/common/files/router-rules-config.sh $ROOT/routers/common/files/router-rules-git.sh $ROOT/routers/common/files/router-rules-repo.sh $ROOT/routers/common/files/router-rules-remote.sh $ROOT/routers/common/files/router-rules-rulestree.sh $ROOT/routers/common/files/router-rules-external-a.sh $ROOT/routers/common/files/router-rules-external-b.sh $ROOT/routers/common/files/router-rules-ipset.sh $ROOT/routers/common/files/router-rules-apply.sh $ROOT/routers/common/files/router-rules-status.sh"
SWITCH_HELPER="$ROOT/routers/gl-mt3000-glinet/files/gl-switch-xray.sh"
WATCHDOG="$ROOT/routers/gl-mt3000-glinet/files/xray-switch-watchdog.init"
HEALTH_MONITOR="$ROOT/routers/gl-mt3000-glinet/files/xray-health-monitor.init"
LIB_COMMON="$ROOT/routers/common/files/lib-common.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q 'runtime_path_active()' "$ADMIN_CGI" \
	|| fail "xray-admin.cgi must expose an explicit runtime path health check"

grep -q '/etc/gl-switch.d/xray.sh "\$switch_state" >/dev/null 2>&1 || return 1' $ADMIN_IMPL \
	|| fail "xray-admin.cgi must not swallow switch-sync failures"

grep -q "path_state='degraded'" $ADMIN_IMPL \
	|| fail "xray-admin.cgi must mark runtime as degraded when smoke health says the path is broken"

grep -q '"path_effective":' $ADMIN_IMPL \
	|| fail "xray-admin.cgi must expose whether the active runtime is still effective after smoke checks"

grep -q 'router_path_active()' "$VPS_CGI" \
	|| fail "xray-vps.cgi must expose an explicit router path health check"

grep -q 'resync_runtime_to_switch || return 1' $VPS_IMPL \
	|| fail "xray-vps.cgi must fail apply_profile when runtime does not come back"

grep -q '"sniffing": {' $VPS_IMPL \
	|| fail "xray-vps.cgi must preserve inbound sniffing when it renders router configs from saved VPS profiles"

grep -q 'LOCAL_MANGLE_CHAIN="CODEX_XRAY_LOCAL"' "$XRAY_INIT" \
	|| fail "codex-xray.init must manage a dedicated local mangle chain for Xray server traffic"

grep -q -- '--clamp-mss-to-pmtu' "$XRAY_INIT" \
	|| fail "codex-xray.init must clamp MSS for router-local Xray traffic to the VPS"

grep -q 'path_requested' "$XRAY_INIT" \
	|| fail "codex-xray.init must gate boot startup behind switch/config readiness"

grep -q 'path_requested || return 0' "$XRAY_INIT" \
	|| fail "codex-xray.init must no-op when boot startup is not requested"

grep -q '"sniffing": {' "$ROOT/routers/gl-mt3000-glinet/files/codex-xray.json.template" \
	|| fail "codex-xray.json template must enable sniffing so transparent traffic can recover hostnames from TLS/HTTP metadata"

grep -q '"destOverride": \[' "$ROOT/routers/gl-mt3000-glinet/files/codex-xray.json.template" \
	|| fail "codex-xray.json template must override HTTP/TLS destinations for transparent traffic"

# Transport parity (DIAGNOSTIC-TREE 8.5 / R.4): EVERY router-config
# generator — the template and both CGI renderers — must emit the same
# WS+TLS transport the VPS serves. A generator left on raw/reality
# produces a config that cannot talk to the WS+TLS VPS; three separate
# generators diverged this way and broke the router (2026-07-10). Assert
# ws+tls, not the legacy reality fingerprint.
for gen in \
	"$ROOT/routers/gl-mt3000-glinet/files/codex-xray.json.template" \
	"$ADMIN_PROBE_LIB" \
	"$VPS_RENDER_LIB"; do
	name="$(basename "$gen")"
	grep -q '"network": "ws"' "$gen" \
		|| fail "$name must render the router outbound as network=ws (transport parity, node 8.5)"
	grep -q '"security": "tls"' "$gen" \
		|| fail "$name must render the router outbound as security=tls (transport parity, node 8.5)"
	grep -q '"security": "reality"' "$gen" \
		&& fail "$name still renders reality — transport mismatch with the WS+TLS VPS (node 8.5)"
	grep -q '"mux": {' "$gen" \
		|| fail "$name must enable outbound mux to avoid connection storms under browser load"
done

grep -q 'path_requested' "$TRANSPROXY_INIT" \
	|| fail "codex-transproxy.init must gate boot startup behind switch/config readiness"

grep -q 'if ! path_requested; then' "$TRANSPROXY_INIT" \
	|| fail "codex-transproxy.init must no-op when boot startup is not requested"

grep -q 'wait_for_xray_runtime()' "$TRANSPROXY_INIT" \
	|| fail "codex-transproxy.init must wait for Xray listeners before keeping transproxy enabled"

grep -q '/etc/init.d/codex-xray stop >/dev/null 2>&1 || true' "$TRANSPROXY_INIT" \
	|| fail "codex-transproxy.init must roll back codex-xray when the runtime never becomes ready"

grep -q 'ROUTER_RULES_USE_CACHED_RESOLVED=1 /usr/bin/router-rules build-xray-ipset' "$TRANSPROXY_INIT" \
	|| fail "codex-transproxy.init must restore selective ipset from cached resolutions before full refresh completes"

grep -q 'ROUTER_RULES_SYNC_ACTOR=boot' "$ROOT/routers/common/files/router-rules-sync.init" \
	|| fail "router-rules-sync init must run an immediate boot-time apply-xray refresh"

grep -q 'path_requested' $ROUTER_RULES_IMPL \
	|| fail "router-rules must gate runtime drift recovery behind the active switch/config state"

grep -q 'xray_runtime_healthy || return 0' $ROUTER_RULES_IMPL \
	|| fail "router-rules must treat a dead codex-xray runtime as actionable drift"

grep -q 'transproxy_runtime_healthy || return 0' $ROUTER_RULES_IMPL \
	|| fail "router-rules must treat a dead transparent proxy runtime as actionable drift"

grep -q 'RUNNER_ACTION=' "$SWITCH_HELPER" \
	|| fail "gl-switch-xray.sh must persist the in-flight action so repeated watchdog retries do not kill the same helper"

grep -q 'helper already processing action=\$ACTION' "$SWITCH_HELPER" \
	|| fail "gl-switch-xray.sh must ignore duplicate on/off retries while the same helper action is already running"

grep -q 'runtime_path_active()' "$SWITCH_HELPER" \
	|| fail "gl-switch-xray.sh must detect when the runtime is already active before restarting it"

grep -q 'xray_runtime_ready()' "$SWITCH_HELPER" \
	|| fail "gl-switch-xray.sh must distinguish the Xray core from the transproxy layer during recovery"

grep -q 'transproxy_runtime_ready()' "$SWITCH_HELPER" \
	|| fail "gl-switch-xray.sh must recover a missing transproxy layer without failing on an already-running Xray core"

grep -q 'wait_for_runtime_state active' "$SWITCH_HELPER" \
	|| fail "gl-switch-xray.sh must keep its helper alive until the requested active state actually converges"

grep -q "SWITCH_SYNC_WAIT_SECONDS='25'" "$ADMIN_CGI" \
	|| fail "xray-admin.cgi must wait long enough for async switch resync to converge"

grep -q "SWITCH_SYNC_WAIT_SECONDS='25'" "$VPS_CGI" \
	|| fail "xray-vps.cgi must wait long enough for async switch resync to converge"

grep -q 'QUERY_STRING=action=smoke' "$WATCHDOG" \
	|| fail "xray-switch-watchdog must periodically smoke-check an active runtime"

grep -q 'QUERY_STRING=action=restart' "$WATCHDOG" \
	|| fail "xray-switch-watchdog must restart the runtime after repeated smoke failures"

grep -q 'PARTIAL_FAILURE_THRESHOLD=' "$WATCHDOG" \
	|| fail "xray-switch-watchdog must tolerate transient single-metric smoke failures before restarting the runtime"

grep -q 'fail_count' "$WATCHDOG" \
	|| fail "xray-switch-watchdog must only take the fast severe-restart path when multiple core smoke checks fail together in the same probe (node 4.7)"

grep -q 'xray_failsafe_enable()' "$LIB_COMMON" \
	|| fail "lib-common must provide a shared client fail-safe kill switch"

grep -q 'CODEX_XRAY_FAILSAFE' "$LIB_COMMON" \
	|| fail "client fail-safe must use a dedicated forward-chain guard"

grep -q "xray_failsafe_enable 'transproxy stopped while Xray path is requested'" "$TRANSPROXY_INIT" \
	|| fail "codex-transproxy stop must fail closed when the switch still requests Xray"

grep -q "xray_failsafe_disable" "$TRANSPROXY_INIT" \
	|| fail "codex-transproxy must clear the fail-safe only after the path is active or switch is off"

grep -q 'xray_failsafe_hold_active' "$WATCHDOG" \
	|| fail "xray-switch-watchdog must honor fail-safe recovery holds"

grep -q 'watchdog detected inactive Xray path while switch is on' "$WATCHDOG" \
	|| fail "xray-switch-watchdog must block client forwarding before recovery when the path is inactive"

grep -q 'GUARD_FAILSAFE_HOLD' "$HEALTH_MONITOR" \
	|| fail "xray-health-monitor must fail closed under critical memory pressure"

grep -q 'recover)' "$SWITCH_HELPER" \
	|| fail "gl-switch-xray.sh must provide a manual recovery lever"

grep -q 'action_recover()' "$ADMIN_CGI" \
	|| fail "xray-admin.cgi must expose a manual recovery action"

grep -q 'Recover Xray Path' $XRAY_UI_IMPL \
	|| fail "xray.html must expose the manual recovery lever"

grep -q 'selective rules file is empty and recovery failed' $ROUTER_RULES_IMPL \
	|| fail "router-rules must fail closed when selective rules cannot be recovered"

grep -q 'client internet is blocked by fail-safe' $ROUTER_RULES_IMPL \
	|| fail "router-rules must report fail-safe blocking when runtime recovery does not converge"

grep -q '/etc/init.d/codex-xray enable' "$INSTALL_PLATFORM" \
	|| fail "install-platform must enable codex-xray on boot for fast post-reboot restore"

grep -q '/etc/init.d/codex-transproxy enable' "$INSTALL_PLATFORM" \
	|| fail "install-platform must enable codex-transproxy on boot for fast post-reboot restore"

grep -q 'data.path_state === "degraded"' $XRAY_UI_IMPL \
	|| fail "xray.html must surface degraded runtime state instead of showing it as healthy active path"

grep -q -- '--socks5-hostname "127.0.0.1:${LIVE_SOCKS_PORT}"' $ADMIN_IMPL \
	|| fail "xray-admin.cgi smoke must verify the local SOCKS path used by transparent traffic"

grep -q '"last_smoke_http_ok":' $ADMIN_IMPL \
	|| fail "xray-admin.cgi status must expose whether the local HTTP proxy path also passed smoke checks"

printf 'ok\n'
