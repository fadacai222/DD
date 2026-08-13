#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

load_prod_env

backup_dir=""
confirmation=""
disaster_empty_target=false
failed_upgrade_recovery=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)
      [[ $# -ge 2 ]] || fail "--backup requires a path"
      backup_dir="$2"
      shift 2
      ;;
    --confirm)
      [[ $# -ge 2 ]] || fail "--confirm requires a value"
      confirmation="$2"
      shift 2
      ;;
    --disaster-empty-target)
      disaster_empty_target=true
      shift
      ;;
    --failed-upgrade-recovery)
      failed_upgrade_recovery=true
      shift
      ;;
    *) fail "usage: restore.sh --backup <dir> --confirm RESTORE:<domain>:<backup-id> [--disaster-empty-target|--failed-upgrade-recovery]" ;;
  esac
done

[[ -n "$backup_dir" ]] || fail "--backup is required"
"$SCRIPT_DIR/verify-backup.sh" "$backup_dir"
backup_dir="$(cd "$backup_dir" && pwd -P)"
load_backup_manifest "$backup_dir/manifest.env" || fail "backup manifest validation failed"

expected="RESTORE:${DD_API_DOMAIN}:${BACKUP_ID}"
[[ "$confirmation" == "$expected" ]] || fail "destructive restore blocked; rerun with --confirm '$expected'"
[[ "${MEDIA_BUCKET:-}" == "${DD_MEDIA_S3_BUCKET:-dd-media}" ]] || fail "backup bucket '$MEDIA_BUCKET' does not match configured target bucket '${DD_MEDIA_S3_BUCKET:-dd-media}'"

root="$(backup_root)"
root="$(cd "$root" && pwd -P)"
case "$backup_dir/" in
  "$root"/*) ;;
  *) fail "backup must be inside configured DD_BACKUP_ROOT so the restore tool can mount it safely" ;;
esac

[[ "$disaster_empty_target" != "true" || "$failed_upgrade_recovery" != "true" ]] || fail "choose only one restore safety-bypass mode"
safety_backup=""
if [[ "$disaster_empty_target" != "true" && "$failed_upgrade_recovery" != "true" ]]; then
  log "creating a verified pre-restore safety backup and leaving application writers stopped"
  safety_output="$($SCRIPT_DIR/backup.sh --quiesce --leave-stopped)"
  printf '%s\n' "$safety_output"
  safety_backup="$(printf '%s\n' "$safety_output" | awk -F= '/^BACKUP_PATH=/{print substr($0, index($0,"=")+1)}' | tail -1)"
  [[ -n "$safety_backup" ]] || fail "failed to capture pre-restore safety backup path"
elif [[ "$failed_upgrade_recovery" == "true" ]]; then
  log "FAILED-UPGRADE RECOVERY: skipping a second safety backup because the selected recovery point is the verified pre-upgrade backup and the newer schema may be unreadable by the old release"
  compose_with_storage stop -t 45 api worker livekit caddy tls-mux >/dev/null 2>&1 || true
else
  log "DISASTER MODE: pre-restore safety backup intentionally skipped because target is declared empty/rebuildable"
  compose_with_storage stop -t 45 api worker livekit caddy tls-mux >/dev/null 2>&1 || true
fi

restore_failed=true
restore_failure_notice() {
  local exit_code=$?
  if [[ "$restore_failed" == "true" ]]; then
    log "RESTORE FAILED: application ingress/writers remain stopped; database was not auto-downgraded"
    if [[ -n "$safety_backup" ]]; then
      log "pre-restore safety backup: $safety_backup"
    fi
  fi
  exit "$exit_code"
}
trap restore_failure_notice EXIT

compose_with_storage up -d postgres redis
wait_service_healthy postgres 120
wait_service_healthy redis 120
if [[ "${DD_OBJECT_STORAGE_MODE:-minio}" == "minio" ]]; then
  compose_with_storage up -d minio
  wait_service_healthy minio 120
  compose_with_storage run --rm --no-deps minio-init
fi

log "dropping and recreating target PostgreSQL database (confirmation gate passed)"
compose exec -T postgres /bin/sh -ec '
  export PGPASSWORD="$(cat /run/secrets/postgres_password)"
  dropdb --if-exists --force -U "$POSTGRES_USER" "$POSTGRES_DB"
  createdb -U "$POSTGRES_USER" "$POSTGRES_DB"
'

log "restoring PostgreSQL custom dump"
cat "$backup_dir/postgres.dump" | compose exec -T postgres /bin/sh -ec '
  export PGPASSWORD="$(cat /run/secrets/postgres_password)"
  exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-acl --exit-on-error
'

log "restoring object storage and removing objects not present in the selected recovery point"
compose_tools run --rm --no-deps \
  -e BACKUP_ID="$BACKUP_ID" \
  --entrypoint /bin/sh object-backup-tool -ec '
    ACCESS_KEY="$(cat /run/secrets/backup_s3_access_key)"
    SECRET_KEY="$(cat /run/secrets/backup_s3_secret_key)"
    mc alias set target "$BACKUP_S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY" >/dev/null
    mc mirror --overwrite --remove "/backups/$BACKUP_ID/objects" "target/$MEDIA_BUCKET"
  '

log "validating restored schema against current release and applying only forward migrations if the backup is older"
compose_with_storage run --rm migrate status
compose_with_storage run --rm migrate up
compose_with_storage run --rm migrate status

log "starting production services after successful restore"
compose_with_storage up -d livekit
wait_service_healthy livekit 120
compose_with_storage up -d api worker
wait_service_healthy api 180
wait_service_healthy worker 120
if ! is_bt_ingress; then
  compose_with_storage up -d caddy tls-mux
  wait_service_healthy tls-mux 120
fi
"$SCRIPT_DIR/deployment-check.sh"

restore_failed=false
log "restore PASS: $BACKUP_ID"
log "database rollback was never executed; this restore replaced state from a verified backup and then ran forward-only migrations"
