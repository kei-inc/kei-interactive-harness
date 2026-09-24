# /land

The pull request from `play` is green. Merge it to main, which ships to
production, and bring `play` back in step so I can keep working.

This deploys. Do not merge anything that is not green, and do not work around a
failing check.

## Stage 1. Find it and check it

```
gh pr list --head play --state open --json number,url,title
gh pr checks <number>
```

No open pull request from `play`: say so and suggest `/ship`.

Any check failing: stop. Show which job failed and the relevant lines of its log
(`gh run view --log-failed`). Offer to fix it on `play`.

Any check still running: say which, and ask whether to wait
(`gh pr checks <number> --watch`) or come back later.

## Stage 2. Merge with a merge commit

```
gh pr merge <number> --merge
```

Always `--merge`: never squash, never rebase, never `--delete-branch`. A merge
commit is what lets `play` carry on without a reset.

If the merge is refused because merge commits are disabled, tell me to turn on
"Allow merge commits" in the repository's Settings, General, Pull Requests.

## Stage 3. Keep play alive

If the repository automatically deletes head branches after merge, `play` will
be gone from the remote. Check, and restore it if so:

```
git ls-remote --heads origin play
git push -u origin play
```

When that happens, tell me to turn off "Automatically delete head branches" in
Settings, General.

## Stage 4. Bring play up to date

```
git switch play
git pull origin main
git push
```

## Report

Two lines: what merged (the pull request link), and that `play` is in step with
main and ready for the next batch. Mention that Vercel is now deploying
production from main.
