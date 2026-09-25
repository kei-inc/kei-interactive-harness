# /perf

Make performance something the project measures instead of something I notice.
Three layers: what real users experience, what each build ships, and what the
database does. Set up the ones that are missing, then report where it is slow
today. Work on `play`.

## 1. Survey

For each Next.js app (every `package.json` that depends on `next`): whether
`@vercel/speed-insights` is installed and rendered, whether there is a `size`
script, and what the last build shipped. Build each app once and record its
client JavaScript (gzipped, everything under `.next/static/chunks`) and the
heaviest routes from the build output.

Report the numbers before changing anything.

## 2. Real users: Speed Insights

Add `@vercel/speed-insights` and render `<SpeedInsights />` (from
`@vercel/speed-insights/next`) in each app's root layout. It reports Core Web
Vitals from real visits, per route, in the Vercel dashboard.

It also has to be enabled per Vercel project (the Speed Insights tab), and it
is metered on paid plans. Tell me which projects to enable and let me check the
cost; that part is mine.

Skip it for an app I say is internal or offline-only, and add that app to
`HARNESS_OBSERVABILITY_SKIP` in `.harness/config.sh` so the flag stops.

## 3. Every build: a bundle budget

CI already runs a `size` script after the build, and flags it when there is
none. Give it one:

- Use `size-limit` with `@size-limit/file`, one config per app, measuring the
  gzipped client JavaScript under `.next/static/chunks`. Add route-level
  entries for the two or three routes that matter most on a slow connection if
  the build output makes them separable.
- Set each limit at today's size plus about 10%, so the budget catches the next
  heavy dependency, not today's baseline.
- In a monorepo, each app gets its own `size` script and the root one runs
  them all (`turbo run size`), after the build. CI builds first, so the output
  is there.

Raising a limit later is allowed, but it is a decision: the diff changes the
number, and the commit says what was added and why it is worth the weight.

## 4. The database

- The RLS audit's `unindexed_foreign_key` warnings. Write one migration adding
  the missing indexes. Plain `create index`, since migrations run in a
  transaction; on a table large enough for that to lock noticeably, say so and
  ask.
- Slow queries on production, read-only: `supabase inspect db outliers` and
  `supabase inspect db calls` with the session pooler URL I provide, or the
  Supabase performance advisors. Report the top five by total time, with the
  code that issues each one, and what would fix it (an index, a narrower
  select, a limit, fewer round trips).

Never run anything against production that writes, and never add indexes to
production by hand: the fix is a migration.

## 5. Report

The baseline numbers, what was set up, the slow queries, and up to three
concrete fixes ordered by how much they would help versus what they cost. Ask
which to do. Deeper work on a specific path (an ingest pipeline, a page that
renders a large collection) is `/scale`.
