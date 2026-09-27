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
      "relevance": 80,
      "summary": "Common 'Error: Cannot find module' failure during build stage with 'npm i' fix. Seen across multiple repos, highly applicable to E2E test builds"
    },
    {
      "file": "index.json",
      "relevance": 75,
      "summary": "Build stage test failure pattern with practical fix 'Increase timeout value in test setup'. Directly relevant for E2E test implementation which often has timing concerns"
    },
    {
      "file": "failures.json (second)",
      "relevance": 65,
      "summary": "Contains actual failure signatures including timeouts and connection issues. Provides pattern context for debugging build-stage test execution"
    },
    {
      "file": "success-patterns.json (test-repo-comptime)",
      "relevance": 50,
      "summary": "Pattern with build and test stages involving test.sh file modifications. Shows successful test-related build work with execution context"
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 45,
      "summary": "Two patterns with build stage execution, including test file modifications. Demonstrates build-stage patterns though generic content"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 5 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for `shipwright doctor --fix` Auto-Remediation for Common Setup Failures — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — `shipwright doctor --fix` Auto-Remediation for Common Setup Failures

## Implementation Checklist
- [ ] T1: Fix-tracking primitives and `--help` (step 1). *Blocks T3–T7.*
- [ ] T2: Convert the existing `doctor_fix_*` helpers from echo to exit codes (step 2). *Depends on T1.*
- [ ] T3: `doctor_fix_path` and `_doctor_check_path`, including fish and backup handling (step 3). *Depends on T1.*
- [ ] T4: `doctor_fix_hooks_exec` and the repaired `doctor_fix_hooks` (steps 4–5). *Depends on T1.*
- [ ] T5: Wire fix-and-recheck into the overlay, hooks, PATH, subcommands and scaffold checks (step 6). *Depends on T2–T4.*
- [ ] T6: `doctor_not_fixable` on the dependency checks (step 7). *Depends on T1.*
- [ ] T7: Replace the stub re-run with the real summary (step 8). *Depends on T5–T6.*
- [ ] T8: Tests T-a through T-g (step 9). *Depends on T5–T7.*
- [ ] T9: Strengthen existing Test 25, which currently passes on any output containing "fixed". *Depends on T7.*
- [ ] T10: shellcheck, `bash -n`, and a Bash 3.2 lint (no `declare -A`, no `${x,,}`, no `readarray`).
- [ ] T11: Run the full `npm test` and update docs if they mention doctor flags.
- [ ] `shipwright doctor --fix` re-checks each fixable failing check right after fixing it, and the summary counts reflect the post-fix state (T-a, T-c, T-g).
- [ ] Missing tmux, jq, claude, node and git are left as diagnostics with their existing guidance, and are listed as "not auto-fixable" (T-d).
- [ ] Every file change made under `--fix` is printed as `changed: <action> <path>`. Only `.claude/`, `~/.shipwright`, `~/.claude/hooks`, `~/.tmux*`, the shell rc file and Shipwright's install dir are ever written. Backups are made before any rc or tmux.conf edit.
- [ ] `--fix-dry` changes nothing (T-e).
- [ ] Output of plain `doctor` without `--fix` is unchanged. `sw-doctor-test.sh`, `sw-init-test.sh` and `sw-setup-test.sh` pass.
- [ ] shellcheck is clean, the code is Bash 3.2 compatible, and `VERSION` is unchanged.

## Context
- Pipeline: autonomous
- Branch: feat/-shipwright-doctor-fix-auto-remediation-3153
- Issue: #3153
- Generated: 2026-09-27T03:47:05Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E test design requires deliberate test scenario selection, setup/teardown patterns, and execution strategies to ensure reproducibility and avoid false failures
- **shell-script-remediation-patterns**: Test cleanup (removing added comments) must be non-destructive, idempotent (safe to run multiple times), and verifiable—patterns prevent orphaned test artifacts in README

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

## Shell Script Auto-Remediation Safety Patterns

Auto-remediation must be non-destructive, idempotent, and verifiable. These patterns prevent corrupting user state.

### Core Principles

**1. Atomic Writes**: Never modify files in-place; use temp file + mv pattern:
```bash
tmpfile=$(mktemp)
# populate tmpfile
mv "$tmpfile" "$target"  # atomic, all-or-nothing, crash-safe
```

**2. Idempotency**: Fix must be safe to run twice. Structure as:
```bash
if ! check_passes; then
  apply_fix
  if check_passes; then
    echo "FIXED: check now passes"
  else
    echo "SKIPPED: fix attempted but check still fails" >&2
    return 1  # leave unchanged if fix fails
  fi
else
  echo "ALREADY_OK: check already passes"
fi
```

**3. Verification Loop**: Re-run check after every fix. Never assume fix succeeded.

**4. Shell RC Backups**: When editing .bashrc/.zshrc/.config/fish/config.fish:
```bash
backup_rc="${rc_file}.bak.$(date +%s)"
cp "$rc_file" "$backup_rc"
echo "Backup: $backup_rc"
# make changes to $rc_file
if verification_fails; then
  mv "$backup_rc" "$rc_file"
  echo "Restored from backup"
else
  rm "$backup_rc"  # only if truly fixed
fi
```

**5. Permission Checks**: Verify write access before attempting fixes:
```bash
if ! [ -w "$target_dir" ]; then
  echo "DIAGNOSTIC: cannot write to $target_dir, skipping auto-fix" >&2
  return 1
fi
```

**6. Clear Reporting**: Report exactly what changed:
- File created/modified/deleted
- Bytes added/removed
- Verification result (pass/fail)
- Backup location if applicable

### Fixable Checks (Auto-Remediate)
- Create missing `.claude/` directories
- Install missing hook symlinks (with verification)
- Add missing PATH entries to shell rc files
- Create missing config skeleton files
- Fix symlink targets (if safe)

### Diagnostic-Only Checks (Never Auto-Fix)
- Missing system binaries (tmux, jq, node) — requires package manager
- Permission errors on system paths — requires chmod/sudo
- GitHub/API access issues — requires OAuth, cannot automate safely
- Version mismatches on installed tools — requires manual update
- Corrupt or conflicting configs — too risky to auto-remediate

### Test Patterns
- Test 1: Fix applied, check passes on re-run
- Test 2: Running --fix again makes no changes (idempotency)
- Test 3: Non-fixable check skipped with diagnostic message
- Test 4: Shell rc backed up, verified, restored if fix failed
- Test 5: Permission error caught, reported, no modification attempted
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-09-27T04:10:57Z
last_iteration_at: 2026-09-27T04:10:57Z
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

