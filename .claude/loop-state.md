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
      "relevance": 95,
      "summary": "Most recent (2026-09-19), contains real build-stage error pattern 'Cannot find module' with npm fix. Directly applicable to any build process."
    },
    {
      "file": "index.json",
      "relevance": 70,
      "summary": "Indexed build-stage patterns including test_failure with timeout fixes. Provides cross-repo patterns relevant to build stage work."
    },
    {
      "file": "failures.json (with timeout data)",
      "relevance": 60,
      "summary": "Contains resolved test-stage failures (timeouts, database issues) with applied fixes. Shows what can go wrong and how fixes work."
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 55,
      "summary": "Has 2 build-stage success patterns with 1 iteration completion. Demonstrates successful build strategies."
    },
    {
      "file": "success-patterns.json (test-repo-comptime)",
      "relevance": 50,
      "summary": "Multi-stage pattern covering intake, build, and test stages. Shows complete build flow with timing/cost data."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 13 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Adaptive circuit breaker threshold based on failure signature similarity — Resolution: 
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
# Pipeline Tasks — Adaptive circuit breaker threshold based on failure signature similarity

## Implementation Checklist
- [ ] Circuit breaker threshold increases when consecutive failures share identical error signature
- [ ] Circuit breaker threshold decreases when failures have different signatures  
- [ ] Threshold respects hard bounds: min=2, max=8
- [ ] Feature can be disabled via config flag (default: false during rollout)
- [ ] Feature works offline (no external API calls)
- [ ] Backward compatible: existing loops unaffected when feature disabled
- [ ] `sw-circuit-breaker.sh` follows Shipwright conventions (set -euo pipefail, VERSION, event logging)
- [ ] All functions documented with comment block (inputs, outputs, side effects)
- [ ] Error handling for all edge cases (missing files, malformed JSON, empty signature data)
- [ ] No hardcoded paths (all use config vars from daemon-config.json)
- [ ] Unit test suite: 20+ tests covering signature extraction, similarity matching, threshold calculation
- [ ] Integration test: loop with adaptive enabled processes similar failures correctly
- [ ] Integration test: loop with adaptive enabled processes diverse failures correctly
- [ ] Backward compat test: loop with adaptive disabled behaves identically to current version
- [ ] All existing loop tests pass (no regressions)
- [ ] Test suite registered in package.json and runs via `npm test`
- [ ] CLAUDE.md updated with algorithm explanation and config examples
- [ ] Code comments explain scoring heuristics and edge cases
- [ ] Error messages are actionable (e.g., "adaptive circuit breaker: signature extraction failed, falling back to default")
- [ ] README or CHANGELOG mention new feature

## Context
- Pipeline: autonomous
- Branch: ci/issue-6176
- Issue: none
- Generated: 2026-09-25T10:42:30Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **e2e-test-reliability**: Ensure the test is deterministic, handles environment variations gracefully, and avoids common E2E pitfalls like flakiness or race conditions

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
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-09-25T20:34:57Z
last_iteration_at: 2026-09-25T20:34:57Z
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

