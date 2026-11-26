#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
CGI_FILE="$ROOT/routers/gl-mt3000-glinet/files/xray-rules.cgi"
# set_mode's async worker lives in the shared action lib (AGENTS.md
# 500-line split); grep the whole implementation set for it. The lock-wait
# and timeout constants stay declared in the CGI itself.
RULES_IMPL="$CGI_FILE $ROOT/routers/common/files/xray-rules-jobs.sh $ROOT/routers/common/files/xray-rules-actions.sh $ROOT/routers/common/files/xray-rules-scripts.sh"
APPLY_LIB="$ROOT/routers/common/files/router-rules-apply.sh"
MODE_LIB="$ROOT/routers/common/files/router-rules-mode.sh"
ROUTER_RULES_IMPL="$ROOT/routers/common/files/router-rules $ROOT/routers/common/files/router-rules-config.sh $ROOT/routers/common/files/router-rules-git.sh $ROOT/routers/common/files/router-rules-repo.sh $ROOT/routers/common/files/router-rules-remote.sh $ROOT/routers/common/files/router-rules-rulestree.sh $ROOT/routers/common/files/router-rules-external-a.sh $ROOT/routers/common/files/router-rules-external-b.sh $ROOT/routers/common/files/router-rules-ipset.sh $APPLY_LIB $ROOT/routers/common/files/router-rules-mode.sh $ROOT/routers/common/files/router-rules-status.sh"
LIB_COMMON="$ROOT/routers/common/files/lib-common.sh"
WATCHDOG="$ROOT/routers/gl-mt3000-glinet/files/xray-switch-watchdog.init"
HEALTH="$ROOT/routers/gl-mt3000-glinet/files/xray-health-monitor.init"
HTML_FILE="$ROOT/routers/gl-mt3000-glinet/files/xray.html"
# xray.html inline CSS/JS extracted to sibling assets (AGENTS.md 500-line
# rule); grep the whole UI implementation set for moved content.
HTML_FILE_IMPL="$HTML_FILE $ROOT/routers/common/files/xray-base.css $ROOT/routers/common/files/xray-components.css $ROOT/routers/common/files/xray-app-1.js $ROOT/routers/common/files/xray-app-2.js $ROOT/routers/common/files/xray-app-3.js $ROOT/routers/common/files/xray-app-4.js $ROOT/routers/common/files/xray-app-5.js $ROOT/routers/common/files/xray-app-6.js $ROOT/routers/common/files/xray-app-7.js"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

body_of() {
	sed -n "/^$1()/,/^}/p" "$2"
}

mode_lock_wait="$(sed -n "s/^[[:space:]]*RULES_MODE_LOCK_WAIT=['\"]\\{0,1\\}\\([0-9][0-9]*\\)['\"]\\{0,1\\}$/\\1/p" "$CGI_FILE" | sed -n '1p')"
[ -n "$mode_lock_wait" ] || fail "mode lock wait is not declared in xray-rules.cgi"

mode_timeout="$(sed -n "s/^[[:space:]]*RULES_MODE_TIMEOUT=['\"]\\{0,1\\}\\([0-9][0-9]*\\)['\"]\\{0,1\\}$/\\1/p" "$CGI_FILE" | sed -n '1p')"
[ -n "$mode_timeout" ] || fail "mode-switch timeout is not declared in xray-rules.cgi"

[ "$mode_timeout" -gt "$mode_lock_wait" ] || fail "mode-switch timeout must be greater than the router-rules lock wait"
# The switch is a dataplane-only operation with a 5-10s operator budget.
[ "$mode_lock_wait" -le 10 ] || fail "mode lock wait must stay within the 5-10s switch budget"
[ "$mode_timeout" -le 30 ] || fail "mode-switch job timeout must stay bounded (<=30s)"

grep -q 'ROUTER_RULES_LOCK_WAIT="$RULES_MODE_LOCK_WAIT"' $RULES_IMPL \
	|| fail "set_mode must use RULES_MODE_LOCK_WAIT in xray-rules.cgi"

grep -q 'ui_job_begin set_mode' $RULES_IMPL \
	|| fail "set_mode must start a tracked async UI job in xray-rules.cgi"

grep -q 'timeout "$RULES_MODE_TIMEOUT" /usr/bin/router-rules set-mode-cutover "$mode" >"$run_log" 2>&1 || rc=\$?' $RULES_IMPL \
	|| fail "set_mode async worker must still enforce RULES_MODE_TIMEOUT in xray-rules.cgi"

# Three states, including software OFF.
grep -q 'full|selective|off)' $RULES_IMPL \
	|| fail "set_mode must accept the third (off) routing state"
grep -q 'full|selective|off)' "$MODE_LIB" \
	|| fail "set_xray_mode_internal must persist xray_mode=off"
grep -q 'apply_software_off_internal' "$APPLY_LIB" \
	|| fail "apply-xray must route mode=off through the software-OFF owner"

# The UI control is a 3-state segment, not a 2-state checkbox.
grep -q 'data-rules-mode="full"' $HTML_FILE_IMPL \
	|| fail "xray.html must expose a Full mode button"
grep -q 'data-rules-mode="selective"' $HTML_FILE_IMPL \
	|| fail "xray.html must expose a Selective mode button"
grep -q 'data-rules-mode="off"' $HTML_FILE_IMPL \
	|| fail "xray.html must expose an Off mode button"
grep -q 'rulesModeToggle' $HTML_FILE_IMPL \
	&& fail "the legacy 2-state rulesModeToggle must be gone"

mode_timeout_ms="$(sed -n 's/^[[:space:]]*const RULES_MODE_TIMEOUT_MS = \([0-9][0-9]*\);/\1/p' $HTML_FILE_IMPL | sed -n '1p')"
[ -n "$mode_timeout_ms" ] || fail "RULES_MODE_TIMEOUT_MS is not declared in xray.html"
[ "$mode_timeout_ms" -gt $((mode_timeout * 1000)) ] || fail "frontend mode timeout must be greater than the backend mode timeout"

grep -q 'setRulesMode(target.dataset.rulesMode, target)' $HTML_FILE_IMPL \
	|| fail "the mode segment buttons must call setRulesMode with the selected mode"

grep -q 'callApi(rulesApi, "set_mode", { mode }, { timeoutMs: RULES_STATUS_TIMEOUT_MS })' $HTML_FILE_IMPL \
	|| fail "set_mode must start through a short-lived status request in xray.html"

grep -q 'beginForegroundTask(`Switching to ${mode} routing mode...`, RULES_MODE_TIMEOUT_MS' $HTML_FILE_IMPL \
	|| fail "mode foreground task must use RULES_MODE_TIMEOUT_MS in xray.html"

grep -q 'async function waitForRulesJob' $HTML_FILE_IMPL \
	|| fail "xray.html must wait for long router operations by polling router status"

grep -q 'const RULES_JOB_STATUS_DELAY_MS = 2000;' $HTML_FILE_IMPL \
	|| fail "xray.html must delay detailed long-running status UX by 2 seconds"

grep -q '"ui_job_state"' $ROUTER_RULES_IMPL \
	|| fail "router-rules status-json must expose async UI job state"

grep -q 'mode_error_message()' "$CGI_FILE" \
	|| fail "xray-rules.cgi must extract a specific mode-switch error message"

# Node 4.10: the switch is dataplane-only. It must not run the full apply,
# Git, DNS resolution, or restart a healthy daemon.
cutover="$(body_of set_mode_cutover_internal "$MODE_LIB")"
[ -n "$cutover" ] || fail "set_mode_cutover_internal is missing"
printf '%s\n' "$cutover" | grep -q 'codex-transproxy apply_mode 9>&-' \
	|| fail "the mode switch must replace firewall rules in place and close the rules lock FD (nodes 4.10/4.11)"
printf '%s\n' "$cutover" | grep -q 'warm_selective_data_internal' \
	|| fail "the selective switch must restore the warm snapshot (node 4.10)"
for forbidden in hard_cutover_xray_internal apply_xray_internal sync_repo_internal resolve_rules_internal 'codex-xray restart' 'codex-transproxy restart' 'init.d/dnsmasq restart'; do
	printf '%s\n' "$cutover" | grep -q "$forbidden" \
		&& fail "the mode switch must not run '$forbidden' (node 4.10)"
done

grep -q 'apply_software_off_internal()' "$MODE_LIB" \
	|| fail "software OFF must own a dedicated path-down routine (node 4.9)"
grep -q 'xray_failsafe_disable' "$MODE_LIB" \
	|| fail "software OFF must clear fail-safe"

# Node 4.9: OFF is first-class in path/gating and protections.
grep -q 'xray_software_off()' "$LIB_COMMON" \
	|| fail "lib-common must expose xray_software_off"
path_body="$(body_of path_allowed "$LIB_COMMON")"
printf '%s\n' "$path_body" | grep -q 'xray_software_off' \
	|| fail "path_allowed must treat software OFF as not requested"
grep -q 'path_allowed || return 1' "$LIB_COMMON" \
	|| fail "path_requested must inherit the software-OFF gate"
grep -q 'xray_software_off' "$WATCHDOG" \
	|| fail "the watchdog must never resurrect a software-OFF path"
grep -q 'router_mode_switch_running 30' "$WATCHDOG" \
	|| fail "the watchdog must stand down while an in-budget mode switch owns the path"
grep -q 'router_mode_switch_settling 45' "$WATCHDOG" \
	|| fail "the watchdog must not smoke/restart while a switched path is warming"
grep -q 'router-rules-mode-settled' "$MODE_LIB" \
	|| fail "a mode switch must publish its settle window for the watchdog"
grep -q 'wait_for_xray_runtime 6' "$ROOT/routers/gl-mt3000-glinet/files/codex-transproxy.init" \
	|| fail "a cold mode switch must retry the Xray/tunnel start inside its budget"
grep -q 'exec 9>&-' "$MODE_LIB" \
	|| fail "the detached warm job must drop the inherited rules-lock FD (node 4.11)"

# The long DNS resolve runs outside the main rules lock, and the snapshot is
# published atomically so a switch never reads a partial file.
grep -q "with_flock '/tmp/router-rules-resolve.flock'" "$ROOT/routers/common/files/router-rules" \
	|| fail "build-xray-ipset must resolve outside the main rules lock (node 4.10)"
grep -q 'ROUTER_RULES_USE_CACHED_RESOLVED=1 with_lock build_xray_ipset_internal' "$ROOT/routers/common/files/router-rules" \
	|| fail "build-xray-ipset must take the main lock only for the fast ipset build (node 4.10)"
grep -q 'new.\$\$' "$ROOT/routers/common/files/router-rules-ipset.sh" \
	|| fail "resolved/domain snapshots must be published atomically (node 4.10)"
grep -q 'ROUTER_RULES_USE_CACHED_RESOLVED=1 hard_cutover_xray_internal' "$ROOT/routers/common/files/router-rules-apply.sh" \
	|| fail "background drift must not hold the rules lock for a full DNS refresh (node 4.10)"
printf '%s\n' "$cutover" | grep -q "last_smoke_status ''" \
	|| fail "a mode switch must clear the previous dataplane's stale smoke verdict (node 4.10)"
grep -q '"job_state":"scheduled"' $RULES_IMPL \
	|| fail "set_mode must return a light accepted response, not the heavy full status"
grep -q 'xray_software_off' "$HEALTH" \
	|| fail "the health monitor must not guard-restart a software-OFF path"

# A daemon started while holding the rules lock must not inherit FD9, or it
# keeps the lock forever and every later apply/mode switch times out.
grep -q 'dnsmasq restart 9>&-' "$ROOT/routers/common/files/router-rules-ipset.sh" \
	|| fail "dnsmasq restarts under the rules lock must close FD9 (node 4.11)"

# The new lib is part of the platform payload in BOTH profiles.
for install_platform in "$ROOT/routers/asus-tuf-ax4200-openwrt/install-platform.sh" \
	"$ROOT/routers/gl-mt3000-glinet/install-platform.sh"; do
	grep -q 'router-rules-mode.sh' "$install_platform" \
		|| fail "$install_platform must deploy router-rules-mode.sh"
done

printf 'ok\n'
