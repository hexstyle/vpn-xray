#!/usr/bin/env python3
"""Run the real timeout helper with an owned grandchild and a real flock."""
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as td:
    work = Path(td)
    child = work / 'child.sh'
    child.write_text('sleep 60 &\necho $! > "$1"\nwait\n')
    runner = work / 'runner.sh'
    runner.write_text('''
. "$1"
command() { return 1; }
eval "exec 6>&$3 $3>&-"
printf ready > "$2/ready"
vx_run_with_timeout 2 sh "$2/child.sh" "$2/grandchild"
rc=$?
exec 6>&-
printf '%s' "$rc" > "$2/rc"
''')
    unrelated = subprocess.Popen(['sleep', '30'])
    held = (work / 'lock').open('w+')
    fcntl.flock(held, fcntl.LOCK_EX)
    proc = subprocess.Popen(['sh', str(runner), str(ROOT / 'routers/common/files/lib-common.sh'), td, str(held.fileno())], pass_fds=(held.fileno(),))
    held.close()
    proc.wait(timeout=8)
    assert (work / 'rc').read_text() == '124'
    pid = int((work / 'grandchild').read_text())
    for _ in range(40):
        state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
        if not state or state.startswith('Z'):
            break
        time.sleep(.05)
    assert not state or state.startswith('Z'), (pid, state)
    with (work / 'lock').open('r+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    assert unrelated.poll() is None, 'foreign process was signalled'
    unrelated.terminate()
    unrelated.wait(timeout=2)
    # Preserve stdin under both the ordinary and forced-fallback branches.
    for fallback in ['', 'command() { return 1; };']:
        r = subprocess.run(['sh', '-c', '. "$1"; ' + fallback + ' vx_run_with_timeout 2 cat',
                            'sh', str(ROOT / 'routers/common/files/lib-common.sh')],
                           input=b'input-survives\n', capture_output=True, timeout=5)
        assert r.returncode == 0 and r.stdout == b'input-survives\n', r
print('PASS: timeout 124; no running descendant; lock reacquired; stdin preserved')
