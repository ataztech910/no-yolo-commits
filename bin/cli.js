#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

const CWD = process.cwd();

function fail(msg) {
  console.error(`✗ ${msg}`);
  process.exit(1);
}

function parseArgs(argv) {
  const args = {
    command: 'init',
    prefix: null,
    stack: 'TypeScript',
    protect: 'main,master',
    model: null,
    global: false,
    force: false,
  };
  const rest = [];
  for (const a of argv) {
    if (a === '--force' || a === '-f') args.force = true;
    else if (a === '--global' || a === '-g') args.global = true;
    else if (a === '--help' || a === '-h') args.command = 'help';
    else if (a.startsWith('--prefix=')) args.prefix = a.slice('--prefix='.length);
    else if (a.startsWith('--stack=')) args.stack = a.slice('--stack='.length);
    else if (a.startsWith('--protect=')) args.protect = a.slice('--protect='.length);
    else if (a.startsWith('--model=')) args.model = a.slice('--model='.length);
    else rest.push(a);
  }
  if (rest[0]) args.command = rest[0];
  return args;
}

function printHelp() {
  console.log(`no-yolo-commits — an AI pre-commit reviewer + "no direct commits to main" guard

Usage:
  npx no-yolo-commits init [options]          per-project install (via husky)
  npx no-yolo-commits init --global [options]  install once, applies to every
                                                new \`git init\`/\`git clone\`

Options:
  --prefix=NAME      Branch prefix for auto-created branches, e.g.
                      --prefix=ACME -> ACME-<ts>-<slug>. In --global mode
                      this defaults to AUTO (derived from each repo's
                      directory name at commit time, since one global script
                      serves many repos); per-project it defaults to your
                      package.json "name".
  --stack=TEXT        One-line description of the project handed to the AI
                      reviewer, e.g. --stack="Next.js + TypeScript + Postgres"
                      (default: "TypeScript")
  --protect=a,b,c     Comma-separated branch names that block direct commits
                      (default: "main,master")
  --model=NAME        Pass --model NAME through to every \`claude\` invocation
                      (cost/speed control — e.g. --model=haiku)
  --global, -g        Install into git's global hook template
                      (~/.git-templates by default, or your existing
                      \`git config --global init.templateDir\`) instead of
                      this one project. Existing repos need \`git init\`
                      re-run inside them to pick it up; a project that later
                      runs the per-project \`init\` (husky) takes precedence
                      over the global hook.
  --force, -f         Overwrite an existing hook
  --help, -h          Show this help

Every commit also gets a zero-dependency secret scan (private keys, AWS/Slack
tokens, staged .env files, etc.) that blocks regardless of whether \`claude\`
is installed.

Requires the \`claude\` CLI on PATH to actually run the AI review — if it's
missing, the hook warns and lets the commit through (fails open).`);
}

function slugifyPrefix(name) {
  return (
    (name || 'wip')
      .replace(/^@[^/]+\//, '') // drop npm scope
      .toUpperCase()
      .replace(/[^A-Z0-9]+/g, '')
      .slice(0, 12) || 'WIP'
  );
}

function buildHookScript(args, defaultPrefixSource) {
  const prefix = args.prefix ? slugifyPrefix(args.prefix) : args.global ? 'AUTO' : slugifyPrefix(defaultPrefixSource);
  const protectedBranches = args.protect
    .split(',')
    .map((b) => b.trim())
    .filter(Boolean)
    .join(' ');
  const modelArgs = args.model ? `--model ${args.model}` : '';

  const templatePath = path.join(__dirname, '..', 'templates', 'pre-commit.sh');
  let hookScript = fs.readFileSync(templatePath, 'utf8');
  hookScript = hookScript
    .replace(/__STACK__/g, args.stack.replace(/"/g, '\\"'))
    .replace(/__PREFIX__/g, prefix)
    .replace(/__PROTECTED__/g, protectedBranches)
    .replace(/__MODEL_ARGS__/g, modelArgs);

  return { hookScript, prefix, protectedBranches };
}

function run(cmd, cmdArgs) {
  console.log(`  $ ${cmd} ${cmdArgs.join(' ')}`);
  const result = spawnSync(cmd, cmdArgs, { cwd: CWD, stdio: 'inherit' });
  if (result.status !== 0) {
    fail(`\`${cmd} ${cmdArgs.join(' ')}\` failed (exit ${result.status}).`);
  }
}

function initProject(args) {
  const gitCheck = spawnSync('git', ['rev-parse', '--is-inside-work-tree'], { cwd: CWD, stdio: 'pipe' });
  if (gitCheck.status !== 0) fail('Not a git repository — run `git init` first.');

  const pkgPath = path.join(CWD, 'package.json');
  if (!fs.existsSync(pkgPath)) {
    fail('No package.json in the current directory — run this from your project root (or use --global).');
  }
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));

  const huskyDir = path.join(CWD, '.husky');
  const hookPath = path.join(huskyDir, 'pre-commit');

  if (fs.existsSync(hookPath) && !args.force) {
    fail(`${hookPath} already exists — pass --force to overwrite it.`);
  }

  const hasHusky = (pkg.devDependencies && pkg.devDependencies.husky) || (pkg.dependencies && pkg.dependencies.husky);
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

  const { hookScript, prefix, protectedBranches } = buildHookScript(args, freshPkg.name);

  fs.mkdirSync(huskyDir, { recursive: true });
  fs.writeFileSync(hookPath, hookScript);
  fs.chmodSync(hookPath, 0o755);

  console.log(`✓ wrote ${path.relative(CWD, hookPath)}`);
  printSummary(prefix, protectedBranches);
}

function initGlobal(args) {
  const configuredDir = spawnSync('git', ['config', '--global', 'init.templateDir'], { stdio: 'pipe' });
  const templateDir =
    configuredDir.status === 0 && configuredDir.stdout.toString().trim()
      ? configuredDir.stdout.toString().trim()
      : path.join(os.homedir(), '.git-templates');

  const hooksDir = path.join(templateDir, 'hooks');
  const hookPath = path.join(hooksDir, 'pre-commit');

  if (fs.existsSync(hookPath) && !args.force) {
    fail(`${hookPath} already exists — pass --force to overwrite it.`);
  }

  const { hookScript, prefix, protectedBranches } = buildHookScript(args, null);

  fs.mkdirSync(hooksDir, { recursive: true });
  fs.writeFileSync(hookPath, hookScript);
  fs.chmodSync(hookPath, 0o755);
  console.log(`✓ wrote ${hookPath}`);

  run('git', ['config', '--global', 'init.templateDir', templateDir]);

  console.log('');
  console.log(`Every \`git init\` and \`git clone\` from now on picks this up automatically.`);
  console.log(`Already-existing local repos won't retroactively get it — re-run \`git init\``);
  console.log(`inside one (safe, doesn't touch history/remotes) to copy it in, or run`);
  console.log(`\`npx no-yolo-commits init\` there for the per-project (husky) version, which`);
  console.log(`takes precedence over this global hook if both are present.`);
  printSummary(prefix, protectedBranches);
}

function printSummary(prefix, protectedBranches) {
  console.log('');
  console.log('Done. New behavior on `git commit`:');
  console.log('  - secret scan on staged changes (private keys, tokens, .env files) — always on');
  console.log('  - AI review of staged changes (needs `claude` on PATH) — blocks only on high-confidence issues');
  console.log(`  - direct commits to [${protectedBranches}] auto-branch instead, as ${prefix}-<timestamp>-<slug>`);
  console.log('');
  console.log('Bypass for one commit: git commit --no-verify');
}

function init(args) {
  if (args.global) return initGlobal(args);
  return initProject(args);
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
