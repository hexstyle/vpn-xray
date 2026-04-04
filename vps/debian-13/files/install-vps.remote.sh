#!/bin/sh

set -eu

XRAY_BIN='${VPS_XRAY_BINARY}'
XRAY_CONFIG_DIR='${VPS_XRAY_CONFIG_DIR}'
XRAY_CONFIG_PATH='${VPS_XRAY_CONFIG_PATH}'
XRAY_LOG_DIR='${VPS_XRAY_LOG_DIR}'
XRAY_SERVICE='${VPS_XRAY_SERVICE}'
REMOTE_META_PATH='${VPS_REMOTE_META_PATH}'

if [ ! -x "$XRAY_BIN" ]; then
  tmp='/tmp/install-xray.sh'
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$tmp" || \
    wget -qO "$tmp" https://github.com/XTLS/Xray-install/raw/main/install-release.sh
  bash "$tmp" install
  rm -f "$tmp"
fi

install -d -m 750 "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR"
"$XRAY_BIN" run -test -config /tmp/codex-router-vps-config.json >/dev/null 2>&1

if [ -f "$XRAY_CONFIG_PATH" ]; then
  cp "$XRAY_CONFIG_PATH" "$XRAY_CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)"
fi

cat /tmp/codex-router-vps-config.json > "$XRAY_CONFIG_PATH"
chmod 600 "$XRAY_CONFIG_PATH"
cat /tmp/codex-router-meta.env > "$REMOTE_META_PATH"
chmod 600 "$REMOTE_META_PATH"

systemctl restart "$XRAY_SERVICE"
systemctl is-active "$XRAY_SERVICE" >/dev/null
