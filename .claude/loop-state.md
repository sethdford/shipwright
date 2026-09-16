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
      "summary": "Contains detailed test failure patterns with root causes and fixes from recent runs (Sept 13-16). Includes timeout issues, schema validation failures, stale pipeline locks, and flaky test patterns essential for diagnosing E2E test failures."
    },
    {
      "file": "patterns.json",
      "relevance": 90,
      "summary": "Defines project structure: Node.js with vitest test runner, npm package manager, commonjs imports. Critical for understanding how tests execute in this environment."
    },
    {
      "file": "retry-outcomes.json",
      "relevance": 80,
      "summary": "Shows model escalation strategy has 100% success rate (5/5) on build_failure class. Provides recovery option if build stage encounters issues."
    },
    {
      "file": "flaky-tests.json",
      "relevance": 75,
      "summary": "Identifies known flaky tests (test-1 with 85% confidence, test-auth with 90% confidence). Helps predict which tests may fail during E2E test run."
    },
    {
      "file": "knowledge.json",
      "relevance": 70,
      "summary": "Contains common bootstrap failures: mktemp /tmp/claude directory creation errors and npm install issues. Relevant for test environment setup phase."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 5 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Cluster and quarantine E2E-test-comment noise to unblock signal in daemon triage — Resolution: 
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
- **e2e-test-reliability**: E2E tests are inherently flaky with filesystem and timing dependencies—this skill ensures the synthetic test executes reliably without false failures masking actual reliability issues.
- **testing-strategy**: Apply systematic patterns for test execution, output validation, and safe completion—critical for synthetic tests that must not contaminate real DORA metrics or consume real issue-processing capacity.

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
model: opus
agents: 1
started_at: 2026-09-16T16:10:23Z
last_iteration_at: 2026-09-16T16:10:23Z
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

