// ============================================================================
// AI Agent — BYOI silo edge function (Deno).
//
// Runs ENTIRELY inside the tenant's own Supabase project. Triggered by pg_cron
// (see the companion silo migration). Because it runs in the silo, it uses the
// silo's own service-role key, which bypasses RLS — so it reads knowledge_docs
// and writes posts directly, with no hub involvement and no JWT minting.
//
// Secrets (set per tenant project via `supabase secrets set`):
//   GEMINI_API_KEY        - the tenant's own Gemini key (true BYOI)
//   AI_AGENT_CRON_SECRET  - shared secret; must match the header pg_cron sends
//   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY,
//   R2_BUCKET, R2_PUBLIC_URL   - OPTIONAL, only for cover images
//
// Auto-injected by Supabase: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Deploy with:  supabase functions deploy ai-agent-run --no-verify-jwt
// (auth is enforced via AI_AGENT_CRON_SECRET below, not Supabase JWT)
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { AwsClient } from 'https://esm.sh/aws4fetch@1.0.20';

const GEN_MODEL = 'gemini-3-flash-preview';
const EMBED_MODEL = 'gemini-embedding-001';
const MAX_CONTENT_CHARS = 18000;
const GENAI_BASE = 'https://generativelanguage.googleapis.com/v1beta/models';

// ---------------------------------------------------------------------------
// Gemini REST helpers (no SDK — avoids Deno/version friction)
// ---------------------------------------------------------------------------

async function embed(apiKey: string, text: string): Promise<number[] | null> {
  const res = await fetch(`${GENAI_BASE}/${EMBED_MODEL}:embedContent?key=${apiKey}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: `models/${EMBED_MODEL}`,
      content: { parts: [{ text }] },
      outputDimensionality: 768,
    }),
  });
  if (!res.ok) {
    console.error('[embed] HTTP', res.status, await res.text());
    return null;
  }
  const json = await res.json();
  return json?.embedding?.values ?? null;
}

async function generateJson(apiKey: string, prompt: string): Promise<any> {
  const res = await fetch(`${GENAI_BASE}/${GEN_MODEL}:generateContent?key=${apiKey}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: { responseMimeType: 'application/json' },
    }),
  });
  if (!res.ok) {
    console.error('[generate] HTTP', res.status, await res.text());
    return null;
  }
  const json = await res.json();
  const text = json?.candidates?.[0]?.content?.parts?.map((p: any) => p.text).join('') ?? '';
  try {
    return JSON.parse(text.replace(/```json\n?|```/g, '').trim());
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function firstLocaleValue(v: any): string {
  if (!v) return '';
  if (typeof v === 'string') return v;
  const k = Object.keys(v)[0];
  return k ? String(v[k]) : '';
}

function slugify(input: string): string {
  return (
    input
      .toLowerCase()
      .normalize('NFKD')
      .replace(/[\u0300-\u036f]/g, '')
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 80) || `post-${Date.now()}`
  );
}

function escapeXml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

function pickColor(_cfg: any): string {
  // Silo has no design_config; use a neutral default. (Could be synced later.)
  return '#1f2937';
}

function darken(hex: string, f = 0.55): string {
  const h = hex.replace('#', '');
  const r = Math.round(parseInt(h.slice(0, 2), 16) * f);
  const g = Math.round(parseInt(h.slice(2, 4), 16) * f);
  const b = Math.round(parseInt(h.slice(4, 6), 16) * f);
  return `#${[r, g, b].map((v) => v.toString(16).padStart(2, '0')).join('')}`;
}

function wrap(title: string, maxChars = 26, maxLines = 4): string[] {
  const words = title.trim().split(/\s+/);
  const lines: string[] = [];
  let cur = '';
  for (const w of words) {
    if ((cur + ' ' + w).trim().length > maxChars) {
      if (cur) lines.push(cur.trim());
      cur = w;
      if (lines.length === maxLines) break;
    } else cur = (cur + ' ' + w).trim();
  }
  if (cur && lines.length < maxLines) lines.push(cur.trim());
  return lines;
}

function buildSvg(title: string): string {
  const primary = pickColor(null);
  const dark = darken(primary);
  const lines = wrap(escapeXml(title), 26, 4);
  const startY = 315 - (lines.length - 1) * 40;
  const tspans = lines.map((l, i) => `<tspan x="90" y="${startY + i * 80}">${l}</tspan>`).join('');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630"><defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="${primary}"/><stop offset="100%" stop-color="${dark}"/></linearGradient></defs><rect width="1200" height="630" fill="url(#bg)"/><rect x="90" y="${startY - 78}" width="70" height="8" rx="4" fill="#ffffff" opacity="0.85"/><text font-family="Georgia, serif" font-weight="700" font-size="64" fill="#ffffff">${tspans}</text></svg>`;
}

async function generateCover(websiteId: string, title: string): Promise<string | null> {
  const accountId = Deno.env.get('R2_ACCOUNT_ID');
  const accessKeyId = Deno.env.get('R2_ACCESS_KEY_ID');
  const secretAccessKey = Deno.env.get('R2_SECRET_ACCESS_KEY');
  const bucket = Deno.env.get('R2_BUCKET');
  const publicUrl = Deno.env.get('R2_PUBLIC_URL');
  if (!accountId || !accessKeyId || !secretAccessKey || !bucket || !publicUrl) return null;

  try {
    const aws = new AwsClient({ accessKeyId, secretAccessKey, region: 'auto', service: 's3' });
    const key = `${websiteId}/ai-covers/${Date.now()}-${Math.random().toString(36).slice(2, 10)}.svg`;
    const svg = buildSvg(title || 'Untitled');
    const res = await aws.fetch(`https://${accountId}.r2.cloudflarestorage.com/${bucket}/${key}`, {
      method: 'PUT',
      body: svg,
      headers: { 'Content-Type': 'image/svg+xml', 'Cache-Control': 'public, max-age=31536000, immutable' },
    });
    if (!res.ok) {
      console.error('[cover] R2 PUT failed', res.status);
      return null;
    }
    return `${publicUrl.replace(/\/$/, '')}/${key}`;
  } catch (e) {
    console.error('[cover] failed', e);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Cadence
// ---------------------------------------------------------------------------

function isDue(cadence: string, lastRunAt: string | null): boolean {
  if (!lastRunAt) return true;
  const elapsed = Date.now() - new Date(lastRunAt).getTime();
  const threshold = cadence === 'weekly' ? 6.5 * 86400000 : 20 * 3600000;
  return elapsed >= threshold;
}

// ---------------------------------------------------------------------------
// Pluggable sources (Deno port of lib/actions/sources). Keep in sync with hub.
// ---------------------------------------------------------------------------

interface SourceItem {
  id: string;
  title: string;
  text: string;
  sourceType: string;
}
interface TopicCandidate {
  topic: string;
  sourceType: string;
  searchQuery?: string;
}
interface SrcCtx {
  websiteId: string;
  db: any;
  apiKey: string;
  config: Record<string, any>;
}

const knowledgeSource = {
  type: 'knowledge',
  async listTopics(ctx: SrcCtx): Promise<TopicCandidate[]> {
    const { data } = await ctx.db
      .from('knowledge_docs')
      .select('metadata')
      .eq('website_id', ctx.websiteId)
      .limit(500);
    const topics = new Set<string>();
    for (const row of data || []) {
      const t = row.metadata?.title || row.metadata?.category;
      if (typeof t === 'string' && t.trim()) topics.add(t.trim());
    }
    return Array.from(topics).map((topic) => ({ topic, sourceType: 'knowledge', searchQuery: topic }));
  },
  async fetch(ctx: SrcCtx, choice: TopicCandidate): Promise<SourceItem[]> {
    const embedding = await embed(ctx.apiKey, choice.searchQuery || choice.topic);
    if (!embedding) return [];
    const { data: chunks } = await ctx.db.rpc('match_knowledge_docs', {
      query_embedding: embedding,
      match_threshold: 0.4,
      match_count: 8,
      filter_website_id: ctx.websiteId,
    });
    return (chunks || []).map((c: any) => ({
      id: String(c.id),
      title: c.metadata?.title || '',
      text: c.content,
      sourceType: 'knowledge',
    }));
  },
};

const TENANT_TABLE_DEFS: Record<string, { topic: string; build: (ctx: SrcCtx) => Promise<SourceItem[]> }> = {
  products: {
    topic: 'New and featured products',
    build: async (ctx) => {
      const { data } = await ctx.db
        .from('products')
        .select('id, name, description, price, currency, created_at')
        .eq('website_id', ctx.websiteId)
        .eq('is_published', true)
        .order('created_at', { ascending: false })
        .limit(10);
      return (data || []).map((p: any) => ({
        id: `product:${p.id}`,
        title: firstLocaleValue(p.name),
        text: `Product: ${firstLocaleValue(p.name)}\nPrice: ${p.price ?? ''} ${p.currency ?? ''}\n${firstLocaleValue(p.description)}`.trim(),
        sourceType: 'tenant-tables',
      }));
    },
  },
  milestones: {
    topic: 'Recent milestones and updates',
    build: async (ctx) => {
      const { data } = await ctx.db
        .from('milestones')
        .select('id, title, description, date, status')
        .eq('website_id', ctx.websiteId)
        .order('date', { ascending: false })
        .limit(10);
      return (data || []).map((m: any) => ({
        id: `milestone:${m.id}`,
        title: firstLocaleValue(m.title),
        text: `Milestone (${m.status ?? 'update'}, ${m.date ?? ''}): ${firstLocaleValue(m.title)}\n${firstLocaleValue(m.description)}`.trim(),
        sourceType: 'tenant-tables',
      }));
    },
  },
};

const tenantTablesSource = {
  type: 'tenant-tables',
  async listTopics(ctx: SrcCtx): Promise<TopicCandidate[]> {
    const tables: string[] = ctx.config.tables?.length ? ctx.config.tables : ['products'];
    const candidates: TopicCandidate[] = [];
    for (const table of tables) {
      const def = TENANT_TABLE_DEFS[table];
      if (!def) continue;
      const { count } = await ctx.db
        .from(table)
        .select('id', { count: 'exact', head: true })
        .eq('website_id', ctx.websiteId);
      if ((count || 0) > 0) candidates.push({ topic: def.topic, sourceType: 'tenant-tables', searchQuery: table });
    }
    return candidates;
  },
  async fetch(ctx: SrcCtx, choice: TopicCandidate): Promise<SourceItem[]> {
    const def = TENANT_TABLE_DEFS[choice.searchQuery || 'products'];
    return def ? def.build(ctx) : [];
  },
};

const SOURCE_REGISTRY: Record<string, any> = {
  knowledge: knowledgeSource,
  'tenant-tables': tenantTablesSource,
};

function resolveSources(sources: any): Array<{ provider: any; config: Record<string, any> }> {
  const list = Array.isArray(sources) && sources.length ? sources : [{ type: 'knowledge', enabled: true }];
  const out: Array<{ provider: any; config: Record<string, any> }> = [];
  for (const c of list) {
    if (c.enabled === false) continue;
    const provider = SOURCE_REGISTRY[c.type];
    if (provider) out.push({ provider, config: c.config || {} });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  // 1. Auth: shared secret sent by pg_cron
  const expected = Deno.env.get('AI_AGENT_CRON_SECRET');
  if (!expected || req.headers.get('x-cron-secret') !== expected) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 });
  }

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  });

  const finish = async (cfg: any, result: any) => {
    await db
      .from('ai_agent_config')
      .update({
        last_run_at: new Date().toISOString(),
        last_result: result.error || result.reason || (result.postTitle ? `Posted: ${result.postTitle}` : 'ok'),
      })
      .eq('website_id', cfg.website_id);
    return new Response(JSON.stringify(result), { status: 200, headers: { 'Content-Type': 'application/json' } });
  };

  try {
    // 2. Load config (single row in this silo)
    const { data: cfg } = await db.from('ai_agent_config').select('*').limit(1).maybeSingle();
    if (!cfg) return new Response(JSON.stringify({ skipped: true, reason: 'No agent config.' }), { status: 200 });
    if (!cfg.enabled) return new Response(JSON.stringify({ skipped: true, reason: 'Agent disabled.' }), { status: 200 });
    if (!isDue(cfg.cadence || 'daily', cfg.last_run_at)) {
      return new Response(JSON.stringify({ skipped: true, reason: 'Not due yet.' }), { status: 200 });
    }

    const apiKey = Deno.env.get('GEMINI_API_KEY');
    if (!apiKey) return finish(cfg, { error: 'GEMINI_API_KEY secret not set in this project.' });

    const websiteId = cfg.website_id;
    const locales: string[] = cfg.supported_locales?.length ? cfg.supported_locales : ['en'];

    // 3. Resolve sources + gather candidates
    const sources = resolveSources(cfg.sources);
    if (sources.length === 0) return finish(cfg, { skipped: true, reason: 'No input sources enabled.' });

    const srcBase = { websiteId, db, apiKey };
    const candidates: TopicCandidate[] = [];
    for (const { provider, config } of sources) {
      try {
        const got = await provider.listTopics({ ...srcBase, config });
        candidates.push(...got);
      } catch (e) {
        console.error(`[source:${provider.type}] listTopics failed`, e);
      }
    }
    if (candidates.length === 0) return finish(cfg, { skipped: true, reason: 'No material from any source yet.' });

    const { data: pastPosts } = await db
      .from('posts')
      .select('title, created_at, meta')
      .eq('website_id', websiteId)
      .contains('meta', { agent: true })
      .order('created_at', { ascending: false })
      .limit(100);

    const coveredTopics = (pastPosts || []).map((p: any) => p.meta?.topic).filter(Boolean);
    const pastTitles = (pastPosts || []).map((p: any) => firstLocaleValue(p.title)).filter(Boolean);
    const lastPostAt = pastPosts?.[0]?.created_at || null;
    const uncovered = candidates.filter((c) => !coveredTopics.includes(c.topic));
    const hasNew = !lastPostAt || uncovered.length > 0;

    // 4a. Topic pick
    const candidateList = candidates.map((c) => ({ topic: c.topic, source: c.sourceType }));
    const pick = await generateJson(
      apiKey,
      `You are the editorial planner for a blog. Pick ONE topic for today's post from the candidates.

TOPIC CANDIDATES (each tagged with its source): ${JSON.stringify(candidateList)}
ALREADY COVERED (do not repeat): ${JSON.stringify(coveredTopics)}
PAST TITLES (do not repeat): ${JSON.stringify(pastTitles.slice(0, 50))}

EDITORIAL BRIEF:
${cfg.brief_md || '(none — write practical, reader-friendly posts about the candidate topics)'}

Return ONLY valid JSON: {"skip": boolean, "topic": string, "angle": string}
"topic" MUST be copied verbatim from a candidate. Set "skip" true ONLY if every candidate is already covered.`
    );

    if (!pick || typeof pick.topic !== 'string') return finish(cfg, { error: 'Topic planner returned invalid JSON.' });
    if (pick.skip === true && !hasNew) return finish(cfg, { skipped: true, reason: 'Nothing new to write about.' });

    // Match chosen topic back to its candidate/source
    const choice =
      candidates.find((c) => c.topic === pick.topic) ||
      candidates.find((c) => c.topic.toLowerCase().includes(String(pick.topic).toLowerCase())) ||
      uncovered[0] ||
      candidates[0];
    const chosen = sources.find((s) => s.provider.type === choice.sourceType);
    if (!chosen) return finish(cfg, { error: `No provider for source "${choice.sourceType}".` });

    // 4b. Fetch grounding material from the chosen source
    const items: SourceItem[] = await chosen.provider.fetch({ ...srcBase, config: chosen.config }, choice);
    if (!items || items.length === 0) return finish(cfg, { skipped: true, reason: `No material for "${choice.topic}".` });

    const contextText = items.map((it) => it.text).join('\n\n---\n\n');
    const sourceDocIds = items.map((it) => it.id).filter(Boolean);

    // 5. Write the post
    const post = await generateJson(
      apiKey,
      `You are an expert blog writer and localization specialist.

RULES:
1. GROUNDING: Write ONLY from the SOURCE MATERIAL. Do not invent facts.
2. LOCALES: Provide title, summary, content for EVERY locale in [ ${locales.join(', ')} ].
3. LENGTH: content < ${MAX_CONTENT_CHARS} chars/locale, title < 140, summary < 450.
4. content is Markdown. Return ONLY valid JSON:
{"title":{"<locale>":string},"summary":{"<locale>":string},"content":{"<locale>":string},"slug":string}

TOPIC: ${choice.topic}
ANGLE: ${pick.angle || 'practical and informative'}

EDITORIAL BRIEF:
${cfg.brief_md || '(none — clear, friendly, professional tone)'}

SOURCE MATERIAL:
${contextText}`
    );

    if (!post?.title || !post?.content) return finish(cfg, { error: 'Post writer returned invalid JSON.' });

    for (const loc of Object.keys(post.content)) {
      if (typeof post.content[loc] === 'string' && post.content[loc].length > MAX_CONTENT_CHARS) {
        post.content[loc] = post.content[loc].slice(0, MAX_CONTENT_CHARS);
      }
    }

    // Unique slug (retry on collision)
    let base = slugify(post.slug || firstLocaleValue(post.title) || choice.topic);
    let slug = base;
    for (let i = 2; i <= 10; i++) {
      const { data: clash } = await db.from('posts').select('id').eq('website_id', websiteId).eq('slug', slug).maybeSingle();
      if (!clash) break;
      slug = `${base}-${i}`;
    }

    const coverImage = await generateCover(websiteId, firstLocaleValue(post.title) || choice.topic);
    const published = cfg.auto_publish === true;

    const { data: inserted, error: insertError } = await db
      .from('posts')
      .insert({
        website_id: websiteId,
        title: post.title,
        slug,
        summary: post.summary || null,
        content: post.content,
        cover_image: coverImage,
        published,
        meta: { agent: true, topic: choice.topic, source_type: choice.sourceType, source_doc_ids: sourceDocIds, model: GEN_MODEL },
      })
      .select('id')
      .single();

    if (insertError) return finish(cfg, { error: `Failed to save post: ${insertError.message}` });

    return finish(cfg, { success: true, postId: inserted.id, postTitle: firstLocaleValue(post.title), published });
  } catch (e) {
    console.error('[AI Agent silo] failed:', e);
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
