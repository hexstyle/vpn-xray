#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/required-env.sh"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/config/asus-router.env}"

load_env_file "$ENV_FILE" "$ROOT_DIR/config/asus-router.env.example"

require_vars \
  ROUTER_HOST \
  RULES_REPO_FETCH_URL \
  RULES_REPO_PUSH_URL \
  RULES_REPO_BRANCH \
  RULES_GIT_USER_NAME \
  RULES_GIT_USER_EMAIL \
  RULES_DNS_RESOLVER \
  RULES_DEVICE_ID \
  RULES_ENABLE_PUSH \
  RULES_CONSUMER \
  RULES_SYNC_INTERVAL \
  XRAY_RULES_MODE

reject_placeholder_vars \
  ROUTER_HOST \
  RULES_REPO_FETCH_URL \
  RULES_REPO_PUSH_URL \
  RULES_DEVICE_ID

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

router_rules_cfg="$tmpdir/router-rules.config"
python3 - <<'PY' "$ROOT_DIR/router-files/router-rules.config.template" "$router_rules_cfg"
import os, pathlib, re, sys
template = pathlib.Path(sys.argv[1]).read_text()
def repl(match):
    key = match.group(1)
    return os.environ[key]
out = re.sub(r"\$\{([A-Z0-9_]+)\}", repl, template)
pathlib.Path(sys.argv[2]).write_text(out)
PY

ssh "root@$ROUTER_HOST" '
  /etc/init.d/router-rules-sync stop >/dev/null 2>&1 || true
  killall git nslookup dig curl >/dev/null 2>&1 || true
  for pid in $(ps w | awk '\''$5=="/bin/sh" && $6=="/usr/bin/router-rules" {print $1}'\''); do
    kill "$pid" 2>/dev/null || true
  done
  mkdir -p /etc/router-rules/generated /etc/router-rules/ssh
  opkg install git git-http curl ca-bundle ca-certificates >/dev/null 2>&1 || true
'
ssh "root@$ROUTER_HOST" 'cat > /etc/config/router_rules && chmod 600 /etc/config/router_rules' < "$router_rules_cfg"
ssh "root@$ROUTER_HOST" 'cat > /usr/bin/router-rules && chmod 755 /usr/bin/router-rules' < "$ROOT_DIR/router-files/router-rules"
ssh "root@$ROUTER_HOST" 'cat > /etc/init.d/router-rules-sync && chmod 755 /etc/init.d/router-rules-sync' < "$ROOT_DIR/router-files/router-rules-sync.init"
ssh "root@$ROUTER_HOST" 'cat > /etc/init.d/ss-domain-filter && chmod 755 /etc/init.d/ss-domain-filter' < "$ROOT_DIR/router-files/ss-domain-filter.init"
ssh "root@$ROUTER_HOST" '
  repo=/etc/router-rules/repo
  if [ -d "$repo/.git" ]; then
    git -C "$repo" fetch origin main >/dev/null 2>&1 || true
    git -C "$repo" reset --hard origin/main >/dev/null 2>&1 || true
    git -C "$repo" clean -fd >/dev/null 2>&1 || true
  fi
  /usr/bin/router-rules sync-apply-shadowsocks >/dev/null 2>&1 || true
  /etc/init.d/router-rules-sync stop >/dev/null 2>&1 || true
  /etc/init.d/router-rules-sync enable >/dev/null 2>&1 || true
  /etc/init.d/router-rules-sync start >/dev/null 2>&1 || true
'

echo "Deployed ASUS rules consumer to $ROUTER_HOST"
