## Shipwright E2E Test Patterns

E2E tests for Shipwright validate full system flows: agent behavior, pipeline execution, git operations, and integration with external systems.

### Test Environment Isolation

- **Dedicated temp directories**: Each E2E test runs in an isolated `mktemp -d` worktree or temp repo to avoid cross-test pollution.
- **Mock GitHub**: Use `scripts/mocks/github.sh` or stub functions that return predictable JSON responses. Do NOT call real GitHub during test runs.
- **Mock git**: Either use a bare temp repository or mock `git` commands via shell function override. Ensure `git status`, `git commit`, `git push` are predictable.
- **Agent isolation**: Spawn test agents with `--session-id test-<unique>` to prevent session reuse across tests.

### Fixture Management

- **Setup phase**: Create baseline repo state (files, commits, README) before running the agent.
- **Teardown phase**: Always run cleanup (rm -rf, kill background processes, unset env vars) in a trap handler, even if the test fails.
- **Fixture versioning**: If tests depend on specific file contents, version fixtures in `.claude/test-fixtures/` and document any assumptions.

### Validating Agent Behavior

- **File state assertions**: After agent runs, check file contents with `grep`, `diff`, or `jq` on expected JSON outputs.
- **Git assertions**: Verify commits exist with `git log --oneline`, check branch state with `git symbolic-ref HEAD`.
- **Comment assertions**: If testing "add comment to README", validate the exact comment text, location, and formatting using `grep` or `awk` on the output.
- **Async operations**: Use polling loops with timeout for async agent work: `until [condition]; do sleep 0.1; [ $((++count)) -gt 100 ] && fail; done`.

### Test Structure

```bash
test_add_comment_to_readme() {
  local test_dir=$(mktemp -d)
  trap "rm -rf $test_dir" EXIT
  
  # Setup: create isolated repo with README
  cd $test_dir
  git init
  echo '# Project' > README.md
  git add README.md && git commit -m 'init'
  
  # Run: spawn agent with goal to add comment
  local result=$(claude --stdin <<'EOF' <<GOAL
    Add a test comment to line 1 of README.md
  GOAL)
  
  # Validate: check comment exists
  grep -q 'test comment' README.md || fail "comment not found"
  
  # Cleanup is automatic via trap
}
```

### Flakiness Prevention

- **Deterministic mocks**: Mock responses with fixed output (no timestamps, UUIDs only where needed).
- **Explicit waits**: Never rely on implicit timing; use `sleep` or polling with explicit timeout.
- **State snapshots**: After key steps, snapshot git state (`git log --oneline > /tmp/state.txt`) for debugging test failures.
- **Idempotency**: Design tests so re-running without cleanup yields the same result (or clear failure), not cascading corruption.

### Debugging Failed E2E Tests

- Capture full output: `set -x` in test functions to log every command.
- Preserve artifacts: Copy temp directories to `.claude/test-artifacts/` on failure for post-mortem.
- Mock introspection: Log mock invocations (mock GitHub received `POST /repos/.../issues`?) to understand what agent attempted.
- Minimal reproduction: Reduce the test to the smallest flow that reproduces the issue, then debug that.
