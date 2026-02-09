# Shipwright

Shipwright orchestrates autonomous Claude Code agent teams with delivery pipelines, daemon-driven issue processing, fleet operations across multiple repos, persistent memory, DORA metrics, cost intelligence, and repo preparation. All CLI aliases — `shipwright`, `sw`, `cct` — work identically.

## Commands

| Command                                            | Purpose                                           |
| -------------------------------------------------- | ------------------------------------------------- |
| `shipwright init`                                  | One-command tmux setup (no prompts)               |
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
| `shipwright worktree create <branch>`              | Git worktree for agent isolation                  |
| `shipwright templates list`                        | Browse team templates                             |
| `shipwright dashboard`                             | Real-time web dashboard (requires Bun)            |
| `shipwright dashboard start`                       | Start dashboard in background                     |
| `shipwright heartbeat list`                        | Show agent heartbeat status                       |
| `shipwright checkpoint list`                       | Show saved pipeline checkpoints                   |
| `shipwright remote list`                           | Show registered remote machines                   |
| `shipwright remote add <name> --host <h>`          | Register a remote worker machine                  |
| `shipwright remote status`                         | Health check all remote machines                  |

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

All scripts are bash. Key files with approximate line counts:

| File                        | Lines | Purpose                                         |
| --------------------------- | ----- | ----------------------------------------------- |
| `scripts/cct`               | ~240  | CLI router — dispatches subcommands via `exec`  |
| `scripts/cct-pipeline.sh`   | ~3800 | Delivery pipeline + compound quality stage      |
| `scripts/cct-daemon.sh`     | ~3200 | Autonomous issue watcher + metrics + auto-scale |
| `scripts/cct-prep.sh`       | ~1350 | Repo preparation and config generation          |
| `scripts/cct-loop.sh`       | ~1330 | Continuous autonomous agent loop                |
| `scripts/cct-memory.sh`     | ~1150 | Persistent learning and context system          |
| `scripts/cct-fleet.sh`      | ~900  | Multi-repo daemon orchestration                 |
| `scripts/cct-cost.sh`       | ~590  | Token usage and cost intelligence               |
| `scripts/cct-doctor.sh`     | ~820  | Setup validation and diagnostics                |
| `scripts/cct-fix.sh`        | ~480  | Bulk fix across repos                           |
| `scripts/cct-upgrade.sh`    | ~430  | Upgrade checker and applier                     |
| `scripts/cct-init.sh`       | ~390  | One-command tmux setup                          |
| `scripts/cct-session.sh`    | ~280  | Team session creation from templates            |
| `scripts/cct-heartbeat.sh`  | ~290  | Agent heartbeat writer/checker                  |
| `scripts/cct-checkpoint.sh` | ~300  | Pipeline checkpoint save/restore                |
| `scripts/cct-remote.sh`     | ~500  | Multi-machine registry + remote management      |
| `scripts/cct-tracker.sh`    | ~200  | Issue tracker router (Linear/Jira)              |
| `scripts/cct-dashboard.sh`  | ~470  | Dashboard server launcher                       |
| `dashboard/server.ts`       | ~1900 | Bun WebSocket dashboard server                  |
| `dashboard/public/`         | —     | Dashboard frontend (HTML/CSS/JS)                |
| `install.sh`                | ~720  | Interactive installer                           |
| `templates/pipelines/`      | —     | 8 pipeline template JSON files                  |
| `tmux/templates/`           | —     | 24 team composition JSON templates              |

State and artifacts at runtime:

- Pipeline state: `.claude/pipeline-state.md`
- Pipeline artifacts: `.claude/pipeline-artifacts/`
- Events log: `~/.claude-teams/events.jsonl` (JSONL for metrics)
- Daemon config: `.claude/daemon-config.json`
- Fleet config: `.claude/fleet-config.json`
- Heartbeats: `~/.claude-teams/heartbeats/<job-id>.json`
- Checkpoints: `.claude/pipeline-artifacts/checkpoints/`
- Machine registry: `~/.claude-teams/machines.json`
- Cost data: `~/.shipwright/costs.json`, `~/.shipwright/budget.json`

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
./scripts/cct-pipeline-test.sh

# Run all test suites (pipeline, daemon, prep, fleet, fix, memory, session, init, tracker, heartbeat, remote)
npm test
```

The pipeline test harness (`scripts/cct-pipeline-test.sh`, ~870 lines) uses mock binaries to test pipeline flow without external dependencies.
