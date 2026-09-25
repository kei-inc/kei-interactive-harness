# /monitor

Set up error monitoring with Sentry, so a crash in production reaches me
before a user does. One app at a time, on `play`, verified on a preview
deployment before it counts as done.

Sentry's Next.js setup changes between major versions. Check the current
Sentry docs for the version being installed rather than trusting memory, and
say which version the steps below were checked against.

## 1. Survey

For each Next.js app (every `package.json` that depends on `next`): whether
`@sentry/nextjs` is already installed, whether it has `instrumentation.ts`,
`app/global-error.tsx`, a Content Security Policy in its headers, and a
service worker or offline storage. In a Turborepo, check whether `turbo.json`
runs in strict env mode, since build-time variables then have to be listed.

Report what is there and what is missing, then ask two things:

- **Sentry projects.** One Sentry project per app (recommended: errors,
  alerts and quotas stay separate) or one shared project tagged by app.
- **Session Replay.** Off unless I ask. It records what users see, which is a
  privacy decision and a cost, not a default.

## 2. Accounts and keys

Install Sentry through the Vercel Marketplace integration where the project is
on Vercel: it creates the Sentry projects and provisions the DSN and auth token
into each Vercel project's environment. That part is a dashboard step for me;
say exactly which Vercel projects to connect and wait until I confirm.

Never ask me to paste the auth token into chat or a file. Locally, only the
DSN is needed, and it is public by design. Add every Sentry variable the code
reads to the app's `.env.example` with a placeholder, or the env-parity check
will flag it.

## 3. Wire each app

Follow the current Sentry manual setup for the App Router, which covers:

- client init in `instrumentation-client.ts`, server and edge init loaded from
  `instrumentation.ts`, and `onRequestError` exported from it so errors in
  server components, route handlers and server actions are captured
- `app/global-error.tsx` reporting the error, so a crash in the root layout is
  not lost
- `next.config` wrapped with `withSentryConfig`, uploading source maps at build
  time so stack traces are readable, and deleting them from the deployed output
- a tunnel route, so ad blockers do not drop browser reports

Settings, in every app:

- `sendDefaultPii: false`. Identify users by id only, never email or name.
  Scrub request bodies and anything token-shaped in `beforeSend`.
- A low `tracesSampleRate` in production (0.1 or less). Errors are always sent;
  traces are what costs money.
- `environment` from `VERCEL_ENV`, so preview errors do not page anyone about
  production, and `release` from the commit, so an error points at a deploy.

Where it applies:

- **Offline apps.** Use Sentry's offline transport
  (`makeBrowserOfflineTransport`), so errors raised without a connection are
  held on the device and sent on reconnect. Errors inside a hand-written
  service worker are not covered by the browser SDK; say so, and note where
  the worker swallows errors.
- **Content Security Policy.** The tunnel route keeps reports same-origin; if
  there is no tunnel, the Sentry ingest host must be in `connect-src`.
- **Turborepo strict env mode.** List the Sentry build variables in
  `turbo.json`, or source maps silently stop uploading.
- **Existing error handling.** Find `catch` blocks that swallow errors
  (log-and-continue, empty catches, `.catch(() => {})`). Do not change them all;
  list the ones on paths I would want to hear about and ask.

## 4. Verify

Commit on `play` and push. On the preview deployment, trigger one test error
from the browser and one from a route handler (a temporary route, or Sentry's
example page), confirm both arrive with readable stack traces and the preview
environment, then remove the test code in the next commit.

## 5. Alerts

Monitoring nobody looks at is a log. Before calling it done, have me set an
alert in Sentry for new issues in production (email, or Slack if the team uses
it), and a spike alert on error volume. These are dashboard steps; list them
and wait for me to confirm.

## Report

Per app: installed, verified on preview, alert set. Plus anything left open
(service worker errors, swallowed catches I chose to keep). The stack check
stops flagging an app once `@sentry/nextjs` is in its `package.json`.
