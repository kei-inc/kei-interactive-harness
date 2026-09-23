-- Emits the Data API grants this database has TODAY, as migration statements.
-- Read-only. GRANT is idempotent, so applying the output to production changes
-- nothing; its purpose is to make environments rebuilt from migrations match.
--
-- Lines are marked REVIEW where anon can write to a table with RLS off, which
-- is the combination the audit reports as an exposure.

\pset pager off
\pset tuples_only on
\pset format unaligned

with roles(role) as (
  select rolname from pg_roles where rolname in ('anon', 'authenticated', 'service_role')
),
rels as (
  select c.oid, c.relname, c.relkind, c.relrowsecurity
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
),
tprivs as (
  select r.relname, ro.role,
         string_agg(p.priv, ', ' order by p.ord) as privs,
         bool_or(ro.role = 'anon' and p.priv <> 'select' and r.relkind in ('r', 'p') and not r.relrowsecurity) as risky
  from rels r cross join roles ro
  cross join lateral (values (1, 'select'), (2, 'insert'), (3, 'update'), (4, 'delete')) p(ord, priv)
  where has_table_privilege(ro.role, r.oid, p.priv)
  group by r.relname, ro.role
),
seqs as (
  select c.relname, ro.role
  from pg_class c join pg_namespace n on n.oid = c.relnamespace cross join roles ro
  where n.nspname = 'public' and c.relkind = 'S' and has_sequence_privilege(ro.role, c.oid, 'USAGE')
)
select line from (
  select 1 as grp, relname as k1, role as k2,
         format('grant %s on table public.%I to %I;', privs, relname, role) ||
         case when risky then '   -- REVIEW: anon can write and RLS is off' else '' end as line
  from tprivs
  union all
  select 2, relname, role, format('grant usage, select on sequence public.%I to %I;', relname, role)
  from seqs
) x
order by grp, k1, k2;
