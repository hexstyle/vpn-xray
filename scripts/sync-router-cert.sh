#!/bin/sh
# Re-pin the router's verify certificate to whatever the VPS currently
# serves, and restart xray only if it changed. Idempotent and safe to run
# repeatedly — intended to be run on demand or from cron to keep the router
# resilient to VPS cert regeneration (reprovision, renewal) without a full
# reinstall (DIAGNOSTIC-TREE G10/G11).
#
# Run on the router:   sh /usr/bin/sync-router-cert   (or via cron)
# Cron example (every 30 min), add to /etc/crontabs/root:
#   */30 * * * * /bin/sh /root/sync-router-cert.sh >/dev/null 2>&1
#
# It never regenerates or deletes anything on the VPS; it only reads the
# cert the VPS presents and pins it locally. VLESS here is encryption:none
# (TLS is the actual encryption), so verification must stay on — this keeps
# the pinned cert correct rather than disabling verification.

set -u

CONFIG=/etc/xray/codex-xray.json
CERT=/etc/xray/server.crt

log() { printf '[cert-sync] %s\n' "$*"; }

[ -f "$CONFIG" ] || { log "no $CONFIG; nothing to do"; exit 0; }
command -v openssl >/dev/null 2>&1 || { log "openssl not available; cannot sync"; exit 0; }

# Endpoint + SNI from the live config.
addr="$(sed -n 's/.*"address" *: *"\([^"]*\)".*/\1/p' "$CONFIG" | head -1)"
port="$(sed -n 's/.*"port" *: *\([0-9]*\).*/\1/p' "$CONFIG" | grep -vE '^(1083|1084|1086|12345)$' | head -1)"
sni="$(sed -n 's/.*"serverName" *: *"\([^"]*\)".*/\1/p' "$CONFIG" | head -1)"
[ -n "$addr" ] || { log "no VPS address in config; skip"; exit 0; }
[ -n "$port" ] || port=443
[ -n "$sni" ] || sni=www.cloudflare.com

fetched="$(echo | openssl s_client -connect "${addr}:${port}" -servername "$sni" 2>/dev/null | openssl x509 2>/dev/null)"
[ -n "$fetched" ] || { log "could not fetch cert from ${addr}:${port} (VPS down?)"; exit 0; }

if [ -f "$CERT" ] && printf '%s\n' "$fetched" | cmp -s - "$CERT"; then
	# Already matches — nothing to do, no restart.
	exit 0
fi

printf '%s\n' "$fetched" > "$CERT"
chmod 600 "$CERT" 2>/dev/null || true
log "pinned cert updated to the cert ${addr}:${port} now serves; restarting xray"
/etc/init.d/codex-xray restart >/dev/null 2>&1 || true
sleep 2
ip="$(curl -sS -m 12 -x http://127.0.0.1:1083 https://api.ipify.org 2>/dev/null || true)"
[ -n "$ip" ] && log "OK — egress $ip" || log "restarted; verify egress manually if needed"
