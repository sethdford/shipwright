---
goal: "Add pre-build validation checks to catch broken environments before the build loop starts

## Plan Summary
Looking at this autonomous pipeline task, I need to create a detailed implementation plan for pre-build validation. Let me analyze the context and design the solution.

## Analysis

**Current State:**
- Recent commits show partial work: event schema registration and documentation started
- Pre-build validation config already exists in daemon-config.json (enabled by default)
- Loop harness exists but doesn't yet call validation
- Common failures: missing dependencies ("Error: Cannot find module"), test runner issues, resource exhaustion

**Key Insight:** This is a **missing implementation** — the infrastructure is declared but not actually built. We need to create the validation logic that's currently referenced but doesn't exist.

---

## Implementation Plan

### Alternatives Considered

**Approach A: Standalone validation script (CHOSEN)**
- Create `scripts/sw-pre-build-validate.sh` with reusable check functions
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Pre-Build Validation Framework
## Context
## Decision
## Alternatives Considered
### 1. Inline Validation in Loop Harness
### 2. Inline + Configuration File Per Check
### 3. Pre-Build as Formal Pipeline Stage
## Implementation Plan
### Files to Create
### Files to Modify
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Add pre-build validation checks to catch broken environments before the build loop starts

### Goals
- Add pre-build validation checks to catch broken environments before the build loop starts

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json (detailed)",
      "relevance": 95,
      "summary": "Contains failure patterns with root causes: database connection refused (db not started), unbounded loop timeouts. These are exactly the environment issues pre-build validation should catch (missing services, resource constraints)."
    },
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 90,
      "summary": "Tracks 'Error: Cannot find module' with fix 'npm i' in build stage across repos. Missing dependencies are a primary pre-build validation concern — this pattern shows a recurring environment issue."
    },
    {
      "file": "index.json",
      "relevance": 70,
      "summary": "Contains test_failure pattern in build stage with root cause related to test setup and timeout configuration. Relevant to build-time environment setup validation."
    },
    {
      "file": "success-patterns.json (test-final-working)",
      "relevance": 65,
      "summary": "Shows daemon timeout issue in sw-daemon.sh resolved in 2 iterations. Indicates build environment problems and timeout handling, relevant context for pre-build validation design."
    },
    {
      "file": "success-patterns.json (test-repo-789)",
      "relevance": 60,
      "summary": "Contains 'Fix timeout' pattern in build stage with high complexity. Shows timeout issues that could be prevented by pre-build environment validation."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Add pre-build validation checks to catch broken environments before the build loop starts — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Add pre-build validation checks to catch broken environments before the build loop starts

## Implementation Checklist
- [ ] **Validation Script Created**: `scripts/sw-pre-build-validate.sh` exists, runs 7+ checks, outputs valid JSON
- [ ] **Helper Library Created**: `scripts/lib/pre-build.sh` with reusable check functions tested in isolation
- [ ] **Loop Integration**: `scripts/sw-loop.sh` calls validation before iteration 1; abort on fatal, inject warnings into context
- [ ] **Event Logging**: Pre-build events registered in `config/event-schema.json` and emitted by validation script
- [ ] **Context Injection**: Validation results merged into `progress.md` and `error-summary.json`; iteration 1 receives structured feedback
- [ ] **Auto-Fix Support**: npm install auto-triggered on missing dependencies (if configured)
- [ ] **Test Coverage**: 15+ tests covering happy path, all failure modes, timeouts, race conditions
- [ ] **Configuration**: `daemon-config.json` template documents all pre-build options
- [ ] **Documentation**: `.claude/CLAUDE.md` has "Pre-Build Validation" section with examples and troubleshooting
- [ ] **No Regressions**: Existing loop tests still pass; pre-build validates on enabled but doesn't break disabled
- [ ] **Performance**: Validation completes in <15s on typical projects
- [ ] **Bash 3.2 Compliance**: All scripts use bash 3.2 compatible syntax (tested with `bash --version 3.2`)
- [ ] **Safety Checks**: Re-validation logic in place to catch environment changes between validation and iteration 1 start

## Context
- Pipeline: autonomous
- Branch: ci/issue-6428
- Issue: none
- Generated: 2026-09-26T12:11:01Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-09-26T12:14:20Z
last_iteration_at: 2026-09-26T12:14:20Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

