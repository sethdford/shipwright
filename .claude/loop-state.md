---
goal: "Auto-file hygiene issue when a script exceeds 2000 lines

## Plan Summary
Plan written to `.claude/pipeline-artifacts/plan.md` (344 lines).

## Key finding that shaped the plan

The feature is mostly **already built and unwired**. Two halves exist that were never connected:

- `scripts/sw-hygiene.sh:420` already has `check_script_sizes()` + a `script-size` subcommand that detects oversized scripts — but it only *reports*.
- `scripts/lib/daemon-patrol.sh:840` (`patrol_untested_scripts`) is a near-exact structural template for auto-filing: scan → `emit_event` → dedup via `gh issue list --search` → `gh issue create`, gated on `NO_GITHUB`/`dry_run`/`PATROL_MAX_ISSUES`.

So the work is connecting a detector with no filer to a filer with no detector, not building either.

## Chosen approach

Extract the scan into a new `scripts/lib/hygiene-size.sh` sourced by both. Rejected the two alternatives: duplicating the scan inside the patrol guarantees drift (the existing function encodes non-obvious choices — `-maxdepth 1`, strict `>`, `[]` fallback), and shelling out to `sw-hygiene.sh` violates the stated rule that stages source from `scripts/lib/` rather than calling scripts.

## Two decisions worth flagging

**The threshold is a new knob, not a change to the existing one.** `hygiene.max_script_lines` currently defaults to 1500. I kept it there and added `oversized_issue_threshold: 2000` separately — warning and opening a tracked issue are different severities. Merging them would either raise the advisory line silently or file issues for every 1500-line script.

**Three scripts are already over 2000** (`sw-loop.sh` 2713, `sw-memory.sh` 2241, `sw-db.sh` 1939-near). With patrol running hourly by default, dedup is load-bearing, not polish — which is why the most critical failure mode I address in the implementation is the `gh` dedup query failing. If that query errors and the result is swallowed into `existing=0`, the patrol concludes "nothing filed yet" and becomes an hourly issue generator. The plan writes that check to **fail closed**: file only on an affirmative `"0"`, treat empty/failed as "unknown, don't file," and log a warning so the silence is diagnosable.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Auto-file hygiene issue when a script exceeds 2000 lines
## Context
## Decision
### Component Diagram
### Interface Contracts
### Data Flow
### Error Boundaries
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Auto-file hygiene issue when a script exceeds 2000 lines

### Goals
- Auto-file hygiene issue when a script exceeds 2000 lines

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 95,
      "summary": "Project structure and conventions (node/vitest/npm/commonjs) directly inform build tooling, test patterns, and import/dependency management for this stage"
    },
    {
      "file": "metrics.json",
      "relevance": 78,
      "summary": "Baseline build duration (7095s) and test duration (1459s) provide reference points for performance expectations and iteration timeouts during build"
    },
    {
      "file": "failures.json (ENOENT/npm install)",
      "relevance": 72,
      "summary": "Common build failure pattern (missing dependencies) with high-effectiveness fix (npm install 95%) is directly applicable to build stage execution"
    },
    {
      "file": "success-patterns.json (auth module, iteration 5)",
      "relevance": 68,
      "summary": "Demonstrates successful feature build pattern using iterative TDD approach with 300s duration and npm test strategy, applicable to similar build scenarios"
    },
    {
      "file": "retry-outcomes.json",
      "relevance": 62,
      "summary": "Model escalation retry strategy achieved 100% success rate on build failures, providing escalation precedent for this stage if initial attempts fail"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Auto-file hygiene issue when a script exceeds 2000 lines — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Auto-file hygiene issue when a script exceeds 2000 lines

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/hygiene-size.sh` with `_emit_script_sizes`, `check_script_sizes`, `hygiene_oversized_scripts` + load guard
- [ ] Task 2: Source the lib from `sw-hygiene.sh`, delete moved bodies, update 3 call sites, bump VERSION to 3.5.0
- [ ] Task 3: Add `PATROL_OVERSIZED_ENABLED` / `PATROL_OVERSIZED_THRESHOLD` defaults and lib sourcing to `daemon-patrol.sh`
- [ ] Task 4: Implement `patrol_oversized_scripts()` with dedup, NO_GITHUB/dry-run guards, and decision-engine branch
- [ ] Task 5: Register the check in the `daemon_patrol()` dispatch block with findings-summary bookkeeping
- [ ] Task 6: Add `hygiene.oversized_issue_threshold: 2000` to `config/policy.json`
- [ ] Task 7: Load `patrol.checks.oversized_scripts.*` in `sw-daemon.sh` with integer validation
- [ ] Task 8: Regression-test `hygiene script-size` behavior is byte-identical after extraction
- [ ] Task 9: Unit tests — detects >threshold, ignores <=threshold, honors dry-run and NO_GITHUB, respects disabled flag
- [ ] Task 10: Dedup test — second patrol run with an open issue creates zero new issues
- [ ] Task 11: Decision-engine test — signal written to `pending.jsonl`, no issue created
- [ ] Task 12: Document the patrol check and config keys in `.claude/CLAUDE.md`
- [ ] Task 13: `bash -n` + shellcheck all changed scripts
- [ ] Task 14: Run `sw-hygiene-test.sh`, `sw-lib-daemon-patrol-test.sh`, then full `npm test`
- [ ] `scripts/lib/hygiene-size.sh` exists with a load guard and is sourced by both `sw-hygiene.sh` and `daemon-patrol.sh`
- [ ] `shipwright hygiene script-size` output is byte-identical to pre-change for the same input
- [ ] `patrol_oversized_scripts()` flags scripts with `lines > 2000` and ignores those at or below
- [ ] Exactly one aggregate GitHub issue is filed per detection cycle, labeled `<PATROL_LABEL>,hygiene`
- [ ] A second patrol run with the issue open files **zero** new issues
- [ ] `NO_GITHUB=true`, `--dry-run`, and `enabled: false` each suppress issue creation

## Context
- Pipeline: autonomous
- Branch: ci/issue-5791
- Issue: none
- Generated: 2026-09-19T17:38:10Z"
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-09-19T18:31:43Z
last_iteration_at: 2026-09-19T18:31:43Z
consecutive_failures: 0
total_commits: 1
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-09-19T18:31:43Z)
That's the stale watcher expiring — no action needed. I'd already read the `npm test` results directly from the backgr
Work is complete and committed:
- `ee77bbab` — the feature

