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

require_vars() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      echo "Missing required variable: $name" >&2
      exit 1
    fi
  done
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

default_router_env_file() {
  local root_dir="$1"

  if [[ -f "$root_dir/config/router.env" ]]; then
    printf '%s\n' "$root_dir/config/router.env"
  elif [[ -f "$root_dir/config/router-prod.env" ]]; then
    printf '%s\n' "$root_dir/config/router-prod.env"
  else
    printf '%s\n' "$root_dir/config/router.env"
  fi
}
