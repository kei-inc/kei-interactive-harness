-- Storage buckets. Run separately because the storage schema may be absent in
-- a plain Postgres instance.
\pset pager off
\pset tuples_only on
\pset format unaligned

select 'ERROR|public_bucket|storage.' || id ||
       '|Bucket is public. Every object in it is readable by URL, forever.'
from storage.buckets
where public = true;
