-- Row level security audit.
--
-- In a Supabase application the anon key is published to every browser, so
-- Postgres RLS is the actual security perimeter. Every check below either
-- passes or represents a way for a stranger with devtools to reach your data.
--
-- Output is pipe-delimited: severity|check|object|detail
-- ERROR rows fail CI. WARN rows are reported and counted.

\pset pager off
\pset tuples_only on
\pset format unaligned
\pset fieldsep '|'

with findings as (

  -- The big one. No RLS means the anon key can read and write this table.
  select 'ERROR'::text as severity,
         'rls_disabled'::text as check_name,
         (n.nspname || '.' || c.relname)::text as object,
         'RLS is off. Anyone holding the anon key can read and write this table.'::text as detail
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p')
    and not c.relrowsecurity

  union all

  -- A policy whose effective condition is literally true grants access to
  -- everyone it applies to. This is the quiet version of having no RLS at all.
  --
  -- Which clause is "effective" depends on the command. INSERT policies have
  -- only WITH CHECK and no USING, so testing USING alone would flag every
  -- insert policy in the database. UPDATE and ALL fall back to USING when
  -- WITH CHECK is absent, which is what Postgres itself does.
  --
  -- Deliberately public tables (a pricing table, say) go in
  -- .harness/rls-allow.txt so this stops reporting them.
  select 'ERROR',
         'policy_always_true',
         n.nspname || '.' || c.relname || ' (' || p.polname || ')',
         'Effective policy condition for ' ||
           case p.polcmd when 'r' then 'SELECT' when 'a' then 'INSERT'
                         when 'w' then 'UPDATE' when 'd' then 'DELETE' else 'ALL' end ||
           ' is always true, so RLS is decorative here.'
  from pg_policy p
  join pg_class c on c.oid = p.polrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and (
      -- read side: SELECT, UPDATE, DELETE, ALL use USING
      (p.polcmd in ('r', 'w', 'd', '*')
         and coalesce(pg_get_expr(p.polqual, p.polrelid), 'true') = 'true')
      or
      -- write side: INSERT uses WITH CHECK; UPDATE and ALL fall back to USING
      (p.polcmd in ('a', 'w', '*')
         and coalesce(pg_get_expr(p.polwithcheck, p.polrelid),
                      pg_get_expr(p.polqual, p.polrelid), 'true') = 'true')
    )

  union all

  -- Write access reachable by an unauthenticated request.
  --
  -- A policy with no TO clause applies to PUBLIC, which includes anon, and
  -- most Supabase policies are written that way. That alone is fine: if the
  -- condition references auth.uid(), auth.jwt() or auth.role(), an anon request
  -- evaluates it against NULL and fails. So this flags only policies that anon
  -- can reach AND whose condition does not depend on the caller's identity.
  -- Occasionally intentional for a contact form. Usually a mistake.
  select 'ERROR',
         'anon_write_policy',
         n.nspname || '.' || c.relname || ' (' || p.polname || ')',
         'Unauthenticated writes allowed: policy reaches anon and its condition does not depend on auth.*'
  from pg_policy p
  join pg_class c on c.oid = p.polrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and p.polcmd in ('a', 'w', 'd', '*')
    and (
      0 = any(p.polroles)
      or p.polroles @> array[(select oid from pg_roles where rolname = 'anon')]::oid[]
    )
    and coalesce(pg_get_expr(p.polwithcheck, p.polrelid),
                 pg_get_expr(p.polqual, p.polrelid), 'true') not ilike '%auth.%'

  union all

  -- A view in the public schema runs with the definer's rights unless
  -- security_invoker is set, which means it can quietly read past the RLS of
  -- every table underneath it.
  select 'ERROR',
         'view_bypasses_rls',
         n.nspname || '.' || c.relname,
         'View is not security_invoker, so it reads underlying tables as its owner.'
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'v'
    -- Postgres accepts on, true, yes and 1. Supabase's docs use "on".
    and not coalesce(
      (select lower(option_value) in ('on', 'true', 'yes', '1')
         from pg_options_to_table(c.reloptions)
        where option_name = 'security_invoker'), false)

  union all

  -- Anything in public that reads auth.users exposes the whole identity table,
  -- including email addresses and provider identifiers.
  select 'ERROR',
         'auth_users_exposed',
         n.nspname || '.' || c.relname,
         'Object in the public schema reads auth.users.'
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'v'
    and pg_get_viewdef(c.oid) ilike '%auth.users%'

  union all

  -- SECURITY DEFINER runs as the function owner and bypasses RLS. Without a
  -- pinned search_path a caller can shadow the objects it references.
  select 'ERROR',
         'definer_without_search_path',
         n.nspname || '.' || p.proname,
         'SECURITY DEFINER function with no pinned search_path. Add: set search_path = ''''.'
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosecdef
    and (p.proconfig is null
         or not exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search\_path=%'))

  union all

  -- RLS on with no policies at all fails closed. Safe, and almost always means
  -- someone enabled RLS and never came back.
  select 'WARN',
         'rls_no_policies',
         n.nspname || '.' || c.relname,
         'RLS is on but no policies exist, so nothing can read this table.'
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p')
    and c.relrowsecurity
    and not exists (select 1 from pg_policy p where p.polrelid = c.oid)

  union all

  -- RLS policies are evaluated per row. An unindexed column in the filter path
  -- turns every query into a sequential scan once the table is real.
  select 'WARN',
         'unindexed_foreign_key',
         ct.conrelid::regclass::text || ' (' || a.attname || ')',
         'Foreign key has no leading-column index. RLS and joins will scan.'
  from pg_constraint ct
  join lateral unnest(ct.conkey) as k(attnum) on true
  join pg_attribute a on a.attrelid = ct.conrelid and a.attnum = k.attnum
  join pg_class c on c.oid = ct.conrelid
  join pg_namespace n on n.oid = c.relnamespace
  where ct.contype = 'f'
    and n.nspname = 'public'
    and not exists (
      select 1 from pg_index i
      where i.indrelid = ct.conrelid and i.indkey[0] = k.attnum
    )
)
select severity || '|' || check_name || '|' || object || '|' || detail
from findings
order by severity, check_name, object;
