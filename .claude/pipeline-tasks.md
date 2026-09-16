# Pipeline Tasks — Cluster and quarantine E2E-test-comment noise to unblock signal in daemon triage

## Implementation Checklist
- [ ] **Task 1**: Update `config/defaults.json` with `triage.synthetic_patterns` schema
- [ ] **Task 2**: Document pattern structure in `.claude/daemon-config.json` comments
- [ ] **Task 3**: Implement `daemon_quarantine_if_synthetic()` in daemon-dispatch.sh
- [ ] **Task 4**: Implement `daemon_issue_matches_pattern()` with regex + labels + authors logic
- [ ] **Task 5**: Add queue lane initialization to daemon-state.sh
- [ ] **Task 6**: Modify daemon poll to classify and enqueue to correct lane
- [ ] **Task 7**: Add `daemon_enqueue_synthetic()` and modify dequeue to prioritize real issues
- [ ] **Task 8**: Update `sw-dora.sh` to support `--exclude-synthetic` flag
- [ ] **Task 9**: Write unit tests for pattern matching (positive case: E2E test issue)
- [ ] **Task 10**: Write unit tests for pattern matching (negative case: real issue)
- [ ] **Task 11**: Write integration tests for queue lane prioritization
- [ ] **Task 12**: Write E2E test for daemon + DORA metrics with synthetic exclusion
- [x] Config schema updated with `triage.synthetic_patterns` (default empty, backward compatible)
- [x] Pattern matching function implemented with fail-open semantics (3+ signals required)
- [x] Queue lane logic in daemon (`.queued` and `.synthetic_queue` separate)
- [x] Daemon integration: classify before enqueue, dequeue prioritizes real issues
- [x] DORA metrics support `--exclude-synthetic` flag to filter out quarantined runs
- [x] Unit tests pass: pattern matching (E2E positive + real negative + 2 edge cases)
- [x] Integration tests pass: queue prioritization, config hot-reload
- [x] E2E test passes: full daemon cycle with mixed issues, DORA metrics correct

## Context
- Pipeline: standard
- Branch: feat/cluster-and-quarantine-e2e-test-comment-5047
- Issue: #5047
- Generated: 2026-09-16T15:34:50Z
