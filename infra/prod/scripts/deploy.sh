#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

load_prod_env
"$SCRIPT_DIR/preflight.sh"
require_cmd git
git -C "$REPO_ROOT" diff --quiet || fail "refusing production build from a dirty working tree"
git -C "$REPO_ROOT" diff --cached --quiet || fail "refusing production build with staged-but-uncommitted changes"

if service_is_running api; then
  fail "an existing DD production API is already running; use upgrade.sh for N→N+1 instead of deploy.sh"
fi

log "pulling pinned infrastructure images"
compose_with_storage pull postgres redis livekit caddy tls-mux
if [[ "${DD_OBJECT_STORAGE_MODE:-minio}" == "minio" ]]; then
  compose_with_storage pull minio minio-init
fi

log "building versioned API / Worker / migrate images"
compose_with_storage build api worker migrate

log "starting persistence layer"
compose_with_storage up -d postgres redis
wait_service_healthy postgres 120
wait_service_healthy redis 120

if [[ "${DD_OBJECT_STORAGE_MODE:-minio}" == "minio" ]]; then
  compose_with_storage up -d minio
  wait_service_healthy minio 120
  compose_with_storage run --rm --no-deps minio-init
fi

log "checking and applying forward-only database migrations"
compose_with_storage run --rm migrate status
compose_with_storage run --rm migrate up
compose_with_storage run --rm migrate status

log "starting RTC, API, and Worker"
compose_with_storage up -d livekit
wait_service_healthy livekit 120
compose_with_storage up -d api worker
wait_service_healthy api 180
wait_service_healthy worker 120

log "starting HTTPS/WSS/TURN-TLS ingress"
compose_with_storage up -d caddy tls-mux
wait_service_healthy caddy 120
wait_service_healthy tls-mux 120

"$SCRIPT_DIR/deployment-check.sh"
log "production deployment started successfully"
log "run: $SCRIPT_DIR/deployment-check.sh --public after DNS resolves and ACME certificates are issued"
