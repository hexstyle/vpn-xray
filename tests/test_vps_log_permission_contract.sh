#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
REMOTE_INSTALL="$ROOT/vps/debian-13/files/install-vps.remote.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q 'touch "$XRAY_LOG_DIR/access.log" "$XRAY_LOG_DIR/error.log"' "$REMOTE_INSTALL" \
	|| fail "install-vps.remote.sh must create Xray log files before restart"

grep -q "find \"\\\$XRAY_LOG_DIR\" -maxdepth 1 -type f -name '\\*.log\\*' -exec chown \"\\\$user:\\\$group\"" "$REMOTE_INSTALL" \
	|| fail "install-vps.remote.sh must normalize Xray log ownership before restart"

grep -q "find \"\\\$XRAY_LOG_DIR\" -maxdepth 1 -type f -name '\\*.log\\*' -exec chmod 640" "$REMOTE_INSTALL" \
	|| fail "install-vps.remote.sh must normalize Xray log permissions before restart"

grep -q 'systemctl daemon-reload >/dev/null 2>&1 || true' "$REMOTE_INSTALL" \
	|| fail "install-vps.remote.sh must reload systemd before it derives the live Xray runtime user for log ownership"

printf 'ok\n'
