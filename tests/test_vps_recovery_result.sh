#!/bin/sh
# Behavioural regressions: incomplete HTTP bodies and the detached job verdict.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
PATH="$ROOT/tests/fixtures:$PATH"; export PATH
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$ROOT/routers/common/files/lib-common.sh"
. "$ROOT/routers/common/files/xray-vps-ssh.sh"
. "$ROOT/routers/common/files/xray-vps-verify.sh"
. "$ROOT/routers/common/files/xray-vps-setup.sh"
. "$ROOT/routers/common/files/xray-vps-job-status.sh"
. "$ROOT/routers/common/files/xray-vps-repair.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
# Exercise the no-timeout firmware branch with real stdin, not a mocked cat.
input="$(
 command() { return 1; }
 printf inspection-input | vx_run_with_timeout 2 cat
)"
[ "$input" = inspection-input ] || fail 'bounded fallback discarded SSH stdin'


# Controlled curl transport leaf: same HTTP 200, differing completion status.
curl() {
 local body=/dev/null url=''
 while [ "$#" -gt 0 ]; do
  case "$1" in -o) body="$2"; shift;; https://*) url="$1";; esac
  shift
 done
 printf called >> "$WORK/curl.calls"
 case "$url" in
  https://ident.me|https://api.ipify.org) printf '38.180.11.240' > "$body";;
 esac
 if [ "$url" = https://chatgpt.com ] && [ "${PARTIAL:-0}" = 1 ]; then
  printf '200 5456'; echo 'curl: (28) Operation timed out with 5456 bytes received' >&2
  return 28
 fi
 printf '%s 262144' "${HTTP_CODE:-200}"
}
PARTIAL=1
if profile_probe_request 11884 https://chatgpt.com 8 "$WORK/probe"; then
 fail 'HTTP 200 plus curl 28 was accepted'
fi
grep -q 'curl_exit=28 http=200 bytes=5456' "$WORK/probe" || fail 'transfer evidence missing'
grep -q 'Operation timed out' "$WORK/probe" || fail 'curl error missing'
PARTIAL=0
profile_probe_request 11884 https://chatgpt.com 8 "$WORK/probe" || fail 'complete 200 rejected'
HTTP_CODE=403
if profile_probe_request 11884 https://chatgpt.com 8 "$WORK/probe"; then fail 'HTTP 403 accepted'; fi
HTTP_CODE=200
VPS_JOB_DEADLINE=$(($(date +%s) - 1))
rm "$WORK/curl.calls"
if profile_probe_request 11884 https://chatgpt.com 8 "$WORK/probe"; then fail 'expired deadline accepted'; fi
[ ! -e "$WORK/curl.calls" ] || fail 'curl ran after deadline'
unset VPS_JOB_DEADLINE

profile_cache_path() { echo unused; }
cache_get() { echo 38.180.11.240; }
ROUTER_SOCKS_PORT=1084
PROFILE_VERIFY_LOG='candidate evidence'
PARTIAL=1
if verify_applied_profile_path default; then fail 'post-apply accepted incomplete HTTP 200'; fi
printf '%s' "$PROFILE_VERIFY_LOG" | grep -q 'curl_exit=28' || fail 'post-apply evidence lost'
PARTIAL=0
verify_applied_profile_path default || fail 'complete post-apply rejected'
[ "$APPLY_ROUTER_EGRESS" = 38.180.11.240 ] || fail 'egress was not verified'

# Run the actual detached job owner and action. Remote/candidate leaves are
# controlled; this proves result serialization/lifecycle, not a live VPS path.
VPS_REPAIR_JOB_DIR="$WORK/jobs"
LOCK_ROOT="$WORK/locks"
PROFILE_PACKAGE=xray_vps
profile_del() { :; }
uci() { :; }
mkdir -p "$VPS_REPAIR_JOB_DIR"
request_has_key() { return 1; }
request_value() { :; }
active_profile_id() { echo default; }
ensure_ssh_ready() { return 0; }
prepare_profile_from_vps() { return 0; }
refresh_remote_cache() { return 0; }
adopt_remote_into_profile() { return 0; }
fetch_profile_tls_cert() { printf certificate > "$2"; }
profile_diff_fields() { echo server_address; }
status_json() { printf '{}'; }
run_repair_pipeline() {
 REPAIR_REPORT='[{"id":"server_overall","status":"ok","message":"server components pass"}]'
 REPAIR_FATAL=''
 REPAIR_RAW_LOG_PATH=''
 [ "${EXPIRE_JOB:-0}" = 0 ] || VPS_JOB_DEADLINE=0
 return 0
}
apply_profile_to_router_internal() {
 APPLY_ROUTER_PHASE=applied; APPLY_PATH_HEALTH=failed
 [ "${CANDIDATE_RC:-1}" != 0 ] || APPLY_PATH_HEALTH=ok
 [ "${EXPIRE_JOB:-0}" = 0 ] || { APPLY_ROUTER_PHASE=unchanged; return 1; }
 PROFILE_VERIFY_LOG='https://chatgpt.com curl_exit=28 http=200 bytes=5456 error=timeout'
 APPLY_ROUTER_ERROR='isolated candidate lost 12 real proxy requests'
 return "${CANDIDATE_RC:-1}"
}
# Lock acquisition is a controlled leaf here (macOS has no flock applet).
# Real single-flight/port ownership is checked on the router.
flock() { return 0; }
mkdir -p /tmp/xray-vps-locks
run_case() {
 local id="$1" expected="$2"
 mkdir "$VPS_REPAIR_JOB_DIR/$id"
 printf default > "$VPS_REPAIR_JOB_DIR/$id/profile"
 printf action=diagnose_repair > "$VPS_REPAIR_JOB_DIR/$id/request"
 run_vps_repair_job "$id" || :
 python3 - "$VPS_REPAIR_JOB_DIR/$id/result" "$expected" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
if sys.argv[2]=='deadline':
 assert r['ok'] is False and r['router_apply']=='unchanged', r
else:
 assert r['ok'] is (sys.argv[2]=='ok'), r
 assert r['steps'][0]['status']=='ok', r
 assert r['steps'][-1]['id']=='selected_path', r
 assert r['steps'][-1]['status']==('ok' if r['ok'] else 'failed'), r
 assert r['router_apply']=='applied' and r['applied'] is True, r
 assert 'curl_exit=28 http=200 bytes=5456' in r['raw_log'], r
PY
 [ "$?" -eq 0 ] || fail 'job result assertion failed'
 [ ! -e "$VPS_REPAIR_JOB_DIR/$id/request" ] || fail 'one-shot request retained'
 [ ! -e "$VPS_REPAIR_JOB_DIR/$id/response.raw" ] || fail 'raw response retained'
 grep -q '^state=done$' "$VPS_REPAIR_JOB_DIR/$id/status" || fail 'job did not terminate'
}
CANDIDATE_RC=1
run_case 1-1 failed
grep -q '^exit_code=1$' "$VPS_REPAIR_JOB_DIR/1-1/status" || fail 'failure exit status lost'
CANDIDATE_RC=0
run_case 1-2 ok
grep -q '^exit_code=0$' "$VPS_REPAIR_JOB_DIR/1-2/status" || fail 'retry did not succeed'
EXPIRE_JOB=1
run_case 1-3 deadline
grep -q '^exit_code=124$' "$VPS_REPAIR_JOB_DIR/1-3/status" || fail 'deadline exit status lost'
unset VPS_JOB_DEADLINE
EXPIRE_JOB=0
ROUTER_APPLY_STATUS_FILE="$WORK/apply.status"
apply_profile_to_router_internal() {
 APPLY_ROUTER_PHASE="$TEST_PHASE"
 APPLY_PATH_HEALTH=failed
 APPLY_ROUTER_ERROR='representative transfer failure'
 PROFILE_VERIFY_LOG='curl_exit=28 http=200 bytes=5456'
 return 1
}
adopt_remote_into_profile() { :; }
TEST_PHASE=unchanged
printf action=apply_router > "$ROUTER_APPLY_STATUS_FILE.request"
run_router_apply_job default || :
grep -q 'Router configuration unchanged' "$ROUTER_APPLY_STATUS_FILE" || fail 'pre-cutover failure claimed rollback'
TEST_PHASE=rolled_back
printf action=apply_router > "$ROUTER_APPLY_STATUS_FILE.request"
run_router_apply_job default || :
grep -q 'previous configuration restored and verified' "$ROUTER_APPLY_STATUS_FILE" || fail 'actual rollback not reported'
router_apply_status_json > "$WORK/apply.json"
python3 - "$WORK/apply.json" <<'PYTEST'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['state']=='failed' and 'curl_exit=28' in r['raw_log'], r
PYTEST
[ "$?" -eq 0 ] || fail 'apply status lost diagnostic evidence'
# Legacy Apply/settings reaches the same owner in its worker, with accepted
# profile and one-shot request preserved; no live active-profile lookup.
active_profile_id() { echo other-profile; }
XRAY_VPS_JOB_ORIGIN=apply_profile
printf 'action=apply_profile&ssh_password=synthetic' > "$ROUTER_APPLY_STATUS_FILE.request"
apply_profile_to_router_internal() {
 [ "$1" = default ] || fail 'worker used changed selection'
 [ "$REQUEST_DATA" = 'action=apply_profile&ssh_password=synthetic' ] || fail 'accepted request lost'
 APPLY_ROUTER_PHASE=applied; APPLY_PATH_HEALTH=failed
 return 1
}
run_router_apply_job default || :
grep -q '^origin=apply_profile$' "$ROUTER_APPLY_STATUS_FILE" || fail 'settings origin lost'
grep -q '^router_apply=applied$' "$ROUTER_APPLY_STATUS_FILE" || fail 'settings failed to apply selected profile'
[ ! -e "$ROUTER_APPLY_STATUS_FILE.request" ] || fail 'apply one-shot request retained'
# Server inspection passed, but the real Apply worker must preserve the
# pipeline's permissions verdict instead of blaming the inspection stage.
run_repair_pipeline() {
 REPAIR_REPORT='[{"id":"permissions","status":"failed","message":"permissions refused"}]'
 REPAIR_FATAL=''; REPAIR_RAW_LOG_PATH=''
 return 1
}
printf action=apply_profile > "$ROUTER_APPLY_STATUS_FILE.request"
run_router_apply_job default || :
router_apply_status_json > "$WORK/server-failed.json"
python3 - "$WORK/server-failed.json" <<'PYSERVER'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['state']=='failed' and r['steps'][0]['id']=='permissions', r
assert 'server repair failed' in r['message'] and 'inspect' not in r['message'], r
PYSERVER
[ "$?" -eq 0 ] || fail 'Apply dropped the server step verdict'
# Previously saved jobs have no step sidecar. Match the CGI's errexit mode:
# an absent optional report must still return a complete JSON response.
rm "$ROUTER_APPLY_STATUS_FILE.steps"
(set -e; router_apply_status_json) > "$WORK/legacy-status.json"
python3 - "$WORK/legacy-status.json" <<'PYLEGACY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['steps']==[] and r['state']=='failed', r
PYLEGACY
[ "$?" -eq 0 ] || fail 'legacy status response was truncated'
unset XRAY_VPS_JOB_ORIGIN
flock() { return 1; }
profile_request_guard && fail 'busy transaction accepted'
if (: >&6) 2>/dev/null; then fail 'failed lock leaked descriptor'; fi
flock() { return 0; }
printf 'state=running\npid=999999999\nprofile=default\n' > "$ROUTER_APPLY_STATUS_FILE"
router_apply_status_json > "$WORK/interrupted.json"
python3 - "$WORK/interrupted.json" <<'PYINT'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['state']=='failed' and r['router_apply']=='unknown' and r['applied'] is None, r
PYINT
[ "$?" -eq 0 ] || fail 'lost response falsely claimed known application state'
VPS_JOB_DEADLINE=$(($(date +%s) + 1))
rc=0
vps_run_bounded sleep 5 || rc=$?
[ "$rc" = 124 ] || fail 'blocking transport escaped the shared deadline'
trap 'rm -rf "$WORK"' EXIT
printf 'ok\n'
