#!/usr/bin/env bash
# ============================================================================
# SANKOR silo — update. Pulls the latest schema (git) and re-applies it (the
# SANKOR SQL is idempotent), pulls newer images, and restarts. Your data in the
# db-data volume is preserved.
#
#   ./update.sh [minimal|full]
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
PROFILE="${1:-minimal}"
COMPOSE="$PROFILE/docker-compose.yml"
[[ -f "$COMPOSE" ]] || { echo "unknown profile: $PROFILE"; exit 1; }
[[ -f .env ]] || { echo "no .env — run ./install.sh first"; exit 1; }

echo "Pulling latest silo repo…"
git -C .. pull --ff-only || echo "(skip git pull — not a clean checkout)"

echo "Re-applying schema (idempotent)…"
docker compose -f "$COMPOSE" --env-file .env exec -T db \
  psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -f - < ../supabase/setup/schema/sankor_content_schema.sql
docker compose -f "$COMPOSE" --env-file .env exec -T db \
  psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -f - < ../supabase/setup/schema/sankor_byoi_schema.sql

echo "Pulling images + restarting…"
docker compose -f "$COMPOSE" --env-file .env pull
docker compose -f "$COMPOSE" --env-file .env up -d

echo "✓ Updated."
