# /ship

A batch of work on `play` has settled. Push it and open (or update) the one pull
request into main. This is the moment the harness gets strict, so surface what
will block before CI does, rather than after.

Use `pnpm exec harness` if the project has a `pnpm-lock.yaml`, otherwise
`npx harness`. The default branch is `HARNESS_DEFAULT_BRANCH` from
`.harness/config.sh`, or `main`.

## Stage 1. Right branch

```
git status -sb
```

If I am not on `play`, stop and suggest `/play`. Pull requests into main come
from `play` only.

## Stage 2. Commit what is outstanding

If there are uncommitted changes, show them in one line each, write a commit
message that says what changed in behavioural terms, and commit. The hooks run.
If a hook blocks, show me what it found and stop; that is a real finding.

## Stage 3. Take in anything that went straight to main

```
git fetch -q origin
git log --oneline HEAD..origin/main
```

If main has commits `play` does not, `git merge origin/main`. If it conflicts,
stop and show me the files.

## Stage 4. What will block the pull request

Check the two things CI enforces on the way into main:

```
grep -rnE "SPIKE[:(]" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" --include="*.mjs" --include="*.py" --exclude-dir=node_modules --exclude-dir=.next .
npx harness ratchet --check
```

If either reports anything, list it (spikes by file with a one-line note on
what each is waiting for, ratchet slips by file and metric) and ask me what to
do: fix them now, accept the ratchet debt with a reason, or open the pull request
anyway knowing CI will fail. Do not fix or accept anything without my say.

## Stage 5. Push and open the pull request

```
git push
gh pr list --head play --state open --json number,url
```

If a pull request from `play` is already open, the push has updated it. Report
its link.

Otherwise open one. Title: a short phrase for what the batch does. Body: a
summary of the batch in a few sentences, then the commit list from
`git log --oneline origin/main..HEAD`.

```
gh pr create --base main --head play --title "<title>" --body "<body>"
```

## Report

The pull request link, a one-line summary of what it carries, and the current
state of its checks (`gh pr checks`). Do not wait for CI to finish. Say that
`/land` merges it once the checks are green.
