#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
CGI_FILE="$ROOT/routers/gl-mt3000-glinet/files/xray-rules.cgi"
# set_mode's async worker moved into the shared action lib (AGENTS.md
# 500-line split); grep the whole implementation set for it. The lock-wait
# and timeout constants stay declared in the CGI itself.
RULES_IMPL="$CGI_FILE $ROOT/routers/common/files/xray-rules-jobs.sh $ROOT/routers/common/files/xray-rules-actions.sh $ROOT/routers/common/files/xray-rules-scripts.sh"
HTML_FILE="$ROOT/routers/gl-mt3000-glinet/files/xray.html"
# xray.html inline CSS/JS extracted to sibling assets (AGENTS.md 500-line
# rule); grep the whole UI implementation set for moved content.
HTML_FILE_IMPL="$HTML_FILE $ROOT/routers/common/files/xray-base.css $ROOT/routers/common/files/xray-components.css $ROOT/routers/common/files/xray-app-1.js $ROOT/routers/common/files/xray-app-2.js $ROOT/routers/common/files/xray-app-3.js $ROOT/routers/common/files/xray-app-4.js $ROOT/routers/common/files/xray-app-5.js $ROOT/routers/common/files/xray-app-6.js $ROOT/routers/common/files/xray-app-7.js"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"
# router-rules split into sourced libs (AGENTS.md 500-line rule); grep the
# whole implementation set for moved function content.
ROUTER_RULES_IMPL="$ROUTER_RULES_FILE $ROOT/routers/common/files/router-rules-config.sh $ROOT/routers/common/files/router-rules-git.sh $ROOT/routers/common/files/router-rules-repo.sh $ROOT/routers/common/files/router-rules-remote.sh $ROOT/routers/common/files/router-rules-rulestree.sh $ROOT/routers/common/files/router-rules-external-a.sh $ROOT/routers/common/files/router-rules-external-b.sh $ROOT/routers/common/files/router-rules-ipset.sh $ROOT/routers/common/files/router-rules-apply.sh $ROOT/routers/common/files/router-rules-status.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

mode_lock_wait="$(sed -n "s/^[[:space:]]*RULES_MODE_LOCK_WAIT=['\"]\\{0,1\\}\\([0-9][0-9]*\\)['\"]\\{0,1\\}$/\\1/p" "$CGI_FILE" | sed -n '1p')"
[ -n "$mode_lock_wait" ] || fail "mode lock wait is not declared in xray-rules.cgi"

mode_timeout="$(sed -n "s/^[[:space:]]*RULES_MODE_TIMEOUT=['\"]\\{0,1\\}\\([0-9][0-9]*\\)['\"]\\{0,1\\}$/\\1/p" "$CGI_FILE" | sed -n '1p')"
[ -n "$mode_timeout" ] || fail "mode-switch timeout is not declared in xray-rules.cgi"

[ "$mode_timeout" -gt "$mode_lock_wait" ] || fail "mode-switch timeout must be greater than the router-rules lock wait"

grep -q 'ROUTER_RULES_LOCK_WAIT="$RULES_MODE_LOCK_WAIT"' $RULES_IMPL \
	|| fail "set_mode must use RULES_MODE_LOCK_WAIT in xray-rules.cgi"

grep -q 'ui_job_begin set_mode' $RULES_IMPL \
	|| fail "set_mode must start a tracked async UI job in xray-rules.cgi"

grep -q 'timeout "$RULES_MODE_TIMEOUT" /usr/bin/router-rules set-mode-cutover "$mode" >"$run_log" 2>&1 || rc=\$?' $RULES_IMPL \
	|| fail "set_mode async worker must still enforce RULES_MODE_TIMEOUT in xray-rules.cgi"

mode_timeout_ms="$(sed -n 's/^[[:space:]]*const RULES_MODE_TIMEOUT_MS = \([0-9][0-9]*\);/\1/p' $HTML_FILE_IMPL | sed -n '1p')"
[ -n "$mode_timeout_ms" ] || fail "RULES_MODE_TIMEOUT_MS is not declared in xray.html"

[ "$mode_timeout_ms" -gt $((mode_timeout * 1000)) ] || fail "frontend mode timeout must be greater than the backend mode timeout"

grep -q 'callApi(rulesApi, "set_mode", { mode }, { timeoutMs: RULES_STATUS_TIMEOUT_MS })' $HTML_FILE_IMPL \
	|| fail "set_mode must start through a short-lived status request in xray.html"

grep -q 'beginForegroundTask(`Applying ${mode} routing mode with hard cutover...`, RULES_MODE_TIMEOUT_MS);' $HTML_FILE_IMPL \
	|| fail "mode foreground task must use RULES_MODE_TIMEOUT_MS in xray.html"

grep -q 'async function waitForRulesJob' $HTML_FILE_IMPL \
	|| fail "xray.html must wait for long router operations by polling router status"

grep -q 'const RULES_JOB_STATUS_DELAY_MS = 2000;' $HTML_FILE_IMPL \
	|| fail "xray.html must delay detailed long-running status UX by 2 seconds"

grep -q '"ui_job_state"' $ROUTER_RULES_IMPL \
	|| fail "router-rules status-json must expose async UI job state"

grep -q 'mode_error_message()' "$CGI_FILE" \
	|| fail "xray-rules.cgi must extract a specific mode-switch error message"

printf 'ok\n'
