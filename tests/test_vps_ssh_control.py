#!/usr/bin/env python3
"""Actual control RPC + inspector/cache owner, with a controlled SSH leaf."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as td:
    work = Path(td)
    bin_dir = work/'bin'; bin_dir.mkdir()
    (work/'scratch').mkdir()
    (work/'key').write_text('fixture')
    (work/'bootstrap').write_text('fixture')
    (work/'meta').write_text('XRAY_UUID=fixture-identity\nXRAY_PRIVATE_KEY=fixture-private\nXRAY_PUBLIC_KEY=fixture-public\nXRAY_PORT=443\nXRAY_SERVER_NAME=example.test\nXRAY_DIAL_MODE=ssh_tunnel\n')
    (work/'config.json').write_text(json.dumps({'inbounds':[{'port':443,'settings':{'clients':[{'id':'fixture-identity'}]},'streamSettings':{'network':'ws','security':'tls','wsSettings':{'path':'/server-owned'}}}]}))
    (work/'xray').write_text('#!/bin/sh\necho fixture-version\n')
    (work/'xray').chmod(0o755)
    for name, body in {'timeout':'exit 1','hostname':'echo fixture','ss':'echo "LISTEN 0 100 0.0.0.0:443 "','systemctl':'echo active'}.items():
        (bin_dir/name).write_text('#!/bin/sh\n'+body+'\n'); (bin_dir/name).chmod(0o755)
    leaf = r'''
import hashlib,json,os,pathlib,subprocess,sys,time
work=pathlib.Path(os.environ['WORK']); args=sys.argv[1:]; payload=sys.stdin.buffer.read()
for fd in (6,9):
 try:os.fstat(fd)
 except OSError:pass
 else:raise AssertionError('transaction FD inherited by SSH')
for option in ('ServerAliveInterval=5','ServerAliveCountMax=2','ConnectTimeout=6','ConnectionAttempts=1','UserKnownHostsFile='+str(work/'known-hosts')):
 assert option in args, option
assert 'StrictHostKeyChecking=accept-new' in args
assert ('LogLevel=DEBUG2' if 'BatchMode=no' in args else 'LogLevel=ERROR') in args
client_log=pathlib.Path(args[args.index('-E')+1])
assert client_log.stat().st_mode & 0o777 == 0o600
assert os.fstat(2).st_mode & 0o777 == 0o600
with (work/'log_paths').open('a') as f:f.write(str(client_log)+'\n')
def client(message):client_log.write_text(message+('\n' if os.environ['LEAF_MODE']=='auth_fallback_lf' else '\r\n'))
calls=work/'calls'
with calls.open('a') as f:f.write(hashlib.sha256(payload).hexdigest()+'\n')
attempt=len(calls.read_text().splitlines()); mode=os.environ['LEAF_MODE']
if mode.startswith('remote_') or mode in ('auth_fallback','auth_fallback_lf','after_execution_reset','disconnect_auth_text') or mode.startswith('password_remote_'):
 if mode.startswith('auth_fallback') and args[args.index('-i')+1]==str(work/'key'):
  client('root@fixture: Permission denied (publickey).');sys.exit(255)
 r=subprocess.run(['sh','-s'],input=payload,capture_output=True)
 sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
 if mode in ('after_execution_reset','disconnect_auth_text'):
  client('Connection reset by peer' if mode=='after_execution_reset' else 'Received disconnect from fixture: root@fixture: Permission denied (publickey).')
  sys.exit(255)
 sys.exit(r.returncode)
if mode.startswith('password_'):
 if 'BatchMode=yes' in args:
  client('root@fixture: Permission denied (publickey).');sys.exit(255)
 assert os.environ.get('SSHPASS')=='fixture-password'
 assert 'NumberOfPasswordPrompts=1' in args
 if mode=='password_auth':client('root@fixture: Permission denied (password).');sys.exit(5)
 if mode=='password_host':client('Host key verification failed.');sys.exit(6)
 client('Timeout, server fixture not responding.');sys.exit(255)
if mode=='deadline':time.sleep(8)
if mode in ('auth','host_key'):
 client('root@fixture: Permission denied (publickey).' if mode=='auth' else 'Host key verification failed.');sys.exit(255)
if mode=='always_loss' or (mode=='first_loss' and attempt==1):
 print('REMOTE_STATUS=ok\nREMOTE_uuid=poison-partial')
 client('Timeout, server fixture not responding.');sys.exit(255)
if mode=='partial_success':print('REMOTE_STATUS=ok\nREMOTE_uuid=poison-partial');sys.exit(0)
r=subprocess.run(['dash','-c',args[-1].removesuffix('sh -s')+'dash -s'],input=payload,capture_output=True)
sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr);sys.exit(r.returncode)
'''
    (bin_dir/'ssh').write_text('#!'+sys.executable+'\n'+leaf)
    (bin_dir/'ssh').chmod(0o755)
    (bin_dir/'sshpass').write_text('#!/bin/sh\nshift\nexec "$@"\n'); (bin_dir/'sshpass').chmod(0o755)
    driver = r'''
set -eu
PROFILE_PACKAGE=xray_vps
KNOWN_HOSTS="$WORK/known-hosts"; INSPECT_DIR="$WORK/inspect"
SSH_RAW_LOG_PATH="$WORK/control.log"
for lib in lib-common xray-vps-ssh xray-vps-render xray-vps-inspect xray-vps-actions xray-vps-repair; do
 . "$ROOT/routers/common/files/$lib.sh"
done
selected_vps_profile() { echo debian-13; }
profile_get() {
 case "$2" in
 managed_key_path) echo "$WORK/key";; bootstrap_key_path) [ "$TEST_AUTH" != mutation ] || echo "$WORK/bootstrap";; ssh_host) echo 10.99.0.2;; ssh_port) echo 22;; ssh_user) echo root;;
 server_port) echo 443;; *) test ! -f "$WORK/profile/$2" || cat "$WORK/profile/$2";; esac
}
profile_set() { printf '%s' "$3" > "$WORK/profile/$2"; }
uci() { :; }
vps_profile_value() {
 case "$2" in
 VPS_REMOTE_META_PATH) echo "$WORK/meta";; VPS_XRAY_CONFIG_PATH) echo "$WORK/config.json";;
 VPS_XRAY_BINARY) echo "$WORK/xray";; esac
}
remote_install_support() { echo 'debian-13|fixture|1|fixture'; }
if [ "$LEAF_MODE" = deadline ]; then VPS_JOB_DEADLINE=$(($(date +%s)+2)); fi
before_deadline="${VPS_JOB_DEADLINE:-}"
exec 6>"$WORK/lock6" 9>"$WORK/lock9"
rc=0
if [ "$TEST_AUTH" = mutation ]; then
 if [ "${LEAF_MODE#password_remote_}" != "$LEAF_MODE" ]; then
  SSHPASS=fixture-password ssh_control_run 20 password '' fixture 22 root 'sh -s' < "$WORK/payload" || rc=$?
 else
  ssh_stdin_cmd default 'sh -s' "$WORK/payload" || rc=$?
 fi
elif [ "$TEST_AUTH" = bootstrap ]; then
 request_value() { [ "$1" != ssh_password ] || printf fixture-password; }
 profile_set default auth_mode password
 ensure_ssh_ready default || rc=$?
 if [ "$rc" -ne 0 ]; then emit_repair_credentials_required fixture ''; fi
elif [ "$TEST_AUTH" = 1 ]; then
 ssh_works default || rc=$?
 if [ "$rc" -ne 0 ]; then emit_repair_credentials_required fixture ''; fi
else
 refresh_remote_cache default || rc=$?
fi
[ "${VPS_JOB_DEADLINE:-}" = "$before_deadline" ]
printf '\nrc=%s kind=%s\n' "$rc" "${SSH_FAILURE_KIND:-}"
exit "$rc"
'''
    for mode, expected_calls, success in [('first_loss',2,True),('always_loss',2,False),('partial_success',1,False),('auth',1,False),('host_key',1,False),('deadline',1,False)]:
        for name in ('inspect','profile'):
            shutil.rmtree(work/name,ignore_errors=True); (work/name).mkdir()
        cache=work/'inspect/default.env'; cache.write_text('old-valid-cache\n')
        private=work/'inspect/default.private'; private.write_text('old-private\n')
        (work/'calls').unlink(missing_ok=True)
        start=time.monotonic()
        r=subprocess.run(['dash','-c',driver],env=dict(os.environ,TMPDIR=str(work/'scratch'),ROOT=str(ROOT),WORK=str(work),
            PATH=str(bin_dir)+':'+os.environ['PATH'],LEAF_MODE=mode,TEST_AUTH='1' if mode in ('auth','host_key') else '0'),
            capture_output=True,text=True,timeout=20)
        assert (r.returncode==0)==success,(mode,r.stdout,r.stderr)
        calls=(work/'calls').read_text().splitlines()
        assert len(calls)==expected_calls,(mode,calls)
        assert len(set(calls))==1,'stdin changed on retry'
        if success:
            assert (work/'profile/uuid').read_text()=='fixture-identity'
            assert (work/'profile/ws_path').read_text()=='/server-owned'
            assert (work/'profile/dial_mode').read_text()=='ssh_tunnel'
            assert 'poison' not in cache.read_text()
            assert 'REMOTE_INSPECTION_COMPLETE=1' in cache.read_text()
        else:
            assert cache.read_text()=='old-valid-cache\n'
            assert private.read_text()=='old-private\n'
            assert not (work/'profile/uuid').exists()
        if mode=='auth':assert 'credentials_required' in r.stdout
        if mode=='host_key':assert 'ssh_host_key' in r.stdout and 'credentials_required' not in r.stdout
        if mode=='deadline':assert time.monotonic()-start<7
        print('PASS:',mode,'attempts='+str(len(calls)),'complete cache only; unchanged global deadline')
    # Transport failure in the credentials phase must not request a password.
    (work/'calls').unlink()
    r=subprocess.run(['dash','-c',driver],env=dict(os.environ,TMPDIR=str(work/'scratch'),ROOT=str(ROOT),WORK=str(work),
        PATH=str(bin_dir)+':'+os.environ['PATH'],LEAF_MODE='always_loss',TEST_AUTH='1'),
        capture_output=True,text=True,timeout=15)
    assert r.returncode and 'ssh_transport' in r.stdout and 'credentials_required' not in r.stdout
    print('PASS: transport refusal has no password prompt')

    for mode, error in [('password_loss','ssh_transport'),('password_host','ssh_host_key'),('password_auth','credentials_required')]:
        (work/'calls').unlink()
        r=subprocess.run(['dash','-c',driver],env=dict(os.environ,TMPDIR=str(work/'scratch'),ROOT=str(ROOT),WORK=str(work),
            PATH=str(bin_dir)+':'+os.environ['PATH'],LEAF_MODE=mode,TEST_AUTH='bootstrap'),
            capture_output=True,text=True,timeout=15)
        assert r.returncode and len((work/'calls').read_text().splitlines())==2,(r.stdout,r.stderr)
        assert '"error":"'+error+'"' in r.stdout,r.stdout
        assert 'fixture-password' not in r.stdout+r.stderr
        print('PASS: actual key refusal -> password bootstrap -> emitter:',error)

    # Inject file-operation failures at the actual publication boundary. The
    # caller remains set +e, as in the real detached repair action.
    cache_driver = driver.replace('set -eu','set +e').replace('rc=0\nif [ "$TEST_AUTH"', r''' 
rc=0
mv() { case "$CACHE_FAULT:$2" in public_mv:"$INSPECT_DIR/default.env"|private_mv:"$INSPECT_DIR/default.private") return 1;; esac; command mv "$@"; }
chmod() { case "$CACHE_FAULT:$*" in chmod:*.inspect.*) return 1;; esac; command chmod "$@"; }
cp() { [ "$CACHE_FAULT" != backup ] || return 1; command cp "$@"; }
printf() { case "$CACHE_FAULT:${2:-}" in public_write:REMOTE_STATUS=*|private_write:fixture-private) return 1;; esac; case "$CACHE_FAULT:$1" in support_write:REMOTE_INSTALL_PROFILE=*) return 1;; esac; command printf "$@"; }
profile_set() { case "$CACHE_FAULT:$2:$3" in freshness_at:last_inspect_at:123|freshness_status:last_inspect_status:old-status) ;; freshness_at:last_inspect_at:*|freshness_status:last_inspect_status:*) return 1;; esac; printf '%s' "$3" > "$WORK/profile/$2"; }
if [ "$TEST_AUTH"''')
    for fault in ('public_mv','private_mv','chmod','backup','public_write','private_write','support_write','freshness_at','freshness_status'):
        for name in ('inspect','profile'):
            shutil.rmtree(work/name); (work/name).mkdir()
        cache=work/'inspect/default.env'; cache.write_text('REMOTE_uuid=old-identity\n')
        private=work/'inspect/default.private'; private.write_text('old-private')
        for key,value in [('last_inspect_status','old-status'),('last_inspect_at','123')]: (work/'profile'/key).write_text(value)
        (work/'calls').unlink(missing_ok=True)
        r=subprocess.run(['dash','-c',cache_driver],env=dict(os.environ,TMPDIR=str(work/'scratch'),ROOT=str(ROOT),WORK=str(work),
            PATH=str(bin_dir)+':'+os.environ['PATH'],LEAF_MODE='success',TEST_AUTH='0',CACHE_FAULT=fault),
            capture_output=True,text=True,timeout=15)
        assert r.returncode!=0,(fault,r.stdout,r.stderr)
        if fault.startswith('freshness_'):
            assert 'REMOTE_uuid=fixture-identity' in cache.read_text() and private.read_text()=='fixture-private',fault
        else:
            assert cache.read_text()=='REMOTE_uuid=old-identity\n' and private.read_text()=='old-private',fault
            assert not (work/'profile/uuid').exists(),fault
        assert (work/'profile/last_inspect_status').read_text()=='old-status'
        assert (work/'profile/last_inspect_at').read_text()=='123'
        assert sorted(p.name for p in (work/'inspect').iterdir())==['default.env','default.private']
        print('PASS: real refresh refuses write failure; coherent cache pair and unchanged freshness:',fault)

    for mode in ['remote_'+str(code) for code in (1,2,5,6,7,255)]+['after_execution_reset','disconnect_auth_text','auth_fallback','auth_fallback_lf']+['password_remote_'+str(code) for code in (5,6,7)]:
        (work/'calls').unlink(missing_ok=True); (work/'executions').unlink(missing_ok=True)
        code=int(mode.rsplit('_',1)[1]) if mode.rsplit('_',1)[1].isdigit() else 0
        (work/'payload').write_text('echo executed >> "$WORK/executions"\nprintf "root@fixture: Permission denied (publickey).\\nHost key verification failed.\\n" >&2\nexit '+str(code)+'\n')
        r=subprocess.run(['dash','-c',driver],env=dict(os.environ,TMPDIR=str(work/'scratch'),ROOT=str(ROOT),WORK=str(work),
            PATH=str(bin_dir)+':'+os.environ['PATH'],LEAF_MODE=mode,TEST_AUTH='mutation'),
            capture_output=True,text=True,timeout=15)
        assert (work/'executions').read_text().splitlines()==['executed'],(mode,r.stdout,r.stderr)
        assert len((work/'calls').read_text().splitlines())==(2 if mode.startswith('auth_fallback') else 1)
        assert len(set((work/'calls').read_text().splitlines()))==1,'fallback stdin changed'
        if mode.startswith('auth_fallback'):assert r.returncode==0,(r.stdout,r.stderr)
        else:assert 'kind='+('transport' if mode=='after_execution_reset' else 'remote') in r.stdout,(mode,r.stdout,r.stderr)
        assert 'fixture-password' not in r.stdout+r.stderr
        print('PASS: executable payload once; diagnostic origin and fallback:',mode)
    for path in (work/'log_paths').read_text().splitlines():assert not Path(path).exists(),'client diagnostic tempfile leaked'
    assert not list((work/'scratch').iterdir()),'control RPC temporary files leaked'
    print('PASS: client/remote logs mode0600; all RPC temporaries cleaned, including bounded timeout')
