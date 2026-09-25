#!/usr/bin/env bash
# Checks specific to Next.js App Router, Supabase, Vercel, and Cloudflare.
#
# These catch the mistakes that are unique to this stack and invisible to
# generic linters. Each hard failure has an explicit escape hatch comment, so
# the harness fails closed while still letting you say "yes, I meant that".

set -uo pipefail
# HARNESS_PROJECT_ROOT is the repo being checked. HARNESS_LIB is where this
# package's own assets live. Both are set by the harness CLI; the fallbacks let
# these scripts still run standalone from an ejected copy.
ROOT="${HARNESS_PROJECT_ROOT:-$(pwd)}"
HARNESS_LIB="${HARNESS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

# Per-project overrides. Everything here is optional; a project that sets
# nothing gets the harness defaults.
#   HARNESS_DEFAULT_BRANCH   branch that rejects spike markers
#   HARNESS_SPIKE_MAX_DAYS   age at which a dated spike starts nagging
#   HARNESS_DISABLE          space-separated check ids to skip
#   HARNESS_EXTRA_METRICS    additional "label|regex" entries for the ratchet
[ -f "$ROOT/.harness/config.sh" ] && . "$ROOT/.harness/config.sh"
disabled() { case " ${HARNESS_DISABLE:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'
FAIL=0

EXCLUDES=(--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist
          --exclude-dir=.git --exclude-dir=coverage --exclude-dir=.vercel
          --exclude-dir=.turbo --exclude-dir=supabase/.temp)

block() { printf '%s\n' "${RED}BLOCKED: $1${RESET}"; FAIL=1; }
note()  { printf '%s\n' "${YELLOW}note: $1${RESET}"; }

if ! disabled service-role; then
# --- 1. The service role key bypasses RLS entirely. -------------------------
# It must never be reachable from code that can be bundled for the browser.
# The `server-only` package makes that a build error, so we require it.

SR_FILES="$(grep -rlE 'SERVICE_ROLE|SUPABASE_SECRET_KEY|sb_secret_' --include='*.ts' --include='*.tsx' \
            --include='*.js' --include='*.jsx' "${EXCLUDES[@]}" . 2>/dev/null || true)"
for f in $SR_FILES; do
  case "$f" in
    *.d.ts|*/env.example*|*.md) continue ;;
  esac
  if grep -q '"use client"\|'"'"'use client'"'"'' "$f"; then
    block "service role key referenced in a client component: $f"
    printf '%s\n' "    This key bypasses row level security. It cannot go near the browser."
  elif ! grep -q "server-only" "$f"; then
    block "service role key in a file that does not import server-only: $f"
    printf '%s\n' "    Add: import 'server-only'  at the top, so a bad import becomes a build error."
  fi
done

fi
if ! disabled server-actions; then
# The names that count as "this handler establishes identity". requireUser is
# the convention the rules teach; the rest are common enough to accept.
AUTH_RE='requireUser|requireAuth|getUser|getCurrentUser|authorize|verifyWebhook'
[ -n "${HARNESS_AUTH_PATTERN:-}" ] && AUTH_RE="$AUTH_RE|$HARNESS_AUTH_PATTERN"

# --- 2. Server actions are public HTTP endpoints. ---------------------------
# A "use server" function is a POST route that anyone can call directly. It does
# not inherit the auth of the page that rendered the form. Every action file
# must either check identity or declare itself deliberately public.
#
# This is a per-FILE heuristic: one identity check anywhere in the file
# satisfies it, even if the file exports five actions and only one checks.
# Keep action files small, or lean on /threat, which reads per function.

ACTION_FILES="$(grep -rl "^[[:space:]]*['\"]use server['\"]" --include='*.ts' --include='*.tsx' \
                "${EXCLUDES[@]}" . 2>/dev/null || true)"
for f in $ACTION_FILES; do
  if ! grep -qE "$AUTH_RE|@public-action" "$f"; then
    block "server action with no identity check: $f"
    printf '%s\n' "    Server actions are callable by anyone with a crafted POST."
    printf '%s\n' "    Add an auth check, or write // @public-action with a reason."
  fi
done

fi
if ! disabled route-handlers; then
# --- 3. Route handlers are public by default. ------------------------------

# Any route file under any app/ directory, so monorepos (apps/*/src/app/...)
# are covered as well as a single app at the root.
ROUTE_FILES="$(find . \( -name node_modules -o -name .next -o -name .git -o -name .turbo -o -name dist \) -prune -o \
  -type f -path '*/app/*' \( -name 'route.ts' -o -name 'route.tsx' -o -name 'route.js' -o -name 'route.mjs' \) -print 2>/dev/null \
  | sed 's|^\./||' || true)"
for f in $ROUTE_FILES; do
  if ! grep -qE "$AUTH_RE|@public-route" "$f"; then
    block "route handler with no identity check: $f"
    printf '%s\n' "    Add an auth check, or write // @public-route with a reason."
  fi
done

fi
if ! disabled getsession; then
# --- 4. getSession does not verify the token. ------------------------------
# It reads the cookie and trusts it. On the server you need getUser, which
# revalidates against the auth server. Spoofing a session cookie is trivial.

GS="$(grep -rn '\.auth\.getSession()' --include='*.ts' --include='*.tsx' \
      "${EXCLUDES[@]}" . 2>/dev/null || true)"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  f="${line%%:*}"
  grep -q '"use client"\|'"'"'use client'"'"'' "$f" && continue
  grep -q '@allow-getsession' "$f" && continue
  block "getSession() in server code: $line"
  printf '%s\n' "    getSession reads the cookie without verifying it. Use getUser() here."
done <<< "$GS"

fi
if ! disabled middleware; then
# --- 5. Middleware is not an authorization boundary. -----------------------
# It runs before the request reaches your code and has been bypassable in the
# past. Use it for redirects and session refresh. Put the real check in the
# data layer, where RLS can back it up.

if [ -f middleware.ts ] || [ -f src/middleware.ts ]; then
  MW="$(ls middleware.ts src/middleware.ts 2>/dev/null | head -1)"
  if grep -qE 'role|isAdmin|permission' "$MW" 2>/dev/null; then
    note "middleware appears to make an authorization decision ($MW)"
    printf '%s\n' "${DIM}       Middleware is for redirects. The enforcing check belongs in the query.${RESET}"
  fi
fi

fi
if ! disabled migrations; then
# --- 6. Every migration that creates a table: grant, RLS, policies. --------
# Supabase's Data API grants change (new projects from 2026-05-30, existing
# projects from 2026-10-30) means new public tables get no grants
# automatically. Grants decide whether a role can reach a table; RLS decides
# which rows. They travel as a unit, in the migration that creates the table.
#
#   missing RLS    -> blocked. Expensive to undo if the table is ever granted.
#   missing grant  -> note. Fails closed: the table is simply unreachable from
#                     supabase-js. Mark a server-only table -- @no-data-api.

for m in supabase/migrations/*.sql; do
  [ -e "$m" ] || continue
  tables="$(grep -ioE 'create table( if not exists)?[[:space:]]+(public\.)?"?[a-z_][a-z0-9_]*' "$m" \
            | sed -E 's/.*[[:space:]]//; s/^public\.//; s/"//g' | sort -u)"
  [ -z "$tables" ] && continue
  if ! grep -qi 'enable row level security' "$m"; then
    block "migration creates a table without enabling RLS: $m"
    printf '%s\n' "    Add, in this same migration: grants, then enable RLS, then policies."
  fi
  # A bulk grant in this migration technically covers its tables; the bulk
  # grant gets its own note below instead of a misleading per-table one.
  bulk=0
  grep -qiE 'grant[^;]+on[[:space:]]+all[[:space:]]+tables[[:space:]]+in[[:space:]]+schema[[:space:]]+public' "$m" && bulk=1
  if ! grep -q '@no-data-api' "$m" && [ "$bulk" -eq 0 ]; then
    # Every table any GRANT in this migration names. Read whole statements, not
    # lines: one grant commonly spans several lines and lists several tables.
    granted="$(sed 's/--.*$//' "$m" | tr '\n' ' ' | tr ';' '\n' | awk '
      { s = tolower($0) }
      s ~ /^[ \t]*grant[ \t]/ && s ~ /[ \t]on[ \t]/ && s ~ /[ \t]to[ \t]/ {
        sub(/^.*[ \t]on[ \t]+/, "", s); sub(/[ \t]+to[ \t].*$/, "", s); sub(/^table[ \t]+/, "", s)
        n = split(s, parts, ",")
        for (i = 1; i <= n; i++) { p = parts[i]; gsub(/[ \t"]/, "", p); sub(/^public\./, "", p); print p }
      }')"
    for t in $tables; do
      if ! printf '%s\n' "$granted" | grep -qix "$t"; then
        note "table $t has no grant in $m"
        printf '%s\n' "${DIM}       Without one, supabase-js cannot reach it (42501). Add e.g.${RESET}"
        printf '%s\n' "${DIM}       grant select, insert, update, delete on public.$t to authenticated;${RESET}"
        printf '%s\n' "${DIM}       or mark the migration -- @no-data-api if the table is server-only.${RESET}"
      fi
    done
  fi
  # Re-exposing everything is the posture the platform change moves away from.
  if grep -qiE 'grant[^;]+on[[:space:]]+all[[:space:]]+tables[[:space:]]+in[[:space:]]+schema[[:space:]]+public[^;]+anon' "$m"; then
    note "bulk grant to anon on all public tables in $m"
    printf '%s\n' "${DIM}       Grant per table, per role. A bulk grant exposes every future review gap too.${RESET}"
  fi
  if grep -qiE 'alter[[:space:]]+default[[:space:]]+privileges[^;]+grant[^;]+anon' "$m"; then
    note "default privileges re-grant new tables to anon in $m"
    printf '%s\n' "${DIM}       This restores auto-exposure of every future table. Only do it knowingly.${RESET}"
  fi
done

# The CLI's temporary cutover flag is removed on 2026-10-30, and Supabase
# branching already fails to parse a config that contains it.
if [ -f supabase/config.toml ] && grep -q 'auto_expose_new_tables' supabase/config.toml; then
  note "supabase/config.toml sets auto_expose_new_tables"
  printf '%s\n' "${DIM}       Temporary flag, removed 2026-10-30, and it breaks branch config parsing.${RESET}"
  printf '%s\n' "${DIM}       Remove it and put explicit grants in migrations instead.${RESET}"
fi

fi
if ! disabled cache-review; then
# --- 7. Per-user data in a shared cache. -----------------------------------

CACHE="$(grep -rn 'unstable_cache\|revalidate[[:space:]]*[:=]' --include='*.ts' --include='*.tsx' \
         "${EXCLUDES[@]}" . 2>/dev/null || true)"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  f="${line%%:*}"
  if grep -qE 'getUser|user\.id|session' "$f" 2>/dev/null && ! grep -q '@cache-reviewed' "$f"; then
    note "cached path in a file that also touches user identity: $f"
    printf '%s\n' "${DIM}       A cache key without the user id in it serves one customer's data to another.${RESET}"
    printf '%s\n' "${DIM}       Mark // @cache-reviewed once you have checked the key.${RESET}"
  fi
done <<< "$CACHE"

fi
if ! disabled wrangler; then
# --- 8. Cloudflare Worker secrets in plaintext config. ---------------------

if [ -f wrangler.toml ] || [ -f wrangler.jsonc ] || [ -f wrangler.json ]; then
  WF="$(ls wrangler.toml wrangler.jsonc wrangler.json 2>/dev/null | head -1)"
  if grep -qiE '(secret|password|api_key|token|service_role).*=.*["'"'"'][^"'"'"']{12,}' "$WF" 2>/dev/null; then
    block "possible secret in $WF"
    printf '%s\n' "    Use: wrangler secret put NAME   so it never lands in the repo."
  fi
fi

fi
if ! disabled env-parity; then
# --- 9. Environment parity. ------------------------------------------------
# Every variable the code reads should appear in .env.example, so that cloning
# the repo tells you what you need rather than failing at runtime.

# Every .env.example in the repo counts, so a monorepo's apps/*/.env.example
# files are all consulted. Names ending in _ are prefixes from template
# strings (process.env.NEXT_PUBLIC_${name}), not variables.
EXAMPLES="$(find . \( -name node_modules -o -name .git -o -name .next \) -prune -o -type f -name '.env.example' -print 2>/dev/null)"
if [ -n "$EXAMPLES" ]; then
  DECLARED="$(cat $EXAMPLES 2>/dev/null | sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Z0-9_]+)=.*/\2/p' | sort -u)"
  USED="$(grep -rhoE 'process\.env\.[A-Z0-9_]+' --include='*.ts' --include='*.tsx' \
          --include='*.js' --include='*.mjs' "${EXCLUDES[@]}" . 2>/dev/null \
          | sed 's/process\.env\.//' | grep -v '_$' | sort -u)"
  MISSING=""
  for v in $USED; do
    case "$v" in NODE_ENV|VERCEL*|CI|NEXT_RUNTIME|npm_*) continue ;; esac
    printf '%s\n' "$DECLARED" | grep -qx "$v" || MISSING="$MISSING $v"
  done
  if [ -n "$MISSING" ]; then
    note "environment variables used in code but absent from every .env.example:"
    for v in $MISSING; do printf '%s\n' "       $v"; done
  fi
else
  note "no .env.example. Create one so a fresh clone knows what it needs."
fi
fi
if ! disabled observability; then
# --- 10. Knowing when production breaks, and when it gets slow. -------------
# Never blocks: an app without these works, you just find out about problems
# from users. Flagged in CI as well, so a green run does not hide the gap.
#   HARNESS_OBSERVABILITY_SKIP   space-separated app dirs to leave out

APPS="$(find . \( -name node_modules -o -name .git -o -name .next \) -prune -o -type f -name package.json -print 2>/dev/null \
        | xargs grep -lE '"next"[[:space:]]*:' 2>/dev/null | sed 's|/package.json$||; s|^\./||; s|^\.$|.|' | sort)"
NO_MONITOR=""; NO_SPEED=""
for a in $APPS; do
  case " ${HARNESS_OBSERVABILITY_SKIP:-} " in *" $a "*) continue ;; esac
  grep -q '"@sentry/' "$a/package.json" || NO_MONITOR="$NO_MONITOR $a"
  grep -q '"@vercel/speed-insights"' "$a/package.json" || NO_SPEED="$NO_SPEED $a"
done
if [ -n "$NO_MONITOR" ]; then
  note "no error monitoring in:$NO_MONITOR"
  printf '%s\n' "${DIM}       Production errors go unseen until someone reports them. Run /monitor.${RESET}"
fi
if [ -n "$NO_SPEED" ]; then
  note "no Speed Insights in:$NO_SPEED"
  printf '%s\n' "${DIM}       Real users' page speed is not measured. Run /perf.${RESET}"
fi
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  for a in $NO_MONITOR; do
    printf '%s\n' "::warning title=No error monitoring: $a::Production errors in $a go unseen until someone reports them. Run /monitor."
  done
  for a in $NO_SPEED; do
    printf '%s\n' "::warning title=No Speed Insights: $a::Real users' page speed in $a is not measured. Run /perf."
  done
fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '%s\n' "${GREEN}Stack checks clear.${RESET}"
else
  printf '%s\n' "${RED}Stack checks failed.${RESET}"
fi
exit "$FAIL"
