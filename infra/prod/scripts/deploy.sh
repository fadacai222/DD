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
if is_bt_ingress; then
  compose_with_storage pull postgres redis livekit
else
  compose_with_storage pull postgres redis livekit caddy tls-mux
fi
if [[ "${DD_OBJECT_STORAGE_MODE:-minio}" == "minio" ]]; then
  compose_with_storage pull minio minio-init
fi

log "building versioned API / Worker / migrate images"
compose_with_storage build api worker migrate

log "verifying non-root DD runtime can read mounted production secrets"
compose_with_storage run --rm --no-deps --entrypoint /bin/sh migrate -ec 'test -r /run/secrets/database_url'
compose_with_storage run --rm --no-deps --entrypoint /bin/sh api -ec '
  for path in \
    /run/secrets/database_url \
    /run/secrets/redis_url \
    /run/secrets/auth_token_secret \
    /run/secrets/admin_security_secret \
    /run/secrets/email_code_pepper \
    /run/secrets/livekit_api_key \
    /run/secrets/livekit_api_secret \
    /run/secrets/media_s3_access_key \
    /run/secrets/media_s3_secret_key \
    /run/secrets/smtp_password \
    /run/secrets/telegram_bot_token; do
    test -r "$path" || { echo "unreadable secret: $path" >&2; exit 1; }
  done
'
compose_with_storage run --rm --no-deps --entrypoint /bin/sh worker -ec '
  for path in \
    /run/secrets/database_url \
    /run/secrets/auth_token_secret \
    /run/secrets/media_s3_access_key \
    /run/secrets/media_s3_secret_key \
    /run/secrets/fcm_service_account_json \
    /run/secrets/apns_private_key; do
    test -r "$path" || { echo "unreadable secret: $path" >&2; exit 1; }
  done
'

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

if is_bt_ingress; then
  log "BaoTa ingress mode: keeping host Nginx on TCP 80/443; Caddy/tls-mux are not started"
  log "loopback backends: API 127.0.0.1:${DD_API_HOST_PORT}, RTC 127.0.0.1:${DD_LIVEKIT_HOST_PORT}, Media 127.0.0.1:${DD_S3_HOST_PORT}"
else
  log "starting HTTPS/WSS/TURN-TLS ingress"
  compose_with_storage up -d caddy tls-mux
  wait_service_healthy caddy 120
  wait_service_healthy tls-mux 120
fi

"$SCRIPT_DIR/deployment-check.sh"
log "production deployment started successfully"
if is_bt_ingress; then
  log "configure BaoTa reverse proxies, then run: $SCRIPT_DIR/deployment-check.sh --public"
else
  log "run: $SCRIPT_DIR/deployment-check.sh --public after DNS resolves and ACME certificates are issued"
fi
