# SANKOR-BYOI

Bring-Your-Own-Infrastructure node for **SANKOR iCMS**. Deploy this on your own
Supabase project to host your site's content under your sole control, and
connect securely to the SANKOR hub.

SANKOR connects to your database using **short-lived JWTs you mint yourself** —
never a shared service account, and never a key the hub can use on its own. The
hub can only hand out single-use tickets; the token that actually grants access
is signed *inside your project* with a secret the hub never sees.

---

## Architecture

```
  SANKOR app (browser)            SANKOR hub (Supabase)         Your silo (Supabase)
  ───────────────────             ─────────────────────         ────────────────────
  signed-in user
        │  issue_byoi_ticket(website_id)
        ├──────────────────────────────▶  validates ownership
        │                                 inserts single-use ticket
        │  ◀── ticket_id ──────────────
        │
        │  POST /functions/v1/authenticate-sankor-user { ticket_id }
        ├───────────────────────────────────────────────────────────▶  edge fn
        │                                  redeem_byoi_ticket          │
        │                                ◀──────────────────────────── │  (learns
        │                                 ──── claims ───────────────▶ │   identity)
        │                                                              │  mints HS256
        │  ◀── access_token (≤15 min) ──────────────────────────────── │  JWT
        │
        │  Supabase client with accessToken: () => token
        └───────────────────────────────────────────────────────────▶  RLS-gated data
```

**Two audiences, two access paths:**
- **Authoring** (the SANKOR admin) uses the minted JWT above — full read/write,
  pinned by RLS to this silo's one `website_id`.
- **The public website** is served with this silo's **anon key** (no JWT). RLS
  exposes only *published* content to anonymous visitors and lets them submit
  forms / orders / bookings — nothing else.

A token minted for one site cannot read another site's silo. The hub holds
tickets, not keys; the silo holds the signing secret.

---

## What's in this repo

```
install.sh                                     one-command install on a fresh VM
                                               (Docker + clone + stack; used by CI)
.github/workflows/deploy-silo.yml              "Deploy Silo" — deploy/update over
                                               SSH from your own fork
docker/                                        self-hosted stack — see docker/README.md
docs/Deploy-from-GitHub.md                     all the deployment paths, in full
supabase/
  config.toml                                  CLI config (both functions: verify_jwt off)
  setup/
    schema/
      sankor_content_schema.sql   (step 3.1)   content tables (fresh-silo, dependency-ordered)
      sankor_byoi_schema.sql      (step 3.2)   BYOI overlay: anchor, JWT helpers, RLS,
                                               public access, AI-agent config + schedule
    functions/
      .env.example                             edge-function secret template
      authenticate-sankor-user/    (required)  ticket → mint silo JWT
      ai-agent-run/                (optional)  scheduled AI blogging, runs in-silo
```

---

## Deploy

Two routes to a running silo — both keep the database and its keys entirely
under your control:

| Route | Best for | Start here |
|---|---|---|
| **Self-hosted Docker stack** on your own VM | Full sovereignty, one command, no Supabase account | [Deploy a silo from GitHub](docs/Deploy-from-GitHub.md) |
| **Managed Supabase project** | You already run Supabase (cloud or self-hosted) | The setup checklist below |

For the Docker route you can install straight from this repo:

```bash
curl -fsSL https://raw.githubusercontent.com/sengtha/sankor-byoi/main/install.sh \
  | sudo bash -s -- --domain silo.example.com \
      --website-id <uuid> --hub-anon-key <hub-anon-key>
```

…or fork this repo, add your `SSH_*` secrets, and run the **Deploy Silo**
workflow (**Actions → Deploy Silo → Run workflow**) to deploy and update the
same stack over SSH from your fork. Both paths are documented in
[docs/Deploy-from-GitHub.md](docs/Deploy-from-GitHub.md).

---

## Setup checklist

### 1. Create a Supabase project
Cloud (supabase.com) or self-hosted. HS256 self-signing works on both.

### 2. Choose a signing key slot
You provide an HS256 secret yourself. Generate one:

```bash
openssl rand -base64 48
```

Pick one slot (the edge function supports both):

- **A. Legacy JWT Secret (simplest)** — Dashboard → **Settings → JWT Keys →
  Legacy JWT Secret** → set this value. Leave `SANKOR_SITE_JWT_KID` unset.
- **B. JWT Signing Keys / shared secret (future-proof)** — **Settings → JWT
  Keys → JWT Signing Keys → Create Standby Key**, choose *shared secret*, paste
  the value, then **Rotate** to make it current. Copy its **Key ID** and set it
  as `SANKOR_SITE_JWT_KID` in step 5. Do **not** revoke the key while tokens
  rely on it.

### 3. Import the schema (SQL editor, in order)

Enable the required extensions first (Dashboard → **Database → Extensions**):
`pgcrypto`, `uuid-ossp`, `vector`. For the optional AI agent also enable
`pg_cron` and `pg_net`.

1. **`supabase/setup/schema/sankor_content_schema.sql`** — the content tables,
   adapted for a fresh silo (dependency-ordered; hub-only tables/FKs removed).
2. **`supabase/setup/schema/sankor_byoi_schema.sql`** — the BYOI overlay: site
   anchor, JWT claim helpers, website-scoped RLS, **public (anon) read + submit
   policies for the live site**, and the optional AI-agent config + schedule.
   Idempotent and guarded — safe to re-run; the AI-agent schedule is skipped
   cleanly if `pg_cron` isn't enabled.

Both files only touch tables that exist, so they apply the same whether or not
you use every module.

**Shortcut (psql/CLI only):** run both in one go with
`bootstrap.sql` — it `\ir`-includes the two files in order:

```bash
psql "postgresql://postgres:<pw>@db.<ref>.supabase.co:5432/postgres" \
     -v ON_ERROR_STOP=1 -f supabase/setup/schema/bootstrap.sql
```

(The Supabase **SQL editor** can't run `bootstrap.sql` — it doesn't support
`\ir` — so there, paste the two files yourself in the order above.)

### 4. Seed this silo's identity
At the bottom of `sankor_byoi_schema.sql` (section 5) there's a commented
template. Run it once with your real `website_id` (from the hub) and hub URL:

```sql
insert into public.byoi_config (website_id, hub_url)
values ('<YOUR-WEBSITE-UUID>', 'https://<hub-ref>.supabase.co')
on conflict (singleton) do update
  set website_id = excluded.website_id, hub_url = excluded.hub_url;

insert into public.websites (id, name, status)
values ('<YOUR-WEBSITE-UUID>', 'My SANKOR Site', 'active')
on conflict (id) do update set status = 'active';
```

### 5. Set edge-function secrets
Copy `supabase/setup/functions/.env.example` → `.env`, fill it in, then:

```bash
supabase secrets set --env-file supabase/setup/functions/.env
```

(or set them in Dashboard → **Edge Functions → Manage Secrets**). Required for
`authenticate-sankor-user`: `SANKOR_SITE_JWT_SECRET`, `SANKOR_SITE_WEBSITE_ID`,
`SANKOR_HUB_URL`, `SANKOR_HUB_ANON_KEY` (+ `SANKOR_SITE_JWT_KID` for slot B).

### 6. Deploy the edge function(s)

```bash
supabase functions deploy authenticate-sankor-user
```

`config.toml` already sets `verify_jwt = false` for it (the ticket exchange must
be reachable before any Supabase session exists). If you deploy from the
Dashboard instead, set **Verify JWT → OFF** in its settings.

### 7. Register with the SANKOR hub
In the SANKOR admin, add this silo's Supabase **URL** and **anon key**. SANKOR
validates the link by performing a live ticket exchange (step 8 below runs
automatically as part of this).

### 8. Verify
- **Auth bridge:** the hub's "connect silo" flow should report success (it does
  a real ticket → redeem → mint round-trip).
- **Public site:** open your public site — published posts, products, pages,
  team, gallery, newsroom, etc. should render (they're served with the anon
  key). If the page is empty, re-check that step 3.2 applied without error.

---

## Environment variables

Which variables you set depends on **how you run the silo**. Both paths share
the same four "identity + hub link" values; the Docker path adds a generated key
set and a couple of hosting bits. Keep every `.env` **out of git**.

Legend: ✅ required · ⬜ optional · ⚙️ only if you enable the AI blogging agent.

### A. Manual Supabase project — edge-function secrets

Set on your silo project (**Dashboard → Edge Functions → Manage Secrets**, or
`supabase secrets set --env-file supabase/setup/functions/.env`).
Template: [`supabase/setup/functions/.env.example`](supabase/setup/functions/.env.example).

| Variable | | What it is / where to get it |
|---|---|---|
| `SANKOR_SITE_JWT_SECRET` | ✅ | HS256 secret that signs minted silo tokens. Generate with `openssl rand -base64 48`; this exact value must also be the project's JWT secret (§2). |
| `SANKOR_SITE_WEBSITE_ID` | ✅ | This silo's website id (uuid) from the SANKOR hub. Must equal `byoi_config.website_id` (§4). |
| `SANKOR_HUB_URL` | ✅ | The SANKOR hub's Supabase URL, e.g. `https://xxxx.supabase.co`. |
| `SANKOR_HUB_ANON_KEY` | ✅ | The hub's anon / publishable key (used only to call the redeem RPC). |
| `SANKOR_SITE_JWT_KID` | ⬜ | Only for the "JWT Signing Keys" slot (§2, option B): the shared-secret key's **Key ID**. Leave empty to use the Legacy JWT Secret slot. |
| `SANKOR_TOKEN_TTL_SECONDS` | ⬜ | Minted-token lifetime in seconds (default `900` = 15 min). |
| `GEMINI_API_KEY` | ⚙️ | Your own Gemini API key (true BYOI). |
| `AI_AGENT_CRON_SECRET` | ⚙️ | Shared secret; must match the value in the `pg_cron` schedule. |
| `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`, `R2_PUBLIC_URL` | ⚙️ | Cloudflare R2 for AI cover images. Leave unset to skip covers. |

### B. Docker self-host — `docker/.env`

`./docker/install.sh` writes most of these for you.
Template: [`docker/.env.example`](docker/.env.example).

**Generated by `lib/gen-keys.sh` — never edit by hand; regenerate all together:**

| Variable | What it is |
|---|---|
| `JWT_SECRET` | The one value the whole silo trusts — the mint function signs with it and PostgREST validates with it. (Same role as `SANKOR_SITE_JWT_SECRET` above.) |
| `ANON_KEY` | HS256 JWT derived from `JWT_SECRET` — the public/anon key. **Register this in the SANKOR admin.** |
| `SERVICE_ROLE_KEY` | HS256 JWT derived from `JWT_SECRET` — full access, silo-internal only. Never given to the hub or browser. |
| `POSTGRES_PASSWORD` | Postgres superuser password. |

**Identity + hub link — you provide, from the SANKOR admin:**

| Variable | | What it is |
|---|---|---|
| `SANKOR_SITE_WEBSITE_ID` | ✅ | Your website id (uuid). Must match `byoi_config`. |
| `SANKOR_HUB_URL` | ✅ | The hub's Supabase URL, e.g. `https://hub.sankor.site`. |
| `SANKOR_HUB_ANON_KEY` | ✅ | The hub's anon key (redeem RPC only). |
| `SANKOR_TOKEN_TTL_SECONDS` | ⬜ | Minted-token lifetime (default `900`). |
| `SILO_DOMAIN` | ✅ | Public domain this silo is served on (Caddy gets a TLS cert). Use `http://localhost` for local testing. **Register this URL + `ANON_KEY` in the SANKOR admin.** |

**Full stack only — Supabase Studio login:**

| Variable | What it is |
|---|---|
| `STUDIO_USER` | Caddy basic-auth user for Studio (default `admin`). |
| `STUDIO_PASSWORD_HASH` | bcrypt hash: `docker run --rm caddy:2.8 caddy hash-password --plaintext 'your-password'`. |

**Optional AI blogging agent:** same `GEMINI_API_KEY`, `AI_AGENT_CRON_SECRET`, and `R2_*` as in table A.

> **What the hub gets, in both paths:** only this silo's **public URL** and
> **anon key** (§7). The hub never needs — and never receives — `JWT_SECRET`,
> `SANKOR_SITE_JWT_SECRET`, or `SERVICE_ROLE_KEY`.

---

## Optional: AI blogging agent

The `ai-agent-run` function writes posts on a schedule, entirely inside your
silo (it uses the silo service-role key; no hub involvement).

1. Enable `pg_cron` + `pg_net` extensions, then re-run
   `sankor_byoi_schema.sql` (the schedule block activates once `pg_cron`
   exists). Replace `<PROJECT_REF>` / `<AI_AGENT_CRON_SECRET>` placeholders in
   that block first.
2. Set `GEMINI_API_KEY` and `AI_AGENT_CRON_SECRET` secrets (see `.env.example`;
   R2_* are optional, only for AI cover images).
3. Deploy it: `supabase functions deploy ai-agent-run` (verify_jwt is already
   off in `config.toml`).
4. Configure the brief/cadence from the SANKOR admin AI-agent panel (it upserts
   `ai_agent_config` through the minted-JWT bridge).

---

## Hub side (SANKOR platform operators only)

The **hub** half — the ticket table, `issue_byoi_ticket` / `redeem_byoi_ticket`
RPCs, and the tenant-client helper the app uses — lives in the **main
`Sankor-CMS` repo**, not here (`supabase/migrations/*byoi*` and
`lib/byoi/`). A silo operator does not need anything from that repo; the hub is
already running when you register in step 7.

---

## Security notes

- Tokens are always `role: authenticated`. The silo never issues `service_role`
  to the hub or the browser.
- Tickets are single-use, short-TTL, bound to one `website_id`.
- The signing secret lives only in the silo edge function; the hub cannot mint
  tokens on its own.
- Authoring RLS denies everything unless `role=authenticated` **and** the
  token's `website_id` claim equals this silo's configured `website_id`.
- Public (anon) access is read-only for *published* content, plus write-only
  submission of leads / orders / bookings — anonymous visitors cannot list
  orders, leads, knowledge, or drafts.
- The hub never holds the silo's signing secret, database password or
  service key. It **can**, however, authorize a token: the silo mints a token
  for any ticket the hub's `redeem_byoi_ticket` accepts. So someone in full
  control of the hub database could obtain an authoring token for your site
  (content read/write, the same power a SANKOR admin of the site has) — but
  never `service_role`, your database credentials, or other silos' data.
  Rotate `SANKOR_SITE_JWT_SECRET` to invalidate outstanding tokens.
- Tables that don't belong to the public site (`byoi_config`, `social_posts`)
  are RLS-locked; paid bodies (lesson content, members-only content, premium
  articles) are not readable with the anon key (column-level grants).
