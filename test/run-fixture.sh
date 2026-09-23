#!/usr/bin/env bash
# Prove the audit still finds exactly what it should, after any change to
# lib/sql/rls-audit.sql. Runs in a throwaway Docker container; needs only
# Docker Desktop running. Leaves nothing behind.
#
#   bash test/run-fixture.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="harness-fixture-$$"
PORT="${FIXTURE_PORT:-54399}"
EXPECT_ERRORS=10
EXPECT_WARNS=4

docker info >/dev/null 2>&1 || { echo "Docker is not running. Start Docker Desktop and retry."; exit 1; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Starting a throwaway Postgres..."
docker run -d --name "$NAME" -p "127.0.0.1:${PORT}:5432" \
  -e POSTGRES_PASSWORD=postgres postgres:16-alpine >/dev/null || exit 1

for _ in $(seq 1 30); do
  docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

echo "Loading test/rls-fixture.sql..."
docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q < "$HERE/test/rls-fixture.sql" || exit 1

echo "Running the audit..."
OUT="$(SUPABASE_DB_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" \
       HARNESS_SUPABASE=on HARNESS_PROJECT_ROOT="$HERE/test" HARNESS_LIB="$HERE/lib" \
       bash "$HERE/lib/scripts/check-rls.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
printf '%s\n' "$OUT"

errors="$(printf '%s\n' "$OUT" | grep -c '^  ERROR')"
warns="$(printf '%s\n' "$OUT" | grep -c '^  warn')"
echo
if [ "$errors" -eq "$EXPECT_ERRORS" ] && [ "$warns" -eq "$EXPECT_WARNS" ]; then
  echo "PASS: $errors errors, $warns warnings, as expected."
else
  echo "FAIL: got $errors errors and $warns warnings; expected $EXPECT_ERRORS and $EXPECT_WARNS."
  echo "Compare against the expected list at the bottom of test/rls-fixture.sql."
  exit 1
fi
