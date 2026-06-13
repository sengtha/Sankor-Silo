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

The hub holds tickets, not keys. The silo holds the signing secret. A token
minted for one site cannot read another site's silo — RLS pins every row to the
silo's single `website_id`.

---

## Setup

### 1. Create a Supabase project
Cloud (supabase.com) or self-hosted (e.g. Elestio). HS256 self-signing works on
both; self-hosted guarantees it long-term regardless of cloud roadmap changes.

### 2. Choose a signing key slot
Run `supabase gen signing-key` is **not** needed here — you provide an HS256
secret yourself. Generate one:

```bash
openssl rand -base64 48
```

You have two slots for it (the edge function supports both):

**A. Legacy JWT Secret (simplest, matches Normsar)**
- Dashboard → **Settings → JWT Keys → Legacy JWT Secret** → set this value.
- Leave `SANKOR_SITE_JWT_KID` unset in step 5.

**B. JWT Signing Keys / shared secret (future-proof)**
- Dashboard → **Settings → JWT Keys → JWT Signing Keys → Create Standby Key**,
  choose *shared secret*, paste the value, then **Rotate** to make it current.
- Copy its **Key ID** and set it as `SANKOR_SITE_JWT_KID` in step 5.
- Do **not** revoke the symmetric key while tokens rely on it.

### 3. Import the content schema
1. Apply your canonical SANKOR content schema first (your existing migrations).
2. Then run `supabase/setup/schema/sankor_byoi_schema.sql` to add the BYOI
   overlay (site anchor, claim helpers, website-scoped RLS, auth.users
   decoupling).
3. Seed the site identity at the bottom of that file with your real
   `website_id` (from the hub) and hub URL.

### 4. Set edge function secrets
Dashboard → **Edge Functions → Manage Secrets** (or `supabase secrets set`):

| Secret | Description |
| :-- | :-- |
| `SANKOR_SITE_JWT_SECRET` | the HS256 secret from step 2 |
| `SANKOR_SITE_WEBSITE_ID` | this silo's website id (uuid), matches `byoi_config` |
| `SANKOR_HUB_URL` | the SANKOR hub Supabase URL |
| `SANKOR_HUB_ANON_KEY` | the hub's publishable/anon key |
| `SANKOR_SITE_JWT_KID` | *(only for slot B)* the signing key's Key ID |
| `SANKOR_TOKEN_TTL_SECONDS` | *(optional)* default `900` |

### 5. Deploy the edge function
Deploy `authenticate-sankor-user`, then in its **Settings** set
**Verify JWT with legacy secret → OFF** (the ticket exchange must be reachable
without an existing Supabase session).

### 6. Register with the SANKOR hub
In the SANKOR admin, add this site's BYOI Supabase **URL** and **anon key**.
SANKOR validates the link by performing a live ticket exchange.

---

## Security notes

- Tokens are always `role: authenticated`. The silo never issues `service_role`.
- Tickets are single-use, ~60s TTL, bound to one `website_id`.
- The signing secret lives only in the silo edge function; the hub cannot mint
  tokens on its own.
- RLS denies everything unless `role=authenticated` **and** the token's
  `website_id` claim equals this silo's configured `website_id`.
- A SANKOR data breach does not expose silo data — the hub has no key to it.
