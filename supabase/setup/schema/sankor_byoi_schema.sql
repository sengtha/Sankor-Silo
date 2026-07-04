-- ============================================================================
-- SANKOR BYOI SILO  ·  Auth overlay (tenant Supabase side)
-- ----------------------------------------------------------------------------
-- Apply this AFTER your canonical SANKOR content schema has been imported into
-- the tenant's Supabase. This file does NOT recreate content tables; it adds:
--   1. A single-row site identity anchor (byoi_config)
--   2. JWT claim helper functions used by RLS
--   3. Website-scoped RLS on all content tables
--   4. Decouples the local `websites` row from auth.users
--
-- Tokens reaching this DB are minted by THIS silo's edge function using the
-- silo's own HS256 secret. They carry role=authenticated and app_metadata
-- claims { website_id, tenant_role }. RLS pins every row to this silo's one
-- website_id, so a token minted for another site cannot read or write here.
-- ============================================================================

-- ============================================================================
-- AI Agent — social syndication (destinations) support.
-- social_posts records every syndication attempt: queued for review, published,
-- or failed. This is what a future "social review" UI reads from, and the audit
-- trail for what the agent posted where.
-- ============================================================================

create table if not exists public.social_posts (
  id uuid primary key default gen_random_uuid(),
  website_id uuid not null references public.websites(id) on delete cascade,
  post_id uuid references public.posts(id) on delete set null,
  platform text not null,                       -- 'twitter' | 'facebook' | ...
  variant_text text,                            -- the platform-shaped text
  status text not null default 'queued',        -- queued | published | failed
  external_id text,                             -- tweet id / fb post id
  error text,
  created_at timestamptz not null default now(),
  constraint social_posts_status_check check (status = any (array['queued','published','failed'])),
  constraint social_posts_platform_length check (platform is null or length(platform) <= 50),
  constraint social_posts_text_length check (variant_text is null or length(variant_text) <= 2000)
);

create index if not exists social_posts_website_idx
  on public.social_posts (website_id, created_at desc);

comment on table public.social_posts is
  'Syndication queue/audit for the AI Agent destination layer (X, Facebook, ...).';

-- ----------------------------------------------------------------------------
-- 0. Decouple the local websites anchor from auth.users
-- ----------------------------------------------------------------------------
-- The SANKOR hub user id (the JWT `sub`) does not exist in this project's
-- auth.users, so the canonical websites.user_id -> auth.users FK must go.
alter table public.websites
    drop constraint if exists websites_user_id_fkey;

-- Owner identity on the silo is informational only (the hub is authoritative).
alter table public.websites
    drop constraint if exists website_owner_check;

-- ----------------------------------------------------------------------------
-- 1. Site identity anchor (exactly one row: this silo's website_id)
-- ----------------------------------------------------------------------------
create table if not exists public.byoi_config (
    website_id   uuid primary key,        -- must equal the hub's website id
    hub_url      text not null,           -- e.g. https://hub.sankor.site
    registered_at timestamptz not null default now(),
    singleton    boolean not null default true,
    constraint byoi_config_singleton_chk check (singleton),
    constraint byoi_config_one_row unique (singleton)
);

comment on table public.byoi_config is
    'Single-row anchor identifying which SANKOR website this silo serves.';

-- ----------------------------------------------------------------------------
-- 2. JWT claim helpers
-- ----------------------------------------------------------------------------
-- The website_id claim, read from app_metadata first (Supabase-managed,
-- not user-spoofable) then top-level as a fallback.
create or replace function public.byoi_claim_website_id()
returns uuid
language sql
stable
as $$
    select coalesce(
        nullif(auth.jwt() -> 'app_metadata' ->> 'website_id', '')::uuid,
        nullif(auth.jwt() ->> 'website_id', '')::uuid
    );
$$;

-- This silo's configured website_id.
create or replace function public.byoi_site_website_id()
returns uuid
language sql
stable
as $$
    select website_id from public.byoi_config limit 1;
$$;

-- True only when the request carries an authenticated SANKOR token whose
-- website_id claim matches this silo. This is the single gate every policy uses.
create or replace function public.byoi_is_authorized()
returns boolean
language sql
stable
as $$
    select auth.role() = 'authenticated'
       and public.byoi_claim_website_id() is not null
       and public.byoi_claim_website_id() = public.byoi_site_website_id();
$$;

-- ----------------------------------------------------------------------------
-- 3. RLS on website-scoped tables (those with a website_id column)
-- ----------------------------------------------------------------------------
do $$
declare
    t text;
    website_scoped text[] := array[
        'websites','albums','alumni','availability_rules','bookings','courses',
        'embedded_media','faculty','forms','knowledge_docs',
        'link_groups','milestones','orders','pages','posts','products',
        'profiles','resources','team_members',
        'web3_settings'
    ];
    pred text;
begin
    foreach t in array website_scoped loop
        if to_regclass('public.' || t) is null then
            continue;  -- table not present in this deployment; skip
        end if;

        execute format('alter table public.%I enable row level security;', t);
        execute format('drop policy if exists byoi_rw on public.%I;', t);

        if t = 'websites' then
            -- the anchor row matches by its own id
            pred := 'public.byoi_is_authorized() and id = public.byoi_site_website_id()';
        else
            pred := 'public.byoi_is_authorized() and website_id = public.byoi_claim_website_id()';
        end if;

        execute format(
            'create policy byoi_rw on public.%I for all to authenticated using (%s) with check (%s);',
            t, pred, pred
        );
    end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. RLS on child tables (scoped through their parent's website_id)
-- ----------------------------------------------------------------------------
-- media_assets -> albums
alter table if exists public.media_assets enable row level security;
drop policy if exists byoi_rw on public.media_assets;
create policy byoi_rw on public.media_assets for all to authenticated
    using (public.byoi_is_authorized() and exists (
        select 1 from public.albums a
        where a.id = media_assets.album_id
          and a.website_id = public.byoi_claim_website_id()))
    with check (public.byoi_is_authorized() and exists (
        select 1 from public.albums a
        where a.id = media_assets.album_id
          and a.website_id = public.byoi_claim_website_id()));

-- order_items -> orders
alter table if exists public.order_items enable row level security;
drop policy if exists byoi_rw on public.order_items;
create policy byoi_rw on public.order_items for all to authenticated
    using (public.byoi_is_authorized() and exists (
        select 1 from public.orders o
        where o.id = order_items.order_id
          and o.website_id = public.byoi_claim_website_id()))
    with check (public.byoi_is_authorized() and exists (
        select 1 from public.orders o
        where o.id = order_items.order_id
          and o.website_id = public.byoi_claim_website_id()));

-- leads -> forms
alter table if exists public.leads enable row level security;
drop policy if exists byoi_rw on public.leads;
create policy byoi_rw on public.leads for all to authenticated
    using (public.byoi_is_authorized() and exists (
        select 1 from public.forms f
        where f.id = leads.form_id
          and f.website_id = public.byoi_claim_website_id()))
    with check (public.byoi_is_authorized() and exists (
        select 1 from public.forms f
        where f.id = leads.form_id
          and f.website_id = public.byoi_claim_website_id()));

-- links -> link_groups
alter table if exists public.links enable row level security;
drop policy if exists byoi_rw on public.links;
create policy byoi_rw on public.links for all to authenticated
    using (public.byoi_is_authorized() and exists (
        select 1 from public.link_groups g
        where g.id = links.group_id
          and g.website_id = public.byoi_claim_website_id()))
    with check (public.byoi_is_authorized() and exists (
        select 1 from public.link_groups g
        where g.id = links.group_id
          and g.website_id = public.byoi_claim_website_id()));

-- Provenance on posts: lets the agent mark its own posts, remember covered
-- topics, and cite source knowledge chunks in the approval UI.
ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS meta jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.posts.meta IS
  'Post provenance: { agent: bool, topic, source_doc_ids: uuid[], model }';

-- 3. Slug safety: an agent generating slugs daily will eventually collide.
--    (Deduplicate any existing collisions before applying, if necessary.)
CREATE UNIQUE INDEX IF NOT EXISTS posts_website_slug_unique
  ON public.posts (website_id, slug);

-- 4. Speeds up "what has the agent already written" lookups.
CREATE INDEX IF NOT EXISTS posts_agent_meta_idx
  ON public.posts USING gin (meta jsonb_path_ops);


-- profile_entries -> profiles
alter table if exists public.profile_entries enable row level security;
drop policy if exists byoi_rw on public.profile_entries;
create policy byoi_rw on public.profile_entries for all to authenticated
    using (public.byoi_is_authorized() and exists (
        select 1 from public.profiles p
        where p.id = profile_entries.profile_id
          and p.website_id = public.byoi_claim_website_id()))
    with check (public.byoi_is_authorized() and exists (
        select 1 from public.profiles p
        where p.id = profile_entries.profile_id
          and p.website_id = public.byoi_claim_website_id()));

-- skills -> profiles
alter table if exists public.skills enable row level security;
drop policy if exists byoi_rw on public.skills;
create policy byoi_rw on public.skills for all to authenticated
    using (public.byoi_is_authorized() and exists (
        select 1 from public.profiles p
        where p.id = skills.profile_id
          and p.website_id = public.byoi_claim_website_id()))
    with check (public.byoi_is_authorized() and exists (
        select 1 from public.profiles p
        where p.id = skills.profile_id
          and p.website_id = public.byoi_claim_website_id()));

-- ============================================================================
-- 5. Seed the site identity (replace placeholders, run once during onboarding)
-- ============================================================================
-- insert into public.byoi_config (website_id, hub_url)
-- values ('00000000-0000-0000-0000-000000000000', 'https://hub.sankor.site')
-- on conflict (singleton) do update
--   set website_id = excluded.website_id, hub_url = excluded.hub_url;
--
-- insert into public.websites (id, name) values
--   ('00000000-0000-0000-0000-000000000000', 'My SANKOR Site')
-- on conflict (id) do nothing;


-- ============================================================================
-- AI Agent — BYOI SILO migration.
-- Run this INSIDE THE TENANT'S OWN SUPABASE PROJECT (not the hub).
-- It creates the agent's config table and schedules the edge function locally,
-- so scheduled posting needs no hub session and no JWT bridge.
-- ============================================================================

-- 1. Config table. The hub admin UI syncs the brief + toggles here; the edge
--    function reads them. One row per silo (silo == one website).
create table if not exists public.ai_agent_config (
  website_id uuid primary key,
  enabled boolean not null default false,
  cadence text not null default 'daily',
  auto_publish boolean not null default false,
  brief_md text not null default '',
  sources jsonb not null default '[{"type":"knowledge","enabled":true}]'::jsonb,
  destinations jsonb not null default '[{"type":"blog","enabled":true}]'::jsonb,
  supported_locales text[] not null default array['en'],
  last_run_at timestamptz,
  last_result text,
  updated_at timestamptz not null default now()
);

-- If the table already existed from an earlier version, add the columns.
alter table public.ai_agent_config
  add column if not exists sources jsonb not null default '[{"type":"knowledge","enabled":true}]'::jsonb;
alter table public.ai_agent_config
  add column if not exists destinations jsonb not null default '[{"type":"blog","enabled":true}]'::jsonb;

-- 2. RLS so the hub admin (authenticated, website_id claim) can upsert config
--    through the existing minted-JWT bridge. Mirrors the byoi_rw pattern used
--    by the other website-scoped tables. The edge function uses the service
--    role and bypasses RLS, so it is unaffected.
alter table public.ai_agent_config enable row level security;
drop policy if exists byoi_rw on public.ai_agent_config;
create policy byoi_rw on public.ai_agent_config for all to authenticated
  using (public.byoi_is_authorized() and website_id = public.byoi_claim_website_id())
  with check (public.byoi_is_authorized() and website_id = public.byoi_claim_website_id());

-- 3. Provenance + slug safety on the silo's posts table (same as the hub).
alter table public.posts add column if not exists meta jsonb not null default '{}'::jsonb;
create unique index if not exists posts_website_slug_unique on public.posts (website_id, slug);
create index if not exists posts_agent_meta_idx on public.posts using gin (meta jsonb_path_ops);

-- 4. Schedule. Requires the pg_cron and pg_net extensions (enable both in the
--    Supabase dashboard: Database -> Extensions). Replace the placeholders:
--      <PROJECT_REF>           your silo project ref (e.g. abcdxyz)
--      <AI_AGENT_CRON_SECRET>  same value set as the function secret
--
--    Fires hourly; the edge function itself enforces cadence + "post only when
--    there's something new".
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — enable it in the dashboard, then re-run section 4.';
  end if;
end $$;

-- Unschedule a prior version if present, then (re)create.
select cron.unschedule('ai-agent-hourly')
where exists (select 1 from cron.job where jobname = 'ai-agent-hourly');

select cron.schedule(
  'ai-agent-hourly',
  '0 * * * *',
  $cron$
  select net.http_post(
    url     := 'https://<PROJECT_REF>.functions.supabase.co/ai-agent-run',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', '<AI_AGENT_CRON_SECRET>'
    ),
    body    := '{}'::jsonb
  );
  $cron$
);

-- ----------------------------------------------------------------------------
-- 5. Newsroom (articles + article_sections)
-- ----------------------------------------------------------------------------
-- Authoring: authenticated minted-JWT tokens for this website (roles are
-- enforced on the hub before the write reaches here). Public magazine reads:
-- published, live articles are readable by anon; sections are public taxonomy.
alter table if exists public.article_sections enable row level security;
drop policy if exists byoi_rw on public.article_sections;
create policy byoi_rw on public.article_sections for all to authenticated
    using (public.byoi_is_authorized() and website_id = public.byoi_claim_website_id())
    with check (public.byoi_is_authorized() and website_id = public.byoi_claim_website_id());
drop policy if exists article_sections_public_read on public.article_sections;
create policy article_sections_public_read on public.article_sections for select to anon
    using (true);

alter table if exists public.articles enable row level security;
drop policy if exists byoi_rw on public.articles;
create policy byoi_rw on public.articles for all to authenticated
    using (public.byoi_is_authorized() and website_id = public.byoi_claim_website_id())
    with check (public.byoi_is_authorized() and website_id = public.byoi_claim_website_id());
drop policy if exists articles_public_read on public.articles;
create policy articles_public_read on public.articles for select to anon
    using (status = 'published' and (publish_at is null or publish_at <= now()));

grant select on public.articles, public.article_sections to anon;
grant all on public.articles, public.article_sections to authenticated;
