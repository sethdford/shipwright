---
goal: "Classify and surface flatlining build-loop iterations distinct from context exhaustion

## Plan Summary
# Implementation Plan: Classify and Surface Flatlining Build-Loop Iterations

## Problem Analysis

The goal is to **improve distinction and visibility** between two failure modes in the build loop:

1. **Flatline**: Loop gets stuck (same error, no code changes) for N consecutive iterations
2. **Context Exhaustion**: Loop runs out of model context mid-execution

Current state (from CLAUDE.md):
- Basic flatline detection exists with `flatline_threshold` (default 3)
- Exit class is written to `progress.md` and `failure-reason.txt`
- Daemon reads it via `loop_read_exit_class` for retry decisions
- **Gap**: Classification logic is scattered; not clearly surfaced to users/operators; unclear how flatline streak counter works

## Requirements Analysis

### Minimum Viable Change
Create a **unified, observable flatline classification system** that:
- Accurately tracks iteration-by-iteration progress (code changes, error signatures)
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Classify and Surface Flatlining Build-Loop Iterations
## Context
## Decision
### Why This Approach
## Alternatives Considered
### Alternative 1: Inline Classification in `sw-loop.sh` ❌
### Alternative 2: Post-Hoc Classification Stage ❌
### Alternative 3: Lightweight Heuristic (No Fingerprinting) ❌
## Component Architecture
### Components & Responsibilities
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Classify and surface flatlining build-loop iterations distinct from context exhaustion

### Goals
- Classify and surface flatlining build-loop iterations distinct from context exhaustion

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Contains failure patterns with timestamps, root causes, and resolution tracking (timeouts, database issues). Critical for detecting iteration-level failures and distinguishing resolved vs unresolved patterns—key indicators of flatlining vs transient failures."
    },
    {
      "file": "index.json",
      "relevance": 85,
      "summary": "Build stage-specific failure patterns with signatures and fixes. Shows classification of test_failure pattern type with 5 occurrences—directly applicable to categorizing build iteration failures."
    },
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 75,
      "summary": "Cross-repo failure patterns with seen_count and contribution tracking. The 'Cannot find module' pattern appearing in both build and test stages helps identify recurring issues—indicators of flatlining vs one-off context failures."
    },
    {
      "file": "success-patterns.json",
      "relevance": 65,
      "summary": "Contains iterations_needed and stages_executed fields across patterns. Shows what successful builds require (1-3 iterations typically)—provides baseline for detecting when iterations exceed expected count, signaling flatlining."
    },
    {
      "file": "pattern-outcomes.json",
      "relevance": 55,
      "summary": "Empty outcome tracking structure but metadata shows repo_hash correlation capability. Designed for tracking iteration outcomes by repo—infrastructure for surface classification of flatlining vs exhaustion by iteration."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Classify and surface flatlining build-loop iterations distinct from context exhaustion — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Classify and surface flatlining build-loop iterations distinct from context exhaustion

## Implementation Checklist
- [ ] Task 1: Create `scripts/sw-lib-loop-classify.sh` with `fingerprint_error()`, `count_code_changes()`, `classify_iteration()` functions
- [ ] Task 2: Integrate classifier into `scripts/sw-loop.sh` iteration handler; write classifications to `flatline.json`; update `progress.md` format
- [ ] Task 3: Enhance `loop_read_exit_class()` in daemon-dispatch.sh to read `flatline.json` and return both exit class and streak count
- [ ] Task 4: Define `flatline.json` schema with iteration-level classifications and exit class summary
- [ ] Task 5: Update `progress.md` format to include `Flatline streak: X/Y` per iteration
- [ ] Task 6: Emit `loop.iteration_classified` and `loop.flatline` events to eventbus for observability
- [ ] Task 7: Update daemon retry logic in `scripts/sw-daemon.sh` to distinguish flatline from context_exhaustion
- [ ] Task 8: Add patrol function `_patrol_flatline()` to detect and alert on flatline patterns
- [ ] Task 9: Create `scripts/sw-loop-flatline-test.sh` with 6+ test cases (productive, flat, context_exhaustion, threshold, reset, fingerprinting)
- [ ] Task 10: Enhance daemon failure tests to verify flatline and context_exhaustion retry strategies
- [ ] Task 11: Add end-to-end integration test simulating 3-iteration flatline
- [ ] Task 12: Update `CLAUDE.md` with "Flatline Classification" section and examples
- [ ] Task 13: Verify no regressions in existing loop and daemon tests
- [x] Flatline classification engine created and tested
- [x] Loop integration complete (calls classifier, writes flatline.json, updates progress.md)
- [x] Daemon reads classification and applies correct retry strategy (flatline → escalate; context_exhaustion → restart boost)
- [x] `flatline.json` schema defined and documented
- [x] Events emitted: `loop.iteration_classified`, `loop.flatline`, `pipeline.flatline`
- [x] `progress.md` format updated to show `Flatline streak: X/Y`
- [x] At least 6 new test cases pass (flat, productive, context_exhaustion, threshold, reset, fingerprinting)

## Context
- Pipeline: autonomous
- Branch: ci/issue-7689
- Issue: none
- Generated: 2026-10-05T10:14:10Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-10-05T12:02:48Z
last_iteration_at: 2026-10-05T12:02:48Z
consecutive_failures: 0
total_commits: 2
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

