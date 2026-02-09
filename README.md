# Shipwright

> Orchestrate autonomous Claude Code agent teams — delivery pipeline, fleet operations, DORA metrics, persistent memory, cost intelligence, and repo preparation.

[![v1.7.1](https://img.shields.io/badge/version-1.7.1-00d4ff?style=flat-square)](https://github.com/sethdford/shipwright/releases) ![tmux dark theme with cyan accents](https://img.shields.io/badge/theme-dark%20blue--gray%20%2B%20cyan-00d4ff?style=flat-square) ![MIT License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

<p align="center">
  <img src="https://vhs.charm.sh/vhs-189lBjHtyH2su8TuxiPQhn.gif" alt="Shipwright CLI demo — version, help, pipeline templates, doctor" width="800" />
</p>

Full docs at [sethdford.github.io/shipwright](https://sethdford.github.io/shipwright)

## Install

**npm** (recommended)

```bash
npm install -g shipwright-cli
```

**curl**

```bash
curl -fsSL https://raw.githubusercontent.com/sethdford/shipwright/main/scripts/install-remote.sh | sh
```

**Homebrew**

```bash
brew install sethdford/shipwright/shipwright
```

**From source**

```bash
git clone https://github.com/sethdford/shipwright.git
cd shipwright && ./install.sh
```

## What's This?

Claude Code's **agent teams** feature lets you spawn multiple AI agents that work in parallel on different parts of a task — one on backend, one on frontend, one writing tests, etc. When you run Claude Code inside tmux, each agent gets its own pane so you can watch them all work simultaneously.

Shipwright packages a complete setup:

- **Premium dark tmux theme** with agent-aware pane borders
- **`shipwright` CLI** (also `sw` or `cct`) for managing team sessions, templates, and autonomous loops
- **Quality gate hooks** that block agents until code passes checks
- **Continuous agent loop** (`shipwright loop`) for autonomous multi-iteration development
- **Delivery pipeline** (`shipwright pipeline`) for full idea-to-PR automation
- **Autonomous daemon** (`shipwright daemon`) for GitHub issue watching and auto-delivery
- **Fleet operations** (`shipwright fleet`) for multi-repo daemon orchestration
- **Bulk fix** (`shipwright fix`) for applying the same fix across multiple repos
- **Persistent memory** (`shipwright memory`) for cross-pipeline learning and context injection
- **Cost intelligence** (`shipwright cost`) for token tracking, budgets, and model routing
- **DORA metrics** (`shipwright daemon metrics`) for engineering performance tracking
- **Repo preparation** (`shipwright prep`) for generating agent-ready `.claude/` configs
- **Deploy adapters** for Vercel, Fly.io, Railway, and Docker
- **Layout presets** that give the leader pane 60-65% of screen space
- **One-command setup** via `shipwright init`

## Prerequisites

| Requirement         | Version                           | Notes                                          |
| ------------------- | --------------------------------- | ---------------------------------------------- |
| **tmux**            | 3.2+ (tested on 3.6a)             | `brew install tmux` on macOS                   |
| **jq**              | any                               | `brew install jq` — JSON parsing for templates |
| **Claude Code CLI** | latest                            | `npm install -g @anthropic-ai/claude-code`     |
| **Node.js**         | 20+                               | For hooks                                      |
| **Git**             | any                               | For installation                               |
| **Terminal**        | iTerm2, Alacritty, Kitty, WezTerm | See note below                                 |

> **Terminal compatibility:** Split-pane agent teams only work in real terminal emulators. **VS Code's integrated terminal and Ghostty are not supported** — they lack the tmux integration needed for agent pane spawning. See [Known Issues](docs/KNOWN-ISSUES.md) for details.

## Quick Start

**Option A: One-command setup (just tmux config, no prompts)**

```bash
git clone https://github.com/sethdford/shipwright.git
cd shipwright
shipwright init
```

**Option B: Full interactive install (tmux + settings + hooks + CLI)**

```bash
git clone https://github.com/sethdford/shipwright.git
cd shipwright
./install.sh
```

Then start a tmux session and launch Claude Code:

```bash
tmux new -s dev
claude
```

## What's Included

```
shipwright/
├── tmux/
│   ├── tmux.conf                    # Full tmux config with premium dark theme
│   ├── claude-teams-overlay.conf    # Agent-aware pane styling, color hooks & keybindings
│   └── templates/                   # 24 team composition templates (full SDLC + PDLC)
│       ├── feature-dev.json         #   Backend + frontend + tests (3 agents)
│       ├── full-stack.json          #   API + database + UI (3 agents)
│       ├── bug-fix.json             #   Reproducer + fixer + verifier (3 agents)
│       ├── code-review.json         #   Quality + security + coverage (3 agents)
│       ├── security-audit.json      #   Code + deps + config (3 agents)
│       ├── testing.json             #   Unit + integration + e2e (3 agents)
│       ├── migration.json           #   Schema + adapter + rollback (3 agents)
│       ├── refactor.json            #   Refactor + consumers (2 agents)
│       ├── documentation.json       #   API docs + guides (2 agents)
│       ├── devops.json              #   Pipeline + infrastructure (2 agents)
│       ├── architecture.json        #   Researcher + spec writer (2 agents)
│       ├── exploration.json         #   Explorer + synthesizer (2 agents)
│       ├── accessibility.json       #   Audit + remediation (2 agents)
│       ├── api-design.json          #   API design + contracts (2 agents)
│       ├── compliance.json          #   Compliance audit + remediation (2 agents)
│       ├── data-pipeline.json       #   ETL + data processing (2 agents)
│       ├── debt-paydown.json        #   Tech debt identification + fix (2 agents)
│       ├── i18n.json                #   Internationalization + translation (2 agents)
│       ├── incident-response.json   #   Triage + fix + postmortem (3 agents)
│       ├── observability.json       #   Metrics + logging + tracing (2 agents)
│       ├── onboarding.json          #   Setup + documentation (2 agents)
│       ├── performance.json         #   Profile + optimize (2 agents)
│       ├── release.json             #   Release prep + validation (2 agents)
│       └── spike.json               #   Research spike + prototype (2 agents)
├── templates/
│   └── pipelines/                   # 8 delivery pipeline templates
│       ├── standard.json            #   Feature pipeline (plan + review gates)
│       ├── fast.json                #   Quick fixes (all auto, no gates)
│       ├── full.json                #   Full deployment (all stages)
│       ├── hotfix.json              #   Urgent fixes (all auto, minimal)
│       ├── autonomous.json          #   Daemon-driven (fully autonomous)
│       ├── enterprise.json          #   Maximum safety (all gates on approve, auto-rollback)
│       ├── cost-aware.json          #   Budget limits, model routing (haiku→sonnet→opus)
│       └── deployed.json            #   Full autonomous + deploy + validate + monitor
├── completions/                     # Shell tab completions
│   ├── shipwright.bash              #   Bash completions
│   ├── _shipwright                  #   Zsh completions
│   └── shipwright.fish              #   Fish completions
├── claude-code/
│   ├── settings.json.template       # Claude Code settings with teams + hooks
│   └── hooks/
│       ├── teammate-idle.sh         # Quality gate: typecheck before idle
│       ├── task-completed.sh        # Quality gate: lint+test before done
│       ├── notify-idle.sh           # Desktop notification on idle
│       └── pre-compact-save.sh      # Save context before compaction
├── scripts/
│   ├── cct                          # CLI router (shipwright/sw/cct)
│   ├── cct-init.sh                  # One-command tmux setup (no prompts)
│   ├── cct-session.sh               # Create team sessions from templates
│   ├── cct-loop.sh                  # Continuous autonomous agent loop
│   ├── cct-pipeline.sh              # Full delivery pipeline (idea → PR)
│   ├── cct-daemon.sh                # Autonomous issue watcher + metrics
│   ├── cct-fleet.sh                 # Multi-repo daemon orchestrator
│   ├── cct-fix.sh                   # Bulk fix across repos
│   ├── cct-memory.sh                # Persistent learning & context system
│   ├── cct-cost.sh                  # Token usage & cost intelligence
│   ├── cct-prep.sh                  # Repo preparation tool
│   ├── cct-doctor.sh                # Validate setup and diagnose issues
│   ├── cct-heartbeat.sh             # Agent heartbeat writer/checker
│   ├── cct-checkpoint.sh            # Pipeline checkpoint save/restore
│   ├── cct-remote.sh                # Multi-machine registry + remote management
│   ├── cct-tracker.sh               # Issue tracker router (Linear/Jira)
│   ├── cct-dashboard.sh             # Dashboard server launcher
│   ├── install-completions.sh       # Shell completion installer
│   ├── adapters/                    # Deploy platform adapters
│   │   ├── vercel-deploy.sh         #   Vercel deploy adapter
│   │   ├── fly-deploy.sh            #   Fly.io deploy adapter
│   │   ├── railway-deploy.sh        #   Railway deploy adapter
│   │   └── docker-deploy.sh         #   Docker deploy adapter
│   └── ...                          # status, ps, logs, cleanup, upgrade, worktree, reaper
├── dashboard/
│   ├── server.ts                    # Bun WebSocket dashboard server
│   └── public/                      # Dashboard frontend (HTML/CSS/JS)
├── docs/
│   ├── KNOWN-ISSUES.md              # Tracked bugs with workarounds
│   └── TIPS.md                      # Power user tips & wave patterns
├── install.sh                       # Interactive installer
└── LICENSE                          # MIT
```

### Premium Dark Theme

Dark blue-gray background (`#1a1a2e`) with cyan accents (`#00d4ff`). The status bar shows your session name, current window, user/host, time, and date. Active pane borders light up in cyan. Agent names display in pane border headers so you always know which agent is in which pane.

### Claude Code Settings + Hooks

Pre-configured `settings.json.template` with:

- Agent teams enabled (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)
- Five production-ready hooks wired in:
  - **TeammateIdle** — typecheck gate (blocks idle until errors fixed)
  - **TaskCompleted** — lint + test gate (blocks completion until quality passes)
  - **Notification** — desktop alerts when agents need attention
  - **PreCompact** — saves git context before compaction
  - **PostToolUse** — auto-formats files after edits
- Haiku subagent model for cheap lookups
- Auto-compact at 70% to prevent context overflow
- Recommended plugins for development workflows

### Quality Gate Hooks

The `teammate-idle.sh` hook runs `pnpm typecheck` (or `npx tsc --noEmit`) when an agent goes idle. If there are TypeScript errors, it blocks the idle with exit code 2, telling the agent to fix them first.

### Shipwright CLI

A full-featured CLI for managing team sessions, autonomous loops, and setup. All three aliases — `shipwright`, `sw`, and `cct` — work identically:

```bash
# Setup & diagnostics
shipwright init                              # One-command tmux setup (no prompts)
shipwright init --deploy                     # Setup with deploy platform configuration
shipwright doctor                            # Validate setup, check color hooks, etc.
shipwright upgrade --apply                   # Pull latest and apply updates

# Team sessions
shipwright session my-feature                # Create a team session
shipwright session my-feature -t feature-dev # Use a template (3 agents, leader pane 65%)
sw status                                    # Show team dashboard
sw ps                                        # Show running agent processes
sw logs myteam --follow                      # Tail agent logs

# Continuous loop (autonomous agent operation)
shipwright loop "Build auth" --test-cmd "npm test"
shipwright loop "Fix bugs" --agents 3 --audit --quality-gates
shipwright loop --resume                     # Resume interrupted loop

# Delivery pipeline (idea → PR)
shipwright pipeline start --goal "Add auth" --pipeline standard
shipwright pipeline start --issue 42 --skip-gates
shipwright pipeline resume                   # Continue from last stage
sw pipeline status                           # Progress dashboard

# Autonomous daemon (watch GitHub, auto-deliver)
shipwright daemon start                      # Start issue watcher (foreground)
shipwright daemon start --detach             # Start in background tmux session
shipwright daemon metrics                    # DORA/DX metrics dashboard
shipwright daemon triage                     # Show issue triage scores
shipwright daemon patrol                     # Proactive codebase patrol
shipwright daemon stop                       # Graceful shutdown

# Fleet operations (multi-repo orchestration)
shipwright fleet init                        # Generate fleet-config.json
shipwright fleet start                       # Start daemons for all configured repos
shipwright fleet status                      # Fleet-wide dashboard
shipwright fleet metrics --period 30         # Aggregate DORA metrics across repos
shipwright fleet stop                        # Stop all fleet daemons

# Bulk fix (apply same fix across repos)
shipwright fix "Update lodash to 4.17.21" --repos ~/api,~/web,~/mobile
shipwright fix "Bump Node to 22" --repos-from repos.txt --pipeline hotfix
shipwright fix --status                      # Show running fix sessions

# Persistent memory
shipwright memory show                       # Display memory for current repo
shipwright memory show --global              # Cross-repo learnings
shipwright memory search "auth"              # Search memory
shipwright memory stats                      # Memory size, age, hit rate

# Cost intelligence
shipwright cost show                         # 7-day cost summary
shipwright cost show --period 30 --by-stage  # 30-day breakdown by stage
shipwright cost budget set 50.00             # Set daily budget ($50/day)
shipwright cost budget show                  # Check current budget

# Repo preparation
shipwright prep                              # Analyze repo, generate .claude/ configs
shipwright prep --check                      # Audit existing prep quality
sw prep --with-claude                        # Deep analysis using Claude Code

# Real-time dashboard
shipwright dashboard                         # Launch web dashboard (requires Bun)
shipwright dashboard start                   # Start dashboard in background

# Agent heartbeats
shipwright heartbeat list                    # Show agent heartbeat status

# Pipeline checkpoints
shipwright checkpoint list                   # Show saved pipeline checkpoints

# Remote machines
shipwright remote list                       # Show registered remote machines
shipwright remote add worker1 --host 10.0.0.5  # Register a remote worker machine
shipwright remote status                     # Health check all remote machines

# Maintenance
shipwright cleanup                           # Dry-run: show orphaned sessions
shipwright cleanup --force                   # Kill orphaned sessions
sw worktree create my-branch                 # Git worktree for agent isolation
sw templates list                            # Browse team templates
```

## Usage

### Starting a Team Session

```bash
# Start tmux (if not already in a session)
tmux new -s dev

# Option 1: Use a template — leader gets 65% of the screen
shipwright session my-feature --template feature-dev

# Option 2: Bare session — then ask Claude to create a team
shipwright session my-feature

# Option 3: tmux keybinding
# Press Ctrl-a then T to launch a team session

# Option 4: Just start Claude Code — it handles teams automatically
claude
```

### Continuous Agent Loop

Run Claude Code autonomously in a loop until a goal is achieved:

```bash
# Basic loop with test verification
shipwright loop "Build user authentication with JWT" --test-cmd "npm test"

# Multi-agent with audit and quality gates
shipwright loop "Refactor the API layer" --agents 3 --audit --quality-gates

# With a definition of done
shipwright loop "Build checkout flow" --definition-of-done requirements.md

# Resume an interrupted loop
shipwright loop --resume
```

The loop supports self-audit (agent reflects on its own work), audit agents (separate reviewer), and quality gates (automated checks between iterations).

### Delivery Pipeline

Chain the full SDLC into a single command — from issue intake to PR creation with full GitHub integration, self-healing builds, and zero-config auto-detection:

```bash
# Start from a GitHub issue (fully autonomous)
shipwright pipeline start --issue 123 --skip-gates

# Start from a goal
shipwright pipeline start --goal "Add JWT authentication"

# Hotfix with custom test command
shipwright pipeline start --issue 456 --pipeline hotfix --test-cmd "pytest"

# Full deployment pipeline with 3 agents
shipwright pipeline start --goal "Build payment flow" --pipeline full --agents 3

# Parallel pipeline in isolated worktree (safe to run multiple concurrently)
shipwright pipeline start --issue 42 --worktree

# Cost-aware pipeline with budget limits
shipwright pipeline start --goal "Add feature" --pipeline cost-aware

# Enterprise pipeline with all safety gates
shipwright pipeline start --issue 789 --pipeline enterprise

# Resume / monitor / abort
shipwright pipeline resume
sw pipeline status
shipwright pipeline abort

# Browse available pipelines
sw pipeline list
sw pipeline show standard
```

**Pipeline stages:** `intake → plan → design → build → test → review → compound_quality → pr → merge → deploy → validate → monitor`

Each stage can be enabled/disabled and gated (auto-proceed or pause for approval). The build stage delegates to `shipwright loop` for autonomous multi-iteration development.

**Self-healing:** When tests fail after a build, the pipeline automatically captures the error output and re-enters the build loop with that context — just like a human developer reading test failures and fixing them. Configurable retry cycles with `--self-heal N`.

**GitHub integration:** Auto-fetches issue metadata, self-assigns, posts progress comments, creates PRs with labels/milestone/reviewers propagated from the issue, and closes the issue on completion.

**Auto-detection:** Test command (9+ project types), branch prefix from task type, reviewers from CODEOWNERS or git history, project language and framework.

**Notifications:** Slack webhook (`--slack-webhook <url>`) or custom webhook (`SHIPWRIGHT_WEBHOOK_URL` env var, with `CCT_WEBHOOK_URL` fallback) for pipeline events.

| Template     | Stages                                     | Gates                             | Use Case                 |
| ------------ | ------------------------------------------ | --------------------------------- | ------------------------ |
| `standard`   | intake → plan → build → test → review → PR | approve: plan, review, pr         | Normal feature work      |
| `fast`       | intake → build → test → PR                 | all auto                          | Quick fixes              |
| `full`       | all stages                                 | approve: plan, review, pr, deploy | Production deployment    |
| `hotfix`     | intake → build → test → PR                 | all auto                          | Urgent production fixes  |
| `autonomous` | all stages                                 | all auto                          | Daemon-driven delivery   |
| `enterprise` | all stages                                 | all approve, auto-rollback        | Maximum safety pipelines |
| `cost-aware` | all stages                                 | all auto, budget checks           | Budget-limited delivery  |
| `deployed`   | all stages + deploy + validate + monitor   | approve: deploy                   | Full deploy + monitoring |

### Autonomous Daemon

Watch a GitHub repo for new issues and automatically deliver them through the pipeline:

```bash
# Start watching (foreground)
shipwright daemon start

# Start in background tmux session
shipwright daemon start --detach

# Show active pipelines, queue, and throughput
shipwright daemon status

# DORA metrics dashboard (lead time, deploy freq, MTTR, change failure rate)
shipwright daemon metrics

# Issue triage scores
shipwright daemon triage

# Proactive codebase patrol
shipwright daemon patrol
shipwright daemon patrol --dry-run

# Graceful shutdown
shipwright daemon stop
```

#### Intelligence Features

The daemon includes an intelligence layer that makes it smarter over time:

**Adaptive Templates** — Automatically selects the best pipeline template based on issue labels and past performance. Configure a `template_map` in `daemon-config.json` to map labels to templates, or let the daemon learn from history.

**Auto-Retry with Escalation** — When a pipeline fails, the daemon automatically retries with an escalation strategy (e.g., switching from `sonnet` to `opus`). Configurable via `max_retries` and `retry_escalation`.

**Self-Optimizing Metrics** — The daemon periodically analyzes its own performance and adjusts parameters (poll interval, model selection, parallel slots) to optimize throughput and cost. Enable with `"self_optimize": true`.

**Priority Lanes** — Issues labeled `hotfix`, `incident`, `p0`, or `urgent` bypass the normal queue and get processed immediately in a dedicated slot. Configurable labels and max priority slots.

**Org-Wide Mode** — Watch issues across an entire GitHub organization instead of a single repo. Set `"watch_mode": "org"` and `"org": "your-org"` in the config. Filter repos with a regex pattern.

**Proactive Patrol** — The daemon can periodically scan the codebase for issues (security vulnerabilities, outdated deps, code smells) and create issues automatically. Run `shipwright daemon patrol` for manual scans.

### Fleet Operations

Orchestrate daemons across multiple repositories from a single config:

```bash
# Generate fleet configuration
shipwright fleet init

# Start daemons for all configured repos
shipwright fleet start

# Fleet-wide dashboard
shipwright fleet status

# Aggregate DORA metrics across all repos
shipwright fleet metrics --period 30

# Stop all fleet daemons
shipwright fleet stop
```

**Fleet configuration** (`.claude/fleet-config.json`):

```json
{
  "repos": [
    { "path": "/path/to/api", "template": "autonomous", "max_parallel": 2 },
    { "path": "/path/to/web", "template": "standard" }
  ],
  "defaults": {
    "watch_label": "ready-to-build",
    "pipeline_template": "autonomous",
    "max_parallel": 2,
    "model": "opus"
  },
  "shared_events": true,
  "worker_pool": {
    "enabled": false,
    "total_workers": 12,
    "rebalance_interval_seconds": 120
  }
}
```

### Bulk Fix

Apply the same fix across multiple repositories in parallel:

```bash
# Fix a dependency across repos
shipwright fix "Update lodash to 4.17.21" --repos ~/api,~/web,~/mobile

# Security fix with fast pipeline
shipwright fix "Fix SQL injection in auth" --repos ~/api --pipeline fast

# Bulk upgrade from a repos file
shipwright fix "Bump Node to 22" --repos-from repos.txt --pipeline hotfix

# Dry run to preview
shipwright fix "Migrate to ESM" --repos ~/api,~/web --dry-run

# Check running fix sessions
shipwright fix --status
```

Options: `--max-parallel N` (default 3), `--branch-prefix` (default `fix/`), `--pipeline` (default `fast`), `--model`, `--dry-run`.

### Persistent Memory

Shipwright learns from every pipeline run and injects context into future builds:

```bash
# View repo memory (patterns, failures, decisions, metrics)
shipwright memory show

# View cross-repo learnings
shipwright memory show --global

# Search memory
shipwright memory search "auth"

# Memory statistics (size, age, hit rate)
shipwright memory stats

# Export/import memory
shipwright memory export > backup.json
shipwright memory import backup.json
```

**Pipeline integration** — Memory is captured automatically after each pipeline:

- **Patterns**: Codebase conventions, test patterns, build configs
- **Failures**: Root cause analysis of test/build failures
- **Decisions**: Design decisions and their rationale
- **Metrics**: Performance baselines (test duration, build time)

Context is injected into pipeline stages automatically, so the agent starts each build with knowledge of past mistakes and repo conventions.

### Cost Intelligence

Track token usage, enforce budgets, and optimize model selection:

```bash
# 7-day cost summary
shipwright cost show

# 30-day breakdown by pipeline stage
shipwright cost show --period 30 --by-stage

# Breakdown by issue
shipwright cost show --by-issue

# Set and check daily budget
shipwright cost budget set 50.00
shipwright cost budget show

# Estimate cost before running
shipwright cost calculate 50000 10000 opus
```

**Model pricing:**

| Model  | Input              | Output             |
| ------ | ------------------ | ------------------ |
| Opus   | $15.00 / 1M tokens | $75.00 / 1M tokens |
| Sonnet | $3.00 / 1M tokens  | $15.00 / 1M tokens |
| Haiku  | $0.25 / 1M tokens  | $1.25 / 1M tokens  |

Use the `cost-aware` pipeline template for automatic budget checking and model routing (haiku for simple stages, sonnet for builds, opus only when needed).

### Deploy Adapters

Deploy to your platform of choice with the `deployed` pipeline template:

```bash
# Setup deploy configuration
shipwright init --deploy

# Run a full deploy pipeline
shipwright pipeline start --issue 123 --pipeline deployed
```

Adapters are available for **Vercel**, **Fly.io**, **Railway**, and **Docker**. Each adapter handles staging deploys, production promotion, smoke tests, health checks, and rollback.

### Repo Preparation

Generate agent-ready `.claude/` configuration for any repository:

```bash
# Analyze repo and generate configs
shipwright prep

# Deep analysis using Claude Code
shipwright prep --with-claude

# Audit existing prep quality
shipwright prep --check
```

### Real-Time Dashboard

A web-based dashboard powered by Bun and WebSockets for live monitoring of pipelines, agents, and daemon status:

```bash
# Launch dashboard (opens browser)
shipwright dashboard

# Start in background
shipwright dashboard start

# Stop background dashboard
shipwright dashboard stop
```

### Agent Heartbeats

Monitor agent liveness with periodic heartbeat signals:

```bash
# Show heartbeat status for all active agents
shipwright heartbeat list
```

Heartbeat data is stored in `~/.claude-teams/heartbeats/<job-id>.json`. The daemon uses heartbeats to detect stale jobs and take corrective action.

### Pipeline Checkpoints

Save and restore pipeline state at any point for resilience:

```bash
# List saved checkpoints
shipwright checkpoint list

# Save current pipeline state
shipwright checkpoint save

# Restore from a checkpoint
shipwright checkpoint restore <id>
```

Checkpoints are stored in `.claude/pipeline-artifacts/checkpoints/`.

### Remote Machines

Distribute pipeline work across multiple machines:

```bash
# List registered machines
shipwright remote list

# Register a new worker machine
shipwright remote add worker1 --host 10.0.0.5

# Health check all registered machines
shipwright remote status
```

Machine registry is stored in `~/.claude-teams/machines.json`.

### Layout Presets

Switch between pane arrangements with keybindings:

| Key            | Layout          | Description                           |
| -------------- | --------------- | ------------------------------------- |
| `prefix + M-1` | main-horizontal | Leader 65% left, agents stacked right |
| `prefix + M-2` | main-vertical   | Leader 60% top, agents tiled bottom   |
| `prefix + M-3` | tiled           | Equal sizes                           |

### Monitoring Teams

```bash
# Show running team sessions
shipwright status

# Or use the tmux keybinding: Ctrl-a then Ctrl-t
```

### Health Check

```bash
shipwright doctor    # Checks: tmux, jq, overlay hooks, color config, orphaned sessions
```

## Configuration

### tmux Theme

The theme lives in `tmux/tmux.conf`. Key color values:

| Element                             | Color          | Hex       |
| ----------------------------------- | -------------- | --------- |
| Background                          | Dark blue-gray | `#1a1a2e` |
| Foreground                          | Light gray     | `#e4e4e7` |
| Accent (active borders, highlights) | Cyan           | `#00d4ff` |
| Secondary                           | Blue           | `#0066ff` |
| Tertiary                            | Purple         | `#7c3aed` |
| Inactive borders                    | Muted indigo   | `#333355` |
| Inactive elements                   | Zinc           | `#71717a` |

To customize, edit the hex values in `tmux/tmux.conf` and reload: `prefix + r`.

### Claude Code Settings

The `claude-code/settings.json.template` is a JSONC file (JSON with comments). To use it:

1. Copy to `~/.claude/settings.json` (strip comments first if your editor doesn't support JSONC)
2. Customize the `enabledPlugins` section for your toolchain
3. Adjust `env` variables as needed

Key settings to customize:

| Setting                                | Default   | What it does                                      |
| -------------------------------------- | --------- | ------------------------------------------------- |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `"1"`     | Enable agent teams (required)                     |
| `CLAUDE_CODE_AUTOCOMPACT_PCT_OVERRIDE` | `"70"`    | When to compact context (lower = more aggressive) |
| `CLAUDE_CODE_SUBAGENT_MODEL`           | `"haiku"` | Model for subagent lookups (cheaper + faster)     |
| `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY` | `"5"`     | Parallel tool calls per agent                     |

### Hooks

Hooks are shell scripts that run on Claude Code lifecycle events. The included `teammate-idle.sh` hook is a quality gate that blocks agents from going idle until TypeScript errors are fixed.

To install hooks:

1. Copy hook scripts to `~/.claude/hooks/`
2. Make them executable: `chmod +x ~/.claude/hooks/*.sh`
3. Wire them up in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "teammate-idle": {
      "command": "~/.claude/hooks/teammate-idle.sh",
      "timeout": 30000
    }
  }
}
```

### Shell Completions

Tab completions are available for bash, zsh, and fish:

```bash
# Auto-install for your current shell
./scripts/install-completions.sh

# Or manually source (bash)
source completions/shipwright.bash

# Or manually install (zsh — add to ~/.zfunc/)
cp completions/_shipwright ~/.zfunc/_shipwright && compinit

# Or manually install (fish)
cp completions/shipwright.fish ~/.config/fish/completions/
```

### Daemon Configuration

The daemon is configured via `.claude/daemon-config.json`:

```json
{
  "watch_label": "ready-to-build",
  "poll_interval": 60,
  "max_parallel": 2,
  "pipeline_template": "autonomous",
  "base_branch": "main",
  "priority_lane": true,
  "priority_lane_labels": "hotfix,incident,p0,urgent",
  "priority_lane_max": 1,
  "auto_template": true,
  "max_retries": 2,
  "retry_escalation": true,
  "self_optimize": false,
  "auto_scale": false,
  "auto_scale_interval": 5,
  "max_workers": 8,
  "min_workers": 1,
  "worker_mem_gb": 4,
  "estimated_cost_per_job_usd": 5.0,
  "watch_mode": "repo",
  "org": ""
}
```

## tmux Keybindings

The prefix key is `Ctrl-a` (remapped from the default `Ctrl-b`).

### General

| Key           | Action                          |
| ------------- | ------------------------------- |
| `prefix + r`  | Reload tmux config              |
| `prefix + \|` | Split pane vertically           |
| `prefix + -`  | Split pane horizontally         |
| `prefix + c`  | New window                      |
| `prefix + x`  | Kill pane (with confirmation)   |
| `prefix + X`  | Kill window (with confirmation) |
| `prefix + s`  | Choose session (tree view)      |
| `prefix + N`  | New session                     |

### Pane Navigation (vim-style)

| Key                | Action                                               |
| ------------------ | ---------------------------------------------------- |
| `prefix + h`       | Move left                                            |
| `prefix + j`       | Move down                                            |
| `prefix + k`       | Move up                                              |
| `prefix + l`       | Move right                                           |
| `Ctrl + h/j/k/l`   | Smart pane switching (works with vim-tmux-navigator) |
| `prefix + H/J/K/L` | Resize pane (repeatable)                             |

### Window Navigation

| Key               | Action          |
| ----------------- | --------------- |
| `prefix + Ctrl-h` | Previous window |
| `prefix + Ctrl-l` | Next window     |

### Agent Teams

| Key               | Action                                          |
| ----------------- | ----------------------------------------------- |
| `prefix + T`      | Launch team session (via `shipwright`)          |
| `prefix + Ctrl-t` | Show team status dashboard                      |
| `prefix + g`      | Display pane numbers (pick by index)            |
| `prefix + G`      | Toggle zoom on current pane                     |
| `prefix + S`      | Toggle synchronized panes (type in all at once) |
| `prefix + M-t`    | Toggle team sync mode                           |
| `prefix + M-l`    | Cycle through pane layouts                      |
| `prefix + M-1`    | Layout: main-horizontal (leader 65% left)       |
| `prefix + M-2`    | Layout: main-vertical (leader 60% top)          |
| `prefix + M-3`    | Layout: tiled (equal sizes)                     |
| `prefix + M-s`    | Capture current pane scrollback to file         |
| `prefix + M-a`    | Capture ALL panes in window                     |

### Copy Mode (vi-style)

| Key          | Action                |
| ------------ | --------------------- |
| `v`          | Begin selection       |
| `y`          | Copy selection        |
| `r`          | Toggle rectangle mode |
| `prefix + p` | Paste buffer          |

## Team Patterns

24 templates covering the full SDLC and PDLC. Use `shipwright templates list` to browse, `shipwright templates show <name>` for details.

### Build Phase

#### Feature Development (`feature-dev`) — 3 agents

| Agent        | Focus                            | Example files               |
| ------------ | -------------------------------- | --------------------------- |
| **backend**  | API routes, services, data layer | `src/api/`, `src/services/` |
| **frontend** | UI components, state, styling    | `apps/web/src/`             |
| **tests**    | Unit tests, integration tests    | `*.test.ts`                 |

#### Full-Stack (`full-stack`) — 3 agents

| Agent        | Focus                                    | Example files                  |
| ------------ | ---------------------------------------- | ------------------------------ |
| **api**      | REST/GraphQL endpoints, middleware, auth | `src/api/`, `src/routes/`      |
| **database** | Schema, migrations, queries, models      | `migrations/`, `prisma/`       |
| **ui**       | Pages, components, forms, styling        | `apps/web/`, `src/components/` |

### Quality Phase

#### Code Review (`code-review`) — 3 agents

| Agent             | Focus                           | What it checks                      |
| ----------------- | ------------------------------- | ----------------------------------- |
| **code-quality**  | Logic, patterns, architecture   | Bugs, code smells, layer violations |
| **security**      | Error handling, injection, auth | OWASP top 10, silent failures       |
| **test-coverage** | Test completeness, edge cases   | Missing tests, weak assertions      |

#### Security Audit (`security-audit`) — 3 agents

| Agent             | Focus                             | What it checks              |
| ----------------- | --------------------------------- | --------------------------- |
| **code-analysis** | SAST: injection, auth, XSS, CSRF  | Source code vulnerabilities |
| **dependencies**  | CVEs, outdated packages, licenses | Supply chain risks          |
| **config-review** | Secrets, CORS, CSP, env config    | Infrastructure security     |

#### Comprehensive Testing (`testing`) — 3 agents

| Agent                 | Focus                               | What it covers        |
| --------------------- | ----------------------------------- | --------------------- |
| **unit-tests**        | Functions, classes, modules         | Isolated unit tests   |
| **integration-tests** | API endpoints, service interactions | Cross-component tests |
| **e2e-tests**         | User flows, UI interactions         | Full system tests     |

### Maintenance Phase

#### Bug Fix (`bug-fix`) — 3 agents

| Agent          | Focus                                | What it does                |
| -------------- | ------------------------------------ | --------------------------- |
| **reproducer** | Write failing test, trace root cause | Proves the bug exists       |
| **fixer**      | Fix source code, handle edge cases   | Implements the fix          |
| **verifier**   | Regression check, review changes     | Ensures nothing else breaks |

#### Refactoring (`refactor`) — 2 agents

| Agent         | Focus                | What it does                      |
| ------------- | -------------------- | --------------------------------- |
| **refactor**  | Source code changes  | Rename, restructure, extract      |
| **consumers** | Tests and dependents | Update imports, fix tests, verify |

#### Migration (`migration`) — 3 agents

| Agent        | Focus                              | What it does         |
| ------------ | ---------------------------------- | -------------------- |
| **schema**   | Migration scripts, data transforms | Write the migration  |
| **adapter**  | Update app code, queries, models   | Adapt to new schema  |
| **rollback** | Rollback scripts, backward compat  | Verify safe reversal |

### Planning Phase

#### Architecture (`architecture`) — 2 agents

| Agent           | Focus                                         | What it does           |
| --------------- | --------------------------------------------- | ---------------------- |
| **researcher**  | Analyze code, trace deps, evaluate trade-offs | Deep codebase analysis |
| **spec-writer** | ADRs, design docs, interface contracts        | Write technical specs  |

#### Exploration (`exploration`) — 2 agents

| Agent           | Focus                                 | What it does     |
| --------------- | ------------------------------------- | ---------------- |
| **explorer**    | Deep-dive code, trace execution paths | Map the codebase |
| **synthesizer** | Summarize findings, document patterns | Distill insights |

### Operations Phase

#### DevOps (`devops`) — 2 agents

| Agent              | Focus                              | What it does                  |
| ------------------ | ---------------------------------- | ----------------------------- |
| **pipeline**       | CI/CD workflows, build, deploy     | GitHub Actions, Jenkins, etc. |
| **infrastructure** | Docker, Terraform, K8s, env config | Infrastructure as code        |

#### Documentation (`documentation`) — 2 agents

| Agent        | Focus                                 | What it does           |
| ------------ | ------------------------------------- | ---------------------- |
| **api-docs** | API reference, OpenAPI spec, examples | Endpoint documentation |
| **guides**   | Tutorials, README, architecture docs  | User-facing docs       |

## Troubleshooting

See [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md) for tracked bugs with workarounds.

**Common problems:**

| Problem                                       | Cause                                    | Fix                                                                |
| --------------------------------------------- | ---------------------------------------- | ------------------------------------------------------------------ |
| Agents spawn in-process instead of tmux panes | Not inside a tmux session                | Start tmux first: `tmux new -s dev`                                |
| Garbled pane output with 4+ agents            | tmux `send-keys` race condition (#23615) | Use `shipwright` (uses `new-window` instead of `split-window`)     |
| Agents fall back to in-process mode           | Not in a real tmux session (#23572)      | Launch Claude inside tmux                                          |
| Context window overflow                       | Too many tasks per agent                 | Keep tasks focused (5-6 per agent)                                 |
| Panes don't show agent names                  | Pane titles not set                      | Use `shipwright session` which sets titles automatically           |
| White/bright pane backgrounds                 | New panes not inheriting theme           | Fixed! Overlay forces dark theme via `set-hook after-split-window` |

## Plugins (TPM)

The tmux config uses [TPM](https://github.com/tmux-plugins/tpm) for plugin management. Install after setup: `prefix + I` (capital I).

### tmux Plugins (Best-in-Class)

| Plugin             | Key            | What it does                                                                   |
| ------------------ | -------------- | ------------------------------------------------------------------------------ |
| **tmux-fingers**   | `prefix + F`   | Vimium-style copy hints — highlight and copy URLs, paths, hashes from any pane |
| **tmux-fzf-url**   | `prefix + u`   | Fuzzy-find and open any URL visible in the current pane                        |
| **tmux-fzf**       | `F5`           | Fuzzy finder for sessions, windows, and panes — jump to any agent by name      |
| **extrakto**       | `prefix + tab` | Extract and copy any text from pane output (paths, IDs, errors)                |
| **tmux-resurrect** | auto           | Save and restore sessions across restarts                                      |
| **tmux-continuum** | auto           | Automatic continuous session saving                                            |
| **tmux-sensible**  | —              | Sensible defaults everyone agrees on                                           |

## Demo

The hero GIF above shows the CLI in action. The team demo below shows the multi-pane tmux experience with leader + agent panes working in parallel:

<p align="center">
  <img src="https://vhs.charm.sh/vhs-77zWXLOKGKC6q29htCKc8M.gif" alt="Team demo — multi-pane tmux with leader + backend + test agents" width="900" />
</p>

<details>
<summary>Full CLI walkthrough (click to expand)</summary>

<p align="center">
  <img src="https://vhs.charm.sh/vhs-ZxrZmi6533fCAnpRl5oG5.gif" alt="Full demo — setup, doctor, templates, pipeline, fleet, cost" width="900" />
</p>

</details>

Re-record the demos yourself:

```bash
vhs demo/hero.tape        # Short hero GIF
vhs demo/team-demo.tape   # Multi-pane team experience
vhs demo/full-demo.tape   # Full CLI walkthrough
```

## Sources & Inspiration

- [Awesome tmux](https://github.com/rothgar/awesome-tmux) — Curated list of tmux resources
- [Claude Code Agent Teams](https://addyosmani.com/blog/claude-code-agent-teams/) — Addy Osmani's guide to team patterns
- [Claude Code Hooks Guide](https://code.claude.com/docs/en/hooks-guide) — Official hooks documentation
- [Everything Claude Code](https://github.com/affaan-m/everything-claude-code) — Comprehensive config collection
- [Claude Code Hooks Mastery](https://github.com/disler/claude-code-hooks-mastery) — Hook patterns and examples
- [tmux issue #23615](https://github.com/anthropics/claude-code/issues/23615) — Agent pane spawning discussion

## License

[MIT](LICENSE) — Seth Ford, 2026.
