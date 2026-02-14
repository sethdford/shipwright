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
| `shipwright connect start`                         | Sync local state to team dashboard                |
| `shipwright connect join --token <t>`              | Join a team using an invite token                 |
| `shipwright connect status`                        | Show connection status                            |
| `shipwright launchd install`                       | Auto-start daemon + dashboard + connect on boot   |
| `shipwright github context`                        | Show repo GitHub context (contributors, alerts)   |
| `shipwright github security`                       | Show CodeQL + Dependabot security alerts          |
| `shipwright checks list`                           | List GitHub Check runs for a commit               |
| `shipwright deploys list`                          | List GitHub deployments by environment            |
| `shipwright vitals`                                | Pipeline vitals — real-time health scoring        |

## Pipeline Stages

12 stages, each can be enabled/disabled and gated (auto-proceed or pause for approval):

```
intake → plan → design → build → test → review → compound_quality → pr → merge → deploy → validate → monitor
```

The build stage delegates to `shipwright loop` for autonomous multi-iteration development. Self-healing: when tests fail, the pipeline re-enters the build loop with error context.

### Build Loop Capabilities

- **Session restart** (`--max-restarts N`): When the loop exhausts iterations without completing, it restarts with a fresh Claude session that reads progress from `progress.md`. Git state = resume point. Default 0 (off) for manual, 3 for daemon.
- **Progress persistence**: `progress.md` written after each iteration with goal, iteration count, test status, recent commits, changed files. Fresh sessions orient from this file.
- **Structured error feedback**: `error-summary.json` written after test failures with machine-readable error lines. Injected into the next iteration prompt as structured context.
- **Fast test mode** (`--fast-test-cmd "cmd"`): Alternates between a fast subset test and the full suite. Full test runs on iteration 1, every N iterations (`--fast-test-interval`, default 5), and the final iteration.
- **Agent roles** (`--roles "builder,reviewer,tester"`): In multi-agent mode, assigns specialization per agent. Built-in roles: `builder`, `reviewer`, `tester`, `optimizer`, `docs`, `security`.
- **Context exhaustion detection**: When the daemon detects a build loop failed due to iteration exhaustion (not a code error), it tags the failure as `context_exhaustion` and boosts `--max-restarts` on retry.

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

## tmux Integration

Shipwright includes a production tmux configuration optimized for Claude Code TUI compatibility, agent team workflows, and multi-pane management.

### Key Bindings

| Binding           | Action                                |
| ----------------- | ------------------------------------- |
| `prefix + T`      | Launch Shipwright team session        |
| `prefix + Ctrl-t` | Team dashboard in floating popup      |
| `prefix + G`      | Toggle zoom on current pane           |
| `prefix + g`      | Display pane numbers (type to select) |
| `prefix + F`      | Floating popup terminal               |
| `prefix + C-f`    | FZF session switcher                  |
| `prefix + M-1`    | Horizontal layout (leader 65% left)   |
| `prefix + M-2`    | Vertical layout (leader 60% top)      |
| `prefix + M-3`    | Tiled layout (equal sizes)            |
| `prefix + M-s`    | Capture current pane to file          |
| `prefix + M-a`    | Capture all panes to files            |
| `prefix + M-d`    | Full dashboard popup                  |
| `prefix + M-m`    | Memory system popup                   |
| `prefix + R`      | Reap dead agent panes                 |
| `prefix + S`      | Sync panes (toggle)                   |

### Claude Code Compatibility

| Setting             | Value    | Why                                                  |
| ------------------- | -------- | ---------------------------------------------------- |
| `allow-passthrough` | `on`     | DEC 2026 synchronized output — eliminates flicker    |
| `extended-keys`     | `on`     | TUI apps receive modifier key combos properly        |
| `escape-time`       | `0`      | No input delay                                       |
| `history-limit`     | `250000` | Handles Claude Code's high output volume             |
| `set-clipboard`     | `on`     | Native OSC 52 clipboard (works across SSH + nesting) |
| `focus-events`      | `on`     | TUI focus tracking                                   |

### Plugins (via TPM)

| Plugin           | Purpose                                       |
| ---------------- | --------------------------------------------- |
| `tmux-sensible`  | Sensible defaults everyone agrees on          |
| `tmux-resurrect` | Persist sessions across restarts              |
| `tmux-continuum` | Auto-save every 15 min, auto-restore on start |
| `tmux-yank`      | System clipboard integration (OSC 52)         |
| `tmux-fzf`       | Fuzzy finder for sessions/windows/panes       |

### tmux Health Management

```bash
shipwright tmux doctor     # Check Claude Code compat + features
shipwright tmux install    # Install TPM + all plugins
shipwright tmux fix        # Auto-fix issues in running session
shipwright tmux reload     # Reload config
```

### Conventions

- Team windows: named `claude-<team-name>` (shows lambda icon in status bar)
- Pane titles: `<team>-<role>` (visible in pane borders via pane-border-status)
- Set pane title: `printf '\033]2;agent-name\033\\'`
- Prefix key: **Ctrl-a**
- Adapter uses pane IDs (not indices) to avoid the pane-base-index bug

## Architecture

All scripts are bash (except the dashboard server in TypeScript). Grouped by layer:

### Core Scripts

<!-- AUTO:core-scripts -->

| File | Lines | Purpose |
| --- | ---: | --- |
| `scripts/sw-adversarial.sh` | 274 | Adversarial Agent Code Review |
| `scripts/sw-architecture-enforcer.sh` | 330 | Living Architecture Model & Enforcer |
| `scripts/sw-checkpoint.sh` | 468 | Save and restore agent state mid-stage |
| `scripts/sw-cleanup.sh` | 359 | Clean up orphaned Claude team sessions & artifacts |
| `scripts/sw-connect.sh` | 619 | Sync local state to team dashboard |
| `scripts/sw-context.sh` | 605 | Context Engine for Pipeline Stages |
| `scripts/sw-cost.sh` | 924 | Token Usage & Cost Intelligence |
| `scripts/sw-daemon.sh` | 5869 | Autonomous GitHub Issue Watcher |
| `scripts/sw-dashboard.sh` | 477 | Fleet Command Dashboard |
| `scripts/sw-db.sh` | 540 | SQLite Persistence Layer |
| `scripts/sw-decompose.sh` | 539 | Intelligent Issue Decomposition |
| `scripts/sw-deps.sh` | 551 | Automated Dependency Update Management |
| `scripts/sw-developer-simulation.sh` | 252 | Multi-Persona Developer Simulation |
| `scripts/sw-discovery.sh` | 412 | Cross-Pipeline Real-Time Learning |
| `scripts/sw-docs.sh` | 635 | Documentation Keeper |
| `scripts/sw-doctor.sh` | 965 | Validate Shipwright setup |
| `scripts/sw-dora.sh` | 615 | DORA Metrics Dashboard with Engineering Intelligence |
| `scripts/sw-eventbus.sh` | 393 | Durable event bus for real-time inter-component |
| `scripts/sw-feedback.sh` | 471 | Production Feedback Loop |
| `scripts/sw-fix.sh` | 482 | Bulk Fix Across Multiple Repos |
| `scripts/sw-fleet-discover.sh` | 567 | Auto-Discovery from GitHub Orgs |
| `scripts/sw-fleet-viz.sh` | 404 | Multi-Repo Fleet Visualization |
| `scripts/sw-fleet.sh` | 1387 | Multi-Repo Daemon Orchestrator |
| `scripts/sw-heartbeat.sh` | 293 | File-based agent heartbeat protocol |
| `scripts/sw-init.sh` | 609 | Complete setup for Shipwright + Shipwright |
| `scripts/sw-intelligence.sh` | 1196 | AI-Powered Analysis & Decision Engine |
| `scripts/sw-jira.sh` | 643 | Jira ↔ GitHub Bidirectional Sync |
| `scripts/sw-launchd.sh` | 699 | Process supervision (macOS + Linux) |
| `scripts/sw-linear.sh` | 648 | Linear ↔ GitHub Bidirectional Sync |
| `scripts/sw-logs.sh` | 343 | View and search agent pane logs |
| `scripts/sw-loop.sh` | 2278 | Continuous agent loop harness for Claude Code |
| `scripts/sw-memory.sh` | 1626 | Persistent Learning & Context System |
| `scripts/sw-model-router.sh` | 545 | Intelligent Model Routing & Cost Optimization |
| `scripts/sw-otel.sh` | 596 | OpenTelemetry Observability |
| `scripts/sw-patrol-meta.sh` | 417 | Shipwright Self-Improvement Patrol |
| `scripts/sw-pipeline-composer.sh` | 455 | Dynamic Pipeline Composition |
| `scripts/sw-pipeline-vitals.sh` | 1096 | Pipeline Vitals Engine |
| `scripts/sw-pipeline.sh` | 8256 | Autonomous Feature Delivery (Idea → Production) |
| `scripts/sw-pm.sh` | 693 | Autonomous PM Agent for Team Orchestration |
| `scripts/sw-pr-lifecycle.sh` | 522 | Autonomous PR Management |
| `scripts/sw-predictive.sh` | 820 | Predictive & Proactive Intelligence |
| `scripts/sw-prep.sh` | 1642 | Repository Preparation for Agent Teams |
| `scripts/sw-ps.sh` | 171 | Show running agent process status |
| `scripts/sw-quality.sh` | 595 | Intelligent completion, audits, zero auto |
| `scripts/sw-reaper.sh` | 394 | Automatic tmux pane cleanup when agents exit |
| `scripts/sw-regression.sh` | 642 | Regression Detection Pipeline |
| `scripts/sw-release.sh` | 706 | Release train automation |
| `scripts/sw-remote.sh` | 687 | Machine Registry & Remote Daemon Management |
| `scripts/sw-replay.sh` | 520 | Pipeline run replay, timeline viewing, narratives |
| `scripts/sw-scale.sh` | 444 | Dynamic agent team scaling during pipeline execution |
| `scripts/sw-self-optimize.sh` | 1048 | Learning & Self-Tuning System |
| `scripts/sw-session.sh` | 541 | Launch a Claude Code team session in a new tmux window |
| `scripts/sw-setup.sh` | 234 | One-shot setup: check prerequisites, init, doctor |
| `scripts/sw-status.sh` | 796 | Dashboard showing Claude Code team status |
| `scripts/sw-templates.sh` | 247 | Browse and inspect team templates |
| `scripts/sw-tmux-pipeline.sh` | 554 | Spawn and manage pipelines in tmux windows |
| `scripts/sw-tmux.sh` | 591 | tmux Health & Plugin Management |
| `scripts/sw-trace.sh` | 485 | E2E Traceability (Issue → Commit → PR → Deploy) |
| `scripts/sw-tracker.sh` | 409 | Provider Router for Issue Tracker Integration |
| `scripts/sw-triage.sh` | 603 | Intelligent Issue Labeling & Prioritization |
| `scripts/sw-upgrade.sh` | 479 | Detect and apply updates from the repo |
| `scripts/sw-webhook.sh` | 627 | GitHub Webhook Receiver for Instant Issue Processing |
| `scripts/sw-widgets.sh` | 530 | Embeddable Status Widgets |
| `scripts/sw-worktree.sh` | 408 | Git worktree management for multi-agent isolation |
| `scripts/sw` | 428 | CLI router — dispatches subcommands via exec |
<!-- /AUTO:core-scripts -->

### GitHub API Modules

<!-- AUTO:github-modules -->

| File | Lines | Purpose |
| --- | ---: | --- |
| `scripts/sw-github-checks.sh` | 521 | Native GitHub Checks API Integration |
| `scripts/sw-github-deploy.sh` | 533 | Native GitHub Deployments API Integration |
| `scripts/sw-github-graphql.sh` | 972 | GitHub GraphQL API Client |
<!-- /AUTO:github-modules -->

### Issue Tracker Adapters

<!-- AUTO:tracker-adapters -->

| File | Lines | Purpose |
| --- | ---: | --- |
| `scripts/sw-linear.sh` | 648 | Linear ↔ GitHub Bidirectional Sync |
| `scripts/sw-jira.sh` | 643 | Jira ↔ GitHub Bidirectional Sync |
| `scripts/sw-tracker-linear.sh` | 292 | do not call directly |
| `scripts/sw-tracker-jira.sh` | 277 | do not call directly |
<!-- /AUTO:tracker-adapters -->

### Shared Libraries

| File                    | Lines | Purpose                            |
| ----------------------- | ----: | ---------------------------------- |
| `scripts/lib/compat.sh` |     — | Cross-platform compatibility shims |

### Test Suites

<!-- AUTO:test-suites -->

| File | Lines | Purpose |
| --- | ---: | --- |
| `scripts/sw-connect-test.sh` | 831 | Validate dashboard connection, heartbeat |
| `scripts/sw-daemon-test.sh` | 2001 | Unit tests for daemon metrics, health, alerting |
| `scripts/sw-docs-test.sh` | 791 | Validate documentation keeper, AUTO sections, |
| `scripts/sw-e2e-integration-test.sh` | 359 | Real Claude + Real GitHub |
| `scripts/sw-e2e-smoke-test.sh` | 799 | Pipeline orchestration without API keys |
| `scripts/sw-fix-test.sh` | 630 | Unit tests for bulk fix across repos |
| `scripts/sw-fleet-test.sh` | 833 | Unit tests for fleet orchestration |
| `scripts/sw-frontier-test.sh` | 581 | Validate adversarial review, developer |
| `scripts/sw-github-checks-test.sh` | 541 | Validate Checks API wrapper |
| `scripts/sw-github-deploy-test.sh` | 530 | Validate Deployments API wrapper |
| `scripts/sw-github-graphql-test.sh` | 671 | Unit tests for GitHub GraphQL client |
| `scripts/sw-heartbeat-test.sh` | 588 | Validate heartbeat lifecycle, |
| `scripts/sw-init-test.sh` | 494 | E2E validation of init/setup flow |
| `scripts/sw-intelligence-test.sh` | 544 | Unit tests for intelligence core |
| `scripts/sw-launchd-test.sh` | 908 | Validate service management on |
| `scripts/sw-memory-test.sh` | 872 | Unit tests for memory system & cost tracking |
| `scripts/sw-pipeline-composer-test.sh` | 643 | Test Suite |
| `scripts/sw-pipeline-test.sh` | 1900 | E2E validation invoking the REAL pipeline |
| `scripts/sw-predictive-test.sh` | 698 | Unit tests for predictive intelligence |
| `scripts/sw-prep-test.sh` | 644 | Validate repo preparation |
| `scripts/sw-remote-test.sh` | 404 | Validate machine registry, atomic writes, |
| `scripts/sw-self-optimize-test.sh` | 730 | Unit tests for learning & tuning system |
| `scripts/sw-session-test.sh` | 591 | E2E validation of session creation flow |
| `scripts/sw-status-test.sh` | 339 | Validate status dashboard and --json output |
| `scripts/sw-tmux-test.sh` | 752 | Validate tmux doctor, install, fix, reload, |
| `scripts/sw-tracker-test.sh` | 476 | Validate tracker router, providers, and |
<!-- /AUTO:test-suites -->

### Dashboard & Infra

| File                   | Lines | Purpose                            |
| ---------------------- | ----: | ---------------------------------- |
| `dashboard/server.ts`  |  3501 | Bun WebSocket dashboard server     |
| `dashboard/public/`    |     — | Dashboard frontend (HTML/CSS/JS)   |
| `install.sh`           |   755 | Interactive installer              |
| `templates/pipelines/` |     — | 8 pipeline template JSON files     |
| `tmux/templates/`      |     — | 24 team composition JSON templates |

### Runtime State and Artifacts

<!-- AUTO:runtime-state -->

- Pipeline state: `.claude/pipeline-state.md`
- Pipeline artifacts: `.claude/pipeline-artifacts/`
- Composed pipeline: `.claude/pipeline-artifacts/composed-pipeline.json`
- Events log: `~/.shipwright/events.jsonl`
- Daemon config: `.claude/daemon-config.json`
- Fleet config: `.claude/fleet-config.json`
- Heartbeats: `~/.shipwright/heartbeats/<job-id>.json`
- Checkpoints: `.claude/pipeline-artifacts/checkpoints/`
- Machine registry: `~/.shipwright/machines.json`
- Cost data: `~/.shipwright/costs.json, ~/.shipwright/budget.json`
- Intelligence cache: `.claude/intelligence-cache.json`
- Optimization data: `~/.shipwright/optimization/`
- Baselines: `~/.shipwright/baselines/`
- Architecture models: `~/.shipwright/memory/<repo-hash>/architecture.json`
- Team config: `~/.shipwright/team-config.json`
- Developer registry: `~/.shipwright/developer-registry.json`
- Team events: `~/.shipwright/team-events.jsonl`
- Invite tokens: `~/.shipwright/invite-tokens.json`
- Connect PID: `~/.shipwright/connect.pid`
- Connect log: `~/.shipwright/connect.log`
- GitHub cache: `~/.shipwright/github-cache/`
- Check run IDs: `.claude/pipeline-artifacts/check-run-ids.json`
- Deployment tracking: `.claude/pipeline-artifacts/deployment.json`
- Error log: `.claude/pipeline-artifacts/error-log.jsonl`
<!-- /AUTO:runtime-state -->

## GitHub Integration

The pipeline uses native GitHub APIs for CI integration, deployment tracking, and intelligent reviewer selection.

### GitHub API Modules

- **GraphQL Client** (`sw-github-graphql.sh`): Cached queries for file change frequency, blame data, contributors, similar issues, commit history, branch protection, CODEOWNERS, security alerts, Dependabot alerts, and Actions run history. All intelligence modules call through this layer.
- **Checks API** (`sw-github-checks.sh`): Creates native GitHub Check Runs per pipeline stage (visible in PR timeline). Replaces comment-based stage tracking with first-class GitHub UI integration.
- **Deployments API** (`sw-github-deploy.sh`): Tracks deployments per environment (staging/production). Enables rollback, deployment history, and environment state tracking.

### Pipeline Integration

- **Stage tracking**: Each pipeline stage creates/updates a GitHub Check Run (in addition to existing comment-based tracking)
- **Deployment tracking**: Deploy stage creates GitHub Deployment objects with status updates
- **Reviewer selection**: PR stage routes reviews to CODEOWNERS first, then top contributors, with auto-approve fallback
- **Branch protection**: Merge stage checks required reviews and status checks before attempting auto-merge
- **Intelligence enrichment**: All intelligence modules receive GitHub context (security alerts, contributor data, CI history, file churn)
- **Patrol enhancement**: Security patrol enriched with CodeQL + Dependabot alert data
- **Doctor checks**: Section 13 validates GitHub API access, scopes, GraphQL, and module installation

## Intelligence Layer

All intelligence features are behind feature flags and disabled by default. Configure in `.claude/daemon-config.json` under the `intelligence` key.

### Feature Flags

<!-- AUTO:feature-flags -->

| Flag | Default | Purpose |
| --- | --- | --- |
| `intelligence.enabled` | `true` | |
| `intelligence.cache_ttl_seconds` | `3600` | |
| `intelligence.composer_enabled` | `true` | |
| `intelligence.optimization_enabled` | `true` | |
| `intelligence.prediction_enabled` | `true` | |
| `intelligence.adversarial_enabled` | `false` | |
| `intelligence.simulation_enabled` | `false` | |
| `intelligence.architecture_enabled` | `false` | |
| `intelligence.ab_test_ratio` | `0.2` | |
| `intelligence.anomaly_threshold` | `3.0` | |
<!-- /AUTO:feature-flags -->

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

## Custom Agents

Specialized agent definitions in `.claude/agents/` are loaded automatically by Claude Code when agents are spawned:

| Agent                   | File                         | Purpose                                                                 |
| ----------------------- | ---------------------------- | ----------------------------------------------------------------------- |
| Shell Script Specialist | `shell-script-specialist.md` | Bash 3.2 rules, pipefail safety, atomic writes, test harness patterns   |
| Code Reviewer           | `code-reviewer.md`           | Review checklist, security, performance, architecture layer boundaries  |
| Test Specialist         | `test-specialist.md`         | Test harness conventions, mock patterns, PASS/FAIL counting, coverage   |
| DevOps Engineer         | `devops-engineer.md`         | GitHub Actions, pipeline workflows, GitHub API, worktree management     |
| Pipeline Agent          | `pipeline-agent.md`          | Build loop context, memory injection, architecture rules, file hotspots |

## Hooks

Repo-level hooks in `.claude/hooks/` fire on lifecycle events. Registered in `.claude/settings.json`.

| Hook                 | Trigger                          | Purpose                                                      |
| -------------------- | -------------------------------- | ------------------------------------------------------------ |
| `pre-tool-use.sh`    | Before Edit/Write on `.sh` files | Injects bash 3.2 compatibility reminder                      |
| `post-tool-use.sh`   | After Bash tool failures         | Captures error signatures to `error-log.jsonl`               |
| `session-started.sh` | On session start                 | Shows pipeline state, recent failures, active issues, budget |

## Documentation Keeper

Auto-sync documentation from source code using HTML comment markers (`AUTO:section-id` pairs).

```bash
shipwright docs check      # Report which sections are stale (exit 1 if any)
shipwright docs sync       # Regenerate all stale AUTO sections
shipwright docs wiki       # Generate/update GitHub wiki pages
shipwright docs report     # Show documentation freshness report
```

AUTO sections in `.claude/CLAUDE.md`: `core-scripts`, `github-modules`, `tracker-adapters`, `test-suites`, `feature-flags`, `runtime-state`. The daemon patrol auto-syncs stale sections. A GitHub Actions workflow (`shipwright-docs.yml`) runs on push to main and weekly.

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

# Run all 22 test suites
npm test
```

The 22 test suites registered in `package.json`:

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
17. `sw-connect-test.sh` — Connect/team platform
18. `sw-github-graphql-test.sh` — GitHub GraphQL client
19. `sw-github-checks-test.sh` — GitHub Checks API
20. `sw-github-deploy-test.sh` — GitHub Deployments API
21. `sw-docs-test.sh` — Documentation keeper
22. `sw-tmux-test.sh` — tmux health & plugin management

Each test suite uses mock binaries in a temp directory, with PASS/FAIL counters, colored output, and ERR traps.
