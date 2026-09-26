import 'server-only'
import { cookies } from 'next/headers'
import { createServerClient } from '@supabase/ssr'

/** A Supabase client acting as the signed-in user, so RLS applies. */
export async function createClient() {
  const store = await cookies()
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    { cookies: { getAll: () => store.getAll(), setAll: (all) => all.forEach((c) => store.set(c.name, c.value, c.options)) } },
  )
}
