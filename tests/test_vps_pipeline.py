#!/usr/bin/env python3
"""Both real renderers, repair caller, and full assembled pipeline with local leaves."""
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
os.environ['PATH'] = str(ROOT/'tests/fixtures')+':'+os.environ['PATH']
ROUTER = r'''
. "$ROOT/routers/common/files/lib-common.sh"
. "$ROOT/routers/common/files/xray-vps-ssh.sh"
. "$ROOT/routers/common/files/xray-vps-render.sh"
selected_vps_profile() { echo debian-13; }
vps_profile_value() { printenv "$2"; }
profile_get() {
 case "$2" in
 server_port) echo "$XRAY_PORT";; server_name) echo "$XRAY_SERVER_NAME";;
 uuid) echo "$XRAY_UUID";; ws_path) printf '%s\n' "$XRAY_WS_PATH";;
 server_address|ssh_host) echo 192.0.2.1;; dial_mode) echo ssh_tunnel;;
 esac
}
'''

with tempfile.TemporaryDirectory() as td:
    work = Path(td)
    profile = work / 'vps/debian-13'
    shutil.copytree(ROOT / 'vps/debian-13', profile,
                    ignore=shutil.ignore_patterns('packages', '__pycache__'))
    env = dict(os.environ, ROOT=str(ROOT), VPS_PROFILE_ROOT=str(profile.parent),
               XRAY_PORT='443', XRAY_UUID='00000000-0000-4000-8000-000000000001',
               XRAY_SERVER_NAME='example.test', XRAY_WS_PATH='/server-owned', XRAY_FLOW='',
               XRAY_PRIVATE_KEY='', XRAY_SHORT_ID='', XRAY_CLIENT_FLOW_BLOCK='',
               VPS_XRAY_BINARY='/usr/local/bin/xray', VPS_XRAY_CONFIG_DIR='/usr/local/etc/xray',
               VPS_XRAY_CONFIG_PATH='/usr/local/etc/xray/config.json', VPS_XRAY_LOG_DIR='/var/log/xray',
               VPS_XRAY_SERVICE='xray', VPS_REMOTE_META_PATH='/usr/local/etc/xray/meta.env',
               VPS_TLS_CERT_PATH='/usr/local/etc/xray/certs/server.crt',
               VPS_TLS_KEY_PATH='/usr/local/etc/xray/certs/server.key',
               VPS_INSTALL_SCRIPT='files/install-vps.remote.sh',
               VPS_SERVER_CONFIG_TEMPLATE='files/xray-vps-config.template.json')
    template = profile / 'files/install-vps.remote.sh'
    runtime = profile / 'files/install-vps-runtime.remote.sh'
    assembled = template.read_text() + runtime.read_text()
    # Baseline = the pre-split installer (parent of the commit that split it
    # into template + runtime parts). HEAD now holds the split template part,
    # so `HEAD:...install-vps.remote.sh` is no longer the full baseline.
    baseline = subprocess.check_output(['git', 'show', '40e4401^:vps/debian-13/files/install-vps.remote.sh'],
                                       cwd=ROOT, text=True)
    without_capacity = lambda s: re.sub(r'^step_tcp_capacity\(\) \{.*?^\}\n', '', s, flags=re.M | re.S)

    def without_control_policy(text):
        text = re.sub(
            r'^# OpenSSH >=9\.8 enables PerSourcePenalties\..*?^step_ssh_control_policy\(\) \{.*?^\}\n\n',
            '', text, flags=re.M | re.S)
        return text.replace('step_ssh_control_policy || true\n', '')

    assert without_capacity(without_control_policy(assembled)) == without_capacity(baseline), \
        'unrelated pipeline behavior/order changed'

    def render(kind, source, out):
        command = ('. "$VPS_PROFILE_ROOT/debian-13/render-template.sh"; render_template "$INPUT" "$OUTPUT"'
                   if kind == 'workstation' else ROUTER + '\nrender_vps_profile_template default "$INPUT" "$OUTPUT"')
        return subprocess.run(['sh', '-c', command], env=dict(env, INPUT=str(source), OUTPUT=str(out)),
                              capture_output=True, text=True, timeout=10)

    outputs = []
    for kind in ('workstation', 'router'):
        out = work / (kind + '.sh')
        r = render(kind, template, out)
        assert r.returncode == 0, r.stderr
        outputs.append(out.read_text())
        subprocess.run(['sh', '-n', str(out)], check=True)
        assert "TLS_CERT_PATH='/usr/local/etc/xray/certs/server.crt'" in out.read_text()
        config = profile / 'files/xray-vps-config.template.json'
        r = render(kind, config, work / (kind + '.json'))
        assert r.returncode == 0, r.stderr
        expected = re.sub(r'\$\{([A-Z0-9_]+)\}', lambda m: env[m[1]], config.read_text())
        assert (work / (kind + '.json')).read_text() == expected, 'JSON rendering changed'
    assert outputs[0] == outputs[1], 'workstation/router install artifacts differ'

    # Actual repair owner under set +e: bad install assembly cannot reach transport.
    # The fixed staging names are private to this controlled test; refuse to touch
    # any pre-existing files. All inputs contain only synthetic fixture values.
    staging = [Path('/tmp') / n for n in ('codex-router-vps-config.json', 'codex-router-vps-meta.env',
                                         'codex-router-install.remote.sh')]
    assert not any(p.exists() for p in staging), 'test staging names already occupied'
    owner = ROUTER + r'''
. "$ROOT/routers/common/files/xray-vps-repair.sh"
ssh_stdin_cmd() { echo upload >> "$UPLOAD_COUNT"; return 1; }
set +e
run_repair_pipeline default
rc=$?
printf 'rc=%s\nfatal=%s\nlog=%s\n' "$rc" "$REPAIR_FATAL" "$REPAIR_RAW_LOG_PATH"
exit "$rc"
'''
    original = runtime.read_text()
    for fault in ('missing', 'placeholder'):
        if fault == 'missing':
            runtime.unlink()
        else:
            runtime.write_text(original + '\n# ${UNRESOLVED_NATIVE_SETTING}\n')
        for kind in ('workstation', 'router'):
            out = work / (kind + '-bad.sh')
            out.write_text('stale artifact')
            r = render(kind, template, out)
            assert r.returncode != 0 and not out.exists(), (kind, fault, r.stderr)
        count = work / ('uploads-' + fault)
        r = subprocess.run(['sh', '-c', owner], env=dict(env, UPLOAD_COUNT=str(count)),
                           capture_output=True, text=True, timeout=10)
        assert r.returncode == 1 and 'source parts or rendered inputs are invalid' in r.stdout, r
        assert not count.exists(), 'bad assembly reached SSH upload/execute'
        assert not any(p.exists() for p in staging), 'bad assembly retained staged inputs'
        log = Path(next(l[4:] for l in r.stdout.splitlines() if l.startswith('log=')))
        assert 'nothing uploaded' in log.read_text()
        log.unlink()
        runtime.write_text(original)
    print('PASS: both renderers, unchanged non-TCP pipeline/JSON, missing/unresolved source stops real repair before SSH')

    # Execute the entire assembled production entry. Only absolute filesystem
    # roots are remapped into a fixture; sysctl/module/service commands are leaves.
    fs = work / 'fs'
    binary = work / 'bin'
    binary.mkdir()
    state_path = work / 'native.json'
    for name in ('sed', 'tr', 'awk', 'grep', 'dirname', 'head', 'cut', 'cat', 'cp',
                 'mv', 'rm', 'rmdir', 'chmod', 'touch', 'cmp', 'date', 'id', 'sleep'):
        os.symlink(shutil.which(name), binary / name)
    native = r'''
import json,os,pathlib,shutil,stat,sys
name=pathlib.Path(sys.argv[0]).name; args=sys.argv[1:]
fs=pathlib.Path(os.environ['FIXTURE_FS']); p=pathlib.Path(os.environ['NATIVE_STATE']); s=json.loads(p.read_text())
def save(): p.write_text(json.dumps(s))
if name=='sysctl':
 if '-n' in args:
  key=args[-1]; print({'net.ipv4.tcp_mem':s['memory'],'net.ipv4.tcp_congestion_control':s['cc'],
    'net.ipv4.tcp_available_congestion_control':'reno cubic'+(' bbr' if s['available'] else '')}[key])
 else:
  s['applies']+=1;save()
  if s.get('apply_fail'):sys.exit(1)
  lines=pathlib.Path(args[-1]).read_text().splitlines()
  s['memory']=lines[0].split('=',1)[1].strip()
  if not s.get('readback_fail') and len(lines)>1:s['cc']=lines[1].split('=',1)[1].strip()
  save()
elif name=='modprobe':
 s['loads']+=1;save()
 if s.get('unavailable'):sys.exit(1)
 if not s.get('load_no_algorithm'):s['available']=True
 save()
elif name=='mktemp':
 if s.get('unexpected_temp'):print(fs/'unexpected')
 else:os.execv(os.environ['REAL_MKTEMP'],[os.environ['REAL_MKTEMP']]+args)
elif name=='getconf':print(4096)
elif name=='stat':
 f=pathlib.Path(args[-1])
 if not f.exists():sys.exit(1)
 if args[1]=='%a:%u:%g':print('%o:0:0'%stat.S_IMODE(f.stat().st_mode))
 else:print('root:root')
elif name=='install':
 mode=int(args[args.index('-m')+1],8) if '-m' in args else 0o755
 if '-d' in args:
  targets=[x for x in args if x.startswith('/')]
  for x in targets:
   assert x.startswith(str(fs));pathlib.Path(x).mkdir(parents=True,exist_ok=True)
 else:
  src,dst=map(pathlib.Path,args[-2:]);assert str(dst).startswith(str(fs))
  if dst.suffix=='.conf':
   if s.get('persist_fail'):sys.exit(1)
   s['writes']+=1;save()
  shutil.copyfile(src,dst);dst.chmod(mode)
elif name=='systemctl':
 if args[0]=='show':print('root')
elif name=='ss':print('LISTEN 0 100 0.0.0.0:443 ')
elif name in ('chown','nc'):pass
else:raise SystemExit('unexpected command '+name)
'''
    for name in ('sysctl', 'modprobe', 'getconf', 'stat', 'install', 'systemctl', 'ss', 'chown', 'nc', 'mktemp'):
        p = binary / name
        p.write_text('#!' + sys.executable + '\n' + native)
        p.chmod(0o755)
    executable = work / 'pipeline.sh'
    executable.write_text(re.sub(r'(?<![A-Za-z0-9_/])/(etc|tmp|proc|var|usr/local)(?=/)',
                                 lambda m: str(fs) + m[0], outputs[0]))
    run_env = dict(env, PATH=str(binary), FIXTURE_FS=str(fs), NATIVE_STATE=str(state_path), TMPDIR=str(fs / 'tmp'), REAL_MKTEMP=shutil.which('mktemp'))

    def reset(**extra):
        shutil.rmtree(fs, ignore_errors=True)
        for d in ('etc/systemd/system', 'etc/sysctl.d', 'etc/modules-load.d', 'proc', 'tmp',
                  'usr/local/bin', 'usr/local/etc/xray/certs', 'var/log/xray'):
            (fs / d).mkdir(parents=True, exist_ok=True)
        for name in ('etc/systemd/system/xray.service', 'usr/local/etc/xray/config.json',
                     'usr/local/etc/xray/certs/server.crt', 'usr/local/etc/xray/certs/server.key'):
            (fs / name).write_text('fixture\n')
        (fs / 'proc/meminfo').write_text('MemTotal: 1048576 kB\n')
        xray = fs / 'usr/local/bin/xray'; xray.write_text('#!/bin/sh\nexit 0\n'); xray.chmod(0o755)
        state_path.write_text(json.dumps(dict(memory='20000 40000 80000', cc='cubic', available=False,
                                              writes=0, loads=0, applies=0, **extra)))

    def execute(expected, memory='20000 40000 80000'):
        r = subprocess.run(['/bin/sh', str(executable)], env=run_env, capture_output=True, text=True, timeout=15)
        reports = [json.loads(l) for l in r.stdout.splitlines()]
        assert [v['id'] for v in reports] == ['binary','service_unit','directories','permissions','certs',
                                             'config','tcp_capacity','firewall','runtime','overall'], r
        capacity = next(v for v in reports if v['id'] == 'tcp_capacity')
        assert capacity['status'] == expected, (capacity, r.stderr)
        assert r.returncode == (1 if expected == 'failed' else 0), (r.stdout, r.stderr)
        assert json.loads(state_path.read_text())['memory'] == memory, 'incorrect memory watermarks'
        assert not list((fs / 'tmp').glob('vpn-xray-tcp.*')), 'owned TCP staging directory leaked'
        return reports

    reset(); execute('fixed')
    assert (fs / 'etc/modules-load.d/vpn-xray-tcp.conf').read_text() == 'tcp_bbr\n'
    before = state_path.read_text(); execute('ok'); assert state_path.read_text() == before, 'repeat mutated native settings'
    reset(); state = json.loads(state_path.read_text()); state.update(cc='bbr', available=True); state_path.write_text(json.dumps(state))
    execute('fixed'); assert json.loads(state_path.read_text())['applies'] == 0, 'already-active BBR was needlessly reapplied'
    for fault in ('unavailable', 'load_no_algorithm'):
        reset(**{fault: True})
        state = json.loads(state_path.read_text()); state['memory'] = '1 2 3'; state_path.write_text(json.dumps(state))
        reports = execute('fixed', memory='16384 32768 65536')
        capacity = next(v for v in reports if v['id'] == 'tcp_capacity')
        assert 'optional BBR skipped: native support unavailable' in json.dumps(capacity)
        assert 'BBR active' not in json.dumps(capacity)
        assert json.loads(state_path.read_text())['cc'] == 'cubic'
        assert not (fs / 'etc/modules-load.d/vpn-xray-tcp.conf').exists()
        assert 'tcp_congestion_control' not in (fs / 'etc/sysctl.d/99-vpn-xray-tcp.conf').read_text()
        execute('ok', memory='16384 32768 65536')
        assert json.loads(state_path.read_text())['applies'] == 1
    for fault in ('persist_fail', 'apply_fail', 'readback_fail'):
        reset(**{fault: True}); execute('failed')
    reset(unexpected_temp=True)
    unexpected = fs / 'unexpected'; unexpected.mkdir()
    for name in ('sysctl', 'modules', 'unrelated'): (unexpected / name).write_text('untouched')
    reports = execute('failed')
    assert 'unexpected TCP staging path' in json.dumps(reports)
    assert all((unexpected / name).read_text() == 'untouched' for name in ('sysctl', 'modules', 'unrelated'))
    assert json.loads(state_path.read_text())['writes'] == 0
    print('PASS: full pipeline BBR load/availability, optional unavailable BBR, missing persistence, no-op, memory repair, safe cleanup and failure verdicts')

    # Positive caller link: consume its actual tar, execute the uploaded entry
    # with the same controlled native leaves, and return its real JSONL report.
    reset()
    transport = work / 'transport.py'
    expected = work / 'expected-install.sh'; expected.write_text(outputs[0])
    transport.write_text(r'''
import os,pathlib,re,subprocess,sys,tarfile
assert 'timeout 90 sh /tmp/install-vps.remote.sh' in sys.argv[1]
with tarfile.open(sys.argv[2]) as tar:
 script=tar.extractfile('./install-vps.remote.sh').read().decode()
 assert script==pathlib.Path(os.environ['EXPECTED_INSTALL']).read_text()
 assert 'XRAY_DIAL_MODE=ssh_tunnel' in tar.extractfile('./codex-router-meta.env').read().decode()
 assert tar.extractfile('./codex-router-vps-config.json').read()
pathlib.Path(os.environ['UPLOAD_COUNT']).write_text('1')
script=re.sub(r'(?<![A-Za-z0-9_/])/(etc|tmp|proc|var|usr/local)(?=/)',
              lambda m: os.environ['FIXTURE_FS']+m[0],script)
entry=pathlib.Path(os.environ['FIXTURE_FS'])/'uploaded.sh';entry.write_text(script)
env=dict(os.environ,PATH=os.environ['FIXTURE_PATH'])
r=subprocess.run(['/bin/sh',str(entry)],env=env,capture_output=True,text=True,timeout=15)
sys.stdout.write(r.stdout);sys.stderr.write(r.stderr);sys.exit(r.returncode)
''')
    good_owner = owner[:owner.index('ssh_stdin_cmd()')] + r'''
profile_cache_path() { echo fixture; }
cache_get() {
 case "$2" in REMOTE_ARCH) echo x86_64;; REMOTE_XRAY_BINARY) echo "$VPS_XRAY_BINARY";; REMOTE_XRAY_RUNNABLE) echo 1;; esac
}
ssh_stdin_cmd() { "$PYTHON" "$TRANSPORT" "$2" "$3"; }
set +e
run_repair_pipeline default
rc=$?
printf 'report=%s\nlog=%s\n' "$REPAIR_REPORT" "$REPAIR_RAW_LOG_PATH"
exit "$rc"
'''
    count = work / 'good-upload'
    r = subprocess.run(['sh', '-c', good_owner], env=dict(env, PYTHON=sys.executable,
        TRANSPORT=str(transport), EXPECTED_INSTALL=str(expected), UPLOAD_COUNT=str(count),
        FIXTURE_FS=str(fs), FIXTURE_PATH=str(binary), NATIVE_STATE=str(state_path), TMPDIR=str(fs / 'tmp'), REAL_MKTEMP=shutil.which('mktemp')),
        capture_output=True, text=True, timeout=25)
    assert r.returncode == 0 and count.read_text() == '1', r
    report = json.loads(next(l[7:] for l in r.stdout.splitlines() if l.startswith('report=')))
    assert report[-1]['id'] == 'server_overall' and report[-1]['status'] == 'ok', report
    assert next(v for v in report if v['id'] == 'tcp_capacity')['status'] == 'fixed'
    Path(next(l[4:] for l in r.stdout.splitlines() if l.startswith('log='))).unlink()
    assert not any(p.exists() for p in staging)
    print('PASS: actual repair owner assembles/bundles, controlled transport executes uploaded full entry, actual report returns')

    # Lost upload response must not replay a mutation, even with another key.
    ssh_leaf = work/'ssh-loss'; ssh_leaf.mkdir()
    (ssh_leaf/'ssh').write_text('#!/bin/sh\ncat >/dev/null\necho called >> "$UPLOAD_COUNT"\nwhile [ "$1" != -E ]; do shift; done; shift\necho "Timeout, server fixture not responding." > "$1"\nexit 255\n')
    (ssh_leaf/'ssh').chmod(0o755)
    for name in ('managed-key','bootstrap-key'): (work/name).write_text('fixture')
    loss_owner = good_owner.replace('ssh_stdin_cmd() { "$PYTHON" "$TRANSPORT" "$2" "$3"; }', r'''
profile_get() {
 case "$2" in
 managed_key_path) echo "$CONTROL_KEYS/managed-key";;
 bootstrap_key_path) echo "$CONTROL_KEYS/bootstrap-key";;
 server_port) echo "$XRAY_PORT";; server_name) echo "$XRAY_SERVER_NAME";;
 uuid) echo "$XRAY_UUID";; ws_path) printf '%s\n' "$XRAY_WS_PATH";;
 server_address|ssh_host) echo 192.0.2.1;; dial_mode) echo ssh_tunnel;; esac
}
KNOWN_HOSTS="$CONTROL_KEYS/known-hosts"
''')
    loss_count = work/'lost-mutation-count'
    r = subprocess.run(['sh','-c',loss_owner], env=dict(env, CONTROL_KEYS=str(work),
        PATH=str(ssh_leaf)+':'+os.environ['PATH'],UPLOAD_COUNT=str(loss_count)),
        capture_output=True,text=True,timeout=15)
    assert r.returncode==1 and loss_count.read_text().splitlines()==['called'], r
    assert 'report=[]' in r.stdout
    Path(next(l[4:] for l in r.stdout.splitlines() if l.startswith('log='))).unlink()
    print('PASS: actual mutation pipeline/SSH wrapper execute once after lost response with two available keys')

    # Desktop entry points use synthetic SSH leaves, then the actual assembled
    # entry writes staged config/meta. Later run the real router inspector/adopter.
    import shlex
    (work / 'common/lib').mkdir(parents=True)
    shutil.copy(ROOT / 'common/lib/env.sh', work / 'common/lib/env.sh')
    shutil.copy(ROOT / 'common/adopt-vps-meta.sh', work / 'common/adopt-vps-meta.sh')
    desktop_bin = work / 'desktop-bin'; desktop_bin.mkdir()
    desktop_ssh = desktop_bin / 'ssh'
    desktop_ssh.write_text('#!' + sys.executable + '\n' + r'''
import json,os,pathlib,re,subprocess,sys
fs=pathlib.Path(os.environ['FIXTURE_FS']); command=sys.argv[-1]
meta=fs/'usr/local/etc/xray/meta.env'; config=fs/'usr/local/etc/xray/config.json'
if command=='true': pass
elif command.startswith("cat '"):
 p=config if 'config.json' in command else meta
 if p.exists():sys.stdout.write(p.read_text())
elif command.startswith('XRAY_PORT='):
 sys.stdin.read()
 print('OS_ID=debian\nOS_VERSION=13\nARCH=x86_64\nPKG_MGR=apt-get\nSYSTEMD=1\nXRAY_PRESENT=1\nIPV4_ADDR=192.0.2.1\nPORT_OWNER=xray\nOUTBOUND_HTTPS=0')
elif command.startswith('cat > /tmp/'):
 dest=command.split()[2];p=fs/dest.lstrip('/');p.write_bytes(sys.stdin.buffer.read())
elif command=='sh /tmp/install-vps.remote.sh':
 script=(fs/'tmp/install-vps.remote.sh').read_text()
 script=re.sub(r'(?<![A-Za-z0-9_/])/(etc|tmp|proc|var|usr/local)(?=/)',lambda m:str(fs)+m[0],script)
 p=fs/'desktop-entry.sh';p.write_text(script)
 r=subprocess.run(['/bin/sh',str(p)],env=dict(os.environ,PATH=os.environ['FIXTURE_PATH']),capture_output=True,text=True)
 reports=[json.loads(line) for line in r.stdout.splitlines()]
 assert next(v for v in reports if v['id']=='config')['status']=='fixed'
 assert reports[-1]['status']=='ok'
 sys.exit(r.returncode)
elif command.startswith('EXPECTED_UUID='):
 # Existing unrelated desktop final verifier is a transport leaf here.
 sys.stdin.read()
else:raise SystemExit('unexpected controlled SSH command')
''')
    desktop_ssh.chmod(0o755)
    # Prevent external HTTP in the actual inspection script; keep real Python
    # JSON parsing and production adoption, with only SSH/UCI native leaves.
    (desktop_bin / 'timeout').write_text('#!/bin/sh\nexit 1\n')
    (desktop_bin / 'timeout').chmod(0o755)
    for name in ('systemctl', 'ss'): os.symlink(binary / name, desktop_bin / name)
    desktop_env = dict(run_env, PATH=str(desktop_bin)+':'+os.environ['PATH'],
                       FIXTURE_PATH=str(binary), ENV_FILE=str(work/'install.env'))
    initial_meta = dict(XRAY_UUID=env['XRAY_UUID'], XRAY_PORT='443', XRAY_SERVER_NAME='example.test',
                        XRAY_PRIVATE_KEY='fixture-private', XRAY_PUBLIC_KEY='fixture-public', XRAY_SHORT_ID='12345678')
    def desktop_start(mode='ssh_tunnel', path='/server-owned', legacy=False):
        reset()
        values = dict(initial_meta)
        if not legacy: values.update(XRAY_DIAL_MODE=mode, XRAY_WS_PATH=path)
        (fs/'usr/local/etc/xray/meta.env').write_text(''.join(k+'='+shlex.quote(v)+'\n' for k,v in values.items()))
        cfg = json.loads((work/'workstation.json').read_text())
        cfg['inbounds'][0]['streamSettings']['wsSettings']['path'] = path
        (fs/'usr/local/etc/xray/config.json').write_text(json.dumps(cfg))
        local = dict(initial_meta, VPS_PROFILE='debian-13', VPS_SSH='root@10.99.0.2', VPS_HOST='10.99.0.2',
                     XRAY_DIAL_MODE='direct', XRAY_WS_PATH='/cdn')
        (work/'install.env').write_text(''.join(k+'='+shlex.quote(v)+'\n' for k,v in local.items()))
    def desktop_adopt():
        return subprocess.run(['bash',str(work/'common/adopt-vps-meta.sh'),str(work/'install.env')],
                              env=desktop_env,capture_output=True,text=True,timeout=20)
    def adopted_values():
        r = subprocess.run(['bash','-c','. "$ENV_FILE"; printf "%s\\n%s\\n" "$XRAY_DIAL_MODE" "$XRAY_WS_PATH"'],
                           env=desktop_env,capture_output=True,text=True,check=True)
        return r.stdout.splitlines()
    inspector = r'''
set -e
PROFILE_PACKAGE=xray_vps
. "$ROOT/routers/common/files/lib-common.sh"
. "$ROOT/routers/common/files/xray-vps-profile.sh"
. "$ROOT/routers/common/files/xray-vps-ssh.sh"
. "$ROOT/routers/common/files/xray-vps-inspect.sh"
. "$ROOT/routers/common/files/xray-vps-actions.sh"
. "$ROOT/routers/common/files/xray-vps-render.sh"
selected_vps_profile() { echo debian-13; }
vps_profile_value() {
 case "$2" in
 VPS_REMOTE_META_PATH) echo "$FIXTURE_FS/usr/local/etc/xray/meta.env";;
 VPS_XRAY_CONFIG_PATH) echo "$FIXTURE_FS/usr/local/etc/xray/config.json";;
 VPS_XRAY_BINARY) echo "$FIXTURE_FS/usr/local/bin/xray";; esac
}
profile_get() {
 case "$2" in
 server_port) echo 443;;
 *) cat "$FIXTURE_FS/adopted-$2" 2>/dev/null || :;; esac
}
ssh_cmd() { dash -c "${2%sh -s}dash -s"; }
profile_cache_path() { echo "$FIXTURE_FS/inspected"; }
profile_set() { printf '%s' "$3" > "$FIXTURE_FS/adopted-$2"; }
private_cache_get() { :; }
uci() { :; }
remote_inspect_output default > "$FIXTURE_FS/inspected"
adopt_remote_into_profile default
ROUTER_ACCESS_LOG="$FIXTURE_FS/access.log"; ROUTER_ERROR_LOG="$FIXTURE_FS/error.log"
ROUTER_HTTP_PORT=1083; ROUTER_SOCKS_PORT=1084
render_router_config "$FIXTURE_FS/client.json" default
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); u=[i for i in c["inbounds"] if i.get("protocol")=="dokodemo-door"]; assert len(u)==1 and u[0]["port"]==1086 and u[0]["streamSettings"]["sockopt"]["tproxy"]=="tproxy", c["inbounds"]' "$FIXTURE_FS/client.json"
'''
    marker = work/'metadata-must-not-execute'
    quoted_path = '/server\'s "quoted" \\path/$(touch '+str(marker)+')'
    for path in ('/server-owned', r'/server\backslash', '/server"quoted', quoted_path):
        desktop_start(path=path)
        r = desktop_adopt(); assert r.returncode == 0, r.stderr
        assert adopted_values() == ['ssh_tunnel',path], (adopted_values(), r.stdout, r.stderr)
        r = subprocess.run(['bash',str(profile/'install-vps.sh')],env=desktop_env,
                           capture_output=True,text=True,timeout=30)
        assert r.returncode == 0, r.stderr
        meta = (fs/'usr/local/etc/xray/meta.env').read_text()
        values = dict(line.split('=',1) for line in meta.splitlines())
        assert shlex.split(values['XRAY_WS_PATH']) == [path] and values['XRAY_DIAL_MODE']=='ssh_tunnel'
        assert json.loads((fs/'usr/local/etc/xray/config.json').read_text())['inbounds'][0]['streamSettings']['wsSettings']['path']==path
        subprocess.run(['sh','-n',str(fs/'usr/local/etc/xray/meta.env')],check=True)
        r = subprocess.run(['dash','-c',inspector],env=desktop_env,capture_output=True,text=True,timeout=15)
        assert r.returncode == 0, (path, r.stderr)
        assert (fs/'adopted-dial_mode').read_text()=='ssh_tunnel'
        assert (fs/'adopted-ws_path').read_text()==path
        client = json.loads((fs/'client.json').read_text())['outbounds'][0]
        assert client['streamSettings']['wsSettings']['path']==path
        assert client['settings']['vnext'][0]['address']=='127.0.0.1'
        assert not marker.exists(), 'metadata was evaluated'
        env['XRAY_WS_PATH'] = path
        server_config = work/'quoted-server.json'
        r = render('router', profile/'files/xray-vps-config.template.json', server_config)
        assert r.returncode==0, r.stderr
        assert json.loads(server_config.read_text())['inbounds'][0]['streamSettings']['wsSettings']['path']==path
        router_meta = work/'quoted-router-meta.env'
        r = subprocess.run(['sh','-c',ROUTER+'\nrender_remote_meta "$OUTPUT" default'],
                           env=dict(env,OUTPUT=str(router_meta)),capture_output=True,text=True)
        assert r.returncode==0, r.stderr
        values = dict(line.split('=',1) for line in router_meta.read_text().splitlines())
        assert shlex.split(values['XRAY_WS_PATH'])==[path]
        r = desktop_adopt(); assert r.returncode==0 and adopted_values()==['ssh_tunnel',path]
    desktop_start(legacy=True)
    r=desktop_adopt(); assert r.returncode==0 and adopted_values()==['direct','/server-owned']
    desktop_start(legacy=True); (fs/'usr/local/etc/xray/config.json').unlink()
    r=desktop_adopt(); assert r.returncode==0 and adopted_values()==['direct','/cdn']
    desktop_start(mode='invalid-mode')
    before=(work/'install.env').read_text(); r=desktop_adopt()
    assert r.returncode!=0 and 'invalid remote XRAY_DIAL_MODE' in r.stderr
    assert (work/'install.env').read_text()==before
    print('PASS: actual desktop adoption/install -> uploaded full pipeline -> router inspection/adoption -> client render; identical client/server paths, legacy defaults, invalid mode refusal')
