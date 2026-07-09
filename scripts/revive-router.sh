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
		# Require the correct transport: a raw/reality backup is exactly the
		# broken state we are recovering from, so skip it even if it has a
		# hostname serverName.
		grep -q '"security" *: *"tls"' "$bak" || continue
		grep -q '"network" *: *"ws"' "$bak" || continue
		sn="$(sed -n 's/.*"serverName" *: *"\([^"]*\)".*/\1/p' "$bak" | head -1)"
		case "$sn" in
			''|*[0-9].[0-9]*.[0-9]*.[0-9]*) continue ;;  # empty or looks like an IP
		esac
		# Validate before trusting it.
		if /usr/local/bin/codex-xray-core run -test -config "$bak" >/dev/null 2>&1; then
			cp "$bak" "$CONFIG"
			log "restored good WS+TLS backup: $bak (serverName=$sn)"
			return 0
		fi
	done
	return 1
}

# 3) Otherwise rebuild the outbound in place. This is the important part:
#    the breakage is often not just an empty serverName but a wrong
#    TRANSPORT (the router left on raw/reality while the VPS serves
#    ws/tls — 2026-07-10). Patching serverName on a reality outbound
#    changes nothing. So we force the outbound to WS+TLS, preserving the
#    endpoint identity (address/port/uuid/flow) already present in the
#    config's vnext, and set serverName/host to the cert SNI, ws path to
#    /cdn (the stack default) or whatever the config already had.
patch_in_place() {
	command -v python3 >/dev/null 2>&1 || {
		log "python3 missing — cannot rebuild config safely; leaving as-is"
		return 1
	}
	WS_PATH_DEFAULT='/cdn' python3 - "$CONFIG" "$SNI" <<'PY'
import json, os, sys
path, sni = sys.argv[1], sys.argv[2]
ws_default = os.environ.get("WS_PATH_DEFAULT", "/cdn")
with open(path) as f:
    cfg = json.load(f)
for ob in cfg.get("outbounds", []):
    if ob.get("protocol") != "vless":
        continue
    ss = ob.setdefault("streamSettings", {})
    # keep an existing ws path if one is set, else default
    ws_path = ((ss.get("wsSettings") or {}).get("path")) or ws_default
    ss.clear()
    ss["network"] = "ws"
    ss["security"] = "tls"
    ss["tlsSettings"] = {
        "serverName": sni,
        "alpn": ["h2", "http/1.1"],
        "fingerprint": "chrome",
        "certificates": [
            {"usage": "verify", "certificateFile": "/etc/xray/server.crt"}
        ],
    }
    ss["wsSettings"] = {"path": ws_path, "host": sni}
    ob["mux"] = {"enabled": True, "concurrency": 8, "xudpConcurrency": 16}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("rebuilt outbound as WS+TLS (serverName=%s)" % sni)
PY
}

if restore_from_backup; then
	:
else
	log "no usable backup; rebuilding outbound as WS+TLS (serverName=$SNI)"
	patch_in_place || { log "in-place rebuild failed"; exit 1; }
fi

# 3b) Sync the pinned verify certificate to whatever the VPS actually
#     presents now. VLESS here is encryption:none — the TLS layer IS the
#     encryption — so we must verify, but the router pins a self-signed
#     cert at /etc/xray/server.crt. If the VPS cert was regenerated (a
#     reprovision, an early repair) the pinned copy no longer matches and
#     every dial fails with "certificate signed by unknown authority".
#     Fetch the leaf cert the VPS serves on the dialed address:port and
#     re-pin it. This is trust-on-first-use against our own VPS.
sync_pinned_cert() {
	local addr port fetched
	addr="$(sed -n 's/.*"address" *: *"\([^"]*\)".*/\1/p' "$CONFIG" | head -1)"
	port="$(sed -n 's/.*"port" *: *\([0-9]*\).*/\1/p' "$CONFIG" | grep -vE '^(1083|1084|1086|12345)$' | head -1)"
	[ -n "$addr" ] || { log "cannot determine VPS address from config; skipping cert sync"; return 1; }
	[ -n "$port" ] || port=443
	command -v openssl >/dev/null 2>&1 || { log "no openssl; cannot sync cert"; return 1; }

	fetched="$(echo | openssl s_client -connect "${addr}:${port}" -servername "$SNI" 2>/dev/null \
		| openssl x509 2>/dev/null)"
	if [ -z "$fetched" ]; then
		log "could not fetch the VPS cert from ${addr}:${port} (is the VPS up?)"
		return 1
	fi
	if [ -f "$CERT" ] && printf '%s\n' "$fetched" | cmp -s - "$CERT"; then
		log "pinned cert already matches the VPS ($CERT)"
		return 0
	fi
	printf '%s\n' "$fetched" > "$CERT"
	chmod 600 "$CERT" 2>/dev/null || true
	log "re-pinned $CERT to the cert the VPS currently serves"
	return 0
}
sync_pinned_cert || log "cert sync skipped/failed — if you still see 'unknown authority', the VPS cert is unreachable"

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
