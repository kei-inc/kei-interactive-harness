# /preflight

Run this before anything becomes publicly reachable, and again whenever the
shape of the product changes. It covers the parts of the system that do not live
in the repository, which is exactly where the expensive mistakes hide, because no
amount of code review can see them.

Work through it with me. For each item, either confirm it or write it down as an
accepted risk in `docs/INVARIANTS.md`. Do not mark anything as fine without
checking, and say plainly when you cannot verify something from the repo alone.

## Database

Run `SUPABASE_DB_URL=... npx harness rls` against the environment being launched, not
against local. Then confirm by hand:

- [ ] Every table in `public` that `anon` or `authenticated` can reach has RLS
      on, verified against the live database.
- [ ] Grants are explicit in migrations rather than inherited from the old
      platform default. If the audit reports `auto_expose_default`, run
      `npx harness grants` and commit the result as a migration.
- [ ] `anon` holds only the grants the logged-out experience needs.
- [ ] No policy is effectively `true` without a written reason in `.harness/rls-allow.txt`.
- [ ] `anon` has no write policy you did not deliberately grant.
- [ ] Every view is `security_invoker = on`.
- [ ] Every `SECURITY DEFINER` function pins `search_path`.
- [ ] Columns used in policies are indexed.
- [ ] Point in time recovery is enabled, and a restore has actually been tested
      once. An untested backup is a belief, not a backup.
- [ ] Storage buckets are private, with policies on `storage.objects`.

## Supabase auth settings

These live in the dashboard and none of them are visible in git, so they need a
human pass. Check current Supabase documentation for defaults, since these change.

- [ ] Email confirmation is required, if your model assumes verified emails.
- [ ] Redirect URL allowlist contains only your domains. A permissive allowlist
      is an open redirect, which turns into account takeover in an OAuth flow.
- [ ] JWT expiry and refresh rotation are set deliberately.
- [ ] Leaked password protection is on.
- [ ] Custom SMTP is configured. The built-in sender is rate limited and is not
      meant for production traffic.
- [ ] Rate limits on sign-in, sign-up, and password reset are set.
- [ ] Anything you do not use (magic links, phone auth, anonymous sign-in) is off.

## Vercel

- [ ] Deployment protection is on for previews, or previews use a separate
      Supabase branch with no production data.
- [ ] Production secrets exist only in the production environment scope.
- [ ] Functions are in the same region as the database.
- [ ] Security headers are served. Verify against the deployed URL, not the
      config file, since a config that is not applied looks identical in git.
- [ ] A spending or usage alert exists.

## Cloudflare

- [ ] The origin rejects traffic that did not come through Cloudflare. Without
      this, the `.vercel.app` URL bypasses every rule below.
- [ ] Rate limiting rules cover auth endpoints and any route that costs money.
- [ ] Cache rules exclude authenticated routes.
- [ ] Bot protection is on for login and signup.
- [ ] R2 buckets are private.

## The application itself

- [ ] Run `/threat` on the two features that touch the most sensitive data.
- [ ] Every route handler and server action either checks identity or carries an
      explicit public marker with a reason. Count them and read the list.
- [ ] Error responses carry no stack traces. Check a deliberately broken request
      against the deployed environment.
- [ ] Logs carry no tokens, passwords, or full request bodies.
- [ ] There is a way to find out that something broke that does not involve a
      user emailing you: error monitoring with an alert on new production
      issues (`/monitor`), verified by a test error on a preview.
- [ ] Offline-capable apps have tests proving queued work arrives exactly once
      (`/offline`).

## Report

Produce a table of everything unchecked or unverifiable, ordered by what would
hurt most. Be direct about the ones I cannot confirm from the repository, because
a checklist item marked done on the basis of a guess is worse than one left open.
