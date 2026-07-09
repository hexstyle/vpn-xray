#!/bin/sh

set -eu

# The xray-switch-watchdog daemon runs as one big `procd ... command
# /bin/sh -c '<script>'`. A literal single quote inside that script closes
# the outer single quote, truncating the script — procd then gets an
# unparseable command and the daemon silently never runs (discovered
# 2026-07-10: the watchdog had never come up; its whole recovery layer,
# including the cert self-heal, was dead). This test extracts the daemon
# body exactly as procd would see it and asserts it is a valid, complete
# script, and that the specific bug pattern (a literal single-quoted string
# passed to xray_failsafe_enable) is gone. It also asserts the cert
# self-heal hook and its helper are present. See docs/BOOT-PATH-DESIGN.md.

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

for profile in gl-mt3000-glinet asus-tuf-ax4200-openwrt; do
	wd="$ROOT/routers/$profile/files/xray-switch-watchdog.init"
	helper="$ROOT/routers/$profile/files/vpn-xray-repin-cert"
	[ -f "$wd" ] || fail "$profile: missing xray-switch-watchdog.init"
	[ -f "$helper" ] || fail "$profile: missing vpn-xray-repin-cert helper"

	# Outer init script must parse.
	sh -n "$wd" || fail "$profile: watchdog init outer syntax error"

	# Extract the daemon body (between `command /bin/sh -c '` and the lone
	# closing `'`) and confirm it is itself a complete, parseable script.
	# If a literal single quote had truncated it, this extraction would be
	# short and sh -n would fail on the incomplete script.
	body="$(mktemp)"
	awk '/command \/bin\/sh -c '"'"'/{f=1;next} /^'"'"'$/{f=0} f' "$wd" > "$body"
	lines="$(wc -l < "$body")"
	[ "$lines" -gt 150 ] || { rm -f "$body"; fail "$profile: extracted watchdog daemon body is only $lines lines — likely truncated by a stray single quote"; }
	sh -n "$body" || { rm -f "$body"; fail "$profile: extracted watchdog daemon body has a syntax error (broken procd quoting?)"; }
	rm -f "$body"

	# The exact bug pattern: a literal single-quoted string argument.
	grep -q "xray_failsafe_enable '" "$wd" \
		&& fail "$profile: watchdog uses a literal single-quoted string inside the sh -c body — this truncates the procd command and the daemon will never start (use \"...\")"

	# Cert self-heal hook + helper wiring (BOOT-PATH-DESIGN §3).
	grep -q '/usr/bin/vpn-xray-repin-cert' "$wd" \
		|| fail "$profile: watchdog must invoke the cert re-pin helper in its severe-failure recovery (G11)"
	sh -n "$helper" || fail "$profile: vpn-xray-repin-cert helper syntax error"
	grep -q 'exit 10' "$helper" \
		|| fail "$profile: vpn-xray-repin-cert must signal a re-pin via exit 10"
	grep -q 'cmp -s' "$helper" \
		|| fail "$profile: vpn-xray-repin-cert must be idempotent (only re-pin on a real change)"
done

printf 'ok\n'
