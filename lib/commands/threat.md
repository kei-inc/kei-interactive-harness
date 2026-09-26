# /threat

Adversarial security pass on a named feature. I will tell you which one. If I do
not, ask before starting, because a whole-codebase sweep produces noise rather
than findings.

## How this runs

The attack stages run in a fresh context, in the `harness-reviewer` subagent.
You wrote this code with me, so you know what it was meant to do, and that is
exactly what stops you seeing what it actually does. The reviewer has not been
told.

1. **Delegate.** Start the `harness-reviewer` subagent with a brief of three
   lines and nothing else:

   ```
   pass: threat
   base: <the default branch, HARNESS_DEFAULT_BRANCH or main>
   feature: <the feature exactly as I named it>
   ```

   Do not add your own account of how the feature works, what we decided, or
   what you think is safe. That is the context the reviewer is there to be
   free of.

2. **Check its findings.** Reviewers are sometimes wrong. For each finding,
   open the file and line it cites and mark it:
   - **confirmed**: you can see the hole, or reproduce the request in your head
     step by step
   - **refuted**: you can point to the specific line that prevents it. Quote it.
   - **unsure**: neither. Keep it in the report.

   Never drop a finding without the line that refutes it.

3. **Report** confirmed and unsure findings in the Stage 3 format below, most
   severe first, with one line at the end listing what you refuted and why.
   Then Stage 4.

If subagents are not available here, run the stages under "For the reviewer"
yourself, and say at the top of the report that this pass was not independent.

## For the reviewer

Your posture for this pass is different from normal. You are not helping build.
You are trying to break what was built. Assume the attacker has read the client
source, knows every endpoint, can craft any request, and has a valid account of
their own.

## Stage 1. Map the surface

List every way into this feature: routes, server actions, webhooks, form
submissions, file uploads, background jobs it can trigger. For each, state the
declared access level and how it is enforced. A surface you cannot find the
enforcement for is the finding.

## Stage 2. Walk the attack classes

Go through these in order. For each, either show the specific line that prevents
it or describe the concrete request that exploits it. Do not answer in the
abstract.

**Broken access control.** This is the one that actually happens, so spend the
most time here.
- Can I read another tenant's record by changing an id in the URL or body?
- Can I write to a record I do not own?
- Can I escalate my role by including a field in an update payload?
- Is there an endpoint that checks authentication but forgets authorization?
- Does the list endpoint filter by owner, or does it filter in the client?

**Injection.**
- Any SQL built by concatenation or interpolation.
- Any shell command built from input.
- Any user content rendered as HTML without sanitizing.
- Any user content placed into a URL, header, or log line without encoding.

**Server-side request forgery.** Any place the server fetches a URL that a user
influenced. Check for allowlists, and check whether the allowlist can be defeated
by a redirect or a DNS trick.

**Secrets and leakage.**
- Anything secret behind a client-exposed env prefix.
- Error responses that carry stack traces, SQL, or internal ids.
- Responses that spread a row and include columns the client should not see.
- Data in URL query strings that ends up in logs and referrers.

**Rate and cost.** What does this feature cost me if someone calls it ten
thousand times in a minute? Name the limit or name its absence.

**Authentication mechanics.** Session lifetime, cookie flags, token storage,
password reset flow, whether logout actually invalidates, whether an invite link
expires.

**Files.** Upload type checking (by content, not extension), size limits, where
files are stored, whether stored files are served from a path that can be
traversed.

## Stage 3. Report

For each finding:

- **What** it is, in one sentence.
- **The exact request or steps** that exploit it. Concrete, reproducible.
- **Severity**: critical if it exposes another user's data or allows takeover;
  high if it costs money or leaks internals; medium otherwise.
- **The fix**, as a specific code change.

Order by severity. If you found nothing critical, say so plainly rather than
padding the list with style observations.

## Stage 4. Afterwards

This stage is back in the main conversation, after the findings are checked.

Add a regression test for every critical and high finding, so that the hole
cannot silently reopen. Record anything deferred in `docs/INVARIANTS.md` under
"Known accepted risks" with a reason.
