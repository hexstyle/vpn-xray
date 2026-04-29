#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HTML_FILE="$ROOT/routers/gl-mt3000-glinet/files/xray.html"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q 'id="rulesEnablePush"' "$HTML_FILE" \
	|| fail "xray.html must expose an Allow Push To Git control"

grep -q 'id="rulesGitActionPanel"' "$HTML_FILE" \
	|| fail "xray.html must show a visible Git action/fix panel"

grep -q 'enable_push: document.getElementById("rulesEnablePush").checked' "$HTML_FILE" \
	|| fail "xray.html must submit enable_push to the router"

grep -q 'git_push_ready' "$HTML_FILE" \
	|| fail "xray.html must render backend push-readiness state"

grep -q 'git_push_next_step' "$HTML_FILE" \
	|| fail "xray.html must render concrete push remediation steps"

grep -q '"git_push_ready"' "$ROUTER_RULES_FILE" \
	|| fail "router-rules status-json must expose git_push_ready"

grep -q '"git_push_next_step"' "$ROUTER_RULES_FILE" \
	|| fail "router-rules status-json must expose git_push_next_step"

grep -q 'git_push_status_fields()' "$ROUTER_RULES_FILE" \
	|| fail "router-rules must compute actionable push status"

printf 'ok\n'
