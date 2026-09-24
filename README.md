# kei-interactive-harness

One repository. Every project depends on it. Change it here, run
`npx harness sync` there, and every project moves together.

This is the harness described in `lib/templates/AGENTS.md`: ratchets rather than
gates, named repair rituals rather than constant interruption, and per-project
invariants that make generic checks specific. Tuned for Next.js on Vercel with
Supabase and Cloudflare.

`docs/SETUP.md` is the operations guide: releasing the harness, installing it on
new and existing projects, wiring CI and the database audit, updating, and
troubleshooting. It is versioned with the code, so the guide at any tag matches
that release.

`lib/templates/WORKFLOW.md` walks the whole cycle end to end, from scaffold to
production, and lands in each project as `docs/WORKFLOW.md`. Read that first if
you want the usage flow rather than the architecture.

## The three tiers

The design problem is that Cursor, husky, and GitHub Actions each read from one
fixed path and will not look anywhere else, so some files genuinely must exist
inside every project. The logic does not. Splitting on that line is what makes a
single source of truth possible.

| Tier | Where | Who owns it | On sync |
|---|---|---|---|
| **Package** | `node_modules/kei-interactive-harness/lib/` | this repo | updated by npm, never copied |
| **Managed** | `.cursor/`, `.husky/`, `.github/workflows/` | this repo | regenerated, carries a do-not-edit header |
| **Yours** | `docs/`, `.harness/`, `.cursor/rules/90-*` | the project | never touched |

All the check logic, the SQL, and the semgrep rules stay in the package and run
from there. Only the files that have nowhere else to live get written into the
project, and those are regenerated rather than merged, which removes the whole
question of drift.

## Using it

This package is not on the npm registry, and should never be installed by bare
name. `npm i kei-interactive-harness` would look it up on the public registry,
where anyone could publish something under that name. Always install from the
GitHub address, pinned to a tag.

```bash
# once per project, in this order
npm i -D husky github:kei-inc/kei-interactive-harness#v1.3.1
npx harness init          # also wires git to .husky/; do NOT run `husky init`
npx harness ratchet       # baseline
git add -A && git commit -m "add kei-interactive-harness"

# whenever the harness improves
npm i -D github:kei-inc/kei-interactive-harness#v1.3.1 && npx harness sync   # the new tag

# across everything
npx harness fleet ~/code     # which projects are on which version
npx harness doctor           # drift, and what is mine versus managed
```

## Changing the harness

Edit this repo, commit, then release with one command:

```bash
npm version <major|minor|patch>   # bumps package.json, rewrites the doc pins, commits "vX.Y.Z", tags it
git push --follow-tags
```

Never bump `package.json` or tag by hand. `npm version` runs
`scripts/sync-version.js`, which rewrites every `kei-interactive-harness#vX.Y.Z`
in the docs to the new tag inside the same commit, so the instructions cannot
fall behind the release. `npm run check:version` fails if they ever have.

Then in any project, install the new tag and `npx harness sync`. That is the
whole loop, and it is the point of the structure.

The rhythm worth aiming for: when a `/repair` or `/threat` pass catches the same
thing for the third time in any project, add the check here rather than there.
Every other project picks it up on its next sync. Over a year the harness
accumulates what your codebases have taught you.

Publishing options, in rough order of friction:

- **Private npm registry** if you have one. `npm publish`, `npm update`.
- **GitHub directly**, no registry: `npm i -D github:kei-inc/kei-interactive-harness#v1.3.1`. Pin by
  tag, bump the tag in each project's `package.json` when you want to move.
- **A file dependency** while you are still iterating fast:
  `npm i -D file:../harness`. Changes are live with no publish step at all, which
  is the right setting for the first few weeks.

## Diverging in one project

Three levels, in order of how much you should reach for them.

**Configure.** `.harness/config.sh` is project-owned and every check script
sources it. Disable checks, change the spike expiry, or add ratchet metrics
specific to this codebase:

```sh
HARNESS_DISABLE="getsession"
HARNESS_SPIKE_MAX_DAYS=14
HARNESS_EXTRA_METRICS='legacy-api|from-old-api
inline-styles|style=\{\{'
```

**Add.** Anything in `.cursor/rules/90-*.mdc` is yours, never overwritten, and
loaded by Cursor alongside the managed rules. Same for extra commands. Each
managed git hook sources a `.local` sibling if one exists (`.husky/pre-commit.local`,
`.husky/commit-msg.local`), so commitlint or a custom script lives there and
survives every sync. Extra CI goes in its own workflow file. This covers most
of what feels like needing a fork.

**Eject.** `npx harness eject` copies the logic into `./harness/`, strips the
do-not-edit headers, and writes `.harness/EJECTED`. One-way door: that project
stops receiving updates. Worth it when a project's needs have genuinely diverged,
and worth resisting before then, because two harnesses is more than twice the
work of one.

## Layout

```
bin/harness.js         the CLI
lib/rules/*.mdc        Cursor rules, materialised into projects
lib/commands/*.md      the rituals (repair, threat, scale, backfill, preflight) and
                       the branch loop (status, play, ship, land)
lib/scripts/*.sh       all check logic, runs from node_modules
lib/sql/*.sql          the row level security audit
lib/semgrep.yml        curated ruleset
lib/generated/         husky hooks and CI workflows, thin shims over the CLI
lib/templates/         written once at init, then owned by the project
  WORKFLOW.md          the development cycle, start to finish
docs/SETUP.md          install, release, update, troubleshoot (not shipped to projects)
scripts/               release tooling for this repo (not shipped to projects)
```

## Testing changes to the audit

`test/rls-fixture.sql` builds a Supabase-shaped database with known good and
known bad patterns, modelled on an existing project still on the old auto-grant
default, with a few tables created the new explicit-grant way. After any change to `lib/sql/rls-audit.sql`, run
`bash test/run-fixture.sh`: it starts a throwaway Postgres in Docker, loads the
fixture, runs the audit, and checks the counts against what the fixture
expects. It needs only Docker Desktop running and leaves nothing behind. The semgrep rules
can be validated with `semgrep --validate --config lib/semgrep.yml`.

## Commands

| | |
|---|---|
| `harness init` | install into a project |
| `harness sync` | regenerate managed files |
| `harness adopt <file>` | take a template added since you installed |
| `harness doctor` | version, drift, ownership |
| `harness fleet [dir]` | version across all your projects |
| `harness eject` | copy everything in, stop receiving updates |
| `harness quick / check / full` | the three check tiers |
| `harness ratchet [--new\|--goals\|--accept]` | debt against the baseline |
| `harness boundaries / stack / rls` | individual checks |
