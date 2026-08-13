#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

load_prod_env
turn_domain="${1:-${DD_TURN_DOMAIN:-}}"
[[ -n "$turn_domain" ]] || fail "usage: import-bt-turn-cert.sh [turn-domain]"

bt_cert_root="${BT_CERT_ROOT:-/www/server/panel/vhost/cert}"
source_dir="$bt_cert_root/$turn_domain"
source_cert="$source_dir/fullchain.pem"
source_key="$source_dir/privkey.pem"

[[ -s "$source_cert" ]] || fail "BaoTa certificate not found: $source_cert"
[[ -s "$source_key" ]] || fail "BaoTa private key not found: $source_key"

mkdir -p "$PROD_DIR/secrets"
install -m 0644 "$source_cert" "$PROD_DIR/secrets/turn_cert.pem"
install -m 0600 "$source_key" "$PROD_DIR/secrets/turn_key.pem"

openssl x509 -in "$PROD_DIR/secrets/turn_cert.pem" -noout -checkhost "$turn_domain" >/dev/null \
  || fail "imported certificate does not cover $turn_domain"

log "imported BaoTa TURN certificate for $turn_domain"
log "after BaoTa renews this certificate, rerun this script and: bash scripts/restart.sh livekit"
