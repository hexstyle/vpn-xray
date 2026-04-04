#!/usr/bin/env bash

set -euo pipefail

REPO_SLUG="${VPN_XRAY_REPO_SLUG:-hexstyle/vpn-xray}"
REPO_REF="${VPN_XRAY_REF:-main}"
ROUTER_SSH="${1:-${ROUTER_SSH:-root@192.168.8.1}}"
SSH_CACHE_DIR="${VPN_XRAY_SSH_CACHE_DIR:-$HOME/.cache/vpn-xray}"
KNOWN_HOSTS="$SSH_CACHE_DIR/known_hosts"
SSH_BIN="${SSH_BIN:-ssh}"
ROUTER_HOST="${ROUTER_SSH##*@}"

info() {
	printf '%s\n' "$*"
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "Missing required local command: $1"
}

mkdir -p "$SSH_CACHE_DIR"
touch "$KNOWN_HOSTS"

need_cmd "$SSH_BIN"

REMOTE_URL="https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}/bootstrap-router.sh"

remote_bootstrap() {
	"$SSH_BIN" \
		-o StrictHostKeyChecking=accept-new \
		-o UserKnownHostsFile="$KNOWN_HOSTS" \
		"$ROUTER_SSH" \
		"sh -s" <<REMOTE
set -eu
URL='$REMOTE_URL'
if command -v wget >/dev/null 2>&1; then
  sh -c "\$(wget -qO- \"\$URL\")"
  exit 0
fi
if command -v curl >/dev/null 2>&1; then
  sh -c "\$(curl -fsSL \"\$URL\")"
  exit 0
fi
echo "ERROR: neither wget nor curl is available on the router." >&2
exit 1
REMOTE
}

ERR_LOG="$(mktemp)"
cleanup() {
	rm -f "$ERR_LOG"
}
trap cleanup EXIT INT TERM

info "Bootstrapping vpn-xray on $ROUTER_SSH ..."
if remote_bootstrap 2> >(tee "$ERR_LOG" >&2); then
	exit 0
fi

if grep -Eq 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed' "$ERR_LOG"; then
	info
	info "Detected a stale cached SSH host key for $ROUTER_HOST. Cleaning the installer cache and retrying once..."
	rm -f "$KNOWN_HOSTS"
	touch "$KNOWN_HOSTS"
	if remote_bootstrap; then
		exit 0
	fi
fi

fail "Router bootstrap did not finish. If the router was factory-reset, verify SSH with 'ssh root@${ROUTER_HOST}' first and confirm the GL.iNet first-run wizard is complete."
