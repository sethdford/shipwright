# Shipwright

Shipwright orchestrates autonomous Claude Code agent teams with delivery pipelines, daemon-driven issue processing, fleet operations across multiple repos, persistent memory, DORA metrics, cost intelligence, and repo preparation. All CLI aliases — `shipwright`, `sw`, `cct` — work identically.

## Commands

| Command                                            | Purpose                                           |
| -------------------------------------------------- | ------------------------------------------------- |
| `shipwright init`                                  | One-command tmux setup (no prompts)               |
| `shipwright setup`                                 | Guided setup — prerequisites, init, doctor        |
| `shipwright session <name> -t <template>`          | Create team session with agent panes              |
| `shipwright loop "<goal>" --test-cmd "..."`        | Continuous autonomous agent loop                  |
| `shipwright pipeline start --issue <N>`            | Full delivery pipeline for an issue               |
| `shipwright pipeline start --issue <N> --worktree` | Pipeline in isolated git worktree (parallel-safe) |
| `shipwright pipeline start --goal "..."`           | Pipeline from a goal description                  |
| `shipwright pipeline resume`                       | Resume from last stage                            |
| `shipwright daemon start`                          | Watch repo for labeled issues, auto-process       |
| `shipwright daemon start --detach`                 | Start daemon in background tmux session           |
| `shipwright daemon metrics`                        | DORA/DX metrics dashboard                         |
| `shipwright fleet start`                           | Multi-repo daemon orchestration                   |
| `shipwright fix "<goal>" --repos <paths>`          | Apply same fix across repos in parallel           |
| `shipwright memory show`                           | View captured failure patterns and learnings      |
| `shipwright cost show`                             | Token usage and spending dashboard                |
| `shipwright cost budget set <amount>`              | Set daily budget limit                            |
| `shipwright prep`                                  | Analyze repo and generate .claude/ configs        |
| `shipwright doctor`                                | Validate setup and diagnose issues                |
| `shipwright status`                                | Show team dashboard                               |
| `shipwright ps`                                    | Show running agent processes                      |
| `shipwright logs <team> --follow`                  | Tail agent logs                                   |
| `shipwright upgrade --apply`                       | Pull latest and apply updates                     |
| `shipwright cleanup --force`                       | Kill orphaned sessions                            |
| `shipwright reaper --watch`                        | Automatic pane cleanup when agents exit           |
| `shipwright worktree create <branch>`              | Git worktree for agent isolation                  |
| `shipwright templates list`                        | Browse team templates                             |
| `shipwright dashboard`                             | Real-time web dashboard (requires Bun)            |
| `shipwright dashboard start`                       | Start dashboard in background                     |
| `shipwright jira <cmd>`                            | Bidirectional issue sync with Jira                |
| `shipwright linear <cmd>`                          | Bidirectional issue sync with Linear              |
| `shipwright tracker <cmd>`                         | Configure Linear/Jira integration                 |
| `shipwright heartbeat list`                        | Show agent heartbeat status                       |
| `shipwright checkpoint list`                       | Show saved pipeline checkpoints                   |
| `shipwright remote list`                           | Show registered remote machines                   |
| `shipwright remote add <name> --host <h>`          | Register a remote worker machine                  |
| `shipwright remote status`                         | Health check all remote machines                  |
| `shipwright intelligence`                          | Run intelligence engine analysis                  |
| `shipwright optimize`                              | Self-optimization based on DORA metrics           |
| `shipwright predict`                               | Predictive risk assessment and anomaly detection  |

## Pipeline Stages

12 stages, each can be enabled/disabled and gated (auto-proceed or pause for approval):

```
intake → plan → design → build → test → review → compound_quality → pr → merge → deploy → validate → monitor
```

The build stage delegates to `shipwright loop` for autonomous multi-iteration development. Self-healing: when tests fail, the pipeline re-enters the build loop with error context.

## Pipeline Templates

| Template     | Stages                                     | Gates                             | Use Case                 |
| ------------ | ------------------------------------------ | --------------------------------- | ------------------------ |
| `fast`       | intake → build → test → PR                 | all auto                          | Quick fixes              |
| `standard`   | intake → plan → build → test → review → PR | approve: plan, review, pr         | Normal feature work      |
| `full`       | all stages                                 | approve: plan, review, pr, deploy | Production deployment    |
| `hotfix`     | intake → build → test → PR                 | all auto                          | Urgent production fixes  |
| `autonomous` | all stages                                 | all auto                          | Daemon-driven delivery   |
| `enterprise` | all stages                                 | all approve, auto-rollback        | Maximum safety           |
| `cost-aware` | all stages                                 | all auto, budget checks           | Budget-limited delivery  |
| `deployed`   | all + deploy + validate + monitor          | approve: deploy                   | Full deploy + monitoring |

## Team Patterns

- Assign each agent **different files** to avoid merge conflicts
- Use `--worktree` for file isolation between agents running concurrently
- Keep tasks self-contained — 5-6 focused tasks per agent
- Use the task list for coordination, not direct messaging
- 12 team templates cover the full SDLC: `shipwright templates list`

## tmux Conventions

- Team windows: named `claude-<team-name>` (shows lambda icon in status bar)
- Pane titles: `<team>-<role>` (visible in pane borders)
- Set pane title: `printf '\033]2;agent-name\033\\'`
- Prefix key: **Ctrl-a**
- Layouts: `prefix + M-1` (horizontal, leader 65% left), `M-2` (vertical, leader 60% top), `M-3` (tiled)
- Zoom: `prefix + G` (toggle focus on one pane)
- Capture output: `prefix + M-s` (current pane), `prefix + M-a` (all panes)
- Team status: `prefix + Ctrl-t`

## Architecture

All scripts are bash (except the dashboard server in TypeScript). Grouped by layer:

### Core Scripts

| File                                  | Lines | Purpose                                         |
| ------------------------------------- | ----: | ----------------------------------------------- |
| `scripts/sw`                          |   286 | CLI router — dispatches subcommands via `exec`  |
| `scripts/sw-pipeline.sh`              |  4383 | Delivery pipeline + compound quality stage      |
| `scripts/sw-daemon.sh`                |  3959 | Autonomous issue watcher + metrics + auto-scale |
| `scripts/sw-loop.sh`                  |  1445 | Continuous autonomous agent loop                |
| `scripts/sw-prep.sh`                  |  1368 | Repo preparation and config generation          |
| `scripts/sw-memory.sh`                |  1259 | Persistent learning and context system          |
| `scripts/sw-fleet.sh`                 |  1255 | Multi-repo daemon orchestration                 |
| `scripts/sw-self-optimize.sh`         |   790 | Self-optimization engine (DORA-driven tuning)   |
| `scripts/sw-doctor.sh`                |   721 | Setup validation and diagnostics                |
| `scripts/sw-intelligence.sh`          |   688 | Intelligence engine (codebase analysis + cache) |
| `scripts/sw-remote.sh`                |   686 | Multi-machine registry + remote management      |
| `scripts/sw-cost.sh`                  |   593 | Token usage and cost intelligence               |
| `scripts/sw-status.sh`                |   527 | Team dashboard display                          |
| `scripts/sw-session.sh`               |   517 | Team session creation from templates            |
| `scripts/sw-init.sh`                  |   500 | One-command tmux setup                          |
| `scripts/sw-fix.sh`                   |   481 | Bulk fix across repos                           |
| `scripts/sw-dashboard.sh`             |   474 | Dashboard server launcher                       |
| `scripts/sw-predictive.sh`            |   456 | Predictive risk assessment + anomaly detection  |
| `scripts/sw-upgrade.sh`               |   436 | Upgrade checker and applier                     |
| `scripts/sw-pipeline-composer.sh`     |   417 | Dynamic pipeline composition from intelligence  |
| `scripts/sw-tracker.sh`               |   408 | Issue tracker router (Linear/Jira)              |
| `scripts/sw-worktree.sh`              |   405 | Git worktree management for agent isolation     |
| `scripts/sw-reaper.sh`                |   390 | Automatic pane cleanup when agents exit         |
| `scripts/sw-checkpoint.sh`            |   384 | Pipeline checkpoint save/restore                |
| `scripts/sw-architecture-enforcer.sh` |   327 | Architecture rule enforcement                   |
| `scripts/sw-heartbeat.sh`             |   292 | Agent heartbeat writer/checker                  |
| `scripts/sw-logs.sh`                  |   273 | Agent log viewer and search                     |
| `scripts/sw-developer-simulation.sh`  |   249 | Developer workflow simulation testing           |
| `scripts/sw-templates.sh`             |   245 | Team template browser                           |
| `scripts/sw-setup.sh`                 |   233 | Guided setup wizard                             |
| `scripts/sw-adversarial.sh`           |   210 | Adversarial code review                         |
| `scripts/sw-cleanup.sh`               |   172 | Orphaned session cleanup                        |
| `scripts/sw-ps.sh`                    |   168 | Running agent process display                   |

### Issue Tracker Adapters

| File                           | Lines | Purpose                           |
| ------------------------------ | ----: | --------------------------------- |
| `scripts/sw-linear.sh`         |   647 | Linear issue sync                 |
| `scripts/sw-jira.sh`           |   642 | Jira issue sync                   |
| `scripts/sw-tracker-linear.sh` |   193 | Linear tracker provider (sourced) |
| `scripts/sw-tracker-jira.sh`   |   187 | Jira tracker provider (sourced)   |

### Shared Libraries

| File                    | Lines | Purpose                            |
| ----------------------- | ----: | ---------------------------------- |
| `scripts/lib/compat.sh` |     — | Cross-platform compatibility shims |

### Test Suites

| File                                   | Lines | Purpose                             |
| -------------------------------------- | ----: | ----------------------------------- |
| `scripts/sw-pipeline-test.sh`          |   874 | Pipeline flow tests (mock binaries) |
| `scripts/sw-daemon-test.sh`            |   911 | Daemon tests                        |
| `scripts/sw-fleet-test.sh`             |   833 | Fleet orchestration tests           |
| `scripts/sw-memory-test.sh`            |   709 | Memory system tests                 |
| `scripts/sw-predictive-test.sh`        |   689 | Predictive intelligence tests       |
| `scripts/sw-prep-test.sh`              |   644 | Repo preparation tests              |
| `scripts/sw-pipeline-composer-test.sh` |   643 | Pipeline composer tests             |
| `scripts/sw-fix-test.sh`               |   630 | Bulk fix tests                      |
| `scripts/sw-self-optimize-test.sh`     |   611 | Self-optimization tests             |
| `scripts/sw-session-test.sh`           |   591 | Session creation tests              |
| `scripts/sw-heartbeat-test.sh`         |   588 | Heartbeat tests                     |
| `scripts/sw-frontier-test.sh`          |   581 | Frontier capability tests           |
| `scripts/sw-intelligence-test.sh`      |   544 | Intelligence engine tests           |
| `scripts/sw-init-test.sh`              |   494 | Init tests                          |
| `scripts/sw-tracker-test.sh`           |   476 | Tracker tests                       |
| `scripts/sw-remote-test.sh`            |   404 | Remote management tests             |

### Dashboard & Infra

| File                   | Lines | Purpose                            |
| ---------------------- | ----: | ---------------------------------- |
| `dashboard/server.ts`  |  3501 | Bun WebSocket dashboard server     |
| `dashboard/public/`    |     — | Dashboard frontend (HTML/CSS/JS)   |
| `install.sh`           |   755 | Interactive installer              |
| `templates/pipelines/` |     — | 8 pipeline template JSON files     |
| `tmux/templates/`      |     — | 24 team composition JSON templates |

### Runtime State and Artifacts

- Pipeline state: `.claude/pipeline-state.md`
- Pipeline artifacts: `.claude/pipeline-artifacts/`
- Composed pipeline: `.claude/pipeline-artifacts/composed-pipeline.json`
- Events log: `~/.shipwright/events.jsonl` (JSONL for metrics)
- Daemon config: `.claude/daemon-config.json`
- Fleet config: `.claude/fleet-config.json`
- Heartbeats: `~/.shipwright/heartbeats/<job-id>.json`
- Checkpoints: `.claude/pipeline-artifacts/checkpoints/`
- Machine registry: `~/.shipwright/machines.json`
- Cost data: `~/.shipwright/costs.json`, `~/.shipwright/budget.json`
- Intelligence cache: `.claude/intelligence-cache.json`
- Optimization data: `~/.shipwright/optimization/`
- Baselines: `~/.shipwright/baselines/`
- Architecture models: `~/.shipwright/memory/<repo-hash>/architecture.json`

## Intelligence Layer

All intelligence features are behind feature flags and disabled by default. Configure in `.claude/daemon-config.json` under the `intelligence` key.

### Feature Flags

| Flag                                | Default | Purpose                                        |
| ----------------------------------- | ------- | ---------------------------------------------- |
| `intelligence.enabled`              | `false` | Master switch for the intelligence engine      |
| `intelligence.composer_enabled`     | `false` | Dynamic pipeline composition based on analysis |
| `intelligence.optimization_enabled` | `false` | Self-tuning based on historical metrics        |
| `intelligence.prediction_enabled`   | `false` | Risk scoring and anomaly detection             |
| `intelligence.adversarial_enabled`  | `false` | Adversarial code review pass                   |
| `intelligence.simulation_enabled`   | `false` | Developer workflow simulation testing          |
| `intelligence.architecture_enabled` | `false` | Architecture rule enforcement                  |
| `intelligence.ab_test_ratio`        | `0.2`   | Fraction of runs using composed pipelines      |
| `intelligence.anomaly_threshold`    | `3.0`   | Standard deviations for anomaly detection      |
| `intelligence.cache_ttl_seconds`    | `3600`  | How long intelligence cache entries live       |

### Modules

- **Intelligence Engine** (`sw-intelligence.sh`): Analyzes codebase structure, file change frequency, and test coverage to produce a cached analysis used by other modules.
- **Pipeline Composer** (`sw-pipeline-composer.sh`): Generates custom pipeline configurations by adjusting stage timeouts, iteration counts, and model routing based on intelligence output.
- **Self-Optimize** (`sw-self-optimize.sh`): Reads DORA metrics (lead time, deployment frequency, CFR, MTTR) and adjusts daemon config to improve performance over time.
- **Predictive** (`sw-predictive.sh`): Scores incoming issues for risk, detects anomalies in pipeline metrics, and provides AI patrol summaries.
- **Adversarial Review** (`sw-adversarial.sh`): Runs a second-pass adversarial review looking for edge cases, security issues, and failure modes.
- **Developer Simulation** (`sw-developer-simulation.sh`): Simulates developer workflows (clone, install, build, test) to catch UX issues.
- **Architecture Enforcer** (`sw-architecture-enforcer.sh`): Validates changes against architecture rules (dependency direction, naming conventions, layer boundaries).

### Enabling

```json
{
  "intelligence": {
    "enabled": true,
    "composer_enabled": true,
    "prediction_enabled": true
  }
}
```

The daemon calls into the intelligence layer at spawn time. The `intelligence` and `predict` CLI commands can also be run standalone.

## Development Guidelines

### Shell Standards

- All scripts use `set -euo pipefail`
- **Bash 3.2 compatible** — no `declare -A` (associative arrays), no `readarray`, no `${var,,}` (lowercase), no `${var^^}` (uppercase)
- `VERSION` variable at top of every script — keep in sync
- Event logging: `emit_event "type" "key=val" "key2=val2"` writes to `events.jsonl`

### Output Helpers

- `info()`, `success()`, `warn()`, `error()` — standardized output
- Boxed headers with Unicode box-drawing characters

### Colors

| Name   | Hex       | Usage                          |
| ------ | --------- | ------------------------------ |
| Cyan   | `#00d4ff` | Primary accent, active borders |
| Purple | `#7c3aed` | Tertiary accent                |
| Blue   | `#0066ff` | Secondary accent               |
| Green  | `#4ade80` | Success indicators             |

### Common Pitfalls

- `grep -c || echo "0"` under pipefail produces double output — use `|| true` + `${var:-0}`
- `cmd | while read` loses variable state (subshell) — use `while read; done < <(cmd)`
- Atomic file writes: use tmp file + `mv`, not direct `echo > file`
- JSON in bash: use `jq --arg` for proper escaping, never string interpolation
- `cd` in helper functions changes caller's directory — use subshells `( cd dir && ... )`
- Check `$NO_GITHUB` in any new GitHub API features

## Test Harness

```bash
# Run all pipeline tests (mock binaries, no real Claude/GitHub calls)
./scripts/sw-pipeline-test.sh

# Run all 16 test suites
npm test
```

The 16 test suites registered in `package.json`:

1. `sw-pipeline-test.sh` — Pipeline flow
2. `sw-daemon-test.sh` — Daemon lifecycle
3. `sw-prep-test.sh` — Repo preparation
4. `sw-fleet-test.sh` — Fleet orchestration
5. `sw-fix-test.sh` — Bulk fix
6. `sw-memory-test.sh` — Memory system
7. `sw-session-test.sh` — Session creation
8. `sw-init-test.sh` — Init setup
9. `sw-tracker-test.sh` — Tracker routing
10. `sw-heartbeat-test.sh` — Heartbeat
11. `sw-remote-test.sh` — Remote management
12. `sw-intelligence-test.sh` — Intelligence engine
13. `sw-pipeline-composer-test.sh` — Pipeline composer
14. `sw-self-optimize-test.sh` — Self-optimization
15. `sw-predictive-test.sh` — Predictive intelligence
16. `sw-frontier-test.sh` — Frontier capabilities (adversarial, simulation, architecture)

Each test suite uses mock binaries in a temp directory, with PASS/FAIL counters, colored output, and ERR traps.
