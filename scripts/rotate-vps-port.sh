#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_SCRIPT="$ROOT_DIR/vps/debian-13/files/rotate-port.remote.sh"

usage() { echo "Usage: VPS_PASSWORD=... $0 user@vps new-xray-port [ssh-port]" >&2; }
[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
VPS_SSH="$1"
NEW_PORT="$2"
VPS_PORT="${3:-22}"
[[ "$NEW_PORT" =~ ^[0-9]+$ && "$NEW_PORT" -ge 1 && "$NEW_PORT" -le 65535 ]] \
  || { echo 'Xray port must be between 1 and 65535.' >&2; exit 2; }
[[ "$VPS_PORT" =~ ^[0-9]+$ ]] || { echo 'SSH port must be numeric.' >&2; exit 2; }

KNOWN_HOSTS="$ROOT_DIR/tmp/ssh/known_hosts"
mkdir -p "$(dirname "$KNOWN_HOSTS")"
ssh_opts=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=8 -p "$VPS_PORT")
if [[ -n "${VPS_PASSWORD:-}" ]]; then
  command -v sshpass >/dev/null 2>&1 || { echo 'sshpass is required for VPS_PASSWORD auth.' >&2; exit 1; }
  SSHPASS="$VPS_PASSWORD" sshpass -e ssh \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
    "${ssh_opts[@]}" "$VPS_SSH" "NEW_PORT='$NEW_PORT' sh -s" < "$REMOTE_SCRIPT"
else
  ssh -o BatchMode=yes "${ssh_opts[@]}" "$VPS_SSH" \
    "NEW_PORT='$NEW_PORT' sh -s" < "$REMOTE_SCRIPT"
fi
