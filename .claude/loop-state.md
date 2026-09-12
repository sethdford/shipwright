---
goal: "Add a pipeline-stage timeout escalation policy driven by historical stage duration, not fixed constants

## Plan Summary
Plan written to `.claude/pipeline-artifacts/plan.md` (466 lines).

## The key finding that reshaped this plan

**`scripts/lib/adaptive-timeout.sh` already implements the entire p95 engine — and it is dead code.** `scripts/sw-pipeline.sh:46` sources it, but `timeout_get`/`timeout_record` have *no callers outside the test file*. Its 26 tests pass (I ran them: 26/0) against a library nothing uses. Meanwhile `run_stage_with_retry` (`scripts/lib/pipeline-execution.sh:40`) calls `"stage_${stage_id}"` bare — **the pipeline enforces no stage timeout at all**, and retries reuse the identical budget, so a timeout retry times out identically.

So the goal is ~90% wiring, 10% new policy. The genuinely new part is the escalation ladder.

I also found three defects worth fixing in the same change:

- **`TIMEOUT_HISTORY_LOOKBACK` is a no-op.** `timeout_calculate_p95` (line 209) greps the *whole* history; only the never-executed awk fallback applies the window. Ancient durations skew p95 forever. Subtlety: since `timeout_record` prepends newest-first, the fix is `head`, not `tail`.
- **`timeout_record` is O(n) per call** — rewrites up to 10 000 entries on every stage completion.
- **An orphaned consumer.** `get_adaptive_heartbeat_timeout` (`daemon-adaptive.sh:114`) reads `stage-durations.**json**` (aggregate p90) — **nothing writes that file**, so the daemon's per-stage heartbeat silently falls back to constants. Writing the aggregate fixes that for free.

## Design decision worth flagging

I rejected the obvious approach of wrapping stages in `timeout(1)`: stage functions mutate parent-shell state the pipeline depends on (`set_stage_status`, `LAST_STAGE_ERROR_CLASS`, `completed`), so a subshell would corrupt the state file mid-run. Instead the budget is *injected* — `sw-loop.sh:461` already honours `CLAUDE_TIMEOUT` as an env override, and `loop-iteration.sh:635` wraps the real `claude` call in it, so setting it from the adaptive budget bounds the actual cost centre without touching stage control flow. A pure-bash watchdog adds the hard backstop (also covering the case where `_timeout` silently degrades to a no-op on hosts lacking `timeout`/`gtimeout`).

The most critical failure mode is a **self-reinforcing ratchet**: budget → timeout → recorded as a duration → higher p95 → higher budget, pinning everything at the 7200s ceiling. It's silent — it looks like normal cost drift, not a bug. Addressed structurally by tagging rows with `result` and excluding timeout-killed samples from p95, sequenced as a prerequisite so recording can't land before the guard.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# ADR: Pipeline-Stage Timeout Escalation Policy Driven by Historical Duration
## Context
## Decision
### Data Flow
### Component Decomposition
## Interface Contracts
### Timeout History & Analytics
### Escalation Engine
### Budget Enforcement
### Pipeline Integration
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Add a pipeline-stage timeout escalation policy driven by historical stage duration, not fixed constants

### Goals
- Add a pipeline-stage timeout escalation policy driven by historical stage duration, not fixed constants

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "success-patterns.json (first entry)",
      "relevance": 85,
      "summary": "Contains a prior successful 'Fix timeout' pattern with approach 'Add handler v2' applied to scripts/sw-daemon.sh; directly relevant to implementing timeout escalation logic in the daemon"
    },
    {
      "file": "issues.json",
      "relevance": 80,
      "summary": "Tracks successful timeout bug fix in sw-daemon.sh and daemon-dispatch.sh using 'added semaphore' approach; provides proven implementation pattern for timeout handling"
    },
    {
      "file": "metrics.json",
      "relevance": 75,
      "summary": "Contains historical baseline durations (build_duration_s: 7095, test_duration_s: 1459) essential for driving the escalation policy with actual stage performance data"
    },
    {
      "file": "failures.json (second entry)",
      "relevance": 60,
      "summary": "Contains timeout-related test failures including sw-e2e-integration-test hang at 301s timeout; provides edge cases and failure modes for timeout escalation validation"
    },
    {
      "file": "retry-outcomes.json",
      "relevance": 55,
      "summary": "Shows successful model escalation retry strategy with 100% success rate; demonstrates escalation pattern approach applicable to timeout escalation policy design"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Add a pipeline-stage timeout escalation policy driven by historical stage duration, not fixed constants — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Add a pipeline-stage timeout escalation policy driven by historical stage duration, not fixed constants

## Implementation Checklist
- [ ] Task 1: Fix lookback no-op in `timeout_calculate_p95` (use `head`, newest-first ordering)
- [ ] Task 2: Route `TIMEOUT_*` knobs through `_smart_int` with guarded fallback
- [ ] Task 3: Implement `timeout_for_attempt` escalation ladder (integer-percent math)
- [ ] Task 4: Add `result` field to JSONL; exclude timeout-killed rows from p95
- [ ] Task 5: Implement watchdog start/stop + `timeout_classify_overrun`
- [ ] Task 6: Implement `timeout_record_aggregate` → `stage-durations.json` (atomic, `jq --arg`)
- [ ] Task 7: Call `timeout_record` on success *and* failure paths in `run_pipeline`
- [ ] Task 8: Wire budget export, watchdog, and `timeout` escalation case into `run_stage_with_retry`
- [ ] Task 9: Repoint `daemon-adaptive.sh` at the aggregate file with `.jsonl` fallback
- [ ] Task 10: Add `pipeline.timeout_escalation` to `config/policy.json`
- [ ] Task 11: Register `shipwright timeout report|reset` CLI subcommand
- [ ] Task 12: Add ~14 tests to `sw-adaptive-timeout-test.sh`
- [ ] Task 13: Sync `VERSION` vars; add suite to `test:legacy-chain`
- [ ] Task 14: Update `.claude/CLAUDE.md`; `docs sync` + `version check`
- [ ] Task 15: Full `npm test` green vs. baseline
- [ ] `timeout_get`/`timeout_record` have production callers — `grep -rn` shows hits in
- [ ] Two consecutive pipeline runs leave one `stage-durations.jsonl` row per executed
- [ ] A stage retried after a timeout receives a **strictly larger** budget than its
- [ ] Escalation is capped: no budget exceeds `TIMEOUT_MAX`, and no stage escalates more
- [ ] Escalation is class-aware: `logic` and `configuration` failures do **not** escalate

## Context
- Pipeline: autonomous
- Branch: ci/issue-4854
- Issue: none
- Generated: 2026-09-12T18:14:04Z"
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-09-12T18:53:16Z
last_iteration_at: 2026-09-12T18:53:16Z
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
### Iteration 1 (2026-09-12T18:53:16Z)
**Testing-strategy sections (required by the active skill):**
1. **Test Pyramid Breakdown** — skipped as not applicable: this change adds no code paths, so no new unit/integration/
2. **Coverage Targets** — skipped: no executable lines or branches added. Existing coverage is unaffected.

