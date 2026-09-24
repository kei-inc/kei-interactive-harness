#!/usr/bin/env bash
# The ratchet.
#
# Play freely, but the codebase only travels one direction. Debt is counted
# rather than blocked, so exploration stays fast and backsliding cannot happen
# quietly.
#
#   ratchet.sh                  check against the baseline, tighten on improvement,
#                               FAIL on regression   (for /repair and CI on PRs)
#   ratchet.sh --soft           same, but never fails (for commit and push hooks)
#   ratchet.sh --check          report only, never writes, fails on regression (CI)
#   ratchet.sh --new [ref]      check only the lines this branch ADDED (no state)
#   ratchet.sh --accept         adopt current counts as the new baseline
#   ratchet.sh --show           print totals without judging them
#   ratchet.sh --goals          print progress toward the targets in goals.txt
#
# Two files, deliberately separated:
#   .harness/ratchet.txt   machine-written state, per metric per file
#   .harness/goals.txt     human-written targets, edited by you
#
# Debt may grow freely inside a branch. It must be paid or acknowledged before
# it reaches the default branch. That is the same rule the spike markers follow,
# and it is what lets exploration stay loose while the trunk only travels one
# direction. So the hooks run --soft (report, never block) and CI on a pull
# request runs the strict mode.
#
# Metrics prefixed with ~ are tracked, not enforced. They show in --show and
# --goals and are recorded in the baseline, but they never count as a slip,
# even in strict mode. Use this for things you want to watch rather than fight.
#
# Counts are kept per file rather than per repository. A whole-repo count lets
# you delete a violation in one file, add one in another, and pass. Per-file
# records close that hole and let the report name the file that got worse,
# which matters because a check that says "worse" without saying where trains
# you to reach for --accept.

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

BASELINE=".harness/ratchet.txt"
GOALS=".harness/goals.txt"
MODE="${1:-check}"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

SRC_GLOBS=(--include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx"
           --include="*.mjs" --include="*.cjs" --include="*.vue" --include="*.svelte"
           --include="*.py" --include="*.go" --include="*.rb")
EXCLUDES=(--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist
          --exclude-dir=build --exclude-dir=.git --exclude-dir=coverage
          --exclude-dir=.venv --exclude-dir=vendor --exclude-dir=.turbo
          --exclude-dir=.vercel)

# label|regex. Add the mistakes YOUR codebase makes. When /repair catches the
# same thing three times, it belongs here.
METRICS=(
  "any-types|: any\b|as any\b"
  "ts-suppressions|@ts-ignore|@ts-nocheck"
  "lint-suppressions|eslint-disable"
  "html-injection|dangerouslySetInnerHTML|\.innerHTML[[:space:]]*="
  "non-null-assertions|[a-zA-Z0-9_)\]]![.[]"
  # Stack specific. The public surface is the one that matters most.
  "public-endpoints|@public-route|@public-action"
  "service-role-uses|SERVICE_ROLE"
  "getsession-allowed|@allow-getsession"
  "unreviewed-caching|unstable_cache"
  # Tracked only. These are the texture of exploration, or architectural
  # interest, and blocking on them would fight the way this codebase is built.
  "~todo-markers|TODO|FIXME|HACK|XXX"
  "~spike-markers|SPIKE[:(]"
  "~console-logs|console\.(log|debug)\("
  "~client-components|['\"]use client['\"]"
)

# Project additions, from .harness/config.sh
if [ -n "${HARNESS_EXTRA_METRICS:-}" ]; then
  while IFS= read -r extra; do
    [ -n "$extra" ] && METRICS+=("$extra")
  done <<< "$HARNESS_EXTRA_METRICS"
fi

metric_labels() { for e in "${METRICS[@]}"; do echo "${e%%|*}"; done; }
is_tracked() { case "$1" in \~*) return 0 ;; *) return 1 ;; esac; }
bare() { printf '%s' "${1#\~}"; }
metric_pattern() {
  for e in "${METRICS[@]}"; do [ "${e%%|*}" = "$1" ] && { echo "${e#*|}"; return; }; done
}

# metric|file|count, one line each, sorted and deterministic so the file diffs
# cleanly and does not become a merge-conflict magnet.
scan() {
  for e in "${METRICS[@]}"; do
    local label="${e%%|*}" pattern="${e#*|}"
    grep -rnoE "$pattern" "${SRC_GLOBS[@]}" "${EXCLUDES[@]}" . 2>/dev/null \
      | cut -d: -f1 | sed 's|^\./||' | sort | uniq -c \
      | awk -v m="$label" '{print m"|"$2"|"$1}'
  done | sort
}

write_goals_if_absent() {
  [ -f "$GOALS" ] && return
  {
    echo "# Targets, edited by you. The baseline records where you are; this"
    echo "# records where you are going. A metric at its goal is finished."
    echo "# Set a goal to 0 for things that should disappear entirely."
    echo "# Lower a goal whenever the baseline drops below it."
    echo
    for label in $(metric_labels); do
      local total; total="$(awk -F'|' -v m="$label" '$1==m {s+=$3} END {print s+0}' <<< "$CURRENT")"
      printf '%s=%s\n' "$(bare "$label")" "$total"
    done
  } > "$GOALS"
}

# --------------------------------------------------------------- new mode ---
# The lesson from Semgrep's --baseline-commit and Sonar's clean-as-you-code:
# the strongest check needs no stored state at all. Look only at the lines this
# branch added. A violation you moved from one file to another is still new
# here, and there is nothing to accept your way past.

if [ "$MODE" = "--new" ]; then
  REF="${2:-}"
  if [ -z "$REF" ]; then
    REF="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||')"
    [ -z "$REF" ] && REF="origin/main"
  fi
  MB="$(git merge-base HEAD "$REF" 2>/dev/null || git rev-parse HEAD~1 2>/dev/null)"
  if [ -z "$MB" ]; then
    printf '%s\n' "${DIM}No merge base against $REF. Skipping new-code check.${RESET}"; exit 0
  fi

  ADDED="$(git diff -U0 "$MB"...HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' \
             '*.vue' '*.svelte' '*.py' '*.go' '*.rb' 2>/dev/null \
           | awk '/^\+\+\+ b\// { f=substr($0,7); next }
                  /^\+/ && !/^\+\+\+/ { print f"\t" substr($0,2) }')"

  if [ -z "$ADDED" ]; then
    printf '%s\n' "${GREEN}No source lines added against $REF.${RESET}"; exit 0
  fi

  printf '%s\n' "${BOLD}Lines added since $REF${RESET}"
  SLIP=0
  for label in $(metric_labels); do
    pattern="$(metric_pattern "$label")"
    hits="$(printf '%s\n' "$ADDED" | grep -E "$pattern" || true)"
    [ -z "$hits" ] && continue
    n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
    printf '%s\n' "${YELLOW}  $label introduced ($n)${RESET}"
    printf '%s\n' "$hits" | head -10 | sed 's/^/      /'
    SLIP=1
  done
  echo
  if [ "$SLIP" -eq 1 ]; then
    printf '%s\n' "${YELLOW}New debt in this branch. Fine on a spike, worth a look before merging.${RESET}"
    [ "${HARNESS_NEW_STRICT:-0}" = "1" ] && exit 1
  else
    printf '%s\n' "${GREEN}Nothing new introduced.${RESET}"
  fi
  exit 0
fi

# ------------------------------------------------------------- state modes ---

CURRENT="$(scan)"
mkdir -p .harness
write_goals_if_absent

total_for() { awk -F'|' -v m="$1" '$1==m {s+=$3} END {print s+0}' <<< "$CURRENT"; }

if [ "$MODE" = "--show" ]; then
  for label in $(metric_labels); do
    if is_tracked "$label"; then printf '%-22s %s  %s\n' "$(bare "$label")" "$(total_for "$label")" "${DIM}tracked${RESET}"
    else printf '%-22s %s\n' "$label" "$(total_for "$label")"; fi
  done
  exit 0
fi

if [ "$MODE" = "--goals" ]; then
  printf '%-22s %8s %8s   %s\n' "metric" "now" "goal" ""
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    now="$(total_for "$k")"; [ "$now" = 0 ] && now="$(total_for "~$k")"
    if   [ "$now" -le "$v" ]; then mark="${GREEN}at goal${RESET}"
    else mark="${YELLOW}$((now - v)) to go${RESET}"; fi
    printf '%-22s %8s %8s   %b\n' "$k" "$now" "$v" "$mark"
  done < "$GOALS"
  exit 0
fi

if [ ! -f "$BASELINE" ] && [ "$MODE" = "--check" ]; then
  printf '%s\n' "${DIM}No baseline yet. Run 'npx harness ratchet' once to record one.${RESET}"
  exit 0
fi
if [ ! -f "$BASELINE" ] || [ "$MODE" = "--accept" ]; then
  printf '%s\n' "$CURRENT" > "$BASELINE"
  printf '%s\n' "${GREEN}Baseline written: $(grep -c . "$BASELINE" 2>/dev/null || echo 0) file entries across $(metric_labels | wc -l | tr -d ' ') metrics.${RESET}"
  for label in $(metric_labels); do printf '  %-22s %s\n' "$(bare "$label")" "$(total_for "$label")"; done
  exit 0
fi

# Compare per file. Report what moved and where.
WORSE=0; IMPROVED=0; STALE=0

while IFS='|' read -r m f c; do
  [ -z "${m:-}" ] && continue
  base="$(awk -F'|' -v m="$m" -v f="$f" '$1==m && $2==f {print $3}' "$BASELINE")"
  base="${base:-0}"
  if [ "$c" -gt "$base" ]; then
    if is_tracked "$m"; then
      printf '%s\n' "${DIM}  up       $(bare "$m")  ${f}  $base -> $c  (tracked, not enforced)${RESET}"
      IMPROVED=1   # baseline still moves to the new count
    else
      printf '%s\n' "${RED}  worse    $m  ${f}  $base -> $c${RESET}"
      WORSE=1
    fi
  elif [ "$c" -lt "$base" ]; then
    printf '%s\n' "${GREEN}  better   $m  ${f}  $base -> $c${RESET}"
    IMPROVED=1
  fi
done <<< "$CURRENT"

# Entries for files that are gone or clean. Pruning these matters: the known
# failure of baseline files is that they rot into permanent amnesty, hiding the
# fact that a violation was fixed years ago. ESLint ships a prune command for
# exactly this reason. Here it happens automatically.
while IFS='|' read -r m f c; do
  [ -z "${m:-}" ] && continue
  # Exact field match, never a regex: Next.js paths carry [id] and (group).
  if ! awk -F'|' -v m="$m" -v f="$f" '$1==m && $2==f {found=1} END {exit !found}' <<< "$CURRENT"; then
    if [ -e "$f" ]; then
      printf '%s\n' "${GREEN}  cleared  $m  ${f}${RESET}"
    else
      printf '%s\n' "${DIM}  pruned   $m  ${f} (file gone)${RESET}"
    fi
    IMPROVED=1; STALE=1
  fi
done < "$BASELINE"

if [ "$WORSE" -eq 0 ] && [ "$IMPROVED" -eq 0 ]; then
  printf '%s\n' "${DIM}  no change across $(metric_labels | wc -l | tr -d ' ') metrics${RESET}"
fi

if [ "$WORSE" -eq 0 ] && [ "$IMPROVED" -eq 1 ]; then
  if [ "$MODE" = "--check" ]; then
    printf '%s\n' "${GREEN}Improved. Run 'npx harness ratchet' to tighten the baseline.${RESET}"
  else
    printf '%s\n' "$CURRENT" > "$BASELINE"
    printf '%s\n' "${GREEN}Ratchet tightened. $BASELINE updated.${RESET}"
  fi
fi

echo
if [ "$WORSE" -eq 1 ] && [ "$MODE" = "--soft" ]; then
  printf '%s\n' "${YELLOW}Debt grew on this branch. Fine while exploring; it must be fixed or${RESET}"
  printf '%s\n' "${YELLOW}accepted (npx harness ratchet --accept) before this reaches main.${RESET}"
  exit 0
fi
if [ "$WORSE" -eq 1 ]; then
  printf '%s\n' "${RED}Ratchet slipped.${RESET}"
  printf '%s\n' "${YELLOW}Fix the lines above, or run 'npx harness ratchet --accept' and say"
  printf '%s\n' "in the commit message why the debt was worth taking.${RESET}"
  exit 1
fi
printf '%s\n' "${GREEN}Ratchet holding.${RESET}"
exit 0
