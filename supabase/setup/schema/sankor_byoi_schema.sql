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

-- Locked down: no client role may read or write it directly. The SECURITY
-- DEFINER helpers below read it as the owner. Without this, anyone holding the
-- public anon key could DELETE or re-point the row (default privileges grant
-- anon ALL on new tables) and so deny every authoring write on the silo.
alter table public.byoi_config enable row level security;
revoke all on public.byoi_config from anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. JWT claim helpers
-- ----------------------------------------------------------------------------
-- The website_id claim, read from app_metadata first (Supabase-managed,
-- not user-spoofable) then top-level as a fallback.
--
-- All three helpers are SECURITY DEFINER with a pinned search_path. This is
-- essential for byoi_site_website_id(): byoi_config has RLS enabled, so a
-- STABLE/INVOKER function reading it as the `authenticated` role would be
-- filtered to zero rows and return NULL, making byoi_is_authorized() NULL and
-- silently denying every authoring write. Running as the definer (owner)
-- bypasses that RLS so the silo can always read its own single-row identity.
-- The others are marked definer too for consistency and to keep the search
-- path fixed; they only read auth.* claims, so this grants no extra exposure.
create or replace function public.byoi_claim_website_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(
        nullif(auth.jwt() -> 'app_metadata' ->> 'website_id', '')::uuid,
        nullif(auth.jwt() ->> 'website_id', '')::uuid
    );
$$;

-- This silo's configured website_id. SECURITY DEFINER so it reads byoi_config
-- past that table's RLS (see note above) — otherwise authoring writes are denied.
create or replace function public.byoi_site_website_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
    select website_id from public.byoi_config limit 1;
$$;

-- True only when the request carries an authenticated SANKOR token whose
-- website_id claim matches this silo. This is the single gate every policy uses.
create or replace function public.byoi_is_authorized()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select auth.role() = 'authenticated'
       and public.byoi_claim_website_id() is not null
       and public.byoi_claim_website_id() = public.byoi_site_website_id();
$$;

-- Connect-time health probe. Returns a small diagnostic JSON so the SANKOR hub
-- can validate a silo link the moment it's registered — catching a missing
-- byoi_config row, an unauthorized/mismatched token, or (historically) a NULL
-- config caused by a non-definer helper, instead of surfacing it as an opaque
-- RLS violation on the operator's first write. SECURITY DEFINER so `ok`
-- reflects the real config regardless of the caller's RLS. Nothing here is
-- secret (the website_id is issued by the hub), so anon + authenticated may call
-- it; the hub calls it with the minted token to assert `authorized = true`.
create or replace function public.byoi_health()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select jsonb_build_object(
        'ok',                    (select count(*) = 1 from public.byoi_config),
        'configured_website_id', public.byoi_site_website_id(),
        'role',                  auth.role(),
        'claim_website_id',      public.byoi_claim_website_id(),
        'authorized',            public.byoi_is_authorized()
    );
$$;

grant execute on function public.byoi_health() to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. RLS on website-scoped tables (those with a website_id column)
-- ----------------------------------------------------------------------------
do $$
declare
    t text;
    website_scoped text[] := array[
        'websites','albums','alumni','availability_rules','bookings','courses',
        'embedded_media','faculty','forms','knowledge_docs',
        'link_groups','lms_courses','lms_sections','lms_lessons',
        'events','event_ticket_types','membership_plans','testimonials',
        'milestones','orders','pages','posts','products',
        'profiles','resources','team_members',
        'web3_settings','social_posts'
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
-- insert into public.websites (id, name, status) values
--   ('00000000-0000-0000-0000-000000000000', 'My SANKOR Site', 'active')
-- on conflict (id) do update set status = 'active';


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
-- Guarded so this whole file still applies on a silo where pg_cron is not
-- enabled (the AI Agent is optional). If pg_cron is absent, the schedule is
-- skipped with a NOTICE — enable pg_cron + pg_net in the dashboard and re-run
-- this file (idempotent) to activate hourly posting.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — AI Agent schedule skipped. Enable pg_cron + pg_net, then re-run to activate.';
    return;
  end if;

  if exists (select 1 from cron.job where jobname = 'ai-agent-hourly') then
    perform cron.unschedule('ai-agent-hourly');
  end if;

  perform cron.schedule(
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
end $$;

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

-- ----------------------------------------------------------------------------
-- Courses / LMS — anon reads published courses + their sections/lessons.
-- (byoi_rw for authenticated writes is applied by the website_scoped loop above.)
-- Paid-lesson content withholding is enforced in the public read layer, not here.
-- ----------------------------------------------------------------------------
drop policy if exists lms_courses_public_read on public.lms_courses;
create policy lms_courses_public_read on public.lms_courses for select to anon
    using (status = 'published');
drop policy if exists lms_sections_public_read on public.lms_sections;
create policy lms_sections_public_read on public.lms_sections for select to anon
    using (exists (select 1 from public.lms_courses c where c.id = course_id and c.status = 'published'));
drop policy if exists lms_lessons_public_read on public.lms_lessons;
create policy lms_lessons_public_read on public.lms_lessons for select to anon
    using (exists (select 1 from public.lms_courses c where c.id = course_id and c.status = 'published'));

grant select on public.lms_courses, public.lms_sections, public.lms_lessons to anon;
grant all on public.lms_courses, public.lms_sections, public.lms_lessons to authenticated;

-- ----------------------------------------------------------------------------
-- Events / Ticketing public reads (anon): published events + their ticket types.
-- ----------------------------------------------------------------------------
drop policy if exists events_public_read on public.events;
create policy events_public_read on public.events for select to anon
    using (status = 'published');
drop policy if exists event_ticket_types_public_read on public.event_ticket_types;
create policy event_ticket_types_public_read on public.event_ticket_types for select to anon
    using (exists (select 1 from public.events e where e.id = event_id and e.status = 'published'));

grant select on public.events, public.event_ticket_types to anon;
grant all on public.events, public.event_ticket_types to authenticated;

-- ----------------------------------------------------------------------------
-- Membership public reads (anon): published plans. The members-only body
-- (member_content) is withheld in the app read layer for non-members.
-- ----------------------------------------------------------------------------
drop policy if exists membership_plans_public_read on public.membership_plans;
create policy membership_plans_public_read on public.membership_plans for select to anon
    using (status = 'published');

grant select on public.membership_plans to anon;
grant all on public.membership_plans to authenticated;

-- ----------------------------------------------------------------------------
-- Testimonials: anon read published + anon submit (pending only). The
-- website_scoped byoi_rw policy already covers editor authoring/moderation.
-- ----------------------------------------------------------------------------
drop policy if exists testimonials_public_read on public.testimonials;
create policy testimonials_public_read on public.testimonials for select to anon
    using (status = 'published');
drop policy if exists testimonials_public_submit on public.testimonials;
create policy testimonials_public_submit on public.testimonials for insert to anon
    with check (status = 'pending' and is_featured = false and source = 'form'
        and website_id = public.byoi_site_website_id());

grant select, insert on public.testimonials to anon;
grant all on public.testimonials to authenticated;

-- ----------------------------------------------------------------------------
-- 6. Ads & Sponsors
-- ----------------------------------------------------------------------------
-- Authoring via authenticated minted-JWT tokens (roles enforced on the hub).
-- Public reads: active sponsors + active ads are readable by anon so they can
-- render on the public site.
alter table if exists public.sponsors enable row level security;
drop policy if exists byoi_rw on public.sponsors;
create policy byoi_rw on public.sponsors for all to authenticated
    using (public.byoi_is_authorized() and website_id = public.byoi_claim_website_id())
    with check (public.byoi_is_authorized() and website_id = public.byoi_claim_website_id());
drop policy if exists sponsors_public_read on public.sponsors;
create policy sponsors_public_read on public.sponsors for select to anon using (is_active);

alter table if exists public.ads enable row level security;
drop policy if exists byoi_rw on public.ads;
create policy byoi_rw on public.ads for all to authenticated
    using (public.byoi_is_authorized() and website_id = public.byoi_claim_website_id())
    with check (public.byoi_is_authorized() and website_id = public.byoi_claim_website_id());
drop policy if exists ads_public_read on public.ads;
create policy ads_public_read on public.ads for select to anon using (is_active);

grant select on public.sponsors, public.ads to anon;
grant all on public.sponsors, public.ads to authenticated;

-- ============================================================================
-- 7. Public (anon) access for the PUBLIC website
-- ----------------------------------------------------------------------------
-- The public site is served with this silo's *anon* key (no minted JWT), so
-- anonymous visitors need to read published content and submit forms / orders /
-- bookings. This mirrors the hub's "Public view/create" policies. Without it a
-- BYOI public site renders empty (RLS is on; only authenticated byoi_rw exists).
--
-- Single-tenant safety: every row on this silo belongs to the one site, so a
-- flag predicate (published / is_active / true) is sufficient — there is no
-- other tenant's data to leak. Authenticated (minted-JWT) access is unchanged.
-- knowledge_docs, orders/leads/bookings *reads* stay private (authenticated
-- only); only their public *writes* are opened below. All guarded + idempotent.
-- ============================================================================

-- ---- Public reads (anon SELECT) --------------------------------------------
do $$
declare
  rec text[];
  -- {table, anon-visibility predicate}. Tables already given anon read earlier
  -- (articles, article_sections, sponsors, ads) are intentionally omitted.
  reads text[][] := array[
    ['websites',           'status = ''active'''],
    ['posts',              'published'],
    ['pages',              'is_published'],
    ['products',           'is_published'],
    ['team_members',       'true'],
    ['web3_settings',      'is_active'],
    ['embedded_media',     'is_publish'],
    ['albums',             'true'],
    ['media_assets',       'true'],
    ['faculty',            'true'],
    ['courses',            'true'],
    ['alumni',             'is_public'],
    ['milestones',         'true'],
    ['resources',          'true'],
    ['link_groups',        'true'],
    ['links',              'is_active'],
    ['forms',              'is_active'],
    ['availability_rules', 'true'],
    ['profiles',           'true'],
    ['profile_entries',    'true'],
    ['skills',             'true']
  ];
begin
  foreach rec slice 1 in array reads loop
    continue when to_regclass('public.' || rec[1]) is null;
    execute format('alter table public.%I enable row level security', rec[1]);
    execute format('drop policy if exists byoi_public_read on public.%I', rec[1]);
    execute format('create policy byoi_public_read on public.%I for select to anon using (%s)', rec[1], rec[2]);
    execute format('grant select on public.%I to anon', rec[1]);
  end loop;
end $$;

-- ---- Public submissions (anon INSERT) --------------------------------------
-- Form leads, storefront checkout (orders + order_items), and public bookings.
-- Reads on these remain authenticated-only (byoi_rw), so submissions are
-- write-only for the public — a visitor cannot list other people's orders.
do $$
declare
  t text;
begin
  foreach t in array array['leads','orders','order_items','bookings'] loop
    continue when to_regclass('public.' || t) is null;
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists byoi_public_insert on public.%I', t);
    execute format('create policy byoi_public_insert on public.%I for insert to anon with check (true)', t);
    execute format('grant insert on public.%I to anon', t);
  end loop;
end $$;

-- ============================================================================
-- 8. Site snapshots (whole-site backup for design/template trials)
-- ----------------------------------------------------------------------------
-- SANKOR lets an owner back up their whole site before trying a new design or
-- installing a marketplace template, then restore it in one click. On a BYOI
-- silo the module content (posts, resume, gallery, …) lives HERE, not on the
-- hub, so the module half of each backup is stored and rebuilt on the silo.
-- The hub keeps the design_config + site_content half and the snapshot index.
--
-- Scope is presentation + content ONLY. Transactional/customer data (orders,
-- order_items, leads, bookings) and secrets/config are never captured or
-- restored — a restore must never be able to wipe real business records.
-- ============================================================================

create table if not exists public.site_snapshots (
    id          uuid primary key default gen_random_uuid(),
    website_id  uuid not null,
    kind        text not null default 'manual',   -- manual | auto | pre_apply | pre_restore
    modules     jsonb not null default '{}'::jsonb,
    created_at  timestamptz not null default now()
);

-- Authoring-only: the minted token for this site may read/write its snapshots;
-- anon never can (backups can contain unpublished drafts).
alter table public.site_snapshots enable row level security;
drop policy if exists byoi_rw on public.site_snapshots;
create policy byoi_rw on public.site_snapshots for all to authenticated
    using (public.byoi_is_authorized() and website_id = public.byoi_claim_website_id())
    with check (public.byoi_is_authorized() and website_id = public.byoi_claim_website_id());
grant all on public.site_snapshots to authenticated;

-- Capture every in-scope module table for this site into one jsonb bundle.
-- SECURITY DEFINER so it can read past per-table RLS in one atomic pass; the
-- internal check pins it to this silo's authorized website.
create or replace function public.snapshot_modules(p_website_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    -- presentation + content only; transactional tables are intentionally absent
    all_tables text[] := array[
        'article_sections','articles','profiles','profile_entries','skills',
        'albums','media_assets','link_groups','links','faculty','courses','alumni',
        'sponsors','ads','posts','team_members','pages','milestones','embedded_media',
        'resources','forms','products'
    ];
    t text;
    result jsonb := '{}'::jsonb;
    rows jsonb;
begin
    if not public.byoi_is_authorized() or p_website_id is distinct from public.byoi_site_website_id() then
        raise exception 'Unauthorized: cannot snapshot this website';
    end if;

    foreach t in array all_tables loop
        if to_regclass('public.' || t) is not null then
            execute format(
                'select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I x where x.website_id = $1',
                t
            ) into rows using p_website_id;
            result := result || jsonb_build_object(t, rows);
        end if;
    end loop;

    return result;
end;
$$;

-- Rebuild the in-scope module tables from a captured bundle, atomically.
--   * "replace" tables (pure presentation, no transactional children) are wiped
--     for this site and re-inserted verbatim (ids preserved so FKs line up).
--   * "protected" tables (products, forms) have orders/leads pointing at them,
--     so they are NEVER deleted — only missing rows are restored — and are
--     inserted first so replace-table FKs (e.g. resources -> forms) resolve.
create or replace function public.restore_modules(p_website_id uuid, p_modules jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    -- parent -> child. Deleted in reverse, re-inserted in this order.
    replace_tables text[] := array[
        'article_sections','articles',
        'profiles','profile_entries','skills',
        'albums','media_assets',
        'link_groups','links',
        'faculty','courses','alumni',
        'sponsors','ads',
        'posts','team_members','pages','milestones','embedded_media','resources'
    ];
    protect_tables text[] := array['forms','products'];
    t text;
    i int;
begin
    if not public.byoi_is_authorized() or p_website_id is distinct from public.byoi_site_website_id() then
        raise exception 'Unauthorized: cannot restore snapshots for this website';
    end if;

    -- 1. Protected parents first: restore only rows that are missing.
    foreach t in array protect_tables loop
        if to_regclass('public.' || t) is not null and p_modules ? t then
            execute format(
                'insert into public.%I select * from jsonb_populate_recordset(null::public.%I, $1->%L) on conflict (id) do nothing',
                t, t, t
            ) using p_modules;
        end if;
    end loop;

    -- 2. Replace tables: delete children -> parents.
    for i in reverse array_length(replace_tables, 1)..1 loop
        t := replace_tables[i];
        if to_regclass('public.' || t) is not null then
            execute format('delete from public.%I where website_id = $1', t) using p_website_id;
        end if;
    end loop;

    -- 3. Replace tables: insert parents -> children.
    foreach t in array replace_tables loop
        if to_regclass('public.' || t) is not null and p_modules ? t then
            execute format(
                'insert into public.%I select * from jsonb_populate_recordset(null::public.%I, $1->%L)',
                t, t, t
            ) using p_modules;
        end if;
    end loop;
end;
$$;

grant execute on function public.snapshot_modules(uuid) to authenticated;
grant execute on function public.restore_modules(uuid, jsonb) to authenticated;
