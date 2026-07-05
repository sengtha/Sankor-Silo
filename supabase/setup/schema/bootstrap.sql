-- ============================================================================
-- SANKOR-BYOI silo · one-shot schema bootstrap
-- ----------------------------------------------------------------------------
-- Applies the content schema and then the BYOI overlay, in the correct order.
-- Both are idempotent, so this is safe to re-run.
--
-- ⚠ Run this with **psql**, not the Supabase SQL editor — the editor does not
--   support the \ir include command. For the dashboard SQL editor, paste the
--   two files yourself in this order: sankor_content_schema.sql, then
--   sankor_byoi_schema.sql.
--
-- Usage (from anywhere; paths are resolved relative to THIS file):
--   psql "postgresql://postgres:<pw>@db.<ref>.supabase.co:5432/postgres" \
--        -v ON_ERROR_STOP=1 -f supabase/setup/schema/bootstrap.sql
--
-- Prerequisites (enable in Dashboard → Database → Extensions first):
--   pgcrypto, uuid-ossp, vector   (+ pg_cron, pg_net only for the AI agent)
--
-- After this runs, seed the site identity (overlay section 5): byoi_config +
-- websites with your real website_id and hub URL.
-- ============================================================================

\echo '→ Applying content schema (step 1/2)…'
\ir sankor_content_schema.sql

\echo '→ Applying BYOI overlay (step 2/2)…'
\ir sankor_byoi_schema.sql

\echo ''
\echo '✓ SANKOR silo schema applied.'
\echo '  Next: seed byoi_config + websites (see sankor_byoi_schema.sql section 5),'
\echo '  set edge-function secrets, and deploy authenticate-sankor-user.'
