## E2E Test Reliability Patterns

**Test Isolation**: Each E2E test run must start from a clean state and leave no artifacts behind. For README modifications:
- Use a temporary branch or separate test file, never modify the canonical README directly
- Restore original state in teardown, even on test failure (use trap handlers in bash)
- Verify idempotency: running the test twice should produce the same result

**Environment Detection**: E2E tests behave differently in CI vs. local development.
- Detect CI environment (`$CI`, `$GITHUB_ACTIONS`) and skip cleanup assertions that require git push access
- Mock or stub external dependencies (GitHub API calls) when running locally
- Log environment context (OS, shell version, git version) to failures for debugging

**Flakiness Signatures**: These patterns indicate your E2E test will fail randomly:
- Hardcoded file paths (use `$TMPDIR` or temp directories)
- Time-dependent assertions (sleep, timestamp checks) without jitter tolerance
- Concurrent test runs sharing state (temp files, git branches)
- Network calls without retry logic (GitHub API rate limits, DNS latency)

**Debugging E2E Failures**: When a test passes locally but fails in CI:
1. Capture full stdout/stderr before cleanup (write to artifact directory)
2. Log the git state: `git status`, `git log --oneline -5`
3. Print environment: `env | grep -E 'CI|GITHUB|PATH'`
4. Re-run the test in CI with `--verbose` if available; CI logs > local reproduction

**Test Structure**: Prefer a three-phase pattern:
```bash
# Phase 1: Setup (idempotent)
# Phase 2: Execute (the actual workflow being tested)
# Phase 3: Verify + Cleanup (always runs, even on error)
```
