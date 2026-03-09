#!/usr/bin/env bash

if [[ -n "${GMAIL_SECRETARY_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
readonly GMAIL_SECRETARY_COMMON_SH_LOADED=1

set -euo pipefail
umask 077

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$COMMON_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

if [[ "$(basename "$(dirname "$SKILL_DIR")")" == "skills" ]]; then
  DEFAULT_WORKSPACE="$(cd "$SKILL_DIR/../.." && pwd)"
else
  DEFAULT_WORKSPACE="$SKILL_DIR"
fi

WORKSPACE="${OPENCLAW_WORKSPACE:-$DEFAULT_WORKSPACE}"
CACHE_DIR="$WORKSPACE/cache"

function gs_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

function gs_dequote() {
  local value="$1"
  if [[ "$value" =~ ^\".*\"$ ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" =~ ^\'.*\'$ ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

function gs_load_env_file() {
  local envfile="$1"
  local line=""
  local key=""
  local raw=""
  local value=""
  local line_no=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    line="${line%$'\r'}"
    line="$(gs_trim "$line")"

    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    fi

    if [[ ! "$line" =~ ^([A-Z0-9_]+)[[:space:]]*=(.*)$ ]]; then
      echo "Invalid line in $envfile:$line_no. Use KEY=value format only." >&2
      return 1
    fi

    key="${BASH_REMATCH[1]}"
    raw="$(gs_trim "${BASH_REMATCH[2]}")"
    value="$(gs_dequote "$raw")"

    case "$key" in
      GOG_ACCOUNT|GOG_KEYRING_PASSWORD|GOG_BIN)
        printf -v "$key" '%s' "$value"
        export "$key"
        ;;
      *)
        echo "Unsupported key '$key' in $envfile:$line_no." >&2
        return 1
        ;;
    esac
  done < "$envfile"
}

function gs_load_config() {
  local envfile=""

  if [[ -n "${GOG_ACCOUNT:-}" && -n "${GOG_KEYRING_PASSWORD:-}" ]]; then
    return 0
  fi

  for envfile in \
    "$WORKSPACE/gmail-secretary.env" \
    "${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/gmail-secretary.env"; do
    if [[ -r "$envfile" ]]; then
      gs_load_env_file "$envfile" || return 1
      return 0
    fi
  done

  return 0
}

function gs_require_config() {
  gs_load_config
  GOG_BIN="${GOG_BIN:-gog}"
  export GOG_BIN
  export GOG_ACCOUNT="${GOG_ACCOUNT:?Set GOG_ACCOUNT in gmail-secretary.env or the environment.}"
  export GOG_KEYRING_PASSWORD="${GOG_KEYRING_PASSWORD:?Set GOG_KEYRING_PASSWORD in gmail-secretary.env or the environment.}"
}

function gs_prepare_cache_dir() {
  mkdir -p "$CACHE_DIR"
  chmod 700 "$CACHE_DIR"
}

function gs_secure_file() {
  local path="$1"
  if [[ -e "$path" ]]; then
    chmod 600 "$path"
  fi
}

function gs_resolve_env_path() {
  local envfile=""
  for envfile in \
    "$WORKSPACE/gmail-secretary.env" \
    "${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/gmail-secretary.env"; do
    if [[ -e "$envfile" ]]; then
      printf '%s' "$envfile"
      return 0
    fi
  done
  return 1
}
