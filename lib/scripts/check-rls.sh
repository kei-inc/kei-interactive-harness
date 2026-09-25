#!/usr/bin/env bash
# Audit the database that actually backs this app.
#
# In a Supabase app the anon key is in every browser, so RLS is the perimeter.
# This is the only check in the harness that talks to a live database, and it is
# the most important one.
#
#   SUPABASE_DB_URL=postgres://... bash "$HARNESS_LIB/scripts/check-rls.sh"
#
# Point it at a branch or staging database in CI. Pointing it at production
# read-only is also fine, since every query here is a catalogue read.

set -uo pipefail
# HARNESS_PROJECT_ROOT is the repo being checked. HARNESS_LIB is where this
# package's own assets live. Both are set by the harness CLI; the fallbacks let
# these scripts still run standalone from an ejected copy.
ROOT="${HARNESS_PROJECT_ROOT:-$(pwd)}"
HARNESS_LIB="${HARNESS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'

[ -f "$ROOT/.harness/config.sh" ] && . "$ROOT/.harness/config.sh"

# This audit assumes Supabase: an anon key shipped to browsers, which is what
# makes RLS the perimeter. Against a plain Postgres (Neon, Vercel Postgres, RDS
# behind Prisma or Drizzle) there is no anon key, RLS is usually and correctly
# off, and every table would be reported as exposed. So it runs only when the
# project uses Supabase.
is_supabase() {
  case "${HARNESS_SUPABASE:-auto}" in
    on) return 0 ;; off) return 1 ;;
  esac
  [ -d "$ROOT/supabase" ] && return 0
  grep -qE '"(@supabase/[^"]+|supabase)"[[:space:]]*:' "$ROOT/package.json" 2>/dev/null
}
if ! is_supabase; then
  printf '%s\n' "${DIM}skipped: not a Supabase project (set HARNESS_SUPABASE=on to force)${RESET}"
  exit 0
fi

# Only SUPABASE_DB_URL or a detected local Supabase stack, never DATABASE_URL:
# the latter is the generic name every ORM uses, and pointing this audit at a
# non-Supabase database is the false alarm described above.
. "$HARNESS_LIB/scripts/_db.sh"

if ! resolve_db; then
  if [ -n "${CI:-}" ] && [ "${HARNESS_REQUIRE_DB_AUDIT:-1}" != "0" ]; then
    printf '%s\n' "::error title=Database audit did not run::SUPABASE_DB_URL is not set, so grants and RLS were not checked."
    printf '%s\n' "${RED}No database to audit. In CI that is a failure, not a pass.${RESET}"
    printf '%s\n' "Add a repository secret SUPABASE_DB_URL holding the SESSION POOLER URI"
    printf '%s\n' "(Project Settings > Database > Connection string > Session pooler), or set"
    printf '%s\n' "HARNESS_REQUIRE_DB_AUDIT=0 in .harness/config.sh to opt out on purpose."
    exit 1
  fi
  printf '%s\n' "${DIM}skipped: no database to audit${RESET}"
  no_db_help rls | sed "s/^/${DIM}/; s/$/${RESET}/"
  exit 0
fi
printf '%s\n' "${DIM}auditing: ${DB_SOURCE}${RESET}"

# Prove the connection before trusting any answer from it.
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"   # an unreachable host fails fast
_probe="$(mktemp)"; printf 'select 1;\n' > "$_probe"
CONN="$(run_sql "$_probe" 2>&1)"; crc=$?; rm -f "$_probe"
if [ "$crc" -eq 127 ]; then no_client_help; [ -n "${CI:-}" ] && exit 1; exit 0; fi
if [ "$crc" -ne 0 ] || ! printf '%s' "$CONN" | grep -q '1'; then
  printf '%s\n' "${RED}Cannot connect to the database, so nothing was audited.${RESET}"
  printf '%s\n' "$CONN" | head -3 | sed 's/^/    /'
  if printf '%s' "$DB" | grep -qE '@db\.[a-z0-9]+\.supabase\.co'; then
    printf '%s\n' "This is the DIRECT host, which is IPv6-only. CI runners and many networks"
    printf '%s\n' "are IPv4. Use the SESSION POOLER URI instead:"
    printf '%s\n' "  postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres"
  else
    printf '%s\n' "Check the URL and password (a rotated password is the usual cause), and"
    printf '%s\n' "that the database is running."
  fi
  [ -n "${CI:-}" ] && printf '%s\n' "::error title=Database audit could not connect::Nothing was audited."
  exit 1
fi

OUT="$(run_sql "$HARNESS_LIB/sql/rls-audit.sql" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 127 ]; then no_client_help; exit 0; fi
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "${YELLOW}Could not query the database (exit $rc). Is it running and reachable?${RESET}"
  exit 1
fi
if ! printf '%s\n' "$OUT" | grep -q '^MARKER|harness|audit-complete|'; then
  printf '%s\n' "${RED}The audit did not complete, so its silence means nothing.${RESET}"
  printf '%s\n' "Checked: ${DB_SOURCE}. Confirm the database is running and reachable, then retry."
  exit 1
fi
OUT="$(printf '%s\n' "$OUT" | grep -v '^MARKER|')"
STORAGE="$(run_sql "$HARNESS_LIB/sql/storage-audit.sql" 2>/dev/null)"
if ! printf '%s\n' "$STORAGE" | grep -q '^MARKER|harness|storage-complete|'; then
  printf '%s\n' "${RED}The storage audit did not complete, so buckets were not checked.${RESET}"
  exit 1
fi
STORAGE="$(printf '%s\n' "$STORAGE" | grep -v '^MARKER|')"
ALL="$(printf '%s\n%s\n' "$OUT" "$STORAGE" | grep -v '^$' || true)"

# Deliberately public objects, from .harness/rls-allow.txt. One per line:
#   <object exactly as the audit prints it>   # reason
# A table entry (public.plans) also covers that table's policies
# (public.plans (plans_read)), and nothing else: public.plans_history is a
# different object. Add until(YYYY-MM-DD) to the reason for a temporary allow;
# after that date the finding comes back.
ALLOW="$ROOT/.harness/rls-allow.txt"
EXPIRED=""
if [ -f "$ALLOW" ] && [ -n "$ALL" ]; then
  today="$(date +%Y-%m-%d)"
  KEEP=""
  while IFS= read -r finding; do
    [ -z "$finding" ] && continue
    obj="$(printf '%s' "$finding" | cut -d'|' -f3)"
    allowed=0
    while IFS= read -r line; do
      name="${line%%#*}"; name="$(printf '%s' "$name" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')"
      [ -z "$name" ] && continue
      if [ "$obj" = "$name" ] || [ "${obj#"$name ("}" != "$obj" ]; then
        until="$(printf '%s' "$line" | sed -nE 's/.*until\(([0-9]{4}-[0-9]{2}-[0-9]{2})\).*/\1/p')"
        if [ -n "$until" ] && [ "$today" \> "$until" ]; then
          EXPIRED="$EXPIRED\n    $name  (allowed until $until)"
        else
          allowed=1
        fi
      fi
    done < "$ALLOW"
    [ "$allowed" -eq 0 ] && KEEP="$KEEP$finding"$'\n'
  done <<< "$ALL"
  ALL="$(printf '%s' "$KEEP" | grep -v '^$' || true)"
fi
if [ -n "$EXPIRED" ]; then
  printf '%b\n' "${YELLOW}Expired allowlist entries in .harness/rls-allow.txt; these findings are back:${EXPIRED}${RESET}"
fi

if [ -z "$ALL" ]; then
  printf '%s\n' "${GREEN}Database audit clean. RLS is on everywhere it should be.${RESET}"
  exit 0
fi

ERRORS=0
while IFS='|' read -r sev check object detail; do
  [ -z "${sev:-}" ] && continue
  if [ "$sev" = "ERROR" ]; then
    printf '%s\n' "${RED}  ERROR  ${check}${RESET}  ${object}"
    printf '%s\n' "         ${detail}"
    ERRORS=$((ERRORS + 1))
  else
    printf '%s\n' "${YELLOW}  warn   ${check}${RESET}  ${object}"
    printf '%s\n' "${DIM}         ${detail}${RESET}"
  fi
done <<< "$ALL"

echo
if [ "$ERRORS" -gt 0 ]; then
  printf '%s\n' "${RED}${ERRORS} database finding(s) that expose data or break access to it.${RESET}"
  printf '%s\n' "Fix these in a migration, not in the dashboard, so the fix is in git."
  exit 1
fi
printf '%s\n' "${GREEN}No exposure findings. Warnings above are worth a look.${RESET}"
exit 0
