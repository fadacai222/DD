#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

load_prod_env
[[ $# -ge 1 ]] || fail "usage: restart.sh <api|worker|livekit|caddy|tls-mux> [...]"

for service in "$@"; do
  case "$service" in
    caddy|tls-mux)
      is_bt_ingress && fail "'$service' is disabled in bt-nginx mode; BaoTa/Nginx owns TCP 80/443"
      ;;
    api|worker|livekit) ;;
    postgres|redis|minio|migrate|minio-init)
      fail "refusing controlled restart of stateful/one-shot service '$service'; use an explicit maintenance procedure"
      ;;
    *) fail "unsupported service for controlled restart: $service" ;;
  esac

done

for service in "$@"; do
  log "controlled restart: $service"
  compose_with_storage up -d --no-deps --force-recreate "$service"
  case "$service" in
    api|worker|livekit|caddy|tls-mux) wait_service_healthy "$service" 180 ;;
  esac
done

"$SCRIPT_DIR/deployment-check.sh"
log "controlled restart PASS"
