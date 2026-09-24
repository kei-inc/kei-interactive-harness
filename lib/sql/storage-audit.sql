-- Storage buckets. Supabase always has the storage schema; a query that fails
-- here is a real failure, so a completion marker follows the findings.
-- Stop at the first error, so the completion marker at the end can only
-- appear if every query before it actually succeeded.
\set ON_ERROR_STOP on
\pset pager off
\pset tuples_only on
\pset format unaligned

select 'ERROR|public_bucket|storage.' || id ||
       '|Bucket is public: every object is readable by URL, forever. Making it private is an app change first ' ||
       '(readers need createSignedUrl, servers need storage.download instead of fetch(publicUrl)), and only ' ||
       'then a migration. Deploy the app before the migration or media breaks. If public is intended, ' ||
       'add it to .harness/rls-allow.txt with a reason.'
from storage.buckets
where public = true;

select 'MARKER|harness|storage-complete|';
