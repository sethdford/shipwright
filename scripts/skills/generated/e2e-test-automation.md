## E2E Test Automation Patterns

End-to-end tests that verify automation features (like Shipwright's ability to modify files, add comments, or update documentation) have unique requirements:

### Test Lifecycle

**Setup Phase**
- Verify clean git state before test starts (no uncommitted changes)
- Create isolated test fixtures (temp dirs, test files) that won't interfere with other tests
- Document what automation you expect to trigger

**Execution Phase**
- Trigger the automation being tested (e.g., call the comment-adding function with known inputs)
- Capture all side effects: file modifications, git changes, API calls
- Record timestamps for any time-sensitive operations

**Verification Phase**
- Assert file contents match expected format exactly (including whitespace, line endings, ANSI codes)
- Verify git state changes are correct (staged files, commit messages, branch state)
- Check idempotency: run the same automation twice and verify same results (no duplicates, no corrupted state)
- Validate integration checkpoints: if automation calls other systems, verify those calls succeeded

**Teardown Phase**
- Clean up test fixtures completely (remove temp files, reset git state)
- Use trap handlers to guarantee cleanup even on test failure
- Verify no orphaned processes or file handles

### Common Failure Modes

- **Race conditions**: File I/O during automation can race with test assertions; use flock or atomic file operations
- **Comment duplication**: Idempotency bugs cause the automation to add comments twice; always test re-runs
- **Formatting mismatches**: ANSI codes, line endings, or markdown escaping differ from expected; use `od -c` to debug
- **Git state leakage**: Test leaves uncommitted changes or wrong branch; always reset HEAD and verify clean status
- **Path assumptions**: Automation hardcodes paths that don't exist in test environment; use relative paths or env vars

### Assertion Patterns

```bash
# Verify file was modified with exact content
assert_file_contains "path/to/file" "expected string"

# Verify git shows expected changes
assert_git_status "path/to/file" "modified"

# Verify automation is idempotent
run_automation
run_automation  # Run twice
assert_file_line_count "path/to/file" "expected_lines"  # Should not double

# Verify cleanup
assert_git_clean  # No uncommitted changes after test teardown
```

E2E tests of automation are integration tests—they verify the full pipeline works, not just individual functions. Invest in clear setup/teardown and comprehensive verification of side effects.
