#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { execSync, spawnSync } = require('child_process');

const CWD = process.cwd();

function fail(msg) {
  console.error(`✗ ${msg}`);
  process.exit(1);
}

function parseArgs(argv) {
  const args = { command: 'init', prefix: null, stack: 'TypeScript', protect: 'main,master', force: false };
  const rest = [];
  for (const a of argv) {
    if (a === '--force' || a === '-f') args.force = true;
    else if (a === '--help' || a === '-h') args.command = 'help';
    else if (a.startsWith('--prefix=')) args.prefix = a.slice('--prefix='.length);
    else if (a.startsWith('--stack=')) args.stack = a.slice('--stack='.length);
    else if (a.startsWith('--protect=')) args.protect = a.slice('--protect='.length);
    else rest.push(a);
  }
  if (rest[0]) args.command = rest[0];
  return args;
}

function printHelp() {
  console.log(`no-yolo-commits — an AI pre-commit reviewer + "no direct commits to main" guard

Usage:
  npx no-yolo-commits init [options]

Options:
  --prefix=NAME      Branch prefix used when auto-creating a branch off a
                      protected branch, e.g. --prefix=ACME -> ACME-<ts>-<slug>
                      (default: derived from package.json "name")
  --stack=TEXT        One-line description of the project handed to the AI
                      reviewer, e.g. --stack="Next.js + TypeScript + Postgres"
                      (default: "TypeScript")
  --protect=a,b,c     Comma-separated branch names that block direct commits
                      (default: "main,master")
  --force, -f         Overwrite an existing .husky/pre-commit
  --help, -h          Show this help

Requires the \`claude\` CLI on PATH to actually run the AI review — if it's
missing, the hook warns and lets the commit through (fails open).`);
}

function readPackageJson() {
  const pkgPath = path.join(CWD, 'package.json');
  if (!fs.existsSync(pkgPath)) {
    fail('No package.json in the current directory — run this from your project root.');
  }
  return { pkgPath, pkg: JSON.parse(fs.readFileSync(pkgPath, 'utf8')) };
}

function ensureGitRepo() {
  const result = spawnSync('git', ['rev-parse', '--is-inside-work-tree'], { cwd: CWD, stdio: 'pipe' });
  if (result.status !== 0) {
    fail('Not a git repository — run `git init` first.');
  }
}

function slugifyPrefix(name) {
  return (name || 'wip')
    .replace(/^@[^/]+\//, '') // drop npm scope
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, '')
    .slice(0, 12) || 'WIP';
}

function run(cmd, args) {
  console.log(`  $ ${cmd} ${args.join(' ')}`);
  const result = spawnSync(cmd, args, { cwd: CWD, stdio: 'inherit' });
  if (result.status !== 0) {
    fail(`\`${cmd} ${args.join(' ')}\` failed (exit ${result.status}).`);
  }
}

function init(args) {
  ensureGitRepo();
  const { pkgPath, pkg } = readPackageJson();

  const huskyDir = path.join(CWD, '.husky');
  const hookPath = path.join(huskyDir, 'pre-commit');

  if (fs.existsSync(hookPath) && !args.force) {
    fail(`${hookPath} already exists — pass --force to overwrite it.`);
  }

  const hasHusky =
    (pkg.devDependencies && pkg.devDependencies.husky) || (pkg.dependencies && pkg.dependencies.husky);

  if (!hasHusky) {
    console.log('→ Installing husky (devDependency)...');
    run('npm', ['install', '--save-dev', 'husky']);
  } else {
    console.log('✓ husky already a devDependency');
  }

  const freshPkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
  freshPkg.scripts = freshPkg.scripts || {};
  if (freshPkg.scripts.prepare !== 'husky') {
    freshPkg.scripts.prepare = 'husky';
    fs.writeFileSync(pkgPath, JSON.stringify(freshPkg, null, 2) + '\n');
    console.log('✓ set "scripts.prepare": "husky" in package.json');
  }

  console.log('→ Wiring up husky (git hooksPath)...');
  run('npx', ['husky']);

  const prefix = slugifyPrefix(args.prefix || freshPkg.name);
  const protectedBranches = args.protect
    .split(',')
    .map((b) => b.trim())
    .filter(Boolean)
    .join(' ');

  const templatePath = path.join(__dirname, '..', 'templates', 'pre-commit.sh');
  let hookScript = fs.readFileSync(templatePath, 'utf8');
  hookScript = hookScript
    .replace(/__STACK__/g, args.stack.replace(/"/g, '\\"'))
    .replace(/__PREFIX__/g, prefix)
    .replace(/__PROTECTED__/g, protectedBranches);

  fs.mkdirSync(huskyDir, { recursive: true });
  fs.writeFileSync(hookPath, hookScript);
  fs.chmodSync(hookPath, 0o755);

  console.log(`✓ wrote ${path.relative(CWD, hookPath)}`);
  console.log('');
  console.log('Done. New behavior on `git commit`:');
  console.log(`  - AI review of staged changes (needs \`claude\` on PATH) — blocks only on high-confidence issues`);
  console.log(`  - direct commits to [${protectedBranches}] auto-branch instead, as ${prefix}-<timestamp>-<slug>`);
  console.log('');
  console.log('Bypass for one commit: git commit --no-verify');
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.command === 'help') return printHelp();
  if (args.command === 'init') return init(args);
  console.error(`Unknown command "${args.command}"\n`);
  printHelp();
  process.exit(1);
}

main();
