#!/usr/bin/env bash
# Custom file suggestion for Claude Code @ autocomplete
# Surfaces Shipwright-specific files for quick access
set -euo pipefail

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

# Core config files
for f in \
    ".claude/pipeline-state.md" \
    ".claude/daemon-config.json" \
    ".claude/fleet-config.json" \
    ".claude/loop-state.md" \
    ".claude/managed-mcp.json" \
    ".claude/settings.json" \
    ".claude/CLAUDE.md" \
    "CLAUDE.md" \
    "AGENTS.md" \
    "CHANGELOG.md"; do
    [[ -f "$PROJECT_ROOT/$f" ]] && echo "$f"
done

# Agent definitions
for f in "$PROJECT_ROOT"/.claude/agents/*.md; do
    [[ -f "$f" ]] && echo ".claude/agents/$(basename "$f")"
done

# Schemas
for f in "$PROJECT_ROOT"/schemas/*.json; do
    [[ -f "$f" ]] && echo "schemas/$(basename "$f")"
done

# Pipeline artifacts (most recent)
if [[ -d "$PROJECT_ROOT/.claude/pipeline-artifacts" ]]; then
    for f in plan.md design.md composed-pipeline.json; do
        [[ -f "$PROJECT_ROOT/.claude/pipeline-artifacts/$f" ]] && echo ".claude/pipeline-artifacts/$f"
    done
fi

# Loop logs (latest iteration)
if [[ -d "$PROJECT_ROOT/.claude/loop-logs" ]]; then
    # shellcheck disable=SC2012
    ls -t "$PROJECT_ROOT/.claude/loop-logs"/iteration-*.log 2>/dev/null | head -3 | while read -r f; do
        echo ".claude/loop-logs/$(basename "$f")"
    done
fi
