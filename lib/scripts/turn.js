#!/usr/bin/env node
/**
 * harness turn: the end-of-turn check.
 *
 * Runs when the agent finishes a turn (a Cursor `stop` hook, a Claude Code
 * `Stop` hook) and hands back anything the fast checks would block, so the
 * agent fixes it in the same turn, before you look. You never see the problem.
 *
 * Built for small interactive bites, so three things matter more than coverage:
 *
 *   fast      Only the instant checks: boundaries and stack. No ratchet (it
 *             writes and stages the baseline), no gitleaks --staged (nothing
 *             is staged mid-turn), no types, no tests. Those stay at commit,
 *             push, and the pull request, where they already run.
 *   scoped    Only blocks that name a file changed since the last commit. An
 *             existing codebase with old findings would otherwise interrupt
 *             every turn with problems this turn did not cause.
 *   bounded   One follow-up per turn at most. If the fix itself trips a check,
 *             the commit hook still has it; the agent does not get to loop.
 *
 *   harness turn                  print blocks for changed files; exit 1 if any
 *   harness turn --agent claude   Claude Code Stop hook: exit 2 with the blocks
 *                                 on stderr, which Claude reads and acts on
 *   harness turn --agent cursor   Cursor stop hook: {"followup_message": ...}
 *
 * HARNESS_DISABLE="turn" in .harness/config.sh switches it off; sync then
 * removes the hook entries too.
 */

'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = process.env.HARNESS_PROJECT_ROOT || process.cwd();
const LIB = process.env.HARNESS_LIB || path.join(__dirname, '..');

const args = process.argv.slice(2);
const agentIdx = args.indexOf('--agent');
const AGENT = agentIdx >= 0 ? args[agentIdx + 1] : null;

function readStdin() {
  if (!AGENT) return {};
  try { return JSON.parse(fs.readFileSync(0, 'utf8') || '{}'); } catch { return {}; }
}

function disabled(id) {
  try {
    const cfg = fs.readFileSync(path.join(ROOT, '.harness', 'config.sh'), 'utf8');
    const m = cfg.match(/^\s*HARNESS_DISABLE=["']?([^"'\n#]*)/m);
    return m ? m[1].split(/\s+/).includes(id) : false;
  } catch { return false; }
}

/** Nothing to say. Each agent wants silence expressed its own way. */
function quiet() {
  if (AGENT === 'cursor') process.stdout.write('{}\n');
  if (!AGENT) console.log('Nothing blocked in files changed since the last commit.');
  process.exit(0);
}

/** Files touched since the last commit, tracked or not, relative to ROOT. */
function changedFiles() {
  const r = spawnSync('git', ['status', '--porcelain=v1', '-uall', '-z'], { cwd: ROOT, encoding: 'utf8' });
  if (r.status !== 0) return null;
  const out = new Set();
  const parts = r.stdout.split('\0').filter(Boolean);
  for (let i = 0; i < parts.length; i++) {
    const code = parts[i].slice(0, 2);
    out.add(parts[i].slice(3));
    if (code[0] === 'R' || code[0] === 'C') i++;   // rename: the next entry is the old path
  }
  return out;
}

const stripAnsi = (s) => s.replace(/\x1b\[[0-9;]*m/g, '');

/**
 * Split check output into blocks: a BLOCKED line plus the indented lines under
 * it. Notes are dropped; they never block a commit, so they never interrupt a
 * turn either.
 */
function blocks(output) {
  const groups = [];
  let cur = null;
  for (const line of stripAnsi(output).split('\n')) {
    if (line.startsWith('BLOCKED:')) { cur = [line]; groups.push(cur); }
    else if (cur && /^\s+\S/.test(line)) cur.push(line);
    else cur = null;
  }
  return groups.map((g) => g.join('\n'));
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Does this block name one of the files? A whole path, not a substring, so a
 *  change to a.ts does not claim a finding in data.ts. */
function mentionsAny(text, files) {
  for (const f of files) {
    if (new RegExp('(^|\\s)(\\./)?' + escapeRe(f) + '(?=[:\\s]|$)', 'm').test(text)) return true;
  }
  return false;
}

// ------------------------------------------------------------------ main --

const input = readStdin();

// Loop guards. Claude Code sets stop_hook_active when this stop was itself
// caused by a stop hook; Cursor counts its automatic follow-ups in loop_count.
if (AGENT === 'claude' && input.stop_hook_active) quiet();
if (AGENT === 'cursor' && ((input.loop_count || 0) >= 1 || (input.status && input.status !== 'completed'))) quiet();
if (disabled('turn')) quiet();

const changed = changedFiles();
if (!changed || changed.size === 0) quiet();

const env = { ...process.env, HARNESS_PROJECT_ROOT: ROOT, HARNESS_LIB: LIB };
let found = [];
for (const script of ['check-boundaries.sh', 'check-stack.sh']) {
  const r = spawnSync('bash', [path.join(LIB, 'scripts', script)], { cwd: ROOT, env, encoding: 'utf8' });
  if (r.status === 0) continue;
  found = found.concat(blocks((r.stdout || '') + (r.stderr || '')).filter((b) => mentionsAny(b, changed)));
}

if (!found.length) quiet();

const message = [
  `The harness blocks ${found.length === 1 ? 'one thing' : found.length + ' things'} in files changed this turn. ` +
  'These are the checks that would stop the commit. Fix them now, in this turn.',
  '',
  ...found,
  '',
  'If one is deliberate, use the escape comment the message names, with a reason ' +
  '(for example // @public-route: webhook, verified by signature). Do not disable the ' +
  'check or suggest --no-verify. The rows in the contract table in AGENTS.md explain each one.',
].join('\n');

if (AGENT === 'claude') {
  process.stderr.write(message + '\n');
  process.exit(2);
}
if (AGENT === 'cursor') {
  process.stdout.write(JSON.stringify({ followup_message: message }) + '\n');
  process.exit(0);
}
console.log(message);
process.exit(1);
