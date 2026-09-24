# /sync

Update this project to the latest harness release, from chat. Find the newest
tag yourself; never take a tag from memory, from shell history, or from an old
document, because installing an old tag is how a project gets downgraded.

Use pnpm if the project has a `pnpm-lock.yaml` (add `-w` if it also has a
`pnpm-workspace.yaml`), otherwise npm.

## Stage 1. Where things stand

```
git status -sb
npx harness version
cat .harness/manifest.json
git ls-remote --tags --refs https://github.com/kei-inc/kei-interactive-harness.git
```

The latest release is the highest `vX.Y.Z` in that list, compared numerically
(v1.10.0 is newer than v1.9.0).

If I am on the default branch, stop and suggest `/play`; the update travels to
main through the next pull request like any other change. If the project is
already on the latest release, say so, run `npx harness doctor`, and stop.

## Stage 2. Install and sync

```
pnpm add -D [-w] github:kei-inc/kei-interactive-harness#<latest>
npx harness sync
```

(or `npm i -D github:kei-inc/kei-interactive-harness#<latest>` for npm)

If sync refuses because it would downgrade the project, stop and show me the
message. Never pass `--allow-downgrade` unless I asked to roll back.

Report which managed files sync updated or added. If sync lists new project
templates, offer `npx harness adopt <file>` for each.

## Stage 3. Project files sync never touches

`AGENTS.md` and `docs/WORKFLOW.md` start as harness templates and then belong
to the project, so improvements to those templates do not arrive on their own.
For each, compare the template at the old version with the new one:

```
curl -sf https://raw.githubusercontent.com/kei-inc/kei-interactive-harness/<old>/lib/templates/AGENTS.md
cat node_modules/kei-interactive-harness/lib/templates/AGENTS.md
```

(`WORKFLOW.md` the same way; it lives at `docs/WORKFLOW.md` in the project.)

- Template unchanged between versions: nothing to do.
- Template changed, and the project file is still identical to the old
  template: offer to replace it with the new one.
- Template changed, and the project file has been customized: show me what the
  template changed in a few lines, then offer to merge just those changes in,
  written in the style of the project's file. Never overwrite project-specific
  content.

## Stage 4. Verify

```
npx harness doctor
```

Managed files should all be in step, and the project synced at the new version.

## Stage 5. Commit

Commit only what this update touched: `package.json`, the lockfile,
`.harness/manifest.json`, the managed files sync wrote (`.cursor/`, `.husky/`,
`.github/workflows/`, `.harness/semgrep.yml`), and any project files merged in
stage 3. Leave unrelated uncommitted work out and mention it. Message:
`update kei-interactive-harness to <latest>`. Push.

## Report

Old version to new, what changed in a few lines (from the managed files sync
updated and any template merges), and that the update reaches main with the
next `/ship`.
