#!/bin/sh
# Router revival: fix the router Xray client config after a bad apply left
# it dialing the VPS with an empty TLS serverName (symptom in the xray
# error log: "x509: cannot validate certificate for <IP> because it
# doesn't contain any IP SANs"). Run this ON the router over LAN SSH:
#
#   ssh root@192.168.8.1 'sh -s' < scripts/revive-router.sh
# or copy it over and run:  sh /tmp/revive-router.sh
#
# It is safe to run repeatedly. It does not touch the VPS.

set -u

CONFIG=/etc/xray/codex-xray.json
CERT=/etc/xray/server.crt
# The known-good SNI for this stack. If your cert CN differs, pass it:
#   SNI=your.host sh revive-router.sh
SNI="${SNI:-www.cloudflare.com}"

log() { printf '[revive] %s\n' "$*"; }

[ -f "$CONFIG" ] || { log "no $CONFIG — nothing to revive"; exit 1; }

# 1) Derive the correct SNI from the certificate itself when possible, so
#    we match whatever cert was actually deployed rather than guessing.
cert_sni=''
if [ -f "$CERT" ] && command -v openssl >/dev/null 2>&1; then
	cert_sni="$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null \
		| sed -n 's/.*CN *= *\([^,]*\).*/\1/p' | head -1 | tr -d ' ')"
fi
[ -n "$cert_sni" ] && SNI="$cert_sni"
log "using serverName/SNI = $SNI"

# 2) Prefer restoring the most recent backup whose serverName is a
#    non-empty hostname (not an IP, not empty). apply writes
#    codex-xray.json.bak.<timestamp> before each change.
restore_from_backup() {
	local bak sn
	for bak in $(ls -1t "${CONFIG}".bak.* 2>/dev/null); do
		[ -f "$bak" ] || continue
		sn="$(sed -n 's/.*"serverName" *: *"\([^"]*\)".*/\1/p' "$bak" | head -1)"
		case "$sn" in
			''|*[0-9].[0-9]*.[0-9]*.[0-9]*) continue ;;  # empty or looks like an IP
		esac
		# Validate before trusting it.
		if /usr/local/bin/codex-xray-core run -test -config "$bak" >/dev/null 2>&1; then
			cp "$bak" "$CONFIG"
			log "restored good backup: $bak (serverName=$sn)"
			return 0
		fi
	done
	return 1
}

# 3) Otherwise patch the live config in place: set every serverName and the
#    wsSettings host to the correct SNI. Handles both ws/tls and
#    raw/reality shapes; only rewrites the string fields, nothing else.
patch_in_place() {
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$CONFIG" "$SNI" <<'PY'
import json, sys
path, sni = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
changed = 0
for ob in cfg.get("outbounds", []):
    ss = ob.get("streamSettings") or {}
    for key in ("tlsSettings", "realitySettings"):
        s = ss.get(key)
        if isinstance(s, dict) and s.get("serverName", "") != sni:
            s["serverName"] = sni; changed += 1
    ws = ss.get("wsSettings")
    if isinstance(ws, dict):
        host = (ws.get("headers") or {}).get("Host")
        if ws.get("host", "") not in ("", sni):
            ws["host"] = sni; changed += 1
        elif "host" in ws and ws["host"] != sni:
            ws["host"] = sni; changed += 1
        else:
            ws["host"] = sni
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("patched fields:", changed)
PY
		return 0
	fi
	# Fallback without python: blunt sed on serverName + host.
	sed -i "s/\"serverName\" *: *\"[^\"]*\"/\"serverName\": \"$SNI\"/g; s/\"host\" *: *\"[^\"]*\"/\"host\": \"$SNI\"/g" "$CONFIG"
}

if restore_from_backup; then
	:
else
	log "no usable backup; patching serverName/host in place to $SNI"
	patch_in_place
fi

# 4) Validate the resulting config before restarting.
if ! /usr/local/bin/codex-xray-core run -test -config "$CONFIG" >/dev/null 2>&1; then
	log "ERROR: config still invalid after repair:"
	/usr/local/bin/codex-xray-core run -test -config "$CONFIG" 2>&1 | tail -5
	exit 1
fi
log "config validates OK"

# 5) Restart the runtime and the transparent path.
/etc/init.d/codex-xray restart >/dev/null 2>&1 || true
sleep 2
/etc/init.d/codex-transproxy restart >/dev/null 2>&1 || true
sleep 2

# 6) Verify the proxy actually reaches the internet through the VPS.
log "verifying proxy egress..."
ip="$(curl -sS -m 12 -x http://127.0.0.1:1083 https://api.ipify.org 2>/dev/null || true)"
if [ -n "$ip" ]; then
	log "OK — egress through proxy: $ip"
	log "router revived. Clients behind it should have internet again."
else
	log "proxy did not return an egress IP yet."
	log "Check the VPS is up and reachable, then re-run. Last xray errors:"
	tail -5 /var/log/xray/codex-xray-error.log 2>/dev/null
	exit 1
fi
