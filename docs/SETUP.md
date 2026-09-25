# kei-interactive-harness: setup and operations

Personal reference for installing, maintaining, and updating the harness across
projects.

Command blocks contain only commands, so they can be pasted into zsh as-is.
Explanations live in the text around them.

Repo: `github.com/kei-inc/kei-interactive-harness` (public)

This guide lives in the harness repo and is versioned with it. Every install
command pins the current release; `npm version` rewrites those pins on each
release, so the tag you see here is always the latest one.

---

## How it fits together

The harness is a package that each project installs from GitHub. It is not on
the npm registry and nothing is registered on your machine globally. Each
project's `package.json` says where to fetch it from, and npm, Vercel, and
GitHub Actions all read that same line.

Files land in three tiers:

| Tier | Where | On sync |
|---|---|---|
| Package logic | `node_modules/kei-interactive-harness/` | updated by reinstalling, never copied |
| Managed | `.cursor/`, `.husky/`, `.github/workflows/` | regenerated; do not edit |
| Yours | `docs/`, `.harness/`, `.cursor/rules/90-*`, `.husky/*.local` | never touched |

**What is committed and what is not.** The package logic sits in
`node_modules/` and is never committed. Everything else the harness writes is
committed on purpose: Cursor needs the rules in every clone, CI cannot run
workflows that are not in the repo, and the ratchet only works with its baseline
in git history. `init` adds the few things that should never be committed
(env files, `*.harness-new`, nightly report files) to `.gitignore` for you.

Committing is not publishing to your users. A Next.js site on Vercel serves only
`public/` and what your routes render; `docs/`, `.cursor/` and `.harness/` are
unreachable from the deployed site.

**If a project repo is public**, keep the "known accepted risks" section of
`docs/INVARIANTS.md` general. In a private repo, naming the exact hole is useful.
In a public one it is a map for an attacker.

**Never install by bare name.** `npm i kei-interactive-harness` asks the public
registry, where anyone could publish a package under that name. Always use the
`github:` address with a tag.

---

## 1. Releasing a new version of the harness

From inside the harness repo, after making changes:

```bash
git add <changed files>
git commit -m "what changed"
npm version patch
git push --follow-tags
```

`npm version` bumps `package.json`, rewrites every
`kei-interactive-harness#vX.Y.Z` pin in the README and this guide to the new
tag, commits it all as `vX.Y.Z`, and creates the matching tag, in one step. It
needs a clean working tree, which is why the commit comes first.
`--follow-tags` sends the tag along with the commit; plain `git push` does not.

Always bump through `npm version`, never by editing `package.json` or tagging by
hand. `harness doctor` and `harness fleet` read the version from `package.json`,
and the doc pins only move when `npm version` runs. `npm run check:version`
fails if the docs have fallen behind.

Which bump to use:

| Change | Command |
|---|---|
| Fixes, wording, false positives | `npm version patch` |
| New checks, rules, rituals, metrics | `npm version minor` |
| Anything that would break existing projects on sync | `npm version major` |

---

## 2. Installing on a brand-new project

Install the harness right after the framework scaffold exists and before
writing any code of your own. `create-next-app` creates the project folder;
every command after it runs from inside that folder. The rules shape what the agent writes from the
first prompt, which is the cheapest moment to get RLS on a table or a key into a
`server-only` file.

```bash
npx create-next-app@latest my-app
cd my-app
npm i -D husky github:kei-inc/kei-interactive-harness#v1.5.0
npx harness init
npx harness ratchet
```

With pnpm, the install line is
`pnpm add -D husky github:kei-inc/kei-interactive-harness#v1.5.0`, and in a pnpm
workspace add `-w` so it installs at the root.

**Do not run `npx husky init`.** It writes its own `pre-commit` file and would
overwrite the harness hooks. `harness init` wires git to `.husky/` itself.

Then fill in the three project files, in this order. Partial is fine on day one;
`harness doctor` reminds you what is still blank.

1. `docs/CONTEXT.md`: what this is, why now, Figma and prototype links, the
   product's vocabulary, what is settled and what is still moving. The agent
   reads this at the start of every session.
2. `docs/INVARIANTS.md`: the tenancy column, what is public, what grows. `/repair`
   proposes additions as the shape settles.
3. `docs/PLATFORM.md`: fill in as the Supabase project and Vercel deployment come
   into existence.

First commit:

```bash
git add -A && git commit -m "add kei-interactive-harness" && git push
```

The hooks run for the first time on that commit. On an empty scaffold they
should pass in a couple of seconds with nothing to report.

Then create the `play` branch you will work on day to day (section 9).

---

## 3. Installing on an existing project

**Do not run `create-next-app`.** That command makes a new app. For an existing
project, the app already exists; you are only adding the harness to it.

Everything below runs from a terminal **inside the project's root folder**, the
one that contains its `package.json` and its `.git` folder. In Cursor, the
built-in terminal (View → Terminal) opens there by default.

### Step 1: get to a clean starting point

```bash
cd ~/code/my-existing-app
git status
git checkout -b add-harness
```

If `git status` shows uncommitted work, commit or stash it first. Keeping the
install on its own branch means the whole change arrives as one reviewable pull
request, and backing out is just deleting the branch.

If the project is a monorepo (several apps in one repo), run everything from the
**repo root**, not from inside one app's folder.

### Step 2: install the harness

```bash
npm i -D husky github:kei-inc/kei-interactive-harness#v1.5.0
```

If the project already has husky, npm simply leaves it in place.

If the project uses pnpm (there is a `pnpm-lock.yaml`), use
`pnpm add -D husky github:kei-inc/kei-interactive-harness#v1.5.0`. In a pnpm
workspace (there is a `pnpm-workspace.yaml`), add `-w` so it installs at the
root: `pnpm add -D -w ...`. The generated CI detects pnpm and uses it, including
the project's own pnpm version from the `packageManager` field in
`package.json`. Set that field if it is missing.

### Step 3: run init

```bash
npx harness init
```

Read the output rather than skimming it. Each line is one of four things:

| Output | Meaning | Action |
|---|---|---|
| `added` | New file created | None |
| `kept` | A project file already existed and was left alone | None |
| `yours` | You already had your own version of a managed file (usually `ci.yml` or `pre-commit`). Yours is untouched; the harness version was written beside it as `.harness-new`. | Merge, see step 4 |
| `wired` | Git now runs hooks from `.husky/` | None |

Do **not** run `npx husky init` at any point. It overwrites the harness hooks.

### Step 4: merge any `.harness-new` files

Find them:

```bash
find . -name "*.harness-new" -not -path "./node_modules/*"
```

For each one, open your original and the `.harness-new` side by side, then
follow section 4 below to decide what to keep. When done, replace your original
with the harness version and delete the `.harness-new` file:

```bash
mv .husky/pre-commit.harness-new .husky/pre-commit
mv .github/workflows/ci.yml.harness-new .github/workflows/ci.yml
```

Anything from your old files that the harness does not do moves into a `.local`
hook or its own workflow file before you overwrite. If there are no
`.harness-new` files, skip this step.

### Step 5: match your package.json scripts

The harness runs your existing tools through `package.json` script names. Check
which it found:

```bash
npx harness doctor
```

Look at the "package.json scripts the checks call" section. If your project
calls its typecheck `type-check` or its tests `test`, either rename them or add
an alias, so the harness can find them:

```json
"scripts": {
  "typecheck": "tsc --noEmit",
  "lint": "next lint",
  "test:unit": "vitest run"
}
```

Missing scripts are skipped rather than failing, so this is about coverage, not
correctness. You can add them later.

### Step 6: audit the database

Do this before anything else in the guide, because on an existing Supabase
project it is the check most likely to find something real:

```bash
SUPABASE_DB_URL="postgres://..." npx harness rls
```

Get the URL from the Supabase dashboard: Project Settings → Database →
Connection string → **Session pooler**. Not the direct connection, which is
IPv6-only and fails from most networks and from CI (section 5 has the detail).
Every query in the audit is a read of system tables, so pointing it at
production is safe. With `supabase start` running locally, plain
`npx harness rls` audits the local stack instead.

If it reports errors, write down what it found, but do not fix them in this
branch. The harness install should arrive as its own clean change; RLS fixes
belong in their own migration and their own pull request, right after.

### Step 7: record the baseline

```bash
npx harness ratchet
npx harness ratchet --goals
```

The first command records the current state of the codebase in
`.harness/ratchet.txt`. It will not be zeros on an existing project, and that is
expected: it is an honest picture, not a verdict. The second shows each metric
against its goal. Open `.harness/goals.txt` and lower a few targets to what you
actually intend to fix; leave the rest equal to today's count.

### Step 8: fill in the project files

Same three files as a new project, same order: `docs/CONTEXT.md`, then
`docs/INVARIANTS.md`, then `docs/PLATFORM.md`. On an existing project you
already know most of the answers, so this goes quicker. Put the RLS findings
from step 6 into `INVARIANTS.md` under known accepted risks for now, so they are
on record until the fix lands.

### Step 9: commit and open a pull request

```bash
git add -A
git commit -m "add kei-interactive-harness"
git push -u origin add-harness
```

The commit runs the new hooks for the first time. On an existing codebase they
may report debt; they will not block on it. They will block on the handful of
genuine gates (a committed secret, a migration without RLS, the service role key
near the browser). If one fires, it has found something real in the existing
code; fix it or note it before continuing.

Open the pull request on GitHub. The harness CI runs for the first time here,
and this is where the ratchet and spike checks are enforced. Since the baseline
was just recorded, the ratchet should pass. Merge when green.

### Step 10: confirm it took

After merging, on `main`:

```bash
git checkout main && git pull
npx harness doctor
```

Doctor should show the project synced at the version you installed, managed
files in step with the package, and your project files present. Then open the
project in Cursor and check the rules panel and `/repair`, as in section 6.
Finally, create the `play` branch (section 9).

---

## 3a. Projects without Supabase

The harness detects Supabase per project: a dependency on any `@supabase/*`
package, or a `supabase/` folder. It re-checks on every `harness sync`.

| | With Supabase | Without |
|---|---|---|
| Supabase Cursor rule (`15-supabase.mdc`) | written | not written |
| RLS audit (`harness rls`, CI database job) | runs | skips cleanly |
| Service role, `getSession`, migration checks | active | dormant (they only match Supabase code) |
| Everything else | active | active |

When you add Supabase to a project later:

```bash
npm i @supabase/supabase-js
npx harness sync
```

Then add the `SUPABASE_DB_URL` secret to the repo (section 5) and the database
job starts auditing. Removing Supabase and syncing takes the rule back out.

To override detection, set `HARNESS_SUPABASE=on` or `off` in
`.harness/config.sh`.

**If the project uses a different Postgres** (Neon, Vercel Postgres, RDS behind
Prisma or Drizzle), leave the RLS audit off. It assumes an anon key shipped to
browsers, which is what makes RLS the perimeter in Supabase. Without that, RLS
is usually and correctly off, and the audit would report every table. On those
stacks the perimeter is your server code, which the route and server action
checks already cover.

**If the project has no user accounts at all** (a marketing site, docs, a
portfolio), there is no identity to check, and the route handler check will
block every `route.ts`. Either mark each with `// @public-route` and a reason,
which is good hygiene for a contact form or webhook, or turn the checks off:

```sh
# .harness/config.sh
HARNESS_DISABLE="route-handlers server-actions"
```

**If the project uses a different auth library** (Clerk, NextAuth, Auth.js),
add its function name so the route and action checks recognize it:

```sh
HARNESS_AUTH_PATTERN='auth\(|currentUser|getServerSession'
```

---

## 3b. Supabase grants change, October 30, 2026

Supabase is changing how tables reach the Data API (the layer `supabase-js`
talks to). Source: github.com/orgs/supabase/discussions/45329

**What changes.** From October 30, 2026, on every existing project, new tables
in `public` get no grants automatically. A table is unreachable from
`supabase-js` until a migration grants it. New projects created since May 30
already behave this way. RLS is unchanged; grants are a separate layer that
decides whether a role can reach a table at all.

**What does not change.** Existing tables keep their current grants. Nothing
already running in production breaks on October 30.

**Where it will bite you.** Your existing migrations never contained grants,
because the platform added them. Any environment rebuilt from migrations
(`supabase db reset`, Supabase branching for previews, a fresh deploy) will
produce tables with no grants, and the app will fail there with
`42501 permission denied` while production works fine.

### What to do on each existing Supabase project, before October 30

On a branch, from the project root:

```bash
SUPABASE_DB_URL="postgres://..." npx harness rls
```

An `auto_expose_default` warning means the project is still on the old
auto-grant default, which is expected before the cutover. `policy_without_grant`
means a table already has policies but is missing a grant.

```bash
SUPABASE_DB_URL="postgres://..." npx harness grants \
  > supabase/migrations/$(date +%Y%m%d%H%M%S)_explicit_grants.sql
```

This reads the live database and writes the grants it has today as `GRANT`
statements. Applying it to production changes nothing, since grants are
idempotent. Its job is to make every rebuilt environment match production.

**3. Review the file before committing.** It reproduces access exactly,
including anything too broad. Under the old default, `anon` was granted
insert, update and delete on every table, with RLS doing all the protecting.
Now is the moment to narrow that:

- Delete lines for tables that should never be reachable from the browser.
- Reduce `anon` to what the logged-out experience genuinely needs, usually
  `select` on a handful of tables, often nothing.
- Look hard at any line marked `REVIEW`; those are tables where anon can write
  and RLS is off, which the audit also reports as an exposure.

```bash
supabase db reset
```

Then click through the app locally. Missing grants show up as `42501` errors,
which name the table and role.

```bash
git add supabase/migrations && git commit -m "explicit Data API grants ahead of Oct 30 cutover"
```

**6. Remove `auto_expose_new_tables`** from `supabase/config.toml` if it is
there. The flag is temporary, is removed on October 30, and already breaks
Supabase branching. The harness flags it.

Optionally, once the grants migration is merged and verified, opt in to the new
behavior early rather than waiting for October 30 by revoking the default
privileges (the SQL is in the Supabase discussion under "Opting in on existing
projects"). Doing it yourself, on your schedule, is calmer than having it happen
to you.

### What the harness does from now on

The agent is taught to write grants, RLS, and policies as one unit in every
migration that creates a table. `harness stack` notes any created table without
a grant (mark server-only tables `-- @no-data-api`), and flags bulk grants to
`anon` and restored default privileges. `harness rls` is now grant-aware: a
table with RLS off but no grants is correctly treated as unreachable rather
than exposed.

---

## 3c. Migrations: who applies them, who checks them

**Keep Supabase's GitHub integration on.** It builds a preview branch database
and runs your migrations on each pull request, and applies them to production
when you merge. That is the right place for applying, for the same reason
Vercel is the right place for deploying: the platform does it, at merge, with
its own safeguards. The harness never applies migrations to a real database.

**The harness checks the three things the integration only reveals as a failed
deploy:**

| Problem | On your branch (pre-push) | On the pull request (CI) |
|---|---|---|
| Local database behind your migration files | reported, or applied if you opt in | n/a |
| An already-merged migration was edited or deleted | note | blocked |
| A new migration is older than the newest merged one | note | blocked |
| Two migrations share a version | blocked | blocked |

The edited-migration case is the one worth understanding. Applied migrations
are never re-run, so if you edit one after it merged, production silently keeps
the old version while every fresh environment gets the new one. Always put a
change in a new migration instead.

**To have pre-push apply pending migrations to your local database**, which is
what your old setup did, set in `.harness/config.sh`:

```sh
HARNESS_MIGRATE_LOCAL=apply
```

Then when you pull a branch with new migrations and push, the harness runs
`supabase migration up` against the local stack first. This only ever touches
the local Docker database. If `SUPABASE_DB_URL` is set, the local comparison is
skipped entirely, so production can never be migrated from a hook.

If the check reports local migrations with no file on this branch, those are
usually leftovers from another branch you had checked out. `supabase db reset`
rebuilds the local database from this branch's files.

Run it by hand any time:

```bash
npx harness migrations
```

**If you apply migrations by hand** rather than through the GitHub integration,
the CI database job also compares your repo with the real database, read-only,
using the same `SUPABASE_DB_URL`. It reports migrations that merged but were
never applied, and migrations the database has recorded that no file in the
repo explains. It never applies or repairs anything. The commands it will point
you at:

```bash
supabase link --project-ref <ref>
supabase db push
supabase migration repair --status applied <version>
supabase migration repair --status reverted <version>
```

Changes made directly in the SQL editor never appear in migration history, so
no history comparison can see them. To catch those, compare the schema itself:
`supabase db diff --linked`. Run the same comparison yourself with
`SUPABASE_DB_URL=... npx harness migrations --remote origin/main`.

---

## 3d. Security scanning on an existing codebase

**Semgrep gates on what a change introduces, not on history.** On a pull
request, only findings new since the base branch fail, and only at ERROR or
WARNING severity; INFO never blocks. On pushes to `main`, only ERROR-severity
findings fail. The nightly job sweeps everything at every severity and uploads
it as a report. So an existing codebase is quiet on day one, and every pull
request is held to the standard from then on.

To silence a harness rule in one project, use its short id:

```sh
# .harness/config.sh
HARNESS_SEMGREP_EXCLUDE="missing-timeout-on-outbound-fetch"
```

The rules live at `.harness/semgrep.yml` (written by sync) so their ids are
short and stable: `harness.<rule>`.

**Secret scanning uses the gitleaks CLI**, which is free on organization
repositories (the gitleaks GitHub Action needs a paid license there). If it
finds an old secret in history, rotate the secret first, then record the
finding's fingerprint in `.gitleaksignore` so the history scan passes. Rotating
is the fix; the ignore file only records that you did it.

---

## 3e. Monorepos (pnpm workspaces, Turborepo)

- Install and run everything from the repo root, with `pnpm add -D -w`.
- Route handler checks cover every `app/` directory, so `apps/*/src/app/**` is
  included. Environment checks read every `.env.example` in the repo.
- CI runs the root `build`, `typecheck`, `lint` and `test:unit` scripts. In a
  Turborepo, point those at Turbo: `"build": "turbo run build"`, and so on.
- Anything app-specific the harness does not do (a per-app build flag, an extra
  check) goes in `.husky/*.local` or its own workflow file.

---

## 4. Merging with existing CI, hooks, and Vercel

**Vercel auto-deploy: keep it, untouched.** It lives in Vercel's Git
integration, not the repo. The harness never deploys; its CI only checks. After
a push, GitHub Actions runs checks and Vercel builds a preview, in parallel.

To make production wait for the checks, add branch protection on `main` in
GitHub requiring the `fast`, `security`, and `database` jobs to pass before
merge. Vercel deploys production from `main`, so nothing reaches production
without passing. Previews still build on every push. Turn on "allow
administrators to bypass" if you want to keep the option of pushing an urgent
fix straight to `main`.

Pull requests from `play` merge with a merge commit (section 9), so in the
repo's Settings → General → Pull Requests, make sure "Allow merge commits" is
on.

**Husky hooks: sort each line of your old hook into one of three buckets.**

| Your old hook does | Do this |
|---|---|
| `lint-staged`, `tsc`, `eslint`, `vitest` | Delete it. The harness calls these via `package.json` scripts. |
| Commitlint or a custom script | Move it to `.husky/pre-commit.local` or `.husky/commit-msg.local` |
| Something that catches a mistake you keep making | Add it as a ratchet metric in `.harness/config.sh`, or to the harness repo itself |

Make sure your `package.json` script names match what the harness calls:
`typecheck`, `lint`, `test:unit`, `test:e2e`, `build`, `size`. `harness doctor`
shows which it found.

Husky sets `core.hooksPath` to `.husky/`, so any raw hooks in `.git/hooks/` stop
running. Move those to `.local` files too.

**GitHub Actions CI: let the harness own `ci.yml`.** If your old workflow ran
lint, types, tests, and build, the harness `fast` and `build` jobs replace it.
Anything else it did goes into its own workflow file (for example
`deploy.yml`), which the harness never touches. The reason to keep them
separate: `ci.yml` is regenerated on every sync, so check improvements flow in
automatically.

---

## 5. Wiring the database audit into CI

In the project's GitHub repo, add a repository secret:

- Name: `SUPABASE_DB_URL`
- Value: the **session pooler** URI, from Project Settings → Database →
  Connection string → Session pooler. It looks like
  `postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres`

Do not use the direct connection (`db.<ref>.supabase.co`). It is IPv6-only, and
GitHub's runners are IPv4, so it cannot connect from CI. The audit recognizes
that host and says so if it fails.

Every query in the audit is a read of Postgres system catalogues, so pointing it
at production is safe.

**Without the secret, the database job fails** rather than passing while
auditing nothing. A green check that checked nothing is the worst outcome a
security check can have, so the harness makes you decide. If a Supabase project
genuinely should not be audited from CI, say so in `.harness/config.sh`:

```sh
HARNESS_REQUIRE_DB_AUDIT=0
```

The same principle applies throughout: the audit tests the connection first,
stops at the first failing query, and only reports a result if it demonstrably
finished. A rotated password or broken URL fails the job loudly.

**Deliberately public objects** go in `.harness/rls-allow.txt`, one per line,
exactly as the audit prints them, with a reason after `#`. Matching is exact: a
table entry covers that table's policies and nothing else, so `public.plans`
does not silence `public.plans_history`. For a temporary exception, put
`until(YYYY-MM-DD)` in the reason; after that date the finding comes back:

```
storage.mark-media   # until(2026-10-15) signed-URL reads deploying first
```

**If the audit reports a public bucket you want private**, that is an app change
first and a migration second. Readers need `createSignedUrl()` instead of
`getPublicUrl()`, and server code needs `storage.download()` instead of
`fetch(publicUrl)` (which is also a server-side request forgery risk). Deploy
the app change, confirm media still loads, then ship the migration that flips
the bucket private. In the other order, media breaks in production.

Locally, with the Supabase CLI running on Docker, no URL is needed:

```bash
supabase start
npx harness rls
```

The harness finds the database in this order: `SUPABASE_DB_URL` if set, then
the running local stack via `supabase status`, then the Supabase database
container directly through Docker. It prints which one it is auditing, so you
always know.

You do not need `psql` installed on the Mac. If it is missing, the harness uses
the `psql` already inside the Supabase container, or, for a production URL, a
throwaway `postgres:16-alpine` container (a small image pull the first time).

**Capture grants from production, not local.** `npx harness grants` will fall
back to the local stack if no URL is set, and says so, but for the cutover
migration in 3b you want production's grants:
`SUPABASE_DB_URL="<production URL>" npx harness grants`.

The audit refuses to report "clean" unless the query demonstrably completed, so
a stopped container or wrong database fails loudly rather than passing silently.

---

## 6. Checking Cursor picked it up

After the first `init`, open the project in Cursor and confirm:

- **Settings → Rules** lists the seven `.mdc` files (six without Supabase), and
  the scoped ones show their globs attached.
- Typing `/repair` in chat offers the command.

If the scoped rules are not attaching to files, the likely cause is the
`globs:` format in the rule frontmatter. Fix it in the harness repo, release a
patch, and sync.

---

## 7. Updating a project to a newer harness version

The easy way: on `play`, type `/sync` in Cursor chat. It looks up the latest
release itself, installs and syncs it, offers to merge template changes into
`AGENTS.md` and `docs/WORKFLOW.md`, and commits only the update.

By hand: `npm update` does not move a pin that points at a GitHub tag. Install
the new tag explicitly, which rewrites the line in `package.json`. Copy the tag
from this guide rather than from shell history; re-running an old install line
is the easy way to downgrade a project. `harness sync` refuses to go backwards
unless you pass `--allow-downgrade`.

```bash
npm i -D github:kei-inc/kei-interactive-harness#v1.5.0
npx harness sync
git add -A && git commit -m "update kei-interactive-harness" && git push
```

Do this on `play`, so the update reaches `main` through the next pull request
like any other change.

Sync regenerates managed files and reports only the ones that actually changed.
Your `docs/`, `.harness/`, `90-*` rules, and `.local` hooks are left alone. That
includes `AGENTS.md` and `docs/WORKFLOW.md`: when a release changes their
templates, sync does not carry the change over, so copy the new sections across
by hand if you want them.

To see which projects are behind:

```bash
npx harness fleet ~/code
```

---

## 8. Iterating on the harness itself

After changing the audit SQL, prove it still finds exactly what it should:

```bash
bash test/run-fixture.sh
```

While actively developing the harness, point one test project at your local
clone so edits are live with no release step:

```bash
npm i -D file:../kei-interactive-harness
```

When something works, release it (section 1).

**Switch back to the `github:` line before pushing that project.** The `file:`
path does not exist on Vercel or in GitHub Actions, so the build will fail.

The habit worth building: when `/repair` or `/threat` catches the same mistake
for the third time in any project, add the check to the harness repo rather than
fixing it in place.

---

## 9. Day to day

Work happens on one long-lived `play` branch, never directly on `main`. Create
it once per project:

```bash
git switch -c play
git push -u origin play
```

Commit and push freely on `play`. No idea needs its own pull request. Vercel
keeps a stable URL for the branch (`<project>-git-play-<team>.vercel.app`) that
always shows the latest push. When a batch has settled, open one pull request,
merge it with a merge commit, and bring `play` up to date:

```bash
gh pr create --base main --head play --fill
gh pr merge --merge
git switch play
git pull origin main
```

A merge commit means `play` never needs resetting, and the same `git pull origin
main` catches `play` up after an urgent fix pushed straight to `main`.

All of that also runs from Cursor chat, with no terminal: `/play` creates or
returns to `play`, `/status` shows where things stand, `/ship` opens the pull
request, and `/land` merges it and brings `play` back in step. `/sync` updates
the harness, `/doctor` checks its health, and `/debt` shows where the ratchet
debt lives and what is cheap to pay down. They need the GitHub CLI signed in
(`gh auth status`).
`docs/WORKFLOW.md` in each project walks through the full cycle, including what
counts as a spike.

The checks:

```bash
npx harness quick
npx harness check
npx harness full
npx harness ratchet
npx harness ratchet --new
npx harness ratchet --goals
npx harness ratchet --accept
npx harness rls
npx harness grants
npx harness migrations
npx harness doctor
```

| Ritual (in Cursor chat) | When |
|---|---|
| `/repair` | A play session settles, before anything substantial gets committed |
| `/threat <feature>` | The feature touches access control, money, or personal data |
| `/scale <feature>` | Before real usage, or when something feels slow |
| `/backfill <feature>` | The shape has stopped moving and tests will hold |
| `/preflight` | Before anything becomes publicly reachable |

The rule behind all of it: **free on the branch, accounted for at the trunk.**
Commits never block on debt or spikes. The pull request to `main` is where both
must be paid or acknowledged.

---

## 10. When something goes wrong

| Symptom | Cause and fix |
|---|---|
| `npm i` fails or installs something unexpected | Installed by bare name. Use the `github:` line. |
| Hooks do not run at all | Husky not wired. Run `npx husky` (not `husky init`). |
| Harness hooks replaced by `npm test` | `husky init` was run. Run `npx harness sync` to restore them. |
| A `.harness-new` file appeared | You had your own version of a managed file. Merge, then delete it. Git ignores these, so `harness doctor` lists any you forgot. |
| Vercel build fails after harness changes | A `file:` dependency was pushed. Switch to `github:`. |
| Commit rejected: "raises the ratchet baseline" | You ran `--accept`. Add a reason to the commit message. |
| Commit rejected on `main`: "SPIKE marker on the default branch" | You are working on `main`. Move the work to `play`. |
| PR fails on `SPIKE` | Finish the spike or remove it from the branch. |
| PR fails on ratchet | Fix the debt, or `npx harness ratchet --accept` and say why. |
| `gh pr merge --merge` refused | Merge commits are off for the repo. Turn on "Allow merge commits" (section 4). |
| Sync refuses: "would downgrade it" | An older tag got installed, usually an install line re-run from shell history. Install the tag it names, or use `/sync`. |
| Docs show an old harness tag | The release was bumped by hand. Run `node scripts/sync-version.js` in the harness repo and commit. |
| Doctor says "edited" on a managed file | Someone edited it. Move the change to a `90-*` rule, `.local` hook, or `config.sh`, then sync. |
| RLS audit reports a table you meant to be public | Add it to `.harness/rls-allow.txt` with a reason. |
| Route using a different auth library fails the stack check | Add its function name to `HARNESS_AUTH_PATTERN` in `.harness/config.sh`. |
| Every route blocked on a site with no logins | Mark them `// @public-route`, or `HARNESS_DISABLE="route-handlers server-actions"`. See 3a. |
| Added Supabase but no Supabase rule in Cursor | Run `npx harness sync`. Detection happens at sync time. |
| App works in production, fails locally or on a branch with `42501` | Migrations lack grants. See 3b: `npx harness grants`. |
| "table X has no grant" note on a migration | Add a narrow grant, or mark it `-- @no-data-api` if server-only. |
| Audit says "no database to audit" | Start Docker Desktop and `supabase start`, or set `SUPABASE_DB_URL`. |
| Audit says "did not complete" | The database answered with nothing: container stopped, or wrong URL. Check `supabase status`. |
| PR blocked: "edits a migration that is already merged" | Revert the edit; put the change in a new migration (`supabase migration new`). |
| PR blocked: migration "older than the newest merged one" | Another branch merged first. Create a fresh migration and move the SQL into it. |
| "local database is N migration(s) behind" | `supabase migration up`, or set `HARNESS_MIGRATE_LOCAL=apply`. |
| "local database has migrations with no file" | Leftovers from another branch. `supabase db reset`. |
| Database job fails: "SUPABASE_DB_URL is not set" | Add the secret (session pooler URI), or `HARNESS_REQUIRE_DB_AUDIT=0` to opt out on purpose. |
| Database job: "Cannot connect", mentions the DIRECT host | Use the session pooler URI; the direct host is IPv6-only and runners are IPv4. |
| Database job suddenly fails to connect | Usually a rotated database password. Update the secret. |
| gitleaks fails on an old secret in history | Rotate it, then add its fingerprint to `.gitleaksignore`. |
| Semgrep blocks a PR on something you consider noise | `HARNESS_SEMGREP_EXCLUDE="<short-id>"` in `.harness/config.sh`. |
| "semgrep could not run" locally, inside an agent's shell | Usually a non-writable `HOME`. Run from a normal terminal, or point `HOME` somewhere writable, and restore it before `git push` or `gh`, which need your real credentials. |
| A `.local` hook aborts the commit unexpectedly | Husky runs hooks with `sh -e`; its last command decides. End the file with `true`. |
| A temporary `rls-allow.txt` entry stopped working | Its `until()` date passed. Fix the finding, or extend the date with a reason. |
| RLS audit says "not a Supabase project" | Expected on non-Supabase projects. Force with `HARNESS_SUPABASE=on` if detection missed it. |
