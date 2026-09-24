-- Data API exposure audit.
--
-- In a Supabase app the anon key ships to every browser, so what a stranger can
-- reach is decided in Postgres by two layers:
--
--   GRANTS decide whether a role can reach a table at all.
--   RLS    decides which rows that role sees once it can.
--
-- Since Supabase's Data API change (default for new projects from 2026-05-30,
-- enforced on existing projects from 2026-10-30), new tables in public get no
-- grants automatically. So "RLS is off" is only an exposure when anon or
-- authenticated can actually reach the table. Every check below is grant-aware.
--
-- Output is pipe-delimited: severity|check|object|detail
-- ERROR rows fail CI. WARN rows are reported and never fail.

-- Stop at the first error, so the completion marker at the end can only
-- appear if every query before it actually succeeded.
\set ON_ERROR_STOP on
\pset pager off
\pset tuples_only on
\pset format unaligned
\pset fieldsep '|'

with
tbl as (
  select c.oid, c.relname, c.relkind, c.relrowsecurity, c.reloptions,
         'public.' || c.relname as fq,
         has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE')          as anon_any,
         has_table_privilege('anon', c.oid, 'INSERT,UPDATE,DELETE')                 as anon_write,
         has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE') as auth_any
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
),
pol as (
  select p.*, t.fq, t.anon_any, t.anon_write, t.auth_any,
         (0 = any(p.polroles) or p.polroles @> array[(select oid from pg_roles where rolname = 'anon')]::oid[])          as reaches_anon,
         (0 = any(p.polroles) or p.polroles @> array[(select oid from pg_roles where rolname = 'authenticated')]::oid[]) as reaches_auth
  from pg_policy p join tbl t on t.oid = p.polrelid
),
findings as (

  -- The big one. Reachable through the Data API with no row filtering at all.
  select 'ERROR'::text as severity, 'rls_disabled'::text as check_name, fq as object,
         ('RLS is off and ' ||
          case when anon_any and auth_any then 'anon and authenticated'
               when anon_any then 'anon' else 'authenticated' end ||
          ' can reach this table. Anyone with the anon key can read or write every row.')::text as detail
  from tbl
  where relkind in ('r', 'p') and not relrowsecurity and (anon_any or auth_any)

  union all

  -- A policy whose effective condition is literally true, on a table the
  -- policy's roles can actually reach. INSERT uses WITH CHECK only; UPDATE and
  -- ALL fall back to USING when WITH CHECK is absent, as Postgres does.
  select 'ERROR', 'policy_always_true', fq || ' (' || polname || ')',
         'Effective condition for ' ||
           case polcmd when 'r' then 'SELECT' when 'a' then 'INSERT' when 'w' then 'UPDATE'
                       when 'd' then 'DELETE' else 'ALL' end ||
           ' is always true, so every reachable row is visible to ' ||
           case when reaches_anon and anon_any then 'anyone with the anon key' else 'every signed-in user' end || '.'
  from pol
  where ((reaches_anon and anon_any) or (reaches_auth and auth_any))
    and (
      (polcmd in ('r', 'w', 'd', '*') and coalesce(pg_get_expr(polqual, polrelid), 'true') = 'true')
      or
      (polcmd in ('a', 'w', '*')
         and coalesce(pg_get_expr(polwithcheck, polrelid), pg_get_expr(polqual, polrelid), 'true') = 'true')
    )

  union all

  -- Unauthenticated writes: anon holds a write grant, a write policy reaches
  -- anon, and its condition does not depend on the caller's identity.
  select 'ERROR', 'anon_write_policy', fq || ' (' || polname || ')',
         'Unauthenticated writes allowed: anon has a write grant and the policy condition does not depend on auth.*'
  from pol
  where polcmd in ('a', 'w', 'd', '*') and reaches_anon and anon_write
    and coalesce(pg_get_expr(polwithcheck, polrelid), pg_get_expr(polqual, polrelid), 'true') not ilike '%auth.%'

  union all

  -- A view runs with its owner's rights unless security_invoker is set, so it
  -- reads past the RLS of every table underneath. Only a problem if reachable.
  select 'ERROR', 'view_bypasses_rls', fq,
         'Reachable view is not security_invoker, so it reads underlying tables as its owner.'
  from tbl
  where relkind = 'v' and (anon_any or auth_any)
    and not coalesce(
      (select lower(option_value) in ('on', 'true', 'yes', '1')
         from pg_options_to_table(reloptions) where option_name = 'security_invoker'), false)

  union all

  select 'ERROR', 'auth_users_exposed', fq,
         'Reachable view in the public schema reads auth.users.'
  from tbl
  where relkind = 'v' and (anon_any or auth_any)
    and pg_get_viewdef(oid) ilike '%auth.users%'

  union all

  -- SECURITY DEFINER bypasses RLS. Without a pinned search_path a caller can
  -- shadow the objects it references. Functions default to PUBLIC execute.
  select 'ERROR', 'definer_without_search_path', 'public.' || p.proname,
         'Callable SECURITY DEFINER function with no pinned search_path. Add: set search_path = ''''.'
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
    and (p.proconfig is null
         or not exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search\_path=%'))

  union all

  -- Breakage, not exposure: policies were written for a role that has no grant,
  -- so every Data API call from that role fails with 42501 permission denied.
  -- This is exactly what a migration written before the grants change produces
  -- when replayed into a fresh environment.
  select 'WARN', 'policy_without_grant', fq || ' (' || string_agg(distinct r.role, ', ') || ')',
         'Policies exist for this role but it has no grant, so its Data API calls fail with 42501. Add an explicit grant in a migration.'
  from pol
  cross join lateral (values ('anon', reaches_anon and not anon_any),
                             ('authenticated', reaches_auth and not auth_any)) r(role, missing)
  where r.missing and not (r.role = 'anon' and 0 = any(polroles))   -- PUBLIC policies need not imply anon
  group by fq

  union all

  select 'WARN', 'rls_no_policies', fq,
         'RLS is on but no policies exist, so the Data API returns nothing from this table.'
  from tbl t
  where relkind in ('r', 'p') and relrowsecurity and (anon_any or auth_any)
    and not exists (select 1 from pg_policy p where p.polrelid = t.oid)

  union all

  -- The old platform default is still in force on this project: every new
  -- public table is auto-granted. Harmless for existing tables, but it means
  -- migrations here have never needed grants, so a fresh environment built
  -- from them (db reset, branching, a new deploy) will break once the default
  -- flips. Run `npx harness grants` to capture today's grants as a migration.
  select distinct 'WARN', 'auto_expose_default', 'public (default privileges)',
         'New public tables are still auto-granted to anon/authenticated. Supabase ends this on 2026-10-30; capture explicit grants in migrations now (npx harness grants).'
  from pg_default_acl d
  join pg_namespace n on n.oid = d.defaclnamespace
  cross join lateral aclexplode(d.defaclacl) a
  where n.nspname = 'public' and d.defaclobjtype = 'r'
    and a.grantee in (select oid from pg_roles where rolname in ('anon', 'authenticated'))

  union all

  -- RLS policies are evaluated per row. An unindexed column in the filter path
  -- turns every query into a sequential scan once the table is real.
  select 'WARN', 'unindexed_foreign_key',
         ct.conrelid::regclass::text || ' (' || a.attname || ')',
         'Foreign key has no leading-column index. RLS and joins will scan.'
  from pg_constraint ct
  join lateral unnest(ct.conkey) as k(attnum) on true
  join pg_attribute a on a.attrelid = ct.conrelid and a.attnum = k.attnum
  join pg_class c on c.oid = ct.conrelid
  join pg_namespace n on n.oid = c.relnamespace
  where ct.contype = 'f' and n.nspname = 'public'
    and not exists (select 1 from pg_index i where i.indrelid = ct.conrelid and i.indkey[0] = k.attnum)
)
select severity || '|' || check_name || '|' || object || '|' || detail
from findings
order by severity, check_name, object;

-- Completion marker. check-rls.sh refuses to call the database clean unless
-- this line arrives, so a query that silently returns nothing (wrong database,
-- dropped connection, a broken client) can never pass as "no findings".
select 'MARKER|harness|audit-complete|';
