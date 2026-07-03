// ============================================================================
// SANKOR BYOI SILO  ·  authenticate-sankor-user
// ----------------------------------------------------------------------------
// Deployed on the TENANT'S Supabase. This is the only place the silo's signing
// secret ever lives. The SANKOR hub never holds it.
//
// Flow:
//   client POST { ticket_id }  ->  this function
//     1. redeem the ticket at the SANKOR hub (learns sankor_user_id + role)
//     2. mint a short-lived HS256 JWT signed with SANKOR_SITE_JWT_SECRET
//     3. return { access_token, expires_in }
//
// Required edge-function secrets (Dashboard > Edge Functions > Manage Secrets):
//   SANKOR_SITE_JWT_SECRET   the HS256 secret, identical to the signing key
//                            imported into this project's JWT settings
//   SANKOR_SITE_WEBSITE_ID   this silo's website id (uuid), matches byoi_config
//   SANKOR_HUB_URL           e.g. https://hub.sankor.site  (Supabase project URL of the hub)
//   SANKOR_HUB_ANON_KEY      the hub's publishable/anon key (used only to call the redeem RPC)
//
// Optional:
//   SANKOR_SITE_JWT_KID      key id of the imported shared-secret SIGNING KEY.
//                            Set this to use the (future-proof) JWT Signing Keys
//                            slot. Leave UNSET to use the Legacy JWT Secret slot.
//   SANKOR_TOKEN_TTL_SECONDS default 900 (15 minutes)
//
// IMPORTANT: set "Verify JWT with legacy secret" to OFF for this function, so
// the ticket exchange can be reached without an existing Supabase session.
// ============================================================================

import { SignJWT } from "npm:jose@5";

const SECRET   = Deno.env.get("SANKOR_SITE_JWT_SECRET");
const SITE_ID  = Deno.env.get("SANKOR_SITE_WEBSITE_ID");
const HUB_URL  = Deno.env.get("SANKOR_HUB_URL");
const HUB_ANON = Deno.env.get("SANKOR_HUB_ANON_KEY");
const KID      = Deno.env.get("SANKOR_SITE_JWT_KID") ?? undefined;
const TTL      = Number(Deno.env.get("SANKOR_TOKEN_TTL_SECONDS") ?? "900");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

interface RedeemRow {
  sankor_user_id: string;
  website_id: string;
  tenant_role: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST")   return json({ error: "method not allowed" }, 405);

  if (!SECRET || !SITE_ID || !HUB_URL || !HUB_ANON) {
    return json({ error: "silo not configured" }, 500);
  }

  let ticketId: string | undefined;
  try {
    ({ ticket_id: ticketId } = await req.json());
  } catch {
    return json({ error: "invalid body" }, 400);
  }
  if (!ticketId) return json({ error: "ticket_id required" }, 400);

  const ip =
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? null;

  // ---- 1. Redeem the ticket at the hub -------------------------------------
  let claims: RedeemRow;
  try {
    const res = await fetch(`${HUB_URL}/rest/v1/rpc/redeem_byoi_ticket`, {
      method: "POST",
      headers: {
        apikey: HUB_ANON,
        Authorization: `Bearer ${HUB_ANON}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        p_ticket_id: ticketId,
        p_website_id: SITE_ID,
        p_ip: ip,
      }),
    });

    if (!res.ok) {
      const detail = await res.text();
      return json({ error: "ticket rejected", detail }, 401);
    }

    const rows = (await res.json()) as RedeemRow[];
    const row = Array.isArray(rows) ? rows[0] : (rows as RedeemRow);
    if (!row?.sankor_user_id) return json({ error: "ticket rejected" }, 401);
    claims = row;
  } catch (_e) {
    return json({ error: "hub unreachable" }, 502);
  }

  // Defense in depth: never mint a token for a website other than this silo's.
  // We already pass SITE_ID to redeem (so the hub binds the ticket), but we must
  // not trust the echoed website_id blindly — a buggy or compromised hub could
  // otherwise coax this silo into signing a token for a different site. The
  // silo's own RLS would still reject such a token, but refuse to sign it here.
  if (claims.website_id !== SITE_ID) {
    return json({ error: "website mismatch" }, 401);
  }

  // ---- 2. Mint the silo JWT ------------------------------------------------
  const now = Math.floor(Date.now() / 1000);
  const key = new TextEncoder().encode(SECRET);

  const header: Record<string, string> = { alg: "HS256", typ: "JWT" };
  if (KID) header.kid = KID; // present => JWT Signing Keys slot; absent => legacy slot

  let token: string;
  try {
    token = await new SignJWT({
      role: "authenticated",
      website_id: claims.website_id,
      tenant_role: claims.tenant_role,
      app_metadata: {
        provider: "sankor",
        website_id: claims.website_id,
        tenant_role: claims.tenant_role,
      },
      user_metadata: {},
    })
      .setProtectedHeader(header)
      .setSubject(claims.sankor_user_id)
      .setAudience("authenticated")
      .setIssuer("sankor-byoi")
      .setIssuedAt(now)
      .setExpirationTime(now + TTL)
      .sign(key);
  } catch (_e) {
    return json({ error: "signing failed" }, 500);
  }

  return json({ access_token: token, token_type: "bearer", expires_in: TTL });
});
