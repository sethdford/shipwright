# tmux Architecture & Integration Patterns for 2025-2026

## 1. Core tmux Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     tmux Server (daemon)                         │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Session 1 (development)                                 │   │
│  │  ┌──────────────┬──────────────┬──────────────┐          │   │
│  │  │  Window 1    │  Window 2    │  Window 3    │          │   │
│  │  │  (editor)    │  (tests)     │  (logs)      │          │   │
│  │  │ ┌──┬──┐      │ ┌────────┐   │ ┌────────┐   │          │   │
│  │  │ │P1│P2│      │ │  P3    │   │ │  P4    │   │          │   │
│  │  │ └──┴──┘      │ └────────┘   │ └────────┘   │          │   │
│  │  └──────────────┴──────────────┴──────────────┘          │   │
│  │                                                            │   │
│  │  Status Line: [session_name] [1:editor] [2:tests] [3:logs] │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Session 2 (agents)                                      │   │
│  │  ┌──────────────┬──────────────┬──────────────┐          │   │
│  │  │ Orchestrator │ Agent (API)  │ Agent (UI)   │          │   │
│  │  │ ┌────────┐   │ ┌────────┐   │ ┌────────┐   │          │   │
│  │  │ │Status  │   │ │Claude  │   │ │Claude  │   │          │   │
│  │  │ └────────┘   │ └────────┘   │ └────────┘   │          │   │
│  │  └──────────────┴──────────────┴──────────────┘          │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
         │              │                │
         ├─ $TMUX socket (localhost)
         ├─ Events (hooks, resize, key bindings)
         └─ Clipboard (OSC 52, system integration)
```

---

## 2. Modern tmux + Neovim + AI Integration

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        Developer Workstation                              │
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    tmux Session: multi-agent-dev                 │   │
│  │                                                                   │   │
│  │  Window 1: editor-vim              Window 2: claude-agent-1     │   │
│  │  ┌────────────────────────────┐   ┌────────────────────────┐   │   │
│  │  │ Neovim (Main Workspace)    │   │ Claude Code REPL       │   │   │
│  │  │                            │   │                        │   │   │
│  │  │ Plugins:                   │   │ ~/worktree-1/backend   │   │   │
│  │  │ - sidekick.nvim ───────────┼──>│ $ claude code          │   │   │
│  │  │ - claude-code.nvim         │   │ > (AI session)         │   │   │
│  │  │ - vim-tmux-navigator ──────┼──>│ Connected via:         │   │   │
│  │  │ - avante.nvim              │   │ - Tmux pane ID         │   │   │
│  │  │ - treesitter               │   │ - OSC 8 links          │   │   │
│  │  │                            │   │ - Copy/paste (OSC 52)  │   │   │
│  │  └────────────────────────────┘   └────────────────────────┘   │   │
│  │                                                                   │   │
│  │  Window 3: claude-agent-2         Window 4: monitor            │   │
│  │  ┌────────────────────────────┐   ┌────────────────────────┐   │   │
│  │  │ Claude Code REPL           │   │ Shipwright Vitals      │   │   │
│  │  │ ~/worktree-2/frontend      │   │ $ shipwright vitals    │   │   │
│  │  │ $ claude code              │   │                        │   │   │
│  │  └────────────────────────────┘   │ [████████░░] 85%       │   │   │
│  │                                    │ Tests: 42/45 passing   │   │   │
│  │                                    │ Cost: $12.50 / $100    │   │   │
│  │                                    └────────────────────────┘   │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                            │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                  tmux Status Line                                │    │
│  │  [multi-agent-dev] 1:editor 2:claude-1 3:claude-2 4:monitor    │    │
│  │                                              18:30  (Sat)       │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────┘

Key Interactions:
┌─────────────────────────────────────────────────────────────────┐
│                                                                   │
│  Ctrl-h/j/k/l  →  vim-tmux-navigator  →  Select panes/windows   │
│  Cmd+F         →  sidekick.nvim        →  Query Claude from Vim  │
│  Space+cf      →  claude-code.nvim     →  Send file to Claude    │
│  Ctrl+P        →  display-popup        →  fzf file search        │
│  Ctrl+A,r      →  Reload config        →  Hot-reload settings    │
│  Cmd+M         →  Toggle mouse         →  Enable for pair prog   │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. Shipwright + Daemon Pipeline in tmux

```
┌─────────────────────────────────────────────────────────────────────┐
│                  shipwright daemon [running 4 workers]               │
│                                                                       │
│  Issue Queue:  [#42 bug] [#43 feat] [#44 refactor] [#45 docs]       │
│       ↓                                                               │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  tmux Session: shipwright-daemon                            │   │
│  │                                                              │   │
│  │ Window 1: pipeline-42             Window 2: pipeline-43    │   │
│  │ Status: [████████░░░] 75%         Status: [████░░░░░░] 40% │   │
│  │ Stage: build → test               Stage: intake            │   │
│  │ ┌──────────────────────┐          ┌──────────────────────┐ │   │
│  │ │ git worktree: wt-42  │          │ git worktree: wt-43  │ │   │
│  │ │ $ cd /tmp/wt-42      │          │ $ cd /tmp/wt-43      │ │   │
│  │ │ $ npm test           │          │ $ shipwright plan    │ │   │
│  │ │                      │          │                      │ │   │
│  │ │ ✓ Build (2m 15s)     │          │ → Planning...        │ │   │
│  │ │ ✓ Tests (1m 40s)     │          │                      │ │   │
│  │ │ → Review (pending)   │          │                      │ │   │
│  │ └──────────────────────┘          └──────────────────────┘ │   │
│  │                                                              │   │
│  │ Window 3: cost-monitor             Window 4: memory-system │   │
│  │ Daily Budget: $100 / $100          ┌──────────────────────┐ │   │
│  │ Used This Run:                     │ Remembered patterns: │   │
│  │  - Pipeline 42: $8.50              │ • Timeout in Jest    │   │
│  │  - Pipeline 43: $2.10              │ • DB migration issue │   │
│  │  - Pipeline 44: $1.80              │ • Auth handler fix   │   │
│  │ Remaining: $87.60                  └──────────────────────┘ │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                       │
│  Heartbeats:                                                         │
│  42 ───╯╰─╱╲╱╲╱╲  (active, 4 pings)                                │
│  43 ───╯╰─╱╲ ♥     (idle, waiting for approval)                   │
│  44 ───╳  (error, max retries exceeded)                            │
│  45 ───◇  (queued, waiting for worker slot)                       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. Plugin Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                   tmux Core (3.2+)                              │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │   Sessions   │  │   Windows    │  │    Panes     │          │
│  │              │  │              │  │              │          │
│  │ [attach]     │  │ [new-window] │  │ [split]      │          │
│  │ [kill]       │  │ [kill]       │  │ [capture]    │          │
│  │ [rename]     │  │ [rename]     │  │ [send-keys]  │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│         ↑                  ↑                  ↑                  │
└─────────┼──────────────────┼──────────────────┼────────────────┘
          │                  │                  │
      ┌───┴──────────────────┴──────────────────┴─────┐
      │                                                 │
      │   ┌─────────────────────────────────────────┐  │
      │   │         TPM (Plugin Manager)            │  │
      │   │   ~/.tmux/plugins/tpm/tpm              │  │
      │   │   Ctrl-I: install | Ctrl-U: update     │  │
      │   └─────────────────────────────────────────┘  │
      │                      │                         │
      └──────────────────────┼─────────────────────────┘
             ┌────────────────┼────────────────┐
             │                │                │
        ┌────▼─────┐    ┌─────▼─────┐   ┌────▼──────┐
        │ Essential │    │ Optional  │   │ Custom    │
        │ Plugins   │    │ Plugins   │   │ Plugins   │
        │           │    │           │   │           │
        │ • sensible│    │ • resurrect   │ • shipwright
        │ • yank    │    │ • continuum   │ • custom hooks
        │ • nav-vim │    │ • statusline  │ • theme
        │ • prefix- │    │ • copycat     │ • bindings
        │   highlight   │ • which-key    │           │
        │           │    │           │   │           │
        └───────────┘    └───────────┘   └───────────┘
```

---

## 5. Configuration Override Hierarchy

```
┌────────────────────────────────────────────────────────────────┐
│               tmux Config Loading Order                         │
│                                                                 │
│  1. Server defaults                                            │
│     (hardcoded, immutable)                                     │
│              ↓                                                  │
│  2. System config (/etc/tmux.conf)                            │
│     (rare, admin-managed)                                      │
│              ↓                                                  │
│  3. User config (~/.tmux.conf)                                │
│     (core configuration, rarely edited)                        │
│              ↓                                                  │
│  4. Local config (~/.tmux.conf.local) ← START HERE           │
│     (customizations, project-specific settings)                │
│              ↓                                                  │
│  5. Runtime commands (from REPL or shell)                     │
│     (tmux set-option, tmux bind-key)                          │
│                                                                 │
│  ⚠️  IMPORTANT: Never edit #3 if using Oh My Tmux!            │
│      Put all customizations in #4 (.tmux.conf.local)          │
│      This allows upgrading core config without conflicts      │
└────────────────────────────────────────────────────────────────┘
```

---

## 6. Hooks & Lifecycle Events

```
┌──────────────────────────────────────────────────────────────────┐
│                       Session Lifecycle                           │
│                                                                   │
│  tmux new-session                                                │
│         ↓                                                         │
│         └─→ after-new-session hook                              │
│                 (run custom setup: mkdir, git clone)            │
│         ↓                                                         │
│  Session active (user working)                                  │
│         ↓                                                         │
│  Window created                                                  │
│         └─→ after-new-window hook                               │
│                 (rename based on directory)                     │
│         ↓                                                         │
│  User types commands in panes                                   │
│         ├─ session-renamed hook (triggered if user renames)    │
│         ├─ window-linked hook (pane changes windows)           │
│         └─ pane-mode-changed hook (enter copy-mode)            │
│         ↓                                                         │
│  Process exits in pane                                          │
│         └─→ pane-exited hook                                    │
│                 (auto-cleanup, capture output)                  │
│         ↓                                                         │
│  tmux kill-session                                              │
│         ↓                                                         │
│         └─→ session-closed hook                                 │
│                 (save state, cleanup worktrees)                 │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘

Example hook chain for Shipwright:

  after-new-session  →  Create git worktree
                     →  Initialize .claude/CLAUDE.md
                     →  Start memory system
                     →  Display pipeline state

  window-linked      →  Rename window to match branch
                     →  Auto-run tests in background
                     →  Update status line

  pane-exited        →  Capture pane output to log
                     →  Check exit code (0 = success, else fail)
                     →  Post event to heartbeat system
                     →  Trigger next pipeline stage (if gated)
```

---

## 7. Mouse Mode Conflict Resolution

```
┌────────────────────────────────────────────────────────────────┐
│            Mouse Mode Trade-offs (2025)                         │
│                                                                 │
│  MOUSE OFF (Default for AI work)                              │
│  ┌──────────────────────────────────┐                         │
│  │ ✓ Text selection bypasses tmux   │                         │
│  │ ✓ Vim/Neovim visual mode works   │                         │
│  │ ✓ Claude Code REPL capture clear │                         │
│  │ ✗ No point-and-click window nav  │                         │
│  │ ✗ Can't drag pane dividers       │                         │
│  │ ✗ Must use keyboard for resizing │                         │
│  └──────────────────────────────────┘                         │
│                                                                 │
│  MOUSE ON (Good for pair programming)                         │
│  ┌──────────────────────────────────┐                         │
│  │ ✓ Click to switch panes/windows  │                         │
│  │ ✓ Drag to resize pane dividers   │                         │
│  │ ✓ Scroll wheel works in panes    │                         │
│  │ ✗ Shift+click needed to select   │                         │
│  │   text across pane boundaries    │                         │
│  │ ✗ System clipboard needs xclip  │                         │
│  │ ✗ TUI apps (Vim) get mouse events│                         │
│  └──────────────────────────────────┘                         │
│                                                                 │
│  SOLUTION: Toggle mouse with key binding                      │
│  bind m set -g mouse \; display "Mouse: #{?mouse,ON,OFF}"    │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

---

## 8. Copy Mode Data Flow

```
┌────────────────────────────────────────────────────────────────┐
│                  Copy Mode Workflow                             │
│                                                                 │
│  Pane Output                                                    │
│  ┌──────────────────────────────────────────────────────┐     │
│  │  $ npm test                                          │     │
│  │  PASS  src/utils.test.js                            │     │
│  │  FAIL  src/auth.test.js (line 42)                   │     │
│  │  ──────────────────────────────────────────────────  │     │
│  │  Tests:  45 passed, 1 failed                        │     │
│  └──────────────────────────────────────────────────────┘     │
│         ↑                                                       │
│         │  User: tmux prefix + [  (enter copy-mode)           │
│         │                                                      │
│  ┌──────▼──────────────────────────────────────────────┐     │
│  │  Copy Mode (vi-style)                               │     │
│  │                                                      │     │
│  │  v        = begin selection                         │     │
│  │  y        = copy selection to tmux buffer           │     │
│  │  Y        = copy entire line                        │     │
│  │  H/L      = start/end of line                       │     │
│  │  j/k      = move down/up                            │     │
│  │  / or ?   = search forward/backward                 │     │
│  │  Enter    = exit copy-mode                          │     │
│  └──────────────────────────────────────────────────────┘     │
│         │                                                       │
│         ↓                                                       │
│  Selection: "Tests:  45 passed, 1 failed"                     │
│         │                                                       │
│         │  User presses: y                                    │
│         │                                                      │
│         ├─→ copy-pipe: if-shell "%if platform=darwin"       │
│         │   ├─→ macOS: copy-pipe-and-cancel "pbcopy"        │
│         │   └─→ Linux: copy-pipe-and-cancel "xclip ..."     │
│         │                                                      │
│         ├─→ tmux buffer (internal clipboard)                 │
│         │                                                      │
│         └─→ System clipboard (Cmd+V / Ctrl+V)               │
│                                                                 │
│  Usage: Paste into Slack, Github issue, etc.                 │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

---

## 9. Floating Popup Windows (tmux 3.2+)

```
┌────────────────────────────────────────────────────────────────┐
│  Main tmux Session (full terminal)                              │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  Neovim (editor pane)                                    │ │
│  │  1 set tabstop=2                                         │ │
│  │  2 set expandtab                                         │ │
│  │  3 let g:copilot_enabled = v:true                       │ │
│  │  4                                                       │ │
│  │  ┌─────────────────────────────────────────────────┐   │ │
│  │  │  FZF Popup (Ctrl+G, display-popup)              │   │ │
│  │  │                                                   │   │ │
│  │  │  Find file:                                      │   │ │
│  │  │  >                                               │   │ │
│  │  │   bundle.json                                    │   │ │
│  │  │   config/auth.js        ← preview right         │   │ │
│  │  │   config/db.js                                   │   │ │
│  │  │   package.json                                   │   │ │
│  │  │                                                   │   │ │
│  │  │  Selected file:                                  │   │ │
│  │  │  config/auth.js                                  │   │ │
│  │  │                                                   │   │ │
│  │  │  [Enter to open]                                │   │ │
│  │  └─────────────────────────────────────────────────┘   │ │
│  │  (User presses Enter)                                   │ │
│  │  ↓ Popup closes, file opened in Neovim                │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  Git Status Popup (C-j)                                 │  │
│  │                                                           │  │
│  │   $ git status -sb                                       │  │
│  │   ## main...upstream/main                               │  │
│  │   M  config/auth.js                                     │  │
│  │   ?? node_modules/.tsconfig                             │  │
│  │                                                           │  │
│  │  [q to close]                                           │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                                 │
│  Popup Features:                                               │
│  • Floats above existing layout (doesn't reshape panes)       │
│  • Customizable size & position: -h 50% -w 80% -x C -y S    │
│  • Closable with Escape or q                                  │
│  • Can run any shell command                                  │
│  • Perfect for quick tools (fzf, git, docs)                  │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

---

## 10. Integration Points Summary

```
┌───────────────────────────────────────────────────────────────────┐
│                     Ecosystem Integration                          │
│                                                                    │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐             │
│  │  Shipwright │  │  Claude Code │  │  Neovim      │             │
│  │             │  │              │  │              │             │
│  │ • Daemon    │  │ • REPL       │  │ • LSP        │             │
│  │ • Pipeline  │  │ • Agent      │  │ • Plugins    │             │
│  │ • Vitals    │  │ • Memory     │  │ • Keymaps    │             │
│  │ • Cost      │  │ • MCP        │  │ • Snippets   │             │
│  └──────┬──────┘  └──────┬───────┘  └──────┬───────┘             │
│         │                │                 │                     │
│         └────────────────┼─────────────────┘                     │
│                          │                                        │
│                   ┌──────▼────────┐                              │
│                   │    tmux       │                              │
│                   │               │                              │
│                   │ • Sessions    │                              │
│                   │ • Windows     │                              │
│                   │ • Panes       │                              │
│                   │ • Hooks       │                              │
│                   │ • Plugins     │                              │
│                   │ • Clipboard   │                              │
│                   └───────────────┘                              │
│                          │                                        │
│         ┌────────────────┼────────────────┐                      │
│         │                │                │                      │
│    ┌────▼────┐    ┌─────▼──────┐   ┌────▼──────┐               │
│    │ Terminal │    │   Git      │   │  System   │               │
│    │          │    │            │   │           │               │
│    │ • Colors │    │ • Worktrees│   │ • Clipboard
│    │ • Keys   │    │ • Branches │   │ • Signals │               │
│    │ • Output │    │ • Status   │   │ • Timing  │               │
│    └──────────┘    └────────────┘   └───────────┘               │
│                                                                    │
│  Data Flow Example:                                              │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ 1. User types in Neovim: ":ClaudeAsk What does this do?"    │
│  │ 2. Neovim plugin captures context (file, cursor, diagnostics) │
│  │ 3. Plugin sends to Claude pane via tmux send-keys            │
│  │ 4. Claude Code processes & responds                          │
│  │ 5. Neovim reads Claude's output from tmux pane buffer       │
│  │ 6. Response appears in Neovim floating window               │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                    │
└───────────────────────────────────────────────────────────────────┘
```

---

## 11. Performance Characteristics

```
┌──────────────────────────────────────────────────────────────────┐
│        tmux Performance in 2025 (with Claude Code)                │
│                                                                   │
│  Memory Usage (typical):                                         │
│  ├─ Empty session              ~2 MB                            │
│  ├─ + 4 panes (Vim, tests, logs, agent)  ~8 MB                 │
│  ├─ + 250K scrollback history   ~45 MB                          │
│  ├─ + Resurrection (saved state) ~2 MB                          │
│  └─ Total for multi-agent setup         ~60 MB                  │
│                                                                   │
│  CPU Usage:                                                      │
│  ├─ Idle session               <0.1% CPU                        │
│  ├─ Active with status updates   ~0.5% CPU (5s intervals)      │
│  ├─ High-throughput (Claude out) ~2-3% CPU (during output)     │
│  ├─ Resizing panes              <0.1% CPU (instant)            │
│  └─ Note: Mostly spent in terminal rendering, not tmux logic   │
│                                                                   │
│  Latency (keyboard to screen):                                  │
│  ├─ Normal key input            <5ms (escape-time: 0)          │
│  ├─ Copy-mode navigation         <2ms (vi bindings optimized)  │
│  ├─ Pane switching (C-a,h)       <2ms                          │
│  ├─ Status bar updates           <10ms                          │
│  └─ Claude output streaming      ~50ms per line (terminal I/O) │
│                                                                   │
│  Optimization Tuples:                                            │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ Feature       │ Default │ Tuned for Claude          │    │
│  │───────────────┼─────────┼──────────────────────────   │    │
│  │ escape-time   │ 500ms   │ 0ms (critical)            │    │
│  │ history-limit │ 2000    │ 250000 (high output)      │    │
│  │ status-interval│ 15s    │ 10s (reduce CPU)          │    │
│  │ buffer-limit  │ 20      │ 20 (keep as-is)           │    │
│  │ mouse         │ off     │ off (AI workflows)        │    │
│  │ allow-passthrough│off   │ on (TUI compat)           │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                   │
│  Bottlenecks:                                                    │
│  1. Terminal rendering (xterm protocol) — not tmux              │
│  2. Pane scrollback search — use ↑/↓ not /search               │
│  3. Large copy operations — tmux buffer is in-memory            │
│  4. Many panes (>10) — CPU increases linearly                   │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

---

## 12. Decision Tree: Which Feature to Use

```
                    ┌─────────────────────────┐
                    │ I need to accomplish... │
                    └───────────┬─────────────┘
                                │
                ┌───────────────┼───────────────┐
                │               │               │
         ┌──────▼─────┐  ┌─────▼──────┐  ┌────▼────────┐
         │Quick        │  │Organize    │  │Automate     │
         │navigation   │  │large tasks │  │repetitive   │
         │             │  │            │  │tasks        │
         └──────┬──────┘  └─────┬──────┘  └────┬────────┘
                │               │               │
      ┌─────────┼─────────┐    │             │
      │         │         │    │             │
   ┌──▼──┐  ┌──▼──┐  ┌───▼─┐  │             │
   │fzf  │  │session
   │     │  │switcher
   │popup│  │     │
   │(C-p)│  └─────┘
   └─────┘

      │
      │         ┌──────────────────────┐
      │         │ Organization Tool    │
      └────────▶│                      │
                │ • One session per    │
                │   project (tmuxinator)
                │ • One window per     │
                │   agent (git worktree)
                │ • One pane per task  │
                │   (side-by-side)     │
                └──────────────────────┘

      │
      │         ┌──────────────────────┐
      │         │ Automation Method    │
      │         │                      │
      │         │ • Hooks: after-new-
      │         │   session, pane-exited
      └────────▶│ • Scripts: setup-
                │   dev-session.sh
                │ • send-keys: CI/CD
                │   runner
                │ • Keybindings: tmux
                │   aliases
                └──────────────────────┘
```

---

## Summary: Best-in-Class Integration (2025-2026)

1. **Foundation**: tmux 3.2+ with Oh My Tmux! configuration
2. **Plugins**: vim-tmux-navigator + tmux-resurrect + tmux-continuum
3. **Editor**: Neovim with sidekick.nvim and claude-code.nvim
4. **AI Workflow**: git worktrees + multi-agent tmux windows
5. **Automation**: Hooks for lifecycle events + scripts for setup
6. **Performance**: escape-time=0, history=250K, status-interval=10s
7. **Floating Tools**: fzf popups for quick access (no pane reshaping)
8. **Integration**: OSC 52 clipboard + focus-events + allow-passthrough

This stack enables **persistent, multi-agent development environments** with seamless Neovim + Claude Code integration, optimized for high-throughput AI-assisted workflows.
