#!/bin/bash
# Create the Supabase-style roles a SANKOR silo needs. GoTrue normally does this;
# the minimal stack has no GoTrue, so we create them here. Runs once, on first DB
# init, before the SANKOR schema. Idempotent. authenticator (PostgREST's login
# role) shares POSTGRES_PASSWORD so the REST service can connect.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  do \$\$
  begin
    if not exists (select from pg_roles where rolname = 'anon') then
      create role anon nologin noinherit;
    end if;
    if not exists (select from pg_roles where rolname = 'authenticated') then
      create role authenticated nologin noinherit;
    end if;
    if not exists (select from pg_roles where rolname = 'service_role') then
      create role service_role nologin noinherit bypassrls;
    end if;
    if not exists (select from pg_roles where rolname = 'authenticator') then
      create role authenticator noinherit login password '${POSTGRES_PASSWORD}';
    end if;
  end
  \$\$;

  alter role authenticator with password '${POSTGRES_PASSWORD}';
  grant anon, authenticated, service_role to authenticator;

  -- Table access is gated by RLS; the roles still need base grants to reach
  -- objects the SANKOR schema creates afterwards.
  grant usage on schema public to anon, authenticated, service_role;
  alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
  alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
  alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
EOSQL
