#!/usr/bin/env bash
# Hook: Capture diagnostics when a Skipper agent crashes
# Trigger: Post-tool-use on Bash failures that look like agent crashes

set -euo pipefail

# Read stdin for tool result context
INPUT="$(cat)"

# Check if this looks like an agent crash
if echo "$INPUT" | grep >/dev/null -i "panic\|segfault\|killed\|oom\|fatal\|crash"; then
    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    CRASH_DIR="${HOME}/.shipwright/crash-reports"
    mkdir -p "$CRASH_DIR"

    REPORT_FILE="${CRASH_DIR}/crash_${TIMESTAMP}.json"

    # Capture diagnostics
    cat > "$REPORT_FILE" << EOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "working_directory": "$(pwd)",
    "git_branch": "$(git branch --show-current 2>/dev/null || echo 'unknown')",
    "git_commit": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
    "error_context": $(echo "$INPUT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()[:2000]))" 2>/dev/null || echo '"capture_failed"'),
    "pipeline_state": "$(cat .claude/pipeline-state.md 2>/dev/null | head -20 | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '"none"')",
    "recent_commits": "$(git log --oneline -5 2>/dev/null | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '"none"')"
}
EOF

    echo "Crash report saved to $REPORT_FILE" >&2
fi
