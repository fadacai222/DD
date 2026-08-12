#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

[[ $# -eq 1 ]] || fail "usage: verify-backup.sh <backup-directory>"
backup_dir="$1"
[[ -d "$backup_dir" ]] || fail "backup directory not found: $backup_dir"
backup_dir="$(cd "$backup_dir" && pwd -P)"

require_cmd docker
require_cmd sha256sum

for required in manifest.env config.env postgres.dump schema-status.txt object-source-list.jsonl SHA256SUMS; do
  [[ -f "$backup_dir/$required" ]] || fail "backup is incomplete; missing $required"
done
[[ -d "$backup_dir/objects" ]] || fail "backup is incomplete; missing objects directory"

load_backup_manifest "$backup_dir/manifest.env" || fail "backup manifest validation failed"
[[ "$(basename "$backup_dir")" == "$BACKUP_ID" ]] || fail "backup directory name does not match manifest BACKUP_ID"

log "verifying backup checksums"
(
  cd "$backup_dir"
  sha256sum -c SHA256SUMS >/dev/null
)

log "verifying PostgreSQL custom dump catalog"
backup_host_path="$(docker_host_path "$backup_dir")"
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$backup_host_path:/backup:ro" \
  postgres:18.4-alpine \
  pg_restore --list /backup/postgres.dump >/dev/null

actual_objects="$(find "$backup_dir/objects" -type f | wc -l | tr -d ' ')"
[[ "$actual_objects" =~ ^[0-9]+$ ]] || fail "failed to count backed-up objects"
[[ "${OBJECT_FILE_COUNT:-}" == "$actual_objects" ]] || fail "object count mismatch: manifest=${OBJECT_FILE_COUNT:-missing}, actual=$actual_objects"

log "backup verification PASS: id=$BACKUP_ID, objects=$actual_objects, schema=${SCHEMA_MIGRATION_MAX:-unknown}, consistency=${CONSISTENCY_MODE:-unknown}"
