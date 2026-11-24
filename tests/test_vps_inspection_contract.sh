#!/bin/sh
# Real inspection/adoption/render and both workers; SSH/runtime leaves are local.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
PATH="$ROOT/tests/fixtures:$PATH"; export PATH
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for lib in lib-common xray-vps-profile xray-vps-ssh xray-vps-render xray-vps-inspect xray-vps-actions xray-vps-verify xray-vps-setup xray-vps-job-status xray-vps-repair; do
 . "$ROOT/routers/common/files/$lib.sh"
done
fail() { echo "FAIL: $*" >&2; exit 1; }
VPS_PROFILE_ROOT="$WORK/vps"; INSPECT_DIR="$WORK/inspect"; LOCK_ROOT="$WORK/locks"
mkdir -p "$VPS_PROFILE_ROOT/debian-13/files" "$INSPECT_DIR" "$WORK/profile" "$WORK/bin"
cp "$ROOT/vps/debian-13/profile.env" "$VPS_PROFILE_ROOT/debian-13/profile.env"
cp "$ROOT/vps/debian-13/files/xray-vps-config.template.json" "$VPS_PROFILE_ROOT/debian-13/files/"
printf 'VPS_XRAY_BINARY=%s/provision-xray\nVPS_REMOTE_META_PATH=%s/meta\nVPS_XRAY_CONFIG_PATH=%s/server.json\n' "$WORK" "$WORK" "$WORK" >> "$VPS_PROFILE_ROOT/debian-13/profile.env"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/timeout"
printf '#!/bin/sh\necho fixture\n' > "$WORK/bin/hostname"
printf '#!/bin/sh\necho active\n' > "$WORK/bin/systemctl"
printf '#!/bin/sh\necho "LISTEN 0 100 0.0.0.0:443 "\n' > "$WORK/bin/ss"
chmod +x "$WORK/bin/"*
# Remote inspection executes its actual stdin script, but cannot access network.
ssh_cmd() { PATH="$WORK/bin:$PATH" dash -c "${2%sh -s}dash -s"; }
profile_set() { printf '%s' "$3" > "$WORK/profile/$2"; }
profile_get() { cat "$WORK/profile/$2" 2>/dev/null || :; }
profile_del() { rm -f "$WORK/profile/$2"; }
uci() { :; }
profile_set default vps_profile debian-13
profile_set default server_address 38.180.11.240
profile_set default server_port 443
profile_set default ws_path /local-default
cat > "$WORK/meta" <<'META'
XRAY_PORT=443
XRAY_SERVER_NAME=www.wp.pl
XRAY_UUID=test-identity
XRAY_DIAL_MODE=direct
META
printf '%s\n' '{"inbounds":[{"port":443,"settings":{"clients":[{"id":"test-identity"}]},"streamSettings":{"network":"ws","security":"tls","wsSettings":{"path":"/server-owned"}}}]}' > "$WORK/server.json"
# A runnable executable at another location cannot suppress the bundled archive.
printf '#!/bin/sh\necho other-version\n' > "$WORK/bin/xray"
chmod +x "$WORK/bin/xray"
remote_inspect_output default > "$INSPECT_DIR/default.env"
inspected_provision_binary_ready default && fail 'wrong executable path suppressed bundle'
printf '#!/bin/sh\necho broken-version\nexit 1\n' > "$WORK/provision-xray"
chmod +x "$WORK/provision-xray"
remote_inspect_output default > "$INSPECT_DIR/default.env"
[ -n "$(cache_get "$INSPECT_DIR/default.env" REMOTE_XRAY_VERSION)" ] || fail 'fixture did not emit stdout'
inspected_provision_binary_ready default && fail 'nonzero version exit suppressed bundle'
printf '#!/bin/sh\necho working-version\n' > "$WORK/provision-xray"
remote_inspect_output default > "$INSPECT_DIR/default.env"
inspected_provision_binary_ready default || fail 'exact runnable provisioning binary rejected'
# Enter the real Apply worker; preserve the authoritative path in client render.
ROUTER_APPLY_STATUS_FILE="$WORK/apply.status"; VPS_REPAIR_JOB_DIR="$WORK/jobs"
ROUTER_CONFIG="$WORK/client.json"; ROUTER_CERT="$WORK/cert"
ROUTER_READY_FILE="$WORK/ready"; ROUTER_TUNNEL_CONFIG="$WORK/tunnel"
ROUTER_XRAY_BIN=/usr/bin/true; ROUTER_HTTP_PORT=1083; ROUTER_SOCKS_PORT=1084
ROUTER_ACCESS_LOG="$WORK/access"; ROUTER_ERROR_LOG="$WORK/error"; PROFILE_PACKAGE=xray_vps
fetch_profile_tls_cert() { echo cert > "$2"; }
activate_profile_tunnel() { :; }
restart_profile_runtime() { :; }
local_profile_runtime_ready() { :; }
current_switch_state() { echo on; }
verify_applied_profile_path() { :; }
valid_port() { [ "$1" = 443 ]; }
flock() { :; }
REQUEST_DATA=''
printf action=apply_router > "$ROUTER_APPLY_STATUS_FILE.request"
run_router_apply_job default || fail 'Apply did not adopt nondefault WS path'
python3 - "$ROUTER_CONFIG" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['outbounds'][0]['streamSettings']['wsSettings']['path']=='/server-owned'
PY
# Repair must also use that path when staging its server config, then applying.
ensure_ssh_ready() { :; }
status_json() { printf '{}'; }
run_repair_pipeline() {
 render_server_config "$WORK/staged-server.json" "$1"
 REPAIR_REPORT='[{"id":"server_overall","status":"ok","message":"controlled server leaf"}]'
 REPAIR_FATAL=''; REPAIR_RAW_LOG_PATH=''
}
profile_set default ws_path /stale-again
printf old > "$ROUTER_CONFIG"
mkdir -p "$VPS_REPAIR_JOB_DIR/1-1"
printf default > "$VPS_REPAIR_JOB_DIR/1-1/profile"
printf action=diagnose_repair > "$VPS_REPAIR_JOB_DIR/1-1/request"
run_vps_repair_job 1-1 || fail 'Repair did not adopt nondefault WS path'
python3 - "$ROUTER_CONFIG" "$WORK/staged-server.json" "$WORK/server.json" <<'PY'
import json,sys
client,staged,live=(json.load(open(p)) for p in sys.argv[1:])
assert client['outbounds'][0]['streamSettings']['wsSettings']['path']=='/server-owned'
assert staged['inbounds'][0]['streamSettings']['wsSettings']['path']=='/server-owned'
assert live['inbounds'][0]['streamSettings']['wsSettings']['path']=='/server-owned'
PY
rm -rf "$WORK"
trap - EXIT
printf 'PASS: exact runnable executable; authoritative WS path through Apply and Repair\n'
