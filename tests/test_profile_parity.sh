#!/bin/sh

set -eu

# DIAGNOSTIC-TREE G7/G12: the router-facing CGIs and UI are
# profile-independent (they read paths that are identical on both OpenWrt
# routers; the VPS profile comes from the profile store, not hardcoded).
# They MUST stay byte-identical across router profiles, or a fix landed in
# one profile silently leaves the other on the broken code — which is
# exactly how the asus profile ended up able to re-corrupt /root while gl
# was fixed. This test fails if they drift.

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
GL="$ROOT/routers/gl-mt3000-glinet/files"
ASUS="$ROOT/routers/asus-tuf-ax4200-openwrt/files"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# Files that must be identical across profiles (profile-independent logic).
for f in xray-vps.cgi xray-admin.cgi xray.html codex-transproxy.init codex-xray.init codex-xray-uplink.hotplug xray-health-monitor.init; do
	[ -f "$GL/$f" ] || fail "missing $GL/$f"
	[ -f "$ASUS/$f" ] || fail "missing $ASUS/$f"
	if ! diff -q "$GL/$f" "$ASUS/$f" >/dev/null 2>&1; then
		fail "$f differs between gl-mt3000-glinet and asus-tuf-ax4200-openwrt — a fix landed in one profile only (G7/G12). Sync them: cp $GL/$f $ASUS/$f"
	fi
done

printf 'ok\n'
