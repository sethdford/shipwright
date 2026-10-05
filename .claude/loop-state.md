---
goal: "E2E test: add comment to README [automated]

## Specification: E2E test: add comment to README [automated]

### Goals
- E2E test: add comment to README [automated]

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{"error":"memory_search_failed","results":[]}

Discoveries from other pipelines:
✓ Injected 13 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Classify and surface flatlining build-loop iterations distinct from context exhaustion — Resolution: 
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
# Pipeline Tasks — Classify and surface flatlining build-loop iterations distinct from context exhaustion

## Implementation Checklist
- [ ] **Task 1**: Add `compute_stall_reason()` function to `scripts/lib/loop-flatline.sh` with logic for all four cases
- [ ] **Task 2**: Read `flatline.json` and error history in `compute_stall_reason()` to determine streak and error signatures
- [ ] **Task 3**: Call `compute_stall_reason()` in `scripts/sw-loop.sh` after loop termination, store in `LOOP_STALL_REASON`
- [ ] **Task 4**: Update `progress.md` write logic to include `Stall reason:` line (after `Exit class:`)
- [ ] **Task 5**: Update `error-summary.json` write logic to include `"stall_reason"` field
- [ ] **Task 6**: Create `_retry_action_for_stall_reason()` function in `scripts/sw-daemon.sh` with decision logic
- [ ] **Task 7**: Update `_should_restart()` in `scripts/sw-daemon.sh` to read stall_reason and call new function
- [ ] **Task 8**: Add max-retry config per stall_reason (optional: `loop.max_retries_by_reason` in daemon-config.json)
- [ ] **Task 9**: Write unit test for `compute_stall_reason()` in `sw-loop-test.sh` covering all cases
- [ ] **Task 10**: Write unit test for daemon retry logic in `sw-lib-daemon-failure-test.sh` covering all cases
- [ ] **Task 11**: Write backward-compatibility test (missing stall_reason field) in both test suites
- [ ] **Task 12**: Update documentation in CLAUDE.md: `loop.max_retries_by_reason` config section
- [ ] **Task 13**: Run full test suite (`npm test`) and verify no regressions
- [ ] **Task 14**: Manual smoke test: trigger loop failure, check progress.md/error-summary.json for stall_reason
- [ ] **Task 15**: Verify daemon restart logic respects stall_reason in live daemon run (or via e2e test)
- [ ] `compute_stall_reason()` function exists in loop-flatline.sh and handles all four cases
- [ ] `stall_reason` field written to progress.md and error-summary.json on loop termination
- [ ] Daemon reads `stall_reason` and uses it in retry/restart/abort decision
- [ ] No hardcoded stall_reason values (all derived from loop state)
- [ ] sw-loop-test.sh has 4+ unit tests for classification (all cases covered)

## Context
- Pipeline: standard
- Branch: feat/classify-and-surface-flatlining-build-lo-7689
- Issue: #7689
- Generated: 2026-10-05T00:57:46Z

## Skill Guidance (backend issue, AI-selected)
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
iteration: 1
max_iterations: 3
status: error
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-10-05T03:02:45Z
last_iteration_at: 2026-10-05T03:02:45Z
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

