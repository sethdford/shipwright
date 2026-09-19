---
goal: "E2E test: add comment to README [automated]

## Specification: E2E test: add comment to README [automated]

### Goals
- E2E test: add comment to README [automated]

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "success-patterns.json",
      "relevance": 90,
      "summary": "Shows successful build patterns with npm test, standard template, 3-4 iterations, and practical approaches (e.g., 'Fix bug' pattern: 45s, 2.50 cost). Directly applicable to building the E2E test."
    },
    {
      "file": "patterns.json",
      "relevance": 85,
      "summary": "Project context: vitest test runner, npm package manager, javascript language, test pattern '*.test.js'. Essential for understanding the build environment for the E2E test."
    },
    {
      "file": "failures.json",
      "relevance": 75,
      "summary": "Detailed test failure patterns (sw-intent-analysis-test, sw-e2e-integration-test, sw-loop-test) with root causes and fixes. Helps anticipate and handle test failures during build stage."
    },
    {
      "file": "metrics.json",
      "relevance": 65,
      "summary": "Baseline metrics: build_duration_s=7095, test_duration_s=1459. Provides timing expectations to identify if the E2E test build is taking abnormally long."
    },
    {
      "file": "retry-outcomes.json",
      "relevance": 60,
      "summary": "Shows build_failure recovery with model_escalation strategy at 100% success rate. Relevant for handling build failures if they occur during the E2E test execution."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 12 new discoveries
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Auto-file hygiene issue when a script exceeds 2000 lines — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Auto-file hygiene issue when a script exceeds 2000 lines

## Implementation Checklist
- [x] Task 1: Create `scripts/lib/hygiene-size.sh` with `_emit_script_sizes`, `check_script_sizes`, `hygiene_oversized_scripts` + load guard
- [x] Task 2: Source the lib from `sw-hygiene.sh`, delete moved bodies, update 3 call sites, bump VERSION to 3.5.0
- [x] Task 3: Add `PATROL_OVERSIZED_ENABLED` / `PATROL_OVERSIZED_THRESHOLD` defaults and lib sourcing to `daemon-patrol.sh`
- [x] Task 4: Implement `patrol_oversized_scripts()` with dedup, NO_GITHUB/dry-run guards, and decision-engine branch
- [x] Task 5: Register the check in the `daemon_patrol()` dispatch block with findings-summary bookkeeping
- [x] Task 6: Add `hygiene.oversized_issue_threshold: 2000` to `config/policy.json`
- [x] Task 7: Load `patrol.checks.oversized_scripts.*` in `sw-daemon.sh` with integer validation
- [x] Task 8: Regression-test `hygiene script-size` behavior is byte-identical after extraction
- [x] Task 9: Unit tests — detects >threshold, ignores <=threshold, honors dry-run and NO_GITHUB, respects disabled flag
- [x] Task 10: Dedup test — second patrol run with an open issue creates zero new issues
- [x] Task 11: Decision-engine test — signal written to `pending.jsonl`, no issue created
- [x] Task 12: Document the patrol check and config keys in `.claude/CLAUDE.md`
- [x] Task 13: `bash -n` + shellcheck all changed scripts
- [x] Task 14: Run `sw-hygiene-test.sh`, `sw-lib-daemon-patrol-test.sh`, then full `npm test`
- [x] `scripts/lib/hygiene-size.sh` exists with a load guard and is sourced by both `sw-hygiene.sh` and `daemon-patrol.sh`
- [x] `shipwright hygiene script-size` output is byte-identical to pre-change for the same input
- [x] `patrol_oversized_scripts()` flags scripts with `lines > 2000` and ignores those at or below
- [x] Exactly one aggregate GitHub issue is filed per detection cycle, labeled `<PATROL_LABEL>,hygiene`
- [x] A second patrol run with the issue open files **zero** new issues
- [x] `NO_GITHUB=true`, `--dry-run`, and `enabled: false` each suppress issue creation

## Context
- Pipeline: autonomous
- Branch: ci/issue-5791
- Issue: none
- Generated: 2026-09-19T17:38:10Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests require clear scenarios and assertions; this skill ensures test coverage is comprehensive and edge cases (timing, state cleanup, idempotency) are addressed.

## Testing Strategy Expertise

Apply these testing patterns:

### Test Pyramid
- **Unit tests** (70%): Test individual functions/methods in isolation
- **Integration tests** (20%): Test component interactions and boundaries
- **E2E tests** (10%): Test critical user flows end-to-end

### What to Test
- Happy path: the expected successful flow
- Error cases: what happens when things go wrong?
- Edge cases: empty inputs, maximum values, concurrent access
- Boundary conditions: off-by-one, empty collections, null/undefined

### Test Quality
- Each test should verify ONE behavior
- Test names should describe the expected behavior, not the implementation
- Tests should be independent — no shared mutable state between tests
- Tests should be deterministic — same result every run

### Coverage Strategy
- Aim for meaningful coverage, not 100% line coverage
- Focus coverage on business logic and error handling
- Don't test framework code or simple getters/setters
- Cover the branches, not just the lines

### Mocking Guidelines
- Mock external dependencies (APIs, databases, file system)
- Don't mock the code under test
- Use realistic test data — edge cases reveal bugs
- Verify mock interactions when the side effect IS the behavior

### Regression Testing
- Write a failing test FIRST that reproduces the bug
- Then fix the bug and verify the test passes
- Keep regression tests — they prevent the bug from recurring

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Test Pyramid Breakdown**: Explicit count of unit/integration/E2E tests and their coverage targets (e.g., "70 unit tests covering business logic, 12 integration tests for API boundaries, 3 E2E tests for critical paths")
2. **Coverage Targets**: Target coverage percentage per layer and which critical paths MUST be tested
3. **Critical Paths to Test**: Specific test cases for the happy path, 2+ error cases, and 2+ edge cases

If any section is not applicable, explicitly state why it's skipped.
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-09-19T20:09:42Z
last_iteration_at: 2026-09-19T20:09:42Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

