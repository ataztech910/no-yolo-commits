# no-yolo-commits

[![npm version](https://img.shields.io/npm/v/no-yolo-commits.svg)](https://www.npmjs.com/package/no-yolo-commits)
[![license](https://img.shields.io/npm/l/no-yolo-commits.svg)](./LICENSE)

You know that feeling when you `git commit -m "fix"` straight onto `main` at 2am, staged changes you half-remember writing, and hit enter before your brain finishes the sentence "wait, should I—"?

This stops that.

```bash
npx no-yolo-commits init
```

One command. On every commit from now on:

1. **A secret scan runs first, always.** Private keys, AWS/Slack-shaped tokens, a staged `.env` — caught with plain regex, zero dependency on any AI CLI being installed or working. Blocks by default; a leaked credential isn't the kind of mistake you want an "unavailable reviewer" to quietly let through.
2. **An AI actually reads your diff** (via the [`claude`](https://claude.com/claude-code) CLI) and blocks the commit — but only for real, high-confidence problems. Not vibes, not "you could refactor this." If the reviewer is missing, slow, or having a bad day, it fails **open** — a flaky reviewer should never be the reason your commit is stuck. Skipped automatically when everything staged is a lockfile or generated asset, so bumping `package-lock.json` doesn't cost you a 2-minute wait.
3. **`main`/`master` become look-but-don't-touch.** Commit straight there and instead of yelling at you, it just makes you a branch — `ACME-1788716508-fix-the-thing-you-were-actually-fixing`, ready to go, commit already on it. It even wrote the branch name from your diff.

No dashboard. No config file to argue with. No runtime dependencies — it's shell scripts wearing a [husky](https://typicode.github.io/husky/) trenchcoat.

## Install

```bash
npx no-yolo-commits init
```

That's the whole install, per project. It will, in order:

- add `husky` as a devDependency (if you don't have it)
- set `"scripts.prepare": "husky"` in `package.json`
- drop `.husky/pre-commit` into your repo

### Or install it once, everywhere

If you're the "I have thirty repos and I am not doing this thirty times" type:

```bash
npx no-yolo-commits init --global
```

This wires up git's own [hook template mechanism](https://git-scm.com/docs/git-init#_template_directory) (`git config --global init.templateDir`) — every `git init` and `git clone` from then on gets the hook automatically, no husky, no per-project npm install. The branch prefix is derived from each repo's folder name at commit time (since one script now serves every project you touch).

Already-cloned repos won't retroactively pick it up — re-run `git init` inside one (safe, doesn't touch history or remotes) to copy it in. A project that later runs the regular per-project `init` gets its own `.husky/pre-commit`, which takes precedence over the global hook.

## Make it yours

```bash
npx no-yolo-commits init \
  --prefix=ACME \
  --stack="Next.js + TypeScript + Postgres" \
  --protect=main,master,release \
  --model=haiku
```

| Flag | Default | Does what it says |
|---|---|---|
| `--prefix` | your `package.json` name, shouted in caps (or `AUTO`, per-repo, in `--global` mode) | prefix for the auto-branch name |
| `--stack` | `TypeScript` | tells the reviewer what it's actually looking at, so findings are relevant instead of generic |
| `--protect` | `main,master` | which branches you're not allowed to just casually commit to |
| `--model` | claude's default | passed through as `--model <name>` to every `claude` call — point it at a cheaper/faster model if you commit a lot |
| `--global`, `-g` | off | install into git's global hook template instead of this one project |
| `--force`, `-f` | off | steamroll an existing hook |

## Also enforce it in CI

A local hook is a courtesy, not a wall — `--no-verify` exists, and a fresh clone hasn't run `npm install` yet. For the same checks on every pull request regardless of what happened locally:

```yaml
# .github/workflows/no-yolo-commits.yml
on: pull_request
jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: ataztech910/no-yolo-commits@main
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          stack: "Next.js + TypeScript + Postgres"
```

Same secret scan, same AI review, run against the PR's diff against its base branch — annotated inline on the PR, fails the check on real findings.

## The eject button

This is a guardrail, not a cage. Bad day, emergency hotfix, you know exactly what you're doing:

```bash
git commit --no-verify
```

No questions asked. No shame either — that's what it's there for.

## Why this exists

Because I kept copy-pasting the same `.husky/pre-commit` into every new project and hand-editing the branch prefix like some kind of caveman. Now it's `npx` and thirty seconds — and it reviews its own commits, because it would be pretty funny if it didn't.

## License

MIT — do whatever you want with it.
