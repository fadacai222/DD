#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

load_prod_env
require_cmd docker
require_cmd sha256sum

quiesce=false
leave_stopped=false
for arg in "$@"; do
  case "$arg" in
    --quiesce) quiesce=true ;;
    --leave-stopped) leave_stopped=true ;;
    *) fail "usage: backup.sh [--quiesce] [--leave-stopped]" ;;
  esac
done
[[ "$leave_stopped" == "false" || "$quiesce" == "true" ]] || fail "--leave-stopped requires --quiesce"

root="$(backup_root)"
[[ "$root" != "/" && "$root" != "$PROD_DIR" && ${#root} -gt 8 ]] || fail "unsafe DD_BACKUP_ROOT: $root"
mkdir -p "$root"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
tag="$(safe_name "${DD_IMAGE_TAG:-unknown}")"
backup_id="${timestamp}-${tag}"
backup_dir="$root/$backup_id"
mkdir -p "$backup_dir/objects"
cp "$ENV_FILE" "$backup_dir/config.env"
chmod 600 "$backup_dir/config.env" 2>/dev/null || true

api_was_running=false
worker_was_running=false
backup_succeeded=false
if service_is_running api; then api_was_running=true; fi
if service_is_running worker; then worker_was_running=true; fi

restore_quiesced_services() {
  local exit_code=$?
  if [[ "$quiesce" == "true" && ( "$backup_succeeded" != "true" || "$leave_stopped" != "true" ) ]]; then
    if [[ "$api_was_running" == "true" ]]; then
      compose_with_storage up -d --no-deps api >/dev/null || true
    fi
    if [[ "$worker_was_running" == "true" ]]; then
      compose_with_storage up -d --no-deps worker >/dev/null || true
    fi
  fi
  exit "$exit_code"
}
trap restore_quiesced_services EXIT

service_is_running postgres || fail "postgres must be running before backup"
wait_service_healthy postgres 30

if [[ "$quiesce" == "true" ]]; then
  log "quiescing API/Worker for a cross-system DR recovery point"
  compose_with_storage stop -t 45 api worker >/dev/null
else
  log "ONLINE SUPPLEMENTARY COPY: writers remain active; this run does not establish a strict cross-DB/Object RPO"
fi

log "dumping PostgreSQL to $backup_id"
compose exec -T postgres /bin/sh -ec '
  export PGPASSWORD="$(cat /run/secrets/postgres_password)"
  exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --compress=6 --no-owner --no-acl
' > "$backup_dir/postgres.dump"
[[ -s "$backup_dir/postgres.dump" ]] || fail "PostgreSQL dump is empty"

log "capturing migration compatibility state"
compose_with_storage run --rm migrate status > "$backup_dir/schema-status.txt"
schema_max="$(awk '$NF == "applied" {v=$1} END {print v}' "$backup_dir/schema-status.txt")"
[[ -n "$schema_max" ]] || schema_max="000000"

log "mirroring current object-storage state"
BACKUP_ID="$backup_id" compose_tools run --rm --no-deps \
  -e BACKUP_ID="$backup_id" \
  --entrypoint /bin/sh object-backup-tool -ec '
    ACCESS_KEY="$(cat /run/secrets/backup_s3_access_key)"
    SECRET_KEY="$(cat /run/secrets/backup_s3_secret_key)"
    mc alias set source "$BACKUP_S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY" >/dev/null
    mkdir -p "/backups/$BACKUP_ID/objects"
    mc mirror --overwrite --preserve "source/$MEDIA_BUCKET" "/backups/$BACKUP_ID/objects"
    mc ls --recursive --json "source/$MEDIA_BUCKET" > "/backups/$BACKUP_ID/object-source-list.jsonl"
  '
[[ -f "$backup_dir/object-source-list.jsonl" ]] || fail "object storage source listing was not created"

object_count="$(find "$backup_dir/objects" -type f | wc -l | tr -d ' ')"
consistency_mode="online-db-first"
if [[ "$quiesce" == "true" ]]; then consistency_mode="quiesced"; fi

{
  printf 'BACKUP_FORMAT_VERSION=%s\n' "1"
  printf 'BACKUP_ID=%s\n' "$backup_id"
  printf 'CREATED_AT_UTC=%s\n' "$timestamp"
  printf 'RELEASE_VERSION=%s\n' "${DD_RELEASE_VERSION:-unknown}"
  printf 'IMAGE_TAG=%s\n' "${DD_IMAGE_TAG:-unknown}"
  printf 'DB_NAME=%s\n' "${DD_POSTGRES_DB:-dd}"
  printf 'MEDIA_BUCKET=%s\n' "${DD_MEDIA_S3_BUCKET:-dd-media}"
  printf 'OBJECT_STORAGE_MODE=%s\n' "${DD_OBJECT_STORAGE_MODE:-minio}"
  printf 'OBJECT_FILE_COUNT=%s\n' "$object_count"
  printf 'SCHEMA_MIGRATION_MAX=%s\n' "$schema_max"
  printf 'CONSISTENCY_MODE=%s\n' "$consistency_mode"
  printf 'RPO_HOURS=%s\n' "${DD_RPO_HOURS:-6}"
  printf 'RTO_HOURS=%s\n' "${DD_RTO_HOURS:-4}"
} > "$backup_dir/manifest.env"

(
  cd "$backup_dir"
  find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | while IFS= read -r file; do
    sha256sum "$file"
  done > SHA256SUMS
)

"$SCRIPT_DIR/verify-backup.sh" "$backup_dir"

retention_days="${DD_BACKUP_RETENTION_DAYS:-14}"
log "applying verified-backup retention: ${retention_days} day(s)"
while IFS= read -r old_dir; do
  [[ "$old_dir" != "$backup_dir" ]] || continue
  base="$(basename "$old_dir")"
  [[ "$base" =~ ^20[0-9]{6}T[0-9]{6}Z- ]] || continue
  rm -rf -- "$old_dir"
  log "expired backup removed: $base"
done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -mtime "+$retention_days" -print)

backup_succeeded=true
log "backup PASS"
printf 'BACKUP_PATH=%s\n' "$backup_dir"
