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
VPS_X64_BUNDLE="$ROOT/vps/debian-13/packages/Xray-linux-64.zip"

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
printf '%s' "$save_action" | grep -q 'refresh_remote_cache' \
	&& fail "saving access must not inspect or modify the VPS"

create_fn="$(sed -n '/^create_profile_action()/,/^}/p' "$ACTIONS")"
printf '%s' "$create_fn" | grep -q 'ensure_profile_material' \
	&& fail "creating a profile must not generate Xray material before VPS inspection"
printf '%s' "$create_fn" | grep -q 'profile_set "$profile_id" auth_mode '\''password'\''' \
	|| fail "a new VPS must start in one-shot password bootstrap mode"
printf '%s' "$create_fn" | grep -q 'managed_key_path "${KEY_DIR}/${profile_id}_ed25519"' \
	|| fail "each new VPS profile must receive its own router-managed SSH key"
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
	grep -q '<button id="saveProfileBtn" type="button" class="primary">Save VPS Access</button>' "$html" \
		|| fail "the SSH form must statically expose Save VPS Access"
	grep -q '<button class="warn-btn" id="diagnoseRepairBtn" type="button">Check &amp; Configure VPS</button>' "$html" \
		|| fail "the SSH form must statically expose Check & Configure VPS"
done
grep -q 'callApi(vpsApi, "save_profile", formPayload()' "$APP7" \
	|| fail "Save VPS Access must call the save_profile backend"
grep -q 'diagnose_repair_status' "$ROOT/routers/common/files/xray-app-6.js" \
	|| fail "Check & Configure VPS must poll the detached repair job"
grep -q "XRAY_VPS_JOB='diagnose_repair'" "$ROOT/routers/common/files/xray-vps-setup.sh" \
	|| fail "VPS repair must be scheduled outside the CGI request"
grep -q 'stage/xray-bundled.zip' "$REPAIR" \
	|| fail "the detached repair bundle must carry the repository-bundled VPS Xray archive"
for platform in \
	"$ROOT/routers/asus-tuf-ax4200-openwrt/install-platform.sh" \
	"$ROOT/routers/gl-mt3000-glinet/install-platform.sh"; do
	grep -q 'cp -R "$VPS_DIR" /usr/share/vpn-xray/vps' "$platform" \
		|| fail "$(basename "$(dirname "$platform")"): base install must deploy the full VPS installer payload to OpenWrt"
	grep -q 'files/diag/nodes.manifest.*share/vpn-xray/diag/nodes.manifest' "$platform" \
		|| fail "$(basename "$(dirname "$platform")"): base install must deploy the diagnostic tree manifest"
done
[ -s "$VPS_X64_BUNDLE" ] \
	|| fail "the VPS installer payload must contain the offline amd64 Xray archive"
grep -q 'VPS_XRAY_ARCHIVE_X64_SHA256:=' "$PROFILE" \
	|| fail "the offline amd64 VPS archive must have a pinned checksum"

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
