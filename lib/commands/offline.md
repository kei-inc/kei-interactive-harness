# /offline

Prove the app's offline promise: what is captured without a connection
survives, and reaches the server exactly once when the connection returns.
This is the hardest part of an offline-first app to get right and the easiest
to break without noticing, because everything works on a good connection.

It maps the offline path, agrees the scenarios with me, then writes tests at
two levels. It never changes app code to make a test pass: a failing test is a
finding.

## 1. Map the offline path

Find what makes the app work offline: service worker registration and the
worker itself, the web app manifest, local storage (IndexedDB, Dexie, `idb`),
the outbox or queue, what drains it and when (online events, intervals,
background sync), and the server endpoint that receives it.

If there is none of that, say the app is not offline-capable and stop.

Then answer, from the code:

- What does a queued item carry, and does it have an id generated on the
  device?
- **Is the receiving endpoint idempotent?** Sending the same item twice must
  not create two rows (an upsert or `on conflict do nothing` on the device
  id). Retries after a timeout are normal, so without this, "exactly once" is
  luck. If it is not idempotent, report that first: it is the finding, and
  the tests below will prove it.
- What happens to an item the server rejects (validation, 4xx)? It should not
  retry forever or block the items behind it.
- What does the service worker cache, and does the app shell load with no
  network?

Check `docs/INVARIANTS.md` for what the project already promises.

## 2. Scenarios

Propose a short table of scenarios, for example:

- capture while offline: the item is visibly queued
- reload while offline: the app still opens and the queued item is still there
- reconnect: the item reaches the server once, and the queue empties
- the server fails the first sync (500 or timeout): the item is retried later,
  still arrives once, and is not lost
- the server rejects an item: it is set aside with a visible state, and the
  items behind it still sync
- the same item sent twice (a retry after the response was lost): one row

Show me the table and wait. My corrections are the spec.

## 3. Unit tests on the queue

Test the outbox and its drain directly, without a browser, using
`fake-indexeddb` in the test setup so the real storage code runs. Stub only the
network call. Cover ordering, persistence across a reopened database, retry
after failure, rejected items, and the duplicate-send case.

## 4. Browser tests with Playwright

Set up Playwright for each offline app if it is not there: a
`playwright.config.ts` in the app, a `test:e2e` script in the app and one at
the root that runs them all. CI already installs browsers when it finds a
Playwright config and runs `test:e2e`.

- Test a production build (`next build && next start` as Playwright's
  `webServer`): service workers usually register only there.
- Go offline with `context.setOffline(true)`, and use `context.route` rather
  than `page.route` for injected failures, so requests the service worker
  makes are covered too.
- **Assert on the server, not the network.** Count the rows that arrived for
  the item's device id; one row is the pass. Counting requests fails on
  legitimate retries and passes on a duplicate that was sent once each.
- If reaching the capture screen needs a signed-in user, the tests need a
  real backend: run them against the local Supabase stack with a seeded test
  user, and have the `test:e2e` script bring it up (`supabase start`, reset,
  seed) so the CI job needs nothing extra. Never point e2e tests at a shared
  or production project.

Keep the suite small: one spec per scenario, each independent, each under a
minute.

## 5. Report

Run both levels. Report scenarios covered, and **findings**: every scenario
that fails, with what was lost or duplicated and where in the code it happens.
The non-idempotent endpoint, if there is one, goes first.

Commit the setup and passing tests on `play`. Leave failing tests out of the
commit and list them as findings; I decide what to fix.

## Later runs

Re-map the offline path, mention anything that changed (new queued item types,
a new endpoint), and propose scenarios only for what has none.
