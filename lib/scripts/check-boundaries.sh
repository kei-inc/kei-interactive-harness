#!/usr/bin/env bash
# Project-shaped checks that generic linters cannot make.
#
# Design rule: only things in the HARD FAIL section stop the commit. Everything
# else is counted by the ratchet, so that exploration stays fast and debt still
# cannot grow. If this script ever produces a false positive that blocks work,
# move the pattern down to the ratchet rather than disabling the script.

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

SRC_GLOBS=(--include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx"
           --include="*.mjs" --include="*.cjs" --include="*.vue" --include="*.svelte"
           --include="*.py" --include="*.go" --include="*.rb")
EXCLUDES=(--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist
          --exclude-dir=build --exclude-dir=.git --exclude-dir=coverage
          --exclude-dir=.venv --exclude-dir=vendor --exclude-dir=.turbo)

fail_on() {
  local label="$1" pattern="$2"
  local hits
  hits="$(grep -rnE "$pattern" "${SRC_GLOBS[@]}" "${EXCLUDES[@]}" . 2>/dev/null)"
  if [ -n "$hits" ]; then
    printf '%s\n' "${RED}BLOCKED: $label${RESET}"
    printf '%s\n' "$hits" | sed 's/^/    /'
    FAIL=1
  fi
}

warn_on() {
  local label="$1" pattern="$2"
  local hits
  hits="$(grep -rnE "$pattern" "${SRC_GLOBS[@]}" "${EXCLUDES[@]}" . 2>/dev/null)"
  if [ -n "$hits" ]; then
    local n; n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
    printf '%s\n' "${YELLOW}note: $label ($n)${RESET}"
  fi
}

# ------------------------------------------------------- hard failures -----
# Kept deliberately short. Each one is something with no legitimate use.

# A secret hiding behind a client-exposed variable prefix. This is the single
# most common way an indie app leaks its keys. Intentional public values go in
# .harness/allow-public-env.txt, one name per line.
ALLOW=".harness/allow-public-env.txt"
PUBLIC_SECRETS="$(grep -rnE '(NEXT_PUBLIC|VITE|PUBLIC|EXPO_PUBLIC|REACT_APP)_[A-Z0-9_]*(SECRET|PRIVATE|SERVICE_ROLE|PASSWORD|_TOKEN|_KEY)' \
  "${SRC_GLOBS[@]}" "${EXCLUDES[@]}" . 2>/dev/null)"
if [ -f "$ALLOW" ]; then
  while IFS= read -r allowed; do
    [ -z "$allowed" ] && continue
    case "$allowed" in \#*) continue ;; esac
    PUBLIC_SECRETS="$(printf '%s\n' "$PUBLIC_SECRETS" | grep -v "$allowed" || true)"
  done < "$ALLOW"
fi
if [ -n "$PUBLIC_SECRETS" ]; then
  printf '%s\n' "${RED}BLOCKED: secret-looking value behind a client-exposed env prefix${RESET}"
  printf '%s\n' "$PUBLIC_SECRETS" | sed 's/^/    /'
  printf '%s\n' "    If this value really is public, add its name to $ALLOW"
  FAIL=1
fi

# Supabase's newer key format. A secret key literal in source is a leak whether
# or not a scanner has a rule for it yet.
fail_on "Supabase secret key literal in source" 'sb_secret_[A-Za-z0-9_-]{12,}'

fail_on "eval of a dynamic expression" '(^|[^a-zA-Z_.])eval\('
fail_on "new Function() with a string body" 'new[[:space:]]+Function\('
fail_on "child_process with interpolated input" 'exec(Sync)?\(`[^`]*\$\{'
fail_on "SQL built by template interpolation" '(query|execute|raw)\([[:space:]]*`[^`]*\$\{'

# A committed .env file. .env.example is fine and expected.
ENVFILES="$(git ls-files 2>/dev/null | grep -E '(^|/)\.env($|\.(local|production|development))' || true)"
if [ -n "$ENVFILES" ]; then
  printf '%s\n' "${RED}BLOCKED: environment file tracked by git${RESET}"
  printf '%s\n' "$ENVFILES" | sed 's/^/    /'
  FAIL=1
fi

# SPIKE markers are fine everywhere except the default branch.
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DEFAULT_BRANCH="${HARNESS_DEFAULT_BRANCH:-main}"
if [ "$BRANCH" = "$DEFAULT_BRANCH" ] || [ "${CI_TARGET_BRANCH:-}" = "$DEFAULT_BRANCH" ]; then
  fail_on "SPIKE marker on the default branch" 'SPIKE[:(]'
fi

# ------------------------------------------------------- spike expiry -----
# Spikes are meant to be temporary. Undated ones never are. Write
# SPIKE(2026-09-22): one line on what is unfinished, and this will start
# reminding you once it has been sitting for a month.

if ! disabled spike-expiry; then
SPIKE_MAX_DAYS="${HARNESS_SPIKE_MAX_DAYS:-30}"
today_s="$(date +%s)"
to_epoch() {
  date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || echo ""
}

UNDATED="$(grep -rnE 'SPIKE:' "${SRC_GLOBS[@]}" "${EXCLUDES[@]}" . 2>/dev/null || true)"
if [ -n "$UNDATED" ]; then
  n="$(printf '%s\n' "$UNDATED" | wc -l | tr -d ' ')"
  printf '%s\n' "${YELLOW}note: $n undated spike marker(s). Use SPIKE(YYYY-MM-DD): so they can expire.${RESET}"
fi

while IFS= read -r line; do
  [ -z "$line" ] && continue
  d="$(printf '%s' "$line" | sed -nE 's/.*SPIKE\(([0-9]{4}-[0-9]{2}-[0-9]{2})\).*/\1/p')"
  [ -z "$d" ] && continue
  ts="$(to_epoch "$d")"; [ -z "$ts" ] && continue
  age=$(( (today_s - ts) / 86400 ))
  if [ "$age" -gt "$SPIKE_MAX_DAYS" ]; then
    printf '%s\n' "${YELLOW}note: spike is ${age} days old${RESET}  ${line%%:*}"
    printf '%s\n' "${DIM}       Either it settled and the marker should go, or it is real debt.${RESET}"
  fi
done <<< "$(grep -rnE 'SPIKE\([0-9]{4}-[0-9]{2}-[0-9]{2}\)' "${SRC_GLOBS[@]}" "${EXCLUDES[@]}" . 2>/dev/null || true)"

fi

# --------------------------------------------------------------- notes -----
# Counted by the ratchet, never blocking.

warn_on "HTML injected without a visible sanitizer" 'dangerouslySetInnerHTML|\.innerHTML[[:space:]]*='
warn_on "type escape hatch" ': any\b|as any\b|@ts-ignore|@ts-nocheck'
warn_on "suppressed lint rule" 'eslint-disable'
warn_on "unfinished work" 'TODO|FIXME|HACK|XXX'
HTTP_HITS="$(grep -rnE 'http://' "${SRC_GLOBS[@]}" "${EXCLUDES[@]}" . 2>/dev/null | grep -vE 'localhost|127\.0\.0\.1|0\.0\.0\.0|schema|xmlns|www\.w3\.org' || true)"
if [ -n "$HTTP_HITS" ]; then
  printf '%s\n' "${YELLOW}note: plaintext http endpoint ($(printf '%s\n' "$HTTP_HITS" | wc -l | tr -d ' '))${RESET}"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '%s\n' "${GREEN}Boundaries clear.${RESET}"
else
  printf '%s\n' "${RED}Boundary check failed.${RESET}"
fi
exit "$FAIL"
