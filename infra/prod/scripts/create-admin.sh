#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

load_prod_env
require_cmd docker

email="${1:-}"
role="${2:-SUPER_ADMIN}"

if [[ -z "$email" ]]; then
  read -r -p "Admin email: " email
fi
email="${email//[[:space:]]/}"
[[ -n "$email" ]] || fail "admin email is required"

role="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
case "$role" in
  SUPER_ADMIN|MODERATOR|SUPPORT_READ_ONLY) ;;
  *) fail "role must be SUPER_ADMIN, MODERATOR, or SUPPORT_READ_ONLY" ;;
esac

password=""
password_confirm=""
read -r -s -p "Admin password (minimum 14 characters): " password
printf '\n'
read -r -s -p "Confirm admin password: " password_confirm
printf '\n'

[[ "$password" == "$password_confirm" ]] || fail "password confirmation does not match"
(( ${#password} >= 14 )) || fail "admin password must contain at least 14 characters"

api_container="$(compose_with_storage ps --status running --quiet api | head -n 1)"
[[ -n "$api_container" ]] || fail "api service is not running; deploy DD before creating an administrator"

compose_with_storage exec -T \
  -e ADMIN_BOOTSTRAP_PASSWORD="$password" \
  api /app/adminctl create -email "$email" -role "$role"

unset password password_confirm
log "administrator created; open https://${DD_API_DOMAIN}/admin/ and complete TOTP enrollment on first login"
