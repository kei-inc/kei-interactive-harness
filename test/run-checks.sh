#!/usr/bin/env bash
# Proves the source-level checks find what they should and nothing else.
#
#   bash test/run-checks.sh
#
# Builds a throwaway git repo per case, runs the check against it, and compares
# the exit code (and, where it matters, the output) with what the case expects.
# Needs only bash, git and node. Leaves nothing behind.
#
# Add a case here whenever a check gains a pattern or loses a false positive.
# The cases are the specification of what each check means.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$HERE/../lib" && pwd)"
PASS=0; FAILN=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# new_repo <name> [branch]: a clean git repo to write files into.
new_repo() {
  local d="$TMPROOT/$1"; mkdir -p "$d"
  git -C "$d" init -q -b "${2:-play}"
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s' "$d"
}

# expect <name> <want-exit> <cmd...>  (run inside $REPO)
expect() {
  local name="$1" want="$2"; shift 2
  local out code
  out="$(cd "$REPO" && HARNESS_PROJECT_ROOT="$REPO" HARNESS_LIB="$LIB" "$@" 2>&1)"; code=$?
  if [ "$code" = "$want" ]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else FAILN=$((FAILN + 1)); printf '  FAIL  %s (exit %s, wanted %s)\n' "$name" "$code" "$want"; printf '%s\n' "$out" | sed 's/^/        /'; fi
  LAST_OUT="$out"
}

# expect_out <name> <grep -E pattern> : the last command's output matches
expect_out() {
  if printf '%s' "$LAST_OUT" | grep -qE "$2"; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"
  else FAILN=$((FAILN + 1)); printf '  FAIL  %s (output did not match /%s/)\n' "$1" "$2"; printf '%s\n' "$LAST_OUT" | sed 's/^/        /'; fi
}
expect_no_out() {
  if printf '%s' "$LAST_OUT" | grep -qE "$2"; then FAILN=$((FAILN + 1)); printf '  FAIL  %s (output matched /%s/)\n' "$1" "$2"; printf '%s\n' "$LAST_OUT" | sed 's/^/        /'
  else PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; fi
}

B="bash $LIB/scripts/check-boundaries.sh"
S="bash $LIB/scripts/spikes.sh"

echo "boundaries"

REPO="$(new_repo clean)"
printf 'export const x = 1\n' > "$REPO/a.ts"
expect "clean code passes" 0 $B

REPO="$(new_repo eval)"
printf 'export const run = (s: string) => eval(s)\n' > "$REPO/a.ts"
expect "eval in code blocks" 1 $B

REPO="$(new_repo eval-comment)"
printf '// never call eval( on user input\n/* eval(x) is how this breaks */\nexport const x = 1\n' > "$REPO/a.ts"
expect "eval in a comment does not block" 0 $B

REPO="$(new_repo sql)"
printf 'export const q = (id: string) => db.query(`select * from t where id = ${id}`)\n' > "$REPO/a.ts"
expect "interpolated SQL blocks" 1 $B

REPO="$(new_repo public-secret)"
printf 'const k = process.env.NEXT_PUBLIC_STRIPE_SECRET_KEY\n' > "$REPO/a.ts"
expect "secret behind NEXT_PUBLIC blocks" 1 $B

REPO="$(new_repo spike-play play)"
printf '// SPIKE(2026-01-01): fake data\nexport const x = 1\n' > "$REPO/a.ts"
expect "spike on play passes" 0 $B

REPO="$(new_repo spike-main main)"
printf '// SPIKE(2026-01-01): fake data\nexport const x = 1\n' > "$REPO/a.ts"
expect "spike on main blocks, even though it is a comment" 1 $B

echo "spikes"

REPO="$(new_repo spikes-none)"
printf 'export const x = 1\n' > "$REPO/a.ts"
expect "no markers passes --strict" 0 $S --strict

REPO="$(new_repo spikes-some)"
mkdir -p "$REPO/node_modules/dep"
printf '// SPIKE(2020-01-01): ancient\n' > "$REPO/old.ts"
printf '// SPIKE: undated\n' > "$REPO/undated.ts"
printf '// SPIKE(2020-01-01): not ours\n' > "$REPO/node_modules/dep/index.js"
expect "markers fail --strict" 1 $S --strict
expect_out "lists the dated marker" 'old\.ts:1'
expect_out "lists the undated marker first" 'undated.*undated\.ts:1'
expect_no_out "ignores node_modules" 'node_modules'
expect "plain listing never fails" 0 $S

echo
if [ "$FAILN" -eq 0 ]; then echo "all $PASS passed"; exit 0; fi
echo "$FAILN failed, $PASS passed"; exit 1
