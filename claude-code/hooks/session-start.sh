#!/usr/bin/env bash
# SessionStart hook — inject Shipwright project context at session start
# Timeout: 5s | Exit: always 0 (never blocks)
set -euo pipefail

# Only activate in Shipwright-managed projects
CLAUDE_DIR=".claude"
[[ -f "$CLAUDE_DIR/pipeline-state.md" || -f "$CLAUDE_DIR/CLAUDE.md" ]] || exit 0

echo "Shipwright project detected."

# Show last pipeline status if available
if [[ -f "$CLAUDE_DIR/pipeline-state.md" ]]; then
    echo "Last pipeline status:"
    head -5 "$CLAUDE_DIR/pipeline-state.md" 2>/dev/null || true
    echo ""
fi

# Remind about project conventions
for f in CLAUDE.md "$CLAUDE_DIR/CLAUDE.md" AGENTS.md; do
    if [[ -f "$f" ]]; then
        echo "Project conventions available in $f"
        break
    fi
done

exit 0
