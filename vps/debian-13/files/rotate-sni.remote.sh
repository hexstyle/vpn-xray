#!/bin/sh
set -eu

# Explicit VPS-side SNI rotation. The VPS remains authoritative: this script
# updates its live config, managed meta and certificate together, then callers
# re-inspect the VPS and derive router state from it.

CONFIG_PATH="${XRAY_CONFIG_PATH:-/usr/local/etc/xray/config.json}"
META_PATH="${VPS_REMOTE_META_PATH:-/usr/local/etc/xray/codex-router-meta.env}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_SERVICE="${XRAY_SERVICE:-xray}"
NEW_SNI="${NEW_SNI:-}"

case "$NEW_SNI" in
	''|*[!A-Za-z0-9.-]*|.*|*..*|*.)
		echo "invalid NEW_SNI: $NEW_SNI" >&2
		exit 2
		;;
esac
case "$CONFIG_PATH:$META_PATH" in
	/*:/*) : ;;
	*) echo 'config and meta paths must be absolute' >&2; exit 2 ;;
esac
[ -x "$XRAY_BIN" ] || { echo "xray binary missing: $XRAY_BIN" >&2; exit 1; }
[ -s "$CONFIG_PATH" ] || { echo "xray config missing: $CONFIG_PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required' >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo 'openssl is required' >&2; exit 1; }

lock='/run/vpn-xray-rotate-sni.lock'
if ! mkdir "$lock" 2>/dev/null; then
	echo 'another SNI rotation is already running' >&2
	exit 1
fi
work="$(mktemp -d /tmp/vpn-xray-sni.XXXXXX)"
cleanup() { rm -rf "$work" "$lock"; }
trap cleanup EXIT HUP INT TERM

new_config="$work/config.json"
facts="$(NEW_SNI="$NEW_SNI" CONFIG_PATH="$CONFIG_PATH" OUTPUT_PATH="$new_config" python3 - <<'PY'
import json, os

with open(os.environ["CONFIG_PATH"], encoding="utf-8") as src:
    config = json.load(src)
inbound = config["inbounds"][0]
stream = inbound.setdefault("streamSettings", {})
if stream.get("network") != "ws" or stream.get("security") != "tls":
    raise SystemExit("live VPS transport is not WS+TLS; refusing SNI-only rotation")
stream.setdefault("wsSettings", {})["host"] = os.environ["NEW_SNI"]
cert = stream.get("tlsSettings", {}).get("certificates", [{}])[0]
cert_path = cert.get("certificateFile", "")
key_path = cert.get("keyFile", "")
if not cert_path.startswith("/") or not key_path.startswith("/"):
    raise SystemExit("certificate paths are missing or not absolute")
with open(os.environ["OUTPUT_PATH"], "w", encoding="utf-8") as dst:
    json.dump(config, dst, indent=2)
    dst.write("\n")
log = config.get("log", {})
print(f"{inbound['port']}|{cert_path}|{key_path}|{log.get('error', '')}|{log.get('access', '')}")
PY
)"
IFS='|' read -r port cert_path key_path error_log access_log <<EOF
$facts
EOF
case "$port" in ''|*[!0-9]*) echo "invalid listener port: $port" >&2; exit 1 ;; esac
"$XRAY_BIN" run -test -config "$new_config" >/dev/null

new_cert="$work/server.crt"
new_key="$work/server.key"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-keyout "$new_key" -out "$new_cert" \
	-subj "/CN=$NEW_SNI" -addext "subjectAltName=DNS:$NEW_SNI" >/dev/null 2>&1

new_meta="$work/meta.env"
NEW_SNI="$NEW_SNI" META_PATH="$META_PATH" OUTPUT_PATH="$new_meta" python3 - <<'PY'
import os

path = os.environ["META_PATH"]
lines = []
if os.path.exists(path):
    with open(path, encoding="utf-8") as src:
        lines = src.read().splitlines()
key = "XRAY_SERVER_NAME="
updated = False
for idx, line in enumerate(lines):
    if line.startswith(key):
        lines[idx] = key + os.environ["NEW_SNI"]
        updated = True
if not updated:
    lines.append(key + os.environ["NEW_SNI"])
with open(os.environ["OUTPUT_PATH"], "w", encoding="utf-8") as dst:
    dst.write("\n".join(lines) + "\n")
PY

backup="$(dirname "$CONFIG_PATH")/backups/sni-$(date +%Y%m%d%H%M%S)"
mkdir -p "$backup"
cp -p "$CONFIG_PATH" "$backup/config.json"
[ -f "$META_PATH" ] && cp -p "$META_PATH" "$backup/meta.env" || true
[ -f "$cert_path" ] && cp -p "$cert_path" "$backup/server.crt" || true
[ -f "$key_path" ] && cp -p "$key_path" "$backup/server.key" || true

rollback() {
	cp -p "$backup/config.json" "$CONFIG_PATH"
	[ -f "$backup/meta.env" ] && cp -p "$backup/meta.env" "$META_PATH" || true
	[ -f "$backup/server.crt" ] && cp -p "$backup/server.crt" "$cert_path" || true
	[ -f "$backup/server.key" ] && cp -p "$backup/server.key" "$key_path" || true
	normalize_runtime_permissions
	systemctl restart "$XRAY_SERVICE" >/dev/null 2>&1 || true
}

service_user="$(systemctl show "$XRAY_SERVICE" -p User --value 2>/dev/null || true)"
service_group="$(systemctl show "$XRAY_SERVICE" -p Group --value 2>/dev/null || true)"
[ -n "$service_user" ] || service_user='root'
[ -n "$service_group" ] || service_group="$service_user"
normalize_runtime_permissions() {
	local log_path
	chown "$service_user:$service_group" "$CONFIG_PATH" "$cert_path" "$key_path" 2>/dev/null || true
	for log_path in "$error_log" "$access_log"; do
		[ -n "$log_path" ] || continue
		install -d -m 750 "$(dirname "$log_path")"
		touch "$log_path"
		chown "$service_user:$service_group" "$log_path"
		chmod 640 "$log_path"
	done
}

install -m 640 "$new_config" "$CONFIG_PATH"
install -m 640 "$new_cert" "$cert_path"
install -m 600 "$new_key" "$key_path"
install -m 600 "$new_meta" "$META_PATH"
normalize_runtime_permissions

if ! systemctl restart "$XRAY_SERVICE"; then
	rollback
	echo 'xray restart failed; rolled back' >&2
	exit 1
fi
i=0
while [ "$i" -lt 15 ]; do
	ss -ltn 2>/dev/null | grep -q ":${port} " && break
	i=$((i + 1)); sleep 1
done
if ! ss -ltn 2>/dev/null | grep -q ":${port} "; then
	rollback
	echo 'listener did not return; rolled back' >&2
	exit 1
fi
if ! timeout 8 openssl s_client -connect "127.0.0.1:$port" -servername "$NEW_SNI" -showcerts </dev/null 2>/dev/null \
	| openssl x509 -noout -checkhost "$NEW_SNI" >/dev/null 2>&1; then
	rollback
	echo 'local TLS verification failed; rolled back' >&2
	exit 1
fi

echo "SNI rotation complete: $NEW_SNI"
echo "backup: $backup"
