#!/bin/sh
# Actual apply owner with external/runtime leaves controlled; no network claims.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$ROOT/routers/common/files/lib-common.sh"
. "$ROOT/routers/common/files/xray-vps-ssh.sh"
. "$ROOT/routers/common/files/xray-vps-verify.sh"
. "$ROOT/routers/common/files/xray-vps-setup.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ROUTER_CONFIG="$WORK/config"; ROUTER_CERT="$WORK/cert"
ROUTER_TUNNEL_CONFIG="$WORK/tunnel"; ROUTER_READY_FILE="$WORK/ready"
ROUTER_XRAY_BIN=/usr/bin/true
# Exercise the real identity validator before replacing remote leaves below.
profile_cache_path() { echo unused; }
profile_get() {
 [ "$2" != "${MISSING_FIELD:-}" ] || return 0
 case "$2" in server_address) echo 38.180.11.240;; server_name) echo www.wp.pl;; uuid) echo test-identity;; server_port) echo 443;; ws_path) echo /cdn;; esac
}
valid_port() { [ "$1" = 443 ]; }
cache_get() {
 case "$2" in
 REMOTE_LIVE_PORT) echo 443;; REMOTE_LIVE_UUID) echo "${LIVE_IDENTITY:-test-identity}";;
 REMOTE_XRAY_SERVICE) echo active;; REMOTE_LISTENER_PORT) echo listening;;
 REMOTE_TRANSPORT_NET) echo ws;; REMOTE_TRANSPORT_SEC) echo tls;; REMOTE_LIVE_WS_PATH) echo /cdn;;
 esac
}
validate_selected_profile default || fail 'valid inspected identity rejected'
for MISSING_FIELD in server_address server_name uuid server_port; do
 validate_selected_profile default && fail "missing $MISSING_FIELD accepted"
done
MISSING_FIELD=''; LIVE_IDENTITY=other
validate_selected_profile default && fail 'live/meta identity mismatch accepted'
LIVE_IDENTITY=test-identity
profile_get() { [ "$2" != dial_mode ] || echo direct; }
validate_selected_profile() { [ "${INVALID:-0}" = 0 ]; }
render_router_config() { echo new > "$1"; }
fetch_profile_tls_cert() { echo newcert > "$2"; }
activate_profile_tunnel() { return 0; }
current_switch_state() { echo on; }
local_profile_runtime_ready() { return 0; }
restart_profile_runtime() { echo restart >> "$WORK/restarts"; return "${RUNTIME_RC:-0}"; }
vx_run_with_timeout() { return 0; }
verify_applied_profile_path() {
 APPLY_ROUTER_ERROR='incomplete HTTP200'
 return "${HEALTH_RC:-1}"
}
reset_old() { echo old > "$ROUTER_CONFIG"; echo oldcert > "$ROUTER_CERT"; touch "$ROUTER_READY_FILE"; }
reset_old
INVALID=1
if apply_profile_to_router_internal default; then fail 'invalid input accepted'; fi
[ "$(cat "$ROUTER_CONFIG")" = old ] || fail 'invalid input changed live config'
INVALID=0
apply_profile_to_router_internal default && fail 'failed health accepted'
[ "$APPLY_ROUTER_PHASE" = applied ] && [ "$APPLY_PATH_HEALTH" = failed ] || fail 'application conflated with health'
[ "$(cat "$ROUTER_CONFIG")" = new ] || fail 'external failure rolled back'
HEALTH_RC=0
VPS_JOB_DEADLINE=$(($(date +%s) + 30))
apply_profile_to_router_internal default || fail 'idempotent retry failed'
[ "$APPLY_ROUTER_PHASE" = unchanged ] || fail 'same config restarted'
unset VPS_JOB_DEADLINE
[ "$(wc -l < "$WORK/restarts" | tr -d ' ')" = 1 ] || fail 'idempotent retry restarted services'
reset_old
restart_profile_runtime() {
 if [ "$(cat "$ROUTER_CONFIG")" = new ]; then return 1; fi
 return 0
}
apply_profile_to_router_internal default && fail 'runtime failure accepted'
[ "$APPLY_ROUTER_PHASE" = rolled_back ] && [ "$(cat "$ROUTER_CONFIG")" = old ] || fail 'runtime rollback not verified'
restart_profile_runtime() { return 1; }
apply_profile_to_router_internal default && fail 'failed rollback accepted'
[ "$APPLY_ROUTER_PHASE" = unknown ] || fail 'failed rollback claimed restoration'
# Refuse to cut over if any backup cannot be written.
(
 reset_old
 backup_apply_file() { return 1; }
 apply_profile_to_router_internal default && fail 'backup failure accepted'
 [ "$(cat "$ROUTER_CONFIG")" = old ] || fail 'backup failure changed live target'
)
# A failed second write restores both the first write and the old certificate.
(
 reset_old
 restart_profile_runtime() { return 0; }
 mv() { [ "$2" != "$ROUTER_CERT" ] || return 1; command mv "$@"; }
 apply_profile_to_router_internal default && fail 'write failure accepted'
 [ "$APPLY_ROUTER_PHASE" = rolled_back ] || fail 'partial write not rolled back'
 [ "$(cat "$ROUTER_CONFIG")" = old ] && [ "$(cat "$ROUTER_CERT")" = oldcert ] || fail 'partial restore'
)
VPS_JOB_DEADLINE=$(($(date +%s) + 20))
reset_old
apply_profile_to_router_internal default && fail 'unsafe late cutover accepted'
[ "$APPLY_ROUTER_PHASE" = unchanged ] && [ "$(cat "$ROUTER_CONFIG")" = old ] || fail 'deadline changed target'
printf 'ok: selected apply, retained unhealthy target, idempotence, runtime rollback, unknown and deadline\n'
