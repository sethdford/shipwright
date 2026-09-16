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
      "file": "patterns.json",
      "relevance": 95,
      "summary": "Defines project conventions (node, vitest, npm, javascript, src/ source directory) that are essential for the build stage to function correctly"
    },
    {
      "file": "failures.json (second)",
      "relevance": 85,
      "summary": "Documents recent test failures (2026-09-16) with root causes and fixes including test suite issues, flaky patterns, and timeouts that could inform debugging if the E2E test fails"
    },
    {
      "file": "success-patterns.json (second)",
      "relevance": 80,
      "summary": "Shows 2 successful patterns with similar complexity, iterations (3-4), test strategies (npm test), and file patterns that provide a reference model for this E2E test build"
    },
    {
      "file": "retry-outcomes.json",
      "relevance": 75,
      "summary": "Demonstrates that model_escalation strategy achieves 100% success rate (5/5) for build_failure class, providing a proven recovery strategy if the build fails"
    },
    {
      "file": "metrics.json",
      "relevance": 65,
      "summary": "Establishes performance baselines (build: 7095s, test: 1459s) that set expectations for how long this E2E test build and verification should take"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 15 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Cluster and quarantine E2E-test-comment noise to unblock signal in daemon triage — Resolution: 
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
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Cluster and quarantine E2E-test-comment noise to unblock signal in daemon triage

## Implementation Checklist
- [ ] **Task 1**: Update `config/defaults.json` with `triage.synthetic_patterns` schema
- [ ] **Task 2**: Document pattern structure in `.claude/daemon-config.json` comments
- [ ] **Task 3**: Implement `daemon_quarantine_if_synthetic()` in daemon-dispatch.sh
- [ ] **Task 4**: Implement `daemon_issue_matches_pattern()` with regex + labels + authors logic
- [ ] **Task 5**: Add queue lane initialization to daemon-state.sh
- [ ] **Task 6**: Modify daemon poll to classify and enqueue to correct lane
- [ ] **Task 7**: Add `daemon_enqueue_synthetic()` and modify dequeue to prioritize real issues
- [ ] **Task 8**: Update `sw-dora.sh` to support `--exclude-synthetic` flag
- [ ] **Task 9**: Write unit tests for pattern matching (positive case: E2E test issue)
- [ ] **Task 10**: Write unit tests for pattern matching (negative case: real issue)
- [ ] **Task 11**: Write integration tests for queue lane prioritization
- [ ] **Task 12**: Write E2E test for daemon + DORA metrics with synthetic exclusion
- [x] Config schema updated with `triage.synthetic_patterns` (default empty, backward compatible)
- [x] Pattern matching function implemented with fail-open semantics (3+ signals required)
- [x] Queue lane logic in daemon (`.queued` and `.synthetic_queue` separate)
- [x] Daemon integration: classify before enqueue, dequeue prioritizes real issues
- [x] DORA metrics support `--exclude-synthetic` flag to filter out quarantined runs
- [x] Unit tests pass: pattern matching (E2E positive + real negative + 2 edge cases)
- [x] Integration tests pass: queue prioritization, config hot-reload
- [x] E2E test passes: full daemon cycle with mixed issues, DORA metrics correct

## Context
- Pipeline: standard
- Branch: feat/cluster-and-quarantine-e2e-test-comment-5047
- Issue: #5047
- Generated: 2026-09-16T15:34:50Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **e2e-test-reliability**: E2E tests are inherently flaky; this test must survive async timing, filesystem state races, and parallel CI runs—requires explicit isolation and determinism patterns.
- **test-parallelization-detection**: Detect hidden shared state (temp directories, cached modules, file locks) that cause the test to fail when run in parallel with other tests; critical for daemon reliability.

## E2E Test Reliability & Flakiness Prevention

E2E tests are inherently flaky: they touch real filesystems, have timing dependencies, and interact with external systems. When an E2E test fails, distinguish between:

**1. Non-Deterministic Failures** (same inputs, different outputs)
- Add explicit waits/retries for asynchronous operations
- Use atomic file operations (write to temp, mv, not direct echo)
- Isolate each test run: unique temp directories, no shared state
- Check for race conditions: if test passes solo but fails in parallel, suspect shared resources

**2. Environment Drift** (test passes locally, fails in CI)
- Document all environment assumptions (file permissions, PATH, HOME, locale)
- Use absolute paths, never relative paths that depend on cwd
- Mock system commands if test depends on specific versions (git, node, etc.)
- Verify test works on both the developer's machine and CI runners

**3. Debugging Flaky Tests**
- Capture full error context: file state before/after, subprocess output, timing logs
- Rerun in isolation first (`./test.sh`), then in parallel (`npm test`)
- Add tracing: `set -x` and `exec 3>&1` to capture stderr separately
- For README tests: verify the comment is actually written, not just that the command exits 0

**4. Cleanup Safety**
- Always clean up on both success AND failure: use trap handlers
- Don't rely on rm -rf—verify files are gone
- If modifying shared files (README), restore from backup or use git
- Test cleanup itself: after test finishes, verify no temp artifacts remain

**5. Idempotency**
- E2E tests must be runnable multiple times safely
- Remove/restore the comment if it already exists before adding
- Use deterministic test data (no timestamps, UUIDs, or random content)
- If the test modifies README, restore it using `git checkout` in cleanup

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
started_at: 2026-09-16T17:21:44Z
last_iteration_at: 2026-09-16T17:21:44Z
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

