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

The design problem is that Cursor, Claude Code, husky, and GitHub Actions each
read from one fixed path and will not look anywhere else, so some files genuinely must exist
inside every project. The logic does not. Splitting on that line is what makes a
single source of truth possible.

| Tier | Where | Who owns it | On sync |
|---|---|---|---|
| **Package** | `node_modules/kei-interactive-harness/lib/` | this repo | updated by npm, never copied |
| **Managed** | `.cursor/rules`, `.cursor/commands`, `.claude/rules`, `.claude/commands`, `.husky/`, `.github/workflows/` | this repo | regenerated, carries a do-not-edit header |
| **Shared** | `.cursor/hooks.json`, `.claude/settings.json` | both | the harness owns one entry, the end-of-turn hook; the rest is the project's |
| **Yours** | `docs/`, `.harness/`, `.cursor/rules/90-*`, `.claude/rules/90-*` | the project | never touched |

All the check logic, the SQL, and the semgrep rules stay in the package and run
from there. Only the files that have nowhere else to live get written into the
project, and those are regenerated rather than merged, which removes the whole
question of drift. The two agent settings files are the exception: they hold
the project's own permissions and hooks too, so sync adds, updates or removes
exactly its own entry, recognised by its command, and leaves the rest alone.

## Two agents, one contract

`AGENTS.md` is the contract, and both Cursor and Claude Code read it. The rules
and rituals are written once in `lib/` and materialised for each agent in its
own format: `.mdc` rules with `globs` for Cursor, `.md` rules with `paths` for
Claude Code, and the same slash commands in both (in Claude Code they only run
when invoked, never on the model's own initiative). `HARNESS_AGENTS="cursor"`
in `.harness/config.sh` narrows it to one, and sync removes what it wrote for
the other.

`/repair` and `/threat` hand their reading to `harness-reviewer`, a read-only
subagent in `.claude/agents/` (Cursor reads that folder too). It gets the pass
name and the base branch, never the conversation, because the agent that helped
write the code shares your blind spot: it knows what the code was meant to do.
The main agent then checks each finding against the code, and can only drop one
by quoting the line that refutes it.

Do not add a `CLAUDE.md` that restates the contract. Claude Code reads
`AGENTS.md` only when there is no `CLAUDE.md`; if a project needs one, give it a
line that says just `@AGENTS.md`. `harness doctor` flags one that does not.

## The end-of-turn check

When the agent finishes a turn, a hook runs `harness turn`: the boundary and
stack checks, in under a second, reporting only what would block a commit in a
file changed since the last commit. If it finds something, it hands it back to
the agent (Claude Code: the stop is blocked with the findings; Cursor: a
follow-up message), and the agent fixes it in the same turn, before you look.

It is built for small interactive turns rather than long autonomous loops. No
ratchet, types or tests, which stay at commit, push and the pull request. Old
findings in untouched files never interrupt. One follow-up per turn at most:
if the fix trips a check again, the commit hook still has it.
`HARNESS_DISABLE="turn"` switches it off.

## Using it

This package is not on the npm registry, and should never be installed by bare
name. `npm i kei-interactive-harness` would look it up on the public registry,
where anyone could publish something under that name. Always install from the
GitHub address, pinned to a tag.

```bash
# once per project, in this order
npm i -D husky github:kei-inc/kei-interactive-harness#v1.10.0
npx harness init          # also wires git to .husky/; do NOT run `husky init`
npx harness ratchet       # baseline
git add -A && git commit -m "add kei-interactive-harness"

# whenever the harness improves
npm i -D github:kei-inc/kei-interactive-harness#v1.10.0 && npx harness sync   # the new tag

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
- **GitHub directly**, no registry: `npm i -D github:kei-inc/kei-interactive-harness#v1.10.0`. Pin by
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

**Add.** Anything in `.cursor/rules/90-*.mdc` or `.claude/rules/90-*.md` is
yours, never overwritten, and loaded alongside the managed rules. Same for extra commands. Each
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
lib/rules/*.mdc        agent rules, materialised for Cursor (.mdc) and Claude Code (.md)
lib/agents/*.md        subagents: the fresh-context reviewer for /repair and /threat
lib/commands/*.md      the rituals (repair, threat, scale, backfill, preflight) and
                       the branch loop (status, play, ship, land) and upkeep
                       (sync, doctor, debt) and coverage (authtest, offline,
                       perf, monitor)
lib/scripts/*.sh       all check logic, runs from node_modules
lib/sql/*.sql          the row level security audit
lib/semgrep.yml        curated ruleset
lib/generated/         husky hooks and CI workflows, thin shims over the CLI
lib/templates/         written once at init, then owned by the project
  WORKFLOW.md          the development cycle, start to finish
docs/SETUP.md          install, release, update, troubleshoot (not shipped to projects)
scripts/               release tooling for this repo (not shipped to projects)
evals/                 bait-prompt cases, a fixture app and the runner (not shipped)
```

## Testing changes to the audit

`test/rls-fixture.sql` builds a Supabase-shaped database with known good and
known bad patterns, modelled on an existing project still on the old auto-grant
default, with a few tables created the new explicit-grant way. After any change to `lib/sql/rls-audit.sql`, run
`bash test/run-fixture.sh`: it starts a throwaway Postgres in Docker, loads the
fixture, runs the audit, and checks the counts against what the fixture
expects. It needs only Docker Desktop running and leaves nothing behind. The semgrep rules
can be validated with `semgrep --validate --config lib/semgrep.yml`.

After any change to a source-level check (`check-boundaries.sh`, `spikes.sh`),
run `npm test`. It builds a throwaway repo per case and checks that each
pattern blocks what it should and stays quiet on what it should not, including
comments. Add a case whenever a check gains a pattern or loses a false
positive; the cases are the specification of what each check means.

`npm run test:shot` does the same for `harness shot` against a local page. It
needs Playwright with Chromium and skips cleanly without it.

The `test/` folder is not shipped to projects.

## Evals: does a rule change what the agent writes?

`evals/` measures the harness itself. Each case in `evals/cases/` is a bait
prompt: an ordinary request where the obvious answer breaks something the
harness teaches (an API route with no identity check, a table with no RLS, an
admin client near the browser, a stub with no `SPIKE` marker, a one-line change
that tidies the file next door). The runner copies `evals/fixture/` into a
fresh repo, installs this checkout of the harness into it, or deliberately does
not, runs the agent headless, and scores what it wrote with file checks and the
harness's own verdict. No model grades a model.

```bash
npm run eval                                   # every case, with and without, Claude Code
npm run eval -- --agent cursor                 # through Cursor's CLI
npm run eval -- --case new-table-rls --runs 3  # one case, three times
npm run eval -- --mode with                    # skip the baseline
```

The number that matters is the gap between the two columns. A case that passes
without the harness is not testing the harness; a rule edit that leaves the gap
unchanged added tokens and nothing else. Agents vary run to run, so use
`--runs 3` or more before believing a difference. Every case and mode is a real
agent session, so this spends model usage; results land in `evals/results/`
(gitignored).

When `/repair` or `/threat` catches the same mistake for the third time, the
case goes here at the same time the check goes into `lib/`. `npm test` checks
the scorer itself against a fake agent, without spending anything.

## Commands

Day to day, use the slash commands in Cursor or Claude Code. They call the CLI below and
handle the judgement around it. The hooks and CI run the checks on their own.

| Slash command | |
|---|---|
| `/status` | where things stand: branch, spikes, debt, open pull request |
| `/play` | get onto `play` and bring it up to date |
| `/ship` | open or update the pull request into main |
| `/land` | merge it with a merge commit, carry on |
| `/sync` | update to the latest harness release |
| `/doctor` | harness health, with offers to fix |
| `/debt` | the ratchet's long view: goals, worst files, cheap wins |
| `/authtest` | tests proving every endpoint turns away the wrong caller |
| `/offline` | tests proving offline work arrives exactly once |
| `/perf` | Speed Insights, a bundle budget, slow queries |
| `/monitor` | Sentry error monitoring, verified on a preview |
| `/match` | build to a Figma frame or screenshot, measured, not eyeballed |
| `/repair` `/threat` `/scale` `/backfill` `/preflight` | the rituals |

The CLI, for terminals, hooks and CI:

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
| `harness spikes [--strict]` | every spike marker, oldest first |
| `harness turn` | what the end-of-turn hook runs, on changed files |
| `harness shot <url>` | render at a frame's width; compare with a reference; measure computed styles |
