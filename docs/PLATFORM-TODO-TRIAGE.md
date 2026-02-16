# Platform TODO/FIXME/HACK Triage (Phase 4)

**Date:** 2026-02-16  
**Source:** `rg -n "TODO|FIXME|HACK" scripts/ docs/ config/ .github/ .claude/` (comment-style markers only)

This document categorizes all TODO/FIXME/HACK comment markers found in the codebase. Only actual technical-debt comment markers are included (not variable names like `STATUS_TODO`, grep patterns, or documentation references).

## Summary by Category

| Category      | Count |
| ------------- | ----- |
| fix-now       | 0     |
| github-issue  | 4     |
| accepted-debt | 3     |
| stale         | 0     |
| **Total**     | **7** |

## Full Triage Table

| File                          | Line | Marker | Text                                                                | Category      |
| ----------------------------- | ---- | ------ | ------------------------------------------------------------------- | ------------- |
| scripts/sw-scale.sh           | 173  | TODO   | Integrate with tmux/SendMessage to spawn agent                      | github-issue  |
| scripts/sw-scale.sh           | 199  | TODO   | Integrate with SendMessage to shut down agent                       | github-issue  |
| scripts/sw-scale.sh           | 337  | TODO   | Parse pipeline context to generate actual recommendations           | github-issue  |
| scripts/sw-swarm.sh           | 365  | TODO   | Implement queue depth and resource monitoring                       | github-issue  |
| scripts/sw-testgen.sh         | 271  | TODO   | Claude unavailable (generated stub when Claude API unavailable)     | accepted-debt |
| scripts/sw-testgen.sh         | 277  | TODO   | Implement test for \$func (placeholder in generated test template)  | accepted-debt |
| scripts/sw-predictive-test.sh | 70   | TODO   | add input validation (intentional fixture for security patrol test) | accepted-debt |

## Category Definitions

- **fix-now**: Simple, actionable, can be addressed in a single session (e.g., replace hardcoded value with policy read).
- **github-issue**: Needs a tracked GitHub issue for future work; non-trivial integration or feature work.
- **accepted-debt**: Intentional or documented trade-off; no action required beyond documentation.
- **stale**: No longer relevant; safe to remove from source.

## Recommended Actions

### github-issue (create issues)

1. **sw-scale.sh** (lines 173, 199): Create issue _"Integrate scale up/down with tmux/SendMessage"_ — when scaling, spawn/shutdown agents via tmux or SendMessage instead of emitting events only.
2. **sw-scale.sh** (line 337): Create issue _"Parse pipeline context for scale recommendations"_ — use active pipeline state to generate context-aware scaling recommendations.
3. **sw-swarm.sh** (line 365): Create issue _"Implement queue depth and resource monitoring for swarm"_ — add queue depth and resource utilization monitoring to auto-scaling analysis.

### accepted-debt (no change)

- **sw-testgen.sh** (271, 277): These are intentional placeholders in generated test templates. The TODO text signals fallback behavior when Claude is unavailable or when no test implementation exists.
- **sw-predictive-test.sh** (70): Intentional test fixture. The test creates sample vulnerable code (SQL injection, missing input validation) to verify the security patrol detects these issues. The TODO is part of the deliberately bad code.

### stale

None identified.

### fix-now

None identified. All TODOs are either deferred integration work (github-issue) or intentional placeholders (accepted-debt).
