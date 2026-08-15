#!/usr/bin/env bash
# install-router-lib.sh — helper functions + the post-preflight deploy/verify
# flow for this profile's install-router.sh (AGENTS.md 500-line rule). Sourced
# after common/lib/{env,install-progress}.sh. install_router_main() wraps the
# original top-level tail verbatim; it uses only globals (no positional params,
# return, or local), so its behaviour is byte-for-byte identical when called.

install_progress_after_update() {
  # Hook called by install-progress.sh after every transition. Mirror the
  # JSON to the router so the UI banner can render live progress. Failures
  # are intentionally swallowed — telemetry must not break the install.
  [ -n "${ROUTER_SSH:-}" ] || return 0
  [ -n "${INSTALLER_KNOWN_HOSTS:-}" ] || return 0
  [ -f "${_VX_PROGRESS_STATUS_FILE:-}" ] || return 0
  # Ride the shared master connection (ROUTER_SSH_OPTS carries mux + identity)
  # and never prompt — telemetry must not block the install.
  ssh -o BatchMode=yes "${ROUTER_SSH_OPTS[@]}" \
    "$ROUTER_SSH" "cat > $ROUTER_INSTALL_STATUS_FILE.tmp && mv $ROUTER_INSTALL_STATUS_FILE.tmp $ROUTER_INSTALL_STATUS_FILE" \
    < "$_VX_PROGRESS_STATUS_FILE" >/dev/null 2>&1 || true
}

router_ssh() {
  local err rc attempt max_retries=3

  for (( attempt = 1; attempt <= max_retries; attempt++ )); do
    err="$(mktemp)"
    if ssh "${ROUTER_SSH_OPTS[@]}" "$ROUTER_SSH" "$@" 2>"$err"; then
      rm -f "$err"
      return 0
    fi

    rc=$?

    if grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$err"; then
      cat "$err" >&2
      echo "Installer SSH cache has a stale host key for $ROUTER_HOST. Refreshing and retrying once..." >&2
      remove_hostkey_entry "$INSTALLER_KNOWN_HOSTS" "$ROUTER_HOST"
      rm -f "$err"
      continue
    fi

    # Retry on transient connection failures (network reload, WiFi blip,
    # service restart on the router that briefly drops sshd). Match common
    # variants from OpenSSH on macOS and Linux as well as the wording sshd
    # produces when it tears the connection down during a reload.
    if grep -qiE 'Connection reset|Broken pipe|Connection refused|Connection (timed out|closed)|Operation timed out|No route to host|kex_exchange_identification|port 22: (Operation|Connection)' "$err" && (( attempt < max_retries )); then
      echo "Router SSH attempt $attempt/$max_retries failed (transient). Retrying in 3s..." >&2
      rm -f "$err"
      sleep 3
      continue
    fi

    cat "$err" >&2
    rm -f "$err"
    break
  done

  # ssh returns 255 only for a genuine transport/auth failure; any other
  # non-zero code is the REMOTE command's own exit status (e.g. a benign
  # `[ -f ... ]` probe returning 1). Password fallback and the "SSH failed"
  # banner apply only to the former — otherwise every non-zero remote command
  # would be misreported as a broken SSH connection (the 2026-08 noisy install).
  if [ "$rc" = 255 ] && [ -n "${ROUTER_PASSWORD:-}" ]; then
    err="$(mktemp)"
    if router_ssh_with_password "$err" "$@"; then
      rm -f "$err"
      return 0
    fi
    rc=$?
    cat "$err" >&2
    rm -f "$err"
  fi

  if [ "$rc" = 255 ]; then
    echo "Router SSH failed for $ROUTER_SSH." >&2
    echo "Checks: the router should be reachable at $ROUTER_HOST, SSH must accept the current admin password, and the installer uses its own host-key cache at $INSTALLER_KNOWN_HOSTS." >&2
    echo "If the router was factory-reset or replaced, rerun the install. The stale key in ~/.ssh/known_hosts is no longer relevant to this installer." >&2
  fi
  return "$rc"
}

# --- Router key-auth bootstrap ---------------------------------------------
# A clean/factory router trusts no key, so every router_ssh would prompt for the
# admin password (the "typed the password 100 times" report). These helpers
# install the workstation public key on the router after at most ONE password
# prompt, then pin key auth so the rest of the install is prompt-free.

ROUTER_PASSWORD="${ROUTER_PASSWORD:-}"
_VX_ROUTER_ASKPASS=''

_vx_cleanup_router_askpass() {
  [ -n "$_VX_ROUTER_ASKPASS" ] && rm -f "$_VX_ROUTER_ASKPASS" 2>/dev/null || true
}

router_key_auth_works() {
  ssh -o BatchMode=yes -o PreferredAuthentications=publickey -o ControlPath=none \
    "${ROUTER_SSH_OPTS[@]}" "$ROUTER_SSH" 'true' >/dev/null 2>&1
}

# router_ssh_with_password <errfile> <remote-cmd...> — one ssh using the cached
# admin password (sshpass if present, else a throwaway SSH_ASKPASS helper).
router_ssh_with_password() {
  local err="$1"
  shift
  [ -n "${ROUTER_PASSWORD:-}" ] || return 1

  if command -v sshpass >/dev/null 2>&1; then
    SSHPASS="$ROUTER_PASSWORD" sshpass -e ssh \
      -o BatchMode=no \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      "${ROUTER_SSH_OPTS[@]}" "$ROUTER_SSH" "$@" 2>"$err"
    return $?
  fi

  if [ -z "$_VX_ROUTER_ASKPASS" ]; then
    _VX_ROUTER_ASKPASS="$(mktemp "${TMPDIR:-/tmp}/vx-router-askpass.XXXXXX")"
    cat > "$_VX_ROUTER_ASKPASS" <<EOF
#!/bin/sh
printf '%s\n' $(shell_quote "$ROUTER_PASSWORD")
EOF
    chmod 700 "$_VX_ROUTER_ASKPASS"
    trap _vx_cleanup_router_askpass EXIT
  fi
  DISPLAY=1 SSH_ASKPASS="$_VX_ROUTER_ASKPASS" SSH_ASKPASS_REQUIRE=force \
    ssh \
      -o BatchMode=no \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      "${ROUTER_SSH_OPTS[@]}" "$ROUTER_SSH" "$@" 2>"$err"
}

ensure_router_key_auth() {
  local pub keyline err rc

  # Pin the chosen identity so the key probe tests exactly our key (and the
  # master connection opens with it) rather than whatever the agent offers.
  if [ -n "${ROUTER_IDENTITY:-}" ] && [ -r "${ROUTER_IDENTITY}" ]; then
    ROUTER_SSH_OPTS+=( -o IdentityFile="$ROUTER_IDENTITY" -o IdentitiesOnly=yes )
  fi

  # 1. Already trusted? Pin key-only + BatchMode so no later hiccup can turn
  #    into an interactive prompt, then return (the common re-install case).
  if router_key_auth_works; then
    ROUTER_SSH_OPTS+=( -o PreferredAuthentications=publickey -o BatchMode=yes )
    return 0
  fi

  # 2. Need a public key to install. Prefer the detected workstation key; if the
  #    workstation has none, generate a dedicated installer key so a keyless
  #    machine still ends up with passwordless access.
  pub="${ROUTER_IDENTITY_PUB:-}"
  if [ -z "$pub" ] || [ ! -r "$pub" ]; then
    warn "No usable local SSH public key for the router; generating an installer key."
    mkdir -p "$(installer_ssh_dir "$ROOT_DIR")"
    ROUTER_IDENTITY="$(installer_ssh_dir "$ROOT_DIR")/router_id_ed25519"
    [ -f "$ROUTER_IDENTITY" ] || ssh-keygen -q -t ed25519 -N '' -f "$ROUTER_IDENTITY" -C 'vpn-xray-installer'
    pub="${ROUTER_IDENTITY}.pub"
    ROUTER_SSH_OPTS+=( -o IdentityFile="$ROUTER_IDENTITY" -o IdentitiesOnly=yes )
  fi

  # 3. Obtain the admin password: from env (non-interactive), else one prompt.
  if [ -z "${ROUTER_PASSWORD:-}" ]; then
    if [ ! -t 0 ] || [ ! -t 1 ]; then
      warn "Router key auth is not set up and no ROUTER_PASSWORD / TTY is available; router_ssh may prompt per call."
      return 0
    fi
    echo
    echo "Key-based SSH is not set up yet for $ROUTER_SSH (clean router)."
    read -rsp "Enter admin password for $ROUTER_SSH (one time, to install the key): " ROUTER_PASSWORD
    echo
    [ -n "$ROUTER_PASSWORD" ] || { warn "No password entered; continuing without key auth (expect per-call prompts)."; return 0; }
  fi

  # 4. Drop any stale host key so the password connection is not refused, then
  #    append our pubkey to both the dropbear and ~/.ssh authorized_keys files
  #    (OpenWrt/dropbear reads the former; belt-and-suspenders for the latter).
  remove_hostkey_entry "$INSTALLER_KNOWN_HOSTS" "$ROUTER_HOST" 2>/dev/null || true
  keyline="$(cat "$pub")"
  err="$(mktemp)"
  router_ssh_with_password "$err" "
    mkdir -p /etc/dropbear /root/.ssh 2>/dev/null || true
    for f in /etc/dropbear/authorized_keys /root/.ssh/authorized_keys; do
      touch \"\$f\" 2>/dev/null || continue
      chmod 600 \"\$f\" 2>/dev/null || true
      grep -qxF $(shell_quote "$keyline") \"\$f\" 2>/dev/null || printf '%s\n' $(shell_quote "$keyline") >> \"\$f\"
    done
  "
  rc=$?
  rm -f "$err"
  if [ "$rc" -ne 0 ]; then
    warn "Could not install the SSH key on the router (admin password rejected?). Continuing; router_ssh will fall back to the password."
    return 0
  fi

  # 5. Confirm and pin key auth so nothing silently falls back to a prompt.
  if router_key_auth_works; then
    ROUTER_SSH_OPTS+=( -o PreferredAuthentications=publickey -o BatchMode=yes )
    ROUTER_PASSWORD=''
    _vx_cleanup_router_askpass
    _VX_ROUTER_ASKPASS=''
    echo "Installed SSH key on the router — the rest of the install runs without password prompts."
    return 0
  fi
  warn "Key auth still not confirmed after key install; router_ssh will use the cached password for this run."
  return 0
}

router_ssh_ready() {
  # Ride the shared master + identity; never prompt while polling for the
  # router to come back after a network reload.
  ssh -o BatchMode=yes -o ConnectTimeout="$ROUTER_RELOAD_PROBE_TIMEOUT" \
    "${ROUTER_SSH_OPTS[@]}" \
    "$ROUTER_SSH" "true" >/dev/null 2>&1
}

wait_for_router_after_network_reload() {
  local deadline

  deadline=$((SECONDS + ROUTER_RELOAD_WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if router_ssh_ready; then
      return 0
    fi
    sleep 2
  done
  return 1
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

current_router_rules_mode() {
  local mode

  mode="$(router_ssh "uci -q get router_rules.global.xray_mode 2>/dev/null || true" | tr -d '\r' | sed -n '1p')"
  case "$mode" in
    full|selective)
      printf '%s\n' "$mode"
      ;;
  esac
}

current_router_external_source_config() {
  router_ssh "printf 'ENABLED=%s\n' \"\$(uci -q get router_rules.global.external_source_enabled 2>/dev/null || true)\"; printf 'URL=%s\n' \"\$(uci -q get router_rules.global.external_source_url 2>/dev/null || true)\"; printf 'INTERVAL=%s\n' \"\$(uci -q get router_rules.global.external_source_interval 2>/dev/null || true)\""
}

current_vps_xray_meta() {
  [[ -n "${VPS_SSH:-}" ]] || return 1
  ssh "${VPS_SSH_OPTS[@]}" "$VPS_SSH" "meta='/usr/local/etc/xray/codex-router-meta.env'; [ -f \"\$meta\" ] || exit 1; sed -n '1,200p' \"\$meta\""
}

current_vps_xray_runtime_facts() {
  [[ -n "${VPS_SSH:-}" ]] || return 1
  ssh "${VPS_SSH_OPTS[@]}" "$VPS_SSH" "CONFIG_PATH=$(shell_quote "${VPS_XRAY_CONFIG_PATH:-/usr/local/etc/xray/config.json}") sh -s" <<'EOF'
config_path="${CONFIG_PATH:-/usr/local/etc/xray/config.json}"
[ -f "$config_path" ] || exit 1
config_port="$(sed -n 's/^[[:space:]]*"port":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$config_path" | sed -n '1p')"
[ -n "$config_port" ] && printf 'CONFIG_PORT=%s\n' "$config_port"
EOF
}

wait_for_router_runtime_ready() {
  local attempt max_attempts sleep_seconds

  max_attempts="${ROUTER_RUNTIME_READY_ATTEMPTS:-30}"
  sleep_seconds="${ROUTER_RUNTIME_READY_INTERVAL:-2}"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if router_ssh "pgrep -af codex-xray-core >/dev/null 2>&1 && pgrep -af redsocks >/dev/null 2>&1"; then
      return 0
    fi
    sleep "$sleep_seconds"
  done

  return 1
}

wait_for_router_background_services_ready() {
  local attempt max_attempts sleep_seconds

  max_attempts="${ROUTER_BACKGROUND_READY_ATTEMPTS:-20}"
  sleep_seconds="${ROUTER_BACKGROUND_READY_INTERVAL:-1}"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if router_ssh "/etc/init.d/xray-switch-watchdog running >/dev/null 2>&1 && /etc/init.d/router-rules-sync running >/dev/null 2>&1"; then
      return 0
    fi
    sleep "$sleep_seconds"
  done

  return 1
}

wait_for_transparent_path_ready() {
  local attempt max_attempts sleep_seconds

  max_attempts="${ROUTER_TRANSPROXY_READY_ATTEMPTS:-15}"
  sleep_seconds="${ROUTER_TRANSPROXY_READY_INTERVAL:-2}"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if router_ssh 'netstat -ltn 2>/dev/null | grep -q ":12345 " && iptables -t nat -S PREROUTING 2>/dev/null | grep -q CODEX_TRANSPROXY'; then
      return 0
    fi
    sleep "$sleep_seconds"
  done

  return 1
}

cleanup() {
  rm -rf "$tmpdir"
}

render_template() {
  local input="$1"
  local output="$2"
  MSYS2_ENV_CONV_EXCL='*' python3 - <<'PY' "$input" "$output"
import os, pathlib, re, sys

template_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
template = template_path.read_text()

def repl(match):
    key = match.group(1)
    try:
        return os.environ[key]
    except KeyError:
        raise SystemExit(f"Template {template_path} requires env variable {key}, but it is missing")

with output_path.open("w", encoding="utf-8", newline="\n") as fh:
    fh.write(re.sub(r"\$\{([A-Z0-9_]+)\}", repl, template))
PY
}

install_router_main() {

source_bundle="$tmpdir/router-source.tar"
json_cfg="$tmpdir/codex-xray.json"
redsocks_cfg="$tmpdir/redsocks.conf"
router_rules_cfg="$tmpdir/router-rules.config"

install_progress_begin "Render router config templates"
# COPYFILE_DISABLE=1 stops macOS bsdtar from emitting AppleDouble "._*" members
# for files carrying xattrs (com.apple.provenance on the bundled .ipk packages);
# --exclude drops any that already exist on disk. Without this the router's
# `find *.ipk` picks up "._python3-light_*.ipk" and opkg aborts with "Malformed
# package file", so python3 never installs (the 2026-08 clean-router failure).
COPYFILE_DISABLE=1 tar --exclude='._*' -C "$ROOT_DIR" -cf "$source_bundle" common routers vps
render_template "$ROUTER_PROFILE_DIR/files/codex-xray.json.template" "$json_cfg"
render_template "$ROUTER_PROFILE_DIR/files/redsocks.conf.template" "$redsocks_cfg"
render_template "$ROUTER_COMMON_DIR/files/router-rules.config.template" "$router_rules_cfg"

PLATFORM_RESUME_FLAG=''
if router_ssh "[ -f /tmp/vpn-xray-install-progress ]" >/dev/null 2>&1; then
  PLATFORM_RESUME_FLAG=' --resume'
fi

remote_source_root='/tmp/vpn-xray-local-src'
remote_source_tar='/tmp/vpn-xray-local-src.tar'
remote_platform_cmd=$(
  cat <<EOF
RULES_GIT_SYNC_ENABLED=$(shell_quote "$RULES_GIT_SYNC_ENABLED") \
RULES_REPO_FETCH_URL=$(shell_quote "$RULES_REPO_FETCH_URL") \
RULES_REPO_PUSH_URL=$(shell_quote "$RULES_REPO_PUSH_URL") \
RULES_REPO_BRANCH=$(shell_quote "$RULES_REPO_BRANCH") \
RULES_GIT_AUTH_MODE=$(shell_quote "$RULES_GIT_AUTH_MODE") \
RULES_GIT_HTTP_USERNAME=$(shell_quote "$RULES_GIT_HTTP_USERNAME") \
RULES_GIT_HTTP_PASSWORD=$(shell_quote "$RULES_GIT_HTTP_PASSWORD") \
RULES_GIT_SSH_PRIVATE_KEY_B64=$(shell_quote "$RULES_GIT_SSH_PRIVATE_KEY_B64") \
RULES_DEVICE_ID=$(shell_quote "$RULES_DEVICE_ID") \
RULES_ENABLE_PUSH=$(shell_quote "${RULES_ENABLE_PUSH:-0}") \
RULES_SYNC_INTERVAL=$(shell_quote "${RULES_SYNC_INTERVAL:-30}") \
RULES_EXTERNAL_SOURCE_ENABLED=$(shell_quote "${RULES_EXTERNAL_SOURCE_ENABLED:-0}") \
RULES_EXTERNAL_SOURCE_URL=$(shell_quote "${RULES_EXTERNAL_SOURCE_URL:-}") \
RULES_EXTERNAL_SOURCE_INTERVAL=$(shell_quote "${RULES_EXTERNAL_SOURCE_INTERVAL:-86400}") \
RULES_GIT_USER_NAME=$(shell_quote "${RULES_GIT_USER_NAME:-router-rules}") \
RULES_GIT_USER_EMAIL=$(shell_quote "${RULES_GIT_USER_EMAIL:-router-rules@example.invalid}") \
RULES_DNS_RESOLVER=$(shell_quote "${RULES_DNS_RESOLVER:-9.9.9.9 208.67.222.222}") \
XRAY_RULES_MODE=$(shell_quote "${XRAY_RULES_MODE:-full}") \
ISOLATE_WIFI_LAN_ONLY=$(shell_quote "${ISOLATE_WIFI_LAN_ONLY:-0}") \
VPN_XRAY_REPO_SLUG=$(shell_quote "local-source-bundle") \
VPN_XRAY_REF=$(shell_quote "local-install") \
sh $(shell_quote "$remote_source_root/routers/$ROUTER_PROFILE/install-platform.sh") --source-dir $(shell_quote "$remote_source_root")${PLATFORM_RESUME_FLAG}
EOF
)

install_progress_begin "Stage source bundle on router"
router_ssh "rm -rf $remote_source_root && mkdir -p $remote_source_root"
router_ssh "cat > $remote_source_tar" < "$source_bundle"
router_ssh "tar -xf $remote_source_tar -C $remote_source_root && rm -f $remote_source_tar"
router_ssh "sed -i 's/\r$//' $remote_source_root/routers/$ROUTER_PROFILE/install-platform.sh $remote_source_root/routers/$ROUTER_PROFILE/install-platform-lib-a.sh $remote_source_root/routers/$ROUTER_PROFILE/install-platform-lib-b.sh"

# Deploy configs BEFORE install-platform.sh so they survive if the router
# reboots during platform setup (e.g. network/wireless reload).
router_ssh 'mkdir -p /etc/xray/logs'
router_ssh 'cat > /etc/xray/codex-xray.json && chmod 600 /etc/xray/codex-xray.json' < "$json_cfg"
router_ssh 'cat > /etc/redsocks.conf && chmod 600 /etc/redsocks.conf' < "$redsocks_cfg"
# Push the VPS-side TLS cert fetched by install-vps.sh, falling back to
# the cert bundled with the profile when no VPS install was run in this
# session. install-platform.sh's copy_if_changed is the deeper fallback.
vps_cert_local="$ROOT_DIR/tmp/vps-server.crt"
profile_cert="$ROUTER_PROFILE_DIR/files/server.crt"
if [[ -s "$vps_cert_local" ]]; then
  router_ssh 'cat > /etc/xray/server.crt && chmod 644 /etc/xray/server.crt' < "$vps_cert_local"
elif [[ -s "$profile_cert" ]]; then
  router_ssh 'cat > /etc/xray/server.crt && chmod 644 /etc/xray/server.crt' < "$profile_cert"
fi
# Only seed /etc/config/router_rules from the rendered template when the file
# is missing or empty. The template only enumerates a fixed set of options;
# overwriting an existing file would wipe per-source enable flags
# (external_source_<id>_enabled), the layout-version marker, and any other
# state the UI / router-rules has stored. install-platform.sh then reconciles
# the template-known options via `uci batch`, so the existing file gets the
# desired values without losing user state.
if router_ssh '[ -s /etc/config/router_rules ]'; then
  echo "Existing /etc/config/router_rules detected; install-platform will reconcile via uci batch."
else
  router_ssh 'cat > /etc/config/router_rules && chmod 600 /etc/config/router_rules' < "$router_rules_cfg"
fi

install_progress_begin "Install router platform packages and runtime"
router_ssh "$remote_platform_cmd"

install_progress_begin "Validate Xray config and apply runtime"
# install-platform.sh already restarted services (codex-xray, codex-
# transproxy, router-rules-sync, xray-switch-watchdog) and ran
# sync-apply-xray as part of the services step. Re-stopping and re-
# applying everything here previously cost ~127s on a no-op deploy
# because we tore xray down and forced sync-apply-xray to do a full
# cutover from scratch. Keep this step lightweight: validate the
# uploaded config (mostly defensive — install-platform.sh already
# started xray with it), make sure the ready marker reflects success,
# and clean the remote staging dir.
router_ssh "
  exec </dev/null
  /usr/local/bin/codex-xray-core run -test -config /etc/xray/codex-xray.json >/dev/null 2>&1 || {
    echo 'Router Xray config validation failed after upload.' >&2
    exit 1
  }
  touch /etc/xray/codex-xray.ready
  chmod 600 /etc/xray/codex-xray.ready
  rm -rf $remote_source_root
"

# Re-trigger the path control script so the runtime ends up in the requested
# state even if install-platform.sh ran while the path was still being torn
# down. No hardware switch on this router — current_switch_state() returns
# "on" by default on non-GL hardware.
router_ssh "/etc/gl-switch.d/xray.sh on >/dev/null 2>&1 || true"

if ! wait_for_router_background_services_ready; then
  echo "Warning: router background supervisors did not report ready before installer exit." >&2
fi

if ! wait_for_router_runtime_ready; then
  echo "Warning: router runtime did not report ready before installer exit." >&2
fi

install_progress_begin "Provision VPS profile for admin UI"
# Bootstrap VPS profile on the router so the admin panel VPS sync works
# out of the box: create the xray_vps UCI config from the deployed xray
# client config and register the router's managed SSH key on the VPS.
# Runs BEFORE network reload — reload drops SSH connections.
if [[ -n "${VPS_SSH:-}" && -n "${VPS_HOST:-}" ]]; then
  echo "Bootstrapping router VPS profile for admin panel..."

  # Force fresh profile creation from the just-deployed xray config.
  # Any stale xray_vps from a previous install would have wrong values.
  router_ssh "rm -f /etc/config/xray_vps"

  # Invoke the VPS CGI to initialize the profile store: creates a
  # 'default' profile from the router config, generates x25519 material,
  # and creates a managed SSH key pair for router→VPS access.
  router_ssh "QUERY_STRING='action=generate_key' REQUEST_METHOD='GET' /www/cgi-bin/xray-vps >/dev/null 2>&1 || true"

  # Retrieve the router's managed SSH public key
  router_pubkey="$(router_ssh "cat /etc/xray/ssh-keys/default_ed25519.pub 2>/dev/null" || true)"

  if [[ -n "$router_pubkey" ]]; then
    echo "Registering router managed SSH key on VPS ($VPS_HOST)..."
    # The workstation reaches the VPS over its OWN uplink, which — when the
    # workstation is a LAN client of this router — briefly drops during the
    # router service restarts earlier in this run. So a single ssh here can fail
    # transiently even though the VPS is fine and the key is often already
    # registered from a prior install. Make this idempotent + resilient:
    # the remote exits 0 when the key is already present, and we retry a few
    # times, so we only warn on a genuine, sustained failure to reach the VPS.
    register_router_key_on_vps() {
      printf '%s\n' "$router_pubkey" | ssh "${VPS_SSH_OPTS[@]}" "$VPS_SSH" "
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        PUB=\$(cat)
        grep -qxF \"\$PUB\" ~/.ssh/authorized_keys 2>/dev/null && exit 0
        printf '%s\n' \"\$PUB\" >> ~/.ssh/authorized_keys
      " 2>/dev/null
    }
    router_key_registered=0
    for attempt in 1 2 3; do
      if register_router_key_on_vps; then
        router_key_registered=1
        break
      fi
      if [[ "$attempt" -lt 3 ]]; then sleep 3; fi
    done
    if [[ "$router_key_registered" == "1" ]]; then
      echo "Router managed SSH key present on VPS."
    else
      echo "Warning: could not register router SSH key on VPS after 3 attempts. Admin panel VPS sync will need manual key setup." >&2
    fi
  else
    echo "Warning: router did not produce a managed SSH public key. Admin panel VPS sync will need manual key setup." >&2
  fi
else
  echo "VPS_SSH is not configured; skipping admin panel VPS profile bootstrap."
fi

install_progress_begin "Apply firewall/DNS config, keep WAN up"
# History: this step used to run a full `/etc/init.d/network reload`, which
# bounces EVERY interface including the WAN. That dropped xray's route to the
# VPS ("dial ...:443: connect: no route to host") and flushed the transparent
# nat, and the WAN then took ~90s to re-DHCP and re-assert — the recurring
# outage that repeatedly took the router down mid-install.
#
# The install changes only `firewall` (WAN proxy rules) and `dhcp`/dns config
# by default; it changes /etc/config/network ONLY under ISOLATE_WIFI_LAN_ONLY.
# So in the normal case we apply exactly those with `firewall reload` +
# `dnsmasq reload`, which touch no interface state and never drop SSH — the WAN
# and xray's VPS connection stay up the whole time. A full network reload is
# used only when the topology actually changed.
if [[ "$NETWORK_RELOAD" == "1" ]]; then
  if [[ "${ISOLATE_WIFI_LAN_ONLY:-0}" == "1" ]]; then
    # Rare path: ISOLATE_WIFI_LAN_ONLY rewrote /etc/config/network (LAN ports),
    # which genuinely needs a full network reload. It drops SSH, so queue it
    # async and wait for SSH to recover.
    router_ssh "nohup sh -c 'sleep 1; /etc/init.d/network reload >/tmp/vpn-xray-network-reload.log 2>&1 || true' >/dev/null 2>&1 &" >/dev/null 2>&1 || true
    echo "Queued async network reload on $ROUTER_HOST (ISOLATE_WIFI_LAN_ONLY topology change)"
    echo "Waiting for router SSH to recover after network reload..."
    sleep 3
    if wait_for_router_after_network_reload; then
      echo "Router is reachable again over SSH after network reload"
    else
      install_progress_fail "Router did not come back over SSH after network reload" "Verify both wired and Wi-Fi management access before re-running the install."
      exit 1
    fi
  else
    router_ssh "/etc/init.d/firewall reload >/dev/null 2>&1 || true; /etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    echo "Applied firewall + DNS config on $ROUTER_HOST without bouncing the WAN"
  fi

  # `firewall reload` (and a full network reload) rebuild the nat table and drop
  # the runtime CODEX_TRANSPROXY chain, which codex-transproxy adds via raw
  # iptables outside uci. Re-assert the transparent path only if it is actually
  # down (never tear down a working one), and wait for it to come back.
  if router_ssh 'netstat -ltn 2>/dev/null | grep -q ":12345 " && iptables -t nat -S PREROUTING 2>/dev/null | grep -q CODEX_TRANSPROXY'; then
    echo "Transparent path still up after config apply"
  else
    echo "Transparent path was flushed by the reload; re-asserting redsocks + CODEX_TRANSPROXY..."
    router_ssh "/etc/init.d/codex-transproxy restart >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    if wait_for_transparent_path_ready; then
      echo "Transparent path re-asserted"
    else
      echo "Warning: transparent path not confirmed up yet; the checks below will verify and report."
    fi
  fi
fi

install_progress_begin "Verify management plane reachable"
if ! router_ssh_ready; then
  install_progress_fail "Router SSH is not reachable after deploy" "Power-cycle the router and re-run the installer. If SSH still fails, restore the previous config from /etc/config backups."
  exit 1
fi

install_progress_begin "Verify selective routing health"
# Surface the live xray mode, ipset count, and last sync state so the
# operator immediately sees whether selective is up or pulling failed.
# Read the real rules health from ONE status-json call (two calls raced the
# non-blocking status lock and one came back "busy"). Health is the sync PHASE
# ("verified" = healthy); last_sync_status is empty for the phase-based path and
# rendered a misleading "unknown".
selective_health="$(router_ssh '
  j=""
  for i in 1 2 3 4 5; do
    j="$(/usr/bin/router-rules status-json 2>/dev/null)"
    case "$j" in *\"error\":\"busy\"*) sleep 1; continue ;; esac
    break
  done
  mode="$(uci -q get router_rules.global.xray_mode 2>/dev/null)"
  ipset_n="$(ipset list xray_selective_dst 2>/dev/null | sed -n "s/^Number of entries: //p")"
  phase="$(jsonfilter -s "$j" -e "@.sync_phase" 2>/dev/null)"
  pmsg="$(jsonfilter -s "$j" -e "@.sync_phase_message" 2>/dev/null)"
  echo "mode=${mode:-unknown}"
  echo "ipset=${ipset_n:-0}"
  echo "sync=${phase:-unknown}"
  echo "sync_msg=${pmsg:-}"
' || true)"
selective_mode="$(printf '%s\n' "$selective_health" | sed -n 's/^mode=//p' | sed -n '1p')"
selective_ipset="$(printf '%s\n' "$selective_health" | sed -n 's/^ipset=//p' | sed -n '1p')"
selective_sync="$(printf '%s\n' "$selective_health" | sed -n 's/^sync=//p' | sed -n '1p')"
selective_sync_msg="$(printf '%s\n' "$selective_health" | sed -n 's/^sync_msg=//p' | sed -n '1p')"
echo "Routing mode: ${selective_mode:-unknown}, ipset entries: ${selective_ipset:-0}, sync phase: ${selective_sync:-unknown}"

# Selective→FULL fallback: fire only on a genuine failure — the sync phase
# reports an error, OR there are no selective targets at all (ipset empty).
# "verified" is the healthy phase and never falls back.
if [[ "${XRAY_RULES_MODE:-full}" == "selective" ]] \
   && [[ "$selective_sync" != "verified" ]] \
   && { [[ "${selective_ipset:-0}" == "0" ]] || [[ "$selective_sync" == *error* ]]; }; then
  fallback_reason="${selective_sync_msg:-Initial rules sync failed: phase=${selective_sync}}"
  echo "Selective rules sync failed (${selective_sync}). Activating FULL fallback; background-tick will retry every sync interval."
  echo "  Reason: $fallback_reason"
  router_ssh "/usr/bin/router-rules enable-selective-fallback $(shell_quote "$fallback_reason") >/dev/null 2>&1; /usr/bin/router-rules sync-apply-xray >/dev/null 2>&1 || true"
fi

install_progress_begin "End-to-end probe through router proxy"
# Self-heal the router runtime path with the SAME decision tree as the UI's
# Diagnose & Repair before probing (installer-as-tree): if the Xray runtime
# (node 4) or the transparent proxy (node 4.1) is down after the deploy/restart
# churn, run its exact node_repair_run and re-verify. The tree is self-contained
# (test_diag_tree_standalone). Each node is repaired at most once.
router_ssh '
  . /usr/share/vpn-xray/lib-common.sh 2>/dev/null || true
  . /usr/share/vpn-xray/xray-admin-probe.sh 2>/dev/null || true
  . /usr/share/vpn-xray/xray-admin-tree.sh 2>/dev/null || true
  for n in 4 4.1; do
    if [ "$(tree_node_status "$n" 2>/dev/null | cut -f1)" = failed ]; then
      printf "  self-heal: node %s down after deploy; running its repair...\n" "$n"
      node_repair_run "$n" >/dev/null 2>&1 || true
      if [ "$(tree_node_status "$n" 2>/dev/null | cut -f1)" = failed ]; then
        printf "  self-heal: node %s STILL down after repair\n" "$n"
      else
        printf "  self-heal: node %s recovered\n" "$n"
      fi
    fi
  done
' 2>&1 || true

# Verify the data plane works the way the user actually consumes it.
# Two-stage probe through the router HTTP-proxy port:
#  1. Reachability: any HTTP response from chatgpt.com proves TCP+TLS+HTTP
#     all completed end-to-end; antibot 4xx pages still count as "the
#     proxy chain works". Only timeouts / connection refused are failures.
#  2. Chain identity: query an IP echo endpoint and confirm the visible
#     egress IP matches the VPS host, which is the only way to be sure
#     traffic is actually leaving through xray and not, say, the router's
#     direct WAN.
e2e_target="${VPN_XRAY_E2E_TARGET:-https://chatgpt.com}"
e2e_timeout="${VPN_XRAY_E2E_TIMEOUT:-15}"
e2e_proxy="http://${ROUTER_LAN_IP}:${PROXY_PORT}"
e2e_ip_target="${VPN_XRAY_E2E_IP_TARGET:-https://api.ipify.org}"

# Network reload in step 7 flaps interfaces; codex-xray-uplink hotplug then
# rebuilds firewall chains and restarts xray. Wait for runtime to be back up
# before probing — otherwise we race the restart.
if ! wait_for_router_runtime_ready; then
  echo "Warning: runtime not ready before e2e probe; probe may report HTTP 000." >&2
fi

set +e
e2e_status=''
e2e_curl_err="$(mktemp)"
# Run the probe FROM the router itself (loopback to the local HTTP proxy)
# rather than from the workstation. The workstation may be on a different
# segment than ROUTER_LAN_IP (e.g. admin sits behind an upstream router),
# in which case a Mac-side probe would fail for routing reasons unrelated
# to the Xray path actually being broken. Probing on the router keeps the
# test focused on what we actually want to verify.
for e2e_attempt in 1 2 3 4 5 6 7; do
  e2e_status="$(router_ssh "curl --proxy http://127.0.0.1:${PROXY_PORT} -ksS -o /dev/null -m ${e2e_timeout} -w '%{http_code}' $(shell_quote "$e2e_target") 2>/dev/null || true" 2>"$e2e_curl_err" | tr -d '\r' | sed -n '1p')"
  case "$e2e_status" in
    ''|000)
      if [ "$e2e_attempt" = "2" ]; then
        # Self-heal the transport. Re-pin the VPS cert FIRST: a fresh or replaced
        # VPS serves a new self-signed leaf the router does not yet trust ("x509:
        # certificate signed by unknown authority"), which no route change or
        # restart alone can fix. vpn-xray-repin-cert fetches the cert the VPS
        # actually serves now and pins it; then re-pin the route (stale "no route
        # to host") and restart so xray reloads the corrected pin.
        echo "  Reachability still failing; self-healing transport (re-pin VPS cert + route + restart)..."
        router_ssh '/usr/bin/vpn-xray-repin-cert >/dev/null 2>&1 || true; /etc/init.d/codex-xray refresh_egress_route >/dev/null 2>&1 || true; /etc/init.d/codex-xray restart >/dev/null 2>&1 || true' >/dev/null 2>&1 || true
        sleep 8
      else
        sleep 3
      fi
      continue
      ;;
    *)
      break
      ;;
  esac
done

case "$e2e_status" in
  ''|000)
    # Router runtime/transparent path were self-healed above and the transport
    # re-pinned; if the tunnel still will not carry traffic the remaining cause
    # is the router's internet uplink or the VPS/config.
    e2e_msg="$(sed -n '1p' "$e2e_curl_err" 2>/dev/null || true)"
    install_progress_fail \
      "Tunnel still not carrying traffic to ${e2e_target} (curl ${e2e_status:-no-response}${e2e_msg:+; ${e2e_msg}}) after self-healing the router path" \
      "The router runtime is up, so the cause is upstream: (1) the router's own internet uplink (check it reaches 1.1.1.1), or (2) the VPS / config. Open the web UI and run Diagnose & Repair — it probes and repairs the VPS with the managed key. Router logs: ssh $ROUTER_SSH 'logread -e codex-xray | tail'"
    e2e_ok=0
    ;;
  *)
    echo "  Reachability: ${e2e_target} responded HTTP ${e2e_status} via ${e2e_proxy}"
    e2e_ok=1
    ;;
esac
[ -f "$e2e_curl_err" ] && rm -f "$e2e_curl_err"

if [[ "${e2e_ok:-0}" == "1" ]]; then
  e2e_egress_ip="$(router_ssh "curl --proxy http://127.0.0.1:${PROXY_PORT} -ksS -m ${e2e_timeout} $(shell_quote "$e2e_ip_target") 2>/dev/null || true" 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$e2e_egress_ip" ]]; then
    echo "  Egress IP probe to ${e2e_ip_target} returned no data; chain identity not confirmed (proxy still answered ${e2e_target})."
  elif [[ "$e2e_egress_ip" == "${XRAY_SERVER:-}" ]]; then
    echo "✓ End-to-end OK: ${e2e_target} reachable and egress IP ${e2e_egress_ip} matches VPS ${XRAY_SERVER}"
  else
    install_progress_fail \
      "Egress IP ${e2e_egress_ip} does not match VPS ${XRAY_SERVER:-unknown}" \
      "Traffic answered the proxy but is not leaving through the VPS. Verify that xray-core's outbound is connecting to ${XRAY_SERVER}:${XRAY_PORT} and that the firewall allows it."
    e2e_ok=0
  fi
fi
if [[ "${e2e_ok:-0}" == "1" ]]; then
  # The probe above only proves the DIRECT HTTP proxy (:$PROXY_PORT) works.
  # LAN clients use the TRANSPARENT path (redsocks -> xray -> CODEX_TRANSPROXY
  # nat), which can be down while :$PROXY_PORT still answers. Verify it for
  # real so "complete" can never render 10/10 over a dead transparent path
  # (2026-07-10 incident: install reported 10/10 while redsocks was down and
  # every LAN client was blocked). redsocks-up + the nat rule are structural
  # and definitive, so this cannot false-fail on a transient egress blip.
  tp_state="$(router_ssh 'netstat -ltn 2>/dev/null | grep -q ":12345 " && echo rs=up || echo rs=DOWN; iptables -t nat -S PREROUTING 2>/dev/null | grep -q CODEX_TRANSPROXY && echo tp=up || echo tp=DOWN' 2>/dev/null | tr "\n" " " || true)"
  case "$tp_state" in
    *rs=up*tp=up*)
      echo "✓ Transparent path healthy: redsocks running and CODEX_TRANSPROXY active"
      ;;
    *)
      # Self-heal instead of failing hard (same as node 4.1 in Diagnose & Repair);
      # the tunnel egress above already proved the VPS path works.
      echo "  Transparent client path down (${tp_state}); self-healing..."
      router_ssh "/etc/init.d/codex-transproxy restart >/dev/null 2>&1 || true; [ -x /etc/gl-switch.d/xray.sh ] && /etc/gl-switch.d/xray.sh on >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
      if wait_for_transparent_path_ready; then
        echo "✓ Transparent path healed: redsocks running and CODEX_TRANSPROXY active"
      else
        install_progress_fail \
          "Transparent client path stayed down after self-heal (${tp_state}); LAN clients would be blocked." \
          "Recover: ssh $ROUTER_SSH '/etc/init.d/codex-transproxy restart'. Then run Live Smoke in the UI to confirm."
        e2e_ok=0
      fi
      ;;
  esac
fi
set -e
[[ "${e2e_ok:-0}" == "1" ]] || exit 1

install_progress_complete

echo "Deployed to $ROUTER_HOST"
echo "LAN proxy:  http://$ROUTER_LAN_IP:$PROXY_PORT"
echo "WAN proxy:  http://$ROUTER_HOST:$PROXY_PORT"
echo "Web UI:     https://$ROUTER_HOST/xray.html"
echo "Rules key:  ssh $ROUTER_SSH 'cat /etc/router-rules/ssh/routerRules_ed25519.pub'"

}
