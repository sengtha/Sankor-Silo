#!/usr/bin/env bash
# ============================================================================
# SANKOR silo — health check. Run after install.sh to confirm the silo is
# actually serving: containers up, schema applied, the data API reachable, the
# JWT-secret coupling correct, and the edge function responding.
#
#   ./doctor.sh [minimal|full]
#
# Exits 0 if everything is green, non-zero otherwise.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/gen-keys.sh
source lib/gen-keys.sh

PROFILE="${1:-minimal}"
COMPOSE="$PROFILE/docker-compose.yml"
[[ -f "$COMPOSE" ]] || { echo "unknown profile: $PROFILE (use minimal|full)"; exit 1; }
[[ -f .env ]]       || { echo "no .env — run ./install.sh first"; exit 1; }

getenv() { grep -E "^$1=" .env | head -1 | cut -d= -f2-; }
DOMAIN="$(getenv SILO_DOMAIN)"; DOMAIN="${DOMAIN%/}"
ANON="$(getenv ANON_KEY)"
SECRET="$(getenv JWT_SECRET)"

pass=0; fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }

dc() { docker compose -f "$COMPOSE" --env-file .env "$@"; }

echo "SANKOR silo doctor · $PROFILE · $DOMAIN"

# 1. Containers running / healthy.
echo "Containers:"
while read -r name state; do
  [[ -z "$name" ]] && continue
  if [[ "$state" == running* || "$state" == *healthy* ]]; then ok "$name ($state)"; else no "$name ($state)"; fi
done < <(dc ps --format '{{.Service}} {{.State}}' 2>/dev/null)

# 2. Schema applied.
echo "Database:"
if dc exec -T db psql -U postgres -d postgres -tAc "select to_regclass('public.byoi_config') is not null" 2>/dev/null | grep -q t; then
  ok "schema applied (byoi_config present)"
else
  no "schema not found — check first-boot logs: dc logs db"
fi

# 3. Data API reachable + the anon key validates (proves the JWT_SECRET coupling).
echo "API:"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$DOMAIN/rest/v1/" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" 2>/dev/null || true)"; code="${code:-000}"
[[ "$code" == 200 ]] && ok "PostgREST reachable; anon key accepted" || no "GET /rest/v1/ → $code"

# 4. A freshly-minted token (signed with the .env secret right now) is accepted —
#    explicit proof that the mint secret equals the DB's JWT secret.
fresh="$(mint_key "$SECRET" anon)"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$DOMAIN/rest/v1/" \
  -H "apikey: $fresh" -H "Authorization: Bearer $fresh" 2>/dev/null || true)"; code="${code:-000}"
[[ "$code" == 200 ]] && ok "freshly-minted token accepted (mint secret == DB JWT secret)" || no "minted token rejected → $code"

# 5. Edge function is serving (empty ticket → the function's own 4xx, not a gateway 5xx).
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST \
  "$DOMAIN/functions/v1/authenticate-sankor-user" -H "Content-Type: application/json" -d '{}' 2>/dev/null || true)"; code="${code:-000}"
case "$code" in
  000)          no "edge function unreachable (timeout / DNS / gateway)";;
  502|503|504)  no "gateway can't reach edge-runtime ($code)";;
  *)            ok "edge function responding (HTTP $code to an empty ticket)";;
esac

echo
if [[ $fail -eq 0 ]]; then
  printf '\033[32mAll %d checks passed — the silo is ready. Register %s + the anon key in the SANKOR admin.\033[0m\n' "$pass" "$DOMAIN"
  exit 0
else
  printf '\033[31m%d passed, %d failed.\033[0m Logs: docker compose -f %s --env-file .env logs\n' "$pass" "$fail" "$COMPOSE"
  exit 1
fi
