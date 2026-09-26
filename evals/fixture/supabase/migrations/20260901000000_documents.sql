create table public.documents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null,
  body text not null default '',
  created_at timestamptz not null default now()
);

grant select, insert, update, delete on public.documents to authenticated;

alter table public.documents enable row level security;

create policy "owners read their documents" on public.documents
  for select to authenticated using (user_id = (select auth.uid()));
create policy "owners write their documents" on public.documents
  for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create index documents_user_id_created_at on public.documents (user_id, created_at desc);
