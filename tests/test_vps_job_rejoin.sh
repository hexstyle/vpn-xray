#!/bin/sh
# Actual schedulers, response-rejoin and status consumer; launch is a leaf stub.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for lib in lib-common xray-vps-actions xray-vps-setup xray-vps-repair; do
 . "$ROOT/routers/common/files/$lib.sh"
done
fail() { echo "FAIL: $*" >&2; exit 1; }
LOCK_ROOT="$WORK/locks"; VPS_REPAIR_JOB_DIR="$WORK/jobs"
ROUTER_APPLY_STATUS_FILE="$WORK/apply.status"
active_profile_id() { echo default; }
flock() { :; }
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nprintf "launched\\n" >> "$WORK/launches"\n' > "$WORK/bin/start-stop-daemon"
chmod +x "$WORK/bin/start-stop-daemon"
export WORK
PATH="$WORK/bin:$PATH"
REQUEST_DATA='action=diagnose_repair&request_id=lost-reply'
schedule_vps_repair_job_action >/dev/null # deliberately discard scheduling response
job=$(cat "$VPS_REPAIR_JOB_DIR/active")
resume_profile_request > "$WORK/rejoined"
python3 - "$WORK/rejoined" "$job" <<'PY'
import json,sys
r=json.loads(open(sys.argv[1]).read().split('\n\n',1)[1])
assert r['ok'] and r['rejoined'] and r['job_id']==sys.argv[2], r
PY
[ "$(wc -l < "$WORK/launches" | tr -d ' ')" = 1 ] || fail 'retry launched a second mutation'
printf '{"ok":false,"router_apply":"applied","path_health":"failed","marker":"original-job"}' > "$VPS_REPAIR_JOB_DIR/$job/result"
printf 'state=done\norigin=diagnose_repair\nrequest_id=lost-reply\n' > "$VPS_REPAIR_JOB_DIR/$job/status"
resume_profile_request >/dev/null || fail 'terminal job could not be rejoined'
REQUEST_DATA="action=diagnose_repair_status&job_id=$job"
vps_repair_job_status_action > "$WORK/result"
grep -q 'original-job' "$WORK/result" || fail 'retry did not recover original result'
REQUEST_DATA='action=apply_router&request_id=apply-reply'
schedule_router_apply_action_for apply_router default >/dev/null
resume_profile_request > "$WORK/apply-rejoined"
grep -q '"rejoined":true' "$WORK/apply-rejoined" || fail 'Apply could not rejoin'
[ "$(wc -l < "$WORK/launches" | tr -d ' ')" = 2 ] || fail 'Apply retry spawned again'
REQUEST_DATA='action=diagnose_repair&request_id=different-request'
if resume_profile_request >/dev/null; then fail 'unrelated request rejoined'; fi
emit_profile_busy > "$WORK/busy"
grep -q '"job_kind":"apply_router"' "$WORK/busy" || fail 'busy response lost active reference'
printf 'PASS: lost Repair/Apply reply rejoins original job; terminal result retained; no duplicate launch\n'
