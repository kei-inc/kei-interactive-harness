-- A Supabase-shaped database for testing lib/sql/rls-audit.sql and
-- lib/sql/grants-snapshot.sql. Models an EXISTING project that is still on the
-- old platform default (new tables auto-granted), plus a few tables created the
-- new way, with explicit grants or none.
--
--   createdb harness_test && psql harness_test -f test/rls-fixture.sql
--   SUPABASE_DB_URL=postgres:///harness_test HARNESS_SUPABASE=on bash lib/scripts/check-rls.sh
--
-- Expected: 10 ERROR, 4 WARN, listed at the bottom of this file.

-- Roles are cluster-wide, so tolerate them already existing from a prior run.
do $$ begin
  create role anon nologin;          exception when duplicate_object then null; end $$;
do $$ begin
  create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin
  create role service_role nologin;  exception when duplicate_object then null; end $$;
create schema auth; create table auth.users(id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as 'select null::uuid';
create schema storage; create table storage.buckets(id text primary key, public boolean default false);
insert into storage.buckets values ('private-docs', false), ('avatars', true);

-- The old Supabase default: every new public table and sequence is granted.
alter default privileges in schema public grant select, insert, update, delete on tables to anon, authenticated, service_role;
alter default privileges in schema public grant usage, select on sequences to anon, authenticated, service_role;

create table public.leaked(id int);

create table public.notes(id uuid primary key, user_id uuid not null, body text);
alter table public.notes enable row level security;
create policy notes_select on public.notes for select using ((select auth.uid()) = user_id);
create policy notes_insert on public.notes for insert with check ((select auth.uid()) = user_id);
create policy notes_update on public.notes for update using ((select auth.uid()) = user_id);

create table public.open_wide(id int, user_id uuid);
alter table public.open_wide enable row level security;
create policy anyone on public.open_wide for select using (true);
create policy anyone_insert on public.open_wide for insert to anon with check (true);

create table public.locked(id int);
alter table public.locked enable row level security;

create table public.plans(id serial primary key, name text, price int);
alter table public.plans enable row level security;
create policy plans_read on public.plans for select using (true);

create view public.user_emails as select id, email from auth.users;
create view public.my_notes with (security_invoker = on) as select * from public.notes;

create function public.sneaky() returns int language sql security definer as 'select 1';
create function public.careful() returns int language sql security definer set search_path = '' as 'select 1';

create table public.comments(id int primary key, note_id uuid references public.notes(id));

-- The new way, done right: explicit grants, RLS, policies, as one unit.
create table public.tasks(id uuid primary key, user_id uuid not null);
revoke all on public.tasks from anon, authenticated, service_role;
grant select, insert, update, delete on public.tasks to authenticated;
grant select, insert, update, delete on public.tasks to service_role;
alter table public.tasks enable row level security;
create policy tasks_own on public.tasks for all using ((select auth.uid()) = user_id);

-- The new way, forgotten grant: policies written, grant missing. What an old
-- migration replayed into a fresh environment produces.
create table public.orders(id uuid primary key, user_id uuid not null);
revoke all on public.orders from anon, authenticated, service_role;
alter table public.orders enable row level security;
create policy orders_own on public.orders for select using ((select auth.uid()) = user_id);

-- Server-only table: RLS off, but no Data API grants. Correctly silent.
create table public.internal_jobs(id int);
revoke all on public.internal_jobs from anon, authenticated, service_role;

-- Expected ERROR (10):
--   anon_write_policy           open_wide (anyone_insert)
--   auth_users_exposed          user_emails
--   definer_without_search_path sneaky
--   policy_always_true          open_wide (anyone), open_wide (anyone_insert), plans (plans_read)
--   rls_disabled                comments, leaked
--   view_bypasses_rls           user_emails
--   public_bucket               avatars
-- Expected WARN (4):
--   auto_expose_default, policy_without_grant (orders), rls_no_policies (locked),
--   unindexed_foreign_key (comments)
-- Expected silence: notes, my_notes, careful, tasks, internal_jobs, private-docs
