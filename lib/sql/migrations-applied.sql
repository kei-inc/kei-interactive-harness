-- Versions recorded as applied by the Supabase CLI, one per line, then a
-- completion marker so an empty result cannot be mistaken for "none applied".
-- Stop at the first error, so the completion marker at the end can only
-- appear if every query before it actually succeeded.
\set ON_ERROR_STOP on
\pset pager off
\pset tuples_only on
\pset format unaligned
select version from supabase_migrations.schema_migrations order by version;
select 'MARKER|harness|migrations-complete|';
