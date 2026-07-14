#!/usr/bin/env bash
# bootstrap-lib-a.sh — bootstrap-router-vps.sh step/helper functions extracted per the
# AGENTS.md 500-line rule. Sourced by bootstrap-router-vps.sh right after
# common/lib/env.sh; defines functions only, runs no top-level code.

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
  -o StrictHostKeyChecking=accept-new \
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
