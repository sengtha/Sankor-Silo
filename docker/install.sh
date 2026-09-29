#!/usr/bin/env bash
# ============================================================================
# SANKOR silo — one-command installer. Picks a stack, generates the JWT secret
# + API keys, collects your hub/domain details, brings the stack up (applying
# the schema on first boot), and prints what to paste into the SANKOR admin.
#
#   ./install.sh                    interactive — prompts for everything
#
# Unattended (CI, GitHub Actions, cloud-init) — pass the answers up front:
#
#   ./install.sh --non-interactive --profile minimal \
#     --domain https://silo.example.com --website-id <uuid> \
#     --hub-url https://hub.sankor.site --hub-anon-key <key>
#
# Prompting is skipped automatically when stdin is not a terminal, so piping
# the script into bash behaves the same as passing --non-interactive.
#
# Options (each has an env-var equivalent, so the deploy workflow can pass
# everything through the environment instead of the command line):
#   --profile <minimal|full>  stack to run                 SANKOR_PROFILE
#   --domain <url>            public URL of this silo      SILO_DOMAIN
#   --website-id <uuid>       website id from the admin    SANKOR_SITE_WEBSITE_ID
#   --hub-url <url>           SANKOR hub URL               SANKOR_HUB_URL
#   --hub-anon-key <key>      hub anon key (redeem RPC)    SANKOR_HUB_ANON_KEY
#   --ttl <seconds>           minted-token lifetime        SANKOR_TOKEN_TTL_SECONDS
#   --studio-user <name>      full stack: Studio login     STUDIO_USER
#   --studio-password <pw>    full stack: Studio password  STUDIO_PASSWORD
#   --non-interactive, -y     never prompt; fail if a required value is missing
#   --force                   rotate ALL secrets (backs up the existing .env)
#   -h, --help                show this header
#
# Optional feature keys are read from the environment and written into .env:
#   GEMINI_API_KEY, AI_AGENT_CRON_SECRET,
#   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET, R2_PUBLIC_URL
#
# Requires: docker + docker compose, openssl. Run again any time to (re)start;
# it reuses an existing .env.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/gen-keys.sh
source lib/gen-keys.sh

die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Seed every answer from the environment; flags below win over them.
PROFILE="${SANKOR_PROFILE:-}"
DOMAIN="${SILO_DOMAIN:-}"
WID="${SANKOR_SITE_WEBSITE_ID:-}"
HUB="${SANKOR_HUB_URL:-}"
HUBKEY="${SANKOR_HUB_ANON_KEY:-}"
TTL="${SANKOR_TOKEN_TTL_SECONDS:-900}"
SU="${STUDIO_USER:-}"
SP="${STUDIO_PASSWORD:-}"
FORCE=""
# No terminal on stdin (piped installer, CI) → never block on a prompt.
NON_INTERACTIVE=""
[[ -t 0 ]] || NON_INTERACTIVE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)          PROFILE="$2"; shift 2 ;;
    --domain)           DOMAIN="$2";  shift 2 ;;
    --website-id)       WID="$2";     shift 2 ;;
    --hub-url)          HUB="$2";     shift 2 ;;
    --hub-anon-key)     HUBKEY="$2";  shift 2 ;;
    --ttl)              TTL="$2";     shift 2 ;;
    --studio-user)      SU="$2";      shift 2 ;;
    --studio-password)  SP="$2";      shift 2 ;;
    --non-interactive|-y) NON_INTERACTIVE=1; shift ;;
    --force)            FORCE=1;      shift ;;
    -h|--help) grep '^#' "$0" | tail -n +2 | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

command -v docker >/dev/null || die "docker is required"
docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"

# ask <current> <prompt> <name> → the value, prompting only when we may.
# Dies (aborting the assignment, thanks to set -e) if unattended and unset.
ask() {
  local current="$1" prompt="$2" name="$3" ans
  if [[ -n "$current" ]]; then printf '%s' "$current"; return 0; fi
  [[ -z "$NON_INTERACTIVE" ]] || die "missing $name — pass --${name} or set it in the environment (see --help)"
  read -rp "$prompt" ans </dev/tty
  printf '%s' "$ans"
}

# setenv <key> <value> — upsert into .env, tolerating any characters in value.
setenv() {
  local key="$1" val="${2:-}"
  [[ -n "$val" ]] || return 0
  if grep -qE "^${key}=" .env 2>/dev/null; then
    grep -vE "^${key}=" .env > .env.tmp
    printf '%s=%s\n' "$key" "$val" >> .env.tmp
    mv .env.tmp .env
  else
    printf '%s=%s\n' "$key" "$val" >> .env
  fi
}

getenv() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2-; }

echo "SANKOR silo installer"
if [[ -z "$PROFILE" ]]; then
  if [[ -n "$NON_INTERACTIVE" ]]; then
    PROFILE="minimal"
  else
    echo "  1) minimal  (~1 GB RAM — Postgres + REST + functions + Caddy)   [recommended]"
    echo "  2) full     (~3-4 GB RAM — adds Studio, GoTrue, Storage)"
    read -rp "Choose a stack [1]: " choice
    PROFILE="minimal"; [[ "${choice:-1}" == "2" ]] && PROFILE="full"
  fi
fi
[[ "$PROFILE" == "minimal" || "$PROFILE" == "full" ]] || die "unknown profile: $PROFILE (use minimal|full)"

# Everything written from here on (.env, .env.tmp, backups) holds secrets:
# create it private from the start rather than chmod-ing afterwards.
OLD_UMASK="$(umask)"
umask 077

if [[ -f .env && -z "$FORCE" ]]; then
  echo "Found existing .env — reusing it."
  # A redeploy may still move the silo to a new domain or re-point it at the
  # hub, so apply anything explicitly supplied this run.
  setenv SANKOR_SITE_WEBSITE_ID "$WID"
  setenv SANKOR_HUB_URL         "$HUB"
  setenv SANKOR_HUB_ANON_KEY    "$HUBKEY"
  setenv SILO_DOMAIN            "$DOMAIN"
else
  if [[ -f .env ]]; then
    BAK=".env.bak.$(date +%Y%m%d%H%M%S)"
    cp .env "$BAK"
    echo "--force: rotating ALL secrets (previous .env saved as $BAK)."
    echo "Note: the new ANON_KEY must be re-registered in the SANKOR admin."
  fi

  # Collect what we need BEFORE writing anything, so an unattended run that is
  # missing an answer fails without leaving a half-written .env behind.
  WID="$(ask "$WID" "This silo's website id (from the SANKOR admin): " website-id)"
  HUB="$(ask "$HUB" "SANKOR hub URL (e.g. https://hub.sankor.site): " hub-url)"
  HUBKEY="$(ask "$HUBKEY" "SANKOR hub anon key: " hub-anon-key)"
  DOMAIN="$(ask "$DOMAIN" "Public URL this silo will be served on (e.g. https://silo.example.com): " domain)"

  if [[ "$PROFILE" == "full" ]]; then
    if [[ -z "$SU" && -z "$NON_INTERACTIVE" ]]; then
      read -rp "Studio admin username [admin]: " SU
    fi
    SU="${SU:-admin}"
    if [[ -z "$SP" ]]; then
      [[ -z "$NON_INTERACTIVE" ]] || die "the full stack needs a Studio password — pass --studio-password or set STUDIO_PASSWORD"
      read -rsp "Studio admin password: " SP </dev/tty; echo
    fi
  fi

  echo "Generating secrets…"
  SECRET="$(gen_secret)"
  {
    echo "JWT_SECRET=$SECRET"
    echo "ANON_KEY=$(mint_key "$SECRET" anon)"
    echo "SERVICE_ROLE_KEY=$(mint_key "$SECRET" service_role)"
    echo "POSTGRES_PASSWORD=$(gen_password)"
    echo "SANKOR_SITE_WEBSITE_ID=$WID"
    echo "SANKOR_HUB_URL=$HUB"
    echo "SANKOR_HUB_ANON_KEY=$HUBKEY"
    echo "SANKOR_TOKEN_TTL_SECONDS=$TTL"
    echo "SILO_DOMAIN=$DOMAIN"
  } > .env

  if [[ "$PROFILE" == "full" ]]; then
    echo "Hashing Studio password…"
    # Password on stdin, not argv (visible in `ps` and Docker's logs).
    HASH="$(printf '%s\n' "$SP" | docker run --rm -i caddy:2.8 caddy hash-password)"
    { echo "STUDIO_USER=$SU"; printf 'STUDIO_PASSWORD_HASH=%s\n' "$HASH"; } >> .env
  fi
  echo "Wrote .env (keep it private)."
fi

# Optional feature keys, supplied via the environment on either path.
if [[ -n "${GEMINI_API_KEY:-}${AI_AGENT_CRON_SECRET:-}${R2_ACCOUNT_ID:-}${R2_ACCESS_KEY_ID:-}${R2_SECRET_ACCESS_KEY:-}${R2_BUCKET:-}${R2_PUBLIC_URL:-}" ]]; then
  echo "Applying optional feature keys from the environment…"
  setenv GEMINI_API_KEY       "${GEMINI_API_KEY:-}"
  setenv AI_AGENT_CRON_SECRET "${AI_AGENT_CRON_SECRET:-}"
  setenv R2_ACCOUNT_ID        "${R2_ACCOUNT_ID:-}"
  setenv R2_ACCESS_KEY_ID     "${R2_ACCESS_KEY_ID:-}"
  setenv R2_SECRET_ACCESS_KEY "${R2_SECRET_ACCESS_KEY:-}"
  setenv R2_BUCKET            "${R2_BUCKET:-}"
  setenv R2_PUBLIC_URL        "${R2_PUBLIC_URL:-}"
fi
chmod 600 .env
umask "$OLD_UMASK"

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
echo
echo "Once it's booted (~1 min), check everything is healthy:"
echo "  ./doctor.sh $PROFILE"
echo "Logs: docker compose -f $PROFILE/docker-compose.yml --env-file .env logs -f"
