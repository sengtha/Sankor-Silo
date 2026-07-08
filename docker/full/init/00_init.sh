#!/bin/bash
# Full-stack DB bootstrap: the Supabase-style roles + JWT settings the platform
# services expect. GoTrue creates the auth schema/functions itself on startup,
# so (unlike the minimal stack) there is no auth shim here. Runs once, before the
# SANKOR schema. Reads JWT_SECRET + POSTGRES_PASSWORD from the container env.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  do \$\$
  begin
    if not exists (select from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if;
    if not exists (select from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
    if not exists (select from pg_roles where rolname = 'service_role') then create role service_role nologin noinherit bypassrls; end if;
    if not exists (select from pg_roles where rolname = 'authenticator') then create role authenticator noinherit login password '${POSTGRES_PASSWORD}'; end if;
    if not exists (select from pg_roles where rolname = 'supabase_auth_admin') then create role supabase_auth_admin noinherit login password '${POSTGRES_PASSWORD}'; end if;
    if not exists (select from pg_roles where rolname = 'supabase_storage_admin') then create role supabase_storage_admin noinherit login password '${POSTGRES_PASSWORD}'; end if;
  end
  \$\$;

  alter role authenticator          with password '${POSTGRES_PASSWORD}';
  alter role supabase_auth_admin    with password '${POSTGRES_PASSWORD}';
  alter role supabase_storage_admin with password '${POSTGRES_PASSWORD}';
  grant anon, authenticated, service_role to authenticator;

  create schema if not exists auth    authorization supabase_auth_admin;
  create schema if not exists storage authorization supabase_storage_admin;
  grant create, usage on schema auth to supabase_auth_admin;
  grant all on schema storage to supabase_storage_admin;

  grant usage on schema public to anon, authenticated, service_role;
  alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
  alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
  alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

  -- Some SANKOR/Supabase SQL reads the JWT secret from a DB setting.
  alter database ${POSTGRES_DB} set "app.settings.jwt_secret" to '${JWT_SECRET}';
  alter database ${POSTGRES_DB} set "app.settings.jwt_exp"    to '3600';
EOSQL
