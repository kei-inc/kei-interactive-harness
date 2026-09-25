# Working agreement

This file is the contract between me and any AI agent working in this repo
(Cursor, Claude Code, Codex, whatever comes next). Read it before you touch code.

## How I build

I build by feel. I put up a scaffold, play with it, revise, and let the shape
emerge. I do not want a full specification up front, and I do not want you to
invent one. Do not write a plan document unless I ask for one.

That is not the same as building without context. `docs/CONTEXT.md` says what
we are making and why, and points at the design references: Figma files,
prototypes, comparable products, the vocabulary the product uses for its own
things. Read it at the start of a session. Treat what it marks as settled as
ground to build on, and what it marks as still moving as ground that may shift.
It is a map of intent, not a contract.

## Two modes

There are two kinds of decision in this codebase and I want you in a different
posture for each.

**Where I have taste, defer.** Layout, interaction, copy, flow, what the thing
should feel like, which of two approaches reads better on screen. I come from
interaction design. Offer alternatives if you see them, then build what I pick
without relitigating it. Do not add caution here; it slows me down and it is not
where the risk is.

**Where I need an expert, hold the line.** Authorization, data boundaries,
migrations, secrets, anything under the non-negotiables below, anything that
will be expensive or impossible to undo. I am a capable coder but not a computer
scientist, and this is exactly the territory where I want to be stopped before I
do something stupid. Push back plainly, explain what breaks, and do not soften
it because I seem sure. If I insist after you have explained, comply and mark
it in `docs/INVARIANTS.md` under known accepted risks.

If you are not sure which mode a decision falls in, ask which it is rather than
guessing. The answer is usually obvious once the question is put.

What this means for you:

- **Prefer the smallest thing that lets me see it working.** A rough screen I can
  click beats a correct abstraction I cannot.
- **Do not refactor code I did not ask you to touch.** Drive-by cleanups hide the
  diff I am actually trying to read. If you see something worth fixing, put it in
  `docs/REPAIR-QUEUE.md` and keep going.
- **Do not add abstraction on speculation.** No config systems, no plugin layers,
  no generic base classes until there are at least three real callers.
- **Small diffs.** If a change touches more than about six files, stop and tell me
  what you are about to do first.
- **Do not generate tests during exploration.** Tests pin behaviour, and during a
  spike the behaviour is the thing that is still moving. We backfill tests when a
  feature settles, using the `/backfill` ritual.

## Maturity markers

Code in this repo lives in one of two states, and you should say which one you are
writing in.

- **Spike.** A specific piece of code that is knowingly not fit to ship. Not a
  branch, not a mode: a label on the code itself. The test is simple. If it
  could go to production exactly as written, it is not a spike, however
  experimental it feels. If it could not (auth faked, hardcoded data standing in
  for a query, a missing error state, a disabled check), mark it with a dated
  comment at the top of the file or block:
  `SPIKE(2026-09-22): hardcoded race list until the query shape settles`.
  CI allows spikes on the `play` branch and rejects them on any pull request
  into the default branch, so they cannot leak into production. The date matters, because a spike older than a
  month is no longer exploration, it is debt, and the harness will start saying so.
- **Settled.** Has tests, has validated inputs, has explicit authorization, has
  bounded queries. Once something is settled, treat regressions as bugs.

The `SPIKE:` marker is how I buy freedom without losing track of debt. Whenever
you cut a corner on purpose, mark it without being asked rather than quietly
leaving rough code unmarked.

## Where work happens

Day-to-day work goes on a long-lived `play` branch, not on `main`. Commit and
push freely there; nothing needs a pull request. When a batch settles, one pull
request from `play` into `main`, merged with a merge commit, and `play` carries
on. `docs/WORKFLOW.md` has the commands. If you are on `main` with changes to
make, stop and tell me first.

## Non-negotiables (these apply even in a spike)

These are the things that are expensive or impossible to fix later. Never trade
them for speed, and flag it loudly if I ask you to.

1. **No secrets in the repo, ever.** Not in code, not in tests, not in fixtures,
   not in comments. Server secrets live in server-side environment variables only.
   Anything in a client-exposed variable (`NEXT_PUBLIC_*`, `VITE_*`, `PUBLIC_*`)
   is published to the world. Treat it as such.
2. **Authorization happens in the query, not after it.** Every read or write of
   user-owned data filters by the owner as part of the database query. Fetching a
   row and then checking ownership in application code is a bug, because the next
   person to touch that code will forget the check.
3. **Every route declares its access level explicitly.** There is no such thing as
   an implicitly public endpoint. If you add a handler, state who may call it.
4. **All external input is parsed by a schema at the boundary.** Request bodies,
   query params, webhook payloads, file uploads, third-party API responses. Derive
   the TypeScript type from the schema rather than declaring it separately.
5. **Every list query is bounded.** A `limit` with a sane default and a hard cap.
   Never `SELECT *` with no limit on a table that grows with usage.
6. **No string-built SQL.** Parameterized queries or a query builder only.
7. **No unsanitized HTML injection.** No `innerHTML` or `dangerouslySetInnerHTML`
   with anything that came from a user.
8. **Server never fetches a user-supplied URL** without an explicit allowlist.
9. **Errors returned to clients are generic.** Stack traces, SQL, and internal
   identifiers go to logs, never to a response body.
10. **Destructive migrations are separate, reviewed commits.** Never bundle a drop
    or a rename into a feature commit.

If you are about to violate one of these because I asked you to, say so plainly
before you do it.

## What to flag rather than silently decide

Stop and ask me when a change would:

- add a dependency (name it, say what it replaces, say how big it is)
- change a database schema
- change an authentication or authorization path
- introduce a background job, cron, or queue
- send data to a third party
- add a new environment variable

## Project shape

See `docs/INVARIANTS.md` for what must be true of this specific system: the trust
boundaries, who can see what, and what is expensive. Read it before writing any
code that touches data. If you find something in the code that contradicts that
file, tell me, because one of the two is wrong.

## The contract

The harness checks the things below. Each is cheap to do while writing and
expensive to retrofit, so do it the first time rather than fixing it later.
This is the whole reason the checks exist: not to catch you, but to make the
right shape the default shape.

Rows marked *(Supabase)* apply only once the project uses Supabase; the rest
apply everywhere.

| The check looks for | So, as you write |
|---|---|
| *(Supabase)* A migration creating a table without RLS | Grants, `enable row level security`, and policies, as one unit in the same migration |
| *(Supabase)* A created table with no grant | Grant only the roles that need it, or mark the migration `-- @no-data-api` |
| *(Supabase)* The service role or secret key outside `server-only` files | `import 'server-only'` at the top of any file that touches it |
| A `route.ts` or `"use server"` file with no identity check | Call `requireUser()` first, or write `// @public-route` / `// @public-action` with a reason |
| *(Supabase)* `getSession()` in server code | `getUser()`, or `// @allow-getsession` with a reason |
| Caching in a file that touches user identity | Put the user or tenant id in the cache key, then `// @cache-reviewed` |
| A secret-looking name behind `NEXT_PUBLIC_` | Server env only; if it is genuinely public, list it in `.harness/allow-public-env.txt` |
| A `process.env.X` missing from `.env.example` | Add it with a placeholder in the same change |
| A Next.js app with no Sentry or Speed Insights (flagged, never blocks) | `/monitor` and `/perf` set them up |
| Unbounded `.select()` | `.limit(n)` with a hard cap, or `.single()` |
| A row spread into a response | Pick the fields |
| `fetch` with no signal | `signal: AbortSignal.timeout(ms)` |
| `any`, `@ts-ignore`, `eslint-disable`, `foo!.bar` | Avoid by default; they are counted, not banned |
| An undated `SPIKE:` | `SPIKE(YYYY-MM-DD):` |

Run `npx harness quick` before you say a change is done. If it reports
something on code you just wrote, the fix is almost always one of the rows
above.

## Rituals

Do not run these unprompted. I invoke them when a session settles.
`docs/WORKFLOW.md` walks through where each one falls in a normal day.

| Command | What it does |
|---|---|
| `/repair` | Review the current diff against the invariants and the working agreement |
| `/threat` | Adversarial security pass on a named feature |
| `/scale` | Performance and growth pass on a named feature |
| `/backfill` | Write the tests for a feature whose shape has settled |

The workflow commands move work between `play` and `main` from chat, so I never
need a terminal for it. Also only when I invoke them.

| Command | What it does |
|---|---|
| `/status` | Where am I: branch, uncommitted work, spikes, ratchet, open pull request. Read-only |
| `/play` | Get onto `play` (creating it if needed) and bring it up to date with main |
| `/ship` | Commit, surface what will block, push, and open or update the pull request into main |
| `/land` | Merge the green pull request with a merge commit and bring `play` back in step |
| `/sync` | Update to the latest harness release and merge template changes into project files |
| `/doctor` | Health check: harness version, drift, unmerged files, blank docs, GitHub settings |
| `/debt` | The ratchet's long view: goals, where the debt lives, cheap wins |
| `/authtest` | Inventory route handlers and server actions, agree who may call each, and write tests proving the wrong caller is turned away |
| `/offline` | Map the offline path, agree scenarios, and test that queued work survives and arrives exactly once |
| `/perf` | Speed Insights for real users, a bundle budget for every build, and a slow-query report |
| `/monitor` | Sentry in each app: server and browser errors, readable stack traces, no personal data, alerts |

## Commands

```
npx harness quick          # what pre-commit runs, a few seconds
npx harness check          # what pre-push runs, under a minute
npx harness full           # what CI runs, including security scans
npx harness ratchet        # debt against the baseline, tightens on improvement
npx harness ratchet --new  # only what this branch added
npx harness ratchet --goals
npx harness rls            # audit the live database (needs SUPABASE_DB_URL)
npx harness doctor         # version, drift, what is mine vs managed
```
