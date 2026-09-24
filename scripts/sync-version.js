#!/usr/bin/env node
/**
 * Rewrites every pinned install tag in the docs to the version in package.json.
 * Runs from the npm "version" lifecycle, after package.json is bumped and before
 * npm commits and tags, so the docs always ship in the same commit as the tag.
 *
 *   node scripts/sync-version.js           rewrite and stage
 *   node scripts/sync-version.js --check   fail if any doc is behind
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const { version } = require(path.join(ROOT, 'package.json'));
const TAG = `v${version}`;
const PIN = /(kei-interactive-harness#)v\d+\.\d+\.\d+/g;
const DOCS = ['README.md', 'docs/SETUP.md', 'lib/templates/AGENTS.md', 'lib/templates/WORKFLOW.md'];

const check = process.argv.includes('--check');
const stale = [];
for (const rel of DOCS) {
  const file = path.join(ROOT, rel);
  if (!fs.existsSync(file)) continue;
  const before = fs.readFileSync(file, 'utf8');
  const after = before.replace(PIN, `$1${TAG}`);
  if (after === before) continue;
  stale.push(rel);
  if (!check) fs.writeFileSync(file, after);
}

if (check) {
  if (stale.length) {
    console.error(`Docs pin an old tag (want ${TAG}): ${stale.join(', ')}`);
    console.error('Run: node scripts/sync-version.js');
    process.exit(1);
  }
  process.exit(0);
}
if (stale.length) {
  execSync(`git add ${stale.map((f) => JSON.stringify(f)).join(' ')}`, { cwd: ROOT, stdio: 'inherit' });
  console.log(`Docs pinned to ${TAG}: ${stale.join(', ')}`);
}
