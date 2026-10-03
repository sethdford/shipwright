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
      "relevance": 75,
      "summary": "Common 'Cannot find module' error in build stage with proven npm i fix; seen across multiple repos"
    },
    {
      "file": "index.json",
      "relevance": 70,
      "summary": "Explicit test_failure pattern for build stage seen 5 times with recommended fix (increase timeout)"
    },
    {
      "file": "failures.json",
      "relevance": 65,
      "summary": "Actual timeout failures in test stage with documented root causes and fixes; includes resolved and unresolved issues"
    },
    {
      "file": "success-patterns.json (test-repo-789)",
      "relevance": 55,
      "summary": "Build stage timeout fix pattern requiring 3 iterations; high complexity scenario relevant to autonomous testing"
    },
    {
      "file": "success-patterns.json (test-final-working)",
      "relevance": 50,
      "summary": "Daemon timeout handler in build stage; medium complexity, 2 iterations needed"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 15 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Add missing test suites for the 5 untested scripts — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
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
- **shell-script-test-harness-design**: Shipwright's test harness enforces strict patterns (PASS/FAIL counting, atomic cleanup, isolation via temp dirs); this test must comply to integrate into `npm test` and avoid race conditions.
- **systematic-debugging**: Automated E2E tests are prone to flakiness and environmental sensitivity; this phase ensures robust error diagnosis and deterministic failure modes if setup or execution goes wrong.

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

## Systematic Debugging: Root Cause Analysis

A previous attempt at this stage FAILED. Do NOT blindly retry the same approach. Follow this 4-phase investigation:

### Phase 1: Evidence Collection
- Read the error output from the previous attempt carefully
- Identify the EXACT line/file where the failure occurred
- Check if the error is a symptom or the root cause
- Look for patterns: is this a known error type?

### Phase 2: Hypothesis Formation
- List 3 possible root causes for this failure
- For each hypothesis, identify what evidence would confirm or deny it
- Rank hypotheses by likelihood

### Phase 3: Root Cause Verification
- Test the most likely hypothesis first
- Read the relevant source code — don't guess
- Check if previous artifacts (plan.md, design.md) are correct or flawed
- If the plan was correct but execution failed, focus on execution
- If the plan was flawed, document what was wrong

### Phase 4: Targeted Fix
- Fix the ROOT CAUSE, not the symptom
- If the previous approach was fundamentally wrong, choose a different approach
- If it was a minor error, make the minimal fix
- Document what went wrong and why the new approach is better

IMPORTANT: If you find existing artifacts from a successful previous stage, USE them — don't regenerate from scratch.

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Root Cause Hypothesis**: List 3 possible root causes ranked by likelihood with specific evidence that would confirm/deny each
2. **Evidence Gathered**: Exact file:line location of failure, error messages, logs, code examination results, artifact validation (plan.md, design.md correctness)
3. **Fix Strategy**: Description of the ROOT CAUSE fix (not the symptom), with rationale for why this approach differs from the previous failed attempt
4. **Verification Plan**: How to verify the fix works (test cases, specific checks, expected behavior confirmation)

If any section is not applicable, explicitly state why it's skipped.
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-10-03T18:48:16Z
last_iteration_at: 2026-10-03T18:48:16Z
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

