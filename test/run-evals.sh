#!/usr/bin/env bash
# Tests the eval scorer, not the model: a fake agent writes a good and a bad
# answer to four cases, and the scorer must pass the first and fail the second.
# Spends no model usage.
#
#   bash test/run-evals.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="route-without-auth,new-table-rls,spike-marking,no-drive-by"
FAKE="node $HERE/evals/test/fake-agent.js"
FAILN=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
GOOD="$T/good.json"; BAD="$T/bad.json"
L="const load = (f) => JSON.parse(require('fs').readFileSync(f, 'utf8'));"

if node "$HERE/evals/run.js" --cmd "$FAKE good" --case "$CASES" --mode with --json > $GOOD 2>&1; then
  echo "  ok    good answers pass every check"
else
  echo "  FAIL  good answers should pass"; node -e "$L for (const r of load('$GOOD')) for (const c of r.checks) if (!c.ok) console.log('        ' + r.case + ': ' + c.says + ' ' + c.detail)"; FAILN=1
fi

node "$HERE/evals/run.js" --cmd "$FAKE bad" --case "$CASES" --mode with --json > $BAD 2>&1
if node -e "$L const rs = load('$BAD'); process.exit(rs.every((r) => r.passed < r.total) ? 0 : 1)"; then
  echo "  ok    every bad answer fails at least one check"
else
  echo "  FAIL  a bad answer passed"; node -e "$L for (const r of load('$BAD')) if (r.passed === r.total) console.log('        ' + r.case)"; FAILN=1
fi
node -e "$L
const rs = load('$BAD');
const missed = (name) => rs.find((r) => r.case === name).checks.filter((c) => !c.ok).map((c) => c.says);
const want = {
  'route-without-auth': ['establishes identity', 'bounds the list', 'does not take the user id from the request'],
  'new-table-rls': ['enables RLS', 'writes policies', 'grants it explicitly', 'nothing the harness would block'],
  'spike-marking': ['marks the stub with a dated SPIKE', 'writes no tests during a spike'],
  'no-drive-by': ['touches nothing else'],
};
let bad = 0;
for (const [c, says] of Object.entries(want)) for (const s of says) if (!missed(c).includes(s)) { console.log('  FAIL  ' + c + ' should miss: ' + s); bad = 1; }
if (!bad) console.log('  ok    each bad answer fails for the right reasons');
process.exit(bad);
" || FAILN=1
rm -rf "$HERE/evals/results"/*custom.json 2>/dev/null

echo
[ "$FAILN" -eq 0 ] && echo "all passed" && exit 0
echo "failed"; exit 1
