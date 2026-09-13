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
