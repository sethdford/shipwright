## E2E Test Reliability

E2E tests verify real user workflows end-to-end by running against actual systems. They catch integration bugs unit tests miss, but are fragile: timing assumptions, environment dependencies, and race conditions cause silent failures or intermittent flakiness. This skill builds reliable, reproducible E2E tests.

### Isolation & Cleanup

**Ephemeral Environments**
- Use temp directories, isolated databases, fresh instances—never shared state or fixtures
- Document environment assumptions: OS, Node version, git config, file permissions, PATH
- Each test must run independently; don't rely on test execution order
- Cleanup MUST run on failure: use try/finally, trap handlers, or destructors—never conditional cleanup
- Verify cleanup completed: check temp files don't leak, processes don't linger, database is empty

### Assertion Robustness

**Verify Actual End-State**
- Assert the real artifact (file contents, HTTP response body, database record)—not "code ran successfully"
- Use exact string matching for content assertions; substring matches hide truncation and encoding issues
- Include unique IDs or timestamps in assertions to catch stale data being re-read
- For file operations: diff expected vs actual on failure, showing exact bytes that differ
- Verify side effects explicitly: if a comment is added to README, read the file and verify the exact text is present

### Timeout & Deadline Handling

**Explicit Waits with Diagnostics**
- Set timeout on all waits (never infinite loops). Distinguish "still waiting" (retry) from "timed out" (fail hard).
- Log elapsed time and what was being waited for; include diagnostic state (file contents, process status) when timeout fires
- For CI: increase timeouts 2x over local (account for slower hardware, higher variance)
- Fail fast on unrecoverable errors (file not found, permission denied)—don't retry those

### Flakiness Detection & Prevention

**Before Merge**
- Run each E2E test locally 10 times in sequence; if any fails, investigate before merging
- In CI: re-run failed tests 2-3 times; if they pass on retry, log as "flaky" and file follow-up
- Common sources: timing assumptions, file I/O race conditions, process startup delays, garbage collector pauses
- Instrument tests with timing telemetry to catch performance regressions that trigger timeouts

### Diagnostic Output

**On Failure, Capture Full Context**
- Output: file contents, environment variables, git status, last N log lines, process list
- Use structured output (JSON) for machine-readability
- Include "what was I trying to do" context in every error message
- For parallel test runs: include test ID in all log output so failures can be correlated to the right test

### Parallelization Safety

**When Tests Run Concurrently**
- Use separate temp directories per test (`$TMPDIR/test-$PID-$RANDOM`)
- Use separate port ranges per test (no hardcoded 3000/5000)
- Lock access to shared resources (git repos, databases); never assume exclusive access
- Avoid global state in configuration files; use per-test config files
