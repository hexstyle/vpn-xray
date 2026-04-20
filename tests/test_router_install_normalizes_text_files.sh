#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
INSTALL_PLATFORM="$ROOT/routers/gl-mt3000-glinet/install-platform.sh"
INSTALL_ROUTER="$ROOT/routers/gl-mt3000-glinet/install-router.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q 'normalize_installed_text_files' "$INSTALL_PLATFORM" \
	|| fail "install-platform must normalize deployed text files to Unix line endings"

grep -q '/etc/hotplug.d/iface/95-codex-xray-uplink' "$INSTALL_PLATFORM" \
	|| fail "install-platform must normalize the deployed Xray uplink hotplug guard"

grep -q 'newline="\\n"' "$INSTALL_ROUTER" \
	|| fail "install-router template rendering must force Unix newlines"

grep -q "MSYS2_ENV_CONV_EXCL='\\*' python3" "$INSTALL_ROUTER" \
	|| fail "install-router must disable Git Bash env path conversion when rendering remote templates"

grep -q "sed -i 's/\\\\r\\$//'" "$INSTALL_ROUTER" \
	|| fail "install-router must normalize the remote install-platform script before executing it"

grep -q 'wait_for_router_background_services_ready' "$INSTALL_ROUTER" \
	|| fail "install-router must wait for router-rules-sync and xray-switch-watchdog after deployment"

printf 'ok\n'
