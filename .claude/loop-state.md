---
goal: "Share failure patterns fleet-wide so daemon triage in one repo benefits from another repo's learnings

## Plan Summary
# Plan: share failure patterns across the fleet so daemon triage in one repo benefits from another's learnings

## Where things stand

Most of this feature is already merged to `main` in e3e92720 and 5505b468. Its two suites pass: `sw-lib-fleet-patterns-test.sh` (80/80) and `sw-lib-daemon-dispatch-test.sh` (37/37).

| Layer | Where | Status |
|---|---|---|
| Error signatures that are the same in every repo | `scripts/lib/fleet-patterns.sh:87-154` | ✅ done |
| Shared store (locked, atomic writes, size caps, recovers from corruption, demotes fixes that rarely work) | `scripts/lib/fleet-patterns.sh:156-370` | ✅ done |
| Failures and fixes get published to the store | `scripts/sw-memory.sh:400-458, 524-528, 840-844` | ✅ done |
| Triage looks up a known fix at spawn time and writes `.claude/fleet-known-fix.json` | `scripts/lib/daemon-dispatch.sh:225-237` | ✅ done |
| The setting reaches pipelines started in tmux | `scripts/lib/daemon-dispatch.sh:293-294` | ✅ done |
| The known fix is shown in the plan, build and test prompts | `scripts/sw-memory.sh:1016-1083` | ✅ done |
| **The fleet launcher turns the feature on** | `scripts/sw-fleet.sh:853-854` | ❌ **missing** |
| Old patterns get pruned (`fleet_pattern_prune` exists) | — | ❌ nothing calls it |
| A command to view or prune the store | `scripts/sw-memory.sh:2244` router | ❌ missing |
| The `fleet.pattern_*` events are listed in `config/event-schema.json` | — | ❌ missing |
| A test that follows a pattern from one repo to another | — | ❌ missing |
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Share failure patterns fleet-wide so daemon triage in one repo benefits from another repo's learnings
## Context
## Decision
### Component diagram
### Interface contracts
### Data flow
### Error boundaries
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Share failure patterns fleet-wide so daemon triage in one repo benefits from another repo's learnings

### Goals
- Share failure patterns fleet-wide so daemon triage in one repo benefits from another repo's learnings

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "fleet-shared-patterns.json",
      "relevance": 95,
      "summary": "Already stores failure signatures and fixes contributed by multiple repos (repo-a, repo-b), with per-repo contribution counts. This is the closest existing implementation of sharing failure patterns fleet-wide."
    },
    {
      "file": "fleet-knowledge.json",
      "relevance": 85,
      "summary": "A cross-fleet knowledge store with publish, query, match, and injection metrics. It tracks how shared learnings get reused, which is the mechanism the goal needs for triage to benefit from other repos."
    },
    {
      "file": "fleet-patterns.json",
      "relevance": 80,
      "summary": "A fleet-level patterns file with the same name as the goal's concept, though currently empty. It is the likely landing spot for fleet-wide failure patterns."
    },
    {
      "file": "failures.json",
      "relevance": 60,
      "summary": "Holds real failure records with root_cause, fix, and resolved flags for the test stage. These are the per-repo failure patterns that would need to be shared and used by daemon triage."
    },
    {
      "file": "index.json",
      "relevance": 45,
      "summary": "Indexes failure patterns by signature, stage, and source with a suggested fix. It could serve as the lookup layer that triage queries across repos."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Share failure patterns fleet-wide so daemon triage in one repo benefits from another repo's learnings — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Share failure patterns fleet-wide so daemon triage in one repo benefits from another repo's learnings

## Implementation Checklist
- [ ] Task 1: Add `fleet_patterns_stats` to `scripts/lib/fleet-patterns.sh` (always exits 0, works on empty or corrupt stores)
- [ ] Task 2: Source `fleet-patterns.sh` in `sw-fleet.sh`; read `shared_patterns` and `shared_patterns_file`; build a `printf %q`-quoted env prefix
- [ ] Task 3: Add the env prefix to the `tmux new-session` daemon command at `sw-fleet.sh:854`
- [ ] Task 4: Prune at fleet start using `shared_patterns_retention_days` (default 90, validated)
- [ ] Task 5: Record `shared_patterns` and `patterns_file` in `fleet-state.json` via `jq --arg`; add the field to `fleet.started`
- [ ] Task 6: Show the shared-pattern summary line in `fleet status`
- [ ] Task 7: Add the `fleet` key to the `fleet init` config template and its help text
- [ ] Task 8: Add `shipwright memory fleet list|show|prune|stats` (with `--json` on `list`)
- [ ] Task 9: Register the 5 `fleet.pattern*` events in `config/event-schema.json`; run the schema sync check
- [ ] Task 10: Fleet tests for export, opt-out, quoting, state and prune
- [ ] Task 11: Library tests for `stats`, the `memory fleet` command, and cross-repo A→B end-to-end through prompt injection
- [ ] Task 12: Update `.claude/CLAUDE.md` (Fleet Mode, Memory commands, Runtime State) and any fleet docs page
- [ ] Task 13: Run `bash -n`, the three targeted suites, then `npm test`
- [ ] Every daemon started by `shipwright fleet start` has `SHIPWRIGHT_FLEET_PATTERNS_FILE` set, unless `shared_patterns: false`.
- [ ] A fix learned in repo A appears as "Known Fix From Fleet" in repo B's build-stage memory injection when B's issue or log has the same normalized error (different path, line or timestamp). This is proven by an automated test.
- [ ] `shared_patterns: false` turns sharing off for that fleet, and standalone `shipwright daemon start` behaves as before.
- [ ] The store is pruned at fleet start, with a configurable retention period.
- [ ] `shipwright memory fleet list|show|prune|stats` works with or without a running fleet.
- [ ] No "Unknown event type" warning for the `fleet.pattern*` events.
- [ ] Every changed script is Bash 3.2 compatible, survives `set -euo pipefail`, uses `jq --arg` for JSON, and writes files atomically.

## Context
- Pipeline: autonomous
- Branch: ci/issue-8328
- Issue: none
- Generated: 2026-10-11T04:12:53Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-10-11T04:15:26Z
last_iteration_at: 2026-10-11T04:15:26Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

