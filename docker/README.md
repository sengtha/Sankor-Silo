# Self-host a SANKOR silo with Docker

Run your SANKOR-BYOI silo on **any VM** with open-source Supabase — your data,
your infrastructure. One command brings up the database, the data API, and the
edge functions, applies the schema, and prints what to paste into the SANKOR
admin.

```bash
git clone https://github.com/sengtha/sankor-byoi.git
cd sankor-byoi/docker
./install.sh
```

## Choose your stack

The silo is **your** infrastructure, so you pick how much of Supabase to run.
Both use the exact same SANKOR schema + functions and the same security model —
they differ only in which Supabase services come along.

| | **minimal** (recommended) | **full** |
|---|---|---|
| Services | Postgres · PostgREST · Edge Runtime · Caddy | + GoTrue · Storage · postgres-meta · **Studio** |
| RAM | ~1 GB | ~3–4 GB |
| DB admin UI | psql / any client | **Supabase Studio** in the browser |
| File storage | Cloudflare R2 (as configured in SANKOR) | + Supabase Storage option |
| AI blogging agent schedule | ✗ (no pg_cron) | ✓ (`supabase/postgres` has pg_cron) |
| Best for | most sites — lean, cheap, small attack surface | teams that want Studio / Supabase Storage |

Everything the silo actually needs to serve content and authenticate the SANKOR
admin is in **minimal**. Pick **full** only if you specifically want Studio or
Supabase Storage.

## How the security model maps to self-hosting

Unchanged from the hosted setup — the silo mints its own short-lived HS256 JWTs
and validates them locally. The single invariant:

> **`JWT_SECRET` is the one value the whole silo trusts.** The
> `authenticate-sankor-user` function signs minted tokens with it, and PostgREST
> validates every request against it. The `ANON_KEY` / `SERVICE_ROLE_KEY` are
> HS256 JWTs derived from that same secret.

`install.sh` generates the secret once and wires it into every service, so this
is handled for you. The SANKOR hub still only holds single-use tickets — never a
key into your silo.

## Prerequisites

- A VM with **Docker + Docker Compose v2** (2 GB RAM for minimal, 4 GB for full).
- A **domain** pointed at the VM (Caddy gets a free Let's Encrypt cert for it).
  Ports **80/443** open. For local testing, set `SILO_DOMAIN=http://localhost`.

## Install

`./install.sh` will:
1. Ask minimal or full.
2. Generate `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY`, `POSTGRES_PASSWORD`
   (via `lib/gen-keys.sh`) into `.env`.
3. Prompt for your **website id**, **hub URL**, **hub anon key**, and this
   silo's **public URL** (full also asks for Studio admin credentials).
4. `docker compose up -d` — the schema is applied automatically on first boot.
5. Print your **Silo URL + Anon key** to register in the SANKOR admin.

Then, in the SANKOR admin → **Connect your site**, paste the Silo URL + Anon key.

### Unattended installs

Pass the answers up front and `install.sh` never prompts — this is how the
[**Deploy Silo**](../docs/Deploy-from-GitHub.md) GitHub Actions workflow drives
it. Prompting is also skipped automatically whenever stdin is not a terminal.

```bash
./install.sh --non-interactive --profile minimal \
  --domain https://silo.example.com --website-id <uuid> \
  --hub-url https://hub.sankor.site --hub-anon-key <key>
```

Every flag has an environment-variable equivalent (`SILO_DOMAIN`,
`SANKOR_SITE_WEBSITE_ID`, `SANKOR_HUB_URL`, `SANKOR_HUB_ANON_KEY`,
`SANKOR_PROFILE`, `STUDIO_PASSWORD`, …) — run `./install.sh --help` for the full
list. A missing required value is a clean error, never a hung prompt.

To deploy from a **fresh VM in one command** (installs Docker, clones the repo,
then runs this installer), use the repo-root bootstrap instead — see
[Deploy a silo from GitHub](../docs/Deploy-from-GitHub.md).

## Verify it's healthy

After the stack boots (~1 min), run the health check:

```bash
./doctor.sh minimal        # or: full
```

It confirms, green/red: containers running, schema applied, the data API
reachable, a **freshly-minted token is accepted** (proving `JWT_SECRET` == the
mint secret), and the edge function responding. Exits non-zero if anything's off.

## Day 2

```bash
# logs
docker compose -f minimal/docker-compose.yml --env-file .env logs -f

# update schema + images (data is preserved)
./update.sh minimal        # or: full

# stop / start
docker compose -f minimal/docker-compose.yml --env-file .env down
./install.sh

# back up the database
docker compose -f minimal/docker-compose.yml --env-file .env exec -T db \
  pg_dump -U postgres postgres | gzip > silo-backup-$(date +%F).sql.gz
```

## Files

```
docker/
  install.sh          installer, both stacks (interactive or --non-interactive)
  doctor.sh           post-boot health check (containers, schema, API, JWT, fn)
  update.sh           re-apply schema + pull images
  .env.example        every setting, documented
  lib/gen-keys.sh     JWT secret + anon/service key generation (openssl)
  functions/main/     edge-runtime router (dispatches to the two functions)
  minimal/            docker-compose.yml · Caddyfile · init/ (roles + auth shim)
  full/               docker-compose.yml · Caddyfile · init/ (roles + JWT settings)
```

Both stacks mount the repo's real assets — `supabase/setup/schema/*.sql` and
`supabase/setup/functions/*` — so the self-hosted silo runs the identical schema
and functions as a hosted one.

## Verification status

The **minimal** stack's database path — roles, the `auth` shim, and the full
1,600-line SANKOR schema (41 tables, RLS on 39) — has been verified to apply
cleanly on Postgres 16 + pgvector. Both compose files pass `docker compose
config`. The **full** stack (≈8 services) follows Supabase's canonical
self-hosting layout; smoke-test it on your VM after the first `up` and check
`docker compose ps` shows every service healthy.
