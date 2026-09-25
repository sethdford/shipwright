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
      "file": "index.json",
      "relevance": 90,
      "summary": "Contains build stage pattern for test_failure with known fix (increase timeout). Directly applicable to E2E test execution."
    },
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 85,
      "summary": "Common build stage error pattern (Cannot find module) with npm i fix, seen in 2 repos. Prevents common build failures."
    },
    {
      "file": "failures.json",
      "relevance": 75,
      "summary": "Contains resolved and unresolved build-related failures (timeouts, missing dependencies) with root causes and fixes applied."
    },
    {
      "file": "success-patterns.json (test-repo-comptime)",
      "relevance": 65,
      "summary": "Recent success pattern with build stage included, shows approach for multi-stage builds with npm test strategy."
    },
    {
      "file": "success-patterns.json (test-final-working)",
      "relevance": 60,
      "summary": "Build stage success pattern for daemon-related fix, shows low iteration count and test strategy applicable to build context."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 5 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Fix hygiene scan false positives on the word "hardcoded" instead of numeric literals — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Fix hygiene scan false positives on the word "hardcoded" instead of numeric literals

## Implementation Checklist
- [ ] 1. Make `REPO_DIR` overridable (blocks 9)
- [ ] 2. Add the regex constants (blocks 3)
- [ ] 3. Add the `_hygiene_literal_lines` helper (blocks 4, 5)
- [ ] 4. Replace the `hardcoded` count; add `literal_defaults` and `hardcoded_mentions` (blocks 6)
- [ ] 5. Switch the findings sample to literals plus markers, and cap it at 25
- [ ] 6. Extend the JSON report, info line and `emit_event`
- [ ] 7. Update the help and info text
- [ ] 8. Add `literal_defaults` to the strategic summary
- [ ] 9. Add the fixture regression tests (depends on 1–6)
- [ ] 10. Run the hygiene, doctor and strategic suites, then `npm test`
- [ ] 11. Confirm on the real repo that `hardcoded` is several hundred (was 49) and that `lib/session-restart.sh:215/350/398/403` appear in the raw literal lines
- [ ] `counts.hardcoded` no longer changes when the word "hardcoded" is added in a comment or string (fixture test).
- [ ] `counts.hardcoded` drops when `[[ $n -ge 3 ]]` is rewritten as `${LIMIT:-3}` or `_smart_int` (fixture test).
- [ ] Exit-code comparisons, 0/1 checks, comment lines and `*-test.sh` files are excluded.
- [ ] The word count is still available as `counts.hardcoded_mentions`.
- [ ] doctor and strategic still work with both old and new JSON (`// 0` fallbacks).
- [ ] The hygiene, doctor and strategic suites pass, and `npm test` shows no regressions.

## Context
- Pipeline: standard
- Branch: fix/fix-hygiene-scan-false-positives-on-the-5846
- Issue: #5846
- Generated: 2026-09-25T07:01:06Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests require careful pattern design to avoid flakiness; this skill ensures proper test structure, setup/teardown, and assertion clarity for testing README mutations

## Testing Strategy Expertise

Apply these testing patterns:

### Test Pyramid
- **Unit tests** (70%): Test individual functions/methods in isolation
- **Integration tests** (20%): Test component interactions and boundaries
- **E2E tests** (10%): Test critical user flows end-to-end

### What to Test
- Happy path: the expected successful flow
- Error cases: what happens when things go wrong?
- Edge cases: empty inputs, maximum values, concurrent access
- Boundary conditions: off-by-one, empty collections, null/undefined

### Test Quality
- Each test should verify ONE behavior
- Test names should describe the expected behavior, not the implementation
- Tests should be independent — no shared mutable state between tests
- Tests should be deterministic — same result every run

### Coverage Strategy
- Aim for meaningful coverage, not 100% line coverage
- Focus coverage on business logic and error handling
- Don't test framework code or simple getters/setters
- Cover the branches, not just the lines

### Mocking Guidelines
- Mock external dependencies (APIs, databases, file system)
- Don't mock the code under test
- Use realistic test data — edge cases reveal bugs
- Verify mock interactions when the side effect IS the behavior

### Regression Testing
- Write a failing test FIRST that reproduces the bug
- Then fix the bug and verify the test passes
- Keep regression tests — they prevent the bug from recurring

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Test Pyramid Breakdown**: Explicit count of unit/integration/E2E tests and their coverage targets (e.g., "70 unit tests covering business logic, 12 integration tests for API boundaries, 3 E2E tests for critical paths")
2. **Coverage Targets**: Target coverage percentage per layer and which critical paths MUST be tested
3. **Critical Paths to Test**: Specific test cases for the happy path, 2+ error cases, and 2+ edge cases

If any section is not applicable, explicitly state why it's skipped.
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-09-25T07:30:59Z
last_iteration_at: 2026-09-25T07:30:59Z
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

