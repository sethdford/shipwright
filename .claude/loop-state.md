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
✓ Injected 5 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Add build-loop pre-flight checks for missing test/lint commands before burning iterations — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Add build-loop pre-flight checks for missing test/lint commands before burning iterations

## Implementation Checklist
- [ ] T1: Create `lib/loop-preflight.sh` with the syntax and executable checks (blocks T2, T4, T6)
- [ ] T2: Add runner-specific checks for npm/yarn/pnpm, make and npx (depends on T1)
- [ ] T3: Write `preflight.json` atomically and emit `loop.preflight_failed` (depends on T1)
- [ ] T4: Load the new file in `sw-loop.sh`, add the `--no-preflight` flag and help text (depends on T1)
- [ ] T5: Call the check first in `main()`, before the single- and multi-agent branches (depends on T4)
- [ ] T6: Unit tests in `sw-loop-test.sh` that load the new file directly (depends on T1–T3)
- [ ] T7: End-to-end test: a broken command exits nonzero, the output names the command, and the mock claude is never called (depends on T5)
- [ ] T8: End-to-end test: with a working command the loop behaves exactly as before (depends on T5)
- [ ] T9: Add the `preflight_failed` branch in `pipeline-stages-build.sh` (depends on T3)
- [ ] T10: Update CLAUDE.md and confirm `package.json`/release packaging picks up the new file
- [ ] T11: Run `sw-loop-test.sh`, `sw-lib-pipeline-stages-test.sh`, `sw-pipeline-test.sh`, then `npm test`

## Context
- Pipeline: standard
- Branch: feat/add-build-loop-pre-flight-checks-for-mis-6987
- Issue: #6987
- Generated: 2026-09-28T07:21:05Z

## Skill Guidance (infrastructure issue, AI-selected)
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
started_at: 2026-09-28T08:28:34Z
last_iteration_at: 2026-09-28T08:28:34Z
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

