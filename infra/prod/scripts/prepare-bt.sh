#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

[[ $# -eq 3 ]] || fail "usage: prepare-bt.sh <base-domain> <public-ipv4> <acme-email>"
base_domain="${1,,}"
public_ip="$2"
acme_email="$3"
template="$PROD_DIR/.env.bt.example"
target="$PROD_DIR/.env"

[[ "$base_domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$base_domain" == *.* ]] || fail "invalid base domain: $base_domain"
[[ "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "public IP must be IPv4"
[[ "$acme_email" == *@*.* ]] || fail "invalid ACME email"
[[ -f "$template" ]] || fail "missing template: $template"
[[ ! -e "$target" ]] || fail "$target already exists; move/remove it explicitly before regenerating"

tmp="$(mktemp "$PROD_DIR/.env.bt.XXXXXX")"
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    DD_API_DOMAIN=*) printf 'DD_API_DOMAIN=api.%s\n' "$base_domain" ;;
    DD_LIVEKIT_DOMAIN=*) printf 'DD_LIVEKIT_DOMAIN=rtc.%s\n' "$base_domain" ;;
    DD_TURN_DOMAIN=*) printf 'DD_TURN_DOMAIN=turn.%s\n' "$base_domain" ;;
    DD_S3_DOMAIN=*) printf 'DD_S3_DOMAIN=media.%s\n' "$base_domain" ;;
    DD_PUBLIC_IP=*) printf 'DD_PUBLIC_IP=%s\n' "$public_ip" ;;
    DD_ACME_EMAIL=*) printf 'DD_ACME_EMAIL=%s\n' "$acme_email" ;;
    DD_ALLOWED_ORIGINS=*) printf 'DD_ALLOWED_ORIGINS=%s\n' "$base_domain" ;;
    DD_ALLOWED_HTTP_ORIGINS=*) printf 'DD_ALLOWED_HTTP_ORIGINS=https://%s\n' "$base_domain" ;;
    DD_MEDIA_S3_ENDPOINT=*) printf 'DD_MEDIA_S3_ENDPOINT=https://media.%s\n' "$base_domain" ;;
    DD_MINIO_CORS_ORIGIN=*) printf 'DD_MINIO_CORS_ORIGIN=https://%s\n' "$base_domain" ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$template" > "$tmp"

chmod 600 "$tmp"
mv "$tmp" "$target"
trap - EXIT
log "created $target for $base_domain / $public_ip"
log "next: bash scripts/init-secrets.sh"
