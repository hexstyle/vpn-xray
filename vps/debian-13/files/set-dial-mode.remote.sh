#!/bin/sh
set -eu

META_PATH="${VPS_REMOTE_META_PATH:-/usr/local/etc/xray/codex-router-meta.env}"
NEW_MODE="${NEW_DIAL_MODE:-}"

case "$NEW_MODE" in
	direct|ssh_tunnel) ;;
	*) echo 'NEW_DIAL_MODE must be direct or ssh_tunnel' >&2; exit 2 ;;
esac
[ -s "$META_PATH" ] || { echo "Managed VPS metadata not found: $META_PATH" >&2; exit 1; }

stamp="$(date +%Y%m%d%H%M%S)"
backup="${META_PATH}.bak.${stamp}.$$"
tmp="${META_PATH}.new.$$"
cp -p "$META_PATH" "$backup"

awk -v mode="$NEW_MODE" '
	BEGIN { found = 0 }
	/^XRAY_DIAL_MODE=/ { print "XRAY_DIAL_MODE=" mode; found = 1; next }
	{ print }
	END { if (!found) print "XRAY_DIAL_MODE=" mode }
' "$META_PATH" > "$tmp"
chmod --reference="$META_PATH" "$tmp" 2>/dev/null || chmod 600 "$tmp"
chown --reference="$META_PATH" "$tmp" 2>/dev/null || true
mv "$tmp" "$META_PATH"

. "$META_PATH"
[ "${XRAY_DIAL_MODE:-}" = "$NEW_MODE" ] || {
	cp -p "$backup" "$META_PATH"
	echo 'Managed dial mode verification failed; metadata rolled back.' >&2
	exit 1
}

echo "XRAY_DIAL_MODE=$XRAY_DIAL_MODE"
echo "BACKUP=$backup"
