-- ============================================================================
-- SANKOR BYOI SILO  ·  Content schema (step 1)
-- ----------------------------------------------------------------------------
-- Derived from the canonical SANKOR (hub) schema, adapted to run on a FRESH
-- tenant Supabase project. Differences from the hub dump:
--   * dependency-ordered so foreign keys resolve top-to-bottom
--   * `subscription_tiers` omitted (hub-only billing)
--   * websites: auth.users FK, subscription_tiers FK, and owner check removed
--     so the table stands up without hub/auth dependencies (platform/billing
--     columns are kept but unused on the silo)
--   * required extensions declared
--   * transactions, site_content, design_snapshots, theme_blueprints
--     omitted (hub-owned, not stored on the silo)
--
-- ⚠ This is generated from your dump, not your live database. Diff it against
--   your actual schema (`supabase db diff` / your migrations) before applying.
--
-- Apply order:  this file  ->  sankor_byoi_schema.sql (the RLS/auth overlay)
-- ============================================================================

create extension if not exists "pgcrypto";
create extension if not exists "uuid-ossp";
create extension if not exists vector;   -- knowledge_docs.embedding vector(768)

-- ----------------------------------------------------------------------------
-- websites  (silo anchor; platform/billing columns retained but unused)
-- ----------------------------------------------------------------------------
create table public.websites (
    id uuid not null default gen_random_uuid(),
    name text not null,
    domain text,
    created_at timestamp with time zone default now(),
    design_config jsonb,
    status text,
    user_id uuid,                          -- no FK on silo (hub auth.users)
    r2_used_bytes bigint default 0,
    stream_used_minutes integer default 0,
    logo_url text,
    supported_locales text[] default array['en'::text],
    default_locale text default 'en'::text,
    custom_domain text,
    byoi jsonb,                            -- unused on silo
    tier_id text,                          -- no FK on silo (hub subscription_tiers)
    subscription_expires_at timestamp with time zone,
    subscription_status text default 'active'::text,
    used_ai_number integer default 0,
    addon_quotas jsonb,                    -- unused on silo
    platform_status text default 'active'::text,
    cookie_banner_config jsonb,
    updated_at timestamp with time zone not null default timezone('utc'::text, now()),
    agent_wallet_address text,
    constraint websites_pkey primary key (id),
    constraint websites_custom_domain_key unique (custom_domain),
    constraint websites_domain_key unique (domain),
    constraint cookie_banner_size_limit check (length(cookie_banner_config::text) <= 5000),
    constraint websites_json_length_check check ((design_config is null or length(design_config::text) <= 100000) and (byoi is null or length(byoi::text) <= 100000) and (addon_quotas is null or length(addon_quotas::text) <= 100000)),
    constraint websites_locale_check check (length(default_locale) <= 20),
    constraint websites_name_domain_length check (length(name) <= 255 and (domain is null or length(domain) <= 255)),
    constraint websites_platform_status_check check (platform_status = any (array['active'::text, 'suspended'::text, 'billing_hold'::text, 'banned'::text])),
    constraint websites_status_length check (length(status) <= 50 and (subscription_status is null or length(subscription_status) <= 50)),
    constraint websites_supported_locales_check check (supported_locales is null or array_length(supported_locales, 1) <= 50 and length(supported_locales::text) <= 1000),
    constraint websites_url_length_check check ((logo_url is null or length(logo_url) <= 2048) and (custom_domain is null or length(custom_domain) <= 255)),
    constraint websites_usage_boundary_check check (r2_used_bytes >= 0 and stream_used_minutes >= 0 and used_ai_number >= 0),
    constraint websites_user_status_check check (status is null or (status = any (array['active'::text, 'maintenance'::text, 'construction'::text, 'user_closed'::text])))
);

-- ----------------------------------------------------------------------------
-- website-scoped tables
-- ----------------------------------------------------------------------------
create table public.albums (
    id uuid not null default gen_random_uuid(),
    website_id uuid not null,
    title jsonb not null,
    description jsonb,
    album_type text default 'mixed'::text,
    cover_image text,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    is_featured boolean default false,
    constraint albums_pkey primary key (id),
    constraint albums_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint albums_cover_image_length_check check (cover_image is null or length(cover_image) <= 2048),
    constraint albums_description_length_check check (description is null or length(description::text) <= 10000),
    constraint albums_title_length_check check (title is null or length(title::text) <= 500),
    constraint albums_type_check check (album_type is null or (album_type = any (array['photo'::text, 'video'::text, 'audio'::text, 'gallery'::text, 'stream'::text])))
);

create table public.alumni (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    student_id text not null,
    name text not null,
    graduation_year integer,
    degree text,
    is_public boolean default false,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    constraint alumni_pkey primary key (id),
    constraint alumni_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint alumni_degree_length_check check (degree is null or length(degree) <= 200),
    constraint alumni_name_length_check check (name is null or length(name) <= 150)
);

create table public.availability_rules (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    day_of_week integer not null,
    start_time time without time zone not null,
    end_time time without time zone not null,
    is_active boolean default true,
    constraint availability_rules_pkey primary key (id),
    constraint availability_rules_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint availability_rules_day_of_week_check check (day_of_week >= 0 and day_of_week <= 6)
);

create table public.faculty (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    name jsonb not null,
    title jsonb,
    department jsonb,
    bio jsonb,
    specialties jsonb default '[]'::jsonb,
    image_url text,
    email text,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    constraint faculty_pkey primary key (id),
    constraint faculty_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint faculty_bio_length_check check (bio is null or length(bio::text) <= 10000),
    constraint faculty_department_length_check check (department is null or length(department::text) <= 500),
    constraint faculty_email_check check (email is null or length(email) <= 255 and email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'::text),
    constraint faculty_image_url_length_check check (image_url is null or length(image_url) <= 2048),
    constraint faculty_name_length_check check (name is null or length(name::text) <= 500),
    constraint faculty_specialties_length_check check (specialties is null or length(specialties::text) <= 5000),
    constraint faculty_title_length_check check (title is null or length(title::text) <= 500)
);

create table public.courses (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    code text not null,
    title jsonb not null,
    description jsonb,
    credits integer,
    syllabus_url text,
    prerequisites jsonb default '[]'::jsonb,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    faculty_id uuid,
    constraint courses_pkey primary key (id),
    constraint courses_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint fk_course_faculty foreign key (faculty_id) references faculty(id) on delete set null,
    constraint courses_code_length_check check (code is null or length(code) <= 50),
    constraint courses_credits_check check (credits is null or credits >= 0 and credits <= 100),
    constraint courses_description_length_check check (description is null or length(description::text) <= 10000),
    constraint courses_prerequisites_length_check check (prerequisites is null or length(prerequisites::text) <= 5000),
    constraint courses_syllabus_url_length_check check (syllabus_url is null or length(syllabus_url) <= 2048),
    constraint courses_title_length_check check (title is null or length(title::text) <= 1000)
);

create table public.embedded_media (
    id uuid not null default gen_random_uuid(),
    website_id uuid,
    platform text not null,
    media_id text not null,
    title jsonb default '{}'::jsonb,
    description jsonb default '{}'::jsonb,
    thumbnail_url text,
    is_featured boolean default false,
    is_publish boolean default false,
    created_at timestamp with time zone default now(),
    updated_at timestamp with time zone default now(),
    constraint embedded_media_pkey primary key (id),
    constraint embedded_media_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint embedded_media_description_length_check check (description is null or length(description::text) <= 10000),
    constraint embedded_media_id_length_check check (media_id is null or length(media_id) <= 255),
    constraint embedded_media_platform_check check (platform = any (array['youtube'::text, 'vimeo'::text, 'spotify'::text, 'twitter'::text])),
    constraint embedded_media_platform_length_check check (platform is null or length(platform) <= 50),
    constraint embedded_media_thumbnail_length_check check (thumbnail_url is null or length(thumbnail_url) <= 2048),
    constraint embedded_media_title_length_check check (title is null or length(title::text) <= 1000)
);

create table public.forms (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    title jsonb not null,
    fields jsonb default '[]'::jsonb,
    is_active boolean default true,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    is_featured boolean,
    constraint forms_pkey primary key (id),
    constraint forms_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint forms_fields_length_check check (fields is null or length(fields::text) <= 200000),
    constraint forms_title_length_check check (title is null or length(title::text) <= 1000)
);

create table public.knowledge_docs (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    content text not null,
    metadata jsonb default '{}'::jsonb,
    embedding vector(768),
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    constraint knowledge_docs_pkey primary key (id),
    constraint knowledge_docs_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint knowledge_docs_content_length_check check (content is null or length(content) <= 50000),
    constraint knowledge_docs_metadata_length_check check (metadata is null or length(metadata::text) <= 10000)
);

create table public.link_groups (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    title text not null,
    sort_order integer default 0,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    is_featured boolean default false,
    constraint link_groups_pkey primary key (id),
    constraint link_groups_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint link_groups_sort_order_check check (sort_order is null or sort_order >= 0 and sort_order <= 10000),
    constraint link_groups_title_length_check check (title is null or length(title) <= 150)
);

create table public.milestones (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    date date not null,
    title jsonb not null,
    description jsonb,
    status text default 'planned'::text,
    icon text,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    constraint milestones_pkey primary key (id),
    constraint milestones_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint milestones_description_length_check check (description is null or length(description::text) <= 5000),
    constraint milestones_icon_length_check check (icon is null or length(icon) <= 100),
    constraint milestones_status_check check (status = any (array['completed'::text, 'in_progress'::text, 'planned'::text])),
    constraint milestones_title_length_check check (title is null or length(title::text) <= 500)
);

create table public.products (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    name jsonb not null,
    slug text not null,
    description jsonb,
    price numeric default 0,
    currency text default 'USD'::text,
    inventory_count integer default 0,
    is_service boolean default false,
    images jsonb default '[]'::jsonb,
    metadata jsonb default '{}'::jsonb,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    is_featured boolean default false,
    is_published boolean default false,
    constraint products_pkey primary key (id),
    constraint products_website_id_slug_key unique (website_id, slug),
    constraint products_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint products_currency_length_check check (currency is null or length(currency) <= 10),
    constraint products_description_length_check check (description is null or length(description::text) <= 50000),
    constraint products_images_length_check check (images is null or length(images::text) <= 20000),
    constraint products_inventory_check check (inventory_count is null or inventory_count >= 0),
    constraint products_metadata_length_check check (metadata is null or length(metadata::text) <= 50000),
    constraint products_name_length_check check (name is null or length(name::text) <= 1000),
    constraint products_price_check check (price is null or price >= 0::numeric),
    constraint products_slug_check check (slug is null or length(slug) <= 255 and slug ~ '^[a-z0-9\-]+$'::text)
);

create table public.orders (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    customer_name text,
    customer_contact text not null,
    total_amount numeric not null,
    status text not null default 'pending'::text,
    payment_method text not null default 'cash'::text,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    shipping_address text,
    constraint orders_pkey primary key (id),
    constraint orders_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint orders_customer_contact_length_check check (customer_contact is null or length(customer_contact) <= 255),
    constraint orders_customer_name_length_check check (customer_name is null or length(customer_name) <= 150),
    constraint orders_payment_method_check check (payment_method is null or length(payment_method) <= 50),
    constraint orders_shipping_address_length_check check (shipping_address is null or length(shipping_address) <= 1000),
    constraint orders_status_check check (status = any (array['pending'::text, 'pending_contact'::text, 'processing'::text, 'shipped'::text, 'completed'::text, 'cancelled'::text, 'refunded'::text])),
    constraint orders_total_amount_check check (total_amount >= 0::numeric)
);

create table public.bookings (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    product_id uuid not null,
    customer_name text not null,
    start_time timestamp with time zone not null,
    end_time timestamp with time zone not null,
    status text not null default 'pending'::text,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    customer_email text,
    customer_phone text,
    constraint bookings_pkey primary key (id),
    constraint bookings_product_id_fkey foreign key (product_id) references products(id) on delete cascade,
    constraint bookings_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint bookings_customer_email_check check (customer_email is null or length(customer_email) <= 255 and customer_email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'::text),
    constraint bookings_customer_name_check check (customer_name is null or length(customer_name) <= 150),
    constraint bookings_customer_phone_check check (customer_phone is null or length(customer_phone) <= 30 and customer_phone ~ '^\+?[0-9\s\-\(\)]+$'::text),
    constraint bookings_status_check check (status = any (array['pending'::text, 'confirmed'::text, 'cancelled'::text]))
);

create table public.pages (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    title jsonb not null,
    slug text not null,
    content jsonb,
    is_published boolean default false,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    updated_at timestamp with time zone not null default timezone('utc'::text, now()),
    cover_image text,
    constraint pages_pkey primary key (id),
    constraint pages_website_id_slug_key unique (website_id, slug),
    constraint pages_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint pages_json_length_check check (((content ->> 'title'::text) is null or length(content ->> 'title'::text) <= 150) and ((content ->> 'content'::text) is null or length(content ->> 'content'::text) <= 50000)),
    constraint pages_slug_format_check check (slug is null or slug ~ '^[a-z0-9\-]+$'::text),
    constraint pages_slug_length_check check (slug is null or length(slug) <= 200)
);

create table public.posts (
    id uuid not null default gen_random_uuid(),
    website_id uuid not null,
    title jsonb not null,
    slug text not null,
    summary jsonb,
    content jsonb,
    cover_image text,
    published boolean default false,
    created_at timestamp with time zone default now(),
    updated_at timestamp with time zone default now(),
    is_featured boolean default false,
    expires_at timestamp with time zone,
    constraint posts_pkey primary key (id),
    constraint posts_website_id_slug_key unique (website_id, slug),
    constraint posts_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint posts_json_length_check check (((content ->> 'title'::text) is null or length(content ->> 'title'::text) <= 150) and ((content ->> 'summary'::text) is null or length(content ->> 'summary'::text) <= 500) and ((content ->> 'content'::text) is null or length(content ->> 'content'::text) <= 20000)),
    constraint posts_slug_format_check check (slug is null or slug ~ '^[a-z0-9\-]+$'::text),
    constraint posts_text_length_check check ((cover_image is null or length(cover_image) <= 2048) and (slug is null or length(slug) <= 200))
);

create table public.profiles (
    id uuid not null default uuid_generate_v4(),
    website_id uuid,
    name jsonb not null,
    headline jsonb,
    bio jsonb,
    email text,
    phone text,
    location jsonb,
    avatar_url text,
    resume_url text,
    social_links jsonb default '{}'::jsonb,
    created_at timestamp with time zone default timezone('utc'::text, now()),
    constraint profiles_pkey primary key (id),
    constraint profiles_website_id_key unique (website_id),
    constraint profiles_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint profiles_avatar_url_length_check check (avatar_url is null or length(avatar_url) <= 2048),
    constraint profiles_bio_length_check check (bio is null or length(bio::text) <= 10000),
    constraint profiles_email_check check (email is null or length(email) <= 255 and email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'::text),
    constraint profiles_headline_length_check check (headline is null or length(headline::text) <= 500),
    constraint profiles_location_length_check check (location is null or length(location::text) <= 1000),
    constraint profiles_name_length_check check (name is null or length(name::text) <= 500),
    constraint profiles_phone_length_check check (phone is null or length(phone) <= 50),
    constraint profiles_resume_url_length_check check (resume_url is null or length(resume_url) <= 2048),
    constraint profiles_social_links_length_check check (social_links is null or length(social_links::text) <= 5000)
);

create table public.resources (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    title jsonb not null,
    category jsonb,
    file_url text not null,
    file_type text,
    is_gated boolean default false,
    download_count integer default 0,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    target_form_id uuid,
    constraint resources_pkey primary key (id),
    constraint resources_target_form_id_fkey foreign key (target_form_id) references forms(id),
    constraint resources_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint resources_category_length_check check (category is null or length(category::text) <= 500),
    constraint resources_download_count_check check (download_count is null or download_count >= 0),
    constraint resources_file_type_length_check check (file_type is null or length(file_type) <= 50),
    constraint resources_file_url_length_check check (file_url is null or length(file_url) <= 2048),
    constraint resources_title_length_check check (title is null or length(title::text) <= 1000)
);

create table public.team_members (
    id uuid not null default gen_random_uuid(),
    website_id uuid not null,
    name text not null,
    image_url text,
    role jsonb default '{"en": "", "km": ""}'::jsonb,
    bio jsonb default '{"en": "", "km": ""}'::jsonb,
    social_links jsonb default '{}'::jsonb,
    order_index integer default 0,
    is_featured boolean default false,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    group_name jsonb default '{"en": "", "km": ""}'::jsonb,
    constraint team_members_pkey primary key (id),
    constraint team_members_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint team_members_bio_length_check check (bio is null or length(bio::text) <= 5000),
    constraint team_members_group_name_length_check check (group_name is null or length(group_name::text) <= 255),
    constraint team_members_image_url_length_check check (image_url is null or length(image_url) <= 2048),
    constraint team_members_name_length_check check (name is null or length(name) <= 255),
    constraint team_members_order_index_check check (order_index is null or order_index >= 0 and order_index <= 10000),
    constraint team_members_role_length_check check (role is null or length(role::text) <= 500),
    constraint team_members_social_links_length_check check (social_links is null or length(social_links::text) <= 3000)
);

create table public.web3_settings (
    id uuid not null default uuid_generate_v4(),
    website_id uuid not null,
    chain_id text default '0x1'::text,
    token_address text,
    nft_address text,
    is_active boolean default false,
    updated_at timestamp with time zone not null default timezone('utc'::text, now()),
    title jsonb default '{}'::jsonb,
    constraint web3_settings_pkey primary key (id),
    constraint web3_settings_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint chk_web3_title_is_object check (jsonb_typeof(title) = 'object'::text),
    constraint chk_web3_title_length check (length(title::text) <= 1000),
    constraint web3_settings_chain_id_check check (chain_id is null or length(chain_id) <= 50),
    constraint web3_settings_nft_address_check check (nft_address is null or length(nft_address) = 42 and nft_address ~ '^0x[a-fA-F0-9]{40}$'::text),
    constraint web3_settings_token_address_check check (token_address is null or length(token_address) = 42 and token_address ~ '^0x[a-fA-F0-9]{40}$'::text)
);

-- ----------------------------------------------------------------------------
-- child tables (scoped through a parent's website_id)
-- ----------------------------------------------------------------------------
create table public.media_assets (
    id uuid not null default gen_random_uuid(),
    album_id uuid not null,
    media_type text not null,
    url text not null,
    title jsonb,
    description jsonb,
    mime_type text,
    file_size bigint,
    duration integer,
    width integer,
    height integer,
    metadata jsonb default '{}'::jsonb,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    is_featured boolean default false,
    constraint media_assets_pkey primary key (id),
    constraint media_assets_album_id_fkey foreign key (album_id) references albums(id) on delete cascade,
    constraint media_assets_description_length_check check (description is null or length(description::text) <= 10000),
    constraint media_assets_dimensions_check check ((width is null or width >= 0) and (height is null or height >= 0)),
    constraint media_assets_duration_check check (duration is null or duration >= 0),
    constraint media_assets_file_size_check check (file_size is null or file_size >= 0),
    constraint media_assets_media_type_check check (media_type is null or length(media_type) <= 50),
    constraint media_assets_metadata_length_check check (metadata is null or length(metadata::text) <= 50000),
    constraint media_assets_mime_type_length_check check (mime_type is null or length(mime_type) <= 100),
    constraint media_assets_title_length_check check (title is null or length(title::text) <= 1000),
    constraint media_assets_url_length_check check (url is null or length(url) <= 2048)
);

create table public.order_items (
    id uuid not null default uuid_generate_v4(),
    order_id uuid not null,
    product_id uuid,
    quantity integer not null,
    price_at_purchase numeric not null,
    constraint order_items_pkey primary key (id),
    constraint order_items_order_id_fkey foreign key (order_id) references orders(id) on delete cascade,
    constraint order_items_product_id_fkey foreign key (product_id) references products(id) on delete set null,
    constraint order_items_price_at_purchase_check check (price_at_purchase >= 0::numeric),
    constraint order_items_price_check check (price_at_purchase is null or price_at_purchase >= 0::numeric),
    constraint order_items_quantity_check check (quantity > 0)
);

create table public.leads (
    id uuid not null default uuid_generate_v4(),
    form_id uuid not null,
    data jsonb default '{}'::jsonb,
    status text default 'new'::text,
    source text default 'web_form'::text,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    constraint leads_pkey primary key (id),
    constraint leads_form_id_fkey foreign key (form_id) references forms(id) on delete cascade,
    constraint leads_data_length_check check (data is null or length(data::text) <= 100000),
    constraint leads_source_length_check check (source is null or length(source) <= 100),
    constraint leads_status_check check (status = any (array['new'::text, 'contacted'::text, 'qualified'::text, 'converted'::text, 'junk'::text]))
);

create table public.links (
    id uuid not null default uuid_generate_v4(),
    group_id uuid not null,
    title text not null,
    url text not null,
    icon_name text,
    is_highlighted boolean default false,
    is_active boolean default true,
    click_count integer default 0,
    sort_order integer default 0,
    created_at timestamp with time zone not null default timezone('utc'::text, now()),
    constraint links_pkey primary key (id),
    constraint links_group_id_fkey foreign key (group_id) references link_groups(id) on delete cascade,
    constraint links_click_count_check check (click_count is null or click_count >= 0),
    constraint links_icon_name_length_check check (icon_name is null or length(icon_name) <= 100),
    constraint links_sort_order_check check (sort_order is null or sort_order >= 0 and sort_order <= 10000),
    constraint links_title_length_check check (title is null or length(title) <= 255),
    constraint links_url_length_check check (url is null or length(url) <= 2048)
);

create table public.profile_entries (
    id uuid not null default uuid_generate_v4(),
    profile_id uuid,
    entry_type text not null,
    title jsonb not null,
    organization jsonb,
    start_date date,
    end_date date,
    is_current boolean default false,
    description jsonb,
    image_url text,
    link_url text,
    sort_order integer default 0,
    created_at timestamp with time zone default timezone('utc'::text, now()),
    is_featured boolean default false,
    constraint profile_entries_pkey primary key (id),
    constraint profile_entries_profile_id_fkey foreign key (profile_id) references profiles(id) on delete cascade,
    constraint profile_entries_description_length_check check (description is null or length(description::text) <= 10000),
    constraint profile_entries_image_url_length_check check (image_url is null or length(image_url) <= 2048),
    constraint profile_entries_link_url_length_check check (link_url is null or length(link_url) <= 2048),
    constraint profile_entries_organization_length_check check (organization is null or length(organization::text) <= 1000),
    constraint profile_entries_sort_order_check check (sort_order is null or sort_order >= 0 and sort_order <= 10000),
    constraint profile_entries_title_length_check check (title is null or length(title::text) <= 1000),
    constraint profile_entries_type_check check (entry_type is null or length(entry_type) <= 50)
);

create table public.skills (
    id uuid not null default uuid_generate_v4(),
    profile_id uuid,
    name jsonb not null,
    category jsonb,
    proficiency_level integer,
    sort_order integer default 0,
    constraint skills_pkey primary key (id),
    constraint skills_profile_id_fkey foreign key (profile_id) references profiles(id) on delete cascade,
    constraint skills_category_length_check check (category is null or length(category::text) <= 255),
    constraint skills_name_length_check check (name is null or length(name::text) <= 255),
    constraint skills_proficiency_level_check check (proficiency_level >= 1 and proficiency_level <= 100),
    constraint skills_sort_order_check check (sort_order is null or sort_order >= 0 and sort_order <= 10000)
);

-- ============================================================================
-- Newsroom / Magazine (silo-hosted content)
-- ----------------------------------------------------------------------------
-- Articles and their sections live on the silo (content sovereignty). Editorial
-- roles / collaborators remain on the SANKOR hub (website_members); bylines are
-- denormalized here (author_name/author_avatar) so the silo needs no members
-- table. RLS is applied in the BYOI overlay (sankor_byoi_schema.sql).
-- ============================================================================
create table public.article_sections (
    id uuid not null default gen_random_uuid(),
    website_id uuid not null,
    name jsonb not null,
    slug text not null,
    description jsonb,
    sort_order integer default 0,
    created_at timestamp with time zone default now(),
    constraint article_sections_pkey primary key (id),
    constraint article_sections_website_id_slug_key unique (website_id, slug),
    constraint article_sections_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint article_sections_slug_format_check check (slug is null or slug ~ '^[a-z0-9\-]+$'::text)
);

create table public.articles (
    id uuid not null default gen_random_uuid(),
    website_id uuid not null,
    section_id uuid,
    author_member_id uuid,          -- references hub website_members (no FK on silo)
    author_name text,               -- denormalized byline (members live on the hub)
    author_avatar text,
    title jsonb not null,
    dek jsonb,
    slug text not null,
    content jsonb,
    cover_image text,
    gallery jsonb not null default '[]'::jsonb,   -- ordered [{ url, caption? }] shown below the body
    tags text[] default '{}'::text[],
    status text not null default 'draft',
    is_featured boolean default false,
    is_premium boolean default false,
    publish_at timestamp with time zone,
    published_at timestamp with time zone,
    created_at timestamp with time zone default now(),
    updated_at timestamp with time zone default now(),
    constraint articles_pkey primary key (id),
    constraint articles_website_id_slug_key unique (website_id, slug),
    constraint articles_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint articles_section_id_fkey foreign key (section_id) references article_sections(id) on delete set null,
    constraint articles_status_check check (status = any (array['draft','in_review','scheduled','published','archived'])),
    constraint articles_slug_format_check check (slug is null or slug ~ '^[a-z0-9\-]+$'::text),
    constraint articles_text_length_check check ((cover_image is null or length(cover_image) <= 2048) and (slug is null or length(slug) <= 200))
);

create index if not exists articles_site_status_idx on public.articles (website_id, status, publish_at desc);
create index if not exists articles_section_idx on public.articles (section_id);

-- ============================================================================
-- Ads & Sponsors (silo-hosted)
-- ----------------------------------------------------------------------------
-- Sponsor directory + image-banner ad units in named placements, with
-- scheduling, weighted rotation, and impression/click counters. Editorial roles
-- stay on the SANKOR hub; RLS is applied in the BYOI overlay.
-- ============================================================================
create table public.sponsors (
    id uuid not null default gen_random_uuid(),
    website_id uuid not null,
    name text not null,
    logo_url text,
    website_url text,
    tier text,
    description jsonb,
    sort_order integer default 0,
    is_active boolean default true,
    created_at timestamp with time zone default now(),
    constraint sponsors_pkey primary key (id),
    constraint sponsors_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint sponsors_name_length_check check (length(name) <= 200),
    constraint sponsors_url_length_check check ((logo_url is null or length(logo_url) <= 2048) and (website_url is null or length(website_url) <= 2048))
);

create table public.ads (
    id uuid not null default gen_random_uuid(),
    website_id uuid not null,
    sponsor_id uuid,
    name text not null,
    placement text not null,
    image_url text,
    link_url text,
    alt_text text,
    weight integer default 1,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    is_active boolean default true,
    impressions bigint default 0,
    clicks bigint default 0,
    created_at timestamp with time zone default now(),
    constraint ads_pkey primary key (id),
    constraint ads_website_id_fkey foreign key (website_id) references websites(id) on delete cascade,
    constraint ads_sponsor_id_fkey foreign key (sponsor_id) references sponsors(id) on delete set null,
    constraint ads_placement_check check (placement = any (array['header','sidebar','in_article','footer','home_hero'])),
    constraint ads_weight_check check (weight >= 1 and weight <= 100),
    constraint ads_url_length_check check ((image_url is null or length(image_url) <= 2048) and (link_url is null or length(link_url) <= 2048))
);

create index if not exists ads_site_placement_idx on public.ads (website_id, placement, is_active);
create index if not exists sponsors_site_idx on public.sponsors (website_id, sort_order);

-- Anon-callable counter bump for impressions/clicks (SECURITY DEFINER).
create or replace function public.increment_ad_stat(p_ad_id uuid, p_kind text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_kind = 'click' then
    update public.ads set clicks = clicks + 1 where id = p_ad_id;
  else
    update public.ads set impressions = impressions + 1 where id = p_ad_id;
  end if;
end;
$$;
revoke all on function public.increment_ad_stat(uuid, text) from public;
grant execute on function public.increment_ad_stat(uuid, text) to anon, authenticated;

-- Ads: AdSense (network) unit support. ad_type 'banner' = self-served image;
-- 'adsense' = a Google AdSense unit rendered from the site's publisher id + this
-- slot. (The publisher id + auto-ads toggle live on the hub, in ads_config.)
alter table public.ads add column if not exists ad_type text not null default 'banner';
alter table public.ads add column if not exists ad_slot text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'ads_ad_type_check') then
    alter table public.ads add constraint ads_ad_type_check check (ad_type in ('banner','adsense'));
  end if;
end $$;

-- Newsroom: article gallery — ordered [{ url, caption? }] shown below the body.
-- Idempotent add for silos provisioned before this column existed.
alter table public.articles add column if not exists gallery jsonb not null default '[]'::jsonb;

-- has_knowledge_docs(): boolean presence check for the public AI chat launcher.
-- knowledge_docs is owner-only under RLS, so an anonymous storefront visitor
-- can't read it to decide whether to show the launcher. This SECURITY DEFINER
-- function exposes only a boolean (never row content), so it's safe for anon.
create or replace function public.has_knowledge_docs(filter_website_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.knowledge_docs
    where website_id = filter_website_id
  );
$$;
revoke all on function public.has_knowledge_docs(uuid) from public;
grant execute on function public.has_knowledge_docs(uuid) to anon, authenticated;
