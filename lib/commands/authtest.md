# /authtest

Prove that every server entry point turns away the wrong caller. Row level
security guards the database; this guards the code in front of it, where a
missing check or the wrong helper hands data to anyone who asks.

It inventories, agrees an access table with me, then writes tests. It never
changes a handler to make a test pass: a failing test is a finding, and I
decide the fix.

## 1. Inventory

Find every entry point that runs on the server:

- route handlers: `app/**/route.ts` (and `.js`), every exported HTTP method
- server actions: files or functions marked `'use server'`
- anything else the project treats as an endpoint (webhooks, cron routes,
  ingest endpoints)

For each one, record the app, the path and method, and the first guard it
calls. A guard is anything that establishes who the caller is before data is
touched: the project's `require*` helpers, `getUser`/`getSession` followed by
a check, a token or signature check. Read the guard helpers themselves to learn
what each one lets through (signed out, deactivated, which roles).

Flag, before anything else:

- entry points with no guard at all
- a guard that is called but whose result is not checked before data is read
- guards called after the first database or storage call

## 2. The access table

Propose one row per entry point: who should get in, and who must be turned
away. The callers to consider are signed out, a signed-in user with the lowest
role, each higher role the app has, a deactivated user, and a caller with a
bad or missing token where tokens are used. Mark public entry points (auth
callbacks, public config, health checks) as public with a reason.

Show me the table and wait. I correct it; my answer is the spec. Do not write
tests against a table I have not confirmed.

## 3. One shared helper per app

Before any test, write a single helper that sets who the caller is. Fake
identity at the lowest layer the guards read from (the session lookup, the
Supabase `auth.getUser` call, the token lookup), never by mocking the guard
itself: the point is that the real guard runs. The helper takes a caller
description (`signedOut`, `crew`, `admin`, `deactivated`, `badToken`, ...)
and nothing else.

Put it next to the app's other test utilities. If the app has no test runner
yet, stop and say so rather than adding one.

## 4. Tests

For each entry point, one test file beside it (follow the project's naming),
with one case per caller that must be turned away: call the exported handler
directly with a `Request`, assert the status (401 signed out, 403 wrong role or
deactivated, or whatever the guard returns), and assert that no data came back.
Add one case for a caller who should get in, so a guard that refuses everyone
cannot pass.

Keep the tests independent of the database: stub the data layer only as far as
needed for the allowed case to reach a response.

## 5. Report

Run the new tests. Then report:

- the count of entry points covered, and any skipped with the reason
- **findings**: every test that fails because the wrong caller got in. Each one
  is a security bug; show the handler, the caller who got through, and what
  they could reach
- entry points with no guard that I did not mark public

Commit the helper and the passing tests on `play`. Leave failing tests out of
the commit and list them as findings; I decide whether each is a bug to fix now
or a table row to correct.

## Later runs

Re-running is incremental: inventory again, and only propose table rows and
tests for entry points that have none. Mention any existing test whose
handler's guard has changed since the test was written.
