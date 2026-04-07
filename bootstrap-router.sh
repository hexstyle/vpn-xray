#!/bin/sh

set -eu

REPO_SLUG="${VPN_XRAY_REPO_SLUG:-hexstyle/vpn-xray}"
REPO_REF="${VPN_XRAY_REF:-main}"
ROUTER_PROFILE="${VPN_XRAY_ROUTER_PROFILE:-}"
WORK_ROOT="${VPN_XRAY_BOOTSTRAP_DIR:-/tmp/vpn-xray-bootstrap.$$}"
ARCHIVE_PATH="$WORK_ROOT/repo.tar.gz"
EXTRACT_ROOT="$WORK_ROOT/src"

info() {
	printf '%s\n' "$*"
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

cleanup() {
	rm -rf "$WORK_ROOT"
}

trap cleanup EXIT INT TERM

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "Missing required command on the router: $1"
}

download_to_file() {
	local url="$1"
	local target="$2"

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 15 --max-time 300 -o "$target" "$url"
		return 0
	fi

	if command -v wget >/dev/null 2>&1; then
		wget -O "$target" "$url"
		return 0
	fi

	fail "Neither curl nor wget is available on the router."
}

profile_model_from_env() {
	local env_path="$1"
	awk -F':=' '/ROUTER_BOOTSTRAP_MODEL/ {print $2; exit}' "$env_path" | sed 's/}"$//' | sed -n '1p'
}

detect_router_profile() {
	local repo_root="$1"
	local model env_path expected profile

	model="$(cat /proc/gl-hw-info/model 2>/dev/null | sed -n '1p' || true)"
	[ -n "$model" ] || fail "Could not detect the router model from /proc/gl-hw-info/model."

	for env_path in "$repo_root"/routers/*/profile.env; do
		[ -f "$env_path" ] || continue
		expected="$(profile_model_from_env "$env_path")"
		[ -n "$expected" ] || continue
		if [ "$expected" = "$model" ]; then
			profile="$(basename "$(dirname "$env_path")")"
			printf '%s\n' "$profile"
			return 0
		fi
	done

	fail "No supported router profile matches detected model '$model'. Set VPN_XRAY_ROUTER_PROFILE explicitly if you are testing a custom profile."
}

need_cmd sh
need_cmd tar
need_cmd find
need_cmd sed
need_cmd awk
mkdir -p "$EXTRACT_ROOT"

info "Downloading vpn-xray bootstrap bundle from ${REPO_SLUG}@${REPO_REF}..."
download_to_file "https://codeload.github.com/${REPO_SLUG}/tar.gz/${REPO_REF}" "$ARCHIVE_PATH" || {
	fail "Could not download the repository bundle. Check the router uplink, DNS, time/NTP and HTTPS reachability to GitHub."
}

tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_ROOT" || fail "Could not unpack the repository bundle on the router."

REPO_ROOT="$(find "$EXTRACT_ROOT" -mindepth 1 -maxdepth 1 -type d | sed -n '1p')"
[ -n "$REPO_ROOT" ] || fail "Bootstrap bundle unpacked, but the repository root was not found."

if [ -z "$ROUTER_PROFILE" ]; then
	ROUTER_PROFILE="$(detect_router_profile "$REPO_ROOT")"
fi

INSTALLER="$REPO_ROOT/routers/$ROUTER_PROFILE/install-platform.sh"
[ -f "$INSTALLER" ] || fail "Router profile '$ROUTER_PROFILE' does not provide install-platform.sh."
chmod 755 "$INSTALLER"

info "Detected router profile: $ROUTER_PROFILE"
info "Installing the vpn-xray platform on the router..."
VPN_XRAY_REPO_SLUG="$REPO_SLUG" VPN_XRAY_REF="$REPO_REF" sh "$INSTALLER" --source-dir "$REPO_ROOT"

info
info "Router platform install completed."
info "Open: https://192.168.8.1/xray.html"
info "Next step: add VPS SSH details in the web UI and click 'Sync Router + VPS'."
