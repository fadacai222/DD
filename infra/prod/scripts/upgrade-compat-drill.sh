#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

from_ref=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-ref)
      [[ $# -ge 2 ]] || fail "--from-ref requires a Git ref"
      from_ref="$2"
      shift 2
      ;;
    *) fail "usage: upgrade-compat-drill.sh --from-ref <git-ref>" ;;
  esac
done
[[ -n "$from_ref" ]] || fail "--from-ref is required"

require_cmd docker
require_cmd git
require_cmd openssl
git -C "$REPO_ROOT" rev-parse --verify "${from_ref}^{commit}" >/dev/null 2>&1 || fail "unknown Git ref: $from_ref"
git_repo_path="$(docker_host_path "$REPO_ROOT")"
export MSYS_NO_PATHCONV=1

suffix="$(date -u +%Y%m%d%H%M%S)-$$"
network="dd-upgrade-drill-net-$suffix"
pg="dd-upgrade-drill-pg-$suffix"
pg_volume="dd-upgrade-drill-pg-$suffix"
pg_restore_volume="dd-upgrade-drill-pg-restore-$suffix"
backup_volume="dd-upgrade-drill-backup-$suffix"
old_code_volume="dd-upgrade-drill-old-code-$suffix"
new_code_volume="dd-upgrade-drill-new-code-$suffix"
bin_volume="dd-upgrade-drill-bin-$suffix"
pg_password="drill$(openssl rand -hex 16)"

cleanup() {
  docker rm -f "$pg" >/dev/null 2>&1 || true
  docker volume rm -f "$pg_volume" "$pg_restore_volume" "$backup_volume" "$old_code_volume" "$new_code_volume" "$bin_volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_postgres() {
  for _ in $(seq 1 60); do
    if docker exec "$pg" pg_isready -U dd -d dd >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  fail "temporary PostgreSQL did not become ready"
}

run_migrate() {
  local binary="$1"
  local action="$2"
  docker run --rm --network "$network" -v "$bin_volume:/binx:ro" \
    -e DATABASE_URL="postgres://dd:${pg_password}@${pg}:5432/dd?sslmode=disable" \
    alpine:3.22.1 "/binx/$binary" "$action"
}

docker network create "$network" >/dev/null
for volume in "$pg_volume" "$pg_restore_volume" "$backup_volume" "$old_code_volume" "$new_code_volume" "$bin_volume"; do
  docker volume create "$volume" >/dev/null
done

log "UPGRADE DRILL: exporting old=$from_ref and new=HEAD source trees into isolated volumes"
git -C "$git_repo_path" archive "$from_ref" server | docker run --rm -i -v "$old_code_volume:/workspace" alpine:3.22.1 tar -x -C /workspace
git -C "$git_repo_path" archive HEAD server | docker run --rm -i -v "$new_code_volume:/workspace" alpine:3.22.1 tar -x -C /workspace

log "UPGRADE DRILL: compiling old/new migrate binaries"
docker run --rm -e CGO_ENABLED=0 -v "$old_code_volume:/workspace" -v "$bin_volume:/out" -w /workspace/server golang:1.26.5-alpine \
  /bin/sh -ec 'go build -trimpath -o /out/old-migrate ./cmd/migrate'
docker run --rm -e CGO_ENABLED=0 -v "$new_code_volume:/workspace" -v "$bin_volume:/out" -w /workspace/server golang:1.26.5-alpine \
  /bin/sh -ec 'go build -trimpath -o /out/new-migrate ./cmd/migrate'

docker run -d --name "$pg" --network "$network" \
  -e POSTGRES_DB=dd -e POSTGRES_USER=dd -e POSTGRES_PASSWORD="$pg_password" \
  -v "$pg_volume:/var/lib/postgresql" postgres:18.4-alpine >/dev/null
wait_postgres

log "UPGRADE DRILL: applying N release schema"
run_migrate old-migrate up >/dev/null
old_schema="$(run_migrate old-migrate status | awk '$NF == "applied" {v=$1} END {print v}')"
[[ -n "$old_schema" ]] || fail "could not determine old schema version"

log "UPGRADE DRILL: taking and validating pre-upgrade DB backup"
docker run --rm --network "$network" -e PGPASSWORD="$pg_password" -v "$backup_volume:/backup" postgres:18.4-alpine \
  pg_dump -h "$pg" -U dd -d dd --format=custom --compress=6 --no-owner --no-acl -f /backup/pre-upgrade.dump
docker run --rm -v "$backup_volume:/backup:ro" postgres:18.4-alpine pg_restore --list /backup/pre-upgrade.dump >/dev/null

log "UPGRADE DRILL: proving N+1 accepts N schema before applying forward migrations"
run_migrate new-migrate status >/dev/null
run_migrate new-migrate up >/dev/null
new_schema="$(run_migrate new-migrate status | awk '$NF == "applied" {v=$1} END {print v}')"
[[ -n "$new_schema" ]] || fail "could not determine new schema version"

log "UPGRADE DRILL: checking whether N application is schema-compatible after N+1 migrations"
set +e
old_after_output="$(run_migrate old-migrate status 2>&1)"
old_after_code=$?
set -e
if [[ "$old_after_code" -eq 0 ]]; then
  old_after_state="COMPATIBLE"
else
  old_after_state="INCOMPATIBLE"
fi

log "UPGRADE DRILL: destroying upgraded DB volume and restoring verified pre-upgrade backup (no migrate down)"
docker rm -f "$pg" >/dev/null
docker volume rm "$pg_volume" >/dev/null
docker run -d --name "$pg" --network "$network" \
  -e POSTGRES_DB=dd -e POSTGRES_USER=dd -e POSTGRES_PASSWORD="$pg_password" \
  -v "$pg_restore_volume:/var/lib/postgresql" postgres:18.4-alpine >/dev/null
wait_postgres
docker exec -e PGPASSWORD="$pg_password" "$pg" dropdb --force -U dd dd >/dev/null
docker exec -e PGPASSWORD="$pg_password" "$pg" createdb -U dd dd >/dev/null
docker run --rm --network "$network" -e PGPASSWORD="$pg_password" -v "$backup_volume:/backup:ro" postgres:18.4-alpine \
  pg_restore -h "$pg" -U dd -d dd --no-owner --no-acl --exit-on-error /backup/pre-upgrade.dump >/dev/null
run_migrate old-migrate status >/dev/null || fail "old release does not accept its own restored pre-upgrade schema"

printf 'UPGRADE_COMPAT_DRILL=PASS\n'
printf 'FROM_REF=%s\n' "$from_ref"
printf 'FROM_SCHEMA=%s\n' "$old_schema"
printf 'TO_SCHEMA=%s\n' "$new_schema"
printf 'PRE_UPGRADE_BACKUP=VERIFIED\n'
printf 'PRE_MIGRATION_NEW_RELEASE_STATUS=PASS\n'
printf 'OLD_RELEASE_STATUS_AFTER_NEW_SCHEMA=%s\n' "$old_after_state"
printf 'OLD_RELEASE_STATUS_AFTER_NEW_SCHEMA_EXIT=%s\n' "$old_after_code"
printf 'BACKUP_RESTORE_OLD_RELEASE_STATUS=PASS\n'
printf 'DATABASE_DOWN_EXECUTED=false\n'
if [[ "$old_after_state" == "INCOMPATIBLE" ]]; then
  printf 'ROLLBACK_POLICY=RESTORE_VERIFIED_PREUPGRADE_BACKUP_BEFORE_STARTING_OLD_APP\n'
  printf 'EXPECTED_OLD_STATUS_ERROR=%s\n' "$(printf '%s' "$old_after_output" | tail -1 | tr '\n' ' ')"
else
  printf 'ROLLBACK_POLICY=OLD_APP_MAY_RUN_AGAINST_NEWER_SCHEMA_AFTER_GATE\n'
fi
log "cleanup is enforced by EXIT trap; no upgrade-drill service or volume is intentionally retained"
