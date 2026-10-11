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
- Generated: 2026-10-11T04:12:53Z
