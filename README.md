# Shipwright

> Orchestrate autonomous Claude Code agent teams — delivery pipeline, DORA metrics, and repo preparation.

[![v1.6.0](https://img.shields.io/badge/version-1.6.0-00d4ff?style=flat-square)](https://github.com/sethdford/shipwright/releases) ![tmux dark theme with cyan accents](https://img.shields.io/badge/theme-dark%20blue--gray%20%2B%20cyan-00d4ff?style=flat-square) ![MIT License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

<p align="center">
  <img src="https://vhs.charm.sh/vhs-sJ34YHLfLxXLMpJgjqvy2.gif" alt="Shipwright CLI demo — version, help, 12 templates, doctor" width="800" />
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
- **DORA metrics** (`shipwright daemon metrics`) for engineering performance tracking
- **Repo preparation** (`shipwright prep`) for generating agent-ready `.claude/` configs
- **Layout presets** that give the leader pane 60-65% of screen space
- **One-command setup** via `shipwright init`

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| **tmux** | 3.2+ (tested on 3.6a) | `brew install tmux` on macOS |
| **jq** | any | `brew install jq` — JSON parsing for templates |
| **Claude Code CLI** | latest | `npm install -g @anthropic-ai/claude-code` |
| **Node.js** | 20+ | For hooks |
| **Git** | any | For installation |
| **Terminal** | iTerm2, Alacritty, Kitty, WezTerm | See note below |

> **Terminal compatibility:** Split-pane agent teams only work in real terminal emulators. **VS Code's integrated terminal and Ghostty are not supported** — they lack the tmux integration needed for agent pane spawning. See [Known Issues](docs/KNOWN-ISSUES.md) for details.

## Quick Start

**Option A: One-command setup (just tmux config, no prompts)**

```bash
git clone https://github.com/sethdford/shipwright.git
cd shipwright
./scripts/cct-init.sh
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
│   └── templates/                   # 12 team composition templates (full SDLC)
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
│       └── exploration.json         #   Explorer + synthesizer (2 agents)
├── templates/
│   └── pipelines/                   # 5 delivery pipeline templates
│       ├── standard.json            #   Feature pipeline (plan + review gates)
│       ├── fast.json                #   Quick fixes (all auto, no gates)
│       ├── full.json                #   Full deployment (all 8 stages)
│       ├── hotfix.json              #   Urgent fixes (all auto, minimal)
│       └── autonomous.json          #   Daemon-driven (fully autonomous)
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
│   ├── cct-prep.sh                  # Repo preparation tool
│   ├── cct-doctor.sh                # Validate setup and diagnose issues
│   ├── install-completions.sh       # Shell completion installer
│   └── ...                          # status, ps, logs, cleanup, upgrade, worktree, reaper
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
shipwright daemon stop                       # Graceful shutdown

# Repo preparation
shipwright prep                              # Analyze repo, generate .claude/ configs
shipwright prep --check                      # Audit existing prep quality
sw prep --with-claude                        # Deep analysis using Claude Code

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

# Resume / monitor / abort
shipwright pipeline resume
sw pipeline status
shipwright pipeline abort

# Browse available pipelines
sw pipeline list
sw pipeline show standard
```

**Pipeline stages:** `intake → plan → build → test → review → pr → deploy → validate`

Each stage can be enabled/disabled and gated (auto-proceed or pause for approval). The build stage delegates to `shipwright loop` for autonomous multi-iteration development.

**Self-healing:** When tests fail after a build, the pipeline automatically captures the error output and re-enters the build loop with that context — just like a human developer reading test failures and fixing them. Configurable retry cycles with `--self-heal N`.

**GitHub integration:** Auto-fetches issue metadata, self-assigns, posts progress comments, creates PRs with labels/milestone/reviewers propagated from the issue, and closes the issue on completion.

**Auto-detection:** Test command (9+ project types), branch prefix from task type, reviewers from CODEOWNERS or git history, project language and framework.

**Notifications:** Slack webhook (`--slack-webhook <url>`) or custom webhook (`CCT_WEBHOOK_URL` env var) for pipeline events.

| Template | Stages | Gates | Use Case |
|----------|--------|-------|----------|
| `standard` | intake → plan → build → test → review → PR | approve: plan, review, pr | Normal feature work |
| `fast` | intake → build → test → PR | all auto | Quick fixes |
| `full` | all 8 stages | approve: plan, review, pr, deploy | Production deployment |
| `hotfix` | intake → build → test → PR | all auto | Urgent production fixes |
| `autonomous` | all stages | all auto | Daemon-driven delivery |

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

# Graceful shutdown
shipwright daemon stop
```

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

### Layout Presets

Switch between pane arrangements with keybindings:

| Key | Layout | Description |
|-----|--------|-------------|
| `prefix + M-1` | main-horizontal | Leader 65% left, agents stacked right |
| `prefix + M-2` | main-vertical | Leader 60% top, agents tiled bottom |
| `prefix + M-3` | tiled | Equal sizes |

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

| Element | Color | Hex |
|---------|-------|-----|
| Background | Dark blue-gray | `#1a1a2e` |
| Foreground | Light gray | `#e4e4e7` |
| Accent (active borders, highlights) | Cyan | `#00d4ff` |
| Secondary | Blue | `#0066ff` |
| Tertiary | Purple | `#7c3aed` |
| Inactive borders | Muted indigo | `#333355` |
| Inactive elements | Zinc | `#71717a` |

To customize, edit the hex values in `tmux/tmux.conf` and reload: `prefix + r`.

### Claude Code Settings

The `claude-code/settings.json.template` is a JSONC file (JSON with comments). To use it:

1. Copy to `~/.claude/settings.json` (strip comments first if your editor doesn't support JSONC)
2. Customize the `enabledPlugins` section for your toolchain
3. Adjust `env` variables as needed

Key settings to customize:

| Setting | Default | What it does |
|---------|---------|--------------|
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `"1"` | Enable agent teams (required) |
| `CLAUDE_CODE_AUTOCOMPACT_PCT_OVERRIDE` | `"70"` | When to compact context (lower = more aggressive) |
| `CLAUDE_CODE_SUBAGENT_MODEL` | `"haiku"` | Model for subagent lookups (cheaper + faster) |
| `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY` | `"5"` | Parallel tool calls per agent |

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

## tmux Keybindings

The prefix key is `Ctrl-a` (remapped from the default `Ctrl-b`).

### General

| Key | Action |
|-----|--------|
| `prefix + r` | Reload tmux config |
| `prefix + \|` | Split pane vertically |
| `prefix + -` | Split pane horizontally |
| `prefix + c` | New window |
| `prefix + x` | Kill pane (with confirmation) |
| `prefix + X` | Kill window (with confirmation) |
| `prefix + s` | Choose session (tree view) |
| `prefix + N` | New session |

### Pane Navigation (vim-style)

| Key | Action |
|-----|--------|
| `prefix + h` | Move left |
| `prefix + j` | Move down |
| `prefix + k` | Move up |
| `prefix + l` | Move right |
| `Ctrl + h/j/k/l` | Smart pane switching (works with vim-tmux-navigator) |
| `prefix + H/J/K/L` | Resize pane (repeatable) |

### Window Navigation

| Key | Action |
|-----|--------|
| `prefix + Ctrl-h` | Previous window |
| `prefix + Ctrl-l` | Next window |

### Agent Teams

| Key | Action |
|-----|--------|
| `prefix + T` | Launch team session (via `shipwright`) |
| `prefix + Ctrl-t` | Show team status dashboard |
| `prefix + g` | Display pane numbers (pick by index) |
| `prefix + G` | Toggle zoom on current pane |
| `prefix + S` | Toggle synchronized panes (type in all at once) |
| `prefix + M-t` | Toggle team sync mode |
| `prefix + M-l` | Cycle through pane layouts |
| `prefix + M-1` | Layout: main-horizontal (leader 65% left) |
| `prefix + M-2` | Layout: main-vertical (leader 60% top) |
| `prefix + M-3` | Layout: tiled (equal sizes) |
| `prefix + M-s` | Capture current pane scrollback to file |
| `prefix + M-a` | Capture ALL panes in window |

### Copy Mode (vi-style)

| Key | Action |
|-----|--------|
| `v` | Begin selection |
| `y` | Copy selection |
| `r` | Toggle rectangle mode |
| `prefix + p` | Paste buffer |

## Team Patterns

12 templates covering the full SDLC and PDLC. Use `shipwright templates list` to browse, `shipwright templates show <name>` for details.

### Build Phase

#### Feature Development (`feature-dev`) — 3 agents

| Agent | Focus | Example files |
|-------|-------|---------------|
| **backend** | API routes, services, data layer | `src/api/`, `src/services/` |
| **frontend** | UI components, state, styling | `apps/web/src/` |
| **tests** | Unit tests, integration tests | `*.test.ts` |

#### Full-Stack (`full-stack`) — 3 agents

| Agent | Focus | Example files |
|-------|-------|---------------|
| **api** | REST/GraphQL endpoints, middleware, auth | `src/api/`, `src/routes/` |
| **database** | Schema, migrations, queries, models | `migrations/`, `prisma/` |
| **ui** | Pages, components, forms, styling | `apps/web/`, `src/components/` |

### Quality Phase

#### Code Review (`code-review`) — 3 agents

| Agent | Focus | What it checks |
|-------|-------|----------------|
| **code-quality** | Logic, patterns, architecture | Bugs, code smells, layer violations |
| **security** | Error handling, injection, auth | OWASP top 10, silent failures |
| **test-coverage** | Test completeness, edge cases | Missing tests, weak assertions |

#### Security Audit (`security-audit`) — 3 agents

| Agent | Focus | What it checks |
|-------|-------|----------------|
| **code-analysis** | SAST: injection, auth, XSS, CSRF | Source code vulnerabilities |
| **dependencies** | CVEs, outdated packages, licenses | Supply chain risks |
| **config-review** | Secrets, CORS, CSP, env config | Infrastructure security |

#### Comprehensive Testing (`testing`) — 3 agents

| Agent | Focus | What it covers |
|-------|-------|----------------|
| **unit-tests** | Functions, classes, modules | Isolated unit tests |
| **integration-tests** | API endpoints, service interactions | Cross-component tests |
| **e2e-tests** | User flows, UI interactions | Full system tests |

### Maintenance Phase

#### Bug Fix (`bug-fix`) — 3 agents

| Agent | Focus | What it does |
|-------|-------|--------------|
| **reproducer** | Write failing test, trace root cause | Proves the bug exists |
| **fixer** | Fix source code, handle edge cases | Implements the fix |
| **verifier** | Regression check, review changes | Ensures nothing else breaks |

#### Refactoring (`refactor`) — 2 agents

| Agent | Focus | What it does |
|-------|-------|--------------|
| **refactor** | Source code changes | Rename, restructure, extract |
| **consumers** | Tests and dependents | Update imports, fix tests, verify |

#### Migration (`migration`) — 3 agents

| Agent | Focus | What it does |
|-------|-------|--------------|
| **schema** | Migration scripts, data transforms | Write the migration |
| **adapter** | Update app code, queries, models | Adapt to new schema |
| **rollback** | Rollback scripts, backward compat | Verify safe reversal |

### Planning Phase

#### Architecture (`architecture`) — 2 agents

| Agent | Focus | What it does |
|-------|-------|--------------|
| **researcher** | Analyze code, trace deps, evaluate trade-offs | Deep codebase analysis |
| **spec-writer** | ADRs, design docs, interface contracts | Write technical specs |

#### Exploration (`exploration`) — 2 agents

| Agent | Focus | What it does |
|-------|-------|--------------|
| **explorer** | Deep-dive code, trace execution paths | Map the codebase |
| **synthesizer** | Summarize findings, document patterns | Distill insights |

### Operations Phase

#### DevOps (`devops`) — 2 agents

| Agent | Focus | What it does |
|-------|-------|--------------|
| **pipeline** | CI/CD workflows, build, deploy | GitHub Actions, Jenkins, etc. |
| **infrastructure** | Docker, Terraform, K8s, env config | Infrastructure as code |

#### Documentation (`documentation`) — 2 agents

| Agent | Focus | What it does |
|-------|-------|--------------|
| **api-docs** | API reference, OpenAPI spec, examples | Endpoint documentation |
| **guides** | Tutorials, README, architecture docs | User-facing docs |

## Troubleshooting

See [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md) for tracked bugs with workarounds.

**Common problems:**

| Problem | Cause | Fix |
|---------|-------|-----|
| Agents spawn in-process instead of tmux panes | Not inside a tmux session | Start tmux first: `tmux new -s dev` |
| Garbled pane output with 4+ agents | tmux `send-keys` race condition (#23615) | Use `shipwright` (uses `new-window` instead of `split-window`) |
| Agents fall back to in-process mode | Not in a real tmux session (#23572) | Launch Claude inside tmux |
| Context window overflow | Too many tasks per agent | Keep tasks focused (5-6 per agent) |
| Panes don't show agent names | Pane titles not set | Use `shipwright session` which sets titles automatically |
| White/bright pane backgrounds | New panes not inheriting theme | Fixed! Overlay forces dark theme via `set-hook after-split-window` |

## Plugins (TPM)

The tmux config uses [TPM](https://github.com/tmux-plugins/tpm) for plugin management. Install after setup: `prefix + I` (capital I).

### tmux Plugins (Best-in-Class)

| Plugin | Key | What it does |
|--------|-----|--------------|
| **tmux-fingers** | `prefix + F` | Vimium-style copy hints — highlight and copy URLs, paths, hashes from any pane |
| **tmux-fzf-url** | `prefix + u` | Fuzzy-find and open any URL visible in the current pane |
| **tmux-fzf** | `F5` | Fuzzy finder for sessions, windows, and panes — jump to any agent by name |
| **extrakto** | `prefix + tab` | Extract and copy any text from pane output (paths, IDs, errors) |
| **tmux-resurrect** | auto | Save and restore sessions across restarts |
| **tmux-continuum** | auto | Automatic continuous session saving |
| **tmux-sensible** | — | Sensible defaults everyone agrees on |

## Demo

The hero GIF above shows the CLI in action. For the full walkthrough (setup, templates, loop, layouts):

<details>
<summary>Full demo (click to expand)</summary>

<p align="center">
  <img src="https://vhs.charm.sh/vhs-3w7KifJzCC9zLxzCfzdsp3.gif" alt="Full demo — setup, doctor, 12 templates, loop, layouts" width="900" />
</p>

</details>

Re-record the demos yourself:

```bash
vhs demo/hero.tape       # Short hero GIF
vhs demo/full-demo.tape  # Full walkthrough
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
