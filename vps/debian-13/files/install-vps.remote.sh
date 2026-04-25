#!/bin/sh

set -eu

XRAY_BIN='${VPS_XRAY_BINARY}'
XRAY_CONFIG_DIR='${VPS_XRAY_CONFIG_DIR}'
XRAY_CONFIG_PATH='${VPS_XRAY_CONFIG_PATH}'
XRAY_LOG_DIR='${VPS_XRAY_LOG_DIR}'
XRAY_SERVICE='${VPS_XRAY_SERVICE}'
REMOTE_META_PATH='${VPS_REMOTE_META_PATH}'
XRAY_PORT='${XRAY_PORT}'

service_user() {
  local user

  user="$(systemctl show -p User --value "$XRAY_SERVICE" 2>/dev/null || true)"
  [ -n "$user" ] || user='root'
  printf '%s\n' "$user"
}

service_group() {
  local user="$1"
  local group

  group="$(systemctl show -p Group --value "$XRAY_SERVICE" 2>/dev/null || true)"
  if [ -z "$group" ]; then
    group="$(id -gn "$user" 2>/dev/null || true)"
  fi
  [ -n "$group" ] || group="$user"
  printf '%s\n' "$group"
}

fix_runtime_permissions() {
  local user="$1"
  local group="$2"

  install -d -m 750 "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR"
  chown "$user:$group" "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR"
  chmod 750 "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR"

  touch "$XRAY_LOG_DIR/access.log" "$XRAY_LOG_DIR/error.log"
  find "$XRAY_LOG_DIR" -maxdepth 1 -type f -name '*.log*' -exec chown "$user:$group" '{}' ';' 2>/dev/null || true
  find "$XRAY_LOG_DIR" -maxdepth 1 -type f -name '*.log*' -exec chmod 640 '{}' ';' 2>/dev/null || true
}

restart_xray() {
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "$XRAY_SERVICE" >/dev/null 2>&1
  systemctl restart "$XRAY_SERVICE"
}

ensure_xray_firewall_port() {
  case "$XRAY_PORT" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | grep -q '^Status: active' || return 0
    ufw allow "${XRAY_PORT}/tcp" >/dev/null 2>&1
  fi
}

dump_xray_failure() {
  systemctl status "$XRAY_SERVICE" --no-pager 2>/dev/null || true
  journalctl -u "$XRAY_SERVICE" -n 40 --no-pager 2>/dev/null || true
}

if [ ! -x "$XRAY_BIN" ]; then
  bundled='/tmp/xray-bundled.zip'
  if [ -f "$bundled" ]; then
    mkdir -p /tmp/xray-extract
    if command -v unzip >/dev/null 2>&1; then
      unzip -oq "$bundled" -d /tmp/xray-extract
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
        "$bundled" /tmp/xray-extract
    else
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq unzip >/dev/null 2>&1 || true
      command -v unzip >/dev/null 2>&1 || {
        echo "ERROR: Cannot extract bundled Xray: no unzip, no python3, and apt-get failed." >&2
        exit 1
      }
      unzip -oq "$bundled" -d /tmp/xray-extract
    fi
    [ -f /tmp/xray-extract/xray ] || {
      echo "ERROR: Bundled Xray archive did not contain the expected binary." >&2
      rm -rf /tmp/xray-extract "$bundled"
      exit 1
    }
    install -m 755 /tmp/xray-extract/xray "$XRAY_BIN"
    "$XRAY_BIN" version >/dev/null 2>&1 || {
      echo "ERROR: Extracted Xray binary is corrupt or incompatible with this architecture." >&2
      rm -f "$XRAY_BIN"
      rm -rf /tmp/xray-extract "$bundled"
      exit 1
    }
    rm -rf /tmp/xray-extract "$bundled"
    if [ ! -f "/etc/systemd/system/${XRAY_SERVICE}.service" ]; then
      cat > "/etc/systemd/system/${XRAY_SERVICE}.service" <<UNIT
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG_PATH
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  else
    tmp='/tmp/install-xray.sh'
    curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$tmp" || \
      wget -qO "$tmp" https://github.com/XTLS/Xray-install/raw/main/install-release.sh
    bash "$tmp" install
    rm -f "$tmp"
  fi
fi

systemctl daemon-reload >/dev/null 2>&1 || true
runtime_user="$(service_user)"
runtime_group="$(service_group "$runtime_user")"
fix_runtime_permissions "$runtime_user" "$runtime_group"
"$XRAY_BIN" run -test -config /tmp/codex-router-vps-config.json >/dev/null 2>&1

if command -v ufw >/dev/null 2>&1; then
  ufw_state="$(ufw status 2>/dev/null | sed -n '1p' || true)"
  if [ "$ufw_state" = 'Status: active' ]; then
    ufw allow "${XRAY_PORT}/tcp" >/dev/null 2>&1 || true
  fi
fi

if [ -f "$XRAY_CONFIG_PATH" ]; then
  cp "$XRAY_CONFIG_PATH" "$XRAY_CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)"
fi

cat /tmp/codex-router-vps-config.json > "$XRAY_CONFIG_PATH"
chown "$runtime_user:$runtime_group" "$XRAY_CONFIG_PATH"
chmod 640 "$XRAY_CONFIG_PATH"
cat /tmp/codex-router-meta.env > "$REMOTE_META_PATH"
chmod 600 "$REMOTE_META_PATH"
fix_runtime_permissions "$runtime_user" "$runtime_group"
ensure_xray_firewall_port

restart_xray || {
  dump_xray_failure
  exit 1
}
systemctl is-active "$XRAY_SERVICE" >/dev/null || {
  dump_xray_failure
  exit 1
}
i=0
while [ "$i" -lt 15 ]; do
  ss -ltnp 2>/dev/null | grep -q ":${XRAY_PORT} " && break
  systemctl is-active "$XRAY_SERVICE" >/dev/null || {
    dump_xray_failure
    exit 1
  }
  i=$((i + 1))
  sleep 1
done
systemctl is-active "$XRAY_SERVICE" >/dev/null || {
  dump_xray_failure
  exit 1
}
ss -ltnp 2>/dev/null | grep -q ":${XRAY_PORT} " || {
  dump_xray_failure
  exit 1
}
