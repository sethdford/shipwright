# Pipeline Tasks — Add test suites for the 3 remaining untested utility scripts

## Implementation Checklist
- [ ] **Task 1**: Create `sw-event-schema-sync-test.sh` skeleton with setup/teardown
- [ ] **Task 2**: Implement schema drift detection tests (check mode, no drift, drift detected)
- [ ] **Task 3**: Implement schema write tests (verify JSON update, new types added)
- [ ] **Task 4**: Implement edge case tests for event-schema-sync (missing python3, malformed JSON, dynamic types)
- [ ] **Task 5**: Create `sw-tmux-role-color-test.sh` skeleton with mock tmux binary
- [ ] **Task 6**: Implement role→color mapping tests (8 roles + unknown default)
- [ ] **Task 7**: Implement tmux edge case tests (empty title, unavailable tmux, case insensitivity)
- [ ] **Task 8**: Create `sw-tmux-status-test.sh` skeleton with mock state files and heartbeats
- [ ] **Task 9**: Implement pipeline widget tests (stage extraction, case normalization, missing state)
- [ ] **Task 10**: Implement agent widget and all-mode tests (heartbeat counting, stale filtering)
- [ ] **Task 11**: Update package.json to register all three new test suites
- [ ] **Task 12**: Run `npm test` to verify all suites pass (both new and existing tests)
- [ ] **Task 13**: Verify coverage improvement toward >90% target (optional: run coverage report)

## Context
- Pipeline: standard
- Branch: test/add-test-suites-for-the-3-remaining-unte-6124
- Issue: #6124
- Generated: 2026-09-24T20:13:21Z
