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
      "relevance": 90,
      "summary": "Comprehensive test failure analysis with patterns from sw-intent-analysis-test, sw-e2e-integration-test, sw-loop-test, and sw-cost-test; includes root causes and fixes directly applicable to diagnosing build stage failures"
    },
    {
      "file": "retry-outcomes.json",
      "relevance": 85,
      "summary": "Shows model_escalation retry strategy achieved 100% success rate (5/5) for build_failure class; highly relevant for recovery strategy selection during build stage"
    },
    {
      "file": "patterns.json",
      "relevance": 80,
      "summary": "Project configuration (Node.js, vitest, npm, commonjs imports) provides essential context for understanding build and test runner behavior"
    },
    {
      "file": "metrics.json",
      "relevance": 75,
      "summary": "Build and test duration baselines (7095s build, 1459s test) help establish expected performance and detect anomalies during the build stage"
    },
    {
      "file": "knowledge.json",
      "relevance": 70,
      "summary": "Contains actionable fixes for common build failures (mktemp directory issues, missing dependencies, npm install requirements) frequently encountered in test setup"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 6 new discoveries
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Auto-file hygiene issue when a script exceeds 2000 lines — Resolution: 
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
- **testing-strategy**: E2E tests require clear patterns for automation setup, test data lifecycle, pass/fail criteria, and CI/CD integration—critical for reliable test execution.
- **test-parallelization-detection**: Tests that modify shared resources (README files) are vulnerable to race conditions when run in parallel; detection and synchronization patterns are mandatory.

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
started_at: 2026-09-19T18:49:08Z
last_iteration_at: 2026-09-19T18:49:08Z
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

