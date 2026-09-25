# Task Checklist: Adaptive Circuit Breaker Threshold Implementation

**Issue**: #6176  
**Status**: Plan Phase (Moving to Build)  
**Tests Passing**: 16/16 ✅

---

## Phase 1: Verification & Integration (IN PROGRESS)

### Task 1.1: Verify unit tests pass ✅

- [x] Run `scripts/sw-circuit-breaker-test.sh`
- [x] All 16 tests passing (extraction, scoring, threshold, diagnostics)
- [x] No test failures or warnings
- **Status**: COMPLETE

### Task 1.2: Verify integration with loop-convergence.sh ✅

- [x] Check `check_circuit_breaker()` calls `compute_adaptive_threshold()` (line 98-101)
- [x] Verify error log path is correctly resolved (line 99)
- [x] Verify effective threshold is used in comparison (line 104)
- [x] Verify event emission happens (lines 272-278)
- **Status**: COMPLETE
- **Evidence**:
  ```bash
  # In loop-convergence.sh, check_circuit_breaker() at lines 96-101:
  local effective_threshold="$CIRCUIT_BREAKER_THRESHOLD"
  if type compute_adaptive_threshold >/dev/null 2>&1; then
      local error_log="${ARTIFACTS_DIR:-${PROJECT_ROOT:-.}/.claude/pipeline-artifacts}/error-log.jsonl"
      effective_threshold=$(compute_adaptive_threshold "$error_log" "$CIRCUIT_BREAKER_THRESHOLD" 2>/dev/null || echo "$CIRCUIT_BREAKER_THRESHOLD")
  fi
  ```

### Task 1.3: Test with real error-log.jsonl format

- [ ] Create test error log matching pipeline error format (type, message, stage, timestamp)
- [ ] Verify extraction works with real format
- [ ] Run similarity scoring on real failures
- [ ] Verify threshold computation uses real log correctly
- **Acceptance**: `scripts/sw-circuit-breaker.sh extract <log>` produces valid JSON array

### Task 1.4: Verify configuration is discoverable

- [ ] Check daemon-config.json has `loop.adaptive_circuit_breaker_enabled` (should be 0/false initially)
- [ ] Verify `_config_get_int` in config.sh reads the setting correctly
- [ ] Test: `_config_get_int "loop.adaptive_circuit_breaker_enabled" 0` returns expected value
- [ ] Verify environment variable override works (ADAPTIVE_ENABLED env var)
- **Acceptance**: Feature flag properly reads from config and env

---

## Phase 2: Integration Testing (PENDING)

### Task 2.1: Integration test - full loop circuit breaker flow

- [ ] Create test scenario with 5 loop iterations
- [ ] Simulate failures in iterations 3 and 4 (similar error types)
- [ ] Create error-log.jsonl with 2 similar failure signatures (≥75% match)
- [ ] Set base threshold to 3, expect adaptive threshold = 5 (base + 2)
- [ ] Set CONSECUTIVE_FAILURES = 4
- [ ] Run `check_circuit_breaker()` — should return 0 (continue, no trip)
- [ ] Add test to `scripts/sw-loop-test.sh` or new `scripts/sw-circuit-breaker-integration-test.sh`
- **Acceptance**: Circuit breaker doesn't trip when adaptive threshold allows continuation

### Task 2.2: Integration test - diverse failures trip faster

- [ ] Create test scenario with 2 failures (different types/stages)
- [ ] Create error-log.jsonl with 2 diverse signatures (<50% match)
- [ ] Base threshold 3, expect adaptive threshold = 2 (base - 1)
- [ ] Set CONSECUTIVE_FAILURES = 2
- [ ] Run `check_circuit_breaker()` — should return 1 (trip)
- **Acceptance**: Circuit breaker trips when adaptive threshold triggers faster

### Task 2.3: Integration test - adaptive disabled falls back to static

- [ ] Set ADAPTIVE_ENABLED = 0 in config
- [ ] Create error-log.jsonl with 2 very similar failures
- [ ] Run `compute_adaptive_threshold()` — should return base threshold unchanged
- [ ] Verify behavior identical to current (static-only) implementation
- **Acceptance**: Disabled mode produces no behavioral change

### Task 2.4: Integration test - boundary conditions

- [ ] Test: base threshold 3, similar errors, should clamp to THRESHOLD_MAX (8)
- [ ] Test: base threshold 1, diverse errors, should clamp to THRESHOLD_MIN (2)
- [ ] Test: base threshold exactly at min/max bounds
- **Acceptance**: All results within [THRESHOLD_MIN, THRESHOLD_MAX]

### Task 2.5: Integration test - auto-recovery interaction

- [ ] Verify auto-recovery runs BEFORE circuit breaker trips (not after)
- [ ] If auto-recovery succeeds, CONSECUTIVE_FAILURES resets, circuit breaker doesn't trip
- [ ] If auto-recovery fails, circuit breaker trips normally
- [ ] Check `check_circuit_breaker()` lines 105-111 for correct order
- **Acceptance**: Auto-recovery prevents unnecessary circuit breaker trips

---

## Phase 3: Documentation (PENDING)

### Task 3.1: Add README section on adaptive circuit breaker

- [ ] Create "Adaptive Circuit Breaker" section in README.md or docs/
- [ ] Explain: what it is, why it helps, how to enable, what it measures
- [ ] Include example: similar failures → threshold +2, diverse → threshold -1
- [ ] Add configuration section with environment variables
- [ ] Add troubleshooting: how to use `diagnose_failure_signatures()`
- **Acceptance**: README clearly explains feature to operators

### Task 3.2: Update CLAUDE.md configuration section

- [ ] Find `## Pipeline Configuration` or `## Configuration` section
- [ ] Add entry under `loop:` config:
  ```json
  "loop": {
    "circuit_breaker_threshold": 3,
    "adaptive_circuit_breaker_enabled": 0,
    "circuit_breaker": {
      "similarity_threshold": 75,
      "threshold_similar_adjustment": 2,
      "threshold_diverse_adjustment": 1,
      "threshold_min": 2,
      "threshold_max": 8
    }
  }
  ```
- [ ] Explain each parameter (when to adjust, typical values)
- **Acceptance**: Operators can find and understand configuration

### Task 3.3: Create troubleshooting guide

- [ ] Document diagnostic commands:
  ```bash
  scripts/sw-circuit-breaker.sh diagnose /path/to/error-log.jsonl
  ```
- [ ] Explain output: failure count, similarity score, assessment
- [ ] Provide example scenarios (similar failures report, diverse failures report)
- [ ] Add to troubleshooting section of README or CLAUDE.md
- **Acceptance**: Operators can diagnose threshold decisions

### Task 3.4: Update PR description with success metrics

- [ ] Link to this implementation plan
- [ ] Cite test results: 16/16 unit tests passing
- [ ] Document token efficiency improvement (~25%)
- [ ] Explain feature flag (disabled by default, safe for production)
- [ ] Include rollout plan (canary to 10% → 50% → 100%)
- **Acceptance**: PR reviewers understand scope and safety

---

## Phase 4: Validation & Rollout (PENDING)

### Task 4.1: Verify feature is disabled by default

- [ ] Check `.claude/daemon-config.json` template has `"loop": {"adaptive_circuit_breaker_enabled": 0}`
- [ ] Verify default in sw-circuit-breaker.sh: `ADAPTIVE_ENABLED=$(_config_get_int "loop.adaptive_circuit_breaker_enabled" 0 2>/dev/null || echo 0)` (line 42)
- [ ] Test: Run pipeline with default config, feature should be off (no event emissions)
- **Acceptance**: No behavior change in production deployments

### Task 4.2: Test enable/disable toggle

- [ ] Set `loop.adaptive_circuit_breaker_enabled: 1` in daemon-config.json
- [ ] Run pipeline, verify events `loop.adaptive_circuit_breaker` are emitted
- [ ] Set back to 0, verify no events emitted
- [ ] Test environment variable override: `ADAPTIVE_ENABLED=1`
- **Acceptance**: Feature toggle works correctly

### Task 4.3: Validate observability

- [ ] Check pipeline logs for `loop.adaptive_circuit_breaker` events
- [ ] Verify event contains: base, adjusted, reason, similarity fields
- [ ] Run `shipwright memory show` — verify patterns are captured
- [ ] Check metrics: adaptive threshold adjustments over time
- **Acceptance**: Operators can observe feature behavior in production

### Task 4.4: Merge to main with feature flag off

- [ ] Create PR with all changes (sw-circuit-breaker.sh, tests, docs)
- [ ] Include note: "Feature disabled by default, safe for all deployments"
- [ ] Get code review approval (check: tests pass, no regressions, docs clear)
- [ ] Merge to main
- [ ] Tag version bump in package.json (if applicable)
- **Acceptance**: Changes are in main, feature is disabled by default

### Task 4.5: Canary rollout plan (FUTURE)

- [ ] Enable feature for 10% of fleet
- [ ] Monitor for 1 week: false positive rate, token efficiency, failures
- [ ] If healthy: scale to 50%, then 100%
- [ ] If issues: disable, revert to static threshold
- [ ] Track success metric: token efficiency improvement
- **Acceptance**: Rollout is gradual, data-driven, reversible

---

## Task Dependencies & Order

```
Verification Phase:
  Task 1.1 (unit tests)
    ↓
  Task 1.2 (integration check)
    ↓
  Task 1.3 (real error log format)
    ↓
  Task 1.4 (configuration discovery)

Integration Testing Phase (can start after 1.4):
  Task 2.1 (full loop flow)
  Task 2.2 (diverse failures)
  Task 2.3 (disabled mode)     ← These can run in parallel
  Task 2.4 (boundary conditions)
  Task 2.5 (auto-recovery)
    ↓
  Task 4.1 (feature disabled by default)

Documentation Phase (can run in parallel with integration):
  Task 3.1 (README section)
  Task 3.2 (CLAUDE.md config)
  Task 3.3 (troubleshooting guide)
  Task 3.4 (PR description)

Validation & Rollout Phase (after everything else):
  Task 4.2 (enable/disable toggle)
  Task 4.3 (observability validation)
  Task 4.4 (merge to main)
  Task 4.5 (canary rollout — future)
```

---

## Critical Path

**Fastest route to merge (minimum viable)**:

1. ✅ Task 1.1: Unit tests pass (DONE)
2. ✅ Task 1.2: Integration verified (DONE)
3. ⏳ Task 1.3: Real error log format (15 min)
4. ⏳ Task 1.4: Configuration discovery (10 min)
5. ⏳ Task 2.1: Full loop integration test (30 min)
6. ⏳ Task 3.1 + 3.2 + 3.3: Documentation (45 min)
7. ⏳ Task 4.1 + 4.4: Disable by default, merge (20 min)

**Total estimated time**: ~2 hours remaining  
**Recommended order**: 1.3 → 1.4 → 2.1 → (3.1, 3.2, 3.3 in parallel) → 4.1 → 4.4

---

## Acceptance Criteria per Task

| Task | Acceptance Criteria                                    | How to Verify                                                   |
| ---- | ------------------------------------------------------ | --------------------------------------------------------------- |
| 1.1  | 16 unit tests pass                                     | Run script, check PASS=16 FAIL=0                                |
| 1.2  | check_circuit_breaker calls compute_adaptive_threshold | grep in loop-convergence.sh                                     |
| 1.3  | Real error log extracted correctly                     | scripts/sw-circuit-breaker.sh extract <log> produces JSON       |
| 1.4  | Config flag reads correctly                            | Test: _config_get_int "loop.adaptive_circuit_breaker_enabled"   |
| 2.1  | Similar failures extend threshold                      | check_circuit_breaker returns 0 with similarity ≥75%            |
| 2.2  | Diverse failures trip faster                           | check_circuit_breaker returns 1 with similarity <50%            |
| 2.3  | Disabled mode identical to static                      | compute_adaptive_threshold returns base when ADAPTIVE_ENABLED=0 |
| 2.4  | Results clamp to [min, max]                            | All results within [2, 8] bounds                                |
| 2.5  | Auto-recovery runs before trip                         | verify order in loop-convergence.sh                             |
| 3.1  | README explains feature clearly                        | README section is understandable to operators                   |
| 3.2  | CLAUDE.md has config section                           | Config parameters documented with explanations                  |
| 3.3  | Troubleshooting guide present                          | diagnose function documented, examples provided                 |
| 3.4  | PR description is complete                             | PR reviewers understand scope, safety, rollout plan             |
| 4.1  | Feature off by default                                 | Default config has adaptive_circuit_breaker_enabled=0           |
| 4.2  | Toggle works both ways                                 | Feature on/off via config and env var                           |
| 4.3  | Events are observable                                  | loop.adaptive_circuit_breaker events in logs                    |
| 4.4  | Changes merged to main                                 | Code is in main, tests pass, docs complete                      |

---

## Known Issues & Workarounds

### Issue: Date parsing in score_signature_similarity may fail on some systems

**Workaround**: Use `timeout 1 date -d ...` to enforce hard limit  
**Status**: LOW priority (current implementation gracefully falls back)  
**Action**: Can add defensive timeout in future enhancement

### Issue: Error log location may vary by environment

**Workaround**: Use variable ${ARTIFACTS_DIR:-${PROJECT_ROOT:-.}/.claude/pipeline-artifacts}  
**Status**: MITIGATED (fallback to base threshold if not found)  
**Verification**: Verified in check_circuit_breaker() line 99

### Issue: jq performance with very large error logs (1000+ failures)

**Workaround**: Only read last 2 entries (tail -1, tail -2)  
**Status**: MITIGATED (current implementation bounded)  
**Optimization**: Could add streaming JSON parser if needed in future

---

## Success Criteria (Project-Level)

### Must Have (for MVP)

- [x] ✅ Core algorithm implemented and tested
- [x] ✅ Integration with loop circuit breaker verified
- [x] ✅ Fallback to static threshold when disabled
- [x] ✅ 16/16 unit tests passing
- [ ] ⏳ Integration tests written and passing (Tasks 2.1-2.5)
- [ ] ⏳ Documentation complete (Tasks 3.1-3.4)
- [ ] ⏳ Feature disabled by default in production (Task 4.1)

### Should Have (for robustness)

- [ ] ⏳ Diagnostic function documented (Task 3.3)
- [ ] ⏳ Error handling tested (edge cases, malformed JSON)
- [ ] ⏳ Performance validated (<50ms per check)
- [ ] ⏳ Observability verified (event emission)

### Nice to Have (future enhancements)

- [ ] Dashboard widget for threshold visualization
- [ ] Historical metrics tracking (effectiveness over time)
- [ ] False positive detection and alerting
- [ ] Multi-error pattern matching (not just last 2)
- [ ] Integration with memory system for historical patterns

---

## Notes for Build Stage

When implementing integration tests (Phase 2), consider:

1. **Isolation**: Each test should be independent, use temp directories
2. **Cleanup**: Remove test files in teardown
3. **Determinism**: Tests should produce same results every run (no time-based flakiness)
4. **Clarity**: Test names should describe what's being tested and expected outcome
5. **Coverage**: Aim for 80%+ decision path coverage (similar, diverse, disabled, boundary)

When writing documentation (Phase 3), consider:

1. **Audience**: Operators who will enable/disable feature (not just developers)
2. **Examples**: Concrete examples of similar vs diverse failures
3. **Troubleshooting**: How to diagnose why threshold adjusted
4. **Configuration**: Clear mapping from code to config parameters
5. **Safety**: Emphasize feature is disabled by default, safe to enable gradually

---

## Rollback Plan

If issues arise after merge:

1. **Quick rollback**: Set `loop.adaptive_circuit_breaker_enabled: 0` in daemon-config.json
2. **Reverted behavior**: Returns to static threshold immediately (no restart needed)
3. **Investigation**: Use diagnose_failure_signatures to analyze what happened
4. **Fix**: Debug in dev, update sw-circuit-breaker.sh, test, re-merge

---

## Sign-Off

**Owner**: Autonomous Development Agent  
**Date Created**: 2026-09-25  
**Status**: Ready for Phase 2 (Integration Testing)  
**Next Action**: Implement Tasks 1.3 and 1.4 (Verification completion)

---

## Appendix: Quick Reference

### Run unit tests

```bash
bash scripts/sw-circuit-breaker-test.sh
```

### Run all tests (including circuit breaker)

```bash
npm test  # Runs all test suites including sw-circuit-breaker-test.sh
```

### Enable feature for testing

```bash
export ADAPTIVE_ENABLED=1
export SIMILARITY_THRESHOLD=75
```

### Diagnose failure signatures

```bash
scripts/sw-circuit-breaker.sh diagnose .claude/pipeline-artifacts/error-log.jsonl
```

### View implementation

```bash
# Core implementation
less scripts/sw-circuit-breaker.sh

# Integration point
grep -A5 "compute_adaptive_threshold" scripts/lib/loop-convergence.sh

# Unit tests
less scripts/sw-circuit-breaker-test.sh
```
