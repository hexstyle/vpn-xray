#!/bin/sh

set -eu

# Guard against a real incident (2026-07-10): a scripted edit collapsed seven
# `copy_if_changed "$COMMON_DIR/files/a.sh" .../a.sh` lines into ONE
# `copy_if_changed "$COMMON_DIR/files/a.sh b.sh c.sh ..." .../a.sh b.sh ...`.
# It passed `sh -n` (syntactically valid) and --preflight (the copy step does
# not run in preflight), then aborted install-platform.sh mid-deploy on the
# router — right after "Stopping vpn-xray runtime" — leaving redsocks / the
# transparent proxy down and LAN clients blocked. copy_if_changed takes
# exactly one source and one destination; assert every call matches.

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

for prof in gl-mt3000-glinet asus-tuf-ax4200-openwrt; do
	f="$ROOT/routers/$prof/install-platform.sh"
	[ -f "$f" ] || fail "$prof: install-platform.sh missing"

	# Each copy_if_changed call must be:  copy_if_changed "<src>" <dst>
	# where <src> is a single quoted path with no embedded space, and <dst>
	# is a single unquoted token with no space. awk parses each call line.
	awk -v prof="$prof" '
		/^[[:space:]]*copy_if_changed[[:space:]]/ {
			line=$0
			# strip leading command
			sub(/^[[:space:]]*copy_if_changed[[:space:]]+/, "", line)
			# src must start with a double quote
			if (substr(line,1,1) != "\"") {
				printf "BADSRC\t%s:%d\t%s\n", prof, NR, $0; bad=1; next
			}
			# find closing quote
			rest = substr(line, 2)
			q = index(rest, "\"")
			if (q == 0) { printf "NOQUOTE\t%s:%d\t%s\n", prof, NR, $0; bad=1; next }
			src = substr(rest, 1, q-1)
			dst = substr(rest, q+1)
			# trim leading spaces on dst
			sub(/^[[:space:]]+/, "", dst)
			sub(/[[:space:]]+$/, "", dst)
			# src must have no space (single file)
			if (src ~ /[[:space:]]/) { printf "MULTISRC\t%s:%d\t%s\n", prof, NR, $0; bad=1; next }
			# dst must be a single token (no space)
			if (dst ~ /[[:space:]]/) { printf "MULTIDST\t%s:%d\t%s\n", prof, NR, $0; bad=1; next }
			if (dst == "") { printf "NODST\t%s:%d\t%s\n", prof, NR, $0; bad=1; next }
		}
		END { exit(bad?1:0) }
	' "$f" > /tmp/copyargs.$$ 2>&1 || {
		sed 's/^/  /' /tmp/copyargs.$$ >&2
		rm -f /tmp/copyargs.$$
		fail "$prof: install-platform.sh has a malformed copy_if_changed (must be exactly one src + one dst)"
	}
	rm -f /tmp/copyargs.$$
done

printf 'ok\n'
