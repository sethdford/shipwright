---
goal: "Classify and surface flatlining build-loop iterations distinct from context exhaustion

## Plan Summary
# Plan: Tell flatlining build-loop iterations apart from context exhaustion

## Summary

**The problem.** Today "context exhaustion" is a catch-all for any build loop that ends without passing tests. There are three places where this happens:

| Location | Current logic | What goes wrong |
|---|---|---|
| `scripts/lib/daemon-failure.sh:51-64` (`classify_failure`) | `progress.md` shows iteration > 0 and tests `false` or `unknown`, so it returns `context_exhaustion` | Any non-passing loop is labelled context exhaustion |
| `scripts/lib/pipeline-stages-build.sh:461-474` | Loop exit is non-zero and tests aren't `true`, so it writes `context_exhaustion` to `failure-reason.txt` | Same mislabel, and the daemon reads it |
| `scripts/lib/session-restart.sh:205-213` (`restart_detect_reason`) | Iteration count is at the maximum, so it returns `context_exhaustion` | Running out of iterations is reported as running out of context. The `iteration_limit` branch below it can never run because it has the identical condition |

**Why it matters.** The daemon treats context exhaustion by raising `--max-restarts` (`daemon-failure.sh:285-292`). That helps when the context window really filled up. It does nothing for a **flatlining** loop, where iterations keep running but produce no code changes and the same error every time. More fresh sessions just repeat the same failure.

**What already exists.**
- `sw-loop.sh:2298` detects real context exhaustion by matching `CONTEXT_EXHAUSTION_PATTERNS` in the iteration log.
- `loop-convergence.sh` records `diff_hash|error_hash|exit_code` per iteration in `stuckness-tracking.txt`.
- `check_progress` uses `MIN_PROGRESS_LINES`.
- `STUCKNESS_COUNT >= 3` sets `STATUS=stuck_restart`.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Classify and surface flatlining build-loop iterations distinct from context exhaustion
## Context
## Decision
### Component diagram
### Interface contracts
### Classification rules
### Data flow
### Error boundaries
### Design decisions worth recording
## Alternatives Considered
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Classify and surface flatlining build-loop iterations distinct from context exhaustion

### Goals
- Classify and surface flatlining build-loop iterations distinct from context exhaustion

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Contains actual failure records with root causes, seen_count, and resolved status. Flatlining would show repeated failures with resolved=false; helps distinguish from context exhaustion."
    },
    {
      "file": "success-patterns.json (test-repo-comptime)",
      "relevance": 80,
      "summary": "Includes iterations_needed, completion_time_seconds, and stages_executed for build stage. Provides baseline metrics to detect when iteration count exceeds normal completion patterns, indicating flatlining."
    },
    {
      "file": "index.json",
      "relevance": 75,
      "summary": "Contains indexed failure patterns with total_seen frequency counts in build stage. High recurrence of same pattern (seen=5) indicates flatlining vs context exhaustion (new errors)."
    },
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 70,
      "summary": "Tracks cross-repo failure patterns with seen_count, timestamps, and fix status. Helps identify whether failures are systematic flatlining or environmental context issues."
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 65,
      "summary": "Multiple patterns with iterations_needed=1 and consistent completion times. Provides comparison baseline to detect when builds exceed expected iteration count, signaling flatlining."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Classify and surface flatlining build-loop iterations distinct from context exhaustion — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Classify and surface flatlining build-loop iterations distinct from context exhaustion

## Implementation Checklist
- [ ] 1. Create `lib/loop-flatline.sh` with the classifier, exit-class resolver and atomic artifact writer
- [ ] 2. Source and call it from `sw-loop.sh` per iteration; emit `loop.iteration_classified` and `loop.flatline` *(depends on 1)*
- [ ] 3. Add `Exit class` and `Flatline streak` to `progress.md` and `show_summary` *(depends on 1)*
- [ ] 4. Tag `stuck_restart` and flatline restarts with a reason and inject the flatline strategy *(depends on 2, 6)*
- [ ] 5. Fix the unreachable `iteration_limit` branch and add flatline in `restart_detect_reason`
- [ ] 6. Add the `flatline` strategy in `restart_suggest_strategy`
- [ ] 7. Pipeline build stage: write `flatline` vs `context_exhaustion` to `failure-reason.txt` *(depends on 3)*
- [ ] 8. Daemon `classify_failure`, retry limits and escalation for `flatline` without the restart boost *(depends on 3, 7)*
- [ ] 9. Add the `flatline` category in `root-cause.sh`
- [ ] 10. Event schema entries plus sync
- [ ] 11. New `sw-loop-flatline-test.sh`, registered in `package.json`
- [ ] 12. Extend the daemon-failure, session-restart and loop tests
- [ ] 13. Update the CLAUDE.md docs

## Context
- Pipeline: autonomous
- Branch: ci/issue-7689
- Issue: none
- Generated: 2026-10-04T14:54:07Z

## Failure Diagnosis (Iteration 2)
Classification: syntax_error
Strategy: fix_syntax
Repeat count: 0
INSTRUCTION: This is a syntax error. Carefully check the exact line mentioned in the error. Look for missing brackets, semicolons, commas, or mismatched quotes."
iteration: 2
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-10-04T16:09:36Z
last_iteration_at: 2026-10-04T16:09:36Z
consecutive_failures: 0
total_commits: 2
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-10-04T15:35:11Z)
  - "Same failure" is judged from the error lines in `error-summary.json`, with numbers stripped so different timings do
  - It also decides one exit class per loop (`complete`, `context_exhaustion`, `flatline`, `iteration_exhaustion`, or th
- **`scripts/sw-loop-flatline-test.sh`** (new, 39 checks against a temporary git repo) covers flatline detection, streak

### Iteration 2 (2026-10-04T16:09:36Z)
- **`restart_suggest_strategy`** has a new critical-priority `flatline` strategy telling the fresh session to stop repea
- **Tests** in `scripts/sw-session-restart-test.sh`: the old context-exhaustion test checked for the bug (reaching 10 of
**Test results:** the full `npm test` run passed all 163 suites. The `sw-cost-test.sh:226` error from last iteration did

