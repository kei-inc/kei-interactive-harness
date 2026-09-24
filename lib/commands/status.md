# /status

Where am I? A read-only look at the working state, so I never have to open a
terminal to find out. Change nothing: no commits, no pushes, no fixes.

Use `pnpm exec harness` if the project has a `pnpm-lock.yaml`, otherwise
`npx harness`. The default branch is `HARNESS_DEFAULT_BRANCH` from
`.harness/config.sh`, or `main`.

## Gather

```
git status -sb
git fetch -q origin
git rev-list --left-right --count origin/main...HEAD
git log --oneline origin/main..HEAD
grep -rnE "SPIKE[:(]" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" --include="*.mjs" --include="*.py" --exclude-dir=node_modules --exclude-dir=.next .
npx harness ratchet --check
gh pr list --head play --state open --json number,url,title
```

If `gh` is not installed or not signed in, skip the pull request line and say so.

## Report

Keep it short. A few lines, in this order:

1. **Branch.** Which branch I am on. If it is the default branch, say plainly
   that work belongs on `play` and suggest `/play`.
2. **Uncommitted work.** How many files, in one line. Do not list them unless
   there are fewer than six.
3. **Against main.** Commits on this branch not yet in main, and commits in main
   not yet here. If main is ahead (an urgent fix went straight to it), say that
   `/ship` will bring it in.
4. **Open pull request.** Its link, if one exists.
5. **Spikes.** Each marker with its file and age in days. Flag any older than
   thirty days. These block the pull request into main.
6. **Ratchet.** Only what got worse, by file. These also block the pull request.
   If nothing got worse, one line saying so.

End with one line on what makes sense next: keep playing, `/ship` if the batch
looks settled, or `/land` if a pull request is open and green.
