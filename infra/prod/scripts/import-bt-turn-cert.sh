#!/usr/bin/env bash
set -Eeuo pipefail
# This helper is intentionally retained as a guard for operators who may have
# seen the first BaoTa deployment draft. The supported bt-nginx topology does
# NOT use embedded TURN/TLS: LiveKit browser clients require the public
# TURN/TLS endpoint on TCP 443 unless a deliberate L4 load balancer/SNI design
# is introduced. BaoTa/Nginx already owns TCP 443, so importing a TURN cert
# would be misleading rather than useful.
printf '[dd-prod] ERROR: bt-nginx mode intentionally disables embedded TURN/TLS; no TURN certificate import is required.\n' >&2
exit 1
