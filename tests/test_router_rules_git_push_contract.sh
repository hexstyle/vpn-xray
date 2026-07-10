#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"
# router-rules split into sourced libs (AGENTS.md 500-line rule); grep the
# whole implementation set for moved function content.
ROUTER_RULES_IMPL="$ROUTER_RULES_FILE $ROOT/routers/common/files/router-rules-config.sh $ROOT/routers/common/files/router-rules-git.sh $ROOT/routers/common/files/router-rules-repo.sh $ROOT/routers/common/files/router-rules-remote.sh $ROOT/routers/common/files/router-rules-rulestree.sh $ROOT/routers/common/files/router-rules-external-a.sh $ROOT/routers/common/files/router-rules-external-b.sh $ROOT/routers/common/files/router-rules-ipset.sh $ROOT/routers/common/files/router-rules-apply.sh $ROOT/routers/common/files/router-rules-status.sh"
INSTALL_PLATFORM="$ROOT/routers/gl-mt3000-glinet/install-platform.sh"
# install-platform.sh split its function groups into sibling libs
# (AGENTS.md 500-line rule); grep the whole set for moved content.
INSTALL_PLATFORM_IMPL="$INSTALL_PLATFORM $ROOT/routers/gl-mt3000-glinet/install-platform-lib-a.sh $ROOT/routers/gl-mt3000-glinet/install-platform-lib-b.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q '^git_push_env_setup()' $ROUTER_RULES_IMPL \
	|| fail "router-rules must configure Git push auth independently from fetch auth"

grep -q '^git_push_cmd()' $ROUTER_RULES_IMPL \
	|| fail "router-rules must route git push through push-specific auth"

grep -q 'git_push_cmd -C "$repo" push origin "$branch"' $ROUTER_RULES_IMPL \
	|| fail "sync_repo_internal must use push-specific Git auth for push"

grep -q 'git_push_auth_configured()' $ROUTER_RULES_IMPL \
	|| fail "router-rules must detect whether push credentials are actually configured"

grep -q 'effective_git_auth_mode()' $INSTALL_PLATFORM_IMPL \
	|| fail "install-platform must preserve the router's existing Git auth mode"

grep -q 'effective_router_rules_bool_value enable_push' "$INSTALL_PLATFORM" \
	|| fail "install-platform must preserve the router's existing push enable state"

printf 'ok\n'
