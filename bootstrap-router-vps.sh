#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/common/lib/env.sh"

# Step/helper functions live in sibling libs (AGENTS.md 500-line rule).
source "$ROOT_DIR/common/lib/bootstrap-lib-a.sh"
source "$ROOT_DIR/common/lib/bootstrap-lib-b.sh"


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






load_rules_git_ssh_private_key
RULES_GIT_SSH_PRIVATE_KEY_B64=''
if [[ -n "${RULES_GIT_SSH_PRIVATE_KEY:-}" ]]; then
  RULES_GIT_SSH_PRIVATE_KEY_B64="$(printf '%s' "$RULES_GIT_SSH_PRIVATE_KEY" | base64_encode)"
fi

















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
