#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

load_prod_env
require_cmd docker

public_check=false
if [[ "${1:-}" == "--public" ]]; then
  public_check=true
elif [[ -n "${1:-}" ]]; then
  fail "usage: deployment-check.sh [--public]"
fi

services=(postgres redis livekit api worker)
if ! is_bt_ingress; then
  services+=(caddy tls-mux)
fi
for service in "${services[@]}"; do
  service_is_running "$service" || fail "$service is not running"
  wait_service_healthy "$service" 5
  log "$service healthy/running"
done
if [[ "${DD_OBJECT_STORAGE_MODE:-minio}" == "minio" ]]; then
  service_is_running minio || fail "minio is not running"
  wait_service_healthy minio 5
  log "minio healthy"
fi
compose exec -T api wget -q -O /dev/null http://127.0.0.1:18473/api/v1/system/live
compose exec -T api wget -q -O /dev/null http://127.0.0.1:18473/api/v1/system/ready
log "API live/readiness endpoints PASS"

api_version="$(compose exec -T api wget -q -O - http://127.0.0.1:18473/api/v1/system/version)"
log "API version: $api_version"

compose exec -T api /bin/sh -ec '
  test -n "${LIVEKIT_URL:-}" || { echo "LIVEKIT_URL is empty" >&2; exit 1; }
  test -s /run/secrets/livekit_api_key || { echo "livekit_api_key is empty" >&2; exit 1; }
  test -s /run/secrets/livekit_api_secret || { echo "livekit_api_secret is empty" >&2; exit 1; }
'
log "group-call media runtime config PASS"

compose exec -T worker /bin/sh -ec '
  test -s /run/secrets/fcm_service_account_json || { echo "fcm_service_account_json is empty; Android background Push cannot work" >&2; exit 1; }
  grep -q '"project_id"' /run/secrets/fcm_service_account_json || { echo "FCM service account has no project_id" >&2; exit 1; }
  grep -q '"private_key"' /run/secrets/fcm_service_account_json || { echo "FCM service account has no private_key" >&2; exit 1; }
'
log "Android FCM worker credential PASS"

voice_endpoint="$(compose exec -T api /bin/sh -ec 'printf %s "${VOICE_TRANSCRIPTION_ENDPOINT:-}"')"
if [[ -n "$voice_endpoint" ]]; then
  log "voice transcription runtime config ENABLED"
else
  log "FEATURE-DISABLED: VOICE_TRANSCRIPTION_ENDPOINT is empty; manual/automatic STT will be unavailable"
fi

livekit_id="$(service_container_id livekit)"
node_ip_line="$(docker logs "$livekit_id" 2>&1 | grep -E 'nodeIP|node_ip' | tail -1 || true)"
if [[ -n "$node_ip_line" ]]; then
  printf '%s' "$node_ip_line" | grep -Fq "$DD_PUBLIC_IP" || fail "LiveKit discovered/advertised a node IP different from DD_PUBLIC_IP=$DD_PUBLIC_IP: $node_ip_line"
  log "LiveKit external/node IP log matches DD_PUBLIC_IP"
else
  log "HUMAN-PENDING: LiveKit log format did not expose nodeIP; verify advertised ICE candidates resolve to DD_PUBLIC_IP from a remote client"
fi

if [[ "$public_check" == "true" ]]; then
  require_cmd curl
  require_cmd openssl
  log "checking public HTTPS API endpoint"
  curl --fail --silent --show-error --max-time 15 "https://${DD_API_DOMAIN}/api/v1/system/live" >/dev/null
  curl --fail --silent --show-error --max-time 15 "https://${DD_API_DOMAIN}/api/v1/system/ready" >/dev/null

  log "checking public LiveKit TLS/WSS ingress host"
  rtc_status="$(curl --silent --show-error --max-time 15 -o /dev/null -w '%{http_code}' "https://${DD_LIVEKIT_DOMAIN}/")"
  [[ "$rtc_status" != "000" && "$rtc_status" -lt 500 ]] || fail "LiveKit public TLS endpoint returned HTTP $rtc_status"

  if (( DD_TURN_TLS_PORT > 0 )); then
    log "checking TURN/TLS certificate on TCP/${DD_TURN_TLS_PORT}"
    if command -v timeout >/dev/null 2>&1; then
      timeout 15 openssl s_client -connect "${DD_TURN_DOMAIN}:${DD_TURN_TLS_PORT}" -servername "$DD_TURN_DOMAIN" -verify_return_error -brief </dev/null >/dev/null 2>&1 \
        || fail "TURN/TLS public handshake failed"
    else
      openssl s_client -connect "${DD_TURN_DOMAIN}:${DD_TURN_TLS_PORT}" -servername "$DD_TURN_DOMAIN" -verify_return_error -brief </dev/null >/dev/null 2>&1 \
        || fail "TURN/TLS public handshake failed"
    fi
    log "public HTTPS + RTC TLS + TURN/TLS handshake PASS"
  else
    log "TURN/TLS check skipped: disabled for bt-nginx coexistence mode"
  fi
  log "HUMAN-PENDING: this does not prove UDP ${DD_TURN_UDP_PORT}, ICE/TCP 7881, media UDP range, carrier NAT behavior, or Wi-Fi/mobile-network switching; verify with real remote clients"
else
  log "public route checks skipped; run deployment-check.sh --public after DNS/cert issuance"
  log "HUMAN-PENDING: public TURN/UDP/TLS and cross-carrier RTC still require real external clients"
fi
