#!/usr/bin/env bash
#
# SANKOR silo — remote bootstrap installer.
#
# Stands up a complete silo on a fresh Linux VM straight from GitHub: installs
# Docker, clones this repository, generates all secrets, and brings the stack
# up behind automatic HTTPS. You run it on YOUR server — the silo, its database
# and its keys stay entirely under your control.
#
# Usage (on a fresh Ubuntu/Debian VM, as root or with sudo):
#
#   curl -fsSL https://raw.githubusercontent.com/sengtha/sankor-byoi/main/install.sh \
#     | sudo bash -s -- --domain silo.example.com \
#         --website-id <uuid> --hub-url https://hub.sankor.site --hub-anon-key <key>
#
# Re-running updates an existing install in place (git pull + recreate) and
# keeps your secrets. The GitHub Actions "Deploy Silo" workflow runs exactly
# this script over SSH.
#
# Options:
#   --domain <url|host>   Public address of the silo (required; DNS A record → this VM).
#                         A bare hostname is upgraded to https://.
#   --website-id <uuid>   This silo's website id, from the SANKOR admin (required on
#                         a first install).
#   --hub-url <url>       SANKOR hub URL (default: https://hub.sankor.site).
#   --hub-anon-key <key>  The hub's anon key, used only for the redeem RPC
#                         (required on a first install).
#   --profile <name>      Stack to run: minimal (default) or full.
#   --studio-user <name>  Full stack only: Studio admin username (default: admin).
#   --studio-password <p> Full stack only: Studio admin password (required for --profile full).
#   --ttl <seconds>       Minted-token lifetime (default: 900).
#   --repo <owner/repo>   GitHub repo to install from (default: sengtha/sankor-byoi).
#   --branch <name>       Branch to install (default: main).
#   --dir <path>          Install directory (default: /opt/sankor-silo). Env: SANKOR_INSTALL_DIR.
#   --force               Regenerate .env even if it exists (rotates ALL secrets;
#                         the new ANON_KEY must be re-registered in the admin).
#   -h, --help            Show this header.
#
# Optional feature keys may be supplied as environment variables and are written
# into .env automatically: GEMINI_API_KEY, AI_AGENT_CRON_SECRET, R2_ACCOUNT_ID,
# R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET, R2_PUBLIC_URL. With
# `curl | sudo bash` put them on the sudo, e.g. `| sudo GEMINI_API_KEY=… bash -s -- …`.

set -euo pipefail

REPO="sengtha/sankor-byoi"
BRANCH="main"
DIR="${SANKOR_INSTALL_DIR:-/opt/sankor-silo}"
DOMAIN="${SILO_DOMAIN:-}"
WEBSITE_ID="${SANKOR_SITE_WEBSITE_ID:-}"
HUB_URL="${SANKOR_HUB_URL:-https://hub.sankor.site}"
HUB_ANON_KEY="${SANKOR_HUB_ANON_KEY:-}"
PROFILE="${SANKOR_PROFILE:-minimal}"
STUDIO_USER_IN="${STUDIO_USER:-}"
STUDIO_PASSWORD_IN="${STUDIO_PASSWORD:-}"
TTL="${SANKOR_TOKEN_TTL_SECONDS:-900}"
FORCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)          DOMAIN="$2";             shift 2 ;;
    --website-id)      WEBSITE_ID="$2";         shift 2 ;;
    --hub-url)         HUB_URL="$2";            shift 2 ;;
    --hub-anon-key)    HUB_ANON_KEY="$2";       shift 2 ;;
    --profile)         PROFILE="$2";            shift 2 ;;
    --studio-user)     STUDIO_USER_IN="$2";     shift 2 ;;
    --studio-password) STUDIO_PASSWORD_IN="$2"; shift 2 ;;
    --ttl)             TTL="$2";                shift 2 ;;
    --repo)            REPO="$2";               shift 2 ;;
    --branch)          BRANCH="$2";             shift 2 ;;
    --dir)             DIR="$2";                shift 2 ;;
    --force)           FORCE="--force";         shift ;;
    -h|--help) grep '^#' "$0" | tail -n +2 | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ -n "$DOMAIN" ] || die "A domain is required: --domain silo.example.com"
# The Caddyfile uses SILO_DOMAIN as its site address: a bare host gets automatic
# HTTPS, so normalise to an explicit https:// URL (leave http:// alone — that is
# how local testing opts out of TLS).
case "$DOMAIN" in
  http://*|https://*) ;;
  *) DOMAIN="https://${DOMAIN}" ;;
esac

# Need root to install Docker and write under /opt. Every documented path pipes
# into `sudo bash`, so just require it (avoids a fragile re-exec when the script
# is read from stdin).
if [ "$(id -u)" -ne 0 ]; then
  die "Please run as root — prepend sudo, e.g.
    curl -fsSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh | sudo bash -s -- --domain ${DOMAIN}"
fi

# --- 1. Docker -------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker…"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 \
  || die "Docker Compose v2 is required (the Docker install above normally includes it)."
systemctl enable --now docker >/dev/null 2>&1 || true

# --- 2. Source -------------------------------------------------------------
if [ -d "$DIR/.git" ]; then
  log "Updating existing install at $DIR…"
  git -C "$DIR" fetch --depth 1 origin "$BRANCH"
  git -C "$DIR" checkout -q "$BRANCH" 2>/dev/null || git -C "$DIR" checkout -q -B "$BRANCH" "origin/$BRANCH"
  git -C "$DIR" reset --hard "origin/$BRANCH"
else
  log "Cloning $REPO ($BRANCH) → $DIR…"
  command -v git >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq git; }
  git clone --depth 1 --branch "$BRANCH" "https://github.com/${REPO}.git" "$DIR"
fi

# --- 3. Hand off to the stack installer ------------------------------------
# It generates the JWT secret + API keys, writes .env and brings the stack up.
# Everything is passed explicitly, and --non-interactive makes a missing answer
# a clean failure rather than a hung prompt.
log "Installing the $PROFILE stack for $DOMAIN…"
set -- --non-interactive --profile "$PROFILE" --domain "$DOMAIN" --ttl "$TTL"
[ -n "$WEBSITE_ID" ]         && set -- "$@" --website-id "$WEBSITE_ID"
[ -n "$HUB_URL" ]            && set -- "$@" --hub-url "$HUB_URL"
[ -n "$STUDIO_USER_IN" ]     && set -- "$@" --studio-user "$STUDIO_USER_IN"
# Secrets go through the environment, not argv: command lines are visible to
# every local user in `ps`.
[ -n "$HUB_ANON_KEY" ]       && export SANKOR_HUB_ANON_KEY="$HUB_ANON_KEY"
[ -n "$STUDIO_PASSWORD_IN" ] && export STUDIO_PASSWORD="$STUDIO_PASSWORD_IN"
[ -n "$FORCE" ]              && set -- "$@" "$FORCE"

bash "$DIR/docker/install.sh" "$@"

log "Done. Health check: cd $DIR/docker && ./doctor.sh $PROFILE"
