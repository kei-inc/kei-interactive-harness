# /repair

The repair pass. Run this when a play session settles, before I commit anything
substantial. This is the ritual that lets me build loosely without accumulating
quiet damage.

Work through the stages in order. Report as you go rather than saving everything
for the end.

## Stage 1. See what actually changed

```
git diff --stat main...HEAD
git diff main...HEAD
```

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

```
grep -rnE "SPIKE[:(]" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" --include="*.py" .
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
