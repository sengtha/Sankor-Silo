#!/usr/bin/env bash
# ============================================================================
# SANKOR silo — one-command installer. Picks a stack, generates the JWT secret
# + API keys, collects your hub/domain details, brings the stack up (applying
# the schema on first boot), and prints what to paste into the SANKOR admin.
#
#   ./install.sh
#
# Requires: docker + docker compose, openssl. Run again any time to (re)start;
# it reuses an existing .env.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/gen-keys.sh
source lib/gen-keys.sh

getenv() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2-; }

command -v docker >/dev/null || { echo "docker is required"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose v2 is required"; exit 1; }

echo "SANKOR silo installer"
echo "  1) minimal  (~1 GB RAM — Postgres + REST + functions + Caddy)   [recommended]"
echo "  2) full     (~3-4 GB RAM — adds Studio, GoTrue, Storage)"
read -rp "Choose a stack [1]: " choice
PROFILE="minimal"; [[ "${choice:-1}" == "2" ]] && PROFILE="full"

if [[ -f .env ]]; then
  echo "Found existing .env — reusing it."
else
  echo "Generating secrets…"
  SECRET="$(gen_secret)"
  {
    echo "JWT_SECRET=$SECRET"
    echo "ANON_KEY=$(mint_key "$SECRET" anon)"
    echo "SERVICE_ROLE_KEY=$(mint_key "$SECRET" service_role)"
    echo "POSTGRES_PASSWORD=$(gen_password)"
  } > .env

  read -rp "This silo's website id (from the SANKOR admin): " WID
  read -rp "SANKOR hub URL (e.g. https://hub.sankor.site): " HUB
  read -rp "SANKOR hub anon key: " HUBKEY
  read -rp "Public URL this silo will be served on (e.g. https://silo.example.com): " DOMAIN
  {
    echo "SANKOR_SITE_WEBSITE_ID=$WID"
    echo "SANKOR_HUB_URL=$HUB"
    echo "SANKOR_HUB_ANON_KEY=$HUBKEY"
    echo "SANKOR_TOKEN_TTL_SECONDS=900"
    echo "SILO_DOMAIN=$DOMAIN"
  } >> .env

  if [[ "$PROFILE" == "full" ]]; then
    read -rp "Studio admin username [admin]: " SU; SU="${SU:-admin}"
    read -rsp "Studio admin password: " SP; echo
    echo "Hashing Studio password…"
    HASH="$(docker run --rm caddy:2.8 caddy hash-password --plaintext "$SP")"
    { echo "STUDIO_USER=$SU"; printf 'STUDIO_PASSWORD_HASH=%s\n' "$HASH"; } >> .env
  fi
  chmod 600 .env
  echo "Wrote .env (keep it private)."
fi

echo "Starting the $PROFILE stack…"
docker compose -f "$PROFILE/docker-compose.yml" --env-file .env up -d

echo
echo "✓ SANKOR silo ($PROFILE) is starting. First boot applies the schema — give it a minute."
echo
echo "  Silo URL : $(getenv SILO_DOMAIN)"
echo "  Anon key : $(getenv ANON_KEY)"
echo
echo "Next: in the SANKOR admin → Connect your site, paste the Silo URL + Anon key above."
[[ "$PROFILE" == "full" ]] && echo "Studio admin UI: $(getenv SILO_DOMAIN)/  (user: $(getenv STUDIO_USER))"
echo "Logs: docker compose -f $PROFILE/docker-compose.yml --env-file .env logs -f"
