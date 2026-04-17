#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
VERIFY_SCRIPT="$ROOT/routers/gl-mt3000-glinet/verify-router.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

grep -q 'lan-device=' "$VERIFY_SCRIPT" \
	|| fail "verify-router must report the resolved LAN device"

grep -q 'wwan-device=' "$VERIFY_SCRIPT" \
	|| fail "verify-router must report the active repeater uplink device"

grep -q 'same-radio-uplink-risk=' "$VERIFY_SCRIPT" \
	|| fail "verify-router must surface same-radio AP/uplink risk during repeater failover"

grep -q 'vps-route=' "$VERIFY_SCRIPT" \
	|| fail "verify-router must report the router-local route chosen for the VPS path"

grep -q -- '-- nat counters --' "$VERIFY_SCRIPT" \
	|| fail "verify-router must inspect NAT counters after risky routing changes"

grep -q -- '-- local xray mss guard --' "$VERIFY_SCRIPT" \
	|| fail "verify-router must report the local Xray TCPMSS guard for VPS traffic"

grep -q 'router-local transparent socks path' "$VERIFY_SCRIPT" \
	|| fail "verify-router must exercise the local SOCKS path used by transparent traffic"

grep -q 'Covered here: router control-plane reachability' "$VERIFY_SCRIPT" \
	|| fail "verify-router must state what coverage it actually provides"

grep -q 'Not covered automatically here: LAN-client traffic checks for VPN off/full/selective' "$VERIFY_SCRIPT" \
	|| fail "verify-router must call out the missing LAN-client verification matrix explicitly"

printf 'ok\n'
