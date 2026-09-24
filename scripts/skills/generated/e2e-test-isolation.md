## E2E Test Isolation & Cleanup

E2E tests that modify repository state (files, README, branches, tags) must be strictly isolated to prevent flaky concurrent runs, test pollution, and hard-to-debug race conditions in CI pipelines.

### Isolation Strategy
- **Use separate branches or worktrees** — Never modify main repository state directly; create test-specific branches or isolated git worktrees per test run
- **Unique namespacing** — Each concurrent E2E test run should use unique file paths, branch names, or temporary directories to avoid collisions
- **Atomic transactions** — Use `git` transactions or file-level atomicity (temp file → move) to ensure changes are all-or-nothing

### Cleanup & Reversibility
- **Cleanup-on-exit guarantee** — Use shell traps (`trap`) or try/finally patterns to ensure cleanup runs even if the test fails mid-execution
- **Verify cleanup** — Manually run the cleanup logic to confirm README changes are reverted and no orphaned state remains
- **Document expected state** — Clearly specify what the repository state should be after the test completes

### Concurrency Safety
- **File locks or git locks** — If multiple E2E tests modify the same files, use lock files or `git update-ref` transactions to serialize access
- **Separate test data** — Store test fixtures and expected output in isolated directories, not in shared test data
- **Audit all modifications** — Log every file change during the test so failures can be traced and state can be manually recovered

### Common Pitfalls
- Creating files without cleanup handlers → use trap to ensure deletion even on error
- Modifying shared branches (main, develop) → always use isolated branches with test-unique names
- Assuming sequential execution → CI pipelines run tests in parallel; use locks or namespacing
- Hard-coded paths or /tmp collisions → generate unique paths per test execution
- Skipping cleanup verification → manually test the cleanup path before merging
