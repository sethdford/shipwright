## E2E Test Isolation and Cleanup

E2E tests that mutate files (like adding README comments) risk polluting subsequent tests. Prevent cascading failures:

### Before Test Runs
- Create isolated test fixtures in a temp directory or sandbox environment, not in the shared repo root
- Use unique markers or UUIDs in test data (e.g., comment markers like `<!-- test-run-abc123 -->`) so cleanup is deterministic
- Verify the test environment state is fresh (no stale artifacts from prior runs)

### Test Execution
- Document what the test modifies (which files, which lines)
- Avoid in-place mutations of tracked files—prefer creating a temporary copy or mocking file I/O
- If you must mutate tracked files, use a dedicated test branch or test workspace

### Cleanup and Idempotence
- Write explicit teardown that removes all added content by UUID/marker, not by line number (line numbers drift as the file evolves)
- Make the test idempotent: running it twice should not double-add comments or fail on the second run
- Verify cleanup completed (e.g., diff before/after to confirm only test markers were removed)

### CI/CD Integration
- Run E2E tests in isolation—do not run them on the same checked-out repo as other tests
- Use fresh clones or reset to HEAD after each E2E test run
- If the test is in the main CI pipeline, gate it behind a flag so developers can run it locally but CI can choose to skip if resources are tight
