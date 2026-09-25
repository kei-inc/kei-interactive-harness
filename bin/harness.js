#!/usr/bin/env node
/**
 * kei-interactive-harness
 *
 * One repository holds the harness. Every project depends on it. Updating the
 * harness and running `harness sync` updates every project.
 *
 * Three tiers of file, which is the whole design:
 *
 *   package-owned   Lives in node_modules and is never copied. All the check
 *                   logic, the SQL, the semgrep rules. Updated by npm.
 *   managed         Must exist at a fixed path because Cursor, husky, or
 *                   GitHub only look there. Regenerated on every sync, so
 *                   never edit these. Carries a header saying so.
 *   project-owned   Written once at init and yours forever. Invariants,
 *                   platform notes, the ratchet baseline, your own rules.
 *                   Sync never touches them.
 */

'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync, execSync } = require('child_process');

const LIB = path.join(__dirname, '..', 'lib');
const PKG = require(path.join(__dirname, '..', 'package.json'));
const CWD = process.cwd();

const c = {
  g: (s) => `\x1b[32m${s}\x1b[0m`,
  y: (s) => `\x1b[33m${s}\x1b[0m`,
  r: (s) => `\x1b[31m${s}\x1b[0m`,
  d: (s) => `\x1b[2m${s}\x1b[0m`,
  b: (s) => `\x1b[1m${s}\x1b[0m`,
};

// ------------------------------------------------------------------- stack --

/**
 * Does this project use Supabase? Re-evaluated on every sync, so a project that
 * adds Supabase later gets the Supabase rule on its next sync, and one that
 * never does is never told that the database is its security perimeter.
 *
 * HARNESS_SUPABASE in .harness/config.sh overrides detection: on, off, or auto.
 */
function readConfigVar(name) {
  try {
    const cfg = fs.readFileSync(path.join(CWD, '.harness', 'config.sh'), 'utf8');
    const m = cfg.match(new RegExp('^\\s*' + name + '=["\']?([^"\'\\n#]*)', 'm'));
    return m ? m[1].trim() : '';
  } catch { return ''; }
}

function usesSupabase() {
  const forced = readConfigVar('HARNESS_SUPABASE').toLowerCase();
  if (forced === 'on') return true;
  if (forced === 'off') return false;
  if (fs.existsSync(path.join(CWD, 'supabase'))) return true;
  try {
    const j = JSON.parse(fs.readFileSync(path.join(CWD, 'package.json'), 'utf8'));
    const deps = { ...(j.dependencies || {}), ...(j.devDependencies || {}) };
    return Object.keys(deps).some((d) => d.startsWith('@supabase/') || d === 'supabase');
  } catch { return false; }
}

// --------------------------------------------------------- package manager --

/** npm or pnpm, from the lockfile. Other managers fall back to npm commands. */
function packageManager() {
  if (fs.existsSync(path.join(CWD, 'pnpm-lock.yaml'))) return 'pnpm';
  return 'npm';
}
const isPnpmWorkspace = () => fs.existsSync(path.join(CWD, 'pnpm-workspace.yaml'));

/** The install command to show people, matching this project. */
function installHint(tag) {
  const spec = `github:kei-inc/kei-interactive-harness#${tag}`;
  if (packageManager() === 'pnpm') return `pnpm add -D${isPnpmWorkspace() ? ' -w' : ''} ${spec}`;
  return `npm i -D ${spec}`;
}

function readPackageJson() {
  try { return JSON.parse(fs.readFileSync(path.join(CWD, 'package.json'), 'utf8')); } catch { return {}; }
}

/** The pnpm version CI should install: the project's own, never a guess. */
function pnpmVersionLine() {
  const pm = readPackageJson().packageManager || '';
  if (pm.startsWith('pnpm@')) return null;   // pnpm/action-setup reads packageManager itself
  try {
    const v = execSync('pnpm --version', { cwd: CWD, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
    if (/^\d+/.test(v)) return v.split('.')[0];
  } catch {}
  return '12';
}

function nodeVersionYaml() {
  for (const f of ['.nvmrc', '.node-version']) {
    if (fs.existsSync(path.join(CWD, f))) return `          node-version-file: ${f}`;
  }
  return '          node-version: 24';
}

function workflowVars() {
  const pm = packageManager();
  const setupNode = (cache) => [
    '      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020  # v7.0.0',
    '        with:',
    nodeVersionYaml(),
    `          cache: ${cache}`,
  ];
  if (pm === 'pnpm') {
    const v = pnpmVersionLine();
    return {
      NODE_SETUP: [
        '      - uses: pnpm/action-setup@ea17c68df8912ef543352723c149a84f56e3d413  # v6.1.0',
        ...(v ? ['        with:', `          version: ${v}   # set "packageManager" in package.json to control this`] : []),
        ...setupNode('pnpm'),
        '      - run: pnpm install --frozen-lockfile',
      ].join('\n'),
      H: 'pnpm exec harness', EXEC: 'pnpm exec',
      DLX: 'pnpm dlx', OUTDATED: 'pnpm outdated --format json',
    };
  }
  return {
    NODE_SETUP: [...setupNode('npm'), '      - run: npm ci --prefer-offline --no-audit'].join('\n'),
    H: 'npx harness', EXEC: 'npx',
    DLX: 'npx --yes', OUTDATED: 'npm outdated --json',
  };
}

/** Fill a workflow template for this project: package manager, Supabase. */
function renderWorkflow(src) {
  const keepSupabase = usesSupabase();
  src = src.replace(/\n# \{\{IF_SUPABASE\}\}\n([\s\S]*?)\n# \{\{END_IF_SUPABASE\}\}\n?/g,
    (_, body) => (keepSupabase ? '\n' + body + '\n' : '\n'));
  const vars = workflowVars();
  return src.replace(/\{\{([A-Z_]+)\}\}/g, (m, k) => (k in vars ? vars[k] : m));
}

/** What a managed file should contain in this project, header included. */
function render(m) {
  let src = fs.readFileSync(path.join(LIB, m.from), 'utf8');
  if (m.to.startsWith('.github/workflows/')) src = renderWorkflow(src);
  return stamp(src, m.comment);
}

/** Managed files that only make sense for some stacks. */
const CONDITIONAL = {
  '.cursor/rules/15-supabase.mdc': usesSupabase,
};

// ---------------------------------------------------------------- manifest --

/**
 * Files regenerated on every sync. Source in the package, destination in the
 * project, and a comment syntax so each can carry a do-not-edit header.
 */
const MANAGED = [
  ...fs.readdirSync(path.join(LIB, 'rules')).map((f) => ({
    from: `rules/${f}`, to: `.cursor/rules/${f}`, comment: 'mdc',
  })),
  ...fs.readdirSync(path.join(LIB, 'commands')).map((f) => ({
    from: `commands/${f}`, to: `.cursor/commands/${f}`, comment: 'md',
  })),
  ...fs.readdirSync(path.join(LIB, 'generated/husky')).map((f) => ({
    from: `generated/husky/${f}`, to: `.husky/${f}`, comment: 'hash', exec: true,
  })),
  ...fs.readdirSync(path.join(LIB, 'generated/workflows')).map((f) => ({
    from: `generated/workflows/${f}`, to: `.github/workflows/${f}`, comment: 'hash',
  })),
  // A stable path gives semgrep stable rule IDs (harness.<rule>). Under
  // node_modules, and under pnpm especially, the ID embeds the whole path.
  { from: 'semgrep.yml', to: '.harness/semgrep.yml', comment: 'hash' },
];

/** Written once at init. Sync never touches these again. */
const TEMPLATES = [
  { from: 'templates/AGENTS.md', to: 'AGENTS.md' },
  { from: 'templates/CONTEXT.md', to: 'docs/CONTEXT.md' },
  { from: 'templates/WORKFLOW.md', to: 'docs/WORKFLOW.md' },
  { from: 'templates/INVARIANTS.md', to: 'docs/INVARIANTS.md' },
  { from: 'templates/PLATFORM.md', to: 'docs/PLATFORM.md' },
  { from: 'templates/REPAIR-QUEUE.md', to: 'docs/REPAIR-QUEUE.md' },
  { from: 'templates/allow-public-env.txt', to: '.harness/allow-public-env.txt' },
  { from: 'templates/rls-allow.txt', to: '.harness/rls-allow.txt' },
  { from: 'templates/gitleaksignore', to: '.gitleaksignore' },
  { from: 'templates/next.config.headers.mjs', to: 'docs/next.config.headers.mjs' },
];

// No version number in the header. It would change every release and make
// every file look modified on every sync, drowning the one file that actually
// changed. The version lives in .harness/manifest.json instead.
const HEADERS = {
  hash:
    `# Generated by kei-interactive-harness. Do not edit; run: npx harness sync\n` +
    `# Project-specific settings belong in .harness/config.sh\n`,
  md:
    `<!-- Generated by kei-interactive-harness. Do not edit; run: npx harness sync.\n` +
    `     Project rules go in .cursor/rules/90-*.mdc, which sync never touches. -->\n\n`,
  get mdc() { return this.md; }, // placed after the frontmatter, not before
};

function stamp(content, kind) {
  const header = HEADERS[kind];
  if (kind !== 'mdc') return header + content;
  // Cursor requires the frontmatter to be the very first thing in the file.
  const m = content.match(/^---\n[\s\S]*?\n---\n/);
  return m ? m[0] + '\n' + header + content.slice(m[0].length) : header + content;
}

const manifestPath = () => path.join(CWD, '.harness', 'manifest.json');
function readManifest() {
  try { return JSON.parse(fs.readFileSync(manifestPath(), 'utf8')); }
  catch { return null; }
}
function writeManifest(m) {
  fs.mkdirSync(path.dirname(manifestPath()), { recursive: true });
  fs.writeFileSync(manifestPath(), JSON.stringify(m, null, 2) + '\n');
}

function write(rel, content, exec) {
  const dest = path.join(CWD, rel);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, content);
  if (exec) fs.chmodSync(dest, 0o755);
}

// -------------------------------------------------------------------- init --

function init() {
  if (!fs.existsSync(path.join(CWD, '.git'))) {
    console.error('Not a git repository. The harness needs git.');
    process.exit(1);
  }
  console.log(c.b(`kei-interactive-harness v${PKG.version} -> ${CWD}`) + '\n');

  syncManaged();

  console.log('\n' + c.b('Project files') + c.d(' (written once, then yours)'));
  for (const t of TEMPLATES) {
    const dest = path.join(CWD, t.to);
    if (fs.existsSync(dest)) { console.log(`  ${c.d('kept')}    ${t.to}`); continue; }
    write(t.to, fs.readFileSync(path.join(LIB, t.from), 'utf8'));
    console.log(`  ${c.g('added')}   ${t.to}`);
  }

  // A config file the project owns, which every check script sources.
  const cfg = path.join(CWD, '.harness', 'config.sh');
  if (!fs.existsSync(cfg)) {
    write('.harness/config.sh',
`# Per-project harness settings. This file is yours; sync never overwrites it.
# Everything is optional.

# Supabase features (the Supabase Cursor rule, the RLS audit) switch on when
# the project depends on @supabase/* or has a supabase/ folder. Override: on | off
# HARNESS_SUPABASE=auto

# Branch on which spike markers are rejected.
# HARNESS_DEFAULT_BRANCH=main

# Days before a dated SPIKE() starts nagging.
# HARNESS_SPIKE_MAX_DAYS=30

# Skip specific checks in this project, space separated.
# HARNESS_DISABLE="getsession cache-review"

# When pre-push finds the LOCAL database behind your migration files, report it
# (default) or apply them with 'supabase migration up'. Never touches any
# database other than the local stack.
# HARNESS_MIGRATE_LOCAL=report

# Semgrep rules to silence in this project, by short id, space separated.
# HARNESS_SEMGREP_EXCLUDE="missing-timeout-on-outbound-fetch"

# In CI, a Supabase project with no SUPABASE_DB_URL secret FAILS the database
# job rather than passing while auditing nothing. Set 0 to opt out on purpose.
# HARNESS_REQUIRE_DB_AUDIT=1

# A site with no user accounts at all (marketing, docs, a portfolio) has no
# identity to check. Mark each route or action // @public-route with a reason,
# or turn the checks off for the whole project:
# HARNESS_DISABLE="route-handlers server-actions"

# Extra names that count as "this handler establishes identity", as a regex
# alternation. The default already accepts requireUser, requireAuth, getUser,
# getCurrentUser, authorize and verifyWebhook. Add your auth library's here.
# HARNESS_AUTH_PATTERN='auth\\(|getServerSession|currentUser'


# Extra ratchet metrics, one "label|regex" per line. Use this instead of
# forking when a mistake is specific to this codebase.
# HARNESS_EXTRA_METRICS='legacy-api|from-old-api
# inline-styles|style=\\{\\{'
`);
    console.log(`  ${c.g('added')}   .harness/config.sh`);
  }

  addPackageScripts();
  ensureGitignore();

  // Wire git to .husky/ without letting `husky init` write its own hook file.
  const huskyBin = path.join(CWD, 'node_modules', '.bin', 'husky');
  if (fs.existsSync(huskyBin)) {
    const r = spawnSync(huskyBin, [], { cwd: CWD, stdio: 'pipe' });
    console.log(r.status === 0
      ? `  ${c.g('wired')}   git hooks -> .husky/`
      : `  ${c.y('note')}    could not run husky; run: npx husky`);
  }

  console.log('\n' + c.b('Next:'));
  console.log('  1. npx harness ratchet          record today as the baseline');
  console.log('  2. Fill in docs/CONTEXT.md, then docs/INVARIANTS.md and docs/PLATFORM.md.');
  console.log('     Partial is fine; doctor will remind you what is still blank.');
  console.log('  3. git add -A && git commit -m "add kei-interactive-harness"');
  console.log('  4. SUPABASE_DB_URL=... npx harness rls    audit the real perimeter');
  console.log('  5. Open in Cursor, check the rules panel shows the .mdc files, try /repair');
  console.log('\n' + c.d('  Do not run `npx husky init`; it writes a competing pre-commit hook.'));
}

/**
 * Entries the project should never commit. Appended once, in a marked block,
 * and only the lines not already present, so an existing .gitignore is never
 * reordered or duplicated.
 */
function ensureGitignore() {
  const gi = path.join(CWD, '.gitignore');
  const existing = fs.existsSync(gi) ? fs.readFileSync(gi, 'utf8') : '';
  const lines = existing.split('\n').map((l) => l.trim());
  const want = [
    'node_modules/',
    '.env',
    '.env.local',
    '.env.*.local',
    '.env.production',
    '.env.development',
    '*.harness-new',
    'semgrep-nightly.json',
    'outdated.json',
    'knip.json',
    'ratchet-trend.txt',
  ];
  // Treat "node_modules" and "/node_modules" as covering node_modules/.
  const has = (w) => lines.includes(w) || lines.includes(w.replace(/\/$/, '')) || lines.includes('/' + w.replace(/\/$/, ''));
  const missing = want.filter((w) => !has(w));
  if (!missing.length) return;
  const block = (existing && !existing.endsWith('\n') ? '\n' : '') +
    '\n# kei-interactive-harness: never commit these\n' + missing.join('\n') + '\n';
  fs.writeFileSync(gi, existing + block);
  console.log(`  ${c.g('added')}   .gitignore entries (${missing.length})`);
}

function addPackageScripts() {
  const pj = path.join(CWD, 'package.json');
  if (!fs.existsSync(pj)) return;
  const j = JSON.parse(fs.readFileSync(pj, 'utf8'));
  j.scripts = j.scripts || {};
  const deps = { ...(j.dependencies || {}), ...(j.devDependencies || {}) };
  const want = {
    harness: 'harness check',
    'harness:full': 'harness full',
    ratchet: 'harness ratchet',
  };
  // "prepare": "husky" runs on every npm install. Adding it when husky is not a
  // dependency makes every install fail with "husky: command not found".
  if (deps.husky) want.prepare = 'husky';
  else console.log(`  ${c.y('note')}    husky is not installed. npm i -D husky && npx husky init`);
  let changed = false;
  for (const [k, v] of Object.entries(want)) {
    if (!j.scripts[k]) { j.scripts[k] = v; changed = true; }
  }
  if (changed) {
    fs.writeFileSync(pj, JSON.stringify(j, null, 2) + '\n');
    console.log(`  ${c.g('added')}   package.json scripts`);
  }
}

// -------------------------------------------------------------------- sync --

/** Numeric compare of x.y.z strings: negative when a is older than b. */
function cmpVersion(a, b) {
  const pa = String(a).split('.').map(Number), pb = String(b).split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return d;
  }
  return 0;
}

function syncManaged(quiet) {
  const prev = readManifest();
  // An old tag re-run from shell history installs cleanly and would quietly
  // rewrite every managed file backwards. Refuse unless it is deliberate.
  if (prev && cmpVersion(PKG.version, prev.version) < 0 && !process.argv.includes('--allow-downgrade')) {
    console.error(c.r(`This project is on v${prev.version}, but the installed harness is v${PKG.version}.`));
    console.error('Syncing would downgrade it. Install the newer tag first:');
    console.error(`  ${installHint('v' + prev.version)}`);
    console.error(c.d('To roll back on purpose: npx harness sync --allow-downgrade'));
    process.exit(1);
  }
  if (!quiet) {
    const from = prev ? `v${prev.version}` : 'nothing';
    console.log(c.b(`Managed files`) + c.d(` (${from} -> v${PKG.version}, regenerated every sync; ${packageManager()}${usesSupabase() ? ', supabase' : ''})`));
  }
  const files = {};
  let changed = 0;
  for (const m of MANAGED) {
    const cond = CONDITIONAL[m.to];
    if (cond && !cond()) {
      const dest = path.join(CWD, m.to);
      // Remove it only if the harness wrote it. A hand-written file stays.
      if (fs.existsSync(dest) && fs.readFileSync(dest, 'utf8').includes('Generated by kei-interactive-harness')) {
        fs.unlinkSync(dest);
        if (!quiet) console.log(`  ${c.d('removed')} ${m.to} ${c.d('(no Supabase in this project)')}`);
      }
      continue;
    }
    const out = render(m);
    const dest = path.join(CWD, m.to);
    const existed = fs.existsSync(dest);
    const current = existed ? fs.readFileSync(dest, 'utf8') : '';
    const same = existed && current === out;
    // A file at a managed path that does not carry the harness header is one
    // the project wrote itself, before the harness arrived. Never clobber it:
    // leave it, put the harness version beside it, and say so.
    const foreign = existed && !same && !current.includes('Generated by kei-interactive-harness');
    if (foreign) {
      write(m.to + '.harness-new', out, m.exec);
      if (!quiet) console.log(`  ${c.y('yours   ')} ${m.to}  ${c.d('(harness version written to ' + m.to + '.harness-new; merge, then delete it)')}`);
      continue;
    }
    if (!same) { write(m.to, out, m.exec); changed++; }
    files[m.to] = 'managed';
    if (!quiet && !same) console.log(`  ${existed ? c.g('updated') : c.g('added  ')} ${m.to}`);
  }
  if (!quiet && changed === 0) console.log(c.d('  already in step, nothing to write'));
  writeManifest({
    version: PKG.version,
    syncedAt: new Date().toISOString(),
    managed: Object.keys(files).sort(),
  });
  return Object.keys(files).length;
}

function sync() {
  const n = syncManaged();
  console.log('\n' + c.d(`${n} managed files at v${PKG.version}.`));
  console.log(c.d('Your rules in .cursor/rules/90-*.mdc, docs/, and .harness/ were untouched.'));
  const stale = TEMPLATES.filter((t) => !fs.existsSync(path.join(CWD, t.to)));
  if (stale.length) {
    console.log('\n' + c.y('New project templates available since your last version:'));
    for (const t of stale) console.log(`  ${t.to}   ${c.d('npx harness adopt ' + t.to)}`);
  }
}

function adopt(rel) {
  const t = TEMPLATES.find((x) => x.to === rel);
  if (!t) { console.error(`Not a template: ${rel}`); process.exit(1); }
  if (fs.existsSync(path.join(CWD, rel))) { console.error(`${rel} already exists.`); process.exit(1); }
  write(rel, fs.readFileSync(path.join(LIB, t.from), 'utf8'));
  console.log(c.g(`added ${rel}`));
}

// ------------------------------------------------------------------ doctor --

function doctor() {
  const m = readManifest();
  console.log(c.b('kei-interactive-harness doctor') + '\n');
  console.log(`  package version   ${PKG.version}`);
  console.log(`  project synced at ${m ? m.version : c.r('never — run: npx harness init')}`);
  if (m && cmpVersion(m.version, PKG.version) < 0) {
    console.log(`  ${c.y(`behind: run npx harness sync to move ${m.version} -> ${PKG.version}`)}`);
  } else if (m && cmpVersion(m.version, PKG.version) > 0) {
    console.log(`  ${c.r(`installed package is older than this project; reinstall: ${installHint('v' + m.version)}`)}`);
  }

  console.log(`  package manager   ${packageManager()}${isPnpmWorkspace() ? ' (workspace)' : ''}`);
  console.log(`  update command    ${installHint('<tag>')} && npx harness sync`);
  console.log(`  supabase          ${usesSupabase() ? 'yes' : c.d('no  (Supabase rule and database audit are off; they switch on at the next sync once it is added)')}`);

  console.log('\n' + c.b('  Managed') + c.d(' (regenerated on sync)'));
  let drifted = 0;
  for (const mf of MANAGED) {
    if (CONDITIONAL[mf.to] && !CONDITIONAL[mf.to]()) continue;
    const dest = path.join(CWD, mf.to);
    if (!fs.existsSync(dest)) { console.log(`    ${c.r('missing')} ${mf.to}`); drifted++; continue; }
    const want = render(mf);
    if (fs.readFileSync(dest, 'utf8') !== want) {
      console.log(`    ${c.y('edited ')} ${mf.to} ${c.d('(sync will overwrite)')}`);
      drifted++;
    }
  }
  if (!drifted) console.log(c.d('    all in step with the package'));

  console.log('\n' + c.b('  Yours') + c.d(' (sync never touches)'));
  const mine = [
    ...TEMPLATES.map((t) => t.to),
    '.harness/config.sh', '.harness/ratchet.txt', '.harness/goals.txt',
  ];
  for (const f of mine) {
    const ok = fs.existsSync(path.join(CWD, f));
    console.log(`    ${ok ? c.g('present') : c.d('absent ')} ${f}`);
  }
  const overrides = safeReaddir(path.join(CWD, '.cursor/rules')).filter((f) => /^9\d/.test(f));
  for (const h of safeReaddir(path.join(CWD, '.husky')).filter((f) => f.endsWith('.local'))) {
    console.log(`    ${c.g('present')} .husky/${h} ${c.d('(project hook)')}`);
  }
  for (const f of overrides) console.log(`    ${c.g('present')} .cursor/rules/${f} ${c.d('(project rule)')}`);

  console.log('\n' + c.b('  package.json scripts the checks call') + c.d(' (absent ones are skipped)'));
  let scripts = {};
  try { scripts = JSON.parse(fs.readFileSync(path.join(CWD, 'package.json'), 'utf8')).scripts || {}; } catch {}
  for (const k of ['typecheck', 'lint', 'test:unit', 'test:e2e', 'build', 'size']) {
    console.log(`    ${scripts[k] ? c.g('present') : c.d('absent ')} ${k}`);
  }

  const strays = [];
  const walk = (d, depth) => {
    if (depth > 4) return;
    for (const e of safeReaddir(d)) {
      if (e === 'node_modules' || e === '.git') continue;
      const p = path.join(d, e);
      let st; try { st = fs.statSync(p); } catch { continue; }
      if (st.isDirectory()) walk(p, depth + 1);
      else if (e.endsWith('.harness-new')) strays.push(path.relative(CWD, p));
    }
  };
  walk(CWD, 0);
  if (strays.length) {
    console.log('\n  ' + c.y('Unmerged .harness-new files (git ignores these, so they are easy to forget):'));
    for (const f of strays) console.log(`    ${f}`);
  }

  const inv = path.join(CWD, 'docs/INVARIANTS.md');
  if (fs.existsSync(inv) && fs.readFileSync(inv, 'utf8').includes('`______`')) {
    console.log('\n  ' + c.y('docs/INVARIANTS.md still has unfilled blanks.'));
    console.log('  ' + c.d('That file is what makes the harness know your system.'));
  }
}

function safeReaddir(p) { try { return fs.readdirSync(p); } catch { return []; } }

// ------------------------------------------------------------------- fleet --

/** Which of my projects are on which version. */
function fleet(dir) {
  const root = path.resolve(dir || path.join(os.homedir(), 'code'));
  console.log(c.b(`kei-interactive-harness across ${root}`) + c.d(`  (package here: v${PKG.version})`) + '\n');
  let found = 0;
  for (const name of safeReaddir(root)) {
    const mp = path.join(root, name, '.harness', 'manifest.json');
    if (!fs.existsSync(mp)) continue;
    found++;
    let v = '?';
    try { v = JSON.parse(fs.readFileSync(mp, 'utf8')).version; } catch {}
    const mark = v === PKG.version ? c.g('current') : c.y('behind ');
    console.log(`  ${mark}  ${v.padEnd(10)} ${name}`);
  }
  if (!found) console.log(c.d('  No harness projects found. Pass a directory: npx harness fleet ~/work'));
  else console.log('\n' + c.d('  Update one:  cd <project> && <npm i -D | pnpm add -D -w> github:kei-inc/kei-interactive-harness#<tag> && npx harness sync'));
}

// ------------------------------------------------------------------- eject --

/** The one-way door. Copy everything in, drop the dependency, own it forever. */
function eject() {
  console.log(c.b('Ejecting kei-interactive-harness into this project.') + '\n');
  const copyTree = (src, dst) => {
    fs.mkdirSync(dst, { recursive: true });
    for (const e of fs.readdirSync(src, { withFileTypes: true })) {
      const s = path.join(src, e.name), d = path.join(dst, e.name);
      if (e.isDirectory()) copyTree(s, d);
      else { fs.copyFileSync(s, d); if (s.endsWith('.sh')) fs.chmodSync(d, 0o755); }
    }
  };
  copyTree(path.join(LIB, 'scripts'), path.join(CWD, 'harness/scripts'));
  copyTree(path.join(LIB, 'sql'), path.join(CWD, 'harness/sql'));
  fs.copyFileSync(path.join(LIB, 'semgrep.yml'), path.join(CWD, 'harness/semgrep.yml'));

  // Managed files lose their do-not-edit header, because now you may.
  for (const m of MANAGED) {
    const dest = path.join(CWD, m.to);
    if (fs.existsSync(dest)) {
      let s = fs.readFileSync(dest, 'utf8');
      s = s.replace(/^# Generated by kei-interactive-harness[^\n]*\n# Project-specific[^\n]*\n/m, '');
      s = s.replace(/<!-- Generated by kei-interactive-harness[\s\S]*?-->\n\n?/m, '');
      fs.writeFileSync(dest, s);
    }
  }
  // The hooks and workflows called the CLI. Point them at the ejected copy.
  const rewire = (rel, pairs) => {
    const f = path.join(CWD, rel);
    if (!fs.existsSync(f)) return;
    let t = fs.readFileSync(f, 'utf8');
    for (const [a, b] of pairs) t = t.split(a).join(b);
    fs.writeFileSync(f, t);
  };
  // A small dispatcher stands in for the CLI, so every call site keeps its shape.
  write('harness/run.sh', `#!/usr/bin/env bash
# Stands in for the harness CLI after eject.
export HARNESS_LIB="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export HARNESS_PROJECT_ROOT="\${HARNESS_PROJECT_ROOT:-$(pwd)}"
cmd="\$1"; shift || true
case "\$cmd" in
  quick|check|full) exec bash "\$HARNESS_LIB/scripts/harness.sh" "\$cmd" ;;
  boundaries) exec bash "\$HARNESS_LIB/scripts/check-boundaries.sh" "\$@" ;;
  stack)      exec bash "\$HARNESS_LIB/scripts/check-stack.sh" "\$@" ;;
  rls)        exec bash "\$HARNESS_LIB/scripts/check-rls.sh" "\$@" ;;
  grants)     exec bash "\$HARNESS_LIB/scripts/grants.sh" "\$@" ;;
  migrations) exec bash "\$HARNESS_LIB/scripts/check-migrations.sh" "\$@" ;;
  semgrep)    exec bash "\$HARNESS_LIB/scripts/semgrep.sh" "\$@" ;;
  ratchet)    exec bash "\$HARNESS_LIB/scripts/ratchet.sh" "\$@" ;;
  *) echo "usage: harness/run.sh <quick|check|full|boundaries|stack|rls|grants|migrations|semgrep|ratchet>"; exit 2 ;;
esac
`, true);
  const pairs = [
    ['./node_modules/.bin/harness', 'bash harness/run.sh'],
    ['pnpm exec harness', 'bash harness/run.sh'],
    ['npx harness', 'bash harness/run.sh'],
  ];
  for (const f of ['.husky/pre-commit', '.husky/pre-push', '.github/workflows/ci.yml', '.github/workflows/nightly.yml']) {
    rewire(f, pairs);
  }
  console.log(c.g('  Hooks and workflows rewired to ./harness/'));

  write('.harness/EJECTED', `Ejected from kei-interactive-harness v${PKG.version} on ${new Date().toISOString()}\n` +
    `The check logic now lives in ./harness/. Set HARNESS_LIB=./harness when running it.\n` +
    `This project no longer receives harness updates.\n`);
  console.log(c.g('  Logic copied to ./harness/'));
  console.log(c.g('  Managed headers removed; every file is yours now.'));
  console.log('\n' + c.y('  This project will no longer receive updates.'));
  console.log(c.d('  Remove the dependency: npm uninstall kei-interactive-harness'));
  console.log(c.d('  Then run checks with:  bash harness/run.sh check'));
}

// ------------------------------------------------------------------- checks --

/**
 * Run a package.json script, or say plainly that nothing ran. A CI step that
 * skipped everything must not look the same as one that tested something, so
 * in GitHub Actions a missing script leaves a warning on the run and a line in
 * the job summary. It still passes: absence is a gap to see, not a failure.
 */
function runScript(name) {
  if (!name) { console.error('usage: harness run <script>'); process.exit(2); }
  if (!(readPackageJson().scripts || {})[name]) {
    const msg = `No "${name}" script in package.json, so nothing ran.`;
    if (process.env.GITHUB_ACTIONS) {
      console.log(`::warning title=Nothing ran: ${name}::${msg} This step passed without checking anything.`);
      if (process.env.GITHUB_STEP_SUMMARY) {
        fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
          `- :warning: **${name}**: nothing ran (no \`${name}\` script in package.json)\n`);
      }
    }
    console.log(c.y(`skipped: ${msg}`));
    process.exit(0);
  }
  const r = spawnSync(packageManager(), ['run', name], { stdio: 'inherit', cwd: CWD });
  process.exit(r.status === null ? 1 : r.status);
}

function run(script, args) {
  const r = spawnSync('bash', [path.join(LIB, 'scripts', script), ...args], {
    stdio: 'inherit',
    env: { ...process.env, HARNESS_PROJECT_ROOT: CWD, HARNESS_LIB: LIB },
  });
  process.exit(r.status === null ? 1 : r.status);
}

// --------------------------------------------------------------------- main --

const [cmd, ...rest] = process.argv.slice(2);
switch (cmd) {
  case 'init': init(); break;
  case 'sync': sync(); break;
  case 'adopt': adopt(rest[0]); break;
  case 'doctor': doctor(); break;
  case 'fleet': fleet(rest[0]); break;
  case 'eject': eject(); break;

  case 'quick': case 'check': case 'full': run('harness.sh', [cmd]); break;
  case 'ratchet': run('ratchet.sh', rest); break;
  case 'boundaries': run('check-boundaries.sh', rest); break;
  case 'stack': run('check-stack.sh', rest); break;
  case 'rls': run('check-rls.sh', rest); break;
  case 'grants': run('grants.sh', rest); break;
  case 'migrations': run('check-migrations.sh', rest); break;
  case 'semgrep': run('semgrep.sh', rest); break;
  case 'run': runScript(rest[0]); break;

  case 'lib': console.log(LIB); break;
  case 'version': case '--version': console.log(PKG.version); break;
  default:
    console.log(`kei-interactive-harness v${PKG.version}

  Setting up
    init            install into this project
    sync            regenerate managed files from the installed version
                    (refuses to downgrade; --allow-downgrade to roll back)
    adopt <file>    take a project template added since you installed
    eject           copy everything in and stop receiving updates

  Looking around
    doctor          version, drift, and what is yours versus managed
    fleet [dir]     which of your projects are on which version

  Running checks
    quick           pre-commit set, seconds
    check           pre-push set, under a minute
    full            everything, including security scans
    ratchet         debt against the baseline
    ratchet --new   only what this branch added
    ratchet --goals distance to your targets
    boundaries      the non-negotiables
    lib             print the package lib path (for CI)
    stack           Next.js, Supabase, Cloudflare specifics
    rls             audit the live database perimeter
    grants          print today's Data API grants as a migration
    migrations      migration order, drift, and local database state
    semgrep         static analysis: new findings only (--pr, --push, --sweep)
    run <script>    run a package.json script; flags it in CI when there is none
`);
}
