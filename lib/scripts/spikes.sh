#!/usr/bin/env bash
# The spike inventory, in one place.
#
#   spikes.sh            every SPIKE marker, oldest first, with its age in days
#   spikes.sh --strict   same, and exit 1 if there are any (what the pull
#                        request into the default branch enforces)
#
# /status, /ship, /repair and /debt all need this list. Before this script each
# carried its own grep, and the copies had drifted: one searched node_modules,
# another missed .mjs. One implementation means one answer.

set -uo pipefail
ROOT="${HARNESS_PROJECT_ROOT:-$(pwd)}"
HARNESS_LIB="${HARNESS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

[ -f "$ROOT/.harness/config.sh" ] && . "$ROOT/.harness/config.sh"

YELLOW=$'\033[33m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
MODE="${1:-list}"
MAX_DAYS="${HARNESS_SPIKE_MAX_DAYS:-30}"

SRC_GLOBS=(--include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx"
           --include="*.mjs" --include="*.cjs" --include="*.vue" --include="*.svelte"
           --include="*.py" --include="*.go" --include="*.rb")
EXCLUDES=(--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist
          --exclude-dir=build --exclude-dir=.git --exclude-dir=coverage
          --exclude-dir=.venv --exclude-dir=vendor --exclude-dir=.turbo
          --exclude-dir=.vercel)

to_epoch() {
  date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || echo ""
}

HITS="$(grep -rnE 'SPIKE[:(]' "${SRC_GLOBS[@]}" "${EXCLUDES[@]}" . 2>/dev/null | sed 's|^\./||' || true)"

if [ -z "$HITS" ]; then
  printf '%s\n' "${GREEN}No spike markers.${RESET}"
  exit 0
fi

today="$(date +%s)"
# Build "age<TAB>location<TAB>note" rows; undated sort first as the oldest.
ROWS="$(while IFS= read -r line; do
  [ -z "$line" ] && continue
  file="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"; text="${rest#*:}"
  d="$(printf '%s' "$text" | sed -nE 's/.*SPIKE\(([0-9]{4}-[0-9]{2}-[0-9]{2})\).*/\1/p')"
  note="$(printf '%s' "$text" | sed -E 's/.*SPIKE(\([^)]*\))?:[[:space:]]*//')"
  if [ -n "$d" ] && ts="$(to_epoch "$d")" && [ -n "$ts" ]; then
    age=$(( (today - ts) / 86400 ))
  else
    age=99999
  fi
  printf '%s\t%s\t%s\n' "$age" "$file:$lineno" "$note"
done <<< "$HITS" | sort -t$'\t' -k1,1nr)"

n=0
while IFS=$'\t' read -r age loc note; do
  [ -z "$loc" ] && continue
  n=$((n + 1))
  if [ "$age" = 99999 ]; then
    printf '%s\n' "${YELLOW}  undated${RESET}  $loc  ${DIM}$note${RESET}"
  elif [ "$age" -gt "$MAX_DAYS" ]; then
    printf '%s\n' "${YELLOW}  ${age}d${RESET}  $loc  ${DIM}$note${RESET}"
  else
    printf '%s\n' "  ${age}d  $loc  ${DIM}$note${RESET}"
  fi
done <<< "$ROWS"

printf '\n%s\n' "$n spike marker(s). They are free on a branch and block the pull request into the default branch."
[ "$MODE" = "--strict" ] && exit 1
exit 0
