#!/usr/bin/env bash
# ============================================================================
# SANKOR silo — secret + API-key generation.
#
# The silo's whole auth model rests on ONE value: the JWT secret. The
# authenticate-sankor-user function signs minted tokens with it, and PostgREST
# validates every request (anon key + minted tokens) against it. So the API
# keys below are HS256 JWTs derived from that same secret — regenerate them and
# the JWT secret together, never independently.
#
# Requires: openssl. Source this file, or run it to print a fresh block.
# ============================================================================
set -euo pipefail

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# A fresh JWT secret (also used as the silo's minting secret).
gen_secret() { openssl rand -base64 48 | tr -d '\n'; }

# A random password (Postgres, etc.) with no shell-hostile characters.
gen_password() { openssl rand -hex 24; }

# mint_key <secret> <role>  →  a long-lived HS256 JWT carrying that role.
# Used for the anon (public site) and service_role keys, exactly like Supabase's.
mint_key() {
  local secret="$1" role="$2" now exp header payload signing sig
  now="$(date +%s)"
  exp="$(( now + 60 * 60 * 24 * 365 * 10 ))"   # ~10 years
  header='{"alg":"HS256","typ":"JWT"}'
  payload="$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$role" "$now" "$exp")"
  signing="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
  sig="$(printf '%s' "$signing" | openssl dgst -sha256 -hmac "$secret" -binary | b64url)"
  printf '%s.%s' "$signing" "$sig"
}

# Print a ready-to-paste .env block when run directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  SECRET="$(gen_secret)"
  echo "JWT_SECRET=$SECRET"
  echo "ANON_KEY=$(mint_key "$SECRET" anon)"
  echo "SERVICE_ROLE_KEY=$(mint_key "$SECRET" service_role)"
  echo "POSTGRES_PASSWORD=$(gen_password)"
fi
