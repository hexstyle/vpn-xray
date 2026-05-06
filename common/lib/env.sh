#!/usr/bin/env bash

load_env_file() {
  local env_file="$1"
  local example_hint="${2:-}"

  if [[ ! -f "$env_file" ]]; then
    echo "Missing env file: $env_file" >&2
    if [[ -n "$example_hint" ]]; then
      echo "Create it from: $example_hint" >&2
    fi
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

load_profile_defaults() {
  local profile_file="$1"

  [[ -f "$profile_file" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$profile_file"
  set +a
}

require_vars() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      echo "Missing required variable: $name" >&2
      exit 1
    fi
  done
}

# Persist `KEY=VALUE` into ENV_FILE: replace the line if present, append
# otherwise. Used by the interactive prompt below so a one-time answer
# survives subsequent installs.
persist_env_value() {
  local name="$1" value="$2" file="${ENV_FILE:-}"
  [[ -n "$file" ]] || return 0
  [[ -f "$file" ]] || return 0
  if grep -q "^${name}=" "$file" 2>/dev/null; then
    # Use a literal-safe replacement: build the new line via printf and
    # let awk swap by exact key match so values containing /, &, | are
    # preserved without sed quoting headaches.
    awk -v key="$name" -v val="$value" '
      BEGIN { OFS = "=" }
      $0 ~ "^"key"=" { print key, val; next }
      { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  else
    printf '%s=%s\n' "$name" "$value" >> "$file"
  fi
}

# ensure_input_var <name> <hint>
# When the variable is empty or still a placeholder:
#   - on a TTY: prompt the operator and persist the answer to ENV_FILE so
#     they only have to enter it once.
#   - off-TTY (CI, piped): fail loudly with the same hint so the missing
#     value is visible in build logs.
ensure_input_var() {
  local name="$1" hint="$2" current value
  current="${!name:-}"
  if [[ -n "$current" ]] && ! is_placeholder_value "$current"; then
    return 0
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "Missing required variable: $name (${hint})" >&2
    echo "Set it in $ENV_FILE or as an environment variable, then retry." >&2
    exit 1
  fi
  printf '%s\n' "Required: $name — ${hint}" >&2
  while true; do
    printf '  Enter %s: ' "$name" >&2
    read -r value || value=''
    if [[ -n "$value" ]] && ! is_placeholder_value "$value"; then
      break
    fi
    printf '  (value required and must not be a placeholder; try again)\n' >&2
  done
  printf -v "$name" '%s' "$value"
  export "$name"
  persist_env_value "$name" "$value"
}

is_placeholder_value() {
  local value="${1:-}"

  [[ -z "$value" ]] && return 0

  case "$value" in
    REPLACE_WITH*|CHANGE_ME*|CHANGEME*|YOUR_*|TODO*|"<"*">")
      return 0
      ;;
  esac

  [[ "$value" == *"example.invalid"* ]] && return 0

  if [[ "$value" =~ ^(192\.0\.2|198\.51\.100|203\.0\.113)(\.|/|$) ]]; then
    return 0
  fi

  return 1
}

reject_placeholder_vars() {
  local name value
  for name in "$@"; do
    value="${!name:-}"
    if is_placeholder_value "$value"; then
      echo "Variable $name still uses a placeholder value: $value" >&2
      exit 1
    fi
  done
}

derive_github_repo_slug() {
  local raw="${1:-}"

  case "$raw" in
    https://github.com/*)
      raw="${raw#https://github.com/}"
      ;;
    ssh://git@ssh.github.com:443/*)
      raw="${raw#ssh://git@ssh.github.com:443/}"
      ;;
    git@github.com:*)
      raw="${raw#git@github.com:}"
      ;;
    *)
      return 1
      ;;
  esac

  raw="${raw%.git}"
  if [[ "$raw" =~ ^[^/]+/[^/]+$ ]]; then
    printf '%s\n' "$raw"
    return 0
  fi

  return 1
}

default_install_env_file() {
  local root_dir="$1"
  printf '%s/install.env\n' "$root_dir"
}

default_install_env_example() {
  local root_dir="$1"
  printf '%s/install.env.example\n' "$root_dir"
}

host_from_ssh_target() {
  local target="${1:-}"

  target="${target#ssh://}"
  target="${target%%/*}"
  target="${target##*@}"

  if [[ "$target" =~ ^\[(.*)\]:[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$target" =~ ^\[(.*)\]$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  target="${target%%:*}"
  printf '%s\n' "$target"
}

router_profile_dir() {
  local root_dir="$1"
  local profile="${2:-gl-mt3000-glinet}"
  printf '%s\n' "$root_dir/routers/$profile"
}

router_common_dir() {
  local root_dir="$1"
  printf '%s\n' "$root_dir/routers/common"
}

vps_profile_dir() {
  local root_dir="$1"
  local profile="${2:-debian-13}"
  printf '%s\n' "$root_dir/vps/$profile"
}

require_supported_profile() {
  local kind="$1"
  local root_dir="$2"
  local profile="$3"
  local profile_dir

  case "$kind" in
    router)
      profile_dir="$(router_profile_dir "$root_dir" "$profile")"
      ;;
    vps)
      profile_dir="$(vps_profile_dir "$root_dir" "$profile")"
      ;;
    *)
      echo "Unknown profile kind: $kind" >&2
      exit 1
      ;;
  esac

  if [[ ! -f "$profile_dir/profile.env" ]]; then
    echo "Unsupported $kind profile: $profile" >&2
    exit 1
  fi
}

require_local_commands() {
  local missing=()
  local cmd

  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if ((${#missing[@]} > 0)); then
    echo "Missing required local commands: ${missing[*]}" >&2
    exit 1
  fi
}

installer_ssh_dir() {
  local root_dir="$1"
  printf '%s/tmp/ssh\n' "$root_dir"
}

installer_known_hosts_file() {
  local root_dir="$1"
  printf '%s/known_hosts\n' "$(installer_ssh_dir "$root_dir")"
}

ensure_installer_ssh_state() {
  local root_dir="$1"
  local dir
  local file

  dir="$(installer_ssh_dir "$root_dir")"
  file="$(installer_known_hosts_file "$root_dir")"
  mkdir -p "$dir"
  touch "$file"
  chmod 600 "$file"
}

remove_hostkey_entry() {
  local known_hosts_file="$1"
  local host="$2"

  [ -f "$known_hosts_file" ] || return 0
  command -v ssh-keygen >/dev/null 2>&1 || return 0
  ssh-keygen -R "$host" -f "$known_hosts_file" >/dev/null 2>&1 || true
}
