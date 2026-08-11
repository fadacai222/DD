#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

require_cmd docker
export MSYS_NO_PATHCONV=1

suffix="$(date -u +%Y%m%d%H%M%S)-$$"
network="dd-drill-net-$suffix"
pg_source="dd-drill-pg-source-$suffix"
pg_target="dd-drill-pg-target-$suffix"
minio_source="dd-drill-minio-source-$suffix"
minio_target="dd-drill-minio-target-$suffix"
pg_source_volume="dd-drill-pg-source-$suffix"
pg_target_volume="dd-drill-pg-target-$suffix"
obj_source_volume="dd-drill-obj-source-$suffix"
obj_target_volume="dd-drill-obj-target-$suffix"
backup_volume="dd-drill-backup-$suffix"
migrate_image="dd-restore-drill-migrate:$suffix"
pg_password="drill$(openssl rand -hex 16)"
minio_password="drill$(openssl rand -hex 16)"
evidence="dd-restore-drill-$suffix-$(openssl rand -hex 8)"
started_at="$(date +%s)"

cleanup() {
  docker rm -f "$pg_source" "$pg_target" "$minio_source" "$minio_target" >/dev/null 2>&1 || true
  docker volume rm -f "$pg_source_volume" "$pg_target_volume" "$obj_source_volume" "$obj_target_volume" "$backup_volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker image rm -f "$migrate_image" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_postgres() {
  local name="$1"
  for _ in $(seq 1 60); do
    if docker exec "$name" pg_isready -U dd -d dd >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  fail "temporary PostgreSQL did not become ready: $name"
}

wait_minio() {
  local name="$1"
  for _ in $(seq 1 60); do
    if docker exec "$name" curl -fsS http://127.0.0.1:9000/minio/health/ready >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  fail "temporary MinIO did not become ready: $name"
}

log "DRILL: building current migrate image"
repo_host_path="$(docker_host_path "$REPO_ROOT")"
dockerfile_host_path="$(docker_host_path "$REPO_ROOT/server/Dockerfile")"
docker build -q -f "$dockerfile_host_path" --target migrate -t "$migrate_image" "$repo_host_path" >/dev/null

docker network create "$network" >/dev/null
docker volume create "$pg_source_volume" >/dev/null
docker volume create "$pg_target_volume" >/dev/null
docker volume create "$obj_source_volume" >/dev/null
docker volume create "$obj_target_volume" >/dev/null
docker volume create "$backup_volume" >/dev/null

log "DRILL: creating source PostgreSQL and applying real DD migrations"
docker run -d --name "$pg_source" --network "$network" \
  -e POSTGRES_DB=dd -e POSTGRES_USER=dd -e POSTGRES_PASSWORD="$pg_password" \
  -v "$pg_source_volume:/var/lib/postgresql" postgres:18.4-alpine >/dev/null
wait_postgres "$pg_source"
docker run --rm --network "$network" \
  -e DATABASE_URL="postgres://dd:${pg_password}@${pg_source}:5432/dd?sslmode=disable" \
  "$migrate_image" up >/dev/null

docker exec -e PGPASSWORD="$pg_password" "$pg_source" psql -U dd -d dd -v ON_ERROR_STOP=1 \
  -c 'CREATE TABLE dr_restore_evidence(value text PRIMARY KEY);' >/dev/null
docker exec -e PGPASSWORD="$pg_password" "$pg_source" psql -U dd -d dd -v ON_ERROR_STOP=1 \
  -c "INSERT INTO dr_restore_evidence(value) VALUES ('$evidence');" >/dev/null

log "DRILL: creating PostgreSQL backup in isolated backup volume"
docker run --rm --network "$network" -e PGPASSWORD="$pg_password" -v "$backup_volume:/backup" postgres:18.4-alpine \
  pg_dump -h "$pg_source" -U dd -d dd --format=custom --compress=6 --no-owner --no-acl -f /backup/postgres.dump
docker run --rm -v "$backup_volume:/backup:ro" postgres:18.4-alpine pg_restore --list /backup/postgres.dump >/dev/null

log "DRILL: creating source MinIO object and mirroring it to isolated backup volume"
docker run -d --name "$minio_source" --network "$network" \
  -e MINIO_ROOT_USER=drillroot -e MINIO_ROOT_PASSWORD="$minio_password" \
  -v "$obj_source_volume:/data" minio/minio:RELEASE.2025-09-07T16-13-09Z server /data >/dev/null
wait_minio "$minio_source"
docker run --rm --network "$network" -v "$backup_volume:/backup" --entrypoint /bin/sh minio/mc:RELEASE.2025-08-13T08-35-41Z -ec "
  mc alias set src http://$minio_source:9000 drillroot '$minio_password' >/dev/null
  mc mb src/dd-media >/dev/null
  printf '%s' '$evidence' | mc pipe src/dd-media/drill/evidence.txt >/dev/null
  mkdir -p /backup/objects
  mc mirror --overwrite --preserve src/dd-media /backup/objects >/dev/null
"

log "DRILL: destroying source database/object containers AND source data volumes"
docker rm -f "$pg_source" "$minio_source" >/dev/null
docker volume rm "$pg_source_volume" "$obj_source_volume" >/dev/null

log "DRILL: restoring PostgreSQL into a brand-new target volume"
docker run -d --name "$pg_target" --network "$network" \
  -e POSTGRES_DB=dd -e POSTGRES_USER=dd -e POSTGRES_PASSWORD="$pg_password" \
  -v "$pg_target_volume:/var/lib/postgresql" postgres:18.4-alpine >/dev/null
wait_postgres "$pg_target"
docker exec -e PGPASSWORD="$pg_password" "$pg_target" dropdb --force -U dd dd >/dev/null
docker exec -e PGPASSWORD="$pg_password" "$pg_target" createdb -U dd dd >/dev/null
docker run --rm --network "$network" -e PGPASSWORD="$pg_password" -v "$backup_volume:/backup:ro" postgres:18.4-alpine \
  pg_restore -h "$pg_target" -U dd -d dd --no-owner --no-acl --exit-on-error /backup/postgres.dump >/dev/null
restored_db_evidence="$(docker exec -e PGPASSWORD="$pg_password" "$pg_target" psql -U dd -d dd -Atc 'SELECT value FROM dr_restore_evidence LIMIT 1')"
[[ "$restored_db_evidence" == "$evidence" ]] || fail "PostgreSQL restore evidence mismatch"
docker run --rm --network "$network" \
  -e DATABASE_URL="postgres://dd:${pg_password}@${pg_target}:5432/dd?sslmode=disable" \
  "$migrate_image" status >/dev/null

log "DRILL: restoring objects into a brand-new MinIO volume"
docker run -d --name "$minio_target" --network "$network" \
  -e MINIO_ROOT_USER=drillroot -e MINIO_ROOT_PASSWORD="$minio_password" \
  -v "$obj_target_volume:/data" minio/minio:RELEASE.2025-09-07T16-13-09Z server /data >/dev/null
wait_minio "$minio_target"
restored_object_evidence="$(docker run --rm --network "$network" -v "$backup_volume:/backup:ro" --entrypoint /bin/sh minio/mc:RELEASE.2025-08-13T08-35-41Z -ec "
  mc alias set dst http://$minio_target:9000 drillroot '$minio_password' >/dev/null
  mc mb dst/dd-media >/dev/null
  mc mirror --overwrite --remove /backup/objects dst/dd-media >/dev/null
  mc cat dst/dd-media/drill/evidence.txt
")"
[[ "$restored_object_evidence" == "$evidence" ]] || fail "object restore evidence mismatch"

elapsed="$(( $(date +%s) - started_at ))"
log "DRILL PASS: PostgreSQL dump→source destroy→restore verified; object mirror→source destroy→restore verified; current migration status verified; elapsed=${elapsed}s"
log "cleanup is enforced by EXIT trap; no drill service or volume is intentionally retained"
