## E2E Test Isolation and Cleanup

E2E tests that mutate external state (file I/O, Git, databases) must be bulletproof about isolation and cleanup. Flaky test suites that leave artifacts behind erode team trust and cause cascading failures.

### Test Design Principles

**Hermetic Isolation**
- Clone/setup fresh state at test start (separate worktree, temp directory, or test fixture)
- Use immutable inputs: never modify shared fixtures or baseline data
- Each test must be runnable in any order and any quantity (1, 100, 1000x)
- Declare dependencies explicitly: if test B requires output from test A, use shared fixtures, not implicit ordering

**Cleanup Guarantee**
- Cleanup runs even on test failure: wrap setup/assertion in try/finally equivalent
- Delete test-created files, revert Git state, close file handles, kill processes
- Use trap handlers (bash) or finally blocks (other languages) to ensure cleanup runs
- Verify cleanup actually succeeded: check that temp files are gone, working directory is clean

**Parallel Safety**
- Tests must not fight over temp directories, lock files, or Git branches
- Use unique IDs per test run (UUID, PID, timestamp) to namespace artifacts
- Test both sequential and parallel execution locally before pushing
- Document any known parallelization limits in the test file header

**Failure Investigation**
- On test failure, preserve artifacts for debugging: temp dir, Git state, logs
- Write detailed error messages: which assertion failed, what state did cleanup leave behind
- Use structured error output (JSON, line-per-fact) so dashboards can detect patterns
- Flakiness detector: tag failures as `flaky` or `environment_dependent` if they don't reproduce locally

### Implementation Checklist

- [ ] Test creates isolated state (worktree, temp dir, fixture)
- [ ] Cleanup runs unconditionally, even on assertion failure
- [ ] Cleanup verifies itself: asserts temp files are gone, Git is clean
- [ ] Test uses unique IDs (UUID/PID) to namespace artifacts if parallelizable
- [ ] Test passes 5x sequentially and 3x in parallel before merge
- [ ] Test failure message includes Git state and artifact paths for debugging
- [ ] README or test file documents parallelization assumptions

### Red Flags

- `rm -rf /tmp/mytest` without checking success
- Hardcoded paths instead of `${TMPDIR}` or temp file generation
- No cleanup section or cleanup runs before assertions
- Tests that depend on previous test's output without explicit setup
- No verification that cleanup actually succeeded
