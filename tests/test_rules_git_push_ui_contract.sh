#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
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

grep -q 'id="rulesEnablePush"' $HTML_FILE_IMPL \
	|| fail "xray.html must expose an Allow Push To Git control"

grep -q 'id="rulesGitActionPanel"' $HTML_FILE_IMPL \
	|| fail "xray.html must show a visible Git action/fix panel"

grep -q 'enable_push: document.getElementById("rulesEnablePush").checked' $HTML_FILE_IMPL \
	|| fail "xray.html must submit enable_push to the router"

grep -q 'git_push_ready' $HTML_FILE_IMPL \
	|| fail "xray.html must render backend push-readiness state"

grep -q 'git_push_next_step' $HTML_FILE_IMPL \
	|| fail "xray.html must render concrete push remediation steps"

grep -q '"git_push_ready"' $ROUTER_RULES_IMPL \
	|| fail "router-rules status-json must expose git_push_ready"

grep -q '"git_push_next_step"' $ROUTER_RULES_IMPL \
	|| fail "router-rules status-json must expose git_push_next_step"

grep -q 'git_push_status_fields()' $ROUTER_RULES_IMPL \
	|| fail "router-rules must compute actionable push status"

printf 'ok\n'
