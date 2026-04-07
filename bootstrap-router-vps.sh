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
  python3 - <<'PY'
import base64
import sys

sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode("ascii"))
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

extract_http_body() {
  python3 - <<'PY'
import sys

data = sys.stdin.read()
if "\r\n\r\n" in data:
    sys.stdout.write(data.split("\r\n\r\n", 1)[1])
elif "\n\n" in data:
    sys.stdout.write(data.split("\n\n", 1)[1])
else:
    sys.stdout.write(data)
PY
}

assert_apply_response_ok() {
  python3 - <<'PY'
import json
import sys

raw = sys.stdin.read()
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

print(status.get("active_profile_id", ""))
PY
}

assert_rules_sync_summary_ok() {
  python3 - <<'PY'
import sys

fields = {}
for line in sys.stdin.read().splitlines():
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

if [[ -n "$ROUTER_PASSWORD" ]]; then
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
  cmd="$1"

  command -v sshpass >/dev/null 2>&1 || return 1
  [ -n "$VPS_PASSWORD" ] || return 1

  SSHPASS="$VPS_PASSWORD" sshpass -e ssh \
    -o BatchMode=no \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o ConnectTimeout="$VPS_SSH_CONNECT_TIMEOUT" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS" \
    -p "$VPS_SSH_PORT" \
    "$VPS_SSH_USER@$VPS_SSH_HOST" "$cmd"
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
  pubkey="$(generate_router_bootstrap_keypair || true)"

  if [ -z "$pubkey" ]; then
    # Fallback to local PEM bootstrap key generation if dropbearkey is not
    # available on the router.
    ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -f "$bootstrap_key_path" >/dev/null
    pubkey="$(cat "${bootstrap_key_path}.pub")"
    bootstrap_private_key="$(cat "$bootstrap_key_path")"
  else
    printf '%s\n' "$bootstrap_private_key" > "$bootstrap_key_path"
    chmod 600 "$bootstrap_key_path"
  fi

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
    info "Installing a temporary bootstrap key on the VPS using VPS_PASSWORD ..."
    if ! install_bootstrap_key_on_vps; then
      info "Could not install bootstrap key with VPS_PASSWORD. Falling back to legacy password auth mode."
      bootstrap_mode='password'
    elif router_bootstrap_key_works; then
      bootstrap_mode='private_key'
    else
      info "Could not validate temporary key on router SSH client. Falling back to legacy password auth mode."
      bootstrap_mode='password'
    fi
    ;;
  *)
    fail "Unsupported VPS_AUTH_MODE: $VPS_AUTH_MODE"
    ;;
esac

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
RULES_DNS_RESOLVER=$(shell_quote "${RULES_DNS_RESOLVER:-1.1.1.1 9.9.9.9}") \
XRAY_RULES_MODE=$(shell_quote "${XRAY_RULES_MODE:-full}") \
sh $(shell_quote "$remote_source_root/routers/$ROUTER_PROFILE/install-platform.sh") --source-dir $(shell_quote "$remote_source_root")"
router_ssh "test -x /www/cgi-bin/xray-vps" >/dev/null

if [[ "$bootstrap_mode" == 'password' ]]; then
  apply_payload="$(
    urlencode_pairs \
      "action=apply_profile" \
      "profile_id=$PROFILE_ID" \
      "label=$PROFILE_LABEL" \
      "vps_profile=$VPS_PROFILE" \
      "auth_mode=$bootstrap_mode" \
      "ssh_host=$VPS_HOST" \
      "ssh_port=$VPS_SSH_PORT" \
      "ssh_user=$VPS_SSH_USER" \
      "ssh_password=$VPS_PASSWORD" \
      "server_address=$XRAY_SERVER" \
      "server_port=$XRAY_PORT" \
      "server_name=$XRAY_SERVER_NAME" \
      "flow=$XRAY_FLOW"
  )"
else
  apply_payload="$(
    urlencode_pairs \
      "action=apply_profile" \
      "profile_id=$PROFILE_ID" \
      "label=$PROFILE_LABEL" \
      "vps_profile=$VPS_PROFILE" \
      "auth_mode=$bootstrap_mode" \
      "ssh_host=$VPS_HOST" \
      "ssh_port=$VPS_SSH_PORT" \
      "ssh_user=$VPS_SSH_USER" \
      "bootstrap_private_key=$bootstrap_private_key" \
      "server_address=$XRAY_SERVER" \
      "server_port=$XRAY_PORT" \
      "server_name=$XRAY_SERVER_NAME" \
      "flow=$XRAY_FLOW"
  )"
fi

info "Applying VPS profile on the router and provisioning $VPS_HOST ..."
apply_response="$(router_cgi_post /www/cgi-bin/xray-vps "$apply_payload" | extract_http_body || true)"
if [[ -n "$apply_response" ]]; then
  active_profile_id="$(printf '%s' "$apply_response" | assert_apply_response_ok)"
else
  info "WARNING: Router returned an empty apply_profile response. Falling back to runtime verification."
  active_profile_id="$(router_ssh "uci -q get xray_vps.main.active_profile 2>/dev/null || true" | tr -d '\r\n')"
  [[ -n "$active_profile_id" ]] || active_profile_id="$PROFILE_ID"
fi

router_ssh "rm -rf $remote_source_root" >/dev/null 2>&1 || true

switch_state="$(router_switch_state)"
if [[ "$switch_state" != "on" ]]; then
  fail "Router install completed and profile '$active_profile_id' is active, but the physical switch is '$switch_state'. Turn it ON and rerun the script to finish proxy verification."
fi

info "Waiting for the router proxy listener on port $PROXY_PORT ..."
wait_for_proxy || fail "Timed out waiting for the router proxy listener on port $PROXY_PORT."

info "Checking HTTPS through the router proxy ..."
curl -fsSI -m 25 -x "http://$ROUTER_HOST:$PROXY_PORT" https://www.google.com >/dev/null

egress_ip="$(curl -fsS -m 25 -x "http://$ROUTER_HOST:$PROXY_PORT" https://ifconfig.me/ip | tr -d '\r\n')"
[ -n "$egress_ip" ] || fail "The router proxy answered, but no egress IP was returned."

if printf '%s' "$XRAY_SERVER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && [[ "$egress_ip" != "$XRAY_SERVER" ]]; then
  fail "Proxy egress IP mismatch: expected $XRAY_SERVER, got $egress_ip."
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
