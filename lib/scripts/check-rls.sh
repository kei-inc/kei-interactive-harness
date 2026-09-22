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

DB="${SUPABASE_DB_URL:-${DATABASE_URL:-}}"

if [ -z "$DB" ]; then
  printf '%s\n' "${DIM}skipped: set SUPABASE_DB_URL to audit row level security${RESET}"
  printf '%s\n' "${DIM}  local:  supabase status --output json  (look for DB URL)${RESET}"
  exit 0
fi

if ! command -v psql >/dev/null 2>&1; then
  printf '%s\n' "${YELLOW}psql not installed. brew install libpq, or use the supabase CLI.${RESET}"
  exit 0
fi

OUT="$(psql "$DB" -X -q -f "$HARNESS_LIB/sql/rls-audit.sql" 2>/dev/null)"
STORAGE="$(psql "$DB" -X -q -f "$HARNESS_LIB/sql/storage-audit.sql" 2>/dev/null || true)"
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
