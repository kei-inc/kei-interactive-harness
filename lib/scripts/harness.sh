#!/usr/bin/env bash
# The single entry point for every check in this repo.
#
#   harness quick    fast, runs on pre-commit, a few seconds
#   harness check    fuller, runs on pre-push, under a minute
#   harness full     everything, runs in CI
#   harness ratchet  show debt counts against the baseline
#
# Everything here degrades gracefully. If a project does not have a given script
# or tool, the step is skipped with a note rather than failing, so the same
# harness works across projects with different stacks.

set -uo pipefail

# HARNESS_PROJECT_ROOT is the repo being checked. HARNESS_LIB is where this
# package's own assets live. Both are set by the harness CLI; the fallbacks let
# these scripts still run standalone from an ejected copy.
ROOT="${HARNESS_PROJECT_ROOT:-$(pwd)}"
HARNESS_LIB="${HARNESS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

FAILED=0
BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
YELLOW=$'\033[33m'; RESET=$'\033[0m'

say()  { printf '%s\n' "${BOLD}$1${RESET}"; }
skip() { printf '%s\n' "${DIM}  skipped: $1${RESET}"; }
ok()   { printf '%s\n' "${GREEN}  ok: $1${RESET}"; }
bad()  { printf '%s\n' "${RED}  failed: $1${RESET}"; FAILED=1; }
warn() { printf '%s\n' "${YELLOW}  warning: $1${RESET}"; }

# Detect the package manager once.
if   [ -f pnpm-lock.yaml ]; then PM=pnpm; RUN="pnpm run"
elif [ -f yarn.lock ];      then PM=yarn; RUN="yarn"
elif [ -f bun.lockb ];      then PM=bun;  RUN="bun run"
elif [ -f package-lock.json ]; then PM=npm; RUN="npm run"
else PM=none; RUN=""
fi

# True when package.json defines the named script.
has_script() {
  [ "$PM" = none ] && return 1
  [ -f package.json ] || return 1
  node -e "process.exit(require('./package.json').scripts?.['$1'] ? 0 : 1)" 2>/dev/null
}

# True when a binary is on PATH.
has_bin() { command -v "$1" >/dev/null 2>&1; }

# Run a package script if it exists, otherwise note the gap.
step() {
  local name="$1"
  if has_script "$name"; then
    if $RUN "$name"; then ok "$name"; else bad "$name"; fi
  else
    skip "no \"$name\" script in package.json"
  fi
}

# ---------------------------------------------------------------- quick -----

quick() {
  say "Boundary check"
  bash "$HARNESS_LIB/scripts/check-boundaries.sh" || bad "boundary check"

  say "Stack check (Next.js, Supabase, Cloudflare)"
  bash "$HARNESS_LIB/scripts/check-stack.sh" || bad "stack check"

  say "Secrets"
  if has_bin gitleaks; then
    if gitleaks git --staged --no-banner --redact --exit-code 1 . ; then ok "gitleaks"
    else bad "gitleaks found a secret in staged changes"; fi
  else
    skip "gitleaks not installed (brew install gitleaks)"
  fi

  # The ratchet runs at commit time in soft mode: it reports, it tightens the
  # baseline on improvement and stages that into this commit, and it never
  # blocks. Debt may grow inside a branch. CI enforces it on the pull request,
  # which is where it has to be paid or acknowledged before reaching main.
  say "Ratchet"
  bash "$HARNESS_LIB/scripts/ratchet.sh" --soft
  if ! git diff --quiet -- .harness/ratchet.txt 2>/dev/null; then
    git add .harness/ratchet.txt && ok "baseline tightened and staged"
  fi

  say "Format and lint on staged files"
  if has_script "lint:staged"; then step "lint:staged"
  elif has_bin npx && [ -f package.json ]; then
    npx --no-install lint-staged 2>/dev/null && ok "lint-staged" || skip "lint-staged not configured"
  else
    skip "no staged linter"
  fi
}

# ---------------------------------------------------------------- check -----

check() {
  quick
  say "Types"
  step typecheck
  say "Lint"
  step lint
  say "Unit tests"
  step "test:unit"

  # Soft here: trunk problems (edited or out-of-order migrations) are notes on
  # a branch and blocks on the pull request. A local database behind the files
  # is reported, or applied if HARNESS_MIGRATE_LOCAL=apply.
  if [ -d supabase/migrations ]; then
    say "Migrations"
    bash "$HARNESS_LIB/scripts/check-migrations.sh" || bad "migration files are broken"
  fi
}

# ----------------------------------------------------------------- full -----

full() {
  check

  say "Row level security"
  bash "$HARNESS_LIB/scripts/check-rls.sh" || bad "database exposes data"

  say "Supabase database lint"
  if has_bin supabase; then
    supabase db lint --level warning && ok "supabase db lint" || warn "supabase db lint findings"
  else
    skip "supabase CLI not installed"
  fi

  say "Build"
  step build

  say "Dependency vulnerabilities"
  if has_bin osv-scanner; then
    osv-scanner --lockfile=. --recursive . >/dev/null 2>&1 && ok "osv-scanner" || warn "osv-scanner reported findings"
  elif [ "$PM" = npm ] || [ "$PM" = pnpm ]; then
    $PM audit --audit-level=high && ok "audit" || warn "audit reported high or critical advisories"
  else
    skip "no vulnerability scanner available"
  fi

  say "Static analysis"
  bash "$HARNESS_LIB/scripts/semgrep.sh" || bad "semgrep findings introduced on this branch"

  say "Full secret history scan"
  if has_bin gitleaks; then
    gitleaks git --no-banner --redact --exit-code 1 . && ok "gitleaks history" || bad "secret found in history (accepted ones go in .gitleaksignore)"
  else
    skip "gitleaks not installed"
  fi

  say "Dead code"
  if has_script knip; then step knip
  elif has_bin npx; then npx --no-install knip 2>/dev/null && ok "knip" || skip "knip not configured"
  else skip "knip not available"; fi

  say "Bundle size"
  step "size"

  say "End to end tests"
  step "test:e2e"
}

# ------------------------------------------------------------------ main -----

case "${1:-check}" in
  quick)   say "Harness: quick"; quick ;;
  check)   say "Harness: check"; check ;;
  full)    say "Harness: full";  full ;;
  ratchet) bash "$HARNESS_LIB/scripts/ratchet.sh"; exit $? ;;
  rls)     bash "$HARNESS_LIB/scripts/check-rls.sh"; exit $? ;;
  stack)   bash "$HARNESS_LIB/scripts/check-stack.sh"; exit $? ;;
  *) echo "usage: harness [quick|check|full|ratchet|rls|stack]"; exit 2 ;;
esac

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%s\n' "${GREEN}${BOLD}Harness passed.${RESET}"
else
  printf '%s\n' "${RED}${BOLD}Harness failed. See above.${RESET}"
fi
exit "$FAILED"
