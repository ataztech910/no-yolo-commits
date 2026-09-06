#!/usr/bin/env sh
# Runs in GitHub Actions on a pull_request event. Reviews the PR's diff
# against its base branch: same secret scan + AI review the local pre-commit
# hook does, as a defense-in-depth check that isn't bypassable with
# `git commit --no-verify` or simply not having the hook installed locally.

STACK="${STACK:-TypeScript}"
MODEL_ARGS=""
if [ -n "${MODEL:-}" ]; then MODEL_ARGS="--model $MODEL"; fi

base_ref="${GITHUB_BASE_REF:-}"
if [ -z "$base_ref" ]; then
  echo "GITHUB_BASE_REF is empty — this action is meant to run on pull_request events. Skipping."
  exit 0
fi

git fetch --no-tags --depth=1 origin "$base_ref" >/dev/null 2>&1
merge_base="$(git merge-base "origin/$base_ref" HEAD 2>/dev/null)"
if [ -z "$merge_base" ]; then
  # Shallow fetch didn't reach a common ancestor — try a full fetch once
  # before giving up and diffing straight against the base branch tip.
  git fetch --no-tags origin "$base_ref" >/dev/null 2>&1
  merge_base="$(git merge-base "origin/$base_ref" HEAD 2>/dev/null)"
fi
merge_base="${merge_base:-origin/$base_ref}"

echo "Reviewing $merge_base...HEAD"

# --- secret scan (same patterns as the local pre-commit hook) ---
secret_hits="$(git diff "$merge_base"...HEAD -U0 -- . 2>/dev/null | grep -E '^\+[^+]' | grep -E -i \
  -e '-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----' \
  -e 'AKIA[0-9A-Z]{16}' \
  -e 'xox[baprs]-[0-9A-Za-z-]{10,}' \
  -e '(api[_-]?key|secret|access[_-]?token|password|passwd)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9_/+=-]{16,}["'"'"']' \
  2>/dev/null || true)"
env_files="$(git diff "$merge_base"...HEAD --name-only -- . 2>/dev/null | grep -E '(^|/)\.env(\.[^.]+)?$' | grep -v -E '\.(example|sample|template|dist)$' || true)"

if [ -n "$secret_hits" ] || [ -n "$env_files" ]; then
  echo "::error::Possible secret(s) found in this PR's diff"
  if [ -n "$env_files" ]; then
    echo "$env_files" | while IFS= read -r f; do [ -n "$f" ] && echo "::error::staged env file: $f"; done
  fi
  if [ -n "$secret_hits" ]; then
    echo "$secret_hits" | cut -c1-200 | while IFS= read -r l; do [ -n "$l" ] && echo "::error::$l"; done
  fi
  exit 1
fi

review_diff="$(git diff "$merge_base"...HEAD -- . ':(exclude)package-lock.json' ':(exclude)yarn.lock' ':(exclude)pnpm-lock.yaml' ':(exclude)composer.lock' ':(exclude)Gemfile.lock' ':(exclude)*.svg' ':(exclude)*.png' ':(exclude)*.jpg' ':(exclude)*.jpeg' ':(exclude)*.gif' ':(exclude)*.webp' ':(exclude)*.ico' 2>/dev/null)"

if [ -z "$review_diff" ]; then
  echo "Nothing to review (lockfile/generated-asset-only diff)."
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "::warning::claude CLI not found on PATH — skipping AI review"
  exit 0
fi

review_prompt="You are reviewing a pull request's diff before merge, for a $STACK project. Inspect the diff (run \`git diff ${merge_base}...HEAD\` yourself; read full files with the Read tool when a hunk needs more context) and flag ONLY real, high-confidence problems: type-safety holes, missing error handling at real failure points, obvious bugs, broken framework patterns, dead/unused code introduced by this diff, and any secret/API key/credential that looks like it's being committed.

Do NOT flag stylistic preferences. Do NOT flag pre-existing patterns already used elsewhere in this codebase. Do NOT invent issues — if you are not confident something is a real problem, leave it out. Respond with ONLY JSON matching the schema, nothing else."

review_tmpfile="$(mktemp)"

# Background claude directly (no subshell wrapper) so $! is its real PID and
# the timeout watcher below can actually kill it — see the local hook's
# comment on this for the failure mode this avoids.
claude -p "$review_prompt" \
  --output-format json \
  --json-schema '{"type":"object","properties":{"blocking_issues":{"type":"array","items":{"type":"string"}}},"required":["blocking_issues"]}' \
  --allowedTools "Bash(git diff*)" "Bash(git show*)" "Bash(git log*)" "Read" "Grep" "Glob" \
  --disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit" \
  --permission-mode bypassPermissions \
  $MODEL_ARGS \
  >"$review_tmpfile" 2>/dev/null &
review_pid=$!
(sleep 180; kill "$review_pid" >/dev/null 2>&1; exit 0) >/dev/null 2>&1 &
watcher_pid=$!
disown "$watcher_pid" >/dev/null 2>&1 || true

wait "$review_pid" >/dev/null 2>&1 || true
kill "$watcher_pid" >/dev/null 2>&1 || true
wait "$watcher_pid" >/dev/null 2>&1 || true

node -e '
  const fs = require("fs")
  try {
    const data = JSON.parse(fs.readFileSync(process.argv[1], "utf-8"))
    if (data.is_error || !data.structured_output) process.exit(2)
    const issues = data.structured_output.blocking_issues || []
    if (issues.length > 0) {
      for (const i of issues) console.log("::error::" + i)
      process.exit(1)
    }
    process.exit(0)
  } catch (e) {
    process.exit(2)
  }
' "$review_tmpfile" && status=0 || status=$?
rm -f "$review_tmpfile" 2>/dev/null || true

if [ "$status" = "1" ]; then
  echo "AI review found blocking issues (see annotations above)."
  exit 1
elif [ "$status" = "2" ]; then
  echo "::warning::AI review unavailable or timed out — not blocking the PR."
  exit 0
else
  echo "AI review found no blocking issues."
  exit 0
fi
