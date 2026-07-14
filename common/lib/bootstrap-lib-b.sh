#!/usr/bin/env bash
# bootstrap-lib-b.sh — bootstrap-router-vps.sh step/helper functions extracted per the
# AGENTS.md 500-line rule. Sourced by bootstrap-router-vps.sh right after
# common/lib/env.sh; defines functions only, runs no top-level code.

validate_vps_state_via_router() {
  local profile_id="$1"
  local expected_uuid="$2"
  local expected_public_key="$3"
  local expected_short_id="$4"
  local response=''
  local tries=10

  while (( tries > 0 )); do
    wait_for_router_direct_ssh >/dev/null 2>&1 || {
      tries=$((tries - 1))
      sleep 5
      continue
    }
    response="$(fetch_vps_state_via_router "$profile_id" 2>/dev/null || true)"
    if [[ -n "$response" ]] && printf '%s' "$response" | assert_vps_state_matches_expected "$expected_uuid" "$expected_public_key" "$expected_short_id" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 10
  done

  if [[ -z "$response" ]]; then
    fail "Router could not SSH into the selected VPS with the managed key after apply."
  fi
  printf '%s' "$response" | assert_vps_state_matches_expected "$expected_uuid" "$expected_public_key" "$expected_short_id"
}

refresh_profile_cache_best_effort() {
  local payload
  payload="$(urlencode_pairs "action=inspect_vps" "profile_id=$PROFILE_ID")"
  router_cgi_post_body_with_retry /www/cgi-bin/xray-vps "$payload" inspect_vps >/dev/null 2>&1 || true
}

set_router_rules_mode_checked() {
  local mode="$1"

  router_ssh_direct "$ROUTER_SSH" "/usr/bin/router-rules set-mode-cutover $(shell_quote "$mode") >/dev/null 2>&1" || return 1
  wait_for_proxy || return 1
  verify_router_proxy_path >/dev/null
}

cleanup() {
  if [[ "$control_opened" == "1" ]]; then
    router_ssh_raw -O exit "$ROUTER_SSH" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}

router_key_auth_works() {
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS" \
    "$ROUTER_SSH" 'echo ok' >/dev/null 2>&1
}

open_router_ssh_master() {
  if [[ -n "$ROUTER_PASSWORD" ]]; then
    SSH_ASKPASS="$router_askpass_script" \
      SSH_ASKPASS_REQUIRE=force \
      DISPLAY=1 \
      ssh "${ROUTER_SSH_COMMON_OPTS[@]}" -M -N -f "$ROUTER_SSH" < /dev/null
  else
    ssh "${ROUTER_SSH_COMMON_OPTS[@]}" -M -N -f "$ROUTER_SSH"
  fi
}

router_ssh_raw() {
  ssh "${ROUTER_SSH_COMMON_OPTS[@]}" "$@"
}

router_ssh_direct() {
  if [[ -n "$ROUTER_PASSWORD" ]]; then
    SSH_ASKPASS="$router_askpass_script" \
      SSH_ASKPASS_REQUIRE=force \
      DISPLAY=1 \
      ssh "${ROUTER_SSH_DIRECT_OPTS[@]}" "$@"
  else
    ssh "${ROUTER_SSH_DIRECT_OPTS[@]}" "$@"
  fi
}

wait_for_router_direct_ssh() {
  local tries=30

  while (( tries > 0 )); do
    if router_ssh_direct "$ROUTER_SSH" 'echo ok' >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 2
  done

  return 1
}

router_ssh() {
  router_ssh_raw "$ROUTER_SSH" "$@"
}

router_ssh_stdin() {
  local remote_cmd="$1"
  local stdin_path="$2"
  router_ssh "$remote_cmd" < "$stdin_path"
}

router_cgi_post() {
  local script_path="$1"
  local payload="$2"
  local payload_len

  payload_len="$(printf '%s' "$payload" | wc -c | tr -d '[:space:]')"
  # Run CGI POSTs outside the master socket. Multiplexed stdin/stdio handling
  # is unreliable here and can collapse a valid JSON response into an empty body.
  printf '%s' "$payload" | router_ssh_direct "$ROUTER_SSH" "REQUEST_METHOD=POST CONTENT_LENGTH=$payload_len $script_path"
}

router_cgi_post_body_with_retry() {
  local script_path="$1"
  local payload="$2"
  local description="$3"
  local tries=10
  local body=''

  while (( tries > 0 )); do
    body="$(router_cgi_post "$script_path" "$payload" 2>/dev/null | extract_http_body || true)"
    if [[ -n "$body" ]]; then
      printf '%s' "$body"
      return 0
    fi
    wait_for_router_direct_ssh >/dev/null 2>&1 || true
    tries=$((tries - 1))
    sleep 2
  done

  fail "Router returned an empty response for $description after waiting for direct SSH recovery."
}

router_rules_sync_summary() {
  local git_sync_enabled last_sync_status last_sync_message rules_relpath repo_head source_count
  local attempts=30

  while (( attempts > 0 )); do
    git_sync_enabled="$(router_ssh_direct "$ROUTER_SSH" "uci -q get router_rules.global.git_sync_enabled 2>/dev/null || true" | tr -d '\r\n')"
    last_sync_status="$(router_ssh_direct "$ROUTER_SSH" "sed -n 's/^last_sync_status=//p' /tmp/router-rules.status | sed -n '1p'" | tr -d '\r\n')"
    last_sync_message="$(router_ssh_direct "$ROUTER_SSH" "sed -n 's/^last_sync_message=//p' /tmp/router-rules.status | sed -n '1p'" | tr -d '\r\n')"

    if [[ "$last_sync_status" == 'ok' ]]; then
      rules_relpath="$(router_ssh_direct "$ROUTER_SSH" "uci -q get router_rules.global.rules_relpath 2>/dev/null || true" | tr -d '\r\n')"
      [ -n "$rules_relpath" ] || rules_relpath='lists/shared-targets.txt'
      repo_head="$(router_ssh_direct "$ROUTER_SSH" "git -C /etc/router-rules/repo rev-parse --short HEAD 2>/dev/null || true" | tr -d '\r\n')"
      source_count="$(router_ssh_direct "$ROUTER_SSH" "awk '/^[[:space:]]*$/ { next } /^[[:space:]]*#/ { next } { count++ } END { print count + 0 }' $(shell_quote "/etc/router-rules/repo/$rules_relpath") 2>/dev/null || echo 0" | tr -d '\r\n')"
      printf 'git_sync_enabled=%s\n' "$git_sync_enabled"
      printf 'last_sync_status=%s\n' "$last_sync_status"
      printf 'last_sync_message=%s\n' "$last_sync_message"
      printf 'repo_head=%s\n' "$repo_head"
      printf 'rules_relpath=%s\n' "$rules_relpath"
      printf 'source_count=%s\n' "$source_count"
      return 0
    fi

    attempts=$((attempts - 1))
    sleep 2
  done

  printf 'git_sync_enabled=%s\n' "$git_sync_enabled"
  printf 'last_sync_status=%s\n' "$last_sync_status"
  printf 'last_sync_message=%s\n' "$last_sync_message"
  printf 'repo_head=\n'
  printf 'rules_relpath=lists/shared-targets.txt\n'
  printf 'source_count=0\n'
  return 1
}

vps_ssh() {
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="$VPS_SSH_CONNECT_TIMEOUT" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS" \
    -p "$VPS_SSH_PORT" \
    "$VPS_SSH_USER@$VPS_SSH_HOST" "$@"
}

vps_ssh_with_password() {
  local cmd
  local askpass_script
  cmd="$1"

  [ -n "$VPS_PASSWORD" ] || return 1

  if command -v sshpass >/dev/null 2>&1; then
    SSHPASS="$VPS_PASSWORD" sshpass -e ssh \
      -o BatchMode=no \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      -o ConnectTimeout="$VPS_SSH_CONNECT_TIMEOUT" \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS" \
      -p "$VPS_SSH_PORT" \
      "$VPS_SSH_USER@$VPS_SSH_HOST" "$cmd"
    return $?
  fi

  askpass_script="$(mktemp "$tmpdir/vps-askpass.XXXXXX")"
  cat > "$askpass_script" <<EOF
#!/bin/sh
printf '%s\n' $(shell_quote "$VPS_PASSWORD")
EOF
  chmod 700 "$askpass_script"
  DISPLAY=1 SSH_ASKPASS="$askpass_script" SSH_ASKPASS_REQUIRE=force \
    ssh \
      -o BatchMode=no \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      -o ConnectTimeout="$VPS_SSH_CONNECT_TIMEOUT" \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$INSTALLER_KNOWN_HOSTS" \
      -p "$VPS_SSH_PORT" \
      "$VPS_SSH_USER@$VPS_SSH_HOST" "$cmd"
  local rc=$?
  rm -f "$askpass_script"
  return "$rc"
}

generate_router_bootstrap_keypair() {
  local remote_key='/tmp/.vpn-xray-bootstrap-rsa'
  local remote_pub='/tmp/.vpn-xray-bootstrap-rsa.pub'
  local pubkey

  if ! router_ssh "command -v dropbearkey >/dev/null 2>&1"; then
    return 1
  fi

  if ! router_ssh "rm -f '$remote_key' '$remote_pub' && \
    umask 077 && \
    dropbearkey -t rsa -s 2048 -f '$remote_key' >/dev/null 2>&1 && \
    dropbearkey -y -f '$remote_key' 2>/dev/null | \
      grep -o 'ssh-rsa .*' | \
      head -n1 > '$remote_pub' && \
    [ -s '$remote_key' ] && [ -s '$remote_pub' ]"; then
    router_ssh "rm -f '$remote_key' '$remote_pub'" >/dev/null 2>&1 || true
    return 1
  fi

  bootstrap_private_key="$(router_ssh "cat '$remote_key'")"
  pubkey="$(router_ssh "cat '$remote_pub'")"
  bootstrap_private_key="$(printf '%s' "$bootstrap_private_key" | tr -d '\r')"
  pubkey="$(printf '%s' "$pubkey" | tr -d '\r')"
  printf '%s' "$pubkey" | grep -q '^ssh-rsa ' || {
    router_ssh "rm -f '$remote_key' '$remote_pub'" >/dev/null 2>&1 || true
    return 1
  }

  router_ssh "rm -f '$remote_key' '$remote_pub'" >/dev/null 2>&1 || true
  printf '%s\n' "$pubkey"
}

local_vps_key_works() {
  vps_ssh 'echo ok' >/dev/null 2>&1
}

install_bootstrap_key_on_vps() {
  local pubkey

  rm -f "$bootstrap_key_path" "${bootstrap_key_path}.pub"
  ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -f "$bootstrap_key_path" >/dev/null
  pubkey="$(cat "${bootstrap_key_path}.pub")"
  bootstrap_private_key="$(cat "$bootstrap_key_path")"

  [ -n "$pubkey" ] || return 1
  printf '%s\n' "$pubkey" > "${bootstrap_key_path}.pub"
  chmod 644 "${bootstrap_key_path}.pub"

  if ! vps_ssh "sh -c 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; PUB=\$(cat); grep -qxF \"\$PUB\" ~/.ssh/authorized_keys || printf \"%s\n\" \"\$PUB\" >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'" < "${bootstrap_key_path}.pub" >/dev/null 2>&1; then
    if ! vps_ssh_with_password "sh -c 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; PUB=\$(cat); grep -qxF \"\$PUB\" ~/.ssh/authorized_keys || printf \"%s\n\" \"\$PUB\" >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'" < "${bootstrap_key_path}.pub" >/dev/null 2>&1; then
      return 1
    fi
  fi
  bootstrap_private_key="$(cat "$bootstrap_key_path")"
}

install_pubkey_on_vps() {
  local pubkey="$1"
  local tmp_pub="$tmpdir/router-managed-vps.pub"

  [ -n "$pubkey" ] || return 1
  printf '%s\n' "$pubkey" > "$tmp_pub"
  chmod 644 "$tmp_pub"

  if ! vps_ssh "sh -c 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; PUB=\$(cat); grep -qxF \"\$PUB\" ~/.ssh/authorized_keys || printf \"%s\n\" \"\$PUB\" >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'" < "$tmp_pub" >/dev/null 2>&1; then
    if ! vps_ssh_with_password "sh -c 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; PUB=\$(cat); grep -qxF \"\$PUB\" ~/.ssh/authorized_keys || printf \"%s\n\" \"\$PUB\" >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'" < "$tmp_pub" >/dev/null 2>&1; then
      rm -f "$tmp_pub"
      return 1
    fi
  fi

  rm -f "$tmp_pub"
}

router_bootstrap_key_works() {
  local remote_key='/tmp/.vpn-xray-bootstrap-rsa'
  local rc=1

  router_ssh_stdin "cat > '$remote_key'" "$bootstrap_key_path" || return 1
  router_ssh "chmod 600 '$remote_key'" >/dev/null 2>&1 || {
    router_ssh "rm -f '$remote_key'" >/dev/null 2>&1 || true
    return 1
  }

  # UserKnownHostsFile=/dev/null: throwaway connectivity probe, intentionally unverified.
  if router_ssh "ssh -i '$remote_key' -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p '$VPS_SSH_PORT' '$VPS_SSH_USER@$VPS_SSH_HOST' 'echo ok' >/dev/null 2>&1"; then
    rc=0
  fi

  router_ssh "rm -f '$remote_key'" >/dev/null 2>&1 || true
  return "$rc"
}
