---
goal: "Adaptive circuit breaker threshold based on failure signature similarity

## Plan Summary
# Implementation Plan: Adaptive Circuit Breaker Threshold Based on Failure Signature Similarity

## Executive Summary

**Goal**: Make the circuit breaker threshold (currently hardcoded to 4 consecutive failures) adapt dynamically based on whether failures share the same root cause (signature similarity).

**Key Insight**: When consecutive loop failures have identical or very similar error signatures, they likely stem from the same root cause (e.g., "test setup timeout"). The user should get more chances to fix the underlying issue before the circuit breaker trips. Different signatures indicate unrelated problems and should trip faster.

**Approach**: Create a new utility script (`sw-circuit-breaker.sh`) that analyzes recent failure signatures and returns an adjusted threshold. Integrate this into `sw-loop.sh`'s circuit breaker decision point.

---

## Requirements Clarity

### Minimum Viable Change
Modify the circuit breaker logic in `sw-loop.sh` to call a new scoring function that:
1. Examines the last N failures in `.claude/pipeline-artifacts/error-log.jsonl`
2. Extracts their error signatures (error type + stage)
3. Calculates similarity percentage between consecutive failures
4. Returns an adjusted threshold: higher if failures are similar, lower if diverse
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Adaptive Circuit Breaker Threshold Based on Failure Signature Similarity
## Context
## Decision
## Alternatives Considered
### Alternative 1: Inline Loop Modification
### Alternative 2: Memory System Integration
### Alternative 3: Dedicated Circuit Breaker Script ✅ CHOSEN
## Component Diagram
## Interface Contracts
### Core Scorer Functions (in `sw-circuit-breaker.sh`)
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Adaptive circuit breaker threshold based on failure signature similarity

### Goals
- Adaptive circuit breaker threshold based on failure signature similarity

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 90,
      "summary": "Contains explicit failure signatures with patterns, root causes, seen counts, and resolution status. Directly applicable to building failure signature similarity detection for circuit breaker thresholds."
    },
    {
      "file": "index.json",
      "relevance": 80,
      "summary": "Indexes failure patterns by signature with stage metadata and fixes. Shows how failure patterns are currently tracked and categorized in the system."
    },
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 70,
      "summary": "Demonstrates signature hashing and cross-repo pattern tracking with seen counts and metadata. Relevant for understanding pattern similarity and aggregation across distributed failures."
    },
    {
      "file": "success-patterns.json (Fix timeout, repo: test-repo-789)",
      "relevance": 55,
      "summary": "Build stage pattern for daemon timeout fix shows relevant context on timeout handling, error signatures array, and build stage execution patterns."
    },
    {
      "file": "fleet-patterns.json",
      "relevance": 40,
      "summary": "Structured pattern storage format (though currently empty) provides schema for how patterns should be stored for fleet-wide circuit breaker decisions."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Adaptive circuit breaker threshold based on failure signature similarity — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Adaptive circuit breaker threshold based on failure signature similarity

## Implementation Checklist
- [ ] Circuit breaker threshold increases when consecutive failures share identical error signature
- [ ] Circuit breaker threshold decreases when failures have different signatures  
- [ ] Threshold respects hard bounds: min=2, max=8
- [ ] Feature can be disabled via config flag (default: false during rollout)
- [ ] Feature works offline (no external API calls)
- [ ] Backward compatible: existing loops unaffected when feature disabled
- [ ] `sw-circuit-breaker.sh` follows Shipwright conventions (set -euo pipefail, VERSION, event logging)
- [ ] All functions documented with comment block (inputs, outputs, side effects)
- [ ] Error handling for all edge cases (missing files, malformed JSON, empty signature data)
- [ ] No hardcoded paths (all use config vars from daemon-config.json)
- [ ] Unit test suite: 20+ tests covering signature extraction, similarity matching, threshold calculation
- [ ] Integration test: loop with adaptive enabled processes similar failures correctly
- [ ] Integration test: loop with adaptive enabled processes diverse failures correctly
- [ ] Backward compat test: loop with adaptive disabled behaves identically to current version
- [ ] All existing loop tests pass (no regressions)
- [ ] Test suite registered in package.json and runs via `npm test`
- [ ] CLAUDE.md updated with algorithm explanation and config examples
- [ ] Code comments explain scoring heuristics and edge cases
- [ ] Error messages are actionable (e.g., "adaptive circuit breaker: signature extraction failed, falling back to default")
- [ ] README or CHANGELOG mention new feature

## Context
- Pipeline: autonomous
- Branch: ci/issue-6176
- Issue: none
- Generated: 2026-09-25T10:42:30Z"
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-09-25T11:16:22Z
last_iteration_at: 2026-09-25T11:16:22Z
consecutive_failures: 0
total_commits: 1
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-09-25T11:16:22Z)
✅ Integration verified with loop-convergence.sh  
✅ Manual testing confirms:
  - Repeated test timeouts: threshold 3 → 5 ✓

