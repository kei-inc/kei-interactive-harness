-- A Supabase-shaped database with known good and known bad patterns, for
-- testing changes to lib/sql/rls-audit.sql. Every object is either a deliberate
-- mistake the audit must catch, or a correct pattern it must stay silent on.
--
--   createdb harness_test && psql harness_test -f test/rls-fixture.sql
--   SUPABASE_DB_URL=postgres:///harness_test bash lib/scripts/check-rls.sh
--
-- Expected: 9 ERROR, 2 warn. Expected silence: notes, my_notes, careful, private-docs.

create role anon nologin; create role authenticated nologin;
create schema auth; create table auth.users(id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as 'select null::uuid';
create schema storage; create table storage.buckets(id text primary key, public boolean default false);
insert into storage.buckets values ('private-docs', false), ('avatars', true);  -- avatars: BAD

create table public.leaked(id int);                                            -- BAD rls_disabled

-- GOOD: the way Supabase docs say to write it, including an INSERT policy and
-- PUBLIC-role policies gated on auth.uid(). Must produce no findings.
create table public.notes(id uuid primary key, user_id uuid not null, body text);
alter table public.notes enable row level security;
create policy notes_select on public.notes for select using ((select auth.uid()) = user_id);
create policy notes_insert on public.notes for insert with check ((select auth.uid()) = user_id);
create policy notes_update on public.notes for update using ((select auth.uid()) = user_id);

create table public.open_wide(id int, user_id uuid);                          -- BAD x3
alter table public.open_wide enable row level security;
create policy anyone on public.open_wide for select using (true);
create policy anyone_insert on public.open_wide for insert to anon with check (true);

create table public.locked(id int);                                            -- warn
alter table public.locked enable row level security;

create table public.plans(id int, name text, price int);                       -- BAD unless allowlisted
alter table public.plans enable row level security;
create policy plans_read on public.plans for select using (true);

create view public.user_emails as select id, email from auth.users;           -- BAD x2
create view public.my_notes with (security_invoker = on) as select * from public.notes;  -- GOOD

create function public.sneaky() returns int language sql security definer as 'select 1';                        -- BAD
create function public.careful() returns int language sql security definer set search_path = '' as 'select 1'; -- GOOD

create table public.comments(id int primary key, note_id uuid references public.notes(id));  -- BAD rls, warn fk
