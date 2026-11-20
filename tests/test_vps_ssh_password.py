#!/usr/bin/env python3
"""Native password authentication -> production control owner/emitter/UI, stdio only."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
# Reuse reviewer R11 ae6925: native OpenSSH + sshpass over stdio ProxyCommand,
# no TCP, OS accounts or live password failures. Existing development-only
# Paramiko is never deployed to router/VPS.
native_proxy = r'''
import os,paramiko,pathlib,time
w=pathlib.Path(os.environ['AUTH_WORK']);case=os.environ['AUTH_CASE']
def record(event):
 with (w/'events').open('a') as f:f.write(event+'\n')
class Stream:
 def send(self,data):return os.write(1,data)
 def recv(self,n):return os.read(0,n)
 def settimeout(self,value):pass
 def close(self):pass
 def getpeername(self):return ('stdio',0)
class Server(paramiko.ServerInterface):
 def get_allowed_auths(self,user):return 'password' if case=='bad_password_only' else 'password,keyboard-interactive'
 def check_auth_none(self,user):record('none');return paramiko.AUTH_FAILED
 def check_auth_password(self,user,password):
  record('password');record('password-match='+str(password=='fixture-password'))
  return paramiko.AUTH_SUCCESSFUL if case.startswith('remote_child') and password=='fixture-password' else paramiko.AUTH_FAILED
 def check_auth_interactive(self,user,submethods):
  record('keyboard-interactive')
  prompts=[('Password: ',False)]
  if case=='bad_password_then_keyboard_multi':prompts.append(('Verification code: ',False))
  return paramiko.InteractiveQuery('','',*prompts)
 def check_auth_interactive_response(self,responses):record('interactive-response');return paramiko.AUTH_FAILED
 def check_channel_request(self,kind,chanid):return paramiko.OPEN_SUCCEEDED
 def check_channel_exec_request(self,channel,command):record('executed');return True
t=paramiko.Transport(Stream());t.add_server_key(paramiko.RSAKey.generate(2048));t.start_server(server=Server())
end=time.monotonic()+15
while t.is_active() and time.monotonic()<end:
 c=t.accept(.1)
 if c is not None:
  while t.is_active() and time.monotonic()<end:
   if (w/'events').exists() and 'executed' in (w/'events').read_text():
    c.send_stderr(b'remote command error\n');c.send_exit_status(int(case[len('remote_child')]));c.close();time.sleep(.1);t.close();break
   time.sleep(.02)
t.close()
'''
with tempfile.TemporaryDirectory(prefix='vx-native-auth-') as td:
    work=Path(td); binary=work/'bin'; binary.mkdir(); (work/'scratch').mkdir()
    (work/'proxy.py').write_text(native_proxy)
    proxy_command='ProxyCommand='+shlex.join([sys.executable,str(work/'proxy.py')])
    native_ssh=shutil.which('ssh')
    assert native_ssh and shutil.which('sshpass'), 'native OpenSSH/sshpass required'
    shim=r'''
import os,sys,pathlib,subprocess
args=sys.argv[1:]; work=pathlib.Path(os.environ['AUTH_WORK'])
assert 'LogLevel=DEBUG2' in args
command=[NATIVE,'-F','/dev/null','-o',PROXY,'-o','IdentityAgent=none','-o','IdentitiesOnly=yes','-o','CheckHostIP=no','-o','CanonicalizeHostname=no']+args
log=pathlib.Path(args[args.index('-E')+1]); (work/'clientpath').write_text(str(log))
if os.environ['AUTH_CASE'].endswith(('_empty_log','_truncated_log')):
 # Filesystem diagnostic leaf, after genuine successful native authentication
 # and command execution. No auth failure or phase messages are fabricated.
 result=subprocess.run(command)
 log.write_text('' if os.environ['AUTH_CASE'].endswith('_empty_log') else 'debug1: Next authentication method: keyboard-interactive\n')
 sys.exit(result.returncode)
os.execv(NATIVE,command)
'''.replace('NATIVE',repr(native_ssh)).replace('PROXY',repr(proxy_command))
    (binary/'ssh').write_text('#!'+sys.executable+'\n'+shim); (binary/'ssh').chmod(0o755)
    native_driver=r'''
for lib in lib-common xray-vps-ssh xray-vps-repair; do . "$AUTH_ROOT/routers/common/files/$lib.sh"; done
KNOWN_HOSTS="$AUTH_WORK/known-hosts"; SSH_RAW_LOG_PATH="$AUTH_WORK/control.log"
# Preserve primary native phase evidence for assertions before owner cleanup.
rm() { for f in "$@"; do if [ "$f" = "$(cat "$AUTH_WORK/clientpath" 2>/dev/null)" ]; then cp "$f" "$AUTH_WORK/native.log"; fi; done; command rm "$@"; }
printf() { if [ "$AUTH_CASE" = bad_password_then_keyboard_log_fail ] && [ "$#" = 1 ] && [ "$1" = '\n' ]; then return 1; fi; command printf "$@"; }
rc=0
SSHPASS=fixture-password ssh_control_run 12 password '' 192.0.2.1 22 fixture 'true fixture-command-private' </dev/null || rc=$?
printf 'native_rc=%s kind=%s\n' "$rc" "$SSH_FAILURE_KIND"
emit_repair_credentials_required fixture "$(raw_log_payload "$SSH_RAW_LOG_PATH")"
'''
    base=work
    results=[]
    cases=['bad_password_only','bad_password_then_keyboard','bad_password_then_keyboard_multi','remote_child5','remote_child6','remote_child7',
           'bad_password_then_keyboard_log_fail','remote_child5_empty_log','remote_child5_truncated_log']
    for case in cases:
        work=base/case; work.mkdir(); (work/'scratch').mkdir()
        for name in ('known-hosts','events','control.log','native.log','clientpath'):(work/name).unlink(missing_ok=True)
        r=subprocess.run(['sh','-c',native_driver],env=dict(os.environ,AUTH_ROOT=str(ROOT),AUTH_WORK=str(work),AUTH_CASE=case,
            TMPDIR=str(work/'scratch'),PATH=str(binary)+':'+os.environ['PATH']),text=True,capture_output=True,timeout=22)
        assert r.returncode==0,(case,r.stdout,r.stderr)
        data=json.loads(r.stdout.split('\n\n',1)[1]); results.append(data)
        events=(work/'events').read_text().splitlines()
        expected='credentials_required' if case in ('bad_password_only','bad_password_then_keyboard','bad_password_then_keyboard_multi') else ('ssh_local' if case.endswith('log_fail') else 'ssh_remote')
        assert data['error']==expected,(case,events,r.stdout,r.stderr)
        assert events.count('executed')==(1 if case.startswith('remote_child') else 0),(case,events)
        assert events.count('password')==1,(case,events)
        evidence=(work/'native.log').read_text()
        if case in ('bad_password_then_keyboard','bad_password_then_keyboard_multi'):
            assert 'keyboard-interactive' in events and 'Permission denied' not in evidence
            assert 'debug2: input_userauth_info_req: num_prompts '+('2' if case.endswith('_multi') else '1') in evidence
            assert 'auth_phase=password_rejected' in data['raw_log']
        if case in ('remote_child5','remote_child6','remote_child7'):
            assert 'Authenticated to ' in evidence and 'debug1: Exit status '+case[-1] in evidence
            assert 'auth_phase=authenticated' in data['raw_log']
        for secret in ('fixture-password','fixture-command-private','debug1:','debug2:','BEGIN RSA PRIVATE KEY'):
            assert secret not in data['raw_log'],(case,secret)
        assert not list((work/'scratch').iterdir()),'native RPC tempfiles leaked'
        print('PASS: native stdio auth -> actual owner/emitter:',case,expected,'executions='+str(events.count('executed')))
    (work/'results.json').write_text(json.dumps(results))
    subprocess.run(['node',str(ROOT/'tests/test_vps_ui_recovery.js'),str(work/'results.json')],cwd=ROOT,check=True)
