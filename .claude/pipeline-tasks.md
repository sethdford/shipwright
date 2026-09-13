# Pipeline Tasks — Cluster and quarantine E2E-test-comment noise to unblock signal in daemon triage

## Implementation Checklist
- [x] **Task 1:** Analyze current daemon configuration structure and identify config loading mechanism
- [x] **Task 2:** Add `triage.synthetic_patterns` configuration schema to `.claude/daemon-config.json` with E2E test default pattern
- [x] **Task 3:** Implement `is_synthetic_issue()` function in `scripts/lib/daemon-triage.sh` with pattern matching logic
- [x] **Task 4:** Unit tests for `is_synthetic_issue()` — positive case (E2E test with `[automated]` marker)
- [x] **Task 5:** Unit tests for `is_synthetic_issue()` — negative case (real issue without marker)
- [ ] **Task 6:** Modify `daemon-state.sh` state schema to add `synthetic_queue` array
- [ ] **Task 7:** Update `enqueue_issue()` to classify issues and route to appropriate queue
- [ ] **Task 8:** Update `dequeue_next()` to prioritize real queue, fall back to synthetic
- [ ] **Task 9:** Emit classification and dequeue events for observability
- [ ] **Task 10:** Unit tests for queue routing (enqueue real, enqueue synthetic, dequeue order)
- [ ] **Task 11:** Add `exclude_synthetic` flag to `sw-dora.sh` metrics computation
- [ ] **Task 12:** Integration test: full daemon poll → classify → enqueue → dequeue flow
- [ ] **Task 13:** Verify config is discoverable (check `shipwright daemon config --show` or equivalent)
- [ ] **Task 14:** Manual test: Run daemon against test repo with mixed real + synthetic issues
- [ ] **Task 15:** Document configuration schema in `.claude/CLAUDE.md` AUTO section (if applicable)

## Context
- Pipeline: standard
- Branch: ci/cluster-and-quarantine-e2e-test-comment-5047
- Issue: #5047
- Generated: 2026-09-13T10:13:48Z
