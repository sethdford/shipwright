---
goal: "Add pre-build dependency/tooling check to pipeline intake stage

## Plan Summary
Perfect! I've created a comprehensive implementation plan. Let me provide you with a summary of what's been documented:

## Summary

I've generated a detailed **Implementation Plan** for adding pre-build dependency/tooling checks to the pipeline intake stage. Here's what's included:

### 📋 Plan Structure

**Filename**: `.claude/pipeline-artifacts/plan.md`

### Key Sections

1. **Problem Statement** — Current intake stage doesn't validate build prerequisites, causing expensive build-stage failures

2. **Design Decision** — Chose a separate reusable module (`sw-prebuild-check.sh`) over inline code because it:
   - Enables independent testing
   - Allows reuse by daemon and other commands  
   - Provides configurability and extensibility
   - Follows Shipwright's modular architecture
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Add pre-build dependency/tooling check to pipeline intake stage
## Context
## Decision
### Component Diagram
### Interface Contracts
### Configuration (in the existing chain; no new file)
### Data Flow
### Error Boundaries
## Alternatives Considered
## Implementation Plan
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Add pre-build dependency/tooling check to pipeline intake stage

### Goals
- Add pre-build dependency/tooling check to pipeline intake stage

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 95,
      "summary": "Contains dependency/tooling pattern: 'Cannot find module' error fixed by 'npm i', directly relevant to pre-build dependency checking across multiple repos"
    },
    {
      "file": "success-patterns.json (test-repo-comptime)",
      "relevance": 85,
      "summary": "Only pattern showing both intake and build stages executed ([intake,build,test]), demonstrates stage flow relevant to adding intake-stage checks"
    },
    {
      "file": "failures.json",
      "relevance": 75,
      "summary": "Contains database connection and unbounded loop timeout failures that a pre-build tooling check could detect and prevent (db service startup, resource validation)"
    },
    {
      "file": "index.json",
      "relevance": 70,
      "summary": "Test failure pattern in build stage with timeout fix, relevant context for understanding build stage validation and potential dependency/tooling failures"
    },
    {
      "file": "success-patterns.json (test-repo-789)",
      "relevance": 60,
      "summary": "Build stage pattern modifying sw-daemon.sh with timeout handler, shows common build stage modifications that might benefit from pre-build verification"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Add pre-build dependency/tooling check to pipeline intake stage — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Add pre-build dependency/tooling check to pipeline intake stage

## Implementation Checklist
- [ ] **Task 6**: Implement `check_required_tools()` — check optional tools from config (git, jq, etc.)
- [ ] **Task 7**: Implement `prebuild_check()` orchestrator — call all checks, save results atomically, emit events
- [ ] **Task 8**: Create `scripts/sw-prebuild-check-test.sh` — ≥15 test cases covering all scenarios
- [ ] **Task 9**: Modify `scripts/lib/pipeline-stages-intake.sh` — call prebuild_check() early, handle results
- [ ] **Task 10**: Create `.claude/prebuild-config.json` — sensible defaults, documentation
- [ ] **Task 11**: Update `.claude/CLAUDE.md` — add to AUTO sections (core-scripts, test-suites)
- [ ] **Task 12**: Update `package.json` — add test to npm test script
- [ ] **Task 13**: Create documentation — `docs/prebuild-checks.md` with examples and recovery steps
- [ ] **Task 14**: End-to-end validation — run full pipeline, verify intake completes successfully
- [ ] Module exists at `scripts/sw-prebuild-check.sh` with all 6 check functions
- [ ] Test suite exists at `scripts/sw-prebuild-check-test.sh` with ≥15 test cases
- [ ] **All tests pass**: `bash scripts/sw-prebuild-check-test.sh` → 0 failures
- [ ] Integrated into intake stage: `pipeline-stages-intake.sh` calls `prebuild_check()`
- [ ] Configuration template exists: `.claude/prebuild-config.json`
- [ ] Backward compatible: existing pipelines run without changes
- [ ] Error messages clear and actionable
- [ ] Events emitted: `prebuild_check.completed`, `prebuild_check.failed`
- [ ] Offline support: works with `--local` flag, skips network checks when `$NO_GITHUB=true`
- [ ] Results in artifacts: `.claude/pipeline-artifacts/prebuild-check.json`
- [ ] GitHub integration: intake comment includes prebuild status

## Context
- Pipeline: autonomous
- Branch: ci/issue-7767
- Issue: none
- Generated: 2026-10-05T10:15:44Z"
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-10-05T10:50:44Z
last_iteration_at: 2026-10-05T10:50:44Z
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
### Iteration 1 (2026-10-05T10:50:44Z)
I did not run the full `npm test` suite, which has over 100 suites. I ran only the checks that read the README:
- **Version consistency:** `scripts/check-version-consistency.sh` reports 3.3.0 everywhere.
- **Docs suite:** `scripts/sw-docs-test.sh` passes 18 of 18.

