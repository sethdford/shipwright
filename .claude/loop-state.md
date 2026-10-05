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
      "summary": "Contains build-stage test_failure pattern with concrete fix (increase timeout). Directly applicable to E2E test debugging."
    },
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 75,
      "summary": "Tracks 'Cannot find module' build errors across repos with npm install fix. Common blocker in E2E test setup phases."
    },
    {
      "file": "failures.json",
      "relevance": 70,
      "summary": "Documents timeout and database connection failures with root causes and fixes. Timeout patterns directly relevant to E2E test reliability."
    },
    {
      "file": "success-patterns.json (test-repo-comptime)",
      "relevance": 60,
      "summary": "Multi-stage pattern (intake→build→test) showing completion time (1234s) and cost tracking. Provides baseline for E2E test execution estimation."
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 50,
      "summary": "Two build-stage patterns with npm test strategy. Generic templates for build phase patterns, applicable to readme comment E2E scenario."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 11 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Split sw-memory.sh into capture, query, and pattern-aggregation modules — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Split sw-memory.sh into capture, query, and pattern-aggregation modules

## Implementation Checklist
- [ ] T1: Record the baseline (test counts, help output, function list, `declare -f` bodies)
- [ ] T2: Create `lib/memory-common.sh` (paths, repo identity, embedding store) with a guard
- [ ] T3: Create `lib/memory-capture.sh` (9 write functions) with a guard
- [ ] T4: Create `lib/memory-query.sh` (9 read/inject functions) with a guard
- [ ] T5: Create `lib/memory-aggregate.sh` (global rollup, finalize, DORA baseline, stats, A/B, decay) with a guard
- [ ] T6: Create `lib/memory-admin.sh` (show, search, forget, export, import) with a guard
- [ ] T7: Reduce `sw-memory.sh` to bootstrap + strict module loader + help + router
- [ ] T8: Mechanical equivalence check (function set and `declare -f` bodies identical)
- [ ] T9: Line-count (≤800) and Bash 3.2 grep, plus `bash -n` and shellcheck gates
- [ ] T10: Add `sw-lib-memory-modules-test.sh` and register it in `package.json`
- [ ] T11: Add the lib files to the `sw-upgrade.sh` manifest
- [ ] T12: ADR plus CLAUDE.md architecture note; run `shipwright docs sync`
- [ ] T13: `sw-memory-test.sh` passes **unmodified**; related suites pass; `npm test` green
- [ ] `sw-memory.sh` ≤ ~200 lines and contains only bootstrap, loader, help and router
- [ ] 5 `lib/memory-*.sh` modules, each ≤ 800 lines, each with a double-source guard
- [ ] Function set and bodies mechanically identical to the baseline
- [ ] `sw-memory-test.sh` passes with **zero** edits; the new module suite passes; `npm test` green
- [ ] `shipwright memory help` output is byte-identical to the baseline
- [ ] No `declare -A`, `readarray`, `mapfile`, `${,,}` or `${^^}` in the new files; `bash -n` is clean
- [ ] `sw-upgrade.sh` installs the new lib files; ADR written; docs synced

## Context
- Pipeline: standard
- Branch: refactor/split-sw-memory-sh-into-capture-query-an-7690
- Issue: #7690
- Generated: 2026-10-05T07:01:49Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests need clear objectives, proper isolation, and reproducibility—this skill ensures the test validates the README comment workflow reliably across environments
- **bash-script-modularization**: If the E2E test harness is bash-based, modularize setup/teardown and test cases to avoid brittle, monolithic test code that fails on minor changes

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

## Bash Script Modularization: Splitting Monoliths into Focused Modules

When decomposing large bash scripts (1500+ lines), follow this pattern used successfully in sw-loop.sh:

### 1. Module Boundaries
- **Identify cohesive responsibilities**: Group related functions (e.g., pattern capture logic, query/lookup logic, aggregation/stats logic)
- **Minimize cross-module dependencies**: Each module should own its data and transformations; prefer passing JSON/stdout over shared state
- **Keep CLI dispatcher thin**: The parent script routes commands to submodules; logic stays in the modules, not the dispatcher

### 2. Shared State & Functions
- **Extract common utilities early**: Logging, JSON parsing, file operations go to a `lib/` directory sourced by all modules
- **Namespace function names**: Prefix functions by module (`memory_capture_*`, `memory_query_*`) to avoid collisions when all are sourced
- **Avoid global state**: Use function arguments and return values; globals are hard to trace across modules

### 3. Bash 3.2 Compatibility (Hard Constraint)
- **No associative arrays** (`declare -A`) — use flat JSON or multiple parallel arrays if needed
- **No `readarray`** — use `while read` loops
- **No parameter expansion** like `${var,,}` (lowercase) — use `tr '[A-Z]' '[a-z]'`
- **Test on bash 3.2**: CI should verify `bash --version` reports 3.2.x compatibility

### 4. Test Harness Updates
- **Keep test structure**: Old test suite should pass with minimal changes (sourcing updates only)
- **Source new modules**: Instead of sourcing monolith, source CLI dispatcher which sources submodules
- **Test module boundaries**: Add tests that verify each module works in isolation (unit tests) and together (integration tests)
- **Mock cross-module calls**: When testing one module, mock its dependencies on others to isolate failures

### 5. CLI Dispatcher Pattern
```bash
#!/usr/bin/env bash
set -euo pipefail
VERSION=<from-parent>

source "$(dirname "$0")/lib/memory-common.sh"  # Shared utilities
source "$(dirname "$0")/sw-memory-capture.sh"  # Capture module
source "$(dirname "$0")/sw-memory-query.sh"    # Query module
source "$(dirname "$0")/sw-memory-aggregate.sh" # Aggregate module

case "$1" in
  capture)    memory_capture_"${2:-}" "${@:3}" ;;
  query)      memory_query_"${2:-}" "${@:3}" ;;
  aggregate)  memory_aggregate_"${2:-}" "${@:3}" ;;
  show)       memory_query_show "${@:2}" ;;  # Backwards compat
  *)          echo "Unknown command: $1" >&2; exit 1 ;;
esac
```

### 6. Version & Documentation
- **Keep VERSION in dispatcher**: Single source of truth for `shipwright memory --version`
- **Update CLAUDE.md**: Document the new module structure and responsibilities in the Architecture section
- **Preserve command help**: `shipwright memory --help` must list all subcommands; delegate to modules if needed

### 7. Performance & Debugging
- **Lazy loading** (if performance-critical): Source modules only when their commands are invoked
- **Trace mode**: Add `SW_TRACE=1 shipwright memory ...` to see which module executed which function
- **Benchmarks**: Compare memory lookup/aggregation speed before/after split; if slower, profile and optimize at module boundaries

### 8. Common Pitfalls
- **Circular sourcing**: Module A sources Module B sources Module A → sourcing loop. Use explicit exports or a lib file only.
- **Subshell bugs**: `cmd | while read` in a module runs in a subshell; variables modified in the loop are lost. Use `while read; done < <(cmd)`.
- **Atomic file writes**: If modules write shared state (e.g., pattern files), use atomic writes (tmp file + mv) to avoid corruption.
- **Test isolation**: If tests modify shared files (memory patterns), clean them up after each test so modules don't interfere.

### Validation Checklist
- All `shipwright memory <cmd>` routes correctly to the right module
- Existing test suite passes (sw-memory-test.sh) with only sourcing changes
- No module exceeds 800 lines (excluding tests and comments)
- Bash 3.2 compatibility verified (no modern syntax)
- Performance regression < 5% on typical operations (lookup, aggregation)
- Module interfaces documented (function signatures, expected inputs/outputs)
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-10-05T08:17:10Z
last_iteration_at: 2026-10-05T08:17:10Z
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

