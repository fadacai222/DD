#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROD_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REPO_ROOT="$(cd "$PROD_DIR/../.." && pwd -P)"
ENV_FILE="${DD_PROD_ENV_FILE:-$PROD_DIR/.env}"
COMPOSE_FILE="$PROD_DIR/compose.yml"
BT_COMPOSE_FILE="$PROD_DIR/compose.bt.yml"

log() {
  printf '[dd-prod] %s\n' "$*"
}

fail() {
  printf '[dd-prod] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

load_prod_env() {
  [[ -f "$ENV_FILE" ]] || fail "missing $ENV_FILE (copy .env.example to .env first)"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

is_bt_ingress() {
  [[ "${DD_INGRESS_MODE:-caddy}" == "bt-nginx" ]]
}

run_compose() {
  local files=(-f "$COMPOSE_FILE")
  if is_bt_ingress; then
    files+=(-f "$BT_COMPOSE_FILE")
  fi
  docker compose --env-file "$ENV_FILE" "${files[@]}" "$@"
}

compose() {
  run_compose "$@"
}

compose_with_storage() {
  if [[ "${DD_OBJECT_STORAGE_MODE:-minio}" == "minio" ]]; then
    run_compose --profile selfhost-storage "$@"
  else
    run_compose "$@"
  fi
}

compose_tools() {
  run_compose --profile tools "$@"
}

secret_path() {
  printf '%s/secrets/%s' "$PROD_DIR" "$1"
}

read_secret() {
  local path
  path="$(secret_path "$1")"
  [[ -f "$path" ]] || fail "missing secret file: $path"
  tr -d '\r\n' < "$path"
}

require_secret_nonempty() {
  local path
  path="$(secret_path "$1")"
  [[ -s "$path" ]] || fail "required secret is missing or empty: $path"
}

require_secret_file() {
  local path
  path="$(secret_path "$1")"
  [[ -f "$path" ]] || fail "required secret file is missing: $path"
}

require_storage_mode_secrets() {
  case "${DD_OBJECT_STORAGE_MODE:-minio}" in
    minio)
      require_secret_nonempty minio_root_password
      ;;
    external-s3)
      ;;
    *)
      fail "DD_OBJECT_STORAGE_MODE must be minio or external-s3"
      ;;
  esac
}

manifest_parse_error() {
  printf '[dd-prod] ERROR: invalid backup manifest: %s\n' "$*" >&2
  return 1
}

load_backup_manifest() {
  local manifest="$1"
  local line key value line_number=0 created_prefix
  local year month day hour minute second year_number month_number day_number max_day
  declare -A manifest_values=()

  [[ -f "$manifest" ]] || { manifest_parse_error "file not found: $manifest"; return 1; }

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    [[ -n "$line" ]] || { manifest_parse_error "blank line at $line_number"; return 1; }
    [[ "$line" != *$'\r'* ]] || { manifest_parse_error "CR/control character at line $line_number"; return 1; }
    if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9._:+-]+)$ ]]; then
      manifest_parse_error "unsafe or malformed data at line $line_number"
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "$key" in
      BACKUP_FORMAT_VERSION|BACKUP_ID|CREATED_AT_UTC|RELEASE_VERSION|IMAGE_TAG|DB_NAME|MEDIA_BUCKET|OBJECT_STORAGE_MODE|OBJECT_FILE_COUNT|SCHEMA_MIGRATION_MAX|CONSISTENCY_MODE|RPO_HOURS|RTO_HOURS)
        ;;
      *)
        manifest_parse_error "unknown key '$key' at line $line_number"
        return 1
        ;;
    esac
    if [[ -n "${manifest_values[$key]+present}" ]]; then
      manifest_parse_error "duplicate key '$key'"
      return 1
    fi
    manifest_values["$key"]="$value"
  done < "$manifest"

  for key in BACKUP_FORMAT_VERSION BACKUP_ID CREATED_AT_UTC RELEASE_VERSION IMAGE_TAG DB_NAME MEDIA_BUCKET OBJECT_STORAGE_MODE OBJECT_FILE_COUNT SCHEMA_MIGRATION_MAX CONSISTENCY_MODE RPO_HOURS RTO_HOURS; do
    [[ -n "${manifest_values[$key]+present}" ]] || { manifest_parse_error "missing key '$key'"; return 1; }
  done

  [[ "${manifest_values[BACKUP_FORMAT_VERSION]}" == "1" ]] || { manifest_parse_error "unsupported BACKUP_FORMAT_VERSION"; return 1; }
  [[ "${manifest_values[CREATED_AT_UTC]}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { manifest_parse_error "CREATED_AT_UTC must be YYYYMMDDTHHMMSSZ"; return 1; }
  created_prefix="${manifest_values[CREATED_AT_UTC]}"
  year="${created_prefix:0:4}"
  month="${created_prefix:4:2}"
  day="${created_prefix:6:2}"
  hour="${created_prefix:9:2}"
  minute="${created_prefix:11:2}"
  second="${created_prefix:13:2}"
  year_number=$((10#$year))
  month_number=$((10#$month))
  day_number=$((10#$day))
  (( year_number >= 2000 && year_number <= 2199 )) || { manifest_parse_error "CREATED_AT_UTC year is outside supported range"; return 1; }
  (( month_number >= 1 && month_number <= 12 )) || { manifest_parse_error "CREATED_AT_UTC month is invalid"; return 1; }
  case "$month_number" in
    4|6|9|11) max_day=30 ;;
    2)
      max_day=28
      if (( year_number % 400 == 0 || (year_number % 4 == 0 && year_number % 100 != 0) )); then max_day=29; fi
      ;;
    *) max_day=31 ;;
  esac
  (( day_number >= 1 && day_number <= max_day )) || { manifest_parse_error "CREATED_AT_UTC day is invalid for month"; return 1; }
  (( 10#$hour <= 23 && 10#$minute <= 59 && 10#$second <= 59 )) || { manifest_parse_error "CREATED_AT_UTC time is invalid"; return 1; }
  [[ "${manifest_values[BACKUP_ID]}" =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { manifest_parse_error "BACKUP_ID format is invalid"; return 1; }
  [[ "${manifest_values[BACKUP_ID]}" == "$created_prefix-"* ]] || { manifest_parse_error "BACKUP_ID timestamp does not match CREATED_AT_UTC"; return 1; }
  [[ "${manifest_values[RELEASE_VERSION]}" == "unknown" || "${manifest_values[RELEASE_VERSION]}" =~ ^[A-Za-z0-9][A-Za-z0-9_.+-]{0,127}$ ]] || { manifest_parse_error "RELEASE_VERSION format is invalid"; return 1; }
  [[ "${manifest_values[IMAGE_TAG]}" == "unknown" || "${manifest_values[IMAGE_TAG]}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { manifest_parse_error "IMAGE_TAG format is invalid"; return 1; }
  [[ "${manifest_values[BACKUP_ID]}" == "${created_prefix}-${manifest_values[IMAGE_TAG]}" ]] || { manifest_parse_error "BACKUP_ID must equal CREATED_AT_UTC-IMAGE_TAG"; return 1; }
  [[ "${manifest_values[DB_NAME]}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}$ ]] || { manifest_parse_error "DB_NAME format is invalid"; return 1; }
  [[ "${manifest_values[MEDIA_BUCKET]}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { manifest_parse_error "MEDIA_BUCKET format is invalid"; return 1; }
  [[ "${manifest_values[MEDIA_BUCKET]}" != *..* && "${manifest_values[MEDIA_BUCKET]}" != *.-* && "${manifest_values[MEDIA_BUCKET]}" != *-.* ]] || { manifest_parse_error "MEDIA_BUCKET contains an invalid label sequence"; return 1; }
  [[ "${manifest_values[OBJECT_STORAGE_MODE]}" == "minio" || "${manifest_values[OBJECT_STORAGE_MODE]}" == "external-s3" ]] || { manifest_parse_error "OBJECT_STORAGE_MODE is invalid"; return 1; }
  [[ "${manifest_values[OBJECT_FILE_COUNT]}" =~ ^[0-9]{1,20}$ ]] || { manifest_parse_error "OBJECT_FILE_COUNT format is invalid"; return 1; }
  [[ "${manifest_values[SCHEMA_MIGRATION_MAX]}" =~ ^[0-9]{6}$ ]] || { manifest_parse_error "SCHEMA_MIGRATION_MAX format is invalid"; return 1; }
  [[ "${manifest_values[CONSISTENCY_MODE]}" == "quiesced" || "${manifest_values[CONSISTENCY_MODE]}" == "online-db-first" ]] || { manifest_parse_error "CONSISTENCY_MODE is invalid"; return 1; }
  [[ "${manifest_values[RPO_HOURS]}" =~ ^[0-9]{1,4}$ ]] || { manifest_parse_error "RPO_HOURS format is invalid"; return 1; }
  [[ "${manifest_values[RTO_HOURS]}" =~ ^[0-9]{1,4}$ ]] || { manifest_parse_error "RTO_HOURS format is invalid"; return 1; }
  (( 10#${manifest_values[RPO_HOURS]} >= 1 && 10#${manifest_values[RPO_HOURS]} <= 8760 )) || { manifest_parse_error "RPO_HOURS is outside 1..8760"; return 1; }
  (( 10#${manifest_values[RTO_HOURS]} >= 1 && 10#${manifest_values[RTO_HOURS]} <= 8760 )) || { manifest_parse_error "RTO_HOURS is outside 1..8760"; return 1; }

  BACKUP_FORMAT_VERSION="${manifest_values[BACKUP_FORMAT_VERSION]}"
  BACKUP_ID="${manifest_values[BACKUP_ID]}"
  CREATED_AT_UTC="${manifest_values[CREATED_AT_UTC]}"
  RELEASE_VERSION="${manifest_values[RELEASE_VERSION]}"
  IMAGE_TAG="${manifest_values[IMAGE_TAG]}"
  DB_NAME="${manifest_values[DB_NAME]}"
  MEDIA_BUCKET="${manifest_values[MEDIA_BUCKET]}"
  OBJECT_STORAGE_MODE="${manifest_values[OBJECT_STORAGE_MODE]}"
  OBJECT_FILE_COUNT="${manifest_values[OBJECT_FILE_COUNT]}"
  SCHEMA_MIGRATION_MAX="${manifest_values[SCHEMA_MIGRATION_MAX]}"
  CONSISTENCY_MODE="${manifest_values[CONSISTENCY_MODE]}"
  RPO_HOURS="${manifest_values[RPO_HOURS]}"
  RTO_HOURS="${manifest_values[RTO_HOURS]}"
}

backup_root() {
  local configured="${DD_BACKUP_ROOT:-./backups}"
  if [[ "$configured" = /* ]]; then
    printf '%s' "$configured"
  else
    printf '%s/%s' "$PROD_DIR" "${configured#./}"
  fi
}

upgrade_state_root() {
  printf '%s/upgrade-state' "$PROD_DIR"
}

service_container_id() {
  compose ps -q "$1"
}

service_is_running() {
  local id
  id="$(service_container_id "$1")"
  [[ -n "$id" ]] || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" == "true" ]]
}

wait_service_healthy() {
  local service="$1"
  local timeout_seconds="${2:-120}"
  local started now id health running
  started="$(date +%s)"

  while true; do
    id="$(service_container_id "$service")"
    if [[ -n "$id" ]]; then
      running="$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)"
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || true)"
      if [[ "$running" == "true" && ( "$health" == "healthy" || "$health" == "none" ) ]]; then
        return 0
      fi
      if [[ "$running" != "true" ]]; then
        docker inspect -f '{{.State.Status}} {{.State.ExitCode}} {{.State.Error}}' "$id" 2>/dev/null || true
        printf '[dd-prod] ERROR: service %s stopped before becoming healthy\n' "$service" >&2
        return 1
      fi
    fi

    now="$(date +%s)"
    if (( now - started >= timeout_seconds )); then
      compose ps "$service" || true
      printf '[dd-prod] ERROR: service %s did not become healthy within %ss\n' "$service" "$timeout_seconds" >&2
      return 1
    fi
    sleep 2
  done
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

docker_host_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$path"
  else
    printf '%s' "$path"
  fi
}

write_env_key() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    index($0, key "=") == 1 { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$ENV_FILE" > "$tmp"
  chmod --reference="$ENV_FILE" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}
