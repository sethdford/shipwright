# Claude Code Teams + tmux

> Production-ready tmux setup for running Claude Code Agent Teams — multi-agent AI development with visual split-pane sessions, quality gates, and autonomous loops.

[![v1.3.0](https://img.shields.io/badge/version-1.3.0-00d4ff?style=flat-square)](https://github.com/sethdford/claude-code-teams-tmux/releases) ![tmux dark theme with cyan accents](https://img.shields.io/badge/theme-dark%20blue--gray%20%2B%20cyan-00d4ff?style=flat-square) ![MIT License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

<p align="center">
  <img src="https://vhs.charm.sh/vhs-3MRxhgRAOQQyRtj3kal6uF.gif" alt="cct CLI demo — version, help, templates, doctor" width="800" />
</p>

## What's This?

Claude Code's **agent teams** feature lets you spawn multiple AI agents that work in parallel on different parts of a task — one on backend, one on frontend, one writing tests, etc. When you run Claude Code inside tmux, each agent gets its own pane so you can watch them all work simultaneously.

This repo packages a complete setup:

- **Premium dark tmux theme** with agent-aware pane borders
- **`cct` CLI** for managing team sessions, templates, and autonomous loops
- **Quality gate hooks** that block agents until code passes checks
- **Continuous agent loop** (`cct loop`) for autonomous multi-iteration development
- **Layout presets** that give the leader pane 60-65% of screen space
- **One-command setup** via `cct init`

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
git clone https://github.com/sethdford/claude-code-teams-tmux.git
cd claude-code-teams-tmux
./scripts/cct-init.sh
```

**Option B: Full interactive install (tmux + settings + hooks + CLI)**

```bash
git clone https://github.com/sethdford/claude-code-teams-tmux.git
cd claude-code-teams-tmux
./install.sh
```

Then start a tmux session and launch Claude Code:

```bash
tmux new -s dev
claude
```

## What's Included

```
claude-code-teams-tmux/
├── tmux/
│   ├── tmux.conf                    # Full tmux config with premium dark theme
│   ├── claude-teams-overlay.conf    # Agent-aware pane styling, color hooks & keybindings
│   └── templates/                   # Team composition templates
│       ├── feature-dev.json         #   Backend + frontend + tests (3 agents)
│       ├── code-review.json         #   Quality + security + coverage (3 agents)
│       ├── refactor.json            #   Refactor + consumers (2 agents)
│       └── exploration.json         #   Explorer + synthesizer (2 agents)
├── claude-code/
│   ├── settings.json.template       # Claude Code settings with teams + hooks
│   └── hooks/
│       ├── teammate-idle.sh         # Quality gate: typecheck before idle
│       ├── task-completed.sh        # Quality gate: lint+test before done
│       ├── notify-idle.sh           # Desktop notification on idle
│       └── pre-compact-save.sh      # Save context before compaction
├── scripts/
│   ├── cct                          # CLI router (session, loop, doctor, init, ...)
│   ├── cct-init.sh                  # One-command tmux setup (no prompts)
│   ├── cct-session.sh               # Create team sessions from templates
│   ├── cct-loop.sh                  # Continuous autonomous agent loop
│   ├── cct-doctor.sh                # Validate setup and diagnose issues
│   └── ...                          # status, ps, logs, cleanup, upgrade, worktree
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

### `cct` CLI

A full-featured CLI for managing team sessions, autonomous loops, and setup:

```bash
# Setup & diagnostics
cct init                              # One-command tmux setup (no prompts)
cct doctor                            # Validate setup, check color hooks, etc.
cct upgrade --apply                   # Pull latest and apply updates

# Team sessions
cct session my-feature                # Create a team session
cct session my-feature -t feature-dev # Use a template (3 agents, leader pane 65%)
cct status                            # Show team dashboard
cct ps                                # Show running agent processes
cct logs myteam --follow              # Tail agent logs

# Continuous loop (autonomous agent operation)
cct loop "Build auth" --test-cmd "npm test"
cct loop "Fix bugs" --agents 3 --audit --quality-gates
cct loop --resume                     # Resume interrupted loop

# Maintenance
cct cleanup                           # Dry-run: show orphaned sessions
cct cleanup --force                   # Kill orphaned sessions
cct worktree create my-branch         # Git worktree for agent isolation
cct templates list                    # Browse team templates
```

## Usage

### Starting a Team Session

```bash
# Start tmux (if not already in a session)
tmux new -s dev

# Option 1: Use a template — leader gets 65% of the screen
cct session my-feature --template feature-dev

# Option 2: Bare session — then ask Claude to create a team
cct session my-feature

# Option 3: tmux keybinding
# Press Ctrl-a then T to launch a team session

# Option 4: Just start Claude Code — it handles teams automatically
claude
```

### Continuous Agent Loop

Run Claude Code autonomously in a loop until a goal is achieved:

```bash
# Basic loop with test verification
cct loop "Build user authentication with JWT" --test-cmd "npm test"

# Multi-agent with audit and quality gates
cct loop "Refactor the API layer" --agents 3 --audit --quality-gates

# With a definition of done
cct loop "Build checkout flow" --definition-of-done requirements.md

# Resume an interrupted loop
cct loop --resume
```

The loop supports self-audit (agent reflects on its own work), audit agents (separate reviewer), and quality gates (automated checks between iterations).

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
cct status

# Or use the tmux keybinding: Ctrl-a then Ctrl-t
```

### Health Check

```bash
cct doctor    # Checks: tmux, jq, overlay hooks, color config, orphaned sessions
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
| `prefix + T` | Launch team session (via `cct`) |
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

### Feature Development (2-3 agents)

Assign each agent to a different layer to avoid file conflicts:

| Agent | Focus | Example files |
|-------|-------|---------------|
| **backend** | API routes, services, data layer | `src/api/`, `src/services/` |
| **frontend** | UI components, state, styling | `apps/web/src/` |
| **tests** | Unit tests, integration tests | `src/tests/`, `*.test.ts` |

### Code Review (2-3 agents)

Run parallel review passes for thorough coverage:

| Agent | Focus | What it checks |
|-------|-------|----------------|
| **code-quality** | Logic, patterns, architecture | Bugs, code smells, layer violations |
| **security** | Error handling, injection, auth | OWASP top 10, silent failures |
| **test-coverage** | Test completeness, edge cases | Missing tests, weak assertions |

### Refactoring (2 agents)

Split the work so one agent never touches the other's files:

| Agent | Focus | What it does |
|-------|-------|--------------|
| **refactor** | Source code changes | Rename, restructure, extract |
| **consumers** | Tests and dependents | Update imports, fix tests, verify |

## Troubleshooting

See [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md) for tracked bugs with workarounds.

**Common problems:**

| Problem | Cause | Fix |
|---------|-------|-----|
| Agents spawn in-process instead of tmux panes | Not inside a tmux session | Start tmux first: `tmux new -s dev` |
| Garbled pane output with 4+ agents | tmux `send-keys` race condition (#23615) | Use `cct` (uses `new-window` instead of `split-window`) |
| Agents fall back to in-process mode | Not in a real tmux session (#23572) | Launch Claude inside tmux |
| Context window overflow | Too many tasks per agent | Keep tasks focused (5-6 per agent) |
| Panes don't show agent names | Pane titles not set | Use `cct session` which sets titles automatically |
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
  <img src="https://vhs.charm.sh/vhs-6UFJGCYhZN0zMSg2CTsnys.gif" alt="Full demo — setup, doctor, templates, loop, layouts" width="900" />
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
