#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# task-completed.sh — Quality gate: block task completion if quality fails
# ═══════════════════════════════════════════════════════════════════════
#
# Runs when a Claude Code agent marks a task as completed. Checks lint
# and tests on changed files. If any check fails, exit code 2 tells
# Claude the task isn't really done yet.
#
# Install:
#   1. Copy this file to ~/.claude/hooks/task-completed.sh
#   2. chmod +x ~/.claude/hooks/task-completed.sh
#   3. Add to ~/.claude/settings.json:
#      "hooks": {
#        "TaskCompleted": [
#          {
#            "hooks": [
#              {
#                "type": "command",
#                "command": "~/.claude/hooks/task-completed.sh",
#                "timeout": 60
#              }
#            ]
#          }
#        ]
#      }
#
# Exit codes:
#   0 = allow completion (all checks passed)
#   2 = block completion (fix issues first)
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

# Read hook input (JSON on stdin) — contains session_id, cwd, etc.
INPUT=$(cat)
HOOK_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -n "$HOOK_CWD" ]]; then
  cd "$HOOK_CWD"
fi

FAILED=0

# Find the project root (walk up from cwd looking for package.json)
find_project_root() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/package.json" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

PROJECT_ROOT="$(find_project_root)" || {
  # No package.json found — not a JS/TS project, allow completion
  exit 0
}

cd "$PROJECT_ROOT"

# ─── Step 1: Lint changed files ──────────────────────────────────────

# Get files changed relative to HEAD (staged + unstaged)
CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null || true)
if [[ -z "$CHANGED_FILES" ]]; then
  # Also check staged files not yet committed
  CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || true)
fi

# Filter to lintable files (ts, tsx, js, jsx)
LINT_FILES=$(echo "$CHANGED_FILES" | grep -E '\.(ts|tsx|js|jsx)$' || true)

if [[ -n "$LINT_FILES" ]]; then
  echo "Linting $(echo "$LINT_FILES" | wc -l | tr -d ' ') changed file(s)..."

  # Build file list as arguments (handle spaces in filenames)
  LINT_ARGS=()
  while IFS= read -r file; do
    [[ -f "$file" ]] && LINT_ARGS+=("$file")
  done <<< "$LINT_FILES"

  if [[ ${#LINT_ARGS[@]} -gt 0 ]]; then
    if command -v pnpm &>/dev/null && [[ -f "pnpm-lock.yaml" ]]; then
      pnpm eslint --no-error-on-unmatched-pattern "${LINT_ARGS[@]}" 2>&1 || {
        echo "::error::Lint errors in changed files."
        FAILED=1
      }
    elif npx --no-install eslint --version &>/dev/null 2>&1; then
      npx eslint --no-error-on-unmatched-pattern "${LINT_ARGS[@]}" 2>&1 || {
        echo "::error::Lint errors in changed files."
        FAILED=1
      }
    else
      echo "ESLint not available — skipping lint check."
    fi
  fi
else
  echo "No lintable files changed — skipping lint."
fi

# ─── Step 2: Run related tests ───────────────────────────────────────

# Find test files related to changed source files
TEST_FILES=()
while IFS= read -r file; do
  [[ -z "$file" ]] && continue

  # Skip if file is itself a test
  if [[ "$file" =~ \.(test|spec)\.(ts|tsx|js|jsx)$ ]]; then
    [[ -f "$file" ]] && TEST_FILES+=("$file")
    continue
  fi

  # Look for corresponding test file
  base="${file%.*}"
  ext="${file##*.}"
  for pattern in "${base}.test.${ext}" "${base}.spec.${ext}"; do
    [[ -f "$pattern" ]] && TEST_FILES+=("$pattern")
  done

  # Also check __tests__ directory
  dir="$(dirname "$file")"
  name="$(basename "$file")"
  namebase="${name%.*}"
  for pattern in "${dir}/__tests__/${namebase}.test.${ext}" "${dir}/__tests__/${namebase}.spec.${ext}"; do
    [[ -f "$pattern" ]] && TEST_FILES+=("$pattern")
  done
done <<< "$CHANGED_FILES"

if [[ ${#TEST_FILES[@]} -gt 0 ]]; then
  # Deduplicate (bash 3.2 compatible — no readarray)
  _deduped=()
  while IFS= read -r _f; do
    [[ -n "$_f" ]] && _deduped+=("$_f")
  done < <(printf '%s\n' "${TEST_FILES[@]}" | sort -u)
  TEST_FILES=("${_deduped[@]}")

  echo "Running ${#TEST_FILES[@]} related test file(s)..."

  if command -v pnpm &>/dev/null && [[ -f "pnpm-lock.yaml" ]]; then
    pnpm vitest run --reporter=verbose "${TEST_FILES[@]}" 2>&1 || {
      echo "::error::Tests failed for changed files."
      FAILED=1
    }
  elif npx --no-install vitest --version &>/dev/null 2>&1; then
    npx vitest run --reporter=verbose "${TEST_FILES[@]}" 2>&1 || {
      echo "::error::Tests failed for changed files."
      FAILED=1
    }
  elif npx --no-install jest --version &>/dev/null 2>&1; then
    npx jest --bail "${TEST_FILES[@]}" 2>&1 || {
      echo "::error::Tests failed for changed files."
      FAILED=1
    }
  else
    echo "No test runner (vitest/jest) available — skipping tests."
  fi
else
  echo "No related test files found — skipping tests."
fi

# ─── Result ───────────────────────────────────────────────────────────

if [[ "$FAILED" -ne 0 ]]; then
  echo ""
  echo "Task completion blocked — fix the issues above first."
  exit 2
fi

echo "All quality checks passed."
exit 0
