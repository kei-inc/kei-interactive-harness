# /doctor

Is this project's harness healthy? A checkup, reported as a short list of
problems with the fix for each. Change nothing until I say which to fix.

Use `pnpm exec harness` if the project has a `pnpm-lock.yaml`, otherwise
`npx harness`.

## Gather

```
npx harness doctor
git status -sb
git ls-remote --tags --refs https://github.com/kei-inc/kei-interactive-harness.git
gh api repos/{owner}/{repo} --jq '{merge: .allow_merge_commit, autodelete: .delete_branch_on_merge}'
gh secret list --json name --jq 'any(.[]; .name == "SUPABASE_DB_URL")'
```

Ask only whether that one secret exists; never list the repository's secrets.

The latest release is the highest `vX.Y.Z` in the tag list, compared
numerically. If `gh` is unavailable, skip the GitHub checks and say so.

## Check

Report only what is wrong. For each, one line on the problem and one on the fix.

1. **Version.** Installed harness older than the latest release: suggest
   `/sync`. Installed package older than the project's recorded version (doctor
   says so in red): the wrong tag got installed; reinstall from the lockfile.
2. **Managed files.** `missing`: a sync restores them. `edited`: someone
   changed a file the harness owns, and the next sync will overwrite it. Show the
   edit, and offer to move it where it survives: a `.cursor/rules/90-*.mdc` rule,
   a `.husky/*.local` hook, `.harness/config.sh`, or its own workflow file.
3. **Unmerged `.harness-new` files.** Git ignores them, so they are easy to
   forget. Offer to merge each into its original.
4. **Project docs still blank.** Compare `docs/CONTEXT.md` and
   `docs/INVARIANTS.md` with their templates in
   `node_modules/kei-interactive-harness/lib/templates/`. A section still
   holding the template's instruction text, an empty table row, or a `______`
   blank has not been filled in. List them. These are what make the harness know
   this system, so offer to draft them from the code, asking me what the code
   cannot answer.
5. **Checks with nothing to run.** `package.json` scripts doctor lists as
   absent (`typecheck`, `lint`, `test:unit`, `test:e2e`, `build`, `size`) are
   skipped silently by the hooks and CI. Note which, and whether the project has
   the tool under another script name.
6. **Branch workflow.** On the default branch: suggest `/play`. No `play`
   branch at all: suggest `/play`. Merge commits disabled on GitHub: `/land`
   will fail; turn on "Allow merge commits". Head branches auto-deleted:
   `/land` would delete `play`; turn that off.
7. **Database audit.** A Supabase project without a `SUPABASE_DB_URL`
   repository secret fails the CI database job. Say where to get the session
   pooler URI (Supabase, Project Settings, Database, Connection string).

## Report

The list, ordered by what would hurt most, or one line saying the project is
healthy. Then ask which to fix.
