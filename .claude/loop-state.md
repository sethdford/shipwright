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
      "file": "failures.json",
      "relevance": 95,
      "summary": "Contains recent test failures from 2026-09-19 (today) including sw-intent-analysis-test, sw-e2e-integration-test, and sw-loop-test with specific root causes and fixes. Directly applicable to diagnosing build stage test failures."
    },
    {
      "file": "patterns.json",
      "relevance": 90,
      "summary": "Identifies project as Node.js with vitest test runner and npm package manager. Essential context for the build stage to know how to install dependencies and run tests."
    },
    {
      "file": "metrics.json",
      "relevance": 75,
      "summary": "Provides baseline build duration (7095s) and test duration (1459s). Critical for understanding expected timing and detecting anomalies in the current build stage."
    },
    {
      "file": "success-patterns.json",
      "relevance": 70,
      "summary": "Shows similar successful builds using npm test strategy that required 3 iterations and ~45-150s duration. Provides a tested playbook for the current E2E test build task."
    },
    {
      "file": "flaky-tests.json",
      "relevance": 65,
      "summary": "Identifies flaky tests (test-1 at 85% confidence, test-auth at 90% confidence) that may cause intermittent build failures. Important for understanding test reliability during the build stage."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 5 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Auto-file hygiene issue when a script exceeds 2000 lines — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Auto-file hygiene issue when a script exceeds 2000 lines

## Implementation Checklist
- [ ] Task 1: Add `MAX_SCRIPT_LINES` via `_config_get_int` with numeric-validation guard
- [ ] Task 2: Add `--max-script-lines` to `main()` option parsing
- [ ] Task 3: Add `_emit_script_sizes()` helper (process substitution, digit-stripped counts)
- [ ] Task 4: Add `check_script_sizes()` returning threshold-filtered, descending-sorted JSON
- [ ] Task 5: Add `report_script_sizes()` human/JSON printer, always exit 0, `emit_event`
- [ ] Task 6: Refactor `scan_platform_refactor` sizes block to use `_emit_script_sizes` (no behavior change to `script_size_hotspots`)
- [ ] Task 7: Add `oversized_scripts`, `counts.oversized_scripts`, `thresholds.max_script_lines` to the report JSON
- [ ] Task 8: Register `script-size` subcommand + add to `run_full_scan`
- [ ] Task 9: Update `show_help`; bump `VERSION` to 3.4.0
- [ ] Task 10: Add `hygiene.max_script_lines: 1500` to `config/policy.json`
- [ ] Task 11: Surface oversized count/list in `sw-strategic.sh` platform-health section
- [ ] Task 12: Surface oversized count in `sw-doctor.sh` PLATFORM HEALTH
- [ ] Task 13: Tests 13–17 in `sw-hygiene-test.sh`
- [ ] Task 14: Document in `.claude/CLAUDE.md` (config table + subcommand)
- [ ] Task 15: Run `shellcheck`, `./scripts/sw-hygiene-test.sh`, `./scripts/sw-doctor-test.sh`, `./scripts/sw-strategic-test.sh`
- [ ] `shipwright hygiene script-size` lists scripts over the threshold with line
- [ ] Threshold honored from `.claude/daemon-config.json` `hygiene.max_script_lines`,
- [ ] `.claude/platform-hygiene.json` contains `oversized_scripts` (array),
- [ ] `scripts/sw-hygiene-test.sh` covers threshold filtering, sort order, config
- [ ] `shipwright hygiene scan` runs the new check and still completes

## Context
- Pipeline: standard
- Branch: feat/auto-file-hygiene-issue-when-a-script-ex-5791
- Issue: #5791
- Generated: 2026-09-19T16:13:53Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests require careful scenario design—need clear test setup, execution flow, assertions, and cleanup for the README comment-adding workflow across all stages.

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
started_at: 2026-09-19T16:38:45Z
last_iteration_at: 2026-09-19T16:38:45Z
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

