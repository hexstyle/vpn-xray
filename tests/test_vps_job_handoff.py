#!/usr/bin/env python3
"""Exercise production schedulers/guards/workers with real inherited flock FDs."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
os.environ['PATH'] = str(ROOT/'tests/fixtures')+':'+os.environ['PATH']
FIXTURE = r'''
set -eu
for lib in lib-common xray-vps-ssh xray-vps-verify xray-vps-actions xray-vps-setup xray-vps-repair; do
 . "$ROOT/routers/common/files/$lib.sh"
done
LOCK_ROOT="$WORK/locks"; ROUTER_APPLY_STATUS_FILE="$WORK/apply.status"
VPS_REPAIR_JOB_DIR="$WORK/jobs"; PROFILE_PACKAGE=xray_vps
flock() { "$PYTHON" "$WORK/flock.py" "$@"; }
profile_del() { :; }
uci() { :; }
active_profile_id() { echo default; }
refresh_remote_cache() { :; }
adopt_remote_into_profile() { :; }
apply_profile_to_router_internal() {
 printf 'executed deadline=%s\n' "$VPS_JOB_DEADLINE" >> "$WORK/executions"
 APPLY_ROUTER_PHASE=applied; APPLY_PATH_HEALTH=ok
}
diagnose_repair_action() {
 apply_profile_to_router_internal default
 emit_header; printf '{"ok":true,"router_apply":"applied","path_health":"ok"}'
}
case "$ROLE" in
 schedule)
  REQUEST_DATA="action=$KIND&request_id=${REQUEST_ID-handoff}"
  profile_request_guard
  if [ "$KIND" = apply_router ]; then schedule_router_apply_job default apply_router
  else schedule_vps_repair_job_action; fi
  ;;
 guard)
  if profile_request_guard; then echo allowed; else echo busy; fi
  ;;
 worker)
  if [ "$KIND" = apply_router ]; then
   XRAY_VPS_JOB_ACCEPTED="$(sed -n 's/^accepted=//p' "$ROUTER_APPLY_STATUS_FILE")"
   run_router_apply_job default
  else run_vps_repair_job "$(cat "$VPS_REPAIR_JOB_DIR/active")"; fi
  ;;
 status)
  REQUEST_DATA="action=apply_router_status&job_id=$POLL_JOB_ID"
  router_apply_status_action
  ;;
esac
'''
FLOCK = '''import fcntl,os,pathlib,sys,time
try: fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError:
 if os.environ.get('BLOCK_WORKER')=='1':
  p=pathlib.Path(os.environ['WORK']); (p/'worker_blocked').touch()
  end=time.monotonic()+20
  while not (p/'release_old').exists():
   if time.monotonic()>end: sys.exit(1)
   time.sleep(.02)
 sys.exit(1)
if os.environ['ROLE']=='guard':
 p=pathlib.Path(os.environ['WORK']); (p/'guard_locked').touch()
 end=time.monotonic()+8
 while not (p/'release_guard').exists():
  if time.monotonic()>end: sys.exit(3)
  time.sleep(.02)
'''


def wait_file(path):
    end = time.monotonic() + 4
    while not path.exists():
        assert time.monotonic() < end, path
        time.sleep(.02)


with tempfile.TemporaryDirectory() as td:
    for kind in ('apply_router', 'diagnose_repair'):
        for scenario in ('interleave', 'acquire_failure', 'launch_failure'):
            work = Path(td) / (kind + '-' + scenario)
            (work / 'bin').mkdir(parents=True)
            (work / 'fixture.sh').write_text(FIXTURE)
            (work / 'flock.py').write_text(FLOCK)
            launch = work / 'bin/start-stop-daemon'
            launch.write_text('#!/bin/sh\nexit "${LAUNCH_RC:-0}"\n')
            launch.chmod(0o755)
            env = dict(os.environ, ROOT=str(ROOT), WORK=str(work), KIND=kind,
                       PYTHON=sys.executable, PATH=str(work / 'bin') + ':' + os.environ['PATH'])
            if scenario == 'launch_failure':
                env['LAUNCH_RC'] = '1'

            def run(role):
                return subprocess.run(['sh', str(work / 'fixture.sh')],
                                      env=dict(env, ROLE=role), capture_output=True,
                                      text=True, timeout=9)

            scheduled = run('schedule')
            assert scheduled.returncode == 0 or scenario == 'launch_failure', scheduled
            if kind == 'apply_router':
                status = (work / 'apply.status').resolve()
                request = Path(str(status) + '.request')
                result = None
            else:
                job = (work / 'jobs/active').read_text().strip()
                status = work / 'jobs' / job / 'status'
                request = status.parent / 'request'
                result = status.parent / 'result'
            accepted = int(next(l.split('=')[1] for l in status.read_text().splitlines()
                                if l.startswith('scheduled_at=')))

            if scenario == 'interleave':
                guard = subprocess.Popen(['sh', str(work / 'fixture.sh')],
                                         env=dict(env, ROLE='guard'), stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, text=True)
                wait_file(work / 'guard_locked')
                worker = subprocess.Popen(['sh', str(work / 'fixture.sh')],
                                          env=dict(env, ROLE='worker'), stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, text=True)
                time.sleep(.3)
                assert worker.poll() is None, 'worker abandoned accepted job during handoff'
                (work / 'release_guard').touch()
                gout, gerr = guard.communicate(timeout=4)
                wout, werr = worker.communicate(timeout=6)
                assert guard.returncode == 0 and gout.strip() == 'busy', (gout, gerr)
                assert worker.returncode == 0, (wout, werr)
                assert (work / 'executions').read_text().splitlines() == [
                    'executed deadline=' + str(accepted + 170)]
                assert 'state=done\n' in status.read_text(), status.read_text()
            elif scenario == 'acquire_failure':
                with (work / 'locks/router-apply.flock').open('r+') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    begin = time.monotonic()
                    failed = run('worker')
                    assert failed.returncode == 1, failed
                    assert time.monotonic() - begin < 7, 'handoff wait was unbounded'
            if scenario != 'interleave':
                assert 'state=failed\n' in status.read_text(), status.read_text()
                assert not (work / 'executions').exists(), 'failed handoff executed mutation'
                if result:
                    verdict = json.loads(result.read_text())
                    assert verdict['error'] == 'job_start_failed' and verdict['applied'] is False
                else:
                    assert 'router_apply=unchanged\n' in status.read_text()
            assert not request.exists(), 'one-shot request survived terminal result'
            with (work / 'locks/router-apply.flock').open('r+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print('PASS:', kind, scenario)

    # Trace the whole accepted identity lifecycle, not only acquisition. The
    # real scheduled grace elapses while an old async writer is paused; a real
    # guard/scheduler then accepts a headless replacement before it resumes.
    for kind in ('apply_router', 'diagnose_repair'):
        for writer in ('launcher', 'worker', 'launched_worker'):
            work = Path(td) / (kind + '-late-' + writer)
            (work / 'bin').mkdir(parents=True)
            (work / 'fixture.sh').write_text(FIXTURE)
            (work / 'flock.py').write_text(FLOCK)
            launch = work / 'bin/start-stop-daemon'
            launch.write_text('''#!/bin/sh
if [ "${BLOCK_LAUNCH:-0}" = 1 ]; then
 touch "$WORK/launch_blocked"
 for n in $(seq 1 20); do
  [ ! -f "$WORK/release_old" ] || exit 1
  sleep 1
 done
 exit 1
fi
exit 0
''')
            launch.chmod(0o755)
            env = dict(os.environ, ROOT=str(ROOT), WORK=str(work), KIND=kind,
                       PYTHON=sys.executable, REQUEST_ID='',
                       PATH=str(work / 'bin') + ':' + os.environ['PATH'])

            def spawn(role, **extra):
                return subprocess.Popen(['sh', str(work / 'fixture.sh')],
                                        env=dict(env, ROLE=role, **extra),
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

            if writer in ('launcher', 'launched_worker'):
                old = spawn('schedule', BLOCK_LAUNCH='1')
                wait_file(work / 'launch_blocked')
            else:
                scheduled = spawn('schedule')
                scheduled.communicate(timeout=4)
                assert scheduled.returncode == 0
                with (work / 'locks/router-apply.flock').open('r+') as held:
                    fcntl.flock(held, fcntl.LOCK_EX)
                    old = spawn('worker', BLOCK_WORKER='1')
                    wait_file(work / 'worker_blocked')
            old_status = ((work / 'apply.status').resolve() if kind == 'apply_router'
                          else work / 'jobs' / (work / 'jobs/active').read_text().strip() / 'status')
            accepted = int(next(l.split('=')[1] for l in old_status.read_text().splitlines()
                                if l.startswith('scheduled_at=')))
            if writer == 'launched_worker':
                worker = spawn('worker')
                worker.communicate(timeout=5)
                assert worker.returncode == 0
                terminal = old_status.read_bytes()
                (work / 'release_old').touch()
                old.communicate(timeout=4)
                assert old.returncode == 0, 'late launcher failure denied an executed job'
                assert old_status.read_bytes() == terminal, 'late failure overwrote worker result'
                assert len((work / 'executions').read_text().splitlines()) == 1
                print('PASS:', kind, 'late launch failure after execution preserves terminal result', flush=True)
                continue
            time.sleep(max(0, accepted + 10.1 - time.time()))
            new = spawn('schedule', KIND='apply_router')
            out, err = new.communicate(timeout=4)
            assert new.returncode == 0, (out, err)
            current = (work / 'apply.status').resolve()
            assert current != old_status, 'new acceptance reused the old generation'
            before = current.read_bytes()
            request = Path(str(current) + '.request')
            request_before = request.read_bytes()
            new_id = next(l.split('=')[1] for l in current.read_text().splitlines()
                          if l.startswith('accepted='))
            (work / 'release_old').touch()
            old.communicate(timeout=4)
            assert current.read_bytes() == before, 'old terminal writer overwrote new status'
            assert request.read_bytes() == request_before, 'old cleanup deleted new request'
            assert 'state=failed\n' in old_status.read_text(), old_status.read_text()
            assert not (work / 'executions').exists()
            worker = spawn('worker', KIND='apply_router')
            worker.communicate(timeout=5)
            assert worker.returncode == 0
            assert len((work / 'executions').read_text().splitlines()) == 1
            poll = spawn('status', POLL_JOB_ID=new_id)
            out, err = poll.communicate(timeout=4)
            assert poll.returncode == 0, err
            assert json.loads(out.split('\n\n', 1)[1])['job']['state'] == 'done'
            if kind == 'apply_router':
                poll = spawn('status', POLL_JOB_ID=old_status.parent.name)
                out, err = poll.communicate(timeout=4)
                assert json.loads(out.split('\n\n', 1)[1])['job']['state'] == 'failed'
            print('PASS:', kind, 'late', writer, 'preserves new headless job and poll identity', flush=True)
