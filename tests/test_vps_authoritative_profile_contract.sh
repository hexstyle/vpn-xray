#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ACTIONS="$ROOT/routers/common/files/xray-vps-actions.sh"
INSPECT="$ROOT/routers/common/files/xray-vps-inspect.sh"
REPAIR="$ROOT/routers/common/files/xray-vps-repair.sh"
APP1="$ROOT/routers/common/files/xray-app-1.js"
APP7="$ROOT/routers/common/files/xray-app-7.js"
ASUS_HTML="$ROOT/routers/asus-tuf-ax4200-openwrt/files/xray.html"
GL_HTML="$ROOT/routers/gl-mt3000-glinet/files/xray.html"
PROFILE_LIB="$ROOT/routers/common/files/xray-vps-profile.sh"
PROFILE="$ROOT/vps/debian-13/profile.env"
ROTATE="$ROOT/vps/debian-13/files/rotate-sni.remote.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

form_payload="$(sed -n '/function formPayload()/,/^    }/p' "$APP1")"
for key in server_port server_name uuid public_key short_id flow; do
	printf '%s' "$form_payload" | grep -q "$key" \
		&& fail "formPayload must not submit VPS-derived field $key"
done

save_fn="$(sed -n '/^save_profile_from_request()/,/^}/p' "$ACTIONS")"
for key in server_port server_name uuid public_key private_key short_id flow; do
	printf '%s' "$save_fn" | grep -q "request_value $key" \
		&& fail "save_profile_from_request must ignore browser-supplied $key"
done
printf '%s' "$save_fn" | grep -q 'profile_set "$profile_id" server_address "$ssh_host"' \
	|| fail "the Xray address must derive from the saved SSH host"
save_action="$(sed -n '/^save_profile_action()/,/^}/p' "$ACTIONS")"
printf '%s' "$save_action" | grep -q 'refresh_remote_cache "$SAVE_PROFILE_ID"' \
	|| fail "saving reachable VPS access must immediately refresh the authoritative identity"
printf '%s' "$save_action" | grep -q '"remote_refreshed"' \
	|| fail "the save response must report whether the VPS identity was refreshed"

create_fn="$(sed -n '/^create_profile_action()/,/^}/p' "$ACTIONS")"
printf '%s' "$create_fn" | grep -q 'ensure_profile_material' \
	&& fail "creating a profile must not generate Xray material before VPS inspection"
printf '%s' "$create_fn" | grep -q 'profile_get "$source_profile" managed_key_path' \
	|| fail "a new profile must reuse the active router-managed SSH identity when available"
printf '%s' "$save_fn" | grep -q 'managed_key_path="$(profile_get "$profile_id" managed_key_path)"' \
	|| fail "saving a profile must preserve an inherited managed key path"

grep -q 'adopt_remote_into_profile "$profile_id"' "$INSPECT" \
	|| fail "every successful VPS inspection must adopt the remote identity"
prepare_fn="$(sed -n '/^prepare_profile_from_vps()/,/^}/p' "$ACTIONS")"
printf '%s' "$prepare_fn" | grep -q 'refresh_remote_cache' \
	|| fail "a write path must inspect the VPS first"
printf '%s' "$prepare_fn" | grep -q 'if \[ -z "$remote_uuid" \]' \
	|| fail "generation must be gated on an empty remote UUID"
printf '%s' "$prepare_fn" | grep -q 'ensure_profile_material' \
	|| fail "an empty VPS must still be provisionable"
grep -q 'prepare_profile_from_vps "$profile_id"' "$REPAIR" \
	|| fail "repair must prepare from the authoritative VPS before rendering"
grep -q "tr 'A-Z' 'a-z' | tr ' ' '_'" "$PROFILE_LIB" \
	|| fail "profile IDs must use the BusyBox-safe staged ASCII sanitizer"
if grep -q "tr '\[:upper:\] ' '\[:lower:\]_'" "$PROFILE_LIB"; then
	fail "combined POSIX-class sanitizer corrupts IDs on BusyBox tr"
fi

for html in "$ASUS_HTML" "$GL_HTML"; do
	grep -q '<button id="saveProfileBtn" type="button" class="primary">Save Changes</button>' "$html" \
		|| fail "the New VPS form must statically expose a Save Changes button"
done
grep -q 'callApi(vpsApi, "save_profile", formPayload()' "$APP7" \
	|| fail "Save Changes must call the save_profile backend"

grep -q 'VPS_DEFAULT_SERVER_NAME:=www.wp.pl' "$PROFILE" \
	|| fail "fresh VPS provisioning must default to the verified Polish SNI"
for cert in \
	"$ROOT/routers/gl-mt3000-glinet/files/server.crt" \
	"$ROOT/routers/asus-tuf-ax4200-openwrt/files/server.crt"; do
	cert_text="$(openssl x509 -in "$cert" -noout -subject -text 2>/dev/null)"
	printf '%s\n' "$cert_text" | grep -Eq 'CN[=/ ]+www\.wp\.pl' \
		|| fail "$cert must have the default Polish SNI as its common name"
	printf '%s\n' "$cert_text" | grep -q 'DNS:www\.wp\.pl' \
		|| fail "$cert must have the default Polish SNI as a SAN"
done
[ -f "$ROTATE" ] || fail "the explicit VPS-side SNI rotation script is missing"
grep -q '^rollback() {' "$ROTATE" \
	|| fail "SNI rotation must provide rollback"
grep -q 'XRAY_SERVER_NAME=' "$ROTATE" \
	|| fail "SNI rotation must update authoritative VPS metadata"
grep -q 'openssl x509 -noout -checkhost' "$ROTATE" \
	|| fail "SNI rotation must verify the live certificate hostname"

printf 'ok\n'
