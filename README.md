# no-yolo-commits

[![npm version](https://img.shields.io/npm/v/no-yolo-commits.svg)](https://www.npmjs.com/package/no-yolo-commits)
[![license](https://img.shields.io/npm/l/no-yolo-commits.svg)](./LICENSE)

You know that feeling when you `git commit -m "fix"` straight onto `main` at 2am, staged changes you half-remember writing, and hit enter before your brain finishes the sentence "wait, should I—"?

This stops that.

```bash
npx no-yolo-commits init
```

One command. Two things happen on every commit from now on:

1. **An AI actually reads your diff** (via the [`claude`](https://claude.com/claude-code) CLI) and blocks the commit — but only for real, high-confidence problems. Not vibes, not "you could refactor this." Type-safety holes, bugs that will actually bite, broken framework patterns. If the reviewer is missing, slow, or having a bad day, it fails **open** — a flaky linter should never be the reason your commit is stuck.
2. **`main` and `master` become look-but-don't-touch.** Try to commit straight there and instead of yelling at you, it just... makes you a branch. `ACME-1788716508-fix-the-thing-you-were-actually-fixing`, ready to go, commit already on it. You didn't even have to think of a branch name — the AI wrote that from your diff too.

No dashboard. No config file to argue with. No dependencies at runtime — it's a ~150-line shell script wearing a `husky` trenchcoat.

## Install

```bash
npx no-yolo-commits init
```

That's the whole install. It will, in order:

- add `husky` as a devDependency (if you don't have it)
- set `"scripts.prepare": "husky"` in `package.json`
- drop `.husky/pre-commit` into your repo

## Make it yours

```bash
npx no-yolo-commits init \
  --prefix=ACME \
  --stack="Next.js + TypeScript + Postgres" \
  --protect=main,master,release
```

| Flag | Default | Does what it says |
|---|---|---|
| `--prefix` | your `package.json` name, shouted in caps | prefix for the auto-branch name |
| `--stack` | `TypeScript` | tells the reviewer what it's actually looking at, so findings are relevant instead of generic |
| `--protect` | `main,master` | which branches you're not allowed to just casually commit to |
| `--force`, `-f` | off | steamroll an existing `.husky/pre-commit` |

## The eject button

This is a guardrail, not a cage. Bad day, emergency hotfix, you know exactly what you're doing:

```bash
git commit --no-verify
```

No questions asked. No shame either — that's what it's there for.

## Why this exists

Because I kept copy-pasting the same `.husky/pre-commit` into every new project and hand-editing the branch prefix like some kind of caveman. Now it's `npx` and thirty seconds.

## License

MIT — do whatever you want with it.
