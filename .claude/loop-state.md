---
goal: "Add pipeline dry-run summary with stage timing estimates

Implementation plan (follow this exactly):
Error: Reached max turns (25)

Follow the approved design document:
Now I have a thorough understanding of the implementation. Let me produce the ADR.

# Design: Add pipeline dry-run summary with stage timing estimates

## Context

Shipwright's delivery pipeline (`scripts/cct-pipeline.sh`, ~3800 lines) executes up to 12 stages sequentially, each potentially invoking Claude Code agents. Before committing to a full run — which can take 30+ minutes and cost $10+ in API usage — operators need visibility into expected duration and cost.

**Constraints from the codebase:**
- All scripts are Bash 3.2-compatible (no associative arrays, no `readarray`, no `${var,,}`)
- `set -euo pipefail` is enforced; `grep` in pipelines must be guarded with `|| true`
- Event data lives in `~/.claude-teams/events.jsonl` (JSONL format, one JSON object per line)
- Cost data uses `cost.record` events with `stage` and `cost_usd` fields; timing uses `stage.completed` events with `stage` and `duration_s` fields
- Pipeline templates (`templates/pipelines/*.json`) define enabled stages, gate modes, and per-stage config including model overrides
- The `DRY_RUN` flag (line 103) gates execution at the main entry point (line 4085-4088), calling `dry_run_summary()` and returning before any stages execute

## Decision

Implement dry-run summary as a self-contained function (`dry_run_summary()`, lines 972-1094 of `scripts/cct-pipeline.sh`) that:

1. **Reads enabled stages** from the active pipeline template via `jq '.stages[] | select(.enabled == true)'` — no hardcoded stage list, adapts to any template.

2. **Computes median duration** per stage from historical `stage.completed` events in `events.jsonl`. Median (not mean) is chosen because pipeline durations are right-skewed — a single outlier build shouldn't distort estimates. Duration values are extracted with `jq -r '.duration_s'`, sorted numerically, and the middle value selected.

3. **Computes median cost** per stage from `cost.record` events, using the same median approach. Cost is summed across stages for a total estimate. Arithmetic uses `awk "BEGIN {printf ...}"` for floating-point addition (Bash integer arithmetic is insufficient for dollar amounts).

4. **Resolves model per stage** using the hierarchy: CLI `--model` flag > stage-level `config.model` > template `defaults.model` > `"opus"` fallback. This matches the runtime resolution order.

5. **Renders a Unicode box-drawing table** with fixed column widths (Stage=18, Duration=15, Model=9, Cost=12) and a Total row. Gracefully degrades to "no data" / "—" when no historical events exist.

6. **Shows budget remaining** by calling `cct-cost.sh remaining-budget`, displayed only when a budget is configured.

7. **Ensures zero side effects**: no artifacts created, no branches created, no events emitted, no heartbeat started. The function returns before `run_pipeline()` is reached.

**Data flow:**
```
CLI --dry-run → DRY_RUN=true → main entry (line 4085) → dry_run_summary()
                                                          ├─ read PIPELINE_CONFIG (jq)
                                                          ├─ for each stage:
                                                          │   ├─ resolve model (jq)
                                                          │   ├─ grep events.jsonl for stage.completed → median duration
                                                          │   └─ grep events.jsonl for cost.record → median cost
                                                          ├─ sum totals
                                                          ├─ render table (printf)
                                                          └─ show budget (cct-cost.sh)
```

**Error handling:**
- All `jq` and `grep` calls are guarded with `2>/dev/null` and `|| true` to satisfy `pipefail`
- Missing `events.jsonl` shows graceful fallback ("no data", "—")
- Non-numeric duration values are rejected by `[[ "$median_dur" =~ ^[0-9]+$ ]]`
- Empty pipeline configs produce an empty table (no crash)

## Alternatives Considered

1. **Mean instead of median for estimates** — Pros: simpler calculation, single `awk` pass / Cons: highly sensitive to outlier runs (a stuck build at 45m skews a typical 8m average to 20m+). Median is more representative of "typical" experience.

2. **Percentile-based estimates (p50/p90)** — Pros: shows range of outcomes, more informative / Cons: significantly more complex in Bash (requires array indexing or multi-pass), harder to fit in a clean table layout, and overkill when most users have <10 historical runs. Could be added later as `--dry-run --verbose`.

3. **Static timing defaults when no history exists** — Pros: always shows a number / Cons: misleading — a static "~5m" for the build stage could be wildly off depending on project size. "no data" is more honest and encourages running the pipeline once to seed real data.

4. **Separate `--estimate` command** — Pros: clean separation of concerns / Cons: introduces a new subcommand for a feature tightly coupled to pipeline config parsing. Keeping it as `--dry-run` on the existing `pipeline start` command means it automatically picks up the same template, model overrides, and goal context.

## Implementation Plan

- **Files to create:** None
- **Files to modify:**
  - `scripts/cct-pipeline.sh` — `dry_run_summary()` function (lines 972-1094), `DRY_RUN` flag init (line 103), CLI parsing (line 248), main entry gate (lines 4085-4088)
  - `scripts/cct-pipeline-test.sh` — Three test cases: `test_dry_run()` (lines 760-778), `test_dry_run_summary_with_history()` (lines 813-866), `test_dry_run_summary_no_history()` (lines 871-886)
- **Dependencies:** None new. Uses existing `jq`, `awk`, `grep`, `sort`, `sed` — all already required by the pipeline.
- **Risk areas:**
  - **`grep` under `pipefail`:** The `grep '"stage.completed"' ... | grep "\"stage\":\"${sid}\""` chains could fail if `events.jsonl` is empty or malformed. Mitigated by `|| true` on each chain and `2>/dev/null` redirects.
  - **Large `events.jsonl`:** Over time, this file grows unbounded. Sequential `grep` per stage per column (2 greps × N stages) scales linearly. For a 12-stage pipeline with a 10MB events file, this is negligible (<1s). If it becomes a problem, a future optimization could pre-filter with a single `jq` pass.
  - **Floating-point cost arithmetic:** `awk "BEGIN {printf ...}"` with string-interpolated variables could break on malformed cost values. The `cost.record` events are emitted by `cct-cost.sh` which always formats as `%.2f`, so this is safe in practice.
  - **Column truncation:** Stage names longer than 16 characters (e.g., `compound_quality` at 16 chars) fit within the 18-char column. Future stages with longer names would need width adjustment.

## Validation Criteria

- [ ] `test_dry_run` passes: `--dry-run` exits 0, outputs "Dry run", shows pipeline name, creates no artifacts or branches
- [ ] `test_dry_run_summary_with_history` passes: seeded events produce correct median durations (`~2m 0s`, `~5m 0s`) and costs (`$0.12`, `$1.45`, `$4.80`), total cost is `~$6.37`
- [ ] `test_dry_run_summary_no_history` passes: missing events.jsonl produces "no data" for duration and "—" for cost
- [ ] Model resolution shows correct model per stage (stage config > template default > fallback)
- [ ] Budget remaining is displayed when configured, omitted when not
- [ ] No pipeline stages execute during dry-run (no `stage.started` events emitted, no artifacts created)
- [ ] Table renders correctly with box-drawing characters for all 8 pipeline templates (varying stage counts)
- [ ] Full test suite passes: `npm test` exits 0 with no regressions

Historical context (lessons from previous pipelines):
# Shipwright Memory Context
# Injected at: 2026-02-09T21:56:44Z
# Stage: build

## Failure Patterns to Avoid

## Known Fixes

## Code Conventions

Task tracking (check off items as you complete them):
# Pipeline Tasks — Add pipeline dry-run summary with stage timing estimates

## Implementation Checklist

- [x] Task 1: Add `dry_run_summary()` function to `cct-pipeline.sh`
- [x] Task 2: Replace existing dry-run block with `dry_run_summary` call
- [x] Task 3: Implement per-stage model resolution (CLI > stage config > defaults > opus)
- [x] Task 4: Implement median duration from `events.jsonl` `stage.completed` events
- [x] Task 5: Implement median cost from `events.jsonl` — adapted: no per-stage cost events exist, uses pipeline.cost for total
- [x] Task 6: Add budget remaining display via `cct-cost.sh remaining-budget`
- [x] Task 7: Add formatted table output with Unicode separators
- [x] Task 8: Handle graceful fallback ("no data" / "—") when no history
- [x] Task 9: Add `test_dry_run_summary_with_history` test
- [x] Task 10: Add `test_dry_run_summary_no_history` test
- [x] Task 11: Register both new tests in runner array
- [x] Task 12: Add events.jsonl backup/restore in test setup/teardown
- [x] Task 13: Run full test suite and fix failures — all 167 tests pass
- [x] `--dry-run` shows table with Stage, Est. Duration, Model, Est. Cost
- [x] Duration uses median from historical `stage.completed` events
- [x] Cost: pipeline-level median from `pipeline.cost` events (no per-stage cost events exist)
- [x] Model resolves per-stage from template config
- [x] "no data" / "—" shown when no history exists
- [x] Total row with summed duration and cost
- [x] Budget line when budget enabled

## Context

- Pipeline: standard
- Branch: ci/add-pipeline-dry-run-summary-with-stage-5
- Issue: #5
- Generated: 2026-02-09T21:05:58Z"
iteration: 2
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-02-09T22:31:31Z
last_iteration_at: 2026-02-09T22:31:31Z
consecutive_failures: 0
total_commits: 2
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-02-09T22:12:27Z)
- Zero side effects during dry-run (no artifacts, no branches, no events)
- Two comprehensive tests with properly escaped assertions
- All 184 tests pass

### Iteration 2 (2026-02-09T22:31:31Z)
Quality gates status:
- Gate 1 (tests pass): ✓ All 184 tests pass
- Gate 2 (no uncommitted changes): ✓ All changes committed

