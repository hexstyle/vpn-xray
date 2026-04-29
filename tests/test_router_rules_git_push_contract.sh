#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"
INSTALL_PLATFORM="$ROOT/routers/gl-mt3000-glinet/install-platform.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q '^git_push_env_setup()' "$ROUTER_RULES_FILE" \
	|| fail "router-rules must configure Git push auth independently from fetch auth"

grep -q '^git_push_cmd()' "$ROUTER_RULES_FILE" \
	|| fail "router-rules must route git push through push-specific auth"

grep -q 'git_push_cmd -C "$repo" push origin "$branch"' "$ROUTER_RULES_FILE" \
	|| fail "sync_repo_internal must use push-specific Git auth for push"

grep -q 'git_push_auth_configured()' "$ROUTER_RULES_FILE" \
	|| fail "router-rules must detect whether push credentials are actually configured"

grep -q 'effective_git_auth_mode()' "$INSTALL_PLATFORM" \
	|| fail "install-platform must preserve the router's existing Git auth mode"

grep -q 'effective_router_rules_bool_value enable_push' "$INSTALL_PLATFORM" \
	|| fail "install-platform must preserve the router's existing push enable state"

printf 'ok\n'
