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
      "file": "fleet-shared-patterns.json",
      "relevance": 60,
      "summary": "Cross-repo build/test stage failure pattern for common npm error 'Cannot find module' with fix 'npm i'. Directly applicable to build stage issues in Node projects."
    },
    {
      "file": "index.json",
      "relevance": 55,
      "summary": "Test failure pattern indexed for build stage with test_strategy npm test. Provides timeout issue signature and fix approach relevant to E2E test builds."
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 45,
      "summary": "Two success patterns for build stage with npm test strategy, showing completion data and iteration counts for similar build-stage testing scenarios."
    },
    {
      "file": "failures.json (with failure data)",
      "relevance": 40,
      "summary": "Documented test stage failures with root causes, fixes, and resolution status. Timeout and connection patterns useful for debugging test execution issues."
    },
    {
      "file": "success-patterns.json (test-repo-comptime)",
      "relevance": 30,
      "summary": "Build stage pattern with completion metrics (1234s, $3.75 cost), includes intake→build→test flow showing multi-stage execution profile for test scenarios."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 15 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for `shipwright doctor --fix` Auto-Remediation for Common Setup Failures — Resolution: 
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
# Pipeline Tasks — `shipwright doctor --fix` Auto-Remediation for Common Setup Failures

## Implementation Checklist
- [ ] T1: Fix-tracking primitives and `--help` (step 1). *Blocks T3–T7.*
- [ ] T2: Convert the existing `doctor_fix_*` helpers from echo to exit codes (step 2). *Depends on T1.*
- [ ] T3: `doctor_fix_path` and `_doctor_check_path`, including fish and backup handling (step 3). *Depends on T1.*
- [ ] T4: `doctor_fix_hooks_exec` and the repaired `doctor_fix_hooks` (steps 4–5). *Depends on T1.*
- [ ] T5: Wire fix-and-recheck into the overlay, hooks, PATH, subcommands and scaffold checks (step 6). *Depends on T2–T4.*
- [ ] T6: `doctor_not_fixable` on the dependency checks (step 7). *Depends on T1.*
- [ ] T7: Replace the stub re-run with the real summary (step 8). *Depends on T5–T6.*
- [ ] T8: Tests T-a through T-g (step 9). *Depends on T5–T7.*
- [ ] T9: Strengthen existing Test 25, which currently passes on any output containing "fixed". *Depends on T7.*
- [ ] T10: shellcheck, `bash -n`, and a Bash 3.2 lint (no `declare -A`, no `${x,,}`, no `readarray`).
- [ ] T11: Run the full `npm test` and update docs if they mention doctor flags.
- [ ] `shipwright doctor --fix` re-checks each fixable failing check right after fixing it, and the summary counts reflect the post-fix state (T-a, T-c, T-g).
- [ ] Missing tmux, jq, claude, node and git are left as diagnostics with their existing guidance, and are listed as "not auto-fixable" (T-d).
- [ ] Every file change made under `--fix` is printed as `changed: <action> <path>`. Only `.claude/`, `~/.shipwright`, `~/.claude/hooks`, `~/.tmux*`, the shell rc file and Shipwright's install dir are ever written. Backups are made before any rc or tmux.conf edit.
- [ ] `--fix-dry` changes nothing (T-e).
- [ ] Output of plain `doctor` without `--fix` is unchanged. `sw-doctor-test.sh`, `sw-init-test.sh` and `sw-setup-test.sh` pass.
- [ ] shellcheck is clean, the code is Bash 3.2 compatible, and `VERSION` is unchanged.

## Context
- Pipeline: autonomous
- Branch: feat/-shipwright-doctor-fix-auto-remediation-3153
- Issue: #3153
- Generated: 2026-09-27T03:47:05Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests require explicit scenarios, setup/teardown patterns, and assertion design—this skill ensures comprehensive coverage of happy path, edge cases (malformed README, file permissions), and failure modes
- **test-parallelization-detection**: E2E tests often hide flakiness through timing dependencies and shared state (temp files, file handles); this skill prevents race conditions when tests run in parallel or in CI

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
started_at: 2026-09-27T05:42:09Z
last_iteration_at: 2026-09-27T05:42:09Z
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

