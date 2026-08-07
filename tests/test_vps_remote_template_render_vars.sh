#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
REMOTE_INSTALL="$ROOT/vps/debian-13/files/install-vps.remote.sh"
VPS_INSTALL="$ROOT/vps/debian-13/install-vps.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# render_template() in install-vps.sh substitutes EVERY ${UPPER_VAR} in the
# template from the process environment and hard-errors ("requires env variable
# X, but it is missing") if the var is not exported. So a braced *shell* variable
# inside the remote script — e.g. "${XRAY_SERVICE}.service.d", where XRAY_SERVICE
# is a runtime variable the remote script sets itself — collides with the render
# placeholder syntax and breaks the whole install (the 2026-08 asus regression).
#
# Contract: every ${VAR} placeholder in the remote template must be a variable
# that install-vps.sh actually provides to the renderer (it appears as a
# standalone word there — in require_vars/export/meta). Runtime shell variables
# of the remote script must be written unbraced ($VAR / "$VAR") so this regex
# never matches them.
[ -f "$REMOTE_INSTALL" ] || fail "missing $REMOTE_INSTALL"
[ -f "$VPS_INSTALL" ] || fail "missing $VPS_INSTALL"

placeholders="$(grep -oE '\$\{[A-Z0-9_]+\}' "$REMOTE_INSTALL" | tr -d '${}' | sort -u)"
[ -n "$placeholders" ] || fail "no \${VAR} placeholders found — template shape changed unexpectedly"

for var in $placeholders; do
	# -w = whole-word, so XRAY_SERVICE does NOT match inside VPS_XRAY_SERVICE.
	if ! grep -wq "$var" "$VPS_INSTALL"; then
		fail "template placeholder \${$var} is not provided by install-vps.sh — if it is a runtime shell variable of the remote script, write it unbraced (\$$var) so render_template does not demand it from the host env"
	fi
done

printf 'ok\n'
