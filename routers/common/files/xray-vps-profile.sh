#!/bin/sh
# xray-vps-profile.sh — VPS profile store, identity material, keygen
# Deployed to /usr/share/vpn-xray/xray-vps-profile.sh
# Sourced by /www/cgi-bin/xray-vps after lib-common.sh (shares its scope,
# constants, and helper functions). Defines functions only; runs no code.

sanitize_id() {
	local raw="$1"
	local out

	out="$(printf '%s' "$raw" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_-')"
	[ -n "$out" ] || out='profile'
	printf '%s' "$out"
}

vps_profile_env_path() {
	printf '%s/%s/profile.env\n' "$VPS_PROFILE_ROOT" "$1"
}

vps_profile_exists() {
	[ -f "$(vps_profile_env_path "$1")" ]
}

vps_profile_value() {
	local profile="$1"
	local key="$2"
	local env_file value

	env_file="$(vps_profile_env_path "$profile")"
	[ -f "$env_file" ] || return 0
	value="$(sh -c '. "$1"; eval "printf %s \"\${'"$key"':-}\""' sh "$env_file" 2>/dev/null || true)"
	printf '%s' "$value"
}

vps_profile_ids() {
	local dir item

	[ -d "$VPS_PROFILE_ROOT" ] || return 0
	for item in "$VPS_PROFILE_ROOT"/*; do
		[ -d "$item" ] || continue
		[ -f "$item/profile.env" ] || continue
		dir="${item##*/}"
		printf '%s\n' "$dir"
	done | sort
}

default_vps_profile() {
	local profile

	for profile in $(vps_profile_ids); do
		printf '%s' "$profile"
		return 0
	done

	printf ''
}

default_server_name_for_profile() {
	local profile="$1"
	local value

	profile="$(normalize_vps_profile "$profile")"
	value="$(vps_profile_value "$profile" VPS_DEFAULT_SERVER_NAME)"
	printf '%s' "$value"
}

normalize_vps_profile() {
	local profile="$1"
	[ -n "$profile" ] || profile="$(default_vps_profile)"
	if vps_profile_exists "$profile"; then
		printf '%s' "$profile"
	else
		printf '%s' "$(default_vps_profile)"
	fi
}

vps_profiles_json() {
	local first=1 profile label
	printf '['
	for profile in $(vps_profile_ids); do
		label="$(vps_profile_value "$profile" VPS_PROFILE_LABEL)"
		[ -n "$label" ] || label="$profile"
		[ "$first" = '1' ] || printf ','
		first=0
		printf '{'
		printf '"id":"%s",' "$(json_escape "$profile")"
		printf '"label":"%s"' "$(json_escape "$label")"
		printf '}'
	done
	printf ']'
}

profile_ids() {
	uci -q show "$PROFILE_PACKAGE" | sed -n "s/^${PROFILE_PACKAGE}\.\([^.=]*\)=profile$/\1/p"
}

profile_exists() {
	uci -q get "${PROFILE_PACKAGE}.$1" >/dev/null 2>&1
}

profile_get() {
	uci -q get "${PROFILE_PACKAGE}.$1.$2" 2>/dev/null || true
}

profile_set() {
	local profile_id="$1"
	local key="$2"
	local value="$3"
	uci -q set "${PROFILE_PACKAGE}.${profile_id}.${key}=${value}"
}

profile_del() {
	uci -q delete "${PROFILE_PACKAGE}.$1.$2" >/dev/null 2>&1 || true
}

active_profile_id() {
	uci -q get "${PROFILE_PACKAGE}.${PROFILE_STATE}.active_profile" 2>/dev/null || true
}

set_active_profile() {
	uci -q set "${PROFILE_PACKAGE}.${PROFILE_STATE}.active_profile=$1"
}

now_epoch() {
	date +%s
}

generate_uuid() {
	"$ROUTER_XRAY_BIN" uuid 2>/dev/null | sed -n '1p'
}

generate_short_id() {
	openssl rand -hex 8 2>/dev/null | sed -n '1p'
}

generate_key_pair() {
	"$ROUTER_XRAY_BIN" x25519 2>/dev/null
}

derive_public_from_private() {
	local private_key="$1"
	"$ROUTER_XRAY_BIN" x25519 -i "$private_key" 2>/dev/null | sed -n 's/^Password (PublicKey): //p' | sed -n '1p'
}

ensure_profile_material() {
	local profile_id="$1"
	local uuid public_key private_key short_id flow keypair

	uuid="$(profile_get "$profile_id" uuid)"
	public_key="$(profile_get "$profile_id" public_key)"
	private_key="$(profile_get "$profile_id" private_key)"
	short_id="$(profile_get "$profile_id" short_id)"
	flow="$(profile_get "$profile_id" flow)"

	if [ -z "$uuid" ]; then
		profile_set "$profile_id" uuid "$(generate_uuid)"
	fi

	if [ -n "$private_key" ] && [ -z "$public_key" ]; then
		public_key="$(derive_public_from_private "$private_key")"
		[ -n "$public_key" ] && profile_set "$profile_id" public_key "$public_key"
	fi

	if [ -z "$private_key" ] && [ -z "$public_key" ]; then
		keypair="$(generate_key_pair)"
		private_key="$(printf '%s\n' "$keypair" | sed -n 's/^PrivateKey: //p' | sed -n '1p')"
		public_key="$(printf '%s\n' "$keypair" | sed -n 's/^Password (PublicKey): //p' | sed -n '1p')"
		[ -n "$private_key" ] && profile_set "$profile_id" private_key "$private_key"
		[ -n "$public_key" ] && profile_set "$profile_id" public_key "$public_key"
	fi

	if [ -z "$short_id" ]; then
		profile_set "$profile_id" short_id "$(generate_short_id)"
	fi

	if [ -z "$flow" ]; then
		profile_set "$profile_id" flow ''
	fi
}

ensure_profile_keypair() {
	local profile_id="$1"
	local key_path pub

	key_path="$(profile_get "$profile_id" managed_key_path)"
	[ -n "$key_path" ] || key_path="${KEY_DIR}/${profile_id}_ed25519"
	mkdir -p "$KEY_DIR"
	if [ ! -f "$key_path" ] || [ ! -f "${key_path}.pub" ] || ! sed -n '1p' "${key_path}.pub" | grep -q '^ssh-rsa ' || ! ssh-keygen -y -f "$key_path" >/dev/null 2>&1; then
		rm -f "$key_path" "${key_path}.pub"
		ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -f "$key_path" >/dev/null 2>&1 || return 1
	fi
	chmod 600 "$key_path"
	chmod 644 "${key_path}.pub"
	pub="$(cat "${key_path}.pub" 2>/dev/null || true)"
	[ -n "$pub" ] || return 1
	profile_set "$profile_id" managed_key_path "$key_path"
	profile_set "$profile_id" managed_pubkey "$pub"
}

save_bootstrap_key() {
	local profile_id="$1"
	local key_text="$2"
	local path

	path="$(profile_get "$profile_id" bootstrap_key_path)"
	[ -n "$path" ] || path="${KEY_DIR}/${profile_id}_bootstrap"
	if [ -n "$key_text" ]; then
		printf '%s\n' "$key_text" > "$path"
		chmod 600 "$path"
		profile_set "$profile_id" bootstrap_key_path "$path"
	fi
}
