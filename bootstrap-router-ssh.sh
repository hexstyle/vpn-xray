#!/usr/bin/env bash

set -euo pipefail

# Конфигурация
REPO_SLUG="${VPN_XRAY_REPO_SLUG:-hexstyle/vpn-xray}"
REPO_REF="${VPN_XRAY_REF:-main}"
ROUTER_SSH="${1:-root@192.168.8.1}"

# ИСПРАВЛЕНО: Добавлены знаки $ перед переменными и правильные домены
URL_GITHUB="https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}/bootstrap-router.sh"
URL_JSDELIVR="https://raw.jsdelivr.net/${REPO_SLUG}@${REPO_REF}/bootstrap-router.sh"

info() { printf '%s\n' "$*"; }

if [ -z "${RULES_GIT_SSH_PRIVATE_KEY:-}" ] && [ -n "${RULES_GIT_SSH_PRIVATE_KEY_FILE:-}" ]; then
    [ -r "${RULES_GIT_SSH_PRIVATE_KEY_FILE}" ] || {
        printf 'ERROR: RULES_GIT_SSH_PRIVATE_KEY_FILE is not readable: %s\n' "${RULES_GIT_SSH_PRIVATE_KEY_FILE}" >&2
        exit 1
    }
    RULES_GIT_SSH_PRIVATE_KEY="$(cat "${RULES_GIT_SSH_PRIVATE_KEY_FILE}")"
fi
RULES_GIT_SSH_PRIVATE_KEY_B64=''
if [ -n "${RULES_GIT_SSH_PRIVATE_KEY:-}" ]; then
    RULES_GIT_SSH_PRIVATE_KEY_B64="$(
        printf '%s' "$RULES_GIT_SSH_PRIVATE_KEY" | python3 - <<'PY'
import base64
import sys

sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode("ascii"))
PY
    )"
fi

info "Starting vpn-xray bootstrap on: $ROUTER_SSH ..."

# Передаем готовые URL внутрь SSH
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$ROUTER_SSH" "sh -s" <<REMOTE
set -u
# Здесь переменные подставляются локально перед отправкой команды
URL1="$URL_GITHUB"
URL2="$URL_JSDELIVR"
TMP="/tmp/bootstrap.sh"

download_attempt() {
    local url="\$1"
    echo "  [Router]: Requesting URL: \$url"

    # Пробуем wget или curl (учитываем особенности BusyBox на роутерах)
    if wget --no-check-certificate -q -O "\$TMP" "\$url" || curl -fkL -o "\$TMP" "\$url"; then
        if [ -s "\$TMP" ]; then
            return 0
        fi
    fi
    return 1
}

# 1. Попытка скачивания
if download_attempt "\$URL1"; then
    echo "  [Router]: Success! (via GitHub)"
elif download_attempt "\$URL2"; then
    echo "  [Router]: Success! (via jsDelivr)"
else
    echo "  [Router]: ERROR - Could not download script."
    exit 1
fi

# 2. Запуск
echo "  [Router]: Executing bootstrap..."
RULES_GIT_SYNC_ENABLED='${RULES_GIT_SYNC_ENABLED:-}' \
RULES_REPO_FETCH_URL='${RULES_REPO_FETCH_URL:-}' \
RULES_REPO_PUSH_URL='${RULES_REPO_PUSH_URL:-}' \
RULES_REPO_BRANCH='${RULES_REPO_BRANCH:-main}' \
RULES_GIT_AUTH_MODE='${RULES_GIT_AUTH_MODE:-auto}' \
RULES_GIT_HTTP_USERNAME='${RULES_GIT_HTTP_USERNAME:-}' \
RULES_GIT_HTTP_PASSWORD='${RULES_GIT_HTTP_PASSWORD:-}' \
RULES_GIT_SSH_PRIVATE_KEY_B64='${RULES_GIT_SSH_PRIVATE_KEY_B64:-}' \
RULES_DEVICE_ID='${RULES_DEVICE_ID:-gl-router}' \
RULES_ENABLE_PUSH='${RULES_ENABLE_PUSH:-0}' \
RULES_SYNC_INTERVAL='${RULES_SYNC_INTERVAL:-30}' \
RULES_GIT_USER_NAME='${RULES_GIT_USER_NAME:-router-rules}' \
RULES_GIT_USER_EMAIL='${RULES_GIT_USER_EMAIL:-router-rules@example.invalid}' \
RULES_DNS_RESOLVER='${RULES_DNS_RESOLVER:-9.9.9.9 208.67.222.222}' \
XRAY_RULES_MODE='${XRAY_RULES_MODE:-full}' \
sh "\$TMP"
rm -f "\$TMP"
REMOTE

info "Done!"
