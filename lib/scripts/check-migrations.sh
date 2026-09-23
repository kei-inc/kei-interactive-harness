#!/usr/bin/env bash
# Migration hygiene for Supabase projects.
#
#   check-migrations.sh            soft: report, never block   (pre-push)
#   check-migrations.sh --strict   block on trunk problems      (CI, pull requests)
#   check-migrations.sh --strict <base-ref>
#
# This never applies a migration to a real database. Supabase's GitHub
# integration does that at merge, and should keep doing it. The one exception is
# opt-in, local only: HARNESS_MIGRATE_LOCAL=apply runs `supabase migration up`
# against the local stack when it is behind.
#
# Checks:
#   file level (always)       malformed names, duplicate versions
#   against the base branch   edited or deleted migrations that already merged,
#                             new migrations older than the newest merged one
#   against the LOCAL db      pending migrations, and applied ones with no file

set -uo pipefail
ROOT="${HARNESS_PROJECT_ROOT:-$(pwd)}"
HARNESS_LIB="${HARNESS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"
[ -f "$ROOT/.harness/config.sh" ] && . "$ROOT/.harness/config.sh"

RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'
STRICT=0; BASE=""
[ "${1:-}" = "--strict" ] && { STRICT=1; BASE="${2:-}"; }
FAIL=0

# Trunk problems block in strict mode and are notes otherwise.
trunk() {
  if [ "$STRICT" -eq 1 ]; then printf '%s\n' "${RED}BLOCKED: $1${RESET}"; FAIL=1
  else printf '%s\n' "${YELLOW}note: $1${RESET}"; fi
}
always_block() { printf '%s\n' "${RED}BLOCKED: $1${RESET}"; FAIL=1; }
note() { printf '%s\n' "${YELLOW}note: $1${RESET}"; }
hint() { printf '%s\n' "${DIM}       $1${RESET}"; }

DIR="supabase/migrations"
[ -d "$DIR" ] || exit 0

version_of() { basename "$1" | sed -nE 's/^([0-9]+)_.*\.sql$/\1/p'; }

# ------------------------------------------------------------- file level ---
FILES="$(ls "$DIR"/*.sql 2>/dev/null | sort)"
for f in $FILES; do
  [ -n "$(version_of "$f")" ] || {
    always_block "migration file name has no version prefix: $f"
    hint "Create migrations with: supabase migration new <name>"
  }
done
DUPES="$(for f in $FILES; do version_of "$f"; done | sort | uniq -d)"
for v in $DUPES; do
  always_block "two migrations share version $v"
  hint "$(ls "$DIR"/${v}_*.sql | tr '\n' ' ')"
  hint "Rename one with a new timestamp. Supabase will refuse to apply both."
done

# ---------------------------------------------------- against the base branch ---
if [ -z "$BASE" ]; then
  BASE="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||')"
  [ -z "$BASE" ] && git rev-parse --verify --quiet origin/main >/dev/null && BASE="origin/main"
fi
MB="$( [ -n "$BASE" ] && git merge-base HEAD "$BASE" 2>/dev/null || true)"

if [ -n "$MB" ]; then
  # Edited or deleted after merging: production will never see the change.
  while IFS=$'\t' read -r status path; do
    [ -z "${status:-}" ] && continue
    case "$status" in
      M*) trunk "edits a migration that is already merged: $path"
          hint "Applied migrations are never re-run, so production keeps the old version"
          hint "while fresh environments get the new one. Put the change in a new migration." ;;
      D*) trunk "deletes a migration that is already merged: $path"
          hint "Its effects stay in production. Undo them with a new migration instead." ;;
    esac
  done <<< "$(git diff --name-status "$MB" HEAD -- "$DIR" 2>/dev/null)"

  # New migrations must sort after everything already merged.
  NEWEST_MERGED="$(git ls-tree --name-only "$MB" "$DIR/" 2>/dev/null | while read -r f; do version_of "$f"; done | sort -n | tail -1)"
  if [ -n "$NEWEST_MERGED" ]; then
    for f in $(git diff --name-only --diff-filter=A "$MB" HEAD -- "$DIR" 2>/dev/null); do
      v="$(version_of "$f")"; [ -z "$v" ] && continue
      if [ "$v" -le "$NEWEST_MERGED" ]; then
        trunk "migration $f is older than the newest merged one ($NEWEST_MERGED)"
        hint "Supabase refuses out-of-order migrations at deploy. Rename it with a"
        hint "fresh timestamp: supabase migration new <name>, then move the SQL across."
      fi
    done
  fi
fi

# --------------------------------------------------------- against the local db ---
# Local only. A database from SUPABASE_DB_URL is never compared or touched here.
if [ -z "${SUPABASE_DB_URL:-}" ]; then
  . "$HARNESS_LIB/scripts/_db.sh"
  if resolve_db; then
    OUT="$(run_sql "$HARNESS_LIB/sql/migrations-applied.sql" 2>/dev/null)"
    if printf '%s\n' "$OUT" | grep -q '^MARKER|harness|migrations-complete|'; then
      APPLIED="$(printf '%s\n' "$OUT" | grep -E '^[0-9]+$' | sort)"
      ONDISK="$(for f in $FILES; do version_of "$f"; done | grep . | sort)"
      PENDING="$(comm -13 <(printf '%s\n' "$APPLIED") <(printf '%s\n' "$ONDISK") | grep . || true)"
      ORPHANS="$(comm -23 <(printf '%s\n' "$APPLIED") <(printf '%s\n' "$ONDISK") | grep . || true)"

      if [ -n "$PENDING" ]; then
        n="$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')"
        if [ "${HARNESS_MIGRATE_LOCAL:-report}" = "apply" ] && command -v supabase >/dev/null 2>&1; then
          printf '%s\n' "${DIM}Local database is $n migration(s) behind. Applying (HARNESS_MIGRATE_LOCAL=apply)...${RESET}"
          if supabase migration up --local >/dev/null 2>&1; then
            printf '%s\n' "${GREEN}  applied $n local migration(s)${RESET}"
          else
            note "supabase migration up failed. Run it by hand to see why."
          fi
        else
          note "local database is $n migration(s) behind your files"
          printf '%s\n' "$PENDING" | sed "s/^/${DIM}       pending: /; s/$/${RESET}/"
          hint "Apply with: supabase migration up   (or set HARNESS_MIGRATE_LOCAL=apply)"
        fi
      fi
      if [ -n "$ORPHANS" ]; then
        note "local database has migrations with no file on this branch"
        printf '%s\n' "$ORPHANS" | sed "s/^/${DIM}       applied, no file: /; s/$/${RESET}/"
        hint "Usually leftovers from another branch. Realign with: supabase db reset"
      fi
    fi
  fi
fi

[ "$FAIL" -eq 0 ] && printf '%s\n' "${GREEN}Migrations in order.${RESET}"
exit "$FAIL"
