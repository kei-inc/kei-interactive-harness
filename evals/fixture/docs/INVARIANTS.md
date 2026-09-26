# Invariants

## Tenancy boundary
- Boundary key: `user_id`. Every table holding user data carries it.
- Enforced in both application queries and row level security.

## Public surface
Nothing is public except the marketing home page and /login.

## Things that grow
| Thing | Grows with | Bounded query? | Index on the hot column? |
|---|---|---|---|
| documents | users × usage | must be | user_id, created_at |

## Data I would hate to leak
- Document bodies. Other users' email addresses.
