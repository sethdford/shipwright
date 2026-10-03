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
      "summary": "Contains build-stage failure patterns with test_failure signature and timeout fixes; directly applicable to troubleshooting build issues"
    },
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 70,
      "summary": "Fleet-wide build error pattern ('Cannot find module') seen 2x across repos; common npm/node dependency issue during build stage"
    },
    {
      "file": "success-patterns.json (test-repo-789)",
      "relevance": 55,
      "summary": "Success pattern executed in build stage with completion time/cost data; demonstrates build-stage workflow even if domain unrelated"
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 50,
      "summary": "Two generic build-stage success patterns with standard npm test strategy; minimal specific guidance but covers build execution"
    },
    {
      "file": "success-patterns.json (test-repo-comptime)",
      "relevance": 45,
      "summary": "Build-stage pattern with timing/cost data and multiple stages executed (intake→build→test); useful for understanding build phase duration"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 9 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Add missing test suites for the 5 untested scripts — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Add missing test suites for the 5 untested scripts

## Implementation Checklist
- [ ] Write the event-schema-sync suite with a fixture repo (9 tests)
- [ ] Write the test-all suite with an isolated runner copy and fake suites (10 tests)
- [ ] Write the tmux-role-color suite with a `tmux` mock and colour table (12 tests)
- [ ] Write the tmux-status suite covering the widgets, heartbeats and walk-up search (12 tests)
- [ ] Write the tracker-github suite with a recording `gh` mock (16 tests)
- [ ] Resolve decision 1 (status widget parsing)
- [ ] Resolve decision 2 (tracker `NO_GITHUB` guard)
- [ ] Add the suites to `package.json` `test:legacy-chain`
- [ ] Run `shipwright docs sync`
- [ ] Run each new suite alone, twice, to check it gives the same result every time
- [ ] Run `bash scripts/sw-test-all.sh --pattern -test` and check the new suites run without timeouts
- [ ] Run the full `npm test`
- [ ] All 5 `*-test.sh` files exist, can be executed, and each covers its main paths plus at least one failure or edge case.
- [ ] Each suite exits 0 when run alone and when run through `npm test`.
- [ ] The suites appear in `package.json` and in the CLAUDE.md test-suites table.
- [ ] Scripts-with-tests reaches 105/105.
- [ ] Tests never touch the real `config/event-schema.json`, `~/.shipwright`, `tmux` or GitHub.
- [ ] Tests never start the real test runner from inside itself.

## Context
- Pipeline: standard
- Branch: test/add-missing-test-suites-for-the-5-untest-7552
- Issue: #7552
- Generated: 2026-10-03T12:18:22Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests validate real workflows end-to-end; this skill ensures the test properly exercises the entire flow of adding comments to README with meaningful assertions
- **shell-script-test-harness-design**: Shipwright's bash test suites follow strict patterns for parallelism and PASS/FAIL counting; this test must integrate seamlessly into the established harness without breaking conventions

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

## Shell Script Test Harness Design

Shipwright test suites follow a strict pattern for consistency, parallelism, and compatibility. This skill guides creation of new test suites that fit seamlessly into the existing 100+ suite ecosystem.

### Core Pattern

Each test file (`scripts/sw-NAME-test.sh`) implements these elements:

1. **Header**: `#!/bin/bash`, `set -euo pipefail`, VERSION constant, source `scripts/lib/compat.sh`
2. **Mock binaries**: Temporary `$TMPDIR/bin/` directory prepended to PATH; mocks match real command signatures
3. **Test functions**: Named `test_<case>()`, each returns success/failure; no output on success
4. **Counter tracking**: Global `PASS=0 FAIL=0` counters incremented in trap handlers
5. **Output format**: Colored `PASS test_name` / `FAIL test_name` at end; one line per test
6. **Cleanup**: ERR trap calls `cleanup()` which removes `$TMPDIR`; exit code = FAIL count

### Mock Binary Strategy

- Store in `TMPDIR/bin/mockbin.sh` wrapper that routes calls by `$1` to stubbed functions
- Each mock must replicate the real command's exit code and output signature
- Use `echo` to stdout, `echo >&2` to stderr; match exact text if tests depend on it
- Example: `mock_git()` must support `git status --porcelain`, `git log`, `git diff` with real-looking output

### Edge Cases & Failure Paths

For each script being tested, identify:
- **Happy path**: Expected inputs, expected outputs
- **Missing input**: Required arguments omitted (e.g., missing repo path)
- **Permission error**: File/dir not readable (mock with `exit 1` + error message)
- **Invalid data**: Malformed JSON, empty files, unexpected format
- **External command failure**: Dependency missing or broken (mock exits 127)
- **Boundary**: Empty string, very large input, special characters

At least 3-4 test cases per script, covering happy path + 1-2 critical failures.

### Parallelism & Isolation

- Each test function creates its own `$TMPDIR/test_$RANDOM` subdirectory
- Never write to `/tmp` directly or use predictable temp names
- Source files from the repo read-only (no modification)
- Mock binaries are temporary and local to that test run
- No global state shared between test functions

### Bash 3.2 Compatibility

- No `declare -A` (associative arrays)
- No `readarray` or `mapfile`
- No `${var,,}` or `${var^^}` (case conversion)
- No `[[ =~ ]]` regex (use `[[ == ]]` + glob patterns or `grep`)
- No `printf %q` (use `printf %s` + manual escaping for JSON)
- Test with: `bash --version` reports 3.2+ before shipping

### Test Registration

Add to `package.json` `"test"` script:
```json
"test": "npm run test:all",
"test:all": "./scripts/sw-test-all.sh",
...
"test:NAME": "./scripts/sw-NAME-test.sh"
```

`sw-test-all.sh` discovers all `*-test.sh` files and runs them sequentially, summing PASS/FAIL counts.

### Debugging Failed Tests

- Run `./scripts/sw-NAME-test.sh` directly to see colored PASS/FAIL output
- Add `set -x` at top to trace execution
- Check `$TMPDIR/test_*/` contents after failure (don't clean up yet)
- Verify mock binary routing with `bash -x scripts/sw-NAME-test.sh 2>&1 | grep mock`
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-10-03T13:27:12Z
last_iteration_at: 2026-10-03T13:27:12Z
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

