#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

load_prod_env
require_cmd openssl
umask 077
mkdir -p "$PROD_DIR/secrets"

random_hex() {
  openssl rand -hex "${1:-32}"
}

write_secret_once() {
  local name="$1"
  local value="$2"
  local path
  path="$(secret_path "$name")"
  if [[ -s "$path" ]]; then
    log "keep existing secret: $name"
    return 0
  fi
  printf '%s\n' "$value" > "$path"
  chmod 600 "$path"
  log "generated secret: $name"
}

ensure_optional_file() {
  local path
  path="$(secret_path "$1")"
  if [[ ! -e "$path" ]]; then
    : > "$path"
  fi
  chmod 600 "$path"
}

postgres_password="$(random_hex 32)"
if [[ -s "$(secret_path postgres_password)" ]]; then
  postgres_password="$(read_secret postgres_password)"
else
  write_secret_once postgres_password "$postgres_password"
fi
write_secret_once database_url "postgres://${DD_POSTGRES_USER:-dd}:${postgres_password}@postgres:5432/${DD_POSTGRES_DB:-dd}?sslmode=disable"

redis_password="$(random_hex 32)"
if [[ -s "$(secret_path redis_password)" ]]; then
  redis_password="$(read_secret redis_password)"
else
  write_secret_once redis_password "$redis_password"
fi
write_secret_once redis_url "redis://:${redis_password}@redis:6379/0"

write_secret_once minio_root_password "$(random_hex 32)"
if [[ "${DD_OBJECT_STORAGE_MODE:-minio}" == "minio" ]]; then
  write_secret_once media_s3_access_key "ddapp$(random_hex 8)"
  write_secret_once media_s3_secret_key "$(random_hex 32)"
  write_secret_once backup_s3_access_key "ddbackup$(random_hex 8)"
  write_secret_once backup_s3_secret_key "$(random_hex 32)"
else
  ensure_optional_file media_s3_access_key
  ensure_optional_file media_s3_secret_key
  ensure_optional_file backup_s3_access_key
  ensure_optional_file backup_s3_secret_key
  log "external S3 selected: fill media_s3_* and backup_s3_* with real least-privilege credentials"
fi

write_secret_once livekit_api_key "dd_$(random_hex 12)"
write_secret_once livekit_api_secret "$(random_hex 32)"
write_secret_once auth_token_secret "$(random_hex 48)"
write_secret_once email_code_pepper "$(random_hex 48)"

for optional in smtp_password telegram_bot_token fcm_service_account_json apns_private_key; do
  ensure_optional_file "$optional"
done

for supplied in turn_cert.pem turn_key.pem; do
  if [[ ! -s "$PROD_DIR/secrets/$supplied" ]]; then
    log "HUMAN-REQUIRED: install trusted $supplied for DD_TURN_DOMAIN; no self-signed production fallback is generated"
  fi
done

log "secret initialization complete; no existing non-empty secret was overwritten"
