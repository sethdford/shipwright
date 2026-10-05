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
      "relevance": 85,
      "summary": "Contains explicit 'test_failure' pattern for build stage, seen 5 times across sources (api, cli), with documented fix: increase timeout value in test setup. Directly applicable to build stage work."
    },
    {
      "file": "failures.json (with failure data)",
      "relevance": 80,
      "summary": "Multiple resolved build/test stage failures including timeout patterns (2 instances) with documented root causes and fixes. Shows practical failure recovery patterns relevant to test execution."
    },
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 75,
      "summary": "Common 'Cannot find module' error pattern in build stage affecting multiple repos (repo-a, repo-b), with simple fix: npm i. Prevents common build breakage in test environments."
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 68,
      "summary": "Two successful simple single-file modifications in build stage (test.sh, test2.sh) with npm test strategy and low complexity. Pattern matches lightweight E2E test changes."
    },
    {
      "file": "success-patterns.json (test-final-working)",
      "relevance": 62,
      "summary": "Successful build stage pattern for timeout handling with 2 iterations needed, demonstrating practical approach to build stage problems using npm test strategy."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 8 new discoveries
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Add pre-build dependency/tooling check to pipeline intake stage — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Add pre-build dependency/tooling check to pipeline intake stage

## Implementation Checklist
- [ ] **Task 6**: Implement `check_required_tools()` — check optional tools from config (git, jq, etc.)
- [ ] **Task 7**: Implement `prebuild_check()` orchestrator — call all checks, save results atomically, emit events
- [ ] **Task 8**: Create `scripts/sw-prebuild-check-test.sh` — ≥15 test cases covering all scenarios
- [ ] **Task 9**: Modify `scripts/lib/pipeline-stages-intake.sh` — call prebuild_check() early, handle results
- [ ] **Task 10**: Create `.claude/prebuild-config.json` — sensible defaults, documentation
- [ ] **Task 11**: Update `.claude/CLAUDE.md` — add to AUTO sections (core-scripts, test-suites)
- [ ] **Task 12**: Update `package.json` — add test to npm test script
- [ ] **Task 13**: Create documentation — `docs/prebuild-checks.md` with examples and recovery steps
- [ ] **Task 14**: End-to-end validation — run full pipeline, verify intake completes successfully
- [ ] Module exists at `scripts/sw-prebuild-check.sh` with all 6 check functions
- [ ] Test suite exists at `scripts/sw-prebuild-check-test.sh` with ≥15 test cases
- [ ] **All tests pass**: `bash scripts/sw-prebuild-check-test.sh` → 0 failures
- [ ] Integrated into intake stage: `pipeline-stages-intake.sh` calls `prebuild_check()`
- [ ] Configuration template exists: `.claude/prebuild-config.json`
- [ ] Backward compatible: existing pipelines run without changes
- [ ] Error messages clear and actionable
- [ ] Events emitted: `prebuild_check.completed`, `prebuild_check.failed`
- [ ] Offline support: works with `--local` flag, skips network checks when `$NO_GITHUB=true`
- [ ] Results in artifacts: `.claude/pipeline-artifacts/prebuild-check.json`
- [ ] GitHub integration: intake comment includes prebuild status

## Context
- Pipeline: autonomous
- Branch: ci/issue-7767
- Issue: none
- Generated: 2026-10-05T10:15:44Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests require clear strategy on fixtures, mocking external systems (git/GitHub), test isolation, and assertion design—this test needs a solid approach across all stages.

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
started_at: 2026-10-05T11:10:42Z
last_iteration_at: 2026-10-05T11:10:42Z
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

