#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/common/lib/env.sh"

MODE='full'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repair-vps)
      MODE='repair-vps'
      shift
      ;;
    --preflight)
      PREFLIGHT_ONLY=1
      shift
      ;;
    -h|--help)
      cat <<HELP
Usage: install.sh [--repair-vps] [--preflight]

Without flags: full end-to-end install (router platform + VPS + verify).

  --repair-vps   Skip the router side and run the VPS repair pipeline only.
                 Useful after a VPS reprovision when the router is fine
                 but the VPS Xray runtime is broken. Prompts for the VPS
                 SSH password if the current key does not work.

  --preflight    Run preflight checks only. No changes are made on either
                 the router or the VPS.

Environment: ENV_FILE (defaults to install.env at the repository root)
             overrides which .env file is loaded.
HELP
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Run: install.sh --help" >&2
      exit 2
      ;;
  esac
done

require_local_commands bash ssh ssh-keygen tar python3

ENV_FILE="${ENV_FILE:-$(default_install_env_file "$ROOT_DIR")}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"
export ENV_FILE

"$ROOT_DIR/common/init-env.sh" "$ENV_FILE"
# VPS-first key adoption: when the VPS already carries provisioned keys
# in its managed meta, they win over whatever install.env holds; locally
# generated values are only pushed to a VPS that has none.
"$ROOT_DIR/common/adopt-vps-meta.sh" "$ENV_FILE"
"$ROOT_DIR/common/validate-env.sh" "$ENV_FILE"

load_env_file "$ENV_FILE" "$(default_install_env_example "$ROOT_DIR")"
ROUTER_PROFILE="${ROUTER_PROFILE:-gl-mt3000-glinet}"
VPS_PROFILE="${VPS_PROFILE:-debian-13}"
require_supported_profile router "$ROOT_DIR" "$ROUTER_PROFILE"
require_supported_profile vps "$ROOT_DIR" "$VPS_PROFILE"

# Interactive VPS password prompt used when key auth fails and the
# environment did not pre-load a password. In non-interactive contexts
# (no tty) we skip the prompt and let downstream scripts fail with their
# usual diagnostics — that keeps CI-style invocations behaving as before.
prompt_vps_password() {
  local prompt msg
  msg="$1"
  if [[ ! -t 0 || ! -t 1 ]]; then
    return 1
  fi
  echo
  echo "VPS SSH key authentication failed for ${VPS_SSH:-}."
  echo "Reason: $msg"
  read -rsp "Enter root password for ${VPS_SSH:-VPS} (or Enter to abort): " VPS_PASSWORD
  echo
  if [[ -z "$VPS_PASSWORD" ]]; then
    return 1
  fi
  export VPS_PASSWORD
  return 0
}

vps_ssh_probe() {
  local host="${VPS_HOST:-}"
  local target="${VPS_SSH:-root@$host}"
  [[ -n "$target" ]] || return 1
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$(installer_known_hosts_file "$ROOT_DIR")" \
    $(ssh_mux_opts) \
    "$target" 'true' >/dev/null 2>&1
}

# Repair-only mode: skip everything else and run just the VPS install/repair
# script. It re-uses the same VPS_PASSWORD interactive fallback so a stale
# managed key does not become a dead end.
if [[ "$MODE" == "repair-vps" ]]; then
  if ! vps_ssh_probe; then
    if [[ -z "${VPS_PASSWORD:-}" ]]; then
      prompt_vps_password 'key-based SSH did not succeed on the current login' \
        || { echo "Cannot proceed without SSH access to the VPS." >&2; exit 1; }
    fi
  fi

  echo "Running VPS repair pipeline..."
  "$ROOT_DIR/vps/$VPS_PROFILE/install-vps.sh"

  echo
  echo "VPS repair completed."
  exit 0
fi

echo "Running router preflight..."
"$ROOT_DIR/routers/$ROUTER_PROFILE/install-router.sh" --preflight

echo "Running VPS preflight..."
if ! "$ROOT_DIR/vps/$VPS_PROFILE/install-vps.sh" --preflight; then
  # Preflight failed. If it was an SSH problem and we have a tty, offer a
  # password fallback rather than exiting silently.
  if ! vps_ssh_probe; then
    if prompt_vps_password 'VPS preflight could not complete'; then
      echo "Retrying VPS preflight with password auth..."
      "$ROOT_DIR/vps/$VPS_PROFILE/install-vps.sh" --preflight
    else
      exit 1
    fi
  else
    # SSH works but preflight still failed — real config issue, not creds.
    exit 1
  fi
fi

if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
  echo
  echo "Preflight passed. No changes were made."
  exit 0
fi

"$ROOT_DIR/vps/$VPS_PROFILE/install-vps.sh"
"$ROOT_DIR/routers/$ROUTER_PROFILE/install-router.sh"

if [[ "$SKIP_VERIFY" != "1" ]]; then
  set +e
  "$ROOT_DIR/routers/$ROUTER_PROFILE/verify-router.sh"
  verify_rc=$?
  set -e
  if [[ "$verify_rc" -eq 20 ]]; then
    echo
    echo "Verification paused: the router hardware switch is OFF."
    echo "Turn the switch ON and rerun:"
    echo "  $ROOT_DIR/routers/$ROUTER_PROFILE/verify-router.sh"
  elif [[ "$verify_rc" -eq 21 ]]; then
    echo
    echo "Verification paused: the router platform is installed, but there is no active VPS profile on the router yet."
    echo "Open the router UI, sync a VPS profile, and rerun:"
    echo "  $ROOT_DIR/routers/$ROUTER_PROFILE/verify-router.sh"
  elif [[ "$verify_rc" -ne 0 ]]; then
    exit "$verify_rc"
  fi
fi

ROUTER_SSH="${ROUTER_SSH:-root@${ROUTER_HOST:-}}"
ROUTER_HOST="${ROUTER_HOST:-$(host_from_ssh_target "$ROUTER_SSH")}"

echo
echo "Stack install completed."
echo "Open the router UI at: https://$ROUTER_HOST/xray.html"
