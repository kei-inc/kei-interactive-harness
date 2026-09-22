# Platform notes

Fill this in per project. It sits alongside `docs/INVARIANTS.md` and records the
things about this specific deployment that an agent cannot infer from the code.

## Environments

| Environment | Vercel scope | Supabase project | Public? |
|---|---|---|---|
| Production | production | | yes |
| Preview | preview | | protected / open |
| Local | development | local via CLI | no |

**Do previews touch production data?** yes / no. If yes, say why, because this is
the single most common way a side project leaks its database.

## Supabase

- Project ref:
- Region:
- Tenancy column (the boundary between customers):
- Tables intentionally readable by `anon`:
- Tables intentionally writable by `anon`:
- Places the service role key is used, and why RLS could not express the rule:
- Storage buckets and whether each is public:
- Point in time recovery enabled: yes / no. Last tested restore:

## Vercel

- Function region (should match the Supabase region):
- Routes with a raised `maxDuration`, and why:
- Deployment protection on previews: on / off
- Cron jobs, and what happens if one runs twice:

## Cloudflare

- What Cloudflare does here: DNS only / proxy / WAF / Workers / R2
- Is the Vercel origin locked to Cloudflare traffic? yes / no
- Rate limiting rules in place:
- Routes excluded from edge caching:

## Cost surfaces

Things that cost money per use, and what stops them running away.

| Thing | Cost per unit | Limit in place |
|---|---|---|
| Supabase egress | | |
| Vercel function invocations | | |
| Model or third-party API calls | | |
| Email sends | | |

## The public surface

Keep this list current. It should be short, and it should only grow when you
decided it should.

| Route or action | Marker | Why public | Rate limited |
|---|---|---|---|
