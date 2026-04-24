#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HTML_FILE="$ROOT/routers/gl-mt3000-glinet/files/xray.html"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q 'editor.readOnly = !state.rulesTextLoaded;' "$HTML_FILE" \
	|| fail "xray.html must keep the shared rules editor writable after the full text is loaded"

grep -q 'if (state.rulesDirty && state.rulesTextLoaded) {' "$HTML_FILE" \
	|| fail "xray.html must submit dirty rules text even in pull-only Git mode"

grep -q 'pull-only mode' "$HTML_FILE" \
	|| fail "xray.html must describe anonymous/read-only Git sync as pull-only instead of a locked editor"

if grep -q 'editing on the router is locked' "$HTML_FILE"; then
	fail "xray.html must not claim that pull-only Git sync locks local rule editing"
fi

if grep -q 'local rule editing on the router is locked' "$ROUTER_RULES_FILE"; then
	fail "router-rules must not hard-block local edits when Git sync is pull-only"
fi

printf 'ok\n'
