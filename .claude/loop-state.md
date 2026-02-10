---
goal: "Add pipeline dry-run summary with stage timing estimates

Implementation plan (follow this exactly):
The plan file is in a protected directory. Let me present the plan directly.

## Implementation Plan: Add Pipeline Dry-Run Summary with Stage Timing Estimates

### Analysis Summary

After thorough codebase exploration, the `dry_run_summary()` function in `scripts/sw-pipeline.sh:972-1094` **already implements the full feature**:
- Stage timing estimates via median calculation from historical `stage.completed` events
- Per-stage cost estimates via median from `cost.record` events
- Model resolution per stage (CLI > stage config > template default > `opus`)
- Total duration/cost summation with budget remaining display
- Box-drawing table with `Stage | Est. Duration | Model | Est. Cost` columns
- Graceful "no data" / "—" when no history exists

The corresponding tests also already exist (`sw-pipeline-test.sh:813-888`).

**However, there are two bugs preventing the tests from passing:**

### Bug 1: Events File Path Mismatch
- **Pipeline script** reads from `~/.shipwright/events.jsonl` (`sw-pipeline.sh:51`)
- **Test file** writes events to `~/.claude-teams/events.jsonl` (`sw-pipeline-test.sh:817`)
- The test harness uses the **old pre-rebrand path** while the pipeline uses the **new path**

### Bug 2: Stale `cct-cost.sh` Reference
- `sw-pipeline.sh:1087` references `cct-cost.sh` (pre-rebrand name)
- Should be `sw-cost.sh` — causes budget display to silently fail

---

### Files to Modify

| File | Change |
|------|--------|
| `scripts/sw-pipeline-test.sh` | Fix all `~/.claude-teams/` → `~/.shipwright/` references (7 occurrences across lines 49, 51, 368, 369, 375, 817, 877) |
| `scripts/sw-pipeline.sh` | Fix `cct-cost.sh` → `sw-cost.sh` on line 1087 |

---

### Implementation Steps

1. **Fix events path in test `setup_env()`** — Update backup path from `~/.claude-teams/events.jsonl` to `~/.shipwright/events.jsonl` (lines 49, 51)
2. **Fix events path in test `cleanup_env()`** — Update restore/cleanup path (lines 368, 369, 375)
3. **Fix events path in `test_dry_run_summary_with_history()`** — Update seed directory (line 817)
4. **Fix events path in `test_dry_run_summary_no_history()`** — Update cleanup path (line 877)
5. **Fix cost script reference in `dry_run_summary()`** — Change `cct-cost.sh` to `sw-cost.sh` (line 1087)
6. **Run targeted dry-run tests** to verify fixes
7. **Run full pipeline test suite** to verify no regressions
8. **Run full `npm test`** to verify all test suites pass

---

### Task Checklist

- [ ] Task 1: Fix `~/.claude-teams/` → `~/.shipwright/` in `setup_env()` backup logic
- [ ] Task 2: Fix `~/.claude-teams/` → `~/.shipwright/` in `cleanup_env()` restore logic
- [ ] Task 3: Fix `~/.claude-teams/` → `~/.shipwright/` in `test_dry_run_summary_with_history()` event seeding
- [ ] Task 4: Fix `~/.claude-teams/` → `~/.shipwright/` in `test_dry_run_summary_no_history()` cleanup
- [ ] Task 5: Fix `cct-cost.sh` → `sw-cost.sh` in `dry_run_summary()` budget check
- [ ] Task 6: Run dry-run tests to verify fixes
- [ ] Task 7: Run full pipeline test suite (no regressions)
- [ ] Task 8: Run full `npm test` (all suites pass)

---

### Testing Approach

1. **Targeted**: Run the three dry-run tests individually to validate each fix
2. **Pipeline suite**: `bash scripts/sw-pipeline-test.sh` — all 17 tests pass
3. **Full suite**: `npm test` — all 11 test files pass
4. **Manual**: `shipwright pipeline start --goal "test" --dry-run` for visual verification

---

### Definition of Done

- [ ] `--dry-run` shows timing estimates when historical data exists
- [ ] `--dry-run` gracefully shows "no data" when no history
- [ ] Existing `--dry-run` behavior preserved (shows stages, exits without running)
- [ ] Cost estimate uses model routing from template
- [ ] Budget remaining uses correct `sw-cost.sh` script
- [ ] All three dry-run tests pass
- [ ] Full pipeline test suite passes
- [ ] Full `npm test` passes

Follow the approved design document:
All 7 occurrences confirmed. Here's the ADR:

---

# Design: Add pipeline dry-run summary with stage timing estimates

## Context

The `--dry-run` flag on `shipwright pipeline start` should display a table of enabled stages with per-stage timing estimates (from historical data), model routing, and cost estimates — then exit without executing anything. This helps operators preview pipeline cost and duration before committing to a run.

The feature implementation already exists in `scripts/sw-pipeline.sh:972-1094` (`dry_run_summary()`), including:
- Median duration from `stage.completed` events in `~/.shipwright/events.jsonl`
- Median cost from `cost.record` events
- Model resolution (CLI arg > stage config > template default > `"opus"`)
- Box-drawing table output with totals row
- Budget remaining via the cost script

Corresponding tests exist in `scripts/sw-pipeline-test.sh:813-888` (tests 16 and 17).

**The feature is broken by two post-rebrand bugs:**

1. **Events file path mismatch**: The pipeline reads from `~/.shipwright/events.jsonl` (line 51), but the test harness writes to / cleans up `~/.claude-teams/events.jsonl` — the pre-rebrand path. Tests seed data the pipeline never sees.
2. **Stale cost script reference**: `dry_run_summary()` calls `cct-cost.sh` (line 1087), the pre-rebrand name. The script was renamed to `sw-cost.sh`. Budget display silently fails.

No new code needs to be written. This is a pure bug-fix task — correcting stale paths left behind during the `cct` → `sw` rebrand.

## Decision

**Fix the two stale references in place.** No new abstractions, no refactoring.

### Data flow (already implemented, just broken plumbing)

```
events.jsonl  ──grep──►  stage.completed / cost.record JSON lines
                            │
                     sort -n + median
                            │
                     ┌──────▼──────┐
                     │ dry_run_    │
                     │ summary()   │──► box-drawing table to stdout
                     └──────┬──────┘
                            │
                    sw-cost.sh remaining-budget
                            │
                     budget line (if set)
```

### Specific changes

1. **`scripts/sw-pipeline.sh` line 1087**: `cct-cost.sh` → `sw-cost.sh`
   - The `$SCRIPT_DIR/cct-cost.sh` call fails silently (trapped by `|| true`), so no error appears but the budget line is never printed.

2. **`scripts/sw-pipeline-test.sh`** — 7 occurrences of `~/.claude-teams/` → `~/.shipwright/`:
   - `setup_env()` backup: lines 49, 51
   - `cleanup_env()` restore/cleanup: lines 368, 369, 375
   - `test_dry_run_summary_with_history()` event seeding: line 817
   - `test_dry_run_summary_no_history()` cleanup: line 877

### Error handling

The existing `dry_run_summary()` handles all edge cases correctly:
- **No events file**: `[[ -f "$EVENTS_FILE" ]]` guard skips median computation → displays "no data" / "—"
- **Empty or malformed events**: `jq -r '... // empty'` + `|| true` → graceful fallback
- **Non-integer durations**: `=~ ^[0-9]+$` regex guard prevents arithmetic errors
- **No budget set**: `remaining-budget` returns "unlimited" or empty → line suppressed
- **No enabled stages**: Loop iterates zero times → table renders headers + empty totals

## Alternatives Considered

1. **Centralize the events path into a shared constant file** — Pros: prevents future drift if the path changes again. Cons: introduces a new shared file and `source` dependency across all scripts; over-engineering for a two-file fix. The `EVENTS_DIR` / `EVENTS_FILE` variables are already defined at the top of each script; a grep-and-replace during any future rebrand is sufficient.

2. **Make the test harness read `EVENTS_FILE` from the pipeline script** — Pros: single source of truth. Cons: requires sourcing the pipeline script or parsing it, adding fragile coupling. The test harness intentionally operates with its own environment setup to isolate side effects.

3. **Remove `|| true` from the cost script call and let it fail loudly** — Pros: surfaces future breakage. Cons: breaks the dry-run on any system without `sw-cost.sh` (e.g., minimal installs). The silent fallback is intentional — budget display is optional.

## Implementation Plan

- **Files to create**: None
- **Files to modify**:
  - `scripts/sw-pipeline.sh` — 1 line change (line 1087: `cct-cost.sh` → `sw-cost.sh`)
  - `scripts/sw-pipeline-test.sh` — 7 occurrences across 6 lines (49, 51, 368, 369, 375, 817, 877: `~/.claude-teams/` → `~/.shipwright/`)
- **Dependencies**: None (no new packages, no new scripts)
- **Risk areas**:
  - **Test environment pollution**: `setup_env()` / `cleanup_env()` backs up and restores the real `events.jsonl`. After the fix, it will correctly operate on `~/.shipwright/events.jsonl`. If a user's real events file is at the old path, it would no longer be backed up — but since the pipeline itself already reads only from `~/.shipwright/`, this is consistent.
  - **`format_duration` integer guard** (line 1025): The `=~ ^[0-9]+$` regex rejects float durations (e.g., `120.5`). This is fine — `emit_event` writes integer seconds. But if future events include fractional seconds, the display would show "no data" instead of an approximate value. Not a regression from this change.
  - **Median on even-count data**: The `(count + 1) / 2` formula uses integer division, selecting the lower-middle element for even counts rather than averaging. This is acceptable for approximate estimates — not a regression.

## Validation Criteria

- [ ] Test 16 (`test_dry_run_summary_with_history`) passes: table shows `~2m 0s` for intake, `~5m 0s` for plan, `~15m 0s` for build; costs `$0.12`, `$1.45`, `$4.80`; total `~$6.37`
- [ ] Test 17 (`test_dry_run_summary_no_history`) passes: table shows "no data" for all durations and "—" for all costs
- [ ] Test 18 (`test_dry_run_flag`) continues to pass (existing dry-run behavior preserved)
- [ ] Full pipeline test suite (`bash scripts/sw-pipeline-test.sh`) — all tests pass, no regressions
- [ ] Full test suite (`npm test`) — all 11 test files pass
- [ ] `grep -r 'claude-teams' scripts/` returns zero matches (no remaining stale paths)
- [ ] `grep -r 'cct-cost' scripts/` returns zero matches (no remaining stale references)
- [ ] Manual: `shipwright pipeline start --goal "test" --dry-run` renders the table and exits cleanly (with and without historical events present)

Historical context (lessons from previous pipelines):
# Shipwright Memory Context
# Injected at: 2026-02-10T02:22:28Z
# Stage: build

## Failure Patterns to Avoid

## Known Fixes

## Code Conventions

Task tracking (check off items as you complete them):
# Pipeline Tasks — Add pipeline dry-run summary with stage timing estimates

## Implementation Checklist
- [ ] Task 1: Fix `~/.claude-teams/` → `~/.shipwright/` in `setup_env()` backup logic
- [ ] Task 2: Fix `~/.claude-teams/` → `~/.shipwright/` in `cleanup_env()` restore logic
- [ ] Task 3: Fix `~/.claude-teams/` → `~/.shipwright/` in `test_dry_run_summary_with_history()` event seeding
- [ ] Task 4: Fix `~/.claude-teams/` → `~/.shipwright/` in `test_dry_run_summary_no_history()` cleanup
- [ ] Task 5: Fix `cct-cost.sh` → `sw-cost.sh` in `dry_run_summary()` budget check
- [ ] Task 6: Run dry-run tests to verify fixes
- [ ] Task 7: Run full pipeline test suite (no regressions)
- [ ] Task 8: Run full `npm test` (all suites pass)

## Context
- Pipeline: standard
- Branch: ci/add-pipeline-dry-run-summary-with-stage-5
- Issue: #5
- Generated: 2026-02-10T02:21:06Z"
iteration: 23
max_iterations: 25
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-02-10T03:01:11Z
last_iteration_at: 2026-02-10T03:01:11Z
consecutive_failures: 0
total_commits: 23
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 1
max_extensions: 3
---

## Log
### Iteration 1 (2026-02-10T02:30:07Z)
- **Full pipeline test suite passes**: 17/17
- **Full `npm test` passes**: All 11 suites pass
- **No stale `claude-teams` in scripts** (except migration helper): Verified

### Iteration 2 (2026-02-10T02:38:19Z)
- All 3 dry-run tests pass (with history, no history, existing behavior)
- No stale `claude-teams` paths in scripts (only in `postinstall.mjs` migration helper)
- No stale `cct-cost` references anywhere in scripts

### Iteration 3 (2026-02-10T02:39:24Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 4 (2026-02-10T02:40:30Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 5 (2026-02-10T02:41:35Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 6 (2026-02-10T02:42:41Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 7 (2026-02-10T02:43:46Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 8 (2026-02-10T02:44:51Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 9 (2026-02-10T02:45:56Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 10 (2026-02-10T02:47:01Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 11 (2026-02-10T02:48:06Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 12 (2026-02-10T02:49:10Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 13 (2026-02-10T02:50:15Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 14 (2026-02-10T02:51:21Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 15 (2026-02-10T02:52:27Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 16 (2026-02-10T02:53:33Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 17 (2026-02-10T02:54:38Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 18 (2026-02-10T02:55:43Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 19 (2026-02-10T02:56:49Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 20 (2026-02-10T02:57:55Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 21 (2026-02-10T02:59:00Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 22 (2026-02-10T03:00:06Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

### Iteration 23 (2026-02-10T03:01:11Z)
API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API us

