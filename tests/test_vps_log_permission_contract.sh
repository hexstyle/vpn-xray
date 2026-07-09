#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
REMOTE_INSTALL="$ROOT/vps/debian-13/files/install-vps.remote.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# The VPS remote script is a step-based repair pipeline (DIAGNOSTIC-TREE
# node 6). The permission contract that closed the 2026-07-09 uid-drift
# outage (log files owned by nobody:nogroup after a reprovision → xray
# exits 23 and stays down) is implemented by step_permissions. This test
# pins the behavior, not a specific one-liner, so the pipeline can be
# refactored as long as it still: creates the log files, re-chowns every
# log file to the service user, tightens their mode, verifies the service
# user can actually write, and reloads systemd before deriving that user.

grep -q 'step_permissions()' "$REMOTE_INSTALL" \
	|| fail "install-vps.remote.sh must implement a step_permissions repair step (DIAGNOSTIC-TREE 6.4)"

grep -q 'touch "$XRAY_LOG_DIR/access.log" "$XRAY_LOG_DIR/error.log"' "$REMOTE_INSTALL" \
	|| fail "install-vps.remote.sh must create Xray log files before restart"

grep -q 'chown "$user:$group" "$f"' "$REMOTE_INSTALL" \
	|| fail "install-vps.remote.sh must normalize Xray log ownership to the service user before restart"

grep -q 'chmod 640 "$f"' "$REMOTE_INSTALL" \
	|| fail "install-vps.remote.sh must normalize Xray log permissions before restart"

grep -q 'user_can_write' "$REMOTE_INSTALL" \
	|| fail "install-vps.remote.sh must verify the service user can actually write the error log"

grep -q 'systemctl daemon-reload >/dev/null 2>&1 || true' "$REMOTE_INSTALL" \
	|| fail "install-vps.remote.sh must reload systemd before it derives the live Xray runtime user for log ownership"

# The runtime step must reset a unit that failed with the exit-23 guard,
# otherwise a plain restart is silently ignored (DIAGNOSTIC-TREE 6.8).
grep -q 'systemctl reset-failed "$XRAY_SERVICE"' "$REMOTE_INSTALL" \
	|| fail "install-vps.remote.sh runtime step must reset-failed before restart (RestartPreventExitStatus=23)"

printf 'ok\n'
