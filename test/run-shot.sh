#!/usr/bin/env bash
# Proves `harness shot` renders, measures and compares. Needs Playwright with
# Chromium installed somewhere Node can find it; skips cleanly otherwise.
#
#   bash test/run-shot.sh
#   PLAYWRIGHT_BROWSERS_PATH=... bash test/run-shot.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/../bin" && pwd)/harness.js"
TMP="$(mktemp -d)"; PORT=$((20000 + RANDOM % 20000))
cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

PW="$(node -e "for (const n of ['playwright','@playwright/test']) { try { console.log(require('path').dirname(require.resolve(n + '/package.json'))); process.exit(0) } catch {} }" 2>/dev/null)"
[ -z "$PW" ] && PW="$(npm root -g 2>/dev/null)/playwright"
if [ ! -d "$PW" ]; then echo "skipped: Playwright not installed (npm i -g playwright && npx playwright install chromium)"; exit 0; fi

mkdir -p "$TMP/proj/node_modules" "$TMP/site"
ln -s "$PW" "$TMP/proj/node_modules/playwright"
[ -d "$(dirname "$PW")/playwright-core" ] && ln -s "$(dirname "$PW")/playwright-core" "$TMP/proj/node_modules/playwright-core"

page() { cat <<HTML
<!doctype html><html><body style="margin:0;font-family:sans-serif">
<header class="bar" style="padding:$1 32px;background:#1d2b53;color:#fff">Title</header>
<main style="padding:32px;display:flex;gap:$2"><div class="card" style="padding:16px;border-radius:12px;background:#eee;width:200px">One</div><div class="card" style="padding:16px;border-radius:12px;background:#eee;width:200px">Two</div></main>
</body></html>
HTML
}
page 24px 16px > "$TMP/site/index.html"
page 20px 24px > "$TMP/site/ref.html"
node -e "require('http').createServer((q,r)=>{r.end(require('fs').readFileSync('$TMP/site'+(q.url==='/'?'/index.html':q.url)))}).listen($PORT)" & SRV=$!
sleep 0.5

cd "$TMP/proj"
PASS=0; FAILN=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAILN=$((FAILN + 1)); printf '  FAIL  %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/        /'; }
has()  { printf '%s' "$OUT" | node -e "const j=JSON.parse(require('fs').readFileSync(0,'utf8')); process.exit(($1)?0:1)"; }

OUT="$(node "$BIN" shot "http://localhost:$PORT/ref.html" --width 600 --height 240 --scale 2 --out ref.png 2>&1)"
if [ ! -f ref.png ]; then
  if printf '%s' "$OUT" | grep -q 'Could not start Chromium'; then echo "skipped: Chromium not installed (npx playwright install chromium)"; exit 0; fi
  fail "reference renders" "$OUT"; exit 1
fi
ok "reference renders at 2x"

OUT="$(node "$BIN" shot "http://localhost:$PORT/" --width 600 --height 240 --reference ref.png --styles "main, .card" 2>&1)"
has 'j.scale===2' && ok "scale is inferred from the reference" || fail "scale inferred" "$OUT"
has 'j.sizes.reference===j.sizes.render' && ok "render matches the reference size" || fail "sizes match" "$OUT"
has 'parseFloat(j.mismatch)>0' && ok "the spacing change is seen as a mismatch" || fail "mismatch seen" "$OUT"
has 'j.hotBands.length>0' && ok "and located by height" || fail "hot bands" "$OUT"
has 'j.styles[0].styles.gap==="16px"' && ok "computed gap is measured" || fail "gap measured" "$OUT"
has 'j.styles[1].styles["border-top-left-radius"]==="12px"' && ok "computed radius is measured" || fail "radius measured" "$OUT"
has '!("opacity" in j.styles[1].styles)' && ok "defaults are left out" || fail "defaults left out" "$OUT"
[ -f .harness/shots/*-compare.png ] && ok "a side-by-side comparison is written" || fail "compare image" "$(ls -R .harness)"

OUT="$(node "$BIN" shot "http://localhost:$PORT/ref.html" --width 600 --height 240 --reference ref.png 2>&1)"
has 'parseFloat(j.mismatch)===0' && ok "identical pages do not mismatch" || fail "identical" "$OUT"

echo
if [ "$FAILN" -eq 0 ]; then echo "all $PASS passed"; exit 0; fi
echo "$FAILN failed, $PASS passed"; exit 1
