#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# teammate-idle.sh — Quality gate: block idle if typecheck fails
# ═══════════════════════════════════════════════════════════════════════
#
# Runs when a Claude Code teammate goes idle. If there are TypeScript
# errors, exit code 2 tells Claude to keep working and fix them first.
#
# Install:
#   1. Copy this file to ~/.claude/hooks/teammate-idle.sh
#   2. chmod +x ~/.claude/hooks/teammate-idle.sh
#   3. Add to ~/.claude/settings.json:
#      "hooks": {
#        "teammate-idle": {
#          "command": "~/.claude/hooks/teammate-idle.sh",
#          "timeout": 30000
#        }
#      }
#
# Exit codes:
#   0 = allow idle (typecheck passed)
#   2 = keep working (typecheck failed — fix errors first)
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

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
  # No package.json found — not a TypeScript project, allow idle
  exit 0
}

cd "$PROJECT_ROOT"

# Check if this project uses TypeScript
if [[ ! -f "tsconfig.json" ]]; then
  exit 0
fi

# Run typecheck — try pnpm first, fall back to npx
if command -v pnpm &>/dev/null && [[ -f "pnpm-lock.yaml" ]]; then
  pnpm typecheck 2>&1 || {
    echo "::error::TypeScript errors found. Fix them before going idle."
    exit 2
  }
elif command -v npm &>/dev/null; then
  npx tsc --noEmit 2>&1 || {
    echo "::error::TypeScript errors found. Fix them before going idle."
    exit 2
  }
else
  # No package manager available — skip check, allow idle
  exit 0
fi

exit 0
