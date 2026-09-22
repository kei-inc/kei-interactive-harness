# /scale

Performance and growth pass on a named feature. Ask which one if I did not say.

The question this pass answers is not "is it fast now." It is "what breaks first
when this succeeds." Assume one hundred times the current data and ten times the
current concurrency.

## Stage 1. Find the loops and the queries

- Every database query in the feature. For each: is it bounded, is it indexed on
  the column it filters and sorts by, does it select only what it needs.
- Every query that happens inside a loop or inside a per-row render. These are
  N+1s, and they are invisible with ten rows of test data.
- Every place that loads a whole collection into memory to filter or count it.
  Counting in the database beats counting in the application.

## Stage 2. Growth

Look at `docs/INVARIANTS.md` section 6. For each thing that grows and that this
feature touches:

- What is the query pattern against it?
- At what row count does that pattern become slow? Give an order of magnitude.
- Does pagination use offset? Offset pagination degrades linearly, so say so.

## Stage 3. Payloads

- Response sizes. Anything sending a full collection where a page would do.
- Bundle impact of any new client dependency.
- Images and assets: dimensions, format, whether they are lazy-loaded.

## Stage 4. Caching and repetition

- What is computed on every request that could be computed once?
- What is fetched on every render that does not change?
- Is there a cache key that includes the tenant, so one customer cannot see
  another's cached result? A cache without tenancy in the key is a data leak, not
  just a performance question.

## Stage 5. Failure under load

- Timeouts on external calls.
- Retry behaviour and whether it has backoff and a ceiling.
- Connection pool limits against expected concurrency.
- What happens when the queue backs up or the external service is down. Does the
  feature degrade, or does the page fail?

## Stage 6. Report

A table: what breaks, at roughly what scale, how much work to fix, and whether it
must be fixed now or merely known about. Be honest about the "now" column. Most
things can wait, and saying so is more useful than flagging everything.
