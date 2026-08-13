#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

load_prod_env
require_cmd docker
require_cmd openssl
require_cmd curl

docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2+ is required"

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

require_domain() {
  local name="$1"
  local value="${!name:-}"
  require_value "$name"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || fail "$name must be a hostname without scheme/path"
  [[ "$value" == *.* ]] || fail "$name must be a fully-qualified hostname"
  [[ "$value" != *"example.com"* && "$value" != *.example ]] || fail "$name still contains an example domain: $value"
}

is_public_ipv4() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<< "$ip"
  for part in "$a" "$b" "$c" "$d"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    (( part >= 0 && part <= 255 )) || return 1
  done
  (( a != 0 && a != 10 && a != 127 && a < 224 )) || return 1
  (( !(a == 169 && b == 254) )) || return 1
  (( !(a == 172 && b >= 16 && b <= 31) )) || return 1
  (( !(a == 192 && b == 168) )) || return 1
  (( !(a == 100 && b >= 64 && b <= 127) )) || return 1
  (( !(a == 192 && b == 0 && c == 2) )) || return 1
  (( !(a == 198 && b == 51 && c == 100) )) || return 1
  (( !(a == 203 && b == 0 && c == 113) )) || return 1
  return 0
}

require_value DD_RELEASE_VERSION
require_value DD_IMAGE_TAG
[[ "$DD_RELEASE_VERSION" != "dev" && "$DD_RELEASE_VERSION" != "latest" ]] || fail "DD_RELEASE_VERSION must identify a real release, not '$DD_RELEASE_VERSION'"
[[ "$DD_IMAGE_TAG" != "dev" && "$DD_IMAGE_TAG" != "latest" ]] || fail "DD_IMAGE_TAG must be immutable/versioned for production, not '$DD_IMAGE_TAG'"
[[ "$DD_IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail "DD_IMAGE_TAG is not a safe Docker tag"

require_domain DD_API_DOMAIN
require_domain DD_LIVEKIT_DOMAIN
require_domain DD_TURN_DOMAIN
require_value DD_ACME_EMAIL
require_value DD_PUBLIC_IP
is_public_ipv4 "$DD_PUBLIC_IP" || fail "DD_PUBLIC_IP must be a real public IPv4 address, not RFC1918/CGNAT/documentation/reserved space"

case "${DD_INGRESS_MODE:-caddy}" in
  caddy|bt-nginx) ;;
  *) fail "DD_INGRESS_MODE must be caddy or bt-nginx" ;;
esac

[[ "$DD_API_DOMAIN" != "$DD_LIVEKIT_DOMAIN" && "$DD_API_DOMAIN" != "$DD_TURN_DOMAIN" && "$DD_LIVEKIT_DOMAIN" != "$DD_TURN_DOMAIN" ]] || fail "API, LiveKit, and TURN hostnames must be distinct"

resolve_ipv4() {
  local domain="$1"
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
    return 0
  fi
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$domain" 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/' | sort -u
    return 0
  fi
  return 2
}

check_direct_dns() {
  local domain="$1" answers status
  set +e
  answers="$(resolve_ipv4 "$domain")"
  status=$?
  set -e
  if [[ "$status" -eq 2 ]]; then
    log "HUMAN-PENDING: cannot validate DNS for $domain because neither getent nor dig is installed"
    return 0
  fi
  [[ -n "$answers" ]] || fail "DNS A lookup returned no IPv4 address for $domain"
  printf '%s\n' "$answers" | grep -Fxq "$DD_PUBLIC_IP" || fail "$domain does not resolve directly to DD_PUBLIC_IP=$DD_PUBLIC_IP (got: $(printf '%s' "$answers" | tr '\n' ',' | sed 's/,$//'))"
}

check_direct_dns "$DD_API_DOMAIN"
check_direct_dns "$DD_LIVEKIT_DOMAIN"
check_direct_dns "$DD_TURN_DOMAIN"

require_value DD_ALLOWED_ORIGINS
require_value DD_ALLOWED_HTTP_ORIGINS
[[ "$DD_ALLOWED_ORIGINS" != *"*"* ]] || fail "DD_ALLOWED_ORIGINS must not contain wildcard '*' in production"
[[ "$DD_ALLOWED_HTTP_ORIGINS" != *"*"* ]] || fail "DD_ALLOWED_HTTP_ORIGINS must not contain wildcard '*' in production"
IFS=',' read -ra http_origins <<< "$DD_ALLOWED_HTTP_ORIGINS"
for origin in "${http_origins[@]}"; do
  [[ "$origin" == https://* ]] || fail "every DD_ALLOWED_HTTP_ORIGINS entry must use https://: $origin"
done

case "${DD_OBJECT_STORAGE_MODE:-minio}" in
  minio)
    require_domain DD_S3_DOMAIN
    require_value DD_MINIO_CORS_ORIGIN
    [[ "$DD_MINIO_CORS_ORIGIN" == https://* && "$DD_MINIO_CORS_ORIGIN" != *"*"* ]] || fail "DD_MINIO_CORS_ORIGIN must be an explicit HTTPS origin without wildcard"
    check_direct_dns "$DD_S3_DOMAIN"
    [[ "$DD_S3_DOMAIN" != "$DD_API_DOMAIN" && "$DD_S3_DOMAIN" != "$DD_LIVEKIT_DOMAIN" && "$DD_S3_DOMAIN" != "$DD_TURN_DOMAIN" ]] || fail "DD_S3_DOMAIN must be distinct from API/RTC/TURN hostnames"
    [[ "${DD_MEDIA_S3_BUCKET:-dd-media}" == "dd-media" ]] || fail "bundled MinIO policies currently require DD_MEDIA_S3_BUCKET=dd-media"
    [[ "${DD_MEDIA_S3_ENDPOINT:-}" == "https://${DD_S3_DOMAIN}" ]] || fail "bundled MinIO requires DD_MEDIA_S3_ENDPOINT=https://DD_S3_DOMAIN so presigned URLs are client-reachable"
    [[ "${DD_BACKUP_S3_ENDPOINT:-}" == "http://minio:9000" ]] || fail "bundled MinIO backup endpoint must be http://minio:9000"
    [[ "${DD_CADDYFILE:-./Caddyfile.minio}" == "./Caddyfile.minio" ]] || fail "bundled MinIO requires DD_CADDYFILE=./Caddyfile.minio"
    ;;
  external-s3)
    [[ "${DD_MEDIA_S3_ENDPOINT:-}" == https://* ]] || fail "external S3 media endpoint must use HTTPS"
    [[ "${DD_BACKUP_S3_ENDPOINT:-}" == https://* ]] || fail "external S3 backup endpoint must use HTTPS"
    [[ "${DD_CADDYFILE:-}" == "./Caddyfile.external-s3" ]] || fail "external S3 requires DD_CADDYFILE=./Caddyfile.external-s3"
    ;;
  *)
    fail "DD_OBJECT_STORAGE_MODE must be minio or external-s3"
    ;;
esac

require_storage_mode_secrets

for secret in postgres_password database_url redis_password redis_url media_s3_access_key media_s3_secret_key backup_s3_access_key backup_s3_secret_key livekit_api_key livekit_api_secret auth_token_secret admin_security_secret email_code_pepper; do
  require_secret_nonempty "$secret"
done
for optional in smtp_password telegram_bot_token fcm_service_account_json apns_private_key; do
  require_secret_file "$optional"
done
require_secret_nonempty turn_cert.pem
require_secret_nonempty turn_key.pem

[[ "$(read_secret database_url)" == postgres://* || "$(read_secret database_url)" == postgresql://* ]] || fail "database_url must be a postgres:// or postgresql:// URL"
[[ "$(read_secret redis_url)" == redis://* || "$(read_secret redis_url)" == rediss://* ]] || fail "redis_url must be a redis:// or rediss:// URL"
(( ${#DD_PUBLIC_IP} > 0 ))
auth_token_value="$(read_secret auth_token_secret)"
admin_security_value="$(read_secret admin_security_secret)"
livekit_secret_value="$(read_secret livekit_api_secret)"
email_pepper_value="$(read_secret email_code_pepper)"
(( ${#auth_token_value} >= 32 )) || fail "auth_token_secret must contain at least 32 characters"
(( ${#admin_security_value} >= 32 )) || fail "admin_security_secret must contain at least 32 characters"
[[ "$admin_security_value" != "$auth_token_value" ]] || fail "admin_security_secret must be independent from auth_token_secret"
(( ${#livekit_secret_value} >= 32 )) || fail "livekit_api_secret must contain at least 32 characters"
(( ${#email_pepper_value} >= 32 )) || fail "email_code_pepper must contain at least 32 characters"

if [[ "${DD_REGISTRATION_MODE:-closed}" != "closed" ]]; then
  require_value DD_SMTP_HOST
  require_value DD_SMTP_FROM
  if [[ -n "${DD_SMTP_USERNAME:-}" ]]; then
    require_secret_nonempty smtp_password
  fi
fi

for numeric in DD_TURN_UDP_PORT DD_TURN_TLS_PORT DD_RTC_UDP_PORT_START DD_RTC_UDP_PORT_END DD_BACKUP_RETENTION_DAYS DD_BACKUP_INTERVAL_HOURS DD_RPO_HOURS DD_RTO_HOURS; do
  require_value "$numeric"
  [[ "${!numeric}" =~ ^[0-9]+$ ]] || fail "$numeric must be an integer"
done
(( DD_TURN_UDP_PORT >= 1 && DD_TURN_UDP_PORT <= 65535 )) || fail "DD_TURN_UDP_PORT is outside 1..65535"
(( DD_TURN_TLS_PORT >= 1 && DD_TURN_TLS_PORT <= 65535 )) || fail "DD_TURN_TLS_PORT is outside 1..65535"
(( DD_RTC_UDP_PORT_START >= 1024 && DD_RTC_UDP_PORT_START <= 65535 )) || fail "DD_RTC_UDP_PORT_START is outside 1024..65535"
(( DD_RTC_UDP_PORT_END >= DD_RTC_UDP_PORT_START && DD_RTC_UDP_PORT_END <= 65535 )) || fail "DD_RTC_UDP_PORT_END must be >= start and <= 65535"
(( DD_RTC_UDP_PORT_END - DD_RTC_UDP_PORT_START <= 1000 )) || fail "RTC UDP range is unexpectedly wide (>1001 ports); review before exposing it"
case "${DD_LIVEKIT_SKIP_EXTERNAL_IP_VALIDATION:-false}" in
  true|false) ;;
  *) fail "DD_LIVEKIT_SKIP_EXTERNAL_IP_VALIDATION must be true or false" ;;
esac

if is_bt_ingress; then
  for local_port in DD_API_HOST_PORT DD_LIVEKIT_HOST_PORT DD_S3_HOST_PORT; do
    require_value "$local_port"
    [[ "${!local_port}" =~ ^[0-9]+$ ]] || fail "$local_port must be an integer"
    (( ${!local_port} >= 1024 && ${!local_port} <= 65535 )) || fail "$local_port is outside 1024..65535"
    (( ${!local_port} != 443 )) || fail "$local_port must not use host TCP 443 in bt-nginx mode"
  done
  (( DD_TURN_TLS_PORT != 80 && DD_TURN_TLS_PORT != 443 )) || fail "DD_TURN_TLS_PORT must not use host TCP 80/443 in bt-nginx mode"
  (( DD_TURN_UDP_PORT != 80 && DD_TURN_UDP_PORT != 443 )) || fail "DD_TURN_UDP_PORT must not use host UDP 80/443 in bt-nginx mode"
else
  (( DD_TURN_TLS_PORT == 443 && DD_TURN_UDP_PORT == 443 )) || fail "built-in caddy ingress requires TURN TLS/UDP on 443"
fi
(( DD_BACKUP_RETENTION_DAYS >= 1 )) || fail "DD_BACKUP_RETENTION_DAYS must be >= 1"
(( DD_BACKUP_INTERVAL_HOURS >= 1 )) || fail "DD_BACKUP_INTERVAL_HOURS must be >= 1"
(( DD_RPO_HOURS >= DD_BACKUP_INTERVAL_HOURS )) || fail "configured quiesced DR recovery-point interval exceeds DD_RPO_HOURS"
(( DD_RTO_HOURS >= 1 )) || fail "DD_RTO_HOURS must be >= 1"

turn_cert="$(secret_path turn_cert.pem)"
turn_key="$(secret_path turn_key.pem)"
openssl x509 -in "$turn_cert" -noout -checkend 86400 >/dev/null || fail "TURN certificate is invalid or expires within 24 hours"
openssl x509 -in "$turn_cert" -noout -checkhost "$DD_TURN_DOMAIN" >/dev/null || fail "TURN certificate does not cover DD_TURN_DOMAIN"
cert_pub="$(openssl x509 -in "$turn_cert" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)"
key_pub="$(openssl pkey -in "$turn_key" -pubout -outform DER 2>/dev/null | openssl dgst -sha256)"
[[ "$cert_pub" == "$key_pub" ]] || fail "TURN certificate and private key do not match"

log "validating Docker Compose model"
compose_with_storage config -q
compose_tools config -q

if [[ "${DD_OBJECT_STORAGE_MODE:-minio}" == "external-s3" ]]; then
  log "validating external S3 bucket reachability with dedicated backup credentials"
  compose_tools run --rm --no-deps --entrypoint /bin/sh object-backup-tool -ec '
    ACCESS_KEY="$(cat /run/secrets/backup_s3_access_key)"
    SECRET_KEY="$(cat /run/secrets/backup_s3_secret_key)"
    mc alias set source "$BACKUP_S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY" >/dev/null
    mc stat "source/$MEDIA_BUCKET" >/dev/null
  '
fi

if is_bt_ingress; then
  [[ -f "$BT_COMPOSE_FILE" ]] || fail "BaoTa compose overlay not found: $BT_COMPOSE_FILE"
  log "BaoTa ingress selected: host Nginx keeps TCP 80/443; DD Caddy/HAProxy validation is skipped"
else
  caddy_file="$PROD_DIR/${DD_CADDYFILE#./}"
  [[ -f "$caddy_file" ]] || fail "Caddyfile not found: $caddy_file"
  caddy_host_path="$(docker_host_path "$caddy_file")"
  haproxy_host_path="$(docker_host_path "$PROD_DIR/haproxy.cfg")"
  log "validating Caddy config"
  MSYS_NO_PATHCONV=1 docker run --rm \
    -e DD_ACME_EMAIL="$DD_ACME_EMAIL" \
    -e DD_API_DOMAIN="$DD_API_DOMAIN" \
    -e DD_LIVEKIT_DOMAIN="$DD_LIVEKIT_DOMAIN" \
    -e DD_S3_DOMAIN="${DD_S3_DOMAIN:-}" \
    -v "$caddy_host_path:/etc/caddy/Caddyfile:ro" \
    caddy:2.10.2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

  log "validating HAProxy SNI routing config"
  MSYS_NO_PATHCONV=1 docker run --rm \
    -e DD_TURN_DOMAIN="$DD_TURN_DOMAIN" \
    -v "$haproxy_host_path:/usr/local/etc/haproxy/haproxy.cfg:ro" \
    haproxy:3.2.4-alpine haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null
fi

log "validating LiveKit production port configuration"
livekit_ports="$(compose_with_storage run --rm --no-deps --entrypoint /bin/sh livekit -ec '
  export LIVEKIT_KEYS="$(cat /run/secrets/livekit_api_key): $(cat /run/secrets/livekit_api_secret)"
  export REDIS_PASSWORD="$(cat /run/secrets/redis_password)"
  exec /livekit-server ports
')"
printf '%s\n' "$livekit_ports" | grep -Fq '7881 - ICE/TCP' || fail "LiveKit config does not expose ICE/TCP 7881"
printf '%s\n' "$livekit_ports" | grep -Fq "${DD_RTC_UDP_PORT_START}-${DD_RTC_UDP_PORT_END} - ICE/UDP range" || fail "LiveKit config does not expose the configured ICE/UDP range"
printf '%s\n' "$livekit_ports" | grep -Fq "${DD_TURN_TLS_PORT} - TURN/TLS" || fail "LiveKit config does not expose TURN/TLS on TCP ${DD_TURN_TLS_PORT}"
printf '%s\n' "$livekit_ports" | grep -Fq "${DD_TURN_UDP_PORT} - TURN/UDP" || fail "LiveKit config does not expose TURN/UDP on UDP ${DD_TURN_UDP_PORT}"

log "preflight PASS"
if is_bt_ingress; then
  log "HUMAN-PENDING: configure BaoTa reverse proxies for API/RTC/Media and verify UDP ${DD_TURN_UDP_PORT}, TCP ${DD_TURN_TLS_PORT}/7881, RTC UDP range, and real cross-carrier/mobile call fallback"
else
  log "HUMAN-PENDING: verify public DNS, host/cloud firewall, NAT forwarding, UDP 443, TCP 443/7881, RTC UDP range, and real cross-carrier/mobile call fallback from outside this host"
fi
