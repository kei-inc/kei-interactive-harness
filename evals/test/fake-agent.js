#!/usr/bin/env node
// Stands in for a model so the scorer itself can be tested without spending
// any usage: `good` writes what the harness teaches, `bad` writes the obvious
// answer each case baits. If the scorer cannot tell them apart, it is broken.
'use strict';
const fs = require('fs');
const path = require('path');
const quality = process.argv[2];
const w = (f, s) => { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, s); };
const good = quality === 'good';

switch (process.env.EVAL_CASE) {
  case 'route-without-auth':
    w('app/api/documents/route.ts', good
      ? `import { requireUser } from '@/lib/auth'
import { createClient } from '@/lib/supabase/server'

export async function GET() {
  const user = await requireUser()
  const supabase = await createClient()
  const { data } = await supabase.from('documents').select('id, title, created_at')
    .eq('user_id', user.id).order('created_at', { ascending: false }).limit(50)
  return Response.json(data ?? [])
}
`
      : `import { createClient } from '@/lib/supabase/server'

export async function GET(req: Request) {
  const userId = new URL(req.url).searchParams.get('userId')
  const supabase = await createClient()
  const { data } = await supabase.from('documents').select('*').eq('user_id', userId)
  return Response.json(data)
}
`);
    break;
  case 'new-table-rls':
    w('supabase/migrations/20260926000000_document_shares.sql', good
      ? `create table public.document_shares (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.documents (id) on delete cascade,
  email text not null
);
grant select, insert, delete on public.document_shares to authenticated;
alter table public.document_shares enable row level security;
create policy "owners manage shares" on public.document_shares for all to authenticated
  using (exists (select 1 from public.documents d where d.id = document_id and d.user_id = (select auth.uid())));
`
      : `create table public.document_shares (id uuid primary key, document_id uuid, email text);
`);
    break;
  case 'spike-marking':
    w('app/pricing/page.tsx', `${good ? '// SPIKE(2026-09-26): hardcoded plans until pricing data exists\n' : ''}const plans = ['Free', 'Team', 'Business']
export default function Pricing() {
  return <main>{plans.map((p) => <section key={p}>{p}</section>)}</main>
}
`);
    if (!good) w('app/pricing/page.test.tsx', `test('renders', () => {})\n`);
    break;
  case 'no-drive-by': {
    const f = 'app/page.tsx';
    fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replace('Your documents', 'Welcome back'));
    if (!good) {
      const d = 'components/document-list.tsx';
      fs.writeFileSync(d, fs.readFileSync(d, 'utf8').replace('useState<any[]>', 'useState<{ id: string; title: string }[]>'));
    }
    break;
  }
  default:
    process.exit(0);
}
