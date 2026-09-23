#!/usr/bin/env bash
# Print today's Data API grants as a migration, ready to review and commit.
#
#   SUPABASE_DB_URL=... npx harness grants > supabase/migrations/$(date +%Y%m%d%H%M%S)_explicit_grants.sql
#
# This reproduces effective access exactly, including anything too broad.
# Review before committing: narrow what should not be there, delete lines for
# tables that should never be on the Data API. Lines marked REVIEW deserve a
# second look.

set -uo pipefail
ROOT="${HARNESS_PROJECT_ROOT:-$(pwd)}"
HARNESS_LIB="${HARNESS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -f "$ROOT/.harness/config.sh" ] && . "$ROOT/.harness/config.sh"

. "$HARNESS_LIB/scripts/_db.sh"

# Grants should normally be captured from PRODUCTION, since that is the state
# rebuilt environments need to match. So unlike rls, this says loudly when it
# fell back to a local stack.
if ! resolve_db; then no_db_help grants >&2; exit 1; fi
if [ "$DB_SOURCE" != "SUPABASE_DB_URL" ]; then
  echo "note: capturing grants from ${DB_SOURCE}, not production." >&2
  echo "      For the cutover migration, use SUPABASE_DB_URL=<production URL>." >&2
fi

BODY="$(run_sql "$HARNESS_LIB/sql/grants-snapshot.sql")"; rc=$?
if [ "$rc" -eq 127 ]; then no_client_help >&2; exit 1; fi
[ "$rc" -eq 0 ] || { echo "Query failed (exit $rc)." >&2; exit 1; }

cat <<HDR
-- Explicit Data API grants, captured from ${DB_SOURCE} on $(date +%Y-%m-%d)
-- by kei-interactive-harness (npx harness grants).
--
-- Before Supabase's grants change these were added by the platform, so no
-- earlier migration contains them. With this migration, environments rebuilt
-- from migrations (db reset, branching, new deploys) match production.
--
-- This reproduces today's access exactly. Before committing:
--   * delete lines for tables that should never be reachable from the browser
--   * narrow anon to what the logged-out experience genuinely needs
--   * look hard at every line marked REVIEW
-- From here on, every migration that creates a table carries its own grants.

HDR
if [ -n "$BODY" ]; then printf '%s\n' "$BODY"; else echo "-- (no grants to anon, authenticated or service_role found)"; fi
