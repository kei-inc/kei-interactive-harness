#!/usr/bin/env node
/**
 * Harness evals: does the harness actually change what the agent writes?
 *
 *   node evals/run.js                         every case, with and without the harness, Claude Code
 *   node evals/run.js --agent cursor          the same through Cursor's CLI
 *   node evals/run.js --case new-table-rls,no-drive-by --runs 3
 *   node evals/run.js --mode with             only with the harness installed
 *   node evals/run.js --cmd '<shell>'         any agent: the prompt is in $EVAL_PROMPT
 *   node evals/run.js --keep                  keep each run's project for a look
 *
 * Each case is a bait prompt (evals/cases/*.json): an ordinary request where
 * the obvious answer breaks a rule the harness teaches. The runner copies
 * evals/fixture into a fresh git repo, installs this checkout of the harness
 * into it (or not, for the baseline), runs the agent headless with the prompt,
 * and scores what it wrote with deterministic checks. No model grades a model.
 *
 * Why both modes: a case that passes without the harness is not measuring the
 * harness. The number worth watching is the gap, per case, and whether a rule
 * edit widened or narrowed it. Agents are not deterministic, so use --runs 3
 * or more before believing a difference.
 *
 * This costs model usage: every case and mode is a real agent session.
 */

'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const REPO = path.join(__dirname, '..');
const BIN = path.join(REPO, 'bin', 'harness.js');
const LIB = path.join(REPO, 'lib');
const CASES = path.join(__dirname, 'cases');
const FIXTURE = path.join(__dirname, 'fixture');

const AGENTS = {
  claude: 'claude -p "$EVAL_PROMPT" --permission-mode acceptEdits',
  // Check `cursor-agent --help` if this drifts; --cmd overrides it.
  cursor: 'cursor-agent -p "$EVAL_PROMPT" --force',
};

// ------------------------------------------------------------------ args --

function parseArgs(argv) {
  const o = { agent: 'claude', runs: 1, mode: 'both', timeout: 600 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--keep') o.keep = true;
    else if (a === '--json') o.json = true;
    else if (a.startsWith('--')) o[a.slice(2)] = argv[++i];
  }
  o.runs = Number(o.runs); o.timeout = Number(o.timeout);
  return o;
}

// ------------------------------------------------------------------ glob --

/** Enough glob for the cases: **, *, ?, {a,b}. Matched against repo-relative paths. */
function globToRegex(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const ch = glob[i];
    if (ch === '*' && glob[i + 1] === '*') {
      i++;
      if (glob[i + 1] === '/') { i++; re += '(?:.*/)?'; } else re += '.*';
    } else if (ch === '*') re += '[^/]*';
    else if (ch === '?') re += '[^/]';
    else if (ch === '{') {
      const end = glob.indexOf('}', i);
      re += '(?:' + glob.slice(i + 1, end).split(',').map((s) => s.replace(/[.+^$()|[\]\\]/g, '\\$&')).join('|') + ')';
      i = end;
    } else re += ch.replace(/[.+^$()|[\]\\]/g, '\\$&');
  }
  return new RegExp('^' + re + '$');
}

function listFiles(dir) {
  const out = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (['node_modules', '.git', '.next'].includes(e.name)) continue;
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else out.push(path.relative(dir, p).split(path.sep).join('/'));
    }
  };
  walk(dir);
  return out;
}

// --------------------------------------------------------------- project --

const sh = (cmd, args, cwd, extra = {}) => spawnSync(cmd, args, { cwd, encoding: 'utf8', ...extra });
const git = (cwd, ...args) => sh('git', ['-c', 'user.email=eval@harness', '-c', 'user.name=eval', ...args], cwd);

function copyTree(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  for (const e of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, e.name), d = path.join(dst, e.name);
    if (e.isDirectory()) copyTree(s, d); else fs.copyFileSync(s, d);
  }
}

/** A fresh project from the fixture, with or without this harness installed. */
function makeProject(withHarness) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-eval-'));
  copyTree(FIXTURE, dir);
  git(dir, 'init', '-q', '-b', 'play');
  if (withHarness) {
    // Install this checkout the way npm would: package in node_modules, bin linked.
    fs.mkdirSync(path.join(dir, 'node_modules', '.bin'), { recursive: true });
    fs.symlinkSync(REPO, path.join(dir, 'node_modules', 'kei-interactive-harness'), 'dir');
    fs.symlinkSync('../kei-interactive-harness/bin/harness.js', path.join(dir, 'node_modules', '.bin', 'harness'));
    const r = sh('node', [BIN, 'init'], dir);
    if (r.status !== 0) throw new Error('harness init failed:\n' + r.stdout + r.stderr);
  } else {
    fs.writeFileSync(path.join(dir, '.gitignore'), 'node_modules/\n');
  }
  git(dir, 'add', '-A');
  git(dir, 'commit', '-q', '-m', 'baseline');
  const base = git(dir, 'rev-parse', 'HEAD').stdout.trim();
  return { dir, base };
}

// --------------------------------------------------------------- scoring --

function read(dir, f) { try { return fs.readFileSync(path.join(dir, f), 'utf8'); } catch { return ''; } }

function changedFiles(dir, base) {
  const r = git(dir, 'status', '--porcelain=v1', '-uall');
  return r.stdout.split('\n').filter(Boolean).map((l) => l.slice(3).replace(/^.* -> /, ''));
}

/**
 * Judge one expectation. Returns { ok, says, detail }. Everything is a file
 * read or a harness check: the same answer every time for the same files.
 */
function judge(e, dir, base, files) {
  const says = e.says || `${e.type} ${e.glob || ''} ${e.pattern || ''}`.trim();
  const re = (p) => new RegExp(p, (e.flags || '') + 'm');
  const inGlob = (g) => files.filter((f) => globToRegex(g).test(f));
  switch (e.type) {
    case 'file-exists': {
      const hit = inGlob(e.glob);
      return { ok: hit.length > 0, says: e.says || `${e.glob} exists`, detail: hit.length ? '' : 'no such file' };
    }
    case 'no-file': {
      const hit = inGlob(e.glob);
      return { ok: hit.length === 0, says, detail: hit.join(', ') };
    }
    case 'match': {
      const hit = inGlob(e.glob).filter((f) => re(e.pattern).test(read(dir, f)));
      return { ok: hit.length > 0, says, detail: hit.length ? '' : `nothing in ${e.glob} matches /${e.pattern}/` };
    }
    case 'no-match': {
      const hit = inGlob(e.glob).filter((f) => re(e.pattern).test(read(dir, f)));
      return { ok: hit.length === 0, says, detail: hit.join(', ') };
    }
    case 'every-file': {
      const scope = inGlob(e.glob).filter((f) => re(e.where).test(read(dir, f)));
      if (e.atLeastOne && !scope.length) return { ok: false, says, detail: `no file matches /${e.where}/` };
      const bad = scope.filter((f) => {
        const t = read(dir, f);
        return (e.must && !re(e.must).test(t)) || (e.mustNot && re(e.mustNot).test(t));
      });
      return { ok: bad.length === 0, says, detail: bad.join(', ') };
    }
    case 'changed-only': {
      const allowed = (e.allow || []).map(globToRegex);
      const extra = changedFiles(dir, base).filter((f) => !allowed.some((r) => r.test(f)));
      return { ok: extra.length === 0, says, detail: extra.join(', ') };
    }
    case 'harness-clean': {
      // The harness's own verdict on this change, whichever mode it ran in.
      if (!fs.existsSync(path.join(dir, '.harness', 'allow-public-env.txt'))) {
        fs.mkdirSync(path.join(dir, '.harness'), { recursive: true });
        fs.copyFileSync(path.join(LIB, 'templates', 'allow-public-env.txt'), path.join(dir, '.harness', 'allow-public-env.txt'));
      }
      const r = sh('node', [path.join(LIB, 'scripts', 'turn.js')], dir, { env: { ...process.env, HARNESS_PROJECT_ROOT: dir, HARNESS_LIB: LIB } });
      return { ok: r.status === 0, says: e.says || 'nothing the harness would block', detail: r.status === 0 ? '' : r.stdout.split('\n').filter((l) => l.startsWith('BLOCKED')).join('; ') };
    }
    default:
      return { ok: false, says, detail: `unknown expectation type ${e.type}` };
  }
}

function score(c, dir, base) {
  // An agent that committed its work would hide it from the change-based
  // checks. Put everything since the baseline back in the working tree.
  git(dir, 'reset', '-q', '--soft', base);
  const files = listFiles(dir);
  return c.expect.map((e) => judge(e, dir, base, files));
}

// ------------------------------------------------------------------ main --

function main() {
  const o = parseArgs(process.argv.slice(2));
  const cmd = o.cmd || AGENTS[o.agent];
  if (!cmd) { console.error(`Unknown agent ${o.agent}; pass --cmd.`); process.exit(2); }
  const wanted = o.case ? new Set(o.case.split(',')) : null;
  const cases = fs.readdirSync(CASES).filter((f) => f.endsWith('.json'))
    .map((f) => JSON.parse(fs.readFileSync(path.join(CASES, f), 'utf8')))
    .filter((c) => !wanted || wanted.has(c.name));
  if (!cases.length) { console.error('No cases matched.'); process.exit(2); }
  const modes = o.mode === 'both' ? ['with', 'without'] : [o.mode];

  const results = [];
  for (const c of cases) {
    for (const mode of modes) {
      for (let run = 1; run <= o.runs; run++) {
        const { dir, base } = makeProject(mode === 'with');
        const label = `${c.name} [${mode}${o.runs > 1 ? ' #' + run : ''}]`;
        if (!o.json) process.stdout.write(`${label} ... `);
        const t0 = Date.now();
        const r = spawnSync('bash', ['-c', cmd], {
          cwd: dir, encoding: 'utf8', timeout: o.timeout * 1000,
          env: { ...process.env, EVAL_PROMPT: c.prompt, EVAL_CASE: c.name, EVAL_MODE: mode },
        });
        const checks = score(c, dir, base);
        const passed = checks.filter((x) => x.ok).length;
        results.push({ case: c.name, mode, run, passed, total: checks.length, seconds: Math.round((Date.now() - t0) / 1000), agentExit: r.status, checks, dir: o.keep ? dir : undefined });
        if (!o.json) {
          console.log(`${passed}/${checks.length}${r.status !== 0 ? `  (agent exited ${r.status === null ? 'on timeout' : r.status})` : ''}`);
          for (const x of checks.filter((x) => !x.ok)) console.log(`    missed: ${x.says}${x.detail ? ' — ' + x.detail : ''}`);
          if (o.keep) console.log(`    kept: ${dir}`);
        }
        if (!o.keep) fs.rmSync(dir, { recursive: true, force: true });
      }
    }
  }

  // The summary: per case, the share of checks passed in each mode.
  const rate = (name, mode) => {
    const rs = results.filter((r) => r.case === name && r.mode === mode);
    if (!rs.length) return null;
    return rs.reduce((s, r) => s + r.passed, 0) / rs.reduce((s, r) => s + r.total, 0);
  };
  const pct = (x) => (x === null ? '  —  ' : `${Math.round(x * 100)}%`.padStart(5));
  if (o.json) {
    console.log(JSON.stringify(results, null, 2));
  } else {
    console.log('\n' + 'case'.padEnd(24) + modes.map((m) => m.padStart(9)).join('') + (modes.length === 2 ? '      gap' : ''));
    for (const c of cases) {
      const w = rate(c.name, 'with'), wo = rate(c.name, 'without');
      const cols = modes.map((m) => '    ' + pct(rate(c.name, m))).join('');
      const gap = modes.length === 2 && w !== null && wo !== null ? `    ${w - wo >= 0 ? '+' : ''}${Math.round((w - wo) * 100)}` : '';
      console.log(c.name.padEnd(24) + cols + gap);
    }
  }
  const outDir = path.join(__dirname, 'results');
  fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${new Date().toISOString().replace(/[:.]/g, '-')}-${o.cmd ? 'custom' : o.agent}.json`);
  fs.writeFileSync(outFile, JSON.stringify({ agent: o.cmd ? 'custom' : o.agent, cmd, runs: o.runs, results }, null, 2) + '\n');
  if (!o.json) console.log(`\nSaved ${path.relative(REPO, outFile)}`);
  const allWith = results.filter((r) => r.mode === 'with');
  process.exit(allWith.length && allWith.every((r) => r.passed === r.total) ? 0 : 1);
}

if (require.main === module) main();
module.exports = { globToRegex, judge };
