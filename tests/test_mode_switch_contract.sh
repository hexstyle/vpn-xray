#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
CGI_FILE="$ROOT/routers/gl-mt3000-glinet/files/xray-rules.cgi"
HTML_FILE="$ROOT/routers/gl-mt3000-glinet/files/xray.html"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

mode_lock_wait="$(sed -n "s/^[[:space:]]*RULES_MODE_LOCK_WAIT=['\"]\\{0,1\\}\\([0-9][0-9]*\\)['\"]\\{0,1\\}$/\\1/p" "$CGI_FILE" | sed -n '1p')"
[ -n "$mode_lock_wait" ] || fail "mode lock wait is not declared in xray-rules.cgi"

mode_timeout="$(sed -n "s/^[[:space:]]*RULES_MODE_TIMEOUT=['\"]\\{0,1\\}\\([0-9][0-9]*\\)['\"]\\{0,1\\}$/\\1/p" "$CGI_FILE" | sed -n '1p')"
[ -n "$mode_timeout" ] || fail "mode-switch timeout is not declared in xray-rules.cgi"

[ "$mode_timeout" -gt "$mode_lock_wait" ] || fail "mode-switch timeout must be greater than the router-rules lock wait"

grep -q 'ROUTER_RULES_LOCK_WAIT="$RULES_MODE_LOCK_WAIT"' "$CGI_FILE" \
	|| fail "set_mode must use RULES_MODE_LOCK_WAIT in xray-rules.cgi"

grep -q 'timeout "$RULES_MODE_TIMEOUT" /usr/bin/router-rules set-mode-cutover "$mode"' "$CGI_FILE" \
	|| fail "set_mode must use RULES_MODE_TIMEOUT in xray-rules.cgi"

mode_timeout_ms="$(sed -n 's/^[[:space:]]*const RULES_MODE_TIMEOUT_MS = \([0-9][0-9]*\);/\1/p' "$HTML_FILE" | sed -n '1p')"
[ -n "$mode_timeout_ms" ] || fail "RULES_MODE_TIMEOUT_MS is not declared in xray.html"

[ "$mode_timeout_ms" -gt $((mode_timeout * 1000)) ] || fail "frontend mode timeout must be greater than the backend mode timeout"

grep -q 'callApi(rulesApi, "set_mode", { mode }, { timeoutMs: RULES_MODE_TIMEOUT_MS })' "$HTML_FILE" \
	|| fail "set_mode must use RULES_MODE_TIMEOUT_MS in xray.html"

grep -q 'beginForegroundTask(`Applying ${mode} routing mode with hard cutover...`, RULES_MODE_TIMEOUT_MS);' "$HTML_FILE" \
	|| fail "mode foreground task must use RULES_MODE_TIMEOUT_MS in xray.html"

grep -q 'mode_error_message()' "$CGI_FILE" \
	|| fail "xray-rules.cgi must extract a specific mode-switch error message"

grep -q 'emit_error set_mode "$error_message"' "$CGI_FILE" \
	|| fail "xray-rules.cgi must return the extracted mode-switch error message"

printf 'ok\n'
