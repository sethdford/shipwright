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
      "relevance": 40,
      "summary": "Contains documented test stage failures (timeouts, connection issues) with root causes and fixes; timeout patterns directly applicable to E2E test execution troubleshooting"
    },
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 32,
      "summary": "Cross-repo pattern for 'Error: Cannot find module' appearing in build/test stages across multiple repos; npm install fix is common prerequisite for E2E tests"
    },
    {
      "file": "index.json",
      "relevance": 26,
      "summary": "Test failure pattern in build stage with timeout increase fix; demonstrates common build stage issues and resolutions for test execution"
    },
    {
      "file": "success-patterns.json (test-repo-comptime)",
      "relevance": 20,
      "summary": "Shows successful intake→build→test multi-stage flow with timing data; provides template for build stage execution patterns in similar test scenarios"
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 15,
      "summary": "Multiple build stage patterns showing successful completions; low specificity but may inform general build strategy for test execution"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 5 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Classify and surface flatlining build-loop iterations distinct from context exhaustion — Resolution: 
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

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests require explicit patterns for setup, execution, assertions, and teardown to remain reliable and maintainable; establish and follow patterns consistently across build, review, and design stages.
- **test-parallelization-detection**: E2E tests interacting with README files may cause race conditions if run in parallel; proactively identify shared state vectors (file locks, temp fixtures, git state) before they cause flakiness.

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

## Test Parallelization Detection & Coordination

### Problem
Test parallelization is dangerous: undetected shared state (temp files, global state, database connections) causes race conditions and flaky failures. This skill provides a systematic approach to detect parallelizable test suites and coordinate their execution safely.

### Shared State Detection Heuristics

**Static Analysis (file scanning):**
- Scan test file imports for singleton patterns (db connections, file handles, global state modules)
- Detect hardcoded file paths (temp dirs) and network ports — tests using fixed resources conflict
- Check for `beforeAll`/`afterAll` hooks that modify global state
- Identify test files importing shared fixtures/setup modules

**Dynamic Analysis (test execution):**
- Run test suite with `--detectOpenHandles` (Node.js) or equivalent to catch file/port leaks
- Track temp directory usage per test file — any overlap = unsafe to parallelize
- Monitor for test isolation violations (tests passing in isolation but failing when run together)

**Safety Levels:**
- **Green (parallelizable)**: No shared state detected, no fixture conflicts, passes isolation tests
- **Yellow (conditional)**: Shared fixtures but isolated datasets, parallel execution with coordination (e.g., separate DB schemas)
- **Red (sequential)**: Database transaction rollback, process spawning, hardware resource contention — must run serially

### Affected-Test Detection via Git Diff

**Module Dependency Tracking:**
1. Build module-to-test mapping (which tests exercise which modules)
2. On each commit, run `git diff --name-only HEAD~1` to identify changed modules
3. Find all tests that import/test those modules
4. Prioritize affected tests first in execution order (fail-fast on functionality regression)
5. Cache mapping per commit to avoid re-scanning on retries

**False Negatives to Handle:**
- Integration tests that cross module boundaries (require broader analysis)
- Tests that exercise shared utilities or base classes (conservative: mark as affected if any parent module changed)
- Dynamic imports and string-based test discovery (fallback: scan test code for patterns)

### Parallel Execution Coordination

**Scheduler:**
- Detect CPU core count, default to `cores - 1` (reserve 1 for OS)
- Group parallelizable tests into batches, run batches in parallel
- Within each batch, respect test file order (some test runners depend on execution order)
- Run non-parallelizable (red) tests serially, either before or after parallel batches (configurable)

**Fast-Fail Policy:**
- Critical failures: assertion errors, uncaught exceptions → abort immediately
- Flaky failures: timeout, process exit, known-flaky markers → retry up to N times before aborting
- Aggregate results across parallel workers before reporting
- Time tracking: measure wall-clock time for each batch, report parallelization efficiency (theoretical vs actual speedup)

### Dashboard Integration

- Display parallel execution summary: N tests in M workers, X% speedup
- Visualize test dependency graph (which tests block which)
- Alert on shared-state violations (test passed alone, failed in parallel)
- Trend: parallelization efficiency over time (detect regressions where new tests add serial bottlenecks)

### Key Decisions for This Issue

1. **Minimum Parallelization Threshold**: What's the smallest safe granularity? (per file, per suite, per test?)
2. **Flaky Detection**: How many retries before marking as critical failure? (recommend 3)
3. **Shared-State Confidence**: Are heuristics sufficient, or require explicit opt-in per test file?
4. **Fast-Fail Behavior**: Abort on first critical failure globally, or let all workers finish for faster feedback iteration?
5. **Fallback**: If parallelization detection is uncertain, run serial — safety over speed.
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-10-05T01:25:35Z
last_iteration_at: 2026-10-05T01:25:35Z
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

