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
