#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$ROOT/install.sh"
ADOPT_SH="$ROOT/common/adopt-vps-meta.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

[ -x "$ADOPT_SH" ] \
	|| fail "common/adopt-vps-meta.sh must exist and be executable"

grep -q 'adopt-vps-meta.sh" "\$ENV_FILE"' "$INSTALL_SH" \
	|| fail "install.sh must run adopt-vps-meta before validation"

# Adoption must run after init-env (env exists) and before validate-env
# (validation sees the adopted values).
awk '/init-env.sh/ { init = NR } /adopt-vps-meta.sh/ { adopt = NR }
     /validate-env.sh/ { validate = NR }
     END { exit !(init && adopt && validate && init < adopt && adopt < validate) }' \
	"$INSTALL_SH" \
	|| fail "install.sh must order init-env -> adopt-vps-meta -> validate-env"

grep -q 'VPS_REMOTE_META_PATH' "$ADOPT_SH" \
	|| fail "adopt-vps-meta must read the VPS managed meta path"

for key in XRAY_UUID XRAY_PRIVATE_KEY XRAY_PUBLIC_KEY XRAY_SHORT_ID XRAY_SERVER_NAME XRAY_PORT; do
	grep -q "adopt $key " "$ADOPT_SH" \
		|| fail "adopt-vps-meta must adopt $key from the VPS managed meta"
done

grep -q 'keeping local Xray values' "$ADOPT_SH" \
	|| fail "adopt-vps-meta must fall back to local values when the VPS is unreachable"

grep -q 'no managed meta yet' "$ADOPT_SH" \
	|| fail "adopt-vps-meta must keep local values when the VPS carries no managed meta"

# Behavioral check: given a fake ssh that serves a managed meta, the
# adopted values must land in the env file.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/install.env" <<'EOF'
ROUTER_PROFILE=gl-mt3000-glinet
ROUTER_SSH=root@10.99.0.1
VPS_PROFILE=debian-13
VPS_SSH=root@10.99.0.2
VPS_HOST=10.99.0.2
XRAY_UUID=00000000-0000-0000-0000-000000000000
XRAY_SERVER_NAME=www.cloudflare.com
XRAY_PORT=443
XRAY_SHORT_ID=1111111111111111
XRAY_PUBLIC_KEY=localpub
XRAY_PRIVATE_KEY=localpriv
EOF

mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/ssh" <<'EOF'
#!/bin/sh
cat <<'META'
PROFILE_ID=debian-13
XRAY_HOST=10.99.0.2
XRAY_PORT=24443
XRAY_UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
XRAY_SERVER_NAME=www.example-front.com
XRAY_SHORT_ID=feedfacefeedface
XRAY_PRIVATE_KEY=vpspriv
XRAY_PUBLIC_KEY=vpspub
XRAY_FLOW=
META
EOF
chmod +x "$tmpdir/bin/ssh"

PATH="$tmpdir/bin:$PATH" "$ADOPT_SH" "$tmpdir/install.env" >/dev/null \
	|| fail "adopt-vps-meta must succeed against a VPS with managed meta"

for expect in \
	'XRAY_UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' \
	'XRAY_PRIVATE_KEY=vpspriv' \
	'XRAY_PUBLIC_KEY=vpspub' \
	'XRAY_SHORT_ID=feedfacefeedface' \
	'XRAY_SERVER_NAME=www.example-front.com' \
	'XRAY_PORT=24443'; do
	grep -q "^$expect\$" "$tmpdir/install.env" \
		|| fail "adopted env must contain $expect"
done

# Fresh VPS (no meta): local values stay untouched.
cat > "$tmpdir/bin/ssh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmpdir/bin/ssh"

cp "$tmpdir/install.env" "$tmpdir/install.env.before"
PATH="$tmpdir/bin:$PATH" "$ADOPT_SH" "$tmpdir/install.env" >/dev/null \
	|| fail "adopt-vps-meta must succeed against a fresh VPS without meta"
cmp -s "$tmpdir/install.env" "$tmpdir/install.env.before" \
	|| fail "a fresh VPS without meta must not change local env values"

printf 'ok\n'
