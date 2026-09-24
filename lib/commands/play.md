# /play

Get me onto the `play` branch, where day-to-day work happens, and make sure it
is current with main. Run this once per project to create `play`, or any time I
have ended up somewhere else.

The default branch is `HARNESS_DEFAULT_BRANCH` from `.harness/config.sh`, or
`main`.

## Stage 1. Where am I

```
git status -sb
git fetch -q origin
git branch --list play
git ls-remote --heads origin play
```

If I am already on `play`, skip to stage 3.

## Stage 2. Get onto play

**`play` does not exist anywhere.** Create it from the up-to-date default branch
and publish it:

```
git switch main
git pull --ff-only
git switch -c play
git push -u origin play
```

**`play` exists on the remote but not locally.** `git switch play` creates the
local branch tracking it.

**Uncommitted changes.** `git switch` carries them across when it can. If it
refuses because they conflict with `play`, use `git stash`, switch, then
`git stash pop`. If the pop conflicts, stop and show me the conflicting files.
Never discard changes to make a switch work.

**Commits on local main that were never pushed.** These belong on `play`. Show
me the list (`git log --oneline origin/main..main`) and ask before moving them.
If I agree: on `play`, `git merge main`, then reset local main with
`git branch -f main origin/main`. Never force-push main.

## Stage 3. Bring play up to date

If main has commits `play` does not (`git log --oneline play..origin/main`),
merge them in:

```
git merge origin/main
```

If it conflicts, stop and show me the files. Do not resolve conflicts in code I
wrote without asking.

If `play` has no upstream yet, `git push -u origin play`.

## Report

One or two lines: I am on `play`, what came along with me (uncommitted files,
merged commits), and whether it is in step with main.
