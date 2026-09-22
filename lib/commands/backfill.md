# /backfill

Write the tests for a feature whose shape has settled. This is deliberately not
part of the build loop, because tests written during exploration pin down
decisions I have not made yet.

Ask which feature if I did not say.

## Stage 1. Describe the behaviour first

Before writing any test, list the behaviours in plain sentences, from the outside.
"When a user without access requests a document, they get a 404 rather than a
403." Show me the list and let me correct it. The list is the specification we
never wrote up front, recovered now that the design has stopped moving.

## Stage 2. Write these in this order

1. **The authorization tests.** Every access rule from `docs/INVARIANTS.md` that
   touches this feature, tested from the outside with a real request. These are
   the most valuable tests in the codebase because they fail closed and they
   catch the mistakes that actually cost money.
2. **The boundary tests.** Malformed input, missing fields, wrong types, empty
   collections, oversized payloads, unicode, null where an object was expected.
3. **The happy path.** One test, at the level of the whole feature, that proves
   the thing works end to end.
4. **The regressions.** Any bug we already found and fixed gets a test that would
   have caught it.

## Stage 3. What not to test

- Do not test implementation detail. If a refactor that preserves behaviour breaks
  the test, the test is wrong.
- Do not mock the thing under test. Mock the network and the clock, not the logic.
- Do not chase coverage percentage. Coverage of authorization paths matters;
  coverage of a formatting helper does not.
- No snapshot tests of large structures. They get blindly updated and stop meaning
  anything.

## Stage 4. Leave it runnable

Every test runs from a clean database with no manual setup. If setup is needed,
it is a fixture in the repo, not an instruction in a comment. Then run the suite
and show me the result.

## Stage 5. Clear the spike markers

Any `SPIKE:` marker on code now covered by these tests can come off. List them
and let me confirm.
