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
      "file": "fleet-shared-patterns.json",
      "relevance": 60,
      "summary": "Common 'Cannot find module' error pattern with npm install fix, applicable to build stage across multiple repos"
    },
    {
      "file": "index.json",
      "relevance": 35,
      "summary": "Build stage test_failure pattern with known timeout fix; directly applicable to build stage diagnostics"
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 25,
      "summary": "Two documented success patterns for build stage execution; shows typical build completion patterns"
    },
    {
      "file": "success-patterns.json (test-repo-comptime)",
      "relevance": 25,
      "summary": "Success pattern including build stage with completion time and cost metrics; helps predict build duration"
    },
    {
      "file": "failures.json",
      "relevance": 20,
      "summary": "Timeout and dependency failure patterns with documented fixes; timeout patterns may apply to build stage issues"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 5 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Budget-aware pipeline template selection — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Budget-aware pipeline template selection

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/budget-template.sh` with the tier ladder, budget reader and selector
- [ ] Task 2: Add `PIPELINE_NAME_EXPLICIT` (init in `sw-pipeline.sh`, set in `pipeline-cli.sh`)
- [ ] Task 3: Replace the `== "standard"` check in `pipeline_start` and call `budget_select_template`
- [ ] Task 4: Apply the budget selection in `daemon_spawn_pipeline` using a local variable
- [ ] Task 5: Source the new lib in the pipeline and daemon entry points
- [ ] Task 6: Register `pipeline.template_budget_downgrade` via `sw-event-schema-sync.sh --write`
- [ ] Task 7: Write `scripts/sw-budget-template-test.sh` (unit plus parse-args cases)
- [ ] Task 8: Add the low-budget case to `sw-lib-daemon-dispatch-test.sh`
- [ ] Task 9: Add the suite to `package.json` `test:legacy-chain`
- [ ] Task 10: Document the config keys and override in `.claude/CLAUDE.md` and the `--help` text
- [ ] Task 11: Run `bash -n`, shellcheck, the targeted suites, then the full `npm test`
- [ ] `pipeline start` without `--template` calls `budget_select_template` before `load_pipeline_config` (criterion 1)
- [ ] Remaining budget below `budget.template_downgrade_threshold_usd` downgrades exactly one tier, emits `pipeline.template_budget_downgrade`, and logs a warning that names the override (criterion 2)
- [ ] `--template X` / `--pipeline X` is never downgraded, including `--template standard` (criterion 3)
- [ ] The daemon applies the same selection at spawn and doesn't change the global `PIPELINE_TEMPLATE`
- [ ] The new suite covers the low-budget, explicit-override and normal no-op paths plus the edge cases, and passes (criterion 4)
- [ ] `sw-event-schema-sync.sh` reports no drift, so there's no "Unknown event type" warning
- [ ] The full `npm test` is green on Linux. No bash 4+ constructs (`bash -n` passes, and `grep` finds no `declare -A`, `readarray`, `${x,,}` or `${x^^}`)
- [ ] Docs updated (CLAUDE.md config table, `--help`)

## Context
- Pipeline: standard
- Branch: feat/budget-aware-pipeline-template-selection-6924
- Issue: #6924
- Generated: 2026-09-27T20:29:45Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests require disciplined test isolation, deterministic assertions, and proper cleanup—this skill ensures the README comment test doesn't pollute other tests and validates the full end-to-end flow.

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
model: opus
agents: 1
started_at: 2026-09-27T20:53:42Z
last_iteration_at: 2026-09-27T20:53:42Z
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

