#!/bin/sh
# Native OpenWrt regression: complete GET dispatch with real stored profiles.
# Only Apply history is isolated; no jobs are launched and no runtime is changed.
# Run on a configured router with this repo staged under /tmp; uses native UCI/jsonfilter.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
command -v jsonfilter >/dev/null
command -v uci >/dev/null
active="$(uci -q get xray_vps.main.active_profile)"
[ -n "$active" ]; uci -q get "xray_vps.$active" >/dev/null
WORK="$(mktemp -d /tmp/vx-status-cgi.XXXXXX)"
chmod 700 "$WORK"
umask 077
# Keep response evidence (contains private profile data); no secret values on stdout.
printf 'evidence=%s\n' "$WORK"
LIB="$ROOT/routers/common/files"
export LIB WORK
export VX_LIB_COMMON="$LIB/lib-common.sh"
export VX_VPS_PROFILE_LIB="$LIB/xray-vps-profile.sh"
export VX_VPS_SSH_LIB="$LIB/xray-vps-ssh.sh"
export VX_VPS_RENDER_LIB="$LIB/xray-vps-render.sh"
export VX_VPS_INSPECT_LIB="$LIB/xray-vps-inspect.sh"
export VX_VPS_ACTIONS_LIB="$LIB/xray-vps-actions.sh"
export VX_VPS_VERIFY_LIB="$LIB/xray-vps-verify.sh"
export VX_VPS_SETUP_LIB="$LIB/xray-vps-setup.sh"
export VX_VPS_JOB_STATUS_LIB="$LIB/xray-vps-job-status.sh"
export VX_VPS_REPAIR_LIB="$WORK/repair-fixture.sh"
cat > "$VX_VPS_REPAIR_LIB" <<'SH'
. "$LIB/xray-vps-repair.sh"
# Isolate only the asynchronous job store, after production library initialization.
VPS_REPAIR_JOB_DIR="$WORK/jobs"
ROUTER_APPLY_STATUS_FILE="$WORK/current"
SH
mkdir "$WORK/jobs" "$WORK/jobs/42-1"
status="$WORK/jobs/42-1/status"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
field() { jsonfilter -i "$body" -e "$1"; }
run() {
 name="$1" expected="$2" query="${3:-action=status}"
 output="$WORK/$platform-$name.cgi"; body="$output.json"
 REQUEST_METHOD=GET QUERY_STRING="$query" sh "$cgi" > "$output" 2> "$output.stderr" || fail "$platform/$name CGI exit"
 # Headers are part of the actual CGI response, not fabricated in the fixture.
 sed '1,/^[[:space:]]*$/d' "$output" > "$body"
 [ "$(jsonfilter -s "[$(cat "$body")]" -t '@[0]')" = object ] || fail "$name invalid JSON"
 [ -z "$(jsonfilter -s "[$(cat "$body")]" -t '@[1]')" ] || fail "$name extra JSON"
 [ "$(field '@.ok')" = true ] || fail "$name outer response failed"
 if [ "$query" = action=status ]; then
  [ "$(field '@.active_profile_id')" = "$active" ] || fail "$name selection changed"
  [ "$(jsonfilter -i "$body" -t '@.profiles')" = array ] || fail "$name missing trailing profiles"
  jsonfilter -i "$body" -e '@.router_current' -e '@.profiles' > "$WORK/current-values"
  if [ -f "$WORK/expected-values" ]; then
   cmp -s "$WORK/current-values" "$WORK/expected-values" || fail "$name live/profile values changed"
  else cp "$WORK/current-values" "$WORK/expected-values"; fi
  job='@.router_apply_job'
 else job='@.job'; fi
 [ "$(field "$job.state")" = "$expected" ] || fail "$name state"
 if [ "$expected" = failed ] && [ "$name" != terminal-rollback ] && [ "$name" != applied-unhealthy ]; then
  [ "$(field "$job.router_apply")" = unknown ] || fail "$name invented outcome"
  [ "$(jsonfilter -i "$body" -t "$job.applied")" = null ] || fail "$name invented applied flag"
  [ -n "$(field "$job.message")" ] || fail "$name missing diagnostic"
 fi
 printf 'PASS %s/%s\n' "$platform" "$name"
}
for platform in asus-tuf-ax4200-openwrt gl-mt3000-glinet; do
 cgi="$ROOT/routers/$platform/files/xray-vps.cgi"
 rm -f "$WORK/current" "$status" "$status.steps" "$status.log"
 run absent idle
 [ ! -e "$WORK/current" ] || fail 'read created history'
 ln -s "$status" "$WORK/current"
 run dangling failed
 : > "$status"
 run empty failed
 printf 'state=done\nprofile=%s\nrouter_apply=applied\npath_health=ok\nmessage=Complete "quoted" \\path=ok\n' "$active" > "$status"
 run complete done
 [ "$(field '@.router_apply_job.applied')" = true ] || fail 'complete result lost'
 [ "$(field '@.router_apply_job.message')" = 'Complete "quoted" \path=ok' ] || fail 'message escaping'
 printf '[{"id":"selected_path","status":"ok","message":"complete"}]\n' > "$status.steps"
 run complete-report done
 [ "$(field '@.router_apply_job.steps[0].id')" = selected_path ] || fail 'steps lost'
 run polling done 'action=apply_router_status&job_id=42-1'
 # Both successful terminal combinations are emitted by the real worker.
 for outcome in applied unchanged; do
  for health in ok not_checked; do
   printf 'state=done\nrouter_apply=%s\npath_health=%s\nmessage=Selected configuration; health=%s\n' "$outcome" "$health" "$health" > "$status"
   run "success-$outcome-$health" done 'action=apply_router_status&job_id=42-1'
  done
 done
 case_index=0
 for fragment in 'state=done' 'state=done
router_apply=applied
message=terminal' 'state=done
path_health=ok
message=terminal' 'state=done
router_apply=applied
path_health=failed
message=terminal' 'state=done
router_apply=rolled_back
path_health=ok
message=terminal'; do
  case_index=$((case_index + 1))
  printf '%s\n' "$fragment" > "$status"
  cp "$status" "$WORK/unchanged"
  run "invalid-done-$case_index" failed 'action=apply_router_status&job_id=42-1'
  cmp -s "$status" "$WORK/unchanged" || fail 'read rewrote incomplete history'
 done
 printf 'state=done\nrouter_apply=applied\npath_health=not_checked\n' > "$status"
 run invalid-done-no-message failed 'action=apply_router_status&job_id=42-1'
 printf 'state=failed\nrouter_apply=applied\npath_health=failed\nmessage=Selected target retained; path failed\n' > "$status"
 run applied-unhealthy failed 'action=apply_router_status&job_id=42-1'
 [ "$(field '@.job.applied')" = true ] || fail 'applied unhealthy outcome lost'
 # Valid array syntax is insufficient: every row is consumed by the UI.
 printf 'state=done\nrouter_apply=applied\npath_health=ok\nmessage=Applied; health=ok\n' > "$status"
 case_index=0
 for report in '[null]' '[{"id":"binary","status":"ok","message":"ready"},null]' '[1]' '["text"]' '[[]]' '[{}]' '[{"id":null,"status":"ok","message":"bad"}]' '[{"id":"test","status":{},"message":"bad"}]' '[{"id":"test","status":"ok","message":[]}]' '[{"id":"test","status":"ok","message":"test","details":{}}]'; do
  case_index=$((case_index + 1))
  printf '%s' "$report" > "$status.steps"
  cp "$status.steps" "$WORK/unchanged"
  run "invalid-shape-$case_index" failed 'action=apply_router_status&job_id=42-1'
  [ "$(field '@.job.steps' | tr -d ' \t\r\n')" = '[]' ] || fail 'invalid report reached consumer'
  cmp -s "$status.steps" "$WORK/unchanged" || fail 'read rewrote invalid report'
 done
 rm "$status.steps"
 printf 'state=running\npid=%s\nprofile=%s\n' "$$" "$active" > "$status"
 cp "$status" "$WORK/unchanged"
 run active running
 cmp -s "$status" "$WORK/unchanged" || fail 'read rewrote active history'
 printf 'state=scheduled\nscheduled_at=%s\n' "$(date +%s)" > "$status"
 run scheduled scheduled
 printf 'state=scheduled\nscheduled_at=1\n' > "$status"
 run stale failed
 printf 'state=running\npid=999999999\n' > "$status"
 run interrupted failed
 for timestamp in 08 999999999999999999999 invalid; do
  printf 'state=scheduled\nscheduled_at=%s\n' "$timestamp" > "$status"
  run "bad-time-$timestamp" failed
 done
 printf 'state=done\nstate=running\n' > "$status"
 run duplicate failed
 printf 'state=done\nrouter_apply=unknown\npath_health=unknown\n' > "$status"
 for report in '' 'not-json' '[] garbage' '{"not":"array"}' '[],[]'; do
  printf '%s' "$report" > "$status.steps"
  cp "$status.steps" "$WORK/unchanged"
  run "bad-report-$(wc -c < "$status.steps" | tr -d ' ')" failed
  cmp -s "$status.steps" "$WORK/unchanged" || fail 'read removed corrupt evidence'
 done
 rm "$status.steps" "$status"
 mkdir "$status"
 run unreadable failed
 rmdir "$status"
 # Incomplete last status line is legal; stored terminal evidence is preserved.
 printf 'state=failed\nrouter_apply=rolled_back\npath_health=failed\nmessage=runtime rejected' > "$status"
 run terminal-rollback failed 'action=apply_router_status&job_id=42-1'
 [ "$(field '@.job.router_apply')" = rolled_back ] || fail 'rollback outcome lost'
 [ "$(field '@.job.applied')" = false ] || fail 'rollback applied flag'
done
