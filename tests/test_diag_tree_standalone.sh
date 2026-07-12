#!/bin/sh
# Guards that the diagnostic tree is usable STANDALONE (installer self-heal,
# one-liner diagnostics), not only from inside the admin CGI. The node checks
# depend on helper functions and vars that used to live only in the CGI; if they
# drift back out of the shared lib, a standalone caller gets false "failed" and
# would self-heal a healthy runtime.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/routers/common/files/xray-admin-probe.sh"
CGI="$ROOT/routers/gl-mt3000-glinet/files/xray-admin.cgi"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

for fn in status_file_value status_file_set service_running listen_present nat_rule_present; do
	grep -qE "^${fn}\(\)" "$PROBE" || fail "$fn must be defined in xray-admin-probe.sh (needed standalone), also in the CGI"
	grep -qE "^${fn}\(\)" "$CGI"   || fail "$fn must stay defined in the CGI too (used before it sources probe)"
done

for v in XRAY_PID REDSOCKS_PID STATUS_FILE LIVE_HTTP_PORT BIN; do
	grep -qE "^: \"\\\$\{${v}:=" "$PROBE" || fail "xray-admin-probe.sh must default \$$v so the tree works standalone"
done

printf 'ok\n'
