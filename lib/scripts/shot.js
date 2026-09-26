#!/usr/bin/env node
/**
 * harness shot: render a page the way a design reference was drawn, and
 * measure it.
 *
 *   harness shot <url> [options]
 *
 *   --width N          viewport width in CSS px, the Figma frame's width (1440)
 *   --height N         viewport height (900)
 *   --full             capture the whole page, not just the viewport
 *   --selector CSS     capture one element instead of the page
 *   --hover CSS        hover this element first      (states the frame shows)
 *   --focus CSS        focus this element first
 *   --scheme S         light | dark
 *   --wait-for CSS     wait for this to appear before capturing
 *   --reference PNG    compare against this image: writes a side-by-side with
 *                      a difference layer, prints the mismatch and where it is
 *   --scale N          device pixel ratio. With --reference it is inferred from
 *                      the reference's width (a 2x Figma export gives 2)
 *   --styles CSS       print computed styles of matching elements as JSON:
 *                      type, spacing, colour, radius, size. The numbers to
 *                      check against the design, rather than eyeballing pixels
 *   --out PATH         where to write the capture (.harness/shots/<name>.png)
 *   --name NAME        file name stem for the outputs
 *
 * Uses the project's own Playwright (playwright or @playwright/test), so the
 * harness adds no dependency. /match asks before adding it.
 */

'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = process.env.HARNESS_PROJECT_ROOT || process.cwd();

function parseArgs(argv) {
  const o = { width: 1440, height: 900 };
  const flags = new Set(['full']);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) { o.url = o.url || a; continue; }
    const k = a.slice(2).replace(/-([a-z])/g, (_, ch) => ch.toUpperCase());
    if (flags.has(k)) o[k] = true;
    else o[k] = argv[++i];
  }
  for (const k of ['width', 'height', 'scale']) if (o[k] !== undefined) o[k] = Number(o[k]);
  return o;
}

function loadPlaywright() {
  for (const name of ['playwright', '@playwright/test', 'playwright-core']) {
    try { return require(require.resolve(name, { paths: [ROOT] })); } catch {}
  }
  return null;
}

/** PNG width and height from the IHDR chunk, without decoding the image. */
function pngSize(file) {
  const b = fs.readFileSync(file);
  if (b.readUInt32BE(12) !== 0x49484452) throw new Error(`${file} is not a PNG`);
  return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
}

const slug = (s) => s.replace(/^https?:\/\//, '').replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60) || 'page';

// Properties worth comparing with a design, grouped the way /match checks them.
const STYLE_PROPS = [
  'font-family', 'font-size', 'font-weight', 'line-height', 'letter-spacing', 'text-transform', 'text-align',
  'color', 'background-color', 'opacity',
  'padding-top', 'padding-right', 'padding-bottom', 'padding-left',
  'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
  'gap', 'row-gap', 'column-gap', 'display', 'flex-direction', 'align-items', 'justify-content',
  'border-top-width', 'border-top-color', 'border-top-style',
  'border-top-left-radius', 'border-top-right-radius', 'border-bottom-right-radius', 'border-bottom-left-radius',
  'box-shadow', 'white-space', 'text-overflow', 'overflow',
];

async function main() {
  const o = parseArgs(process.argv.slice(2));
  if (!o.url) {
    console.error('usage: harness shot <url> [--width N] [--reference ref.png] [--styles CSS] ... (see harness shot --help)');
    process.exit(2);
  }
  const pw = loadPlaywright();
  if (!pw) {
    console.error('Playwright is not installed in this project. It is a dev dependency, so ask first, then:');
    console.error('  npm i -D playwright && npx playwright install chromium');
    process.exit(3);
  }

  const name = o.name || `${slug(o.url)}-${o.width}${o.scheme === 'dark' ? '-dark' : ''}`;
  const dir = path.join(ROOT, '.harness', 'shots');
  fs.mkdirSync(dir, { recursive: true });
  const out = o.out ? path.resolve(ROOT, o.out) : path.join(dir, `${name}.png`);

  let ref = null;
  if (o.reference) {
    const refPath = path.resolve(ROOT, o.reference);
    ref = { path: refPath, ...pngSize(refPath) };
  }
  // A 2x Figma export of a 1440 frame is 2880 wide: render at the same density
  // so the comparison is pixel for pixel.
  const scale = o.scale || (ref && !o.selector ? Math.max(1, Math.round((ref.width / o.width) * 4) / 4) : 1);

  let browser;
  try {
    browser = await pw.chromium.launch();
  } catch (e) {
    console.error('Could not start Chromium. Install it once with: npx playwright install chromium');
    console.error(String(e.message || e).split('\n')[0]);
    process.exit(3);
  }
  const context = await browser.newContext({
    viewport: { width: o.width, height: o.height },
    deviceScaleFactor: scale,
    colorScheme: o.scheme === 'dark' ? 'dark' : 'light',
    reducedMotion: 'reduce',
  });
  const page = await context.newPage();
  await page.goto(o.url, { waitUntil: 'networkidle', timeout: 45000 });
  if (o.waitFor) await page.waitForSelector(o.waitFor, { timeout: 15000 });
  // Web fonts are the most common false difference. Wait for them explicitly.
  await page.evaluate(() => document.fonts && document.fonts.ready);
  if (o.hover) await page.hover(o.hover);
  if (o.focus) await page.focus(o.focus);
  await page.waitForTimeout(150);

  if (o.selector) await page.locator(o.selector).first().screenshot({ path: out, animations: 'disabled' });
  else await page.screenshot({ path: out, fullPage: !!o.full, animations: 'disabled' });

  const report = { capture: path.relative(ROOT, out), viewport: `${o.width}x${o.height}`, scale };

  // Fonts that were asked for but never loaded render in a fallback face and
  // throw every text measurement off. Say so before anyone chases 1px.
  report.fontsNotLoaded = await page.evaluate(() => {
    if (!document.fonts) return [];
    const missing = new Set();
    document.fonts.forEach((f) => { if (f.status === 'error') missing.add(f.family.replace(/"/g, '')); });
    return [...missing];
  });

  if (o.styles) {
    report.styles = await page.evaluate(({ sel, props }) => {
      return [...document.querySelectorAll(sel)].slice(0, 40).map((el) => {
        const cs = getComputedStyle(el);
        const r = el.getBoundingClientRect();
        // Leave out what is only a default, so the list reads like a spec.
        const layout = /flex|grid/.test(cs.display);
        const bordered = parseFloat(cs.borderTopWidth) > 0;
        const defaults = { opacity: '1', 'text-align': 'start', 'text-overflow': 'clip', overflow: 'visible', 'text-transform': 'none', display: 'block' };
        const styles = {};
        for (const p of props) {
          const v = cs.getPropertyValue(p);
          if (!v || ['normal', 'none', '0px', 'auto', 'rgba(0, 0, 0, 0)'].includes(v) || defaults[p] === v) continue;
          if (!layout && /^(gap|row-gap|column-gap|flex-direction|align-items|justify-content)$/.test(p)) continue;
          if (!bordered && /^border-top-(color|style)$/.test(p)) continue;
          styles[p] = v;
        }
        const text = (el.innerText || '').trim().replace(/\s+/g, ' ').slice(0, 60);
        return {
          element: el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (el.classList.length ? '.' + [...el.classList].slice(0, 3).join('.') : ''),
          text,
          box: { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) },
          styles,
        };
      });
    }, { sel: o.styles, props: STYLE_PROPS });
  }

  if (ref) {
    const compare = path.join(path.dirname(out), `${path.basename(out, '.png')}-compare.png`);
    const b64 = (f) => 'data:image/png;base64,' + fs.readFileSync(f).toString('base64');
    const diffPage = await context.newPage();
    await diffPage.setViewportSize({ width: 800, height: 600 });
    const result = await diffPage.evaluate(async ({ refSrc, capSrc, cssScale }) => {
      const load = (src) => new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = src; });
      const [a, b] = await Promise.all([load(refSrc), load(capSrc)]);
      const w = Math.min(a.width, b.width), h = Math.min(a.height, b.height);
      const px = (img) => { const c = document.createElement('canvas'); c.width = w; c.height = h; const x = c.getContext('2d'); x.drawImage(img, 0, 0); return x.getImageData(0, 0, w, h); };
      const A = px(a), B = px(b);
      const D = new ImageData(w, h);
      // 16 of 255 on any channel. Low enough that a light grey card edge
      // shifting on white still shows; text anti-aliasing will speckle, which
      // is why the mismatch is a pointer to where to look, not a score.
      const THRESH = 16;
      const bandPx = Math.round(40 * cssScale);
      const bands = new Array(Math.ceil(h / bandPx)).fill(0);
      let bad = 0;
      for (let i = 0; i < A.data.length; i += 4) {
        const d = Math.max(Math.abs(A.data[i] - B.data[i]), Math.abs(A.data[i + 1] - B.data[i + 1]), Math.abs(A.data[i + 2] - B.data[i + 2]));
        if (d > THRESH) {
          bad++; bands[Math.floor(i / 4 / w / bandPx)]++;
          D.data[i] = 230; D.data[i + 1] = 30; D.data[i + 2] = 60; D.data[i + 3] = 255;
        } else {
          const g = 255 - (255 - (A.data[i] + A.data[i + 1] + A.data[i + 2]) / 3) * 0.25;
          D.data[i] = D.data[i + 1] = D.data[i + 2] = g; D.data[i + 3] = 255;
        }
      }
      // Reference | render | difference, side by side, labelled.
      const gap = 24, label = 36;
      const c = document.createElement('canvas');
      c.width = a.width + b.width + w + gap * 2; c.height = Math.max(a.height, b.height) + label;
      const x = c.getContext('2d');
      x.fillStyle = '#fff'; x.fillRect(0, 0, c.width, c.height);
      x.fillStyle = '#111'; x.font = `${Math.round(14 * cssScale)}px sans-serif`;
      x.fillText('reference', 0, label - 12); x.fillText('render', a.width + gap, label - 12);
      x.fillText('difference', a.width + b.width + gap * 2, label - 12);
      x.drawImage(a, 0, label); x.drawImage(b, a.width + gap, label);
      const dc = document.createElement('canvas'); dc.width = w; dc.height = h; dc.getContext('2d').putImageData(D, 0, 0);
      x.drawImage(dc, a.width + b.width + gap * 2, label);
      const hot = bands
        .map((n, k) => ({ from: Math.round((k * bandPx) / cssScale), to: Math.round(Math.min((k + 1) * bandPx, h) / cssScale), share: n / (w * Math.min(bandPx, h - k * bandPx)) }))
        .filter((r) => r.share > 0.02).sort((p, q) => q.share - p.share).slice(0, 5)
        .map((r) => ({ y: `${r.from}-${r.to}px`, mismatch: `${(r.share * 100).toFixed(1)}%` }));
      return {
        png: c.toDataURL('image/png'),
        mismatch: `${((bad / (w * h)) * 100).toFixed(2)}%`,
        sizes: { reference: `${a.width}x${a.height}`, render: `${b.width}x${b.height}` },
        hotBands: hot,
      };
    }, { refSrc: b64(ref.path), capSrc: b64(out), cssScale: scale });
    fs.writeFileSync(compare, Buffer.from(result.png.split(',')[1], 'base64'));
    report.compare = path.relative(ROOT, compare);
    report.mismatch = result.mismatch;
    report.sizes = result.sizes;
    if (result.sizes.reference !== result.sizes.render) {
      report.sizeNote = 'Reference and render differ in size; only the overlap is compared. A height difference usually means spacing drifted somewhere above the first hot band.';
    }
    report.hotBands = result.hotBands;
  }

  await browser.close();
  console.log(JSON.stringify(report, null, 2));
}

main().catch((e) => { console.error(String(e && e.stack || e)); process.exit(1); });
