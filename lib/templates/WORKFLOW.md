# The cycle

How a feature actually moves through this harness, start to finish. Written as
a day rather than a checklist, because the point is where the weight sits rather
than which commands exist.

The worked example is a real one: letting someone share a document with a
teammate. Substitute your own feature; the rhythm is the same.

---

## Morning: scaffold

Branch and start talking to the agent. Nothing ceremonial happens here.

The rules in `.cursor/rules/` are already shaping what gets written, invisibly,
which is the cheapest place in the whole system to prevent a problem. Ask for a
share dialog and a `document_shares` table, and because the Supabase rules are
loaded, the migration comes back with RLS enabled and policies in the same file
without you having asked for either.

The agent marks what it knows is rough:

```ts
// SPIKE(2026-09-22): permission levels are just a string for now,
// want to see how the UI feels before committing to an enum
```

Commit freely as you go. Pre-commit takes about four seconds: secrets scan,
boundary check, stack check, ratchet, lint on staged files. Most of the time it
says nothing at all.

Occasionally it stops you:

```
BLOCKED: migration creates a table without enabling RLS
    supabase/migrations/0042_shares.sql
```

Thirty seconds to fix. That same mistake found three weeks later, after the
table went live, is a very different day.

---

## Midday: play

The long stretch, and the part the harness is built to stay out of.

You are trying share-by-email against share-by-link, moving the dialog around,
changing your mind about whether permissions belong to documents or folders. You
commit fifteen times. Nothing heavy runs. The `SPIKE` markers let genuinely
rough code exist without pretending otherwise.

Do not run `/repair`. Do not write tests. Do not think about the ratchet.

If the agent notices something unrelated worth fixing, it appends a line to
`docs/REPAIR-QUEUE.md` and keeps going rather than derailing you with a
refactor you did not ask for.

---

## Afternoon: the shape settles

You stop moving things. The dialog feels right. This is the pivot, and it is
where the rhythm changes.

### `/repair`

Reads the whole branch diff, summarizes what the change does in behavioural
terms, and checks it against `docs/INVARIANTS.md`. Say it returns four things.
Two are noise. Two are real: a list query with no limit, and a response that
spreads a database row straight into JSON, which will publish the next column
anyone adds to that table. Ten minutes to fix both.

### `/threat document sharing`

Run this when the feature touches access control, money, or personal data.

It finds what you cannot, because you already know what you meant. Here: the
share endpoint verifies you are signed in and verifies the document exists, but
a signed-in stranger can share a document they do not own. Authentication
checked, authorization skipped. That is the most common real breach in this
stack, and the pass hands you the exact request that exploits it.

Fix it in the RLS policy rather than the handler, so the hole closes even for a
request that never touches your application code.

### `/backfill document sharing`

Now that the shape has stopped moving, tests are worth writing.

It lists the behaviours in plain sentences first and asks you to correct the
list. That list is the specification you never wrote up front, recovered now
that the design is finished. Then: authorization tests, boundary tests, one
happy path, and a regression test for whatever `/threat` found. Last, it lists
the `SPIKE` markers now covered by tests so you can clear them.

---

## Push

```bash
git push
```

Pre-push takes about forty seconds: types, lint, unit tests.

The ratchet has been reporting quietly at each commit, never blocking:

```
worse    any-types  app/share/dialog.tsx  0 -> 2
Debt grew on this branch. Fine while exploring; it must be fixed or
accepted before this reaches main.
```

Two `any` types from when you were moving fast. During the play phase you
ignored this, correctly. Now the shape has settled, so you type them properly,
commit, and the baseline tightens and stages itself into that same commit.
Improvements and the record of them travel together. Had you decided the debt
was worth keeping, `npx harness ratchet --accept` and a sentence in the commit
message would have been the honest alternative.

If you genuinely need to push mid-exploration, `git push --no-verify` is a
legitimate move on a feature branch. CI still has you.

---

## Pull request

Four jobs in parallel:

| Job | What it adds beyond pre-push |
|---|---|
| fast | `ratchet --new`, which sees only lines this branch added, so a violation you moved between files is still caught |
| security | gitleaks over full history, semgrep, dependency advisories |
| build | bundle budget |
| database | the RLS audit against the branch database |

The database job is the one that matters most, because it is the only check that
inspects the actual perimeter rather than your intentions about it.

Vercel builds a preview. Click around in it like a user. This catches what no
static check ever will, such as the dialog being wrong on a phone.

---

## Merge

Opening the pull request against the default branch flips one switch: the
things that were free on the branch are now accounted for. **`SPIKE` markers
hard-fail, and the ratchet is enforced.** Anything still marked rough gets
finished or gets pulled out of the branch before it can merge.

This is the gate that stops exploratory code from quietly becoming production,
and it is the only place in the system where the harness is genuinely strict.

If this is the first time the feature becomes publicly reachable, or if it
meaningfully changed the public surface, run `/preflight`. That pass covers what
lives outside the repository entirely: Vercel preview protection, Supabase auth
settings, the Cloudflare origin lock, and whether a database restore has ever
actually been tested.

---

## Afterward

Two habits close the loop.

**Clear the queue.** Glance at `docs/REPAIR-QUEUE.md` between things and take a
couple of items.

**Push lessons upstream.** When a pass catches the same kind of mistake for the
third time across your projects, add the check to the harness repo rather than
fixing it in place. Bump the version. Every other project picks it up on its
next `npm update && npx harness sync`. Over a year the harness becomes a record
of what your codebases have taught you.

---

## Where the weight sits

| Moment | Cost | What runs |
|---|---|---|
| While typing | free | Cursor rules shaping the output |
| Every commit | ~4s | secrets, boundaries, stack, ratchet (report only), staged lint |
| Every push | ~40s | types, lint, unit tests |
| Pull request | minutes, elsewhere | full suite, semgrep, RLS audit, build, e2e |
| Session settles | your call | `/repair`, `/threat`, `/scale`, `/backfill` |
| Going public | an hour, rarely | `/preflight` |
| Nightly | asleep | deep sweep, drift, dead code, trends |

The exploration phase is deliberately unguarded except for the handful of things
that are expensive to undo. That is the trade the whole design is built around.

The escape hatches are real and meant to be used. `--no-verify` on a feature
branch is fine. `harness ratchet --accept` is fine when the debt is worth
taking, and the commit-msg hook only makes you say why. What the harness is
trying to prevent is not you making a mess. It is you making a mess you did not
notice.

---

## Quick reference

```bash
npx harness quick                # pre-commit set, seconds
npx harness check                # pre-push set, under a minute
npx harness full                 # everything, including security scans
npx harness ratchet              # debt against the baseline
npx harness ratchet --new        # only what this branch added
npx harness ratchet --goals      # distance to your targets
npx harness ratchet --accept     # take the debt, and say why in the commit
npx harness rls                  # audit the live database perimeter
npx harness doctor               # version, drift, what is yours vs managed
npx harness fleet ~/code         # which projects are on which version
```

| Ritual | When |
|---|---|
| `/repair` | a play session settles, before anything substantial gets committed |
| `/threat <feature>` | the feature touches access control, money, or personal data |
| `/scale <feature>` | before the thing gets real usage, or when something feels slow |
| `/backfill <feature>` | the shape has stopped moving and tests will hold rather than fight |
| `/preflight` | before anything becomes publicly reachable, and when the product changes shape |
