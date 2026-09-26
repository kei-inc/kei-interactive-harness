# /repair

The repair pass. Run this when a play session settles, before I commit anything
substantial. This is the ritual that lets me build loosely without accumulating
quiet damage.

## How this runs

Stages 1 to 3 read the change cold, in the `harness-reviewer` subagent. You
built this with me, so you read the diff through what we meant; the reviewer
can only read what it does. Stages 4 to 6 are bookkeeping and stay here.

1. **Delegate.** Start the `harness-reviewer` subagent with a brief of two
   lines and nothing else:

   ```
   pass: repair
   base: <the default branch, HARNESS_DEFAULT_BRANCH or main>
   ```

   Do not summarise the session or explain what the change is for.

2. **Compare the summary with what we meant.** The reviewer's Stage 1 summary
   says what the change does. Put it beside what we set out to build in this
   session. Anything it does that we did not intend, or anything we meant that
   it does not describe, is the first finding in the report.

3. **Check its findings.** For each one, open the cited line. Keep it if you
   can see it, drop it only if you can quote the line that shows it is wrong,
   and keep it marked unsure otherwise.

4. **Then run Stages 4 to 6 here**, and report everything together. Report as
   you go rather than saving everything for the end.

If subagents are not available here, run Stages 1 to 3 yourself against
`git diff $(git merge-base main HEAD)` plus any untracked files, and say at the
top of the report that the review was not independent.

## For the reviewer

Stages 1 to 3 only.

## Stage 1. See what actually changed

Summarize in three or four sentences what this change actually does, in terms of
behaviour rather than files. If the diff does more than one thing, name each
thing separately. If you cannot tell what it does, say so, because that itself is
a finding.

## Stage 2. Check against the invariants

Open `docs/INVARIANTS.md`. For every file in the diff that touches data, auth, or
an external boundary, check it against the relevant invariant. Report as a table:

| File | Invariant | Holds? | Note |

Be specific. "Looks fine" is not a finding. Either the query filters by the
tenancy key or it does not.

Then the reverse: is the code now consistently following a rule that
`docs/INVARIANTS.md` does not yet state? A tenancy column every table carries,
an access pattern every handler repeats, a table that has clearly become the one
that grows. Propose the sentence to add. Invariants are discovered by building
and written down when they settle, in the same rhythm as everything else here.

## Stage 3. The five recurring mistakes

Check the diff for these specifically, because they are the ones that keep
happening and the ones generic linters miss.

1. **Ownership checked after the fetch** rather than inside the query.
2. **An identifier taken from the request** and used as though it proves identity.
3. **A response that spreads a database row** instead of picking fields.
4. **An unbounded list query** with no limit.
5. **A new input path with no schema validation** at the boundary.

## Stage 4. The spike inventory

Back in the main conversation from here.

```
npx harness spikes
```

For each marker: is this still exploratory, or has it settled and just not been
cleaned up? Dated markers older than a month are the first suspects. List the
ones that have settled, because those are the ones that will bite. Do not clean
them up yet; I will decide.

## Stage 5. Ratchet

```
npx harness ratchet
```

If anything got worse, the report names the file. Show me the specific lines.
If it tightened, that is already staged for the next commit.

## Stage 6. What I would do next

Three items, ordered by what would hurt most if left alone. For each, one line on
the fix and an honest size estimate. Append anything I defer to
`docs/REPAIR-QUEUE.md`.

Do not start fixing. This pass is for seeing.
