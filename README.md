# Claude Code Teams + tmux

> Run Claude Code Agent Teams with split-pane tmux sessions for visual multi-agent development.

## What's This?

Claude Code's **agent teams** feature lets you spawn multiple AI agents that work in parallel on different parts of a task — one on backend, one on frontend, one writing tests, etc. When you run Claude Code inside tmux, each agent gets its own pane so you can watch them all work simultaneously.

This repo packages a complete setup: a premium dark tmux theme, Claude Code settings tuned for teams, quality gate hooks, and a `cct` CLI for managing team sessions.

![tmux dark theme with cyan accents](https://img.shields.io/badge/theme-dark%20blue--gray%20%2B%20cyan-00d4ff?style=flat-square) ![MIT License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| **tmux** | 3.2+ (tested on 3.6a) | `brew install tmux` on macOS |
| **Claude Code CLI** | latest | `npm install -g @anthropic-ai/claude-code` |
| **Node.js** | 20+ | For hooks |
| **Git** | any | For installation |
| **Terminal** | iTerm2, Alacritty, Kitty, WezTerm | See note below |

> **Terminal compatibility:** Split-pane agent teams only work in real terminal emulators. **VS Code's integrated terminal and Ghostty are not supported** — they lack the tmux integration needed for agent pane spawning. See [Known Issues](docs/KNOWN-ISSUES.md) for details.

## Quick Start

```bash
git clone https://github.com/sethford/claude-code-teams-tmux.git
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
│   └── claude-teams-overlay.conf    # Agent-aware pane styling & team keybindings
├── claude-code/
│   ├── settings.json.template       # Claude Code settings with teams enabled
│   └── hooks/
│       └── teammate-idle.sh         # Quality gate: block idle if typecheck fails
├── scripts/
│   └── cct                          # CLI for managing team sessions
├── docs/
│   ├── KNOWN-ISSUES.md              # Tracked bugs with workarounds
│   └── TIPS.md                      # Power user tips
├── install.sh                       # Interactive installer
└── LICENSE                          # MIT
```

### Premium Dark Theme

Dark blue-gray background (`#1a1a2e`) with cyan accents (`#00d4ff`). The status bar shows your session name, current window, user/host, time, and date. Active pane borders light up in cyan. Agent names display in pane border headers so you always know which agent is in which pane.

### Claude Code Settings Template

Pre-configured `settings.json.template` with:
- Agent teams enabled (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)
- Auto-detects tmux — agents get split panes automatically
- Haiku model for cheap subagent lookups
- Auto-compact at 70% to prevent context overflow
- Recommended plugins and environment variables

### Quality Gate Hooks

The `teammate-idle.sh` hook runs `pnpm typecheck` (or `npx tsc --noEmit`) when an agent goes idle. If there are TypeScript errors, it blocks the idle with exit code 2, telling the agent to fix them first.

### `cct` CLI

A shell script for managing team sessions:

```bash
cct session my-feature    # Create a team session with agent panes
cct status                # Show team dashboard
cct cleanup               # Dry-run: show orphaned sessions
cct cleanup --force       # Kill orphaned sessions
```

## Usage

### Starting a Team Session

```bash
# Start tmux (if not already in a session)
tmux new -s dev

# Option 1: Use cct CLI
cct session my-feature

# Option 2: Use tmux keybinding
# Press Ctrl-a then T to launch a team session

# Option 3: Just start Claude Code — it handles teams automatically
claude
```

### Monitoring Teams

```bash
# Show running team sessions
cct status

# Or use the tmux keybinding: Ctrl-a then Ctrl-t
```

### Cleaning Up

```bash
# Preview what would be cleaned up
cct cleanup

# Actually kill orphaned sessions and panes
cct cleanup --force
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
| `prefix + Alt-t` | Toggle team sync mode |
| `prefix + Alt-l` | Cycle through pane layouts |
| `prefix + Alt-s` | Capture pane contents to file |

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

## Plugins (TPM)

The tmux config uses [TPM](https://github.com/tmux-plugins/tpm) for plugin management. Included plugins:

- **tmux-sensible** — Sensible defaults
- **tmux-resurrect** — Save/restore sessions across restarts
- **tmux-continuum** — Automatic session saving

Install plugins after setup: `prefix + I` (capital I).

## License

[MIT](LICENSE) — Seth Ford, 2026.
