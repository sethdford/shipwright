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
      "relevance": 75,
      "summary": "Direct build stage pattern index with test_failure signature and test setup recommendations. Relevant for understanding common build stage issues."
    },
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 70,
      "summary": "Recent cross-repo build pattern (2026-09-19): 'Error: Cannot find module' with npm install fix. Practical reference for common build dependency issues."
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 60,
      "summary": "Low-complexity build stage patterns with 1-iteration completions. Relevant reference for simple automated test implementations."
    },
    {
      "file": "failures.json (detailed)",
      "relevance": 55,
      "summary": "Common test stage failure patterns (timeouts, database issues) with documented root causes and fixes. Useful for anticipating build/test failures."
    },
    {
      "file": "success-patterns.json (test-repo-comptime)",
      "relevance": 50,
      "summary": "Pattern spanning intake→build→test stages with npm test strategy. Shows execution profile and cost for multi-stage builds."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 4 new discoveries
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Add pre-build validation checks to catch broken environments before the build loop starts — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Add pre-build validation checks to catch broken environments before the build loop starts

## Implementation Checklist
- [ ] **Validation Script Created**: `scripts/sw-pre-build-validate.sh` exists, runs 7+ checks, outputs valid JSON
- [ ] **Helper Library Created**: `scripts/lib/pre-build.sh` with reusable check functions tested in isolation
- [ ] **Loop Integration**: `scripts/sw-loop.sh` calls validation before iteration 1; abort on fatal, inject warnings into context
- [ ] **Event Logging**: Pre-build events registered in `config/event-schema.json` and emitted by validation script
- [ ] **Context Injection**: Validation results merged into `progress.md` and `error-summary.json`; iteration 1 receives structured feedback
- [ ] **Auto-Fix Support**: npm install auto-triggered on missing dependencies (if configured)
- [ ] **Test Coverage**: 15+ tests covering happy path, all failure modes, timeouts, race conditions
- [ ] **Configuration**: `daemon-config.json` template documents all pre-build options
- [ ] **Documentation**: `.claude/CLAUDE.md` has "Pre-Build Validation" section with examples and troubleshooting
- [ ] **No Regressions**: Existing loop tests still pass; pre-build validates on enabled but doesn't break disabled
- [ ] **Performance**: Validation completes in <15s on typical projects
- [ ] **Bash 3.2 Compliance**: All scripts use bash 3.2 compatible syntax (tested with `bash --version 3.2`)
- [ ] **Safety Checks**: Re-validation logic in place to catch environment changes between validation and iteration 1 start

## Context
- Pipeline: autonomous
- Branch: ci/issue-6428
- Issue: none
- Generated: 2026-09-26T12:11:01Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Plan, design, and implement the E2E test structure; ensure the test covers the main flow (adding comment to README) and validates actual file modification
- **build-environment-validation**: Verify test environment has correct dependencies (file system access, README file availability, necessary tooling) before test execution

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

## Build Environment Validation Pattern

Pre-build validation catches environment failures (broken dependencies, syntax errors, test-runner startup) before wasting a full loop iteration. The pattern integrates tightly with the build loop's error-feedback system.

### Core Contract

**Inputs:**
- Changed files (from git diff)
- Project type detection (package.json, Cargo.toml, etc.)
- Config flag `loop.pre_build_validate_enabled` (default: true)

**Outputs on failure:**
- `error-summary.json` matching the shape the loop already reads
- Each error entry: `{"line": "...", "message": "..."}`
- Exit code 1 (non-fatal; loop treats it as a failed pre-flight, not a fatal error)

**Outputs on success:**
- Clean exit code 0
- Optional validation log file for observability

### Check Categories

1. **Dependency Install** — Run package manager (npm ci, cargo fetch, pip install --dry-run) with a short timeout (10s). Catches missing deps, lockfile corruption, network issues.

2. **Syntax Check** — Lint only changed files using the project's existing linter (eslint, cargo check, mypy) if available. Skip if no linter configured. Report first 5 errors to avoid overwhelming context.

3. **Test Runner Startup** — Run test command with `--help` or `--list` (or equivalent) to verify the test runner even starts. Catches test config errors without running actual tests.

### Integration Points

- **Error Feedback**: When validation fails, `sw-loop.sh` reads `error-summary.json` and injects it as structured context into the next iteration. Pre-flight failures surface the same way as loop errors.

- **Conditional Execution**: Check `daemon-config.json` for `loop.pre_build_validate_enabled`. Respect the flag; allow skipping for environments where pre-flight is not applicable.

- **No Retry**: Pre-flight failures don't auto-retry the validation itself. The loop's normal retry logic handles re-attempts on the full build.

### Implementation Checklist

- [ ] Read project type from context (already available in loop)
- [ ] Implement `pre_build_validate()` in sw-loop.sh
- [ ] Generate `error-summary.json` on failure with full file path + error message per check
- [ ] Add `pre_build_validate_enabled` config flag (default true)
- [ ] Test with mock projects: working env, missing deps, syntax error, broken test config
- [ ] Document in CLAUDE.md Build Loop section: "Pre-Build Validation" subsection
- [ ] Wire into loop's error injection: `pre_build_validate() || { cat error-summary.json | inject_to_prompt; }`

### Failure Handling

Pre-flight failures are logged but not fatal—the loop enters with the validation error as structured context, giving the agent a chance to fix and retry. If pre-flight fails 3 times in a row, the loop's circuit-breaker trips as normal (treating it like any other error).
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-09-26T12:40:20Z
last_iteration_at: 2026-09-26T12:40:20Z
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

