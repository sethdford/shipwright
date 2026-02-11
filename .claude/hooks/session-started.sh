#!/usr/bin/env bash
# Hook: SessionStarted — Context loading on agent session start

# Show pipeline state if exists
if [[ -f ".claude/pipeline-state.md" ]]; then
    echo "=== Active Pipeline ==="
    head -20 ".claude/pipeline-state.md"
    echo ""
fi

# Show recent failures from memory
if [[ -x "scripts/sw-memory.sh" ]]; then
    recent=$(bash scripts/sw-memory.sh show --recent 3 2>/dev/null) || true
    if [[ -n "$recent" ]]; then
        echo "=== Recent Failures ==="
        echo "$recent" | head -10
        echo ""
    fi
fi

# Show active issue count
if command -v gh &>/dev/null && [[ -z "${NO_GITHUB:-}" ]]; then
    issue_count=$(gh issue list --label "shipwright" --state open --json number -q 'length' 2>/dev/null) || true
    if [[ -n "$issue_count" ]]; then
        echo "=== Active Issues: ${issue_count:-0} ==="
    fi
fi

# Show budget remaining
if [[ -x "scripts/sw-cost.sh" ]]; then
    budget=$(bash scripts/sw-cost.sh remaining-budget 2>/dev/null) || true
    if [[ -n "$budget" ]]; then
        echo "=== Budget Remaining: $budget ==="
    fi
fi

exit 0
