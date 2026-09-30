#!/bin/sh
set -eu

# Move the authoritative Xray listener to a new port. Config and managed
# metadata are committed together; the router must re-inspect them afterwards.
CONFIG_PATH="${XRAY_CONFIG_PATH:-/usr/local/etc/xray/config.json}"
META_PATH="${VPS_REMOTE_META_PATH:-/usr/local/etc/xray/codex-router-meta.env}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_SERVICE="${XRAY_SERVICE:-xray}"
NEW_PORT="${NEW_PORT:-}"

case "$NEW_PORT" in ''|*[!0-9]*) echo 'NEW_PORT must be numeric' >&2; exit 2;; esac
[ "$NEW_PORT" -ge 1 ] && [ "$NEW_PORT" -le 65535 ] \
	|| { echo 'NEW_PORT must be between 1 and 65535' >&2; exit 2; }
case "$CONFIG_PATH:$META_PATH" in /*:/*) :;; *) echo 'config and meta paths must be absolute' >&2; exit 2;; esac
[ -x "$XRAY_BIN" ] || { echo "xray binary missing: $XRAY_BIN" >&2; exit 1; }
[ -s "$CONFIG_PATH" ] || { echo "xray config missing: $CONFIG_PATH" >&2; exit 1; }
[ -s "$META_PATH" ] || { echo "managed VPS metadata missing: $META_PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required' >&2; exit 1; }

lock='/run/vpn-xray-rotate-port.lock'
mkdir "$lock" 2>/dev/null || { echo 'another port rotation is already running' >&2; exit 1; }
work="$(mktemp -d /tmp/vpn-xray-port.XXXXXX)"
cleanup() { rm -rf "$work" "$lock"; }
trap cleanup EXIT HUP INT TERM

new_config="$work/config.json"
facts="$(NEW_PORT="$NEW_PORT" CONFIG_PATH="$CONFIG_PATH" OUTPUT_PATH="$new_config" python3 - <<'PY'
import json, os

with open(os.environ["CONFIG_PATH"], encoding="utf-8") as src:
    config = json.load(src)
inbound = config["inbounds"][0]
stream = inbound.get("streamSettings", {})
if stream.get("network") != "ws" or stream.get("security") != "tls":
    raise SystemExit("live VPS transport is not WS+TLS; refusing port-only rotation")
inbound["port"] = int(os.environ["NEW_PORT"])
tls = stream.get("tlsSettings", {})
cert = tls.get("certificates", [{}])[0]
cert_path = cert.get("certificateFile", "")
server_name = tls.get("serverName", "") or stream.get("wsSettings", {}).get("host", "")
if not cert_path.startswith("/") or not server_name:
    raise SystemExit("certificate path or server name is missing")
with open(os.environ["OUTPUT_PATH"], "w", encoding="utf-8") as dst:
    json.dump(config, dst, indent=2)
    dst.write("\n")
print(f"{cert_path}|{server_name}")
PY
)"
IFS='|' read -r cert_path server_name <<EOF
$facts
EOF
"$XRAY_BIN" run -test -config "$new_config" >/dev/null

new_meta="$work/meta.env"
NEW_PORT="$NEW_PORT" META_PATH="$META_PATH" OUTPUT_PATH="$new_meta" python3 - <<'PY'
import os

path = os.environ["META_PATH"]
lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
key = "XRAY_PORT="
for idx, line in enumerate(lines):
    if line.startswith(key):
        lines[idx] = key + os.environ["NEW_PORT"]
        break
else:
    lines.append(key + os.environ["NEW_PORT"])
with open(os.environ["OUTPUT_PATH"], "w", encoding="utf-8") as dst:
    dst.write("\n".join(lines) + "\n")
PY

backup="$(dirname "$CONFIG_PATH")/backups/port-$(date +%Y%m%d%H%M%S)"
mkdir -p "$backup"
cp -p "$CONFIG_PATH" "$backup/config.json"
[ -f "$META_PATH" ] && cp -p "$META_PATH" "$backup/meta.env" || true

service_user="$(systemctl show "$XRAY_SERVICE" -p User --value 2>/dev/null || true)"
service_group="$(systemctl show "$XRAY_SERVICE" -p Group --value 2>/dev/null || true)"
[ -n "$service_user" ] || service_user='root'
[ -n "$service_group" ] || service_group="$service_user"
normalize_permissions() {
	chown "$service_user:$service_group" "$CONFIG_PATH" 2>/dev/null || true
	chmod 640 "$CONFIG_PATH"
}
rollback() {
	cp -p "$backup/config.json" "$CONFIG_PATH"
	[ -f "$backup/meta.env" ] && cp -p "$backup/meta.env" "$META_PATH" || true
	normalize_permissions
	systemctl restart "$XRAY_SERVICE" >/dev/null 2>&1 || true
}

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
	ufw allow "${NEW_PORT}/tcp" >/dev/null
fi
install -m 640 "$new_config" "$CONFIG_PATH"
install -m 600 "$new_meta" "$META_PATH"
normalize_permissions
if ! systemctl restart "$XRAY_SERVICE"; then
	rollback
	echo 'xray restart failed; rolled back' >&2
	exit 1
fi

i=0
while [ "$i" -lt 15 ]; do
	ss -ltn 2>/dev/null | grep -q ":${NEW_PORT} " && break
	i=$((i + 1)); sleep 1
done
if ! ss -ltn 2>/dev/null | grep -q ":${NEW_PORT} "; then
	rollback
	echo 'listener did not return; rolled back' >&2
	exit 1
fi
if ! timeout 8 openssl s_client -connect "127.0.0.1:$NEW_PORT" -servername "$server_name" </dev/null 2>/dev/null \
	| openssl x509 -noout -checkhost "$server_name" >/dev/null 2>&1; then
	rollback
	echo 'local TLS verification failed; rolled back' >&2
	exit 1
fi

echo "Port rotation complete: $NEW_PORT"
echo "backup: $backup"
