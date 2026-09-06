#!/usr/bin/env sh

# --- Secret scan on staged changes ---
# Cheap, deterministic, no dependency on `claude` being installed or
# working — runs regardless, so a leaked key doesn't slip through just
# because the AI reviewer below is unavailable. Blocks by default since
# a leaked credential is a different class of mistake than a code-quality
# nit; bypass with `git commit --no-verify` for a confirmed false positive.
if ! git diff --cached --quiet 2>/dev/null; then
  secret_hits="$(git diff --cached -U0 -- . 2>/dev/null | grep -E '^\+[^+]' | grep -E -i \
    -e '-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----' \
    -e 'AKIA[0-9A-Z]{16}' \
    -e 'xox[baprs]-[0-9A-Za-z-]{10,}' \
    -e '(api[_-]?key|secret|access[_-]?token|password|passwd)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9_/+=-]{16,}["'"'"']' \
    2>/dev/null || true)"

  env_files="$(git diff --cached --name-only -- . 2>/dev/null | grep -E '(^|/)\.env(\.[^.]+)?$' | grep -v -E '\.(example|sample|template|dist)$' || true)"

  if [ -n "$secret_hits" ] || [ -n "$env_files" ]; then
    echo ""
    echo "⛔ Possible secret(s) in staged changes:"
    if [ -n "$env_files" ]; then
      echo "$env_files" | while IFS= read -r f; do [ -n "$f" ] && echo "  - staged env file: $f"; done
    fi
    if [ -n "$secret_hits" ]; then
      echo "$secret_hits" | cut -c1-120 | while IFS= read -r l; do [ -n "$l" ] && echo "  - $l"; done
    fi
    echo ""
    echo "If this is a false positive: git commit --no-verify"
    exit 1
  fi
fi

# --- AI code review on staged changes ---
# Fails the commit only on real, high-confidence findings. If Claude is
# missing, times out, or errors, this fails OPEN (warns, does not block) —
# a broken/unavailable review must never be the only thing stopping commits.
#
# Skipped entirely when every staged file is a lockfile/generated asset —
# nothing there for a code reviewer to usefully say, and it's the case
# most likely to be a large, slow diff to hand an LLM for zero benefit.
review_diff_probe="$(git diff --cached -- . ':(exclude)package-lock.json' ':(exclude)yarn.lock' ':(exclude)pnpm-lock.yaml' ':(exclude)composer.lock' ':(exclude)Gemfile.lock' ':(exclude)*.svg' ':(exclude)*.png' ':(exclude)*.jpg' ':(exclude)*.jpeg' ':(exclude)*.gif' ':(exclude)*.webp' ':(exclude)*.ico' 2>/dev/null)"

if command -v claude >/dev/null 2>&1 && [ -n "$review_diff_probe" ]; then
  echo "→ Running AI code review on staged changes..."

  review_prompt="You are reviewing staged git changes before they are committed, for a __STACK__ project. Inspect the staged changes (run \`git diff --cached\` yourself; read full files with the Read tool when a diff hunk needs more surrounding context) and flag ONLY real, high-confidence problems: type-safety holes (any/unsafe casts), missing error handling at real failure points, obvious bugs, broken framework patterns, dead or unused code introduced by this diff, and any secret/API key/credential that looks like it's being committed.

Do NOT flag stylistic preferences. Do NOT flag pre-existing patterns already used elsewhere in this codebase (check before flagging). Do NOT invent issues — if you are not confident something is a real problem, leave it out. Respond with ONLY JSON matching the schema, nothing else."

  review_tmpfile="$(mktemp)"

  # No subshell wrapper here on purpose: `(claude ...; exit 0) &` would make
  # $! the wrapper's PID, not claude's — since the wrapper has more to do
  # after claude exits, the shell can't tail-exec it, so killing $review_pid
  # on timeout would kill the empty wrapper and leave claude itself running
  # orphaned. Backgrounding claude directly makes $! the real PID.
  claude -p "$review_prompt" \
    --output-format json \
    --json-schema '{"type":"object","properties":{"blocking_issues":{"type":"array","items":{"type":"string"}}},"required":["blocking_issues"]}' \
    --allowedTools "Bash(git diff*)" "Bash(git show*)" "Bash(git log*)" "Read" "Grep" "Glob" \
    --disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit" \
    --permission-mode bypassPermissions \
    __MODEL_ARGS__ \
    >"$review_tmpfile" 2>/dev/null &
  review_pid=$!
  (sleep 120; kill "$review_pid" >/dev/null 2>&1; exit 0) >/dev/null 2>&1 &
  review_watcher_pid=$!
  disown "$review_watcher_pid" >/dev/null 2>&1 || true

  wait "$review_pid" >/dev/null 2>&1 || true
  kill "$review_watcher_pid" >/dev/null 2>&1 || true
  wait "$review_watcher_pid" >/dev/null 2>&1 || true

  node -e '
    const fs = require("fs")
    try {
      const data = JSON.parse(fs.readFileSync(process.argv[1], "utf-8"))
      // An API/session error from claude itself is valid JSON with no
      // structured_output — falling back to [] there made a failed review
      // look identical to "no issues found" instead of "unavailable".
      if (data.is_error || !data.structured_output) {
        process.exit(2)
      }
      const issues = data.structured_output.blocking_issues || []
      if (issues.length > 0) {
        console.error("")
        console.error("⛔ AI review found blocking issues:")
        for (const i of issues) console.error("  - " + i)
        console.error("")
        console.error("Fix these, or commit anyway with `git commit --no-verify`.")
        process.exit(1)
      }
      process.exit(0)
    } catch (e) {
      process.exit(2)
    }
  ' "$review_tmpfile" && review_status=0 || review_status=$?
  rm -f "$review_tmpfile" 2>/dev/null || true

  if [ "$review_status" = "1" ]; then
    exit 1
  elif [ "$review_status" = "2" ]; then
    echo "⚠ AI review unavailable or timed out — continuing without it."
  else
    echo "✓ AI review found no blocking issues."
  fi
elif command -v claude >/dev/null 2>&1; then
  echo "→ Skipping AI review (only lockfile/generated-asset changes staged)."
fi

# --- Block direct commits to protected branches ---
# symbolic-ref first: on a brand-new repo's very first commit (no HEAD
# commit exists yet — an "unborn" branch) rev-parse --abbrev-ref HEAD
# fails and prints the literal string "HEAD" to stdout before erroring,
# which silently bypassed protection entirely on repo #1's commit #1.
# symbolic-ref resolves the branch name in that state; it only fails on
# a genuinely detached HEAD, where falling back to "HEAD" is correct
# (you can't be "on" a protected branch while detached).
branch="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

case " __PROTECTED__ " in
  *" $branch "*) ;;
  *) exit 0 ;;
esac

echo "⛔ Direct commits to '$branch' are blocked — creating a branch for this commit..."

fallback_slug() {
  echo "changes-$(date +%s | tail -c 5)"
}

slug=""

if command -v claude >/dev/null 2>&1; then
  diff="$(git diff --cached -- . ':(exclude)package-lock.json' ':(exclude)yarn.lock' ':(exclude)pnpm-lock.yaml' ':(exclude)*.svg' ':(exclude)*.png' 2>/dev/null | head -c 6000)"
  diff="${diff:-}"

  if [ -n "$diff" ]; then
    tmpfile="$(mktemp)"
    prompt="Summarize the following staged git diff as ONE short phrase in kebab-case (lowercase words separated by hyphens, no punctuation, no quotes), at most 8 words, describing what changed. Output ONLY the phrase, nothing else, no explanation."

    # Same reasoning as the review call above: background claude directly,
    # no subshell wrapper, so $! is the real PID the timeout can kill.
    printf '%s' "$diff" | claude -p "$prompt" __MODEL_ARGS__ >"$tmpfile" 2>/dev/null &
    claude_pid=$!
    (sleep 25; kill "$claude_pid" >/dev/null 2>&1; exit 0) >/dev/null 2>&1 &
    watcher_pid=$!
    disown "$watcher_pid" >/dev/null 2>&1 || true

    wait "$claude_pid" >/dev/null 2>&1 || true
    kill "$watcher_pid" >/dev/null 2>&1 || true
    wait "$watcher_pid" >/dev/null 2>&1 || true

    raw="$(cat "$tmpfile" 2>/dev/null || true)"
    rm -f "$tmpfile" 2>/dev/null || true

    slug="$(printf '%s' "$raw" \
      | tr '[:upper:]' '[:lower:]' \
      | tr -cs 'a-z0-9' '-' \
      | sed -e 's/^-*//' -e 's/-*$//' \
      | cut -c1-60)"
    slug="${slug:-}"
  fi
fi

if [ -z "$slug" ]; then
  slug="$(fallback_slug)"
fi

# The configured prefix is the literal word AUTO for global (git-template)
# installs, which serve many unrelated repos from one script — derive the
# prefix per-repo at commit time instead of baking one in at install time.
configured_prefix="__PREFIX__"
if [ "$configured_prefix" = "AUTO" ]; then
  prefix="$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null \
    | tr '[:lower:]' '[:upper:]' | tr -cs 'A-Z0-9' '-' | sed -e 's/^-*//' -e 's/-*$//' | cut -c1-20)"
  prefix="${prefix:-WIP}"
else
  prefix="$configured_prefix"
fi

timestamp="$(date +%s)"
new_branch="${prefix}-${timestamp}-${slug}"
new_branch="$(printf '%s' "$new_branch" | cut -c1-100)"

branch_err_file="$(mktemp)"
if ! git checkout -b "$new_branch" 2>"$branch_err_file"; then
  echo "✗ Failed to create branch '$new_branch':"
  cat "$branch_err_file" 2>/dev/null || true
  rm -f "$branch_err_file" 2>/dev/null || true
  echo "Commit aborted — create/switch to a feature branch manually and retry."
  exit 1
fi
rm -f "$branch_err_file" 2>/dev/null || true

echo "✓ Switched to '$new_branch' — continuing commit there."
