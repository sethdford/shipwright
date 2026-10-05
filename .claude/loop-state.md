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
      "relevance": 65,
      "summary": "Contains actual resolved build/test failure patterns including timeout and database connection issues that could occur during E2E test execution"
    },
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 60,
      "summary": "Tracks 'Cannot find module' error pattern across build stages with 'npm i' fix; common blocker in build stage across multiple repos"
    },
    {
      "file": "index.json",
      "relevance": 55,
      "summary": "Contains test_failure pattern in build stage with timeout fix; directly applicable to build stage debugging"
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 48,
      "summary": "Two build stage success patterns with npm test strategy; provides templates for similar build-stage tasks though generic"
    },
    {
      "file": "success-patterns.json (test-repo-outcomes)",
      "relevance": 45,
      "summary": "Build stage pattern labeled 'Test outcome' with npm test strategy; applicable to E2E test context"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 8 new discoveries
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Classify and surface flatlining build-loop iterations distinct from context exhaustion — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

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
- Generated: 2026-10-05T10:14:10Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **e2e-test-automation**: This skill guides the entire lifecycle of automaton feature testing—from designing validation points that catch real failures (not just 'code runs') through implementation and review focused on test reliability and isolation.
- **testing-strategy**: E2E tests require careful design around test sequencing, cleanup, and determinism; this skill ensures patterns like fixture setup/teardown and idempotency are applied.

## E2E Test Automation Patterns

End-to-end tests that verify automation features (like Shipwright's ability to modify files, add comments, or update documentation) have unique requirements:

### Test Lifecycle

**Setup Phase**
- Verify clean git state before test starts (no uncommitted changes)
- Create isolated test fixtures (temp dirs, test files) that won't interfere with other tests
- Document what automation you expect to trigger

**Execution Phase**
- Trigger the automation being tested (e.g., call the comment-adding function with known inputs)
- Capture all side effects: file modifications, git changes, API calls
- Record timestamps for any time-sensitive operations

**Verification Phase**
- Assert file contents match expected format exactly (including whitespace, line endings, ANSI codes)
- Verify git state changes are correct (staged files, commit messages, branch state)
- Check idempotency: run the same automation twice and verify same results (no duplicates, no corrupted state)
- Validate integration checkpoints: if automation calls other systems, verify those calls succeeded

**Teardown Phase**
- Clean up test fixtures completely (remove temp files, reset git state)
- Use trap handlers to guarantee cleanup even on test failure
- Verify no orphaned processes or file handles

### Common Failure Modes

- **Race conditions**: File I/O during automation can race with test assertions; use flock or atomic file operations
- **Comment duplication**: Idempotency bugs cause the automation to add comments twice; always test re-runs
- **Formatting mismatches**: ANSI codes, line endings, or markdown escaping differ from expected; use `od -c` to debug
- **Git state leakage**: Test leaves uncommitted changes or wrong branch; always reset HEAD and verify clean status
- **Path assumptions**: Automation hardcodes paths that don't exist in test environment; use relative paths or env vars

### Assertion Patterns

```bash
# Verify file was modified with exact content
assert_file_contains "path/to/file" "expected string"

# Verify git shows expected changes
assert_git_status "path/to/file" "modified"

# Verify automation is idempotent
run_automation
run_automation  # Run twice
assert_file_line_count "path/to/file" "expected_lines"  # Should not double

# Verify cleanup
assert_git_clean  # No uncommitted changes after test teardown
```

E2E tests of automation are integration tests—they verify the full pipeline works, not just individual functions. Invest in clear setup/teardown and comprehensive verification of side effects.

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
started_at: 2026-10-05T11:20:57Z
last_iteration_at: 2026-10-05T11:20:57Z
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

