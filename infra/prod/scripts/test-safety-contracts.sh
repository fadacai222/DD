#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

tmp_root="$(mktemp -d)"
cleanup() {
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

write_manifest() {
  local path="$1"
  local backup_id="$2"
  local created_at="$3"
  local consistency="${4:-quiesced}"
  {
    printf 'BACKUP_FORMAT_VERSION=1\n'
    printf 'BACKUP_ID=%s\n' "$backup_id"
    printf 'CREATED_AT_UTC=%s\n' "$created_at"
    printf 'RELEASE_VERSION=1.2.3\n'
    printf 'IMAGE_TAG=v1.2.3\n'
    printf 'DB_NAME=dd\n'
    printf 'MEDIA_BUCKET=dd-media\n'
    printf 'OBJECT_STORAGE_MODE=minio\n'
    printf 'OBJECT_FILE_COUNT=0\n'
    printf 'SCHEMA_MIGRATION_MAX=000030\n'
    printf 'CONSISTENCY_MODE=%s\n' "$consistency"
    printf 'RPO_HOURS=6\n'
    printf 'RTO_HOURS=4\n'
  } > "$path"
}

expect_manifest_fail() {
  local label="$1"
  local path="$2"
  if (load_backup_manifest "$path" >/dev/null 2>&1); then
    fail "safety contract failed: manifest unexpectedly accepted ($label)"
  fi
}

valid_dir="$tmp_root/20260812T010203Z-v1.2.3"
mkdir -p "$valid_dir"
write_manifest "$valid_dir/manifest.env" "20260812T010203Z-v1.2.3" "20260812T010203Z"
load_backup_manifest "$valid_dir/manifest.env" >/dev/null
[[ "$BACKUP_ID" == "20260812T010203Z-v1.2.3" ]] || fail "valid manifest did not load expected BACKUP_ID"

unknown_manifest="$tmp_root/unknown.env"
cp "$valid_dir/manifest.env" "$unknown_manifest"
printf 'UNEXPECTED_KEY=1\n' >> "$unknown_manifest"
expect_manifest_fail "unknown key" "$unknown_manifest"

duplicate_manifest="$tmp_root/duplicate.env"
cp "$valid_dir/manifest.env" "$duplicate_manifest"
printf 'BACKUP_ID=20260812T010203Z-other\n' >> "$duplicate_manifest"
expect_manifest_fail "duplicate key" "$duplicate_manifest"

bad_time_manifest="$tmp_root/bad-time.env"
write_manifest "$bad_time_manifest" "20260812T250203Z-v1.2.3" "20260812T250203Z"
expect_manifest_fail "invalid UTC time" "$bad_time_manifest"

bad_consistency_manifest="$tmp_root/bad-consistency.env"
write_manifest "$bad_consistency_manifest" "20260812T010203Z-v1.2.3" "20260812T010203Z" "best-effort"
expect_manifest_fail "invalid consistency mode" "$bad_consistency_manifest"

malicious_dir="$tmp_root/20260812T010203Z-v1.2.3-malicious"
mkdir -p "$malicious_dir/objects"
for file in config.env postgres.dump schema-status.txt object-source-list.jsonl SHA256SUMS; do
  : > "$malicious_dir/$file"
done
marker="$tmp_root/manifest-command-executed"
{
  printf 'BACKUP_FORMAT_VERSION=1\n'
  printf 'BACKUP_ID=$(touch$IFS%s)\n' "$marker"
  printf 'CREATED_AT_UTC=20260812T010203Z\n'
  printf 'RELEASE_VERSION=1.2.3\n'
  printf 'IMAGE_TAG=v1.2.3\n'
  printf 'DB_NAME=dd\n'
  printf 'MEDIA_BUCKET=dd-media\n'
  printf 'OBJECT_STORAGE_MODE=minio\n'
  printf 'OBJECT_FILE_COUNT=0\n'
  printf 'SCHEMA_MIGRATION_MAX=000030\n'
  printf 'CONSISTENCY_MODE=quiesced\n'
  printf 'RPO_HOURS=6\n'
  printf 'RTO_HOURS=4\n'
} > "$malicious_dir/manifest.env"

expect_manifest_fail "shell command substitution" "$malicious_dir/manifest.env"
[[ ! -e "$marker" ]] || fail "malicious manifest executed shell syntax during direct parser test"

if "$SCRIPT_DIR/verify-backup.sh" "$malicious_dir" >/dev/null 2>&1; then
  fail "verify-backup.sh accepted malicious manifest"
fi
[[ ! -e "$marker" ]] || fail "verify-backup.sh executed malicious manifest shell syntax"

: > "$tmp_root/prod.env"
if DD_PROD_ENV_FILE="$tmp_root/prod.env" "$SCRIPT_DIR/restore.sh" \
  --backup "$malicious_dir" \
  --confirm "RESTORE:invalid.example:never" >/dev/null 2>&1; then
  fail "restore.sh accepted malicious manifest"
fi
[[ ! -e "$marker" ]] || fail "restore.sh executed malicious manifest shell syntax"

storage_root="$tmp_root/storage"
mkdir -p "$storage_root/secrets"
if (PROD_DIR="$storage_root" DD_OBJECT_STORAGE_MODE=minio require_storage_mode_secrets >/dev/null 2>&1); then
  fail "MinIO mode accepted missing minio_root_password"
fi
: > "$storage_root/secrets/minio_root_password"
if (PROD_DIR="$storage_root" DD_OBJECT_STORAGE_MODE=minio require_storage_mode_secrets >/dev/null 2>&1); then
  fail "MinIO mode accepted empty minio_root_password"
fi
printf 'non-empty-test-secret\n' > "$storage_root/secrets/minio_root_password"
(PROD_DIR="$storage_root" DD_OBJECT_STORAGE_MODE=minio require_storage_mode_secrets >/dev/null)
rm -f "$storage_root/secrets/minio_root_password"
(PROD_DIR="$storage_root" DD_OBJECT_STORAGE_MODE=external-s3 require_storage_mode_secrets >/dev/null)

log "safety contract tests PASS: manifest is data-only; malicious verify/restore rejected; storage-mode secret gate verified"
