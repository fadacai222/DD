#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROD_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REPO_ROOT="$(cd "$PROD_DIR/../.." && pwd -P)"
ENV_FILE="${DD_PROD_ENV_FILE:-$PROD_DIR/.env}"
COMPOSE_FILE="$PROD_DIR/compose.yml"

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

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

compose_with_storage() {
  if [[ "${DD_OBJECT_STORAGE_MODE:-minio}" == "minio" ]]; then
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" --profile selfhost-storage "$@"
  else
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
  fi
}

compose_tools() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" --profile tools "$@"
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
