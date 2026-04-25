#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/common/lib/env.sh"

usage() {
  cat <<'EOF'
Usage:
  VPS_PASSWORD=... ./bootstrap-router-vps.sh [router-ssh] [vps-host]

Examples:
  VPS_PASSWORD=secret ./bootstrap-router-vps.sh root@192.168.8.1 38.180.250.9
  ROUTER_PASSWORD=routerpass VPS_PASSWORD=secret ./bootstrap-router-vps.sh

Inputs:
  router-ssh      Optional. Defaults to ROUTER_SSH or root@192.168.8.1.
  vps-host        Optional. Defaults to VPS_HOST.

Environment:
  ROUTER_PASSWORD Optional. If set, the script uses non-interactive SSH_ASKPASS
                  for router SSH and bypasses broken local public-key auth.
                  If unset, ssh prompts once and the script reuses that SSH session.
  VPS_PASSWORD    Required. Used by the router to install its managed SSH key on the VPS.
  VPS_SSH_USER    Optional. Defaults to root.
  VPS_SSH_PORT    Optional. Defaults to 22.
  XRAY_PORT       Optional. Defaults to 443.
  XRAY_SERVER     Optional. Defaults to VPS_HOST.
  XRAY_SERVER_NAME Optional. Defaults to the VPS profile server name.

Development note:
  Before testing script changes on a router, commit and push all related local changes first.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

require_local_commands bash ssh ssh-keygen tar python3 curl

ROUTER_SSH="${1:-${ROUTER_SSH:-root@192.168.8.1}}"
VPS_HOST="${2:-${VPS_HOST:-}}"
ROUTER_PROFILE="${ROUTER_PROFILE:-gl-mt3000-glinet}"
VPS_PROFILE="${VPS_PROFILE:-debian-13}"
VPS_PASSWORD="${VPS_PASSWORD:-}"
ROUTER_PASSWORD="${ROUTER_PASSWORD:-}"
VPS_SSH_USER="${VPS_SSH_USER:-root}"
VPS_SSH_PORT="${VPS_SSH_PORT:-22}"
VPS_SSH_HOST="${VPS_SSH_HOST:-$VPS_HOST}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
VPS_SSH_CONNECT_TIMEOUT="${VPS_SSH_CONNECT_TIMEOUT:-30}"
XRAY_RULES_MODE="${XRAY_RULES_MODE:-full}"
POST_APPLY_ROUTER_VPS_SSH_COOLDOWN="${POST_APPLY_ROUTER_VPS_SSH_COOLDOWN:-12}"

require_supported_profile router "$ROOT_DIR" "$ROUTER_PROFILE"
require_supported_profile vps "$ROOT_DIR" "$VPS_PROFILE"
load_profile_defaults "$(router_profile_dir "$ROOT_DIR" "$ROUTER_PROFILE")/profile.env"
load_profile_defaults "$(vps_profile_dir "$ROOT_DIR" "$VPS_PROFILE")/profile.env"

ROUTER_HOST="${ROUTER_HOST:-$(host_from_ssh_target "$ROUTER_SSH")}"
XRAY_PORT="${XRAY_PORT:-443}"
XRAY_SERVER="${XRAY_SERVER:-$VPS_HOST}"
XRAY_SERVER_NAME="${XRAY_SERVER_NAME:-${VPS_DEFAULT_SERVER_NAME:-}}"
XRAY_FLOW="${XRAY_FLOW:-}"
PROFILE_LABEL="${PROFILE_LABEL:-VPS $VPS_HOST}"
PROXY_PORT="${PROXY_PORT:-1083}"
PROFILE_ID="${PROFILE_ID:-}"
VPS_AUTH_MODE="${VPS_AUTH_MODE:-auto}"
REQUESTED_XRAY_RULES_MODE="${XRAY_RULES_MODE:-full}"
BOOTSTRAP_SAFE_XRAY_RULES_MODE="${BOOTSTRAP_SAFE_XRAY_RULES_MODE:-selective}"

info() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

load_rules_git_ssh_private_key() {
  local key_file="${RULES_GIT_SSH_PRIVATE_KEY_FILE:-}"

  if [[ -n "${RULES_GIT_SSH_PRIVATE_KEY:-}" || -z "$key_file" ]]; then
    return 0
  fi
  [[ -r "$key_file" ]] || fail "RULES_GIT_SSH_PRIVATE_KEY_FILE is not readable: $key_file"
  RULES_GIT_SSH_PRIVATE_KEY="$(cat "$key_file")"
}

base64_encode() {
  python3 - 3<&0 <<'PY'
import base64
import os
import sys

with os.fdopen(3, "rb") as fh:
    sys.stdout.write(base64.b64encode(fh.read()).decode("ascii"))
PY
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

load_rules_git_ssh_private_key
RULES_GIT_SSH_PRIVATE_KEY_B64=''
if [[ -n "${RULES_GIT_SSH_PRIVATE_KEY:-}" ]]; then
  RULES_GIT_SSH_PRIVATE_KEY_B64="$(printf '%s' "$RULES_GIT_SSH_PRIVATE_KEY" | base64_encode)"
fi

build_profile_id() {
  local raw="$1"
  local clean

  clean="$(printf '%s' "$raw" | tr '[:upper:] .:' '[:lower:]___' | tr -cd 'a-z0-9_-')"
  [ -n "$clean" ] || clean='vps'
  printf 'vps_%s\n' "$clean"
}

urlencode_pairs() {
  python3 - "$@" <<'PY'
import sys
import urllib.parse

pairs = []
for item in sys.argv[1:]:
    key, value = item.split("=", 1)
    pairs.append((key, value))
print(urllib.parse.urlencode(pairs))
PY
}

build_vps_profile_payload() {
  local action="$1"
  shift || true
  local pairs=(
    "action=$action"
    "profile_id=$PROFILE_ID"
    "label=$PROFILE_LABEL"
    "vps_profile=$VPS_PROFILE"
    "auth_mode=$bootstrap_mode"
    "ssh_host=$VPS_HOST"
    "ssh_port=$VPS_SSH_PORT"
    "ssh_user=$VPS_SSH_USER"
    "server_address=$XRAY_SERVER"
    "server_port=$XRAY_PORT"
    "server_name=$XRAY_SERVER_NAME"
    "flow=$XRAY_FLOW"
  )

  if [[ "$bootstrap_mode" == 'password' ]]; then
    pairs+=("ssh_password=$VPS_PASSWORD")
  else
    pairs+=("bootstrap_private_key=$bootstrap_private_key")
  fi
  while (($# > 0)); do
    pairs+=("$1")
    shift
  done
  urlencode_pairs "${pairs[@]}"
}

extract_http_body() {
  python3 - 3<&0 <<'PY'
import os
import sys

with os.fdopen(3, "r", encoding="utf-8", errors="replace") as fh:
    data = fh.read()
if "\r\n\r\n" in data:
    sys.stdout.write(data.split("\r\n\r\n", 1)[1])
elif "\n\n" in data:
    sys.stdout.write(data.split("\n\n", 1)[1])
else:
    sys.stdout.write(data)
PY
}

assert_apply_response_ok() {
  python3 - 3<&0 <<'PY'
import json
import os
import sys

with os.fdopen(3, "r", encoding="utf-8", errors="replace") as fh:
  raw = fh.read()
if not raw.strip():
  raise SystemExit("Router returned an empty response for apply_profile.")
try:
  payload = json.loads(raw)
except Exception as exc:
  raise SystemExit(f"Router returned invalid JSON: {raw[:200]}")

if not payload.get("ok"):
  raise SystemExit(payload.get("error") or "Router returned an unknown error.")

status = payload.get("status") or {}
router = status.get("router_current") or {}
if not router.get("config_ready"):
  raise SystemExit("Router reported success, but router_current.config_ready is false.")

active_profile_id = status.get("active_profile_id", "")
profiles = {
    item.get("id"): item
    for item in (status.get("profiles") or [])
    if isinstance(item, dict)
}
profile = profiles.get(active_profile_id) or {}
remote = profile.get("remote_cache") or {}

issues = []
if active_profile_id and not profile:
  issues.append(f"Active profile {active_profile_id!r} is missing from router status.")
if remote.get("ssh_ok") not in ("1", 1, True, "true"):
  issues.append("Router cannot SSH into the VPS after apply.")
if remote.get("xray_present") not in ("1", 1, True, "true"):
  issues.append("Xray is missing on the VPS after apply.")
service_state = str(remote.get("xray_service") or "")
if service_state not in ("active", "activating"):
  issues.append(f"VPS xray service state is {service_state or 'unknown'}.")
if not str(remote.get("listener_443") or ""):
  issues.append("VPS is not listening on port 443 after apply.")
router_diff = str(profile.get("router_diff") or "")
remote_diff = str(profile.get("remote_diff") or "")
if router_diff:
  issues.append(f"Router config drift: {router_diff}.")
if remote_diff:
  issues.append(f"VPS config drift: {remote_diff}.")
if issues:
  raise SystemExit(" ".join(issues))

print(active_profile_id)
PY
}

extract_saved_profile_material() {
  python3 - 3<&0 <<'PY'
import json
import os
import sys

with os.fdopen(3, "r", encoding="utf-8", errors="replace") as fh:
  raw = fh.read()
if not raw.strip():
  raise SystemExit("Router returned an empty response for save_profile.")
try:
  payload = json.loads(raw)
except Exception:
  raise SystemExit(f"Router returned invalid JSON: {raw[:200]}")

if not payload.get("ok"):
  raise SystemExit(payload.get("error") or "Router returned an unknown error.")

status = payload.get("status") or {}
active_profile_id = status.get("active_profile_id", "")
profiles = {
    item.get("id"): item
    for item in (status.get("profiles") or [])
    if isinstance(item, dict)
}
profile = profiles.get(active_profile_id) or {}
uuid = profile.get("uuid") or ""
public_key = profile.get("public_key") or ""
short_id = profile.get("short_id") or ""
managed_pubkey = profile.get("managed_pubkey") or ""

if not active_profile_id:
  raise SystemExit("Router did not report an active profile after save_profile.")
if not uuid or not public_key or not short_id or not managed_pubkey:
  raise SystemExit("Router did not return complete generated Xray material after save_profile.")

print("|".join((active_profile_id, uuid, public_key, short_id, managed_pubkey)))
PY
}

assert_rules_sync_summary_ok() {
  python3 - 3<&0 <<'PY'
import os
import sys

fields = {}
with os.fdopen(3, "r", encoding="utf-8", errors="replace") as fh:
  lines = fh.read().splitlines()
for line in lines:
  if "=" not in line:
    continue
  key, value = line.split("=", 1)
  fields[key] = value

last_status = fields.get("last_sync_status", "")
last_message = fields.get("last_sync_message", "")
if last_status != "ok":
  raise SystemExit(last_message or f"Shared rules Git sync did not complete successfully (status={last_status!r}).")

repo_head = fields.get("repo_head", "")
rules_relpath = fields.get("rules_relpath", "")
source_count = fields.get("source_count", "0")
print("|".join((repo_head, rules_relpath, source_count)))
PY
}

assert_router_action_ok() {
  python3 - 3<&0 <<'PY'
import json
import os
import sys

with os.fdopen(3, "r", encoding="utf-8", errors="replace") as fh:
  raw = fh.read()
if not raw.strip():
  raise SystemExit("Router returned an empty JSON response.")
try:
  payload = json.loads(raw)
except Exception:
  raise SystemExit(f"Router returned invalid JSON: {raw[:200]}")

if not payload.get("ok"):
  raise SystemExit(payload.get("error") or "Router returned an unknown error.")

status = payload.get("status") or {}
active_profile_id = status.get("active_profile_id") or ""
if active_profile_id:
  print(active_profile_id)
PY
}

router_switch_state() {
  router_ssh '. /lib/functions/gl_util.sh 2>/dev/null; get_switch_button_status 2>/dev/null || echo unknown' | sed -n '1p'
}

wait_for_proxy() {
  local tries=20

  while [ "$tries" -gt 0 ]; do
    if router_ssh "pid=\$(cat /var/run/codex-xray.pid 2>/dev/null || true); [ -n \"\$pid\" ] && kill -0 \"\$pid\" 2>/dev/null && netstat -ltnp 2>/dev/null | grep -q ':$PROXY_PORT '" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 1
  done

  return 1
}

verify_router_proxy_path() {
  local egress_ip=''

  printf '%s\n' "Checking HTTPS through the router proxy ..." >&2
  curl -fsSI -m 25 -x "http://$ROUTER_HOST:$PROXY_PORT" https://www.google.com >/dev/null

  egress_ip="$(curl -fsS -m 25 -x "http://$ROUTER_HOST:$PROXY_PORT" https://ifconfig.me/ip | tr -d '\r\n')"
  [ -n "$egress_ip" ] || fail "The router proxy answered, but no egress IP was returned."

  if printf '%s' "$XRAY_SERVER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && [[ "$egress_ip" != "$XRAY_SERVER" ]]; then
    fail "Proxy egress IP mismatch: expected $XRAY_SERVER, got $egress_ip."
  fi

  printf '%s\n' "$egress_ip"
}

fetch_vps_state_via_router() {
  local profile_id="$1"

  router_ssh_direct "$ROUTER_SSH" "PROFILE_ID=$(shell_quote "$profile_id") sh -s" <<'EOF'
profile_id="${PROFILE_ID:-}"
key="$(uci -q get xray_vps.$profile_id.managed_key_path 2>/dev/null || true)"
host="$(uci -q get xray_vps.$profile_id.ssh_host 2>/dev/null || true)"
user="$(uci -q get xray_vps.$profile_id.ssh_user 2>/dev/null || true)"
port="$(uci -q get xray_vps.$profile_id.ssh_port 2>/dev/null || true)"
[ -n "$key" ] || exit 1
[ -n "$host" ] || exit 1
[ -n "$user" ] || exit 1
[ -n "$port" ] || port=22

ssh -i "$key" \
  -o BatchMode=yes \
  -o ConnectTimeout=8 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/etc/xray/known_hosts \
  -p "$port" \
  "$user@$host" 'sh -s' <<'"'"'INNER'"'"'
meta='/usr/local/etc/xray/codex-router-meta.env'
[ -f "$meta" ] || exit 1
. "$meta"
service="$(systemctl is-active xray 2>/dev/null || true)"
if ss -ltn 2>/dev/null | grep -q ':443 '; then
  listener_443=1
else
  listener_443=0
fi
printf 'uuid=%s\n' "${XRAY_UUID:-}"
printf 'public_key=%s\n' "${XRAY_PUBLIC_KEY:-}"
printf 'short_id=%s\n' "${XRAY_SHORT_ID:-}"
printf 'service=%s\n' "$service"
printf 'listener_443=%s\n' "$listener_443"
INNER
EOF
}

assert_vps_state_matches_expected() {
  local expected_uuid="$1"
  local expected_public_key="$2"
  local expected_short_id="$3"

  python3 - "$expected_uuid" "$expected_public_key" "$expected_short_id" 3<&0 <<'PY'
import os
import sys

expected_uuid, expected_public_key, expected_short_id = sys.argv[1:4]
fields = {}
with os.fdopen(3, "r", encoding="utf-8", errors="replace") as fh:
    payload = fh.read()
for line in payload.splitlines():
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    fields[key] = value

issues = []
if fields.get("uuid") != expected_uuid:
    issues.append(f"uuid mismatch: expected {expected_uuid}, got {fields.get('uuid') or 'missing'}")
if fields.get("public_key") != expected_public_key:
    issues.append("public_key mismatch")
if fields.get("short_id") != expected_short_id:
    issues.append(f"short_id mismatch: expected {expected_short_id}, got {fields.get('short_id') or 'missing'}")
if fields.get("service") not in {"active", "activating"}:
    issues.append(f"xray service state is {fields.get('service') or 'unknown'}")
if fields.get("listener_443") != "1":
    issues.append("port 443 listener is missing")

if issues:
    raise SystemExit("; ".join(issues))
PY
}

validate_vps_state_via_router() {
  local profile_id="$1"
  local expected_uuid="$2"
  local expected_public_key="$3"
  local expected_short_id="$4"
  local response=''
  local tries=10

  while (( tries > 0 )); do
    wait_for_router_direct_ssh >/dev/null 2>&1 || {
      tries=$((tries - 1))
      sleep 5
      continue
    }
    response="$(fetch_vps_state_via_router "$profile_id" 2>/dev/null || true)"
    if [[ -n "$response" ]] && printf '%s' "$response" | assert_vps_state_matches_expected "$expected_uuid" "$expected_public_key" "$expected_short_id" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 10
  done

  if [[ -z "$response" ]]; then
    fail "Router could not SSH into the selected VPS with the managed key after apply."
  fi
  printf '%s' "$response" | assert_vps_state_matches_expected "$expected_uuid" "$expected_public_key" "$expected_short_id"
}

refresh_profile_cache_best_effort() {
  local payload
  payload="$(urlencode_pairs "action=inspect_vps" "profile_id=$PROFILE_ID")"
  router_cgi_post_body_with_retry /www/cgi-bin/xray-vps "$payload" inspect_vps >/dev/null 2>&1 || true
}

set_router_rules_mode_checked() {
  local mode="$1"

  router_ssh_direct "$ROUTER_SSH" "/usr/bin/router-rules set-mode-cutover $(shell_quote "$mode") >/dev/null 2>&1" || return 1
  wait_for_proxy || return 1
  verify_router_proxy_path >/dev/null
}

[ -n "$VPS_HOST" ] || fail "Missing VPS host. Pass it as the second argument or set VPS_HOST."
[ -n "$XRAY_SERVER_NAME" ] || fail "Missing XRAY_SERVER_NAME and VPS profile default server name."

PROFILE_ID="${PROFILE_ID:-$(build_profile_id "$VPS_HOST")}"

tmpdir="$(mktemp -d)"
source_bundle="$tmpdir/router-source.tar"
control_path="$tmpdir/router-control"
remote_source_root="/tmp/vpn-xray-one-shot-src"
remote_source_tar="/tmp/vpn-xray-one-shot-src.tar"
control_opened=0
bootstrap_key_path="$tmpdir/vps-bootstrap-key"
bootstrap_private_key=''
bootstrap_mode=''
router_askpass_script="$tmpdir/router-askpass.sh"

cleanup() {
  if [[ "$control_opened" == "1" ]]; then
    router_ssh_raw -O exit "$ROUTER_SSH" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT INT TERM

ensure_installer_ssh_state "$ROOT_DIR"
INSTALLER_KNOWN_HOSTS="$(installer_known_hosts_file "$ROOT_DIR")"
ROUTER_SSH_COMMON_OPTS=(
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=4
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS"
  -o ControlPath="$control_path"
)
ROUTER_SSH_DIRECT_OPTS=(
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS"
)

router_key_auth_works() {
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS" \
    "$ROUTER_SSH" 'echo ok' >/dev/null 2>&1
}

if [[ -n "$ROUTER_PASSWORD" ]]; then
  if router_key_auth_works; then
    info "Router key-based SSH already works. ROUTER_PASSWORD will not be forced."
    ROUTER_PASSWORD=''
  else
    cat > "$router_askpass_script" <<EOF
#!/bin/sh
printf '%s\n' $(shell_quote "$ROUTER_PASSWORD")
EOF
    chmod 700 "$router_askpass_script"
    ROUTER_SSH_COMMON_OPTS+=(
      -o PreferredAuthentications=password,keyboard-interactive
      -o PubkeyAuthentication=no
      -o NumberOfPasswordPrompts=1
    )
    ROUTER_SSH_DIRECT_OPTS+=(
      -o PreferredAuthentications=password,keyboard-interactive
      -o PubkeyAuthentication=no
      -o NumberOfPasswordPrompts=1
    )
  fi
fi

open_router_ssh_master() {
  if [[ -n "$ROUTER_PASSWORD" ]]; then
    SSH_ASKPASS="$router_askpass_script" \
      SSH_ASKPASS_REQUIRE=force \
      DISPLAY=1 \
      ssh "${ROUTER_SSH_COMMON_OPTS[@]}" -M -N -f "$ROUTER_SSH" < /dev/null
  else
    ssh "${ROUTER_SSH_COMMON_OPTS[@]}" -M -N -f "$ROUTER_SSH"
  fi
}

router_ssh_raw() {
  ssh "${ROUTER_SSH_COMMON_OPTS[@]}" "$@"
}

router_ssh_direct() {
  if [[ -n "$ROUTER_PASSWORD" ]]; then
    SSH_ASKPASS="$router_askpass_script" \
      SSH_ASKPASS_REQUIRE=force \
      DISPLAY=1 \
      ssh "${ROUTER_SSH_DIRECT_OPTS[@]}" "$@"
  else
    ssh "${ROUTER_SSH_DIRECT_OPTS[@]}" "$@"
  fi
}

wait_for_router_direct_ssh() {
  local tries=30

  while (( tries > 0 )); do
    if router_ssh_direct "$ROUTER_SSH" 'echo ok' >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 2
  done

  return 1
}

router_ssh() {
  router_ssh_raw "$ROUTER_SSH" "$@"
}

router_ssh_stdin() {
  local remote_cmd="$1"
  local stdin_path="$2"
  router_ssh "$remote_cmd" < "$stdin_path"
}

router_cgi_post() {
  local script_path="$1"
  local payload="$2"
  local payload_len

  payload_len="$(printf '%s' "$payload" | wc -c | tr -d '[:space:]')"
  # Run CGI POSTs outside the master socket. Multiplexed stdin/stdio handling
  # is unreliable here and can collapse a valid JSON response into an empty body.
  printf '%s' "$payload" | router_ssh_direct "$ROUTER_SSH" "REQUEST_METHOD=POST CONTENT_LENGTH=$payload_len $script_path"
}

router_cgi_post_body_with_retry() {
  local script_path="$1"
  local payload="$2"
  local description="$3"
  local tries=10
  local body=''

  while (( tries > 0 )); do
    body="$(router_cgi_post "$script_path" "$payload" 2>/dev/null | extract_http_body || true)"
    if [[ -n "$body" ]]; then
      printf '%s' "$body"
      return 0
    fi
    wait_for_router_direct_ssh >/dev/null 2>&1 || true
    tries=$((tries - 1))
    sleep 2
  done

  fail "Router returned an empty response for $description after waiting for direct SSH recovery."
}

router_rules_sync_summary() {
  local git_sync_enabled last_sync_status last_sync_message rules_relpath repo_head source_count
  local attempts=30

  while (( attempts > 0 )); do
    git_sync_enabled="$(router_ssh_direct "$ROUTER_SSH" "uci -q get router_rules.global.git_sync_enabled 2>/dev/null || true" | tr -d '\r\n')"
    last_sync_status="$(router_ssh_direct "$ROUTER_SSH" "sed -n 's/^last_sync_status=//p' /tmp/router-rules.status | sed -n '1p'" | tr -d '\r\n')"
    last_sync_message="$(router_ssh_direct "$ROUTER_SSH" "sed -n 's/^last_sync_message=//p' /tmp/router-rules.status | sed -n '1p'" | tr -d '\r\n')"

    if [[ "$last_sync_status" == 'ok' ]]; then
      rules_relpath="$(router_ssh_direct "$ROUTER_SSH" "uci -q get router_rules.global.rules_relpath 2>/dev/null || true" | tr -d '\r\n')"
      [ -n "$rules_relpath" ] || rules_relpath='lists/shared-targets.txt'
      repo_head="$(router_ssh_direct "$ROUTER_SSH" "git -C /etc/router-rules/repo rev-parse --short HEAD 2>/dev/null || true" | tr -d '\r\n')"
      source_count="$(router_ssh_direct "$ROUTER_SSH" "awk '/^[[:space:]]*$/ { next } /^[[:space:]]*#/ { next } { count++ } END { print count + 0 }' $(shell_quote "/etc/router-rules/repo/$rules_relpath") 2>/dev/null || echo 0" | tr -d '\r\n')"
      printf 'git_sync_enabled=%s\n' "$git_sync_enabled"
      printf 'last_sync_status=%s\n' "$last_sync_status"
      printf 'last_sync_message=%s\n' "$last_sync_message"
      printf 'repo_head=%s\n' "$repo_head"
      printf 'rules_relpath=%s\n' "$rules_relpath"
      printf 'source_count=%s\n' "$source_count"
      return 0
    fi

    attempts=$((attempts - 1))
    sleep 2
  done

  printf 'git_sync_enabled=%s\n' "$git_sync_enabled"
  printf 'last_sync_status=%s\n' "$last_sync_status"
  printf 'last_sync_message=%s\n' "$last_sync_message"
  printf 'repo_head=\n'
  printf 'rules_relpath=lists/shared-targets.txt\n'
  printf 'source_count=0\n'
  return 1
}

vps_ssh() {
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="$VPS_SSH_CONNECT_TIMEOUT" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS" \
    -p "$VPS_SSH_PORT" \
    "$VPS_SSH_USER@$VPS_SSH_HOST" "$@"
}

vps_ssh_with_password() {
  local cmd
  local askpass_script
  cmd="$1"

  [ -n "$VPS_PASSWORD" ] || return 1

  if command -v sshpass >/dev/null 2>&1; then
    SSHPASS="$VPS_PASSWORD" sshpass -e ssh \
      -o BatchMode=no \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      -o ConnectTimeout="$VPS_SSH_CONNECT_TIMEOUT" \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS" \
      -p "$VPS_SSH_PORT" \
      "$VPS_SSH_USER@$VPS_SSH_HOST" "$cmd"
    return $?
  fi

  askpass_script="$(mktemp "$tmpdir/vps-askpass.XXXXXX")"
  cat > "$askpass_script" <<EOF
#!/bin/sh
printf '%s\n' $(shell_quote "$VPS_PASSWORD")
EOF
  chmod 700 "$askpass_script"
  DISPLAY=1 SSH_ASKPASS="$askpass_script" SSH_ASKPASS_REQUIRE=force \
    ssh \
      -o BatchMode=no \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      -o ConnectTimeout="$VPS_SSH_CONNECT_TIMEOUT" \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS" \
      -p "$VPS_SSH_PORT" \
      "$VPS_SSH_USER@$VPS_SSH_HOST" "$cmd"
  local rc=$?
  rm -f "$askpass_script"
  return "$rc"
}

generate_router_bootstrap_keypair() {
  local remote_key='/tmp/.vpn-xray-bootstrap-rsa'
  local remote_pub='/tmp/.vpn-xray-bootstrap-rsa.pub'
  local pubkey

  if ! router_ssh "command -v dropbearkey >/dev/null 2>&1"; then
    return 1
  fi

  if ! router_ssh "rm -f '$remote_key' '$remote_pub' && \
    umask 077 && \
    dropbearkey -t rsa -s 2048 -f '$remote_key' >/dev/null 2>&1 && \
    dropbearkey -y -f '$remote_key' 2>/dev/null | \
      grep -o 'ssh-rsa .*' | \
      head -n1 > '$remote_pub' && \
    [ -s '$remote_key' ] && [ -s '$remote_pub' ]"; then
    router_ssh "rm -f '$remote_key' '$remote_pub'" >/dev/null 2>&1 || true
    return 1
  fi

  bootstrap_private_key="$(router_ssh "cat '$remote_key'")"
  pubkey="$(router_ssh "cat '$remote_pub'")"
  bootstrap_private_key="$(printf '%s' "$bootstrap_private_key" | tr -d '\r')"
  pubkey="$(printf '%s' "$pubkey" | tr -d '\r')"
  printf '%s' "$pubkey" | grep -q '^ssh-rsa ' || {
    router_ssh "rm -f '$remote_key' '$remote_pub'" >/dev/null 2>&1 || true
    return 1
  }

  router_ssh "rm -f '$remote_key' '$remote_pub'" >/dev/null 2>&1 || true
  printf '%s\n' "$pubkey"
}

local_vps_key_works() {
  vps_ssh 'echo ok' >/dev/null 2>&1
}

install_bootstrap_key_on_vps() {
  local pubkey

  rm -f "$bootstrap_key_path" "${bootstrap_key_path}.pub"
  ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -f "$bootstrap_key_path" >/dev/null
  pubkey="$(cat "${bootstrap_key_path}.pub")"
  bootstrap_private_key="$(cat "$bootstrap_key_path")"

  [ -n "$pubkey" ] || return 1
  printf '%s\n' "$pubkey" > "${bootstrap_key_path}.pub"
  chmod 644 "${bootstrap_key_path}.pub"

  if ! vps_ssh "sh -c 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; PUB=\$(cat); grep -qxF \"\$PUB\" ~/.ssh/authorized_keys || printf \"%s\n\" \"\$PUB\" >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'" < "${bootstrap_key_path}.pub" >/dev/null 2>&1; then
    if ! vps_ssh_with_password "sh -c 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; PUB=\$(cat); grep -qxF \"\$PUB\" ~/.ssh/authorized_keys || printf \"%s\n\" \"\$PUB\" >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'" < "${bootstrap_key_path}.pub" >/dev/null 2>&1; then
      return 1
    fi
  fi
  bootstrap_private_key="$(cat "$bootstrap_key_path")"
}

install_pubkey_on_vps() {
  local pubkey="$1"
  local tmp_pub="$tmpdir/router-managed-vps.pub"

  [ -n "$pubkey" ] || return 1
  printf '%s\n' "$pubkey" > "$tmp_pub"
  chmod 644 "$tmp_pub"

  if ! vps_ssh "sh -c 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; PUB=\$(cat); grep -qxF \"\$PUB\" ~/.ssh/authorized_keys || printf \"%s\n\" \"\$PUB\" >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'" < "$tmp_pub" >/dev/null 2>&1; then
    if ! vps_ssh_with_password "sh -c 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; PUB=\$(cat); grep -qxF \"\$PUB\" ~/.ssh/authorized_keys || printf \"%s\n\" \"\$PUB\" >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'" < "$tmp_pub" >/dev/null 2>&1; then
      rm -f "$tmp_pub"
      return 1
    fi
  fi

  rm -f "$tmp_pub"
}

router_bootstrap_key_works() {
  local remote_key='/tmp/.vpn-xray-bootstrap-rsa'
  local rc=1

  router_ssh_stdin "cat > '$remote_key'" "$bootstrap_key_path" || return 1
  router_ssh "chmod 600 '$remote_key'" >/dev/null 2>&1 || {
    router_ssh "rm -f '$remote_key'" >/dev/null 2>&1 || true
    return 1
  }

  if router_ssh "ssh -i '$remote_key' -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p '$VPS_SSH_PORT' '$VPS_SSH_USER@$VPS_SSH_HOST' 'echo ok' >/dev/null 2>&1"; then
    rc=0
  fi

  router_ssh "rm -f '$remote_key'" >/dev/null 2>&1 || true
  return "$rc"
}

info "Opening router SSH session on $ROUTER_SSH ..."
open_router_ssh_master
control_opened=1

info "Packing local vpn-xray source bundle ..."
tar -C "$ROOT_DIR" -cf "$source_bundle" common routers vps

case "$VPS_AUTH_MODE" in
  auto)
    if local_vps_key_works; then
      info "Workstation already has key-based SSH access to $VPS_SSH_USER@$VPS_SSH_HOST. Seeding a temporary bootstrap key for the router ..."
      install_bootstrap_key_on_vps
      if router_bootstrap_key_works; then
        bootstrap_mode='private_key'
      elif [ -n "$VPS_PASSWORD" ]; then
        info "Router Dropbear cannot use generated temporary key. Falling back to password auth mode."
        bootstrap_mode='password'
      else
        fail "Router cannot use generated temporary key and no VPS_PASSWORD is set."
      fi
    else
      if [ -n "$VPS_PASSWORD" ]; then
        info "Installing a temporary bootstrap key on the VPS using VPS_PASSWORD ..."
        if install_bootstrap_key_on_vps; then
          if router_bootstrap_key_works; then
            bootstrap_mode='private_key'
          else
            info "Router cannot use generated temporary key. Falling back to password auth mode."
            bootstrap_mode='password'
          fi
        else
          info "Could not install bootstrap key with VPS_PASSWORD. Falling back to legacy password auth mode."
          bootstrap_mode='password'
        fi
      else
        fail "Missing VPS_PASSWORD, and the workstation does not have key-based SSH access to the VPS."
      fi
    fi
    ;;
  private_key|key)
    info "Seeding a temporary bootstrap key for the router ..."
    install_bootstrap_key_on_vps
    if router_bootstrap_key_works; then
      bootstrap_mode='private_key'
    else
      info "Could not validate temporary key on router SSH client. Falling back to password auth mode."
      bootstrap_mode='password'
    fi
    ;;
  password)
    [ -n "$VPS_PASSWORD" ] || fail "Missing VPS_PASSWORD for VPS_AUTH_MODE=password."
    info "Using explicit VPS password bootstrap mode."
    bootstrap_mode='password'
    ;;
  *)
    fail "Unsupported VPS_AUTH_MODE: $VPS_AUTH_MODE"
    ;;
esac

PLATFORM_RESUME_FLAG=''
if router_ssh "[ -f /tmp/vpn-xray-install-progress ]" >/dev/null 2>&1; then
  PLATFORM_RESUME_FLAG=' --resume'
fi

info "Uploading local source bundle to the router ..."
router_ssh "rm -rf $remote_source_root && mkdir -p $remote_source_root"
router_ssh_stdin "cat > $remote_source_tar" "$source_bundle"
router_ssh "tar -xf $remote_source_tar -C $remote_source_root && rm -f $remote_source_tar"

info "Installing vpn-xray platform on the router from the local repository ..."
router_ssh "\
RULES_GIT_SYNC_ENABLED=$(shell_quote "${RULES_GIT_SYNC_ENABLED:-}") \
RULES_REPO_FETCH_URL=$(shell_quote "${RULES_REPO_FETCH_URL:-}") \
RULES_REPO_PUSH_URL=$(shell_quote "${RULES_REPO_PUSH_URL:-}") \
RULES_REPO_BRANCH=$(shell_quote "${RULES_REPO_BRANCH:-main}") \
RULES_GIT_AUTH_MODE=$(shell_quote "${RULES_GIT_AUTH_MODE:-auto}") \
RULES_GIT_HTTP_USERNAME=$(shell_quote "${RULES_GIT_HTTP_USERNAME:-}") \
RULES_GIT_HTTP_PASSWORD=$(shell_quote "${RULES_GIT_HTTP_PASSWORD:-}") \
RULES_GIT_SSH_PRIVATE_KEY_B64=$(shell_quote "${RULES_GIT_SSH_PRIVATE_KEY_B64:-}") \
RULES_DEVICE_ID=$(shell_quote "${RULES_DEVICE_ID:-gl-router}") \
RULES_ENABLE_PUSH=$(shell_quote "${RULES_ENABLE_PUSH:-0}") \
RULES_SYNC_INTERVAL=$(shell_quote "${RULES_SYNC_INTERVAL:-30}") \
RULES_GIT_USER_NAME=$(shell_quote "${RULES_GIT_USER_NAME:-router-rules}") \
RULES_GIT_USER_EMAIL=$(shell_quote "${RULES_GIT_USER_EMAIL:-router-rules@example.invalid}") \
RULES_DNS_RESOLVER=$(shell_quote "${RULES_DNS_RESOLVER:-9.9.9.9 208.67.222.222}") \
XRAY_RULES_MODE=$(shell_quote "$BOOTSTRAP_SAFE_XRAY_RULES_MODE") \
DEFER_XRAY_ACTIVATION='1' \
sh $(shell_quote "$remote_source_root/routers/$ROUTER_PROFILE/install-platform.sh") --source-dir $(shell_quote "$remote_source_root")${PLATFORM_RESUME_FLAG}"
router_ssh "test -x /www/cgi-bin/xray-vps" >/dev/null
wait_for_router_direct_ssh || fail "Router direct SSH did not recover after install-platform.sh."

info "Saving router VPS profile material before apply ..."
save_payload="$(build_vps_profile_payload save_profile)"
save_response="$(router_cgi_post_body_with_retry /www/cgi-bin/xray-vps "$save_payload" save_profile)"
saved_profile_material="$(printf '%s' "$save_response" | extract_saved_profile_material)"
IFS='|' read -r PROFILE_ID saved_uuid saved_public_key saved_short_id saved_managed_pubkey <<<"$saved_profile_material"

vps_private_key="$(router_ssh "uci -q get xray_vps.$PROFILE_ID.private_key 2>/dev/null || true" | tr -d '\r\n')"
[ -n "$vps_private_key" ] || fail "Router profile did not expose a VPS private key after save_profile."

info "Provisioning VPS and applying the saved profile through the router control plane ..."
apply_profile_payload="$(build_vps_profile_payload apply_profile \
  "uuid=$saved_uuid" \
  "public_key=$saved_public_key" \
  "private_key=$vps_private_key" \
  "short_id=$saved_short_id")"
apply_response="$(router_cgi_post_body_with_retry /www/cgi-bin/xray-vps "$apply_profile_payload" apply_profile)"
printf '%s' "$apply_response" | assert_router_action_ok >/dev/null
wait_for_router_direct_ssh || fail "Router direct SSH did not recover after apply_profile."
sleep "$POST_APPLY_ROUTER_VPS_SSH_COOLDOWN"
validate_vps_state_via_router "$PROFILE_ID" "$saved_uuid" "$saved_public_key" "$saved_short_id"
refresh_profile_cache_best_effort
active_profile_id="$PROFILE_ID"

router_ssh "rm -rf $remote_source_root" >/dev/null 2>&1 || true

switch_state="$(router_switch_state)"
if [[ "$switch_state" != "on" ]]; then
  fail "Router install completed and profile '$active_profile_id' is active, but the physical switch is '$switch_state'. Turn it ON and rerun the script to finish proxy verification."
fi

info "Waiting for the router proxy listener on port $PROXY_PORT ..."
wait_for_proxy || fail "Timed out waiting for the router proxy listener on port $PROXY_PORT."

egress_ip="$(verify_router_proxy_path)"

if [[ "$REQUESTED_XRAY_RULES_MODE" != "$BOOTSTRAP_SAFE_XRAY_RULES_MODE" ]]; then
  info "Switching router rules mode from bootstrap-safe '$BOOTSTRAP_SAFE_XRAY_RULES_MODE' to requested '$REQUESTED_XRAY_RULES_MODE' ..."
  if ! set_router_rules_mode_checked "$REQUESTED_XRAY_RULES_MODE"; then
    info "Requested mode '$REQUESTED_XRAY_RULES_MODE' did not verify cleanly. Rolling back to '$BOOTSTRAP_SAFE_XRAY_RULES_MODE' ..."
    set_router_rules_mode_checked "$BOOTSTRAP_SAFE_XRAY_RULES_MODE" >/dev/null 2>&1 || true
    fail "Router proxy path did not verify after switching to requested mode '$REQUESTED_XRAY_RULES_MODE'. The bootstrap-safe mode '$BOOTSTRAP_SAFE_XRAY_RULES_MODE' was restored."
  fi
  egress_ip="$(verify_router_proxy_path)"
fi

rules_sync_summary=''
if [[ "${RULES_GIT_SYNC_ENABLED:-0}" == '1' ]]; then
  rules_sync_status=''
  info "Verifying shared rules Git sync ..."
  rules_sync_raw="$(router_rules_sync_summary || true)"
  rules_sync_status="$(printf '%s' "$rules_sync_raw" | sed -n 's/^last_sync_status=//p' | sed -n '1p' | tr -d '\r[:space:]')"
  if [[ -z "$rules_sync_status" ]]; then
    info "WARNING: Could not confirm shared rules Git sync status over SSH. The router continues syncing in the background."
  else
    if ! rules_sync_summary="$(printf '%s' "$rules_sync_raw" | assert_rules_sync_summary_ok)"; then
      info "WARNING: Shared rules Git sync probe did not return a confirmed OK status over SSH. Check xray.html for the live router status."
      rules_sync_summary=''
    fi
  fi
fi

info
info "One-shot router + VPS install completed."
info "Router:       $ROUTER_HOST"
info "Active profile: $active_profile_id"
info "Proxy:        http://$ROUTER_HOST:$PROXY_PORT"
info "Web UI:       https://$ROUTER_HOST/xray.html"
info "Egress IP:    $egress_ip"
if [[ -n "$rules_sync_summary" ]]; then
  IFS='|' read -r rules_repo_head rules_relpath rules_source_count <<<"$rules_sync_summary"
  info "Shared rules: $rules_relpath ($rules_source_count entries) @ $rules_repo_head"
fi
