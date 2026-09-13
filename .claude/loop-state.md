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
      "file": "failures.json (second version with stage/pattern entries)",
      "relevance": 95,
      "summary": "Contains critical patterns for E2E test builds: sw-e2e-integration-test hanging mid-loop, stale pipeline locks blocking new runs, sw-loop-test behavior issues, and timeout problems — all directly relevant to automated E2E test stage execution"
    },
    {
      "file": "success-patterns.json (with loop iterations and cleanup patterns)",
      "relevance": 78,
      "summary": "Shows successful multi-iteration build patterns with loop cleanup, test strategies that work, file change patterns, and cost data — provides context for how complex automated builds succeed"
    },
    {
      "file": "patterns.json",
      "relevance": 62,
      "summary": "Contains project metadata (node, vitest test runner, npm, commonjs imports) — necessary context for understanding how the E2E test's build stage will execute"
    },
    {
      "file": "metrics.json",
      "relevance": 55,
      "summary": "Historical baseline metrics (build_duration_s: 7095, test_duration_s: 1459) — provides expected duration ranges for build and test stages to detect anomalies"
    },
    {
      "file": "knowledge.json (mktemp and test environment entries)",
      "relevance": 48,
      "summary": "Captures test harness environment issues (mktemp path problems, test setup conventions) — useful for diagnosing build environment setup failures in E2E automation"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 13 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Cluster and quarantine E2E-test-comment noise to unblock signal in daemon triage — Resolution: 
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
# Pipeline Tasks — Cluster and quarantine E2E-test-comment noise to unblock signal in daemon triage

## Implementation Checklist
- [x] **Task 1:** Analyze current daemon configuration structure and identify config loading mechanism
- [x] **Task 2:** Add `triage.synthetic_patterns` configuration schema to `.claude/daemon-config.json` with E2E test default pattern
- [x] **Task 3:** Implement `is_synthetic_issue()` function in `scripts/lib/daemon-triage.sh` with pattern matching logic
- [x] **Task 4:** Unit tests for `is_synthetic_issue()` — positive case (E2E test with `[automated]` marker)
- [x] **Task 5:** Unit tests for `is_synthetic_issue()` — negative case (real issue without marker)
- [x] **Task 6:** Modify `daemon-state.sh` state schema to add `synthetic_queue` array
- [x] **Task 7:** Update `enqueue_issue()` to classify issues and route to appropriate queue
- [x] **Task 8:** Update `dequeue_next()` to prioritize real queue, fall back to synthetic
- [x] **Task 9:** Emit classification and dequeue events for observability
- [x] **Task 10:** Unit tests for queue routing (enqueue real, enqueue synthetic, dequeue order)
- [x] **Task 11:** Add `exclude_synthetic` flag to `sw-dora.sh` metrics computation
- [x] **Task 12:** Integration test: full daemon poll → classify → enqueue → dequeue flow
- [x] **Task 13:** Verify config is discoverable (check `shipwright daemon config --show` or equivalent)
- [ ] **Task 14:** Manual test: Run daemon against test repo with mixed real + synthetic issues — _not runnable in CI (needs a live GitHub repo); covered by the classify → lane → drain integration test in `sw-lib-daemon-dispatch-test.sh`_
- [x] **Task 15:** Document configuration schema in `.claude/CLAUDE.md` AUTO section (if applicable)

## Context
- Pipeline: standard
- Branch: ci/cluster-and-quarantine-e2e-test-comment-5047
- Issue: #5047
- Generated: 2026-09-13T10:13:48Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **e2e-test-reliability**: This skill directly mitigates the core risks of E2E tests—timing dependencies, file system interactions, environment variability—that cause flakiness even in simple scenarios like README modification

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
"
iteration: 1
max_iterations: 3
status: error
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-09-13T12:39:25Z
last_iteration_at: 2026-09-13T12:39:25Z
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

