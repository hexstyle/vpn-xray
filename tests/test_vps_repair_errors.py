#!/usr/bin/env python3
"""Real repair worker -> control SSH/pipeline/cache -> public polling terminal."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as td:
    work=Path(td); binary=work/'bin'; binary.mkdir()
    shutil.copytree(ROOT/'vps/debian-13',work/'vps/debian-13',ignore=shutil.ignore_patterns('packages'))
    with (work/'vps/debian-13/profile.env').open('a') as f:
        for k,v in [('VPS_REMOTE_META_PATH',work/'meta'),('VPS_XRAY_CONFIG_PATH',work/'config.json'),('VPS_XRAY_BINARY',work/'xray')]:f.write('\n'+k+'='+str(v)+'\n')
    (work/'xray').write_text('#!/bin/sh\necho fixture-version\n'); (work/'xray').chmod(0o755)
    (work/'key').write_text('fixture'); (work/'bootstrap').write_text('fixture')
    for name, body in {'timeout':'exit 1','hostname':'echo fixture','ss':'echo "LISTEN 0 100 0.0.0.0:443 "','systemctl':'echo active'}.items():
        (binary/name).write_text('#!/bin/sh\n'+body+'\n'); (binary/name).chmod(0o755)
    ssh=r'''
import json,os,pathlib,subprocess,sys
w=pathlib.Path(os.environ['WORK']); mode=os.environ['CASE']; command=sys.argv[-1]; payload=sys.stdin.buffer.read()
if command=='echo ok':print('ok');sys.exit(0)
if command.startswith('timeout '):
 with (w/'mutations').open('a') as f:f.write('executed\n')
 if mode=='cache_fail':
  (w/'meta').write_text((w/'meta').read_text().replace('old-identity','new-identity').replace('old-private','new-private'))
  (w/'config.json').write_text((w/'config.json').read_text().replace('old-identity','new-identity'))
 sys.stdout.write('{"id":"overall","status":"ok","message":"server completed"}'+('' if mode=='valid_no_lf_255' else '\n'))
 if mode.startswith('malformed'):sys.stdout.write('not-json\n' if 'line' in mode else '{"id":')
 sys.exit(255 if mode.endswith('255') else 0)
if command.endswith('sh -s'):
 if (w/'mutations').exists() and mode in ('post_transport','post_host'):
  pathlib.Path(sys.argv[sys.argv.index('-E')+1]).write_text(('Timeout, server fixture not responding.' if mode=='post_transport' else 'Host key verification failed.')+'\n');sys.exit(255)
 r=subprocess.run(['dash','-c',command.removesuffix('sh -s')+'dash -s'],input=payload,capture_output=True)
 sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr);sys.exit(r.returncode)
raise SystemExit('unexpected SSH leaf')
'''
    (binary/'ssh').write_text('#!'+sys.executable+'\n'+ssh);(binary/'ssh').chmod(0o755)
    driver=r'''
set +e
for lib in lib-common xray-vps-profile xray-vps-ssh xray-vps-render xray-vps-inspect xray-vps-actions xray-vps-verify xray-vps-setup xray-vps-repair; do . "$ROOT/routers/common/files/$lib.sh"; done
PROFILE_PACKAGE=xray_vps; KNOWN_HOSTS="$WORK/known-hosts"; VPS_PROFILE_ROOT="$WORK/vps"
INSPECT_DIR="$WORK/inspect"; LOCK_ROOT="$WORK/locks"; VPS_REPAIR_JOB_DIR="$WORK/jobs"
profile_get() {
 case "$2" in
 vps_profile) echo debian-13;; managed_key_path) echo "$WORK/key";; bootstrap_key_path) echo "$WORK/bootstrap";;
 ssh_host|server_address) echo 10.99.0.2;; ssh_port) echo 22;; ssh_user) echo root;;
 *) cat "$WORK/profile/$2" 2>/dev/null || :;; esac
}
profile_set() { printf '%s' "$3" > "$WORK/profile/$2"; }
profile_del() { rm -f "$WORK/profile/$2"; }
uci() { :; }
status_json() { printf '{}'; }
flock() { :; }
mv() { if [ "$CASE" = cache_fail ] && [ -f "$WORK/mutations" ] && [ "$2" = "$INSPECT_DIR/default.env" ]; then return 1; fi; command mv "$@"; }
date() { if [ "$CASE" = post_deadline ] && [ -f "$WORK/mutations" ] && [ "$1" = +%s ]; then echo $(($(command date +%s)+171)); else command date "$@"; fi; }
apply_profile_to_router_internal() { echo unexpected > "$WORK/applied"; return 1; }
run_vps_repair_job 1-1; rc=$?
printf '%s\n' "$rc" > "$WORK/worker.rc"
REQUEST_DATA='action=diagnose_repair_status&job_id=1-1'
vps_repair_job_status_action > "$WORK/poll"
exit 0
'''
    results=[]
    for mode in ('post_transport','post_host','post_deadline','malformed_line_0','malformed_line_255','malformed_partial_0','malformed_partial_255','valid_no_lf_255','cache_fail'):
        for name in ('inspect','profile','jobs','locks'):
            shutil.rmtree(work/name,ignore_errors=True); (work/name).mkdir()
        for name in ('mutations','applied'): (work/name).unlink(missing_ok=True)
        (work/'meta').write_text('XRAY_UUID=old-identity\nXRAY_PRIVATE_KEY=old-private\nXRAY_PUBLIC_KEY=fixture-public\nXRAY_PORT=443\nXRAY_SERVER_NAME=example.test\nXRAY_DIAL_MODE=ssh_tunnel\n')
        (work/'config.json').write_text(json.dumps({'inbounds':[{'port':443,'settings':{'clients':[{'id':'old-identity'}]},'streamSettings':{'network':'ws','security':'tls','wsSettings':{'path':'/server-owned'}}}]}))
        (work/'jobs/1-1').mkdir(); (work/'jobs/1-1/profile').write_text('default')
        (work/'jobs/1-1/request').write_text('action=diagnose_repair&request_id=fixture')
        r=subprocess.run(['bash','-c',driver],env=dict(os.environ,ROOT=str(ROOT),WORK=str(work),CASE=mode,
            PATH=str(binary)+':'+str(ROOT/'tests/fixtures')+':'+os.environ['PATH']),capture_output=True,text=True,timeout=30)
        assert r.returncode==0,(mode,r.stderr)
        result=json.loads((work/'jobs/1-1/result').read_text())
        poll=json.loads((work/'poll').read_text().split('\n\n',1)[1])
        assert result==poll and result['ok'] is False,(mode,result,poll)
        results.append(poll)
        assert (work/'worker.rc').read_text().strip()==('124' if mode=='post_deadline' else '1')
        assert (work/'mutations').read_text().splitlines()==['executed']
        assert not (work/'applied').exists()
        assert 'state=done' in (work/'jobs/1-1/status').read_text()
        for name in ('request','request.running','response.raw'):assert not (work/'jobs/1-1'/name).exists()
        if mode.startswith('post_'):
            expected={'post_transport':'transport','post_host':'host_key','post_deadline':'deadline'}[mode]
            assert expected in result['steps'][-1]['message'],result
            assert {'post_transport':'Timeout, server','post_host':'Host key verification failed','post_deadline':'exit=124 kind=deadline'}[mode] in result['raw_log'],result
            assert 'repair pipeline finished with exit=0' in result['raw_log'],result
        if mode.startswith('malformed'):
            assert result['steps']==[] and 'Malformed or truncated' in result['reason'],result
            assert result['error']=='pipeline_report_failed',result
            assert ('not-json' if 'line' in mode else '{"id":') in result['raw_log'],result
        if mode=='valid_no_lf_255':
            assert result['steps'][0]['id']=='server_overall' and result['steps'][-1]['status']=='failed',result
        if mode=='cache_fail':
            assert 'publication failed' in result['steps'][-1]['message'],result
            assert (work/'profile/uuid').read_text()=='old-identity'
            assert (work/'profile/private_key').read_text()=='old-private'
            assert 'REMOTE_uuid=old-identity' in (work/'inspect/default.env').read_text()
            assert (work/'inspect/default.private').read_text()=='old-private'
        print('PASS:',mode,'actual worker/poll terminal JSON; mutation once; request cleanup')
    (work/'results.json').write_text(json.dumps(results))
    subprocess.run(['node',str(ROOT/'tests/test_vps_ui_recovery.js'),str(work/'results.json')],cwd=ROOT,check=True)
