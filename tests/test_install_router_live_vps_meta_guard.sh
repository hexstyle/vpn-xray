#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
INSTALL_ROUTER="$ROOT/routers/gl-mt3000-glinet/install-router.sh"
# install-router.sh: helpers + deploy/verify flow moved to a sibling lib
# (AGENTS.md 500-line rule); grep the whole implementation set.
INSTALL_ROUTER_IMPL="$INSTALL_ROUTER $ROOT/routers/gl-mt3000-glinet/install-router-lib.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q 'current_vps_xray_runtime_facts()' $INSTALL_ROUTER_IMPL \
	|| fail "install-router must inspect live VPS runtime facts before trusting managed meta"

grep -q 'CONFIG_PORT=' $INSTALL_ROUTER_IMPL \
	|| fail "install-router must read the active Xray port from the VPS config"

grep -q 'differs from active VPS config port' $INSTALL_ROUTER_IMPL \
	|| fail "install-router must warn when managed meta disagrees with the active VPS config port"

grep -q 'XRAY_PORT="\$current_vps_config_port"' $INSTALL_ROUTER_IMPL \
	|| fail "install-router must prefer the active VPS config port over stale managed meta"

printf 'ok\n'
