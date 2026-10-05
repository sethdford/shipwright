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
      "summary": "Contains 'Cannot find module' error pattern with 'npm i' fix in build/test stages. Common blocker for build stage execution that could prevent E2E test from running."
    },
    {
      "file": "failures.json (with timeout data)",
      "relevance": 65,
      "summary": "Contains resolved timeout failures and unresolved database connection issues from test execution. E2E tests often encounter timeout and resource initialization issues during build."
    },
    {
      "file": "index.json",
      "relevance": 60,
      "summary": "Documents test_failure pattern in build stage with timeout issues and fix to increase timeout value. Directly applicable to build stage troubleshooting."
    },
    {
      "file": "success-patterns.json (test-repo-outcomes)",
      "relevance": 45,
      "summary": "Generic test outcome pattern with build stage and npm test strategy. Basic reference for E2E test execution approach in build stage."
    },
    {
      "file": "success-patterns.json (test-repo-comptime)",
      "relevance": 40,
      "summary": "Timed fix pattern with build/test stages and npm test execution. Relevant for understanding timing constraints in E2E test builds."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 15 new discoveries
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
- **e2e-test-reliability**: Critical for this issue—README tests are prone to state pollution and cleanup failures; proper test isolation is the difference between a flaky test that passes locally and one that passes consistently in CI.
- **documentation**: The test itself should be self-documenting with clear assertions and comments explaining why each step matters—future developers will debug this test and need to understand its intent.

## E2E Test Reliability Patterns

**Test Isolation**: Each E2E test run must start from a clean state and leave no artifacts behind. For README modifications:
- Use a temporary branch or separate test file, never modify the canonical README directly
- Restore original state in teardown, even on test failure (use trap handlers in bash)
- Verify idempotency: running the test twice should produce the same result

**Environment Detection**: E2E tests behave differently in CI vs. local development.
- Detect CI environment (`$CI`, `$GITHUB_ACTIONS`) and skip cleanup assertions that require git push access
- Mock or stub external dependencies (GitHub API calls) when running locally
- Log environment context (OS, shell version, git version) to failures for debugging

**Flakiness Signatures**: These patterns indicate your E2E test will fail randomly:
- Hardcoded file paths (use `$TMPDIR` or temp directories)
- Time-dependent assertions (sleep, timestamp checks) without jitter tolerance
- Concurrent test runs sharing state (temp files, git branches)
- Network calls without retry logic (GitHub API rate limits, DNS latency)

**Debugging E2E Failures**: When a test passes locally but fails in CI:
1. Capture full stdout/stderr before cleanup (write to artifact directory)
2. Log the git state: `git status`, `git log --oneline -5`
3. Print environment: `env | grep -E 'CI|GITHUB|PATH'`
4. Re-run the test in CI with `--verbose` if available; CI logs > local reproduction

**Test Structure**: Prefer a three-phase pattern:
```bash
# Phase 1: Setup (idempotent)
# Phase 2: Execute (the actual workflow being tested)
# Phase 3: Verify + Cleanup (always runs, even on error)
```

## Documentation Expertise

For documentation-focused issues, apply a lightweight approach:

### Scope
- Focus on accuracy over comprehensiveness
- Update only what's actually changed or incorrect
- Remove outdated information rather than marking it deprecated
- Keep examples current and runnable

### Writing Style
- Use active voice and present tense
- Lead with the most important information
- Use code examples for anything technical
- Keep paragraphs short — 2-3 sentences max

### Structure
- Start with a one-line summary of what this documents
- Include prerequisites and setup if applicable
- Provide a quick start / most common usage first
- Put advanced topics and edge cases later

### Skip Heavy Stages
This is a documentation change. The following pipeline stages can be simplified:
- **Design stage**: Skip — documentation doesn't need architecture design
- **Build stage**: Focus on file edits only, no compilation needed
- **Test stage**: Verify links work and examples are syntactically correct
- **Review stage**: Focus on accuracy and clarity, not code patterns

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **What to Document**: List of documentation files created/modified with specific sections added to each
2. **What to Skip**: Explicitly state which topics are NOT documented and why (e.g., "Advanced topic X is out of scope for this issue")
3. **Audience**: Who will read this documentation (developers, users, operators) and what level of detail is appropriate

If any section is not applicable, explicitly state why it's skipped.
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-10-05T09:03:49Z
last_iteration_at: 2026-10-05T09:03:49Z
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

