# Shared database access for check-rls.sh and grants.sh. Sourced, not run.
#
# Finds the database, in this order:
#   1. SUPABASE_DB_URL, if set. Always wins, so CI and production audits are
#      explicit.
#   2. The local Supabase CLI stack (supabase start, running on Docker), via
#      `supabase status`.
#   3. The Supabase database container, found directly through Docker. Covers
#      a CLI stack when the CLI is not on PATH, and self-hosted docker compose.
#
# Runs SQL with, in this order:
#   1. psql on the host, if installed.
#   2. psql inside the local Supabase container (docker exec). Nothing to
#      install; the container already has it.
#   3. A throwaway postgres container (docker run), for a remote URL with no
#      host psql. Pulls a small image the first time.
#
# Sets DB, DB_CONTAINER, DB_SOURCE. Call resolve_db, then run_sql FILE.

DB="${SUPABASE_DB_URL:-}"
DB_CONTAINER=""
DB_SOURCE=""

have() { command -v "$1" >/dev/null 2>&1; }

docker_up() { have docker && docker info >/dev/null 2>&1; }

# The CLI names its database container supabase_db_<project_id>; self-hosted
# docker compose names it supabase-db. Prefer this project's CLI container.
find_db_container() {
  docker_up || return 1
  local project_id="" names
  if [ -f "$ROOT/supabase/config.toml" ]; then
    project_id="$(sed -nE 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$ROOT/supabase/config.toml" | head -1)"
  fi
  names="$(docker ps --format '{{.Names}}' 2>/dev/null)"
  if [ -n "$project_id" ] && printf '%s\n' "$names" | grep -qx "supabase_db_${project_id}"; then
    echo "supabase_db_${project_id}"; return 0
  fi
  printf '%s\n' "$names" | grep -E '^supabase_db_|^supabase-db$' | head -1 | grep . && return 0
  return 1
}

resolve_db() {
  if [ -n "$DB" ]; then
    DB_SOURCE="SUPABASE_DB_URL"
    return 0
  fi
  # Local CLI stack. `status -o env` prints DB_URL="postgresql://..."
  if have supabase && [ -d "$ROOT/supabase" ]; then
    local url
    url="$(cd "$ROOT" && supabase status -o env 2>/dev/null | sed -nE 's/^DB_URL="?([^"]*)"?$/\1/p' | head -1)"
    if [ -n "$url" ]; then
      DB="$url"; DB_SOURCE="local Supabase stack (supabase status)"
      DB_CONTAINER="$(find_db_container || true)"
      return 0
    fi
  fi
  # Container found directly.
  DB_CONTAINER="$(find_db_container || true)"
  if [ -n "$DB_CONTAINER" ]; then
    DB_SOURCE="local container $DB_CONTAINER"
    return 0
  fi
  return 1
}

# Localhost inside a throwaway container is the container itself; the Mac is
# host.docker.internal.
host_reachable_url() {
  printf '%s' "$1" | sed -E 's#@(127\.0\.0\.1|localhost)([:/])#@host.docker.internal\2#'
}

run_sql() {
  local file="$1"
  if have psql && [ -n "$DB" ]; then
    psql "$DB" -X -q -f "$file"
  elif [ -n "$DB_CONTAINER" ] && { [ -z "$DB" ] || [ "$DB_SOURCE" != "SUPABASE_DB_URL" ]; }; then
    # Local stack: use the container's own psql over its local socket.
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q < "$file"
  elif [ -n "$DB" ] && docker_up; then
    docker run --rm -i --add-host=host.docker.internal:host-gateway postgres:16-alpine \
      psql "$(host_reachable_url "$DB")" -X -q < "$file"
  else
    return 127
  fi
}

no_db_help() {
  cat <<HELP
No database found. Any one of these works:
  - start the local stack:        supabase start   (Docker Desktop must be running)
  - or point at a database:       SUPABASE_DB_URL="postgresql://..." npx harness ${1:-rls}
HELP
}

no_client_help() {
  cat <<HELP
Found a database but nothing to run SQL with. Either:
  - start Docker Desktop (the harness will use psql inside a container), or
  - install psql:  brew install libpq && brew link --force libpq
HELP
}
