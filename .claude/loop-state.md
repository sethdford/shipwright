---
goal: "Use failure classification to set adaptive retry backoff in the daemon

## Plan Summary
# Plan: classification-driven adaptive retry backoff in the daemon

## What exists today

All of this lives in `scripts/lib/daemon-failure.sh`:

- `classify_failure()` (lines 22–71) sorts a failure into one of six classes: `auth_error`, `api_error`, `invalid_issue`, `context_exhaustion`, `build_failure`, `unknown`.
- `get_max_retries_for_class()` (lines 79–88) already sets the retry *count* per class.
- The backoff *delay* barely uses the class. Lines 295–299 hardcode `base=30`, switch to `base=300` only for `api_error`, double each retry and cap at 3600s. It ignores the consecutive-failure signal from `record_failure_class()`, cannot be configured and has no jitter.
- **Critical defect:** line 319 runs `sleep "$backoff_secs"` inside `daemon_on_failure()`. That function runs synchronously from `daemon_reap_completed()` (`daemon-dispatch.sh:485`), which runs inside `daemon_poll_loop()` (`daemon-poll.sh:560`). A second `api_error` retry therefore freezes the whole daemon for 600s, and up to 3600s at the cap. During that time there is no polling, no reaping of other jobs, no health checks and no shutdown-flag check. Making backoff more adaptive (and often longer) would make this worse, so it must be fixed in the same change.
- Smaller bug: the retry comment (line 309) shows `${MAX_RETRIES:-2}` rather than the per-class `effective_max`.

## Brainstorming

**Smallest change that meets the goal:** one pure function, `get_retry_backoff_for_class <class> <retry_count> [consecutive]`, that returns seconds from a per-class policy (base, multiplier, cap, plus a boost when the same class keeps failing). Lines 295–299 would call it. But adaptive backoff that blocks the daemon is a regression risk, so the minimum *responsible* change also makes the wait non-blocking.

**Unstated requirements:**
- The default for `api_error` (300s, doubling, 1h cap) must stay as it is.
- `auth_error` and `invalid_issue` must never wait, because they never retry.
- Every value must be overridable through `daemon-config.json` and environment variables, matching the `_smart_int` convention.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Use failure classification to set adaptive retry backoff in the daemon
## Context
## Decision
### Component diagram
### Interface contracts
### Policy (defaults; with jitter off, `api_error` matches today's values exactly)
### Data flow
### Error boundaries
## Alternatives Considered
## Implementation Plan
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Use failure classification to set adaptive retry backoff in the daemon

### Goals
- Use failure classification to set adaptive retry backoff in the daemon

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 90,
      "summary": "Holds timeout and connection-refused failure records with classification-like fields (root_cause, fix_applied, resolved, seen_count), directly relevant to classifying failures for retry backoff."
    },
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 60,
      "summary": "Cross-repo failure signatures with stage, seen_count and fix; useful for recurring-failure classification that could drive backoff tiers."
    },
    {
      "file": "index.json",
      "relevance": 50,
      "summary": "Failure pattern index keyed by signature and stage (test_failure in build) with total_seen counts, a possible input for classifying failures."
    },
    {
      "file": "success-patterns.json",
      "relevance": 35,
      "summary": "Build-stage success patterns with iterations and completion times that could inform retry expectations, though not about failure classification or backoff."
    },
    {
      "file": "test-failures.json",
      "relevance": 30,
      "summary": "Empty signature store for test failures; a likely place to record classified failures, though currently holds no data."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Use failure classification to set adaptive retry backoff in the daemon — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Use failure classification to set adaptive retry backoff in the daemon

## Implementation Checklist
- [ ] Task 1: Add `get_retry_backoff_for_class` with the per-class base, factor and cap table
- [ ] Task 2: Add the `_retry_backoff_cfg` override chain (env → `retry_backoff.<class>.<field>` → default) with integer validation
- [ ] Task 3: Add the consecutive-failure boost for `api_error` and ±jitter (`RETRY_BACKOFF_JITTER`)
- [ ] Task 4: Load `RETRY_BACKOFF_CFG` in `sw-daemon.sh` config loading
- [ ] Task 5: Replace the blocking `sleep` with `schedule_deferred_retry` writing `.pending_retries`
- [ ] Task 6: Add `daemon_process_due_retries` (capacity- and pause-aware, removes the entry before spawning)
- [ ] Task 7: Call it from `daemon_poll_loop`
- [ ] Task 8: Make `daemon_is_inflight`, stale cleanup and the success handler aware of `pending_retries`
- [ ] Task 9: Fix the `MAX_RETRIES` vs `effective_max` display bug; add `backoff_s` to events and the comment
- [ ] Task 10: Policy unit tests in `sw-lib-daemon-failure-test.sh`
- [ ] Task 11: Scheduling and draining tests in `sw-lib-daemon-dispatch-test.sh`
- [ ] Task 12: Event schema sync and CLAUDE.md docs
- [ ] Task 13: Run the daemon test suites and `npm test`; fix regressions
- [ ] Backoff delay comes from the failure class through `get_retry_backoff_for_class`; no hardcoded `base_secs` is left in `daemon_on_failure`.
- [ ] `api_error` defaults are unchanged (300 → 600 → … capped at 3600) when jitter is off.
- [ ] Each class's `base_secs`, `factor` and `cap_secs` can be overridden from `daemon-config.json` and from environment variables.
- [ ] `daemon_on_failure` never sleeps longer than `RETRY_INLINE_MAX_SECS`; the test proves it returns quickly while a retry is pending.
- [ ] Pending retries survive a daemon restart, aren't picked up again by polling, don't lose their `retry_counts`, and respect `MAX_PARALLEL` and the pause flag.
- [ ] `daemon.retry` and `daemon.retry_scheduled` events carry `class` and `backoff_s`, and the event schema has no drift.
- [ ] The retry comment shows the per-class max.

## Context
- Pipeline: autonomous
- Branch: ci/issue-8227
- Issue: none
- Generated: 2026-10-10T19:09:38Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-10-10T19:14:19Z
last_iteration_at: 2026-10-10T19:14:19Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

