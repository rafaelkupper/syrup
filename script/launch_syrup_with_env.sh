#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_path="$repo_root/.env"

read_env_value() {
  local key="$1"
  local line
  line="$(grep -E "^${key}=" "$env_path" | tail -n 1 || true)"
  if [ -z "$line" ]; then
    return 1
  fi

  local value="${line#*=}"
  value="${value%$'\r'}"
  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac
  printf '%s' "$value"
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

if [ ! -f "$env_path" ]; then
  printf '.env not found at %s\n' "$env_path" >&2
  exit 1
fi

base_url="$(trim_value "$(read_env_value OPENAI_COMPATIBLE_URL || true)")"
api_key="$(trim_value "$(read_env_value OPENAI_COMPATIBLE_API_KEY || true)")"
model="$(trim_value "$(read_env_value OPENAI_COMPATIBLE_MODEL || true)")"

if [ -z "$base_url" ] || [ -z "$api_key" ] || [ -z "$model" ]; then
  printf 'OPENAI_COMPATIBLE_URL, OPENAI_COMPATIBLE_API_KEY, and OPENAI_COMPATIBLE_MODEL are required.\n' >&2
  exit 1
fi

app_candidates="$(
  while IFS= read -r -d '' candidate; do
    stat -f '%m %N' "$candidate"
  done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Debug/Syrup.app' -type d -print0)
)"
app_path="$(printf '%s\n' "$app_candidates" | sort -nr | head -n 1 | cut -d ' ' -f 2-)"
if [ -z "$app_path" ]; then
  printf 'Syrup.app not found in DerivedData. Build the Debug scheme first.\n' >&2
  exit 1
fi

pkill -x Syrup 2>/dev/null || true
for _ in {1..20}; do
  if ! pgrep -x Syrup >/dev/null; then
    break
  fi
  sleep 0.25
done

if pgrep -x Syrup >/dev/null; then
  printf 'Existing Syrup process did not exit after termination request.\n' >&2
  exit 1
fi

cleanup_launch_env() {
  launchctl unsetenv OPENAI_COMPATIBLE_URL 2>/dev/null || true
  launchctl unsetenv OPENAI_COMPATIBLE_API_KEY 2>/dev/null || true
  launchctl unsetenv OPENAI_COMPATIBLE_MODEL 2>/dev/null || true
}

trap cleanup_launch_env EXIT
trap 'cleanup_launch_env; exit 130' INT
trap 'cleanup_launch_env; exit 143' TERM
launchctl setenv OPENAI_COMPATIBLE_URL "$base_url"
launchctl setenv OPENAI_COMPATIBLE_API_KEY "$api_key"
launchctl setenv OPENAI_COMPATIBLE_MODEL "$model"
open -n "$app_path"
sleep 2

pid="$(pgrep -x Syrup || true)"
if [ -z "$pid" ]; then
  printf 'Syrup did not stay running after launch.\n' >&2
  exit 1
fi

printf 'Launched Syrup with .env endpoint settings as pid %s\n' "$pid"
