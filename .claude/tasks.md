# Tasks — Use failure classification to set adaptive retry backoff in the daemon

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-8227

## Checklist
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

## Notes
- Generated from pipeline plan at 2026-10-10T19:09:39Z
- Pipeline will update status as tasks complete
