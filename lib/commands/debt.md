# /debt

The long view of the ratchet: where the debt is, how far each metric is from
its goal, and what is cheap to pay down. Run it between batches, not in the
middle of one.

Use `pnpm exec harness` if the project has a `pnpm-lock.yaml`, otherwise
`npx harness`.

## Gather

```
npx harness ratchet --goals
npx harness ratchet --check
sort -t'|' -k3 -nr .harness/ratchet.txt
```

`.harness/ratchet.txt` is one `metric|file|count` line per file. Metrics that
start with `~` are tracked for interest and never enforced. `.harness/goals.txt`
holds my targets; it is mine to edit.

## Report

1. **Against the goals.** Each enforced metric: now, goal, and how far off. One
   line for the tracked ones together.
2. **Where it lives.** For each enforced metric that is off its goal, the three
   files carrying the most, with counts.
3. **Spikes.** Every `SPIKE(` marker with its age in days, oldest first. Past
   thirty days it is debt, not exploration; say which of those look settled
   enough to clear.
4. **Cheap wins.** Up to three things that could be fixed in a small diff
   today. Prefer single occurrences in a file (clearing one takes the file off
   the list), `eslint-disable` with no reason after `--`, and `as any` where the
   real type is obvious from the code around it. Show the lines, and say how
   big each fix is.
5. **Goals to lower.** Any metric already below its goal. Lowering the goal to
   the current count locks in the progress.

## Then

Ask what to do. If I pick cheap wins, fix them on `play` as a small diff and
commit; the pre-commit hook tightens the baseline and stages it into the same
commit. If I agree to lower goals, edit `.harness/goals.txt` to the current
counts and commit that separately.

Never run `ratchet --accept` from here. Accepting debt is a decision for the
moment it is taken, which is `/ship`.
