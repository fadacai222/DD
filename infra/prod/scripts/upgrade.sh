#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

load_prod_env

from_tag="${DD_IMAGE_TAG:-}"
to_tag=""
to_version=""
image_mode="build"
restore_on_failure=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to-tag)
      [[ $# -ge 2 ]] || fail "--to-tag requires a value"
      to_tag="$2"; shift 2 ;;
    --to-version)
      [[ $# -ge 2 ]] || fail "--to-version requires a value"
      to_version="$2"; shift 2 ;;
    --build)
      image_mode="build"; shift ;;
    --pull)
      image_mode="pull"; shift ;;
    --restore-on-failure)
      restore_on_failure=true; shift ;;
    *) fail "usage: upgrade.sh --to-tag <tag> --to-version <version> [--build|--pull] [--restore-on-failure]" ;;
  esac
done

[[ -n "$from_tag" ]] || fail "DD_IMAGE_TAG must identify the currently deployed release"
[[ -n "$to_tag" && -n "$to_version" ]] || fail "--to-tag and --to-version are required"
[[ "$to_tag" != "$from_tag" ]] || fail "target tag equals current tag; nothing to upgrade"
[[ "$from_tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail "current DD_IMAGE_TAG is not a safe Docker tag"
[[ "$to_tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail "target tag is not a safe Docker tag"
[[ "$to_version" =~ ^[A-Za-z0-9][A-Za-z0-9_.+-]{0,127}$ ]] || fail "target version contains unsupported characters"

"$SCRIPT_DIR/preflight.sh"
service_is_running api || fail "upgrade requires a running production API; use deploy.sh for first install"
service_is_running worker || fail "upgrade requires a running production Worker"

api_repo="${DD_IMAGE_REPOSITORY:-local/dd-api}"
worker_repo="${DD_WORKER_IMAGE_REPOSITORY:-local/dd-worker}"
migrate_repo="${DD_MIGRATE_IMAGE_REPOSITORY:-local/dd-migrate}"
for image in "$api_repo:$from_tag" "$worker_repo:$from_tag" "$migrate_repo:$from_tag"; do
  docker image inspect "$image" >/dev/null 2>&1 || fail "previous release image is missing locally: $image (rollback would be impossible)"
done

compose_for_tag() {
  local tag="$1" version="$2"
  shift 2
  if [[ "${DD_OBJECT_STORAGE_MODE:-minio}" == "minio" ]]; then
    DD_IMAGE_TAG="$tag" DD_RELEASE_VERSION="$version" run_compose --profile selfhost-storage "$@"
  else
    DD_IMAGE_TAG="$tag" DD_RELEASE_VERSION="$version" run_compose "$@"
  fi
}

if [[ "$image_mode" == "build" ]]; then
  require_cmd git
  git -C "$REPO_ROOT" diff --quiet || fail "refusing release build from a dirty working tree"
  git -C "$REPO_ROOT" diff --cached --quiet || fail "refusing release build with staged-but-uncommitted changes"
  log "building target release images: $to_tag"
  compose_for_tag "$to_tag" "$to_version" build api worker migrate
else
  log "pulling target release images: $to_tag"
  compose_for_tag "$to_tag" "$to_version" pull api worker migrate
fi

for image in "$api_repo:$to_tag" "$worker_repo:$to_tag" "$migrate_repo:$to_tag"; do
  docker image inspect "$image" >/dev/null 2>&1 || fail "target release image unavailable after $image_mode: $image"
done

state_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
state_dir="$(upgrade_state_root)/${state_stamp}-$(safe_name "$from_tag")-to-$(safe_name "$to_tag")"
mkdir -p "$state_dir"

log "pre-migration compatibility gate: N+1 migrate binary must accept the current N database"
compose_for_tag "$to_tag" "$to_version" run --rm migrate status | tee "$state_dir/target-pre-migration-status.txt" >/dev/null
from_schema="$(awk '$NF == "applied" {v=$1} END {print v}' "$state_dir/target-pre-migration-status.txt")"
[[ -n "$from_schema" ]] || from_schema="000000"

target_pre_status="PASS"
target_post_status="NOT_RUN"
to_schema="NOT_RUN"
old_after_state="NOT_RUN"
rollback_mode="NOT_NEEDED"
backup_path=""
upgrade_success=false

write_evidence() {
  local result="$1"
  {
    printf 'EVIDENCE_FORMAT=%q\n' "1"
    printf 'CREATED_AT_UTC=%q\n' "$state_stamp"
    printf 'FROM_TAG=%q\n' "$from_tag"
    printf 'TO_TAG=%q\n' "$to_tag"
    printf 'TO_VERSION=%q\n' "$to_version"
    printf 'FROM_SCHEMA=%q\n' "$from_schema"
    printf 'TO_SCHEMA=%q\n' "$to_schema"
    printf 'TARGET_PRE_MIGRATION_STATUS=%q\n' "$target_pre_status"
    printf 'TARGET_POST_MIGRATION_STATUS=%q\n' "$target_post_status"
    printf 'OLD_RELEASE_STATUS_AFTER_NEW_SCHEMA=%q\n' "$old_after_state"
    printf 'PRE_UPGRADE_BACKUP=%q\n' "$backup_path"
    printf 'ROLLBACK_MODE=%q\n' "$rollback_mode"
    printf 'DATABASE_DOWN_EXECUTED=%q\n' "false"
    printf 'RESULT=%q\n' "$result"
  } > "$state_dir/evidence.env"
  cat > "$state_dir/compatibility-row.json" <<EOF
{
  "formatVersion": 1,
  "fromTag": "$from_tag",
  "toTag": "$to_tag",
  "toVersion": "$to_version",
  "fromSchema": "$from_schema",
  "toSchema": "$to_schema",
  "targetPreMigrationStatus": "$target_pre_status",
  "targetPostMigrationStatus": "$target_post_status",
  "previousReleaseAgainstNewSchema": "$old_after_state",
  "rollbackMode": "$rollback_mode",
  "databaseDownExecuted": false,
  "result": "$result"
}
EOF
}

handle_upgrade_failure() {
  local exit_code=$?
  if [[ "$upgrade_success" == "true" ]]; then
    exit "$exit_code"
  fi
  set +e
  if [[ -n "$backup_path" ]]; then
    log "upgrade failed after quiesce; stopping target writers before rollback decision"
    compose_for_tag "$to_tag" "$to_version" stop -t 45 api worker >/dev/null 2>&1

    old_status_output="$(compose_for_tag "$from_tag" "${DD_RELEASE_VERSION:-unknown}" run --rm migrate status 2>&1)"
    old_status_code=$?
    printf '%s\n' "$old_status_output" > "$state_dir/old-release-post-failure-status.txt"
    if [[ "$old_status_code" -eq 0 ]]; then
      old_after_state="COMPATIBLE"
      rollback_mode="APPLICATION_ONLY"
      log "previous release accepts the current schema; restarting previous API/Worker without database downgrade"
      compose_for_tag "$from_tag" "${DD_RELEASE_VERSION:-unknown}" up -d --no-deps api worker >/dev/null
      rollback_up_code=$?
      rollback_api_code=1
      rollback_worker_code=1
      if [[ "$rollback_up_code" -eq 0 ]]; then
        wait_service_healthy api 180
        rollback_api_code=$?
        wait_service_healthy worker 120
        rollback_worker_code=$?
      fi
      if [[ "$rollback_up_code" -eq 0 && "$rollback_api_code" -eq 0 && "$rollback_worker_code" -eq 0 ]]; then
        write_evidence "FAILED_ROLLED_BACK_APPLICATION"
      else
        rollback_mode="APPLICATION_ONLY_ROLLBACK_UNHEALTHY"
        compose_with_storage stop -t 45 api worker livekit caddy tls-mux >/dev/null 2>&1
        write_evidence "FAILED_ROLLBACK_APPLICATION_UNHEALTHY_SERVICES_STOPPED"
      fi
    elif [[ "$restore_on_failure" == "true" ]]; then
      old_after_state="INCOMPATIBLE"
      rollback_mode="RESTORE_PREUPGRADE_BACKUP"
      if load_backup_manifest "$backup_path/manifest.env"; then
        log "previous release rejects the newer schema; restoring verified pre-upgrade recovery point (no migrate down)"
        "$SCRIPT_DIR/restore.sh" --backup "$backup_path" --confirm "RESTORE:${DD_API_DOMAIN}:${BACKUP_ID}" --failed-upgrade-recovery
        restore_code=$?
        if [[ "$restore_code" -eq 0 ]]; then
          write_evidence "FAILED_RESTORED_PREUPGRADE_BACKUP"
        else
          compose_with_storage stop -t 45 api worker livekit caddy tls-mux >/dev/null 2>&1
          write_evidence "FAILED_RESTORE_FAILED_SERVICES_STOPPED"
        fi
      else
        rollback_mode="BLOCKED_INVALID_BACKUP_MANIFEST"
        compose_with_storage stop -t 45 api worker livekit caddy tls-mux >/dev/null 2>&1
        write_evidence "FAILED_INVALID_BACKUP_MANIFEST_SERVICES_STOPPED"
        log "pre-upgrade backup manifest failed strict parsing; automatic restore is blocked"
      fi
    else
      old_after_state="INCOMPATIBLE"
      rollback_mode="BLOCKED_REQUIRES_BACKUP_RESTORE"
      compose_with_storage stop -t 45 api worker livekit caddy tls-mux >/dev/null 2>&1
      write_evidence "FAILED_SERVICES_STOPPED"
      log "previous release rejects the newer schema; old app is intentionally NOT restarted"
      if load_backup_manifest "$backup_path/manifest.env"; then
        log "recovery command: $SCRIPT_DIR/restore.sh --backup '$backup_path' --confirm 'RESTORE:${DD_API_DOMAIN}:${BACKUP_ID}' --failed-upgrade-recovery"
      else
        rollback_mode="BLOCKED_INVALID_BACKUP_MANIFEST"
        write_evidence "FAILED_INVALID_BACKUP_MANIFEST_SERVICES_STOPPED"
        log "pre-upgrade backup manifest failed strict parsing; no restore command will be emitted"
      fi
    fi
  else
    write_evidence "FAILED_BEFORE_QUIESCE"
    log "upgrade failed before the pre-upgrade recovery point/quiesce; existing application was not intentionally stopped"
  fi
  log "upgrade evidence: $state_dir/evidence.env"
  exit "$exit_code"
}
trap handle_upgrade_failure EXIT

log "creating mandatory verified pre-upgrade recovery point"
backup_output="$($SCRIPT_DIR/backup.sh --quiesce --leave-stopped)"
printf '%s\n' "$backup_output"
backup_path="$(printf '%s\n' "$backup_output" | awk -F= '/^BACKUP_PATH=/{print substr($0, index($0,"=")+1)}' | tail -1)"
[[ -n "$backup_path" && -d "$backup_path" ]] || fail "pre-upgrade backup path was not captured"

log "applying N→N+1 forward-only migrations"
compose_for_tag "$to_tag" "$to_version" run --rm migrate up
compose_for_tag "$to_tag" "$to_version" run --rm migrate status | tee "$state_dir/target-post-migration-status.txt" >/dev/null
to_schema="$(awk '$NF == "applied" {v=$1} END {print v}' "$state_dir/target-post-migration-status.txt")"
[[ -n "$to_schema" ]] || to_schema="000000"
target_post_status="PASS"

log "machine compatibility gate: can previous release understand the newer schema?"
set +e
old_after_output="$(compose_for_tag "$from_tag" "${DD_RELEASE_VERSION:-unknown}" run --rm migrate status 2>&1)"
old_after_code=$?
set -e
printf '%s\n' "$old_after_output" > "$state_dir/old-release-after-new-schema-status.txt"
if [[ "$old_after_code" -eq 0 ]]; then
  old_after_state="COMPATIBLE"
else
  old_after_state="INCOMPATIBLE"
fi

log "starting target API/Worker while retaining the previous images for rollback"
compose_for_tag "$to_tag" "$to_version" up -d --no-deps api worker
wait_service_healthy api 180
wait_service_healthy worker 120
"$SCRIPT_DIR/deployment-check.sh"

write_env_key DD_IMAGE_TAG "$to_tag"
write_env_key DD_RELEASE_VERSION "$to_version"
rollback_mode="APPLICATION_ONLY_IF_GATE_COMPATIBLE_OTHERWISE_RESTORE_BACKUP"
write_evidence "SUCCESS"
upgrade_success=true

log "upgrade PASS: $from_tag -> $to_tag ($to_version)"
log "previous-release schema compatibility after upgrade: $old_after_state"
log "verified pre-upgrade recovery point: $backup_path"
log "upgrade evidence: $state_dir/evidence.env"
log "database down migrations were not executed"
