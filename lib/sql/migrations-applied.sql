-- Versions recorded as applied by the Supabase CLI, one per line, then a
-- completion marker so an empty result cannot be mistaken for "none applied".
\pset pager off
\pset tuples_only on
\pset format unaligned
select version from supabase_migrations.schema_migrations order by version;
select 'MARKER|harness|migrations-complete|';
