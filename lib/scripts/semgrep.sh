#!/usr/bin/env bash
# Static analysis, gated the way the rest of the harness is: on what a change
# introduces, not on the history it inherits.
#
#   semgrep.sh               local: findings new since the default branch
#   semgrep.sh --pr <ref>    CI on a pull request: new findings since <ref> fail
#   semgrep.sh --push        CI on the default branch: ERROR-severity findings fail
#   semgrep.sh --sweep       nightly: everything, all severities, written to
#                            semgrep-nightly.json, never fails
#
# Gating: ERROR and WARNING findings block when new; INFO never blocks. On an
# existing codebase that means day one is quiet, and every PR is held to the
# standard from then on. The nightly sweep keeps the full picture visible.
#
# Rules run from .harness/semgrep.yml (written by sync) so rule IDs are stable
# and short: harness.<rule>. Silence one per project in .harness/config.sh:
#   HARNESS_SEMGREP_EXCLUDE="missing-timeout-on-outbound-fetch"

set -uo pipefail
ROOT="${HARNESS_PROJECT_ROOT:-$(pwd)}"
HARNESS_LIB="${HARNESS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"
[ -f "$ROOT/.harness/config.sh" ] && . "$ROOT/.harness/config.sh"
RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'

MODE="${1:-local}"; REF="${2:-}"
IN_CI="${CI:-}"

if ! command -v semgrep >/dev/null 2>&1; then
  if [ -n "$IN_CI" ]; then echo "${RED}semgrep is not installed in CI. The workflow should install it.${RESET}"; exit 1; fi
  echo "${DIM}skipped: semgrep not installed (pipx install semgrep)${RESET}"; exit 0
fi

CFG=".harness/semgrep.yml"
[ -f "$CFG" ] || CFG="$HARNESS_LIB/semgrep.yml"
ARGS=(--config "$CFG" --metrics off --quiet)
# Registry rulesets need semgrep.dev. HARNESS_SEMGREP_REGISTRY=off runs the
# harness rules alone, for offline use.
if [ "${HARNESS_SEMGREP_REGISTRY:-on}" != "off" ]; then
  ARGS+=(--config p/secrets --config p/owasp-top-ten)
fi
for rule in ${HARNESS_SEMGREP_EXCLUDE:-}; do
  case "$rule" in *.*) ARGS+=(--exclude-rule "$rule") ;; *) ARGS+=(--exclude-rule "harness.$rule") ;; esac
done

case "$MODE" in
  --sweep)
    semgrep "${ARGS[@]}" --json --output semgrep-nightly.json . ; rc=$?
    [ "$rc" -le 1 ] && echo "${GREEN}Sweep written to semgrep-nightly.json${RESET}" && exit 0
    echo "${YELLOW}semgrep could not complete the sweep (exit $rc).${RESET}"; exit 0 ;;
  --push)
    ARGS+=(--severity ERROR) ;;
  --pr|local)
    if [ "$MODE" = local ] && [ -z "$REF" ]; then
      REF="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||')"
      [ -z "$REF" ] && git rev-parse --verify --quiet origin/main >/dev/null && REF=origin/main
    fi
    if [ -n "$REF" ] && MB="$(git merge-base HEAD "$REF" 2>/dev/null)"; then
      ARGS+=(--severity ERROR --severity WARNING --baseline-commit "$MB")
      echo "${DIM}new findings since $REF only${RESET}"
    else
      ARGS+=(--severity ERROR)   # no baseline to compare against
      echo "${DIM}no base branch found; gating on ERROR severity only${RESET}"
    fi ;;
esac

semgrep "${ARGS[@]}" --error .; rc=$?
# semgrep exits 1 for findings and 2+ when it could not run. "Could not run" is
# never allowed to look like a pass in CI: silence from a broken check means
# nothing. Locally it is a warning, with the most common cause named.
case "$rc" in
  0) echo "${GREEN}semgrep: nothing new${RESET}"; exit 0 ;;
  1) echo "${RED}semgrep: findings above${RESET}"; exit 1 ;;
  *) if [ -n "$IN_CI" ]; then echo "${RED}semgrep could not run (exit $rc).${RESET}"; exit 1; fi
     echo "${YELLOW}semgrep could not run (exit $rc). In a sandboxed shell this is usually a"
     echo "non-writable HOME; run it from a normal terminal, or set HOME to a writable dir"
     echo "(and restore it before git push or gh, which need the real HOME).${RESET}"; exit 0 ;;
esac
