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
  printf '%s\n' "${DIM}skipped: no database to audit${RESET}"
  no_db_help rls | sed "s/^/${DIM}/; s/$/${RESET}/"
  exit 0
fi
printf '%s\n' "${DIM}auditing: ${DB_SOURCE}${RESET}"

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
STORAGE="$(run_sql "$HARNESS_LIB/sql/storage-audit.sql" 2>/dev/null || true)"
ALL="$(printf '%s\n%s\n' "$OUT" "$STORAGE" | grep -v '^$' || true)"

# Deliberately public objects. One per line: a table name, a "table (policy)"
# string, or a bucket name, exactly as the audit prints it. Each line needs a
# reason after a # so the decision is on record.
ALLOW="$ROOT/.harness/rls-allow.txt"
if [ -f "$ALLOW" ] && [ -n "$ALL" ]; then
  while IFS= read -r line; do
    name="${line%%#*}"; name="$(printf '%s' "$name" | sed 's/[[:space:]]*$//')"
    [ -z "$name" ] && continue
    ALL="$(printf '%s\n' "$ALL" | grep -vF "$name" || true)"
  done < "$ALLOW"
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
  printf '%s\n' "${RED}${ERRORS} database finding(s) that expose data.${RESET}"
  printf '%s\n' "Fix these in a migration, not in the dashboard, so the fix is in git."
  exit 1
fi
printf '%s\n' "${GREEN}No exposure findings. Warnings above are worth a look.${RESET}"
exit 0
