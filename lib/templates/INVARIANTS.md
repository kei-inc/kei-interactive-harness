# Invariants

> The things that must be true of this system. Written in plain language, kept
> short enough to actually read, and updated whenever reality changes.
>
> This is the most valuable file in the harness. Generic tooling cannot know that
> `workspace_id` is the tenant boundary in your app, or that the `exports` table
> is the one that will blow up first. This file tells it.
>
> Fill in every section. If a section does not apply, write "not applicable" and
> say why, rather than deleting it.

## 1. Actors

Who or what touches this system, and what each one is trusted with.

| Actor | Authenticated? | Can read | Can write | Notes |
|---|---|---|---|---|
| Anonymous visitor | no | | | |
| Signed-in user | yes | | | |
| Workspace admin | yes | | | |
| Service / cron | machine token | | | |
| Me, in the admin panel | yes | | | |

## 2. The tenancy boundary

The single column or claim that separates one customer's data from another's.

- Boundary key: `______` (for example `workspace_id`, `user_id`, `org_id`)
- Every table holding user data carries this key: yes / no (list exceptions)
- It is enforced in: application queries / database row-level security / both
- If a query on a user-data table does not filter by this key, that is a bug.

## 3. Trust boundaries

Every place where data crosses from somewhere I do not control into somewhere I
do. Each one needs schema validation on entry.

- [ ] HTTP request bodies
- [ ] Query and path parameters
- [ ] Webhooks from: `______`
- [ ] Third-party API responses from: `______`
- [ ] File uploads
- [ ] Anything read out of the database that was originally user-supplied and is
      about to be rendered as HTML
- [ ] Environment variables at boot

## 4. Public surface

Routes and resources reachable without authentication. This list should be short,
and every addition to it deserves a moment of thought.

| Path | Why it is public | Rate limited? |
|---|---|---|
| | | |

## 5. Secrets

| Name | Where it lives | Rotatable without downtime? |
|---|---|---|
| | | |

Client-exposed variables that are intentionally public (anon keys, publishable
keys, analytics IDs) go in `.harness/allow-public-env.txt` so the boundary checker
stops warning about them.

## 6. Things that grow

The tables, files, or collections that get bigger the more the product succeeds.
These are where performance dies first.

| Thing | Grows with | Bounded query? | Index on the hot column? |
|---|---|---|---|
| | | | |

## 7. Things that are expensive

Operations that cost real money or real time: model calls, image processing,
external APIs, email sends. Each needs a rate limit and an idempotency story.

| Operation | Cost driver | Rate limited | Idempotent on retry |
|---|---|---|---|
| | | | |

## 8. Data I would hate to leak

Be specific. This is the list that `/threat` works hardest on.

-

## 9. Data I would hate to lose

And what the recovery path is.

| Data | Backup | Tested restore? |
|---|---|---|
| | | |

## 10. Known accepted risks

Things I know are not right and have decided to live with for now. Writing them
down is what separates a decision from an oversight.

| Risk | Why it is acceptable today | What would change that |
|---|---|---|
| | | |
