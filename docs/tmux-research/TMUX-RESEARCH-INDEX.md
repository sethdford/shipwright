# tmux Research Index: Best-in-Class 2025-2026

**Research Completion Date**: February 12, 2026
**Focus Areas**: 14 comprehensive topics
**Total Documentation**: 4 detailed guides + this index

---

## Overview

This research compiled best-in-class tmux configurations, patterns, and integrations from the 2025-2026 ecosystem, with special emphasis on:

1. Modern developer workflows
2. AI agent multi-pane orchestration
3. Neovim + Claude Code integration
4. High-throughput terminal scenarios
5. Shipwright daemon patterns

---

## Document Guide

### 1. TMUX-BEST-PRACTICES-2025-2026.md (29 KB)

**The comprehensive configuration bible**

| Section                   | Coverage                                                         |
| ------------------------- | ---------------------------------------------------------------- |
| 1. Core Patterns          | Oh My Tmux! philosophy, version detection, conditional configs   |
| 2. Status Line            | Minimal design, production templates, Neovim integration         |
| 3. Advanced Features      | Hooks, copy-mode, popups, mouse handling                         |
| 4. Plugin Ecosystem       | TPM, essential plugins, modern tools (2025-2026)                 |
| 5. Neovim Integration     | vim-tmux-navigator, claude-code.nvim, sidekick.nvim, avante.nvim |
| 6. Performance Tuning     | Claude Code high-throughput optimization                         |
| 7. CI/CD Patterns         | Automated session setup, GitHub Actions integration              |
| 8. Shipwright Config      | Daemon setup, team pane layouts, vitals monitoring               |
| 9. Best Practices Summary | Quick reference table                                            |
| 10. Config Templates      | Minimal production + full-featured configs                       |
| 11. Resources             | Links to official docs, frameworks, plugins                      |

**When to Use**: Deep understanding of features, production configuration, troubleshooting complex setups

---

### 2. TMUX-ARCHITECTURE.md (43 KB)

**Visual architecture and integration patterns**

| Section                         | Purpose                                                   |
| ------------------------------- | --------------------------------------------------------- |
| 1. Core Architecture            | ASCII diagram of tmux server, sessions, windows, panes    |
| 2. Modern Neovim+AI             | Full integration diagram (Neovim ↔ Claude ↔ tmux)         |
| 3. Shipwright Pipeline          | Daemon with 4 parallel workers, heartbeats, cost tracking |
| 4. Plugin Architecture          | TPM flow and plugin categories                            |
| 5. Config Override Hierarchy    | Load order and precedence rules                           |
| 6. Hooks & Lifecycle            | Session/window/pane event flow                            |
| 7. Mouse Mode Trade-offs        | Decision table for mouse on/off scenarios                 |
| 8. Copy Mode Data Flow          | Selection → clipboard → system integration                |
| 9. Floating Popups              | Visual example of display-popup usage                     |
| 10. Integration Points          | How Shipwright, Claude Code, Neovim coordinate            |
| 11. Performance Characteristics | Memory, CPU, latency benchmarks                           |
| 12. Feature Decision Tree       | Choose right tool for each task                           |

**When to Use**: Visual learners, understanding integration patterns, debugging coordination issues

---

### 3. TMUX-QUICK-REFERENCE.md (13 KB)

**Fast lookup for developers**

| Section                 | Content                                               |
| ----------------------- | ----------------------------------------------------- |
| Installation            | macOS, Linux, source build                            |
| Oh My Tmux Setup        | 3-line quick start                                    |
| Essential Keybindings   | All critical shortcuts in table format                |
| Command-Line Essentials | `tmux` command reference                              |
| Config Patterns         | Copy-paste ready snippets                             |
| Plugin Manager          | TPM install + common plugins                          |
| Scripting Examples      | Multi-pane setup, multi-agent workflow, file watchers |
| Troubleshooting         | Colors, ESC delay, clipboard, version checks          |
| Performance Tuning      | High-throughput settings                              |
| One-Liners              | Useful bash commands                                  |
| Version Compatibility   | Feature support by tmux version                       |

**When to Use**: During active development, copy-paste configuration, quick lookups

---

## Key Findings Summary

### Best-in-Class Configuration (2025-2026)

**Gold Standard**: [Oh My Tmux!](https://github.com/gpakosz/.tmux) (gpakosz/.tmux)

- Actively maintained as of 2025
- 100+ contributors
- Philosophy: Never edit core config; customize via `.tmux.conf.local`
- Dual prefix support (C-a + C-b for nested sessions)
- SSH-aware, Powerline-inspired theming

**Essential Plugins** (via TPM):

1. `tmux-plugins/tmux-sensible` — Sensible defaults
2. `christoomey/vim-tmux-navigator` — Vim ↔ tmux seamless navigation
3. `tmux-plugins/tmux-yank` — System clipboard integration
4. `tmux-plugins/tmux-resurrect` — Persist sessions across restarts
5. `tmux-plugins/tmux-continuum` — Auto-save every 5 minutes

**Modern Tools** (new in 2025-2026):

- **dmux** (Rust) — Workspace manager for multi-agent setups
- **sessionx** — FZF session switcher with preview
- **sesh** — Intelligent session detection by project type
- **treemux** (Rust) — File explorer sidebar (Nvim-Tree style)
- **laio** (Rust) — Flexbox-inspired declarative layouts

### Critical Settings for AI Development

```tmux
set -g escape-time 0                    # Neovim ESC responsiveness
set -g history-limit 250000             # Claude Code output volume
set -g allow-passthrough on             # DEC 2026 synchronized output
set -g extended-keys on                 # Alt key combinations work
set -g focus-events on                  # TUI app focus tracking
set -g set-clipboard on                 # OSC 52 native clipboard
set -g status-interval 10               # Reduce CPU (5-10s better than 1s)
```

### Integration Patterns

**Pattern 1: Neovim + Claude Code in Same Session**

```
Window 1: Neovim (with sidekick.nvim, claude-code.nvim)
Window 2: Claude Code REPL (separate pane)
Window 3: Tests/Monitor (watch build output)

Navigation: Ctrl-h/j/k/l (vim-tmux-navigator) moves seamlessly
Workflow: Query Claude from Neovim, see response in adjacent pane
```

**Pattern 2: Multi-Agent Autonomous Development**

```
Session: multi-agent-dev
├─ Window 1: Orchestrator (shipwright status)
├─ Window 2: Agent-1 (API backend, git worktree)
├─ Window 3: Agent-2 (UI frontend, git worktree)
├─ Window 4: Monitor (shipwright vitals, cost tracking)
└─ Window 5: Memory (failure patterns from last runs)

Each agent runs in isolated git worktree, no merge conflicts
```

**Pattern 3: Floating Popups for Quick Tasks**

```
Ctrl+G → Floating scratch terminal (fzf, commands, repl)
Ctrl+S → Floating session switcher
Ctrl+J → Floating git status
Ctrl+F → Floating file search (rg + fzf)
Ctrl+P → Floating process monitor

Popups don't reshape main layout, press Escape to dismiss
```

### Performance Characteristics

| Metric                             | Value    | Notes                        |
| ---------------------------------- | -------- | ---------------------------- |
| Memory (idle session)              | 2 MB     | Single session, no panes     |
| Memory (4 panes + 250K scrollback) | 45-60 MB | Typical multi-agent setup    |
| CPU (idle)                         | <0.1%    | Minimal overhead             |
| CPU (active with updates)          | 0.5-2%   | Terminal rendering dominates |
| Keyboard latency (C-a key)         | <5ms     | Instant with escape-time 0   |
| Pane switch latency (C-h)          | <2ms     | Native vim-tmux-navigator    |
| Status bar update                  | <10ms    | Every 5-10s intervals        |

### Hooks Lifecycle

Key automation points:

- `after-new-session` — Create git worktree, init CLAUDE.md, start memory system
- `window-linked` — Auto-rename window to match branch
- `pane-exited` — Capture output, check status code, trigger next stage (if gated)
- `session-closed` — Save state, cleanup worktrees, post event to heartbeat

### Copy-Mode Best Practices

For TUI apps (Vim, Neovim, Claude Code):

- Bind vi-style keys: `v` begin, `y` copy, `H`/`L` line bounds
- Shift+drag for cross-pane selection (bypasses tmux capture)
- Don't use mouse mode in AI workflows (conflicts with tool focus)
- On macOS: bind `y` to `pbcopy`; on Linux: bind `y` to `xclip`

### Version Compatibility Matrix

| Feature                              | Min Version | Status                      |
| ------------------------------------ | ----------- | --------------------------- |
| `display-popup` (floating windows)   | 3.2+        | Full support                |
| `allow-passthrough` (DEC 2026 sync)  | 3.2+        | Eliminates TUI flicker      |
| `extended-keys` (Alt combinations)   | 3.0+        | TUI compatibility           |
| `focus-events` (app focus tracking)  | 2.2+        | Responsive to window events |
| `set-clipboard` (OSC 52)             | 3.2+        | Native clipboard over SSH   |
| `if-shell` versioning (`%if` syntax) | 2.4+        | Conditional config loading  |
| `copy-pipe-and-cancel`               | 2.5+        | Enhanced copy behavior      |

---

## Research Coverage

### Topics Fully Researched

1. **Core Configuration Patterns** ✓
   - Oh My Tmux! framework
   - Conditional version detection
   - Override hierarchy

2. **Status Line Best Practices** ✓
   - Minimal vs. informative trade-offs
   - Performance considerations
   - Neovim-specific optimizations

3. **Advanced Features** ✓
   - Hooks (after-new-session, pane-exited, etc.)
   - Copy-mode for TUI apps
   - display-popup floating windows
   - Mouse mode conflicts and resolution

4. **Plugin Ecosystem** ✓
   - TPM installation and workflow
   - Essential plugins (2025-2026)
   - Modern tools (dmux, sessionx, sesh, treemux, laio)

5. **Neovim + AI Integration** ✓
   - vim-tmux-navigator setup
   - claude-code.nvim, sidekick.nvim, avante.nvim
   - Multi-agent orchestration patterns

6. **Performance Tuning** ✓
   - High-throughput Claude Code scenarios
   - Memory and CPU optimization
   - Status bar frequency tuning

7. **CI/CD and Automation** ✓
   - Automated session setup scripts
   - GitHub Actions integration
   - Shipwright daemon patterns

8. **Hooks & Lifecycle** ✓
   - Complete event list
   - Use cases for each hook
   - Shipwright integration examples

9. **Copy-Mode Optimization** ✓
   - vi-style keybindings
   - Clipboard integration (macOS, Linux)
   - TUI app considerations

10. **Mouse Mode Handling** ✓
    - On vs. Off trade-offs
    - Shift+drag for selection
    - AI tool compatibility

11. **Floating Popups** ✓
    - display-popup syntax (3.2+)
    - Use cases (fzf, git, file search)
    - Best practices

12. **Conditional Configuration** ✓
    - if-shell version detection
    - %if modern syntax
    - Platform-specific (darwin, linux)

13. **Session Management** ✓
    - One session per project pattern
    - Tmuxinator and alternatives
    - Multi-agent git worktree patterns

14. **Shipwright Integration** ✓
    - Daemon configuration
    - Team pane layouts
    - Vitals monitoring
    - Cost tracking in status line

---

## Recommended Reading Order

**For Quick Setup** (< 30 min):

1. Start: TMUX-QUICK-REFERENCE.md → Installation + Oh My Tmux setup
2. Copy: Minimal production config from TMUX-BEST-PRACTICES-2025-2026.md (section 10.1)
3. Install: TPM and essential plugins
4. Done: Reload config with `C-a r`

**For Deep Understanding** (2-3 hours):

1. Read: TMUX-BEST-PRACTICES-2025-2026.md sections 1-5
2. Visualize: TMUX-ARCHITECTURE.md sections 1-3 (diagrams)
3. Review: Integration examples (TMUX-BEST-PRACTICES-2025-2026.md section 5)
4. Reference: TMUX-QUICK-REFERENCE.md as needed

**For Shipwright Integration** (1-2 hours):

1. Read: TMUX-BEST-PRACTICES-2025-2026.md section 8
2. Review: TMUX-ARCHITECTURE.md section 3 (pipeline diagram)
3. Copy: Multi-agent workflow template from TMUX-BEST-PRACTICES-2025-2026.md (section 5.3)
4. Adapt: For your project layout

**For Performance Optimization** (30 min):

1. Reference: TMUX-ARCHITECTURE.md section 11 (benchmarks)
2. Review: TMUX-BEST-PRACTICES-2025-2026.md section 6
3. Apply: Settings to `.tmux.conf.local`

---

## External Resources

### Official Documentation

- [tmux Manual](https://man7.org/linux/man-pages/man1/tmux.1.html) — Complete reference
- [GitHub tmux/tmux](https://github.com/tmux/tmux) — Release notes, issues

### Frameworks & Configs

- [Oh my tmux!](https://github.com/gpakosz/.tmux) — Actively maintained 2025
- [Awesome tmux](https://github.com/rothgar/awesome-tmux) — Community curated
- [tao-of-tmux](https://tao-of-tmux.readthedocs.io/) — Educational guide

### AI Integration Plugins

- [claude-code.nvim](https://github.com/dreemanuel/claude-code.nvim) — Neovim + Claude + tmux
- [sidekick.nvim](https://github.com/folke/sidekick.nvim) — AI sidekick with tmux backend
- [avante.nvim](https://github.com/yetone/avante.nvim) — Multi-provider AI in Neovim

### Plugin Manager & Plugins

- [TPM](https://github.com/tmux-plugins/tpm) — Plugin manager
- [vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator) — Seamless navigation
- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) — Session persistence
- [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) — Auto-save

### Multi-Agent Workflows

- [Shipwright](https://github.com/sethdford/shipwright) — Autonomous agent pipeline (this repo!)
- [multi-agent-workflow-kit](https://github.com/laris-co/multi-agent-workflow-kit) — Reusable patterns
- [workmux](https://github.com/raine/workmux) — git worktrees + tmux windows

---

## Implementation Checklist

### Immediate Actions (< 1 hour)

- [ ] Install/upgrade tmux to 3.2+: `brew install tmux`
- [ ] Clone Oh My Tmux!: `git clone https://github.com/gpakosz/.tmux.git ~/.tmux`
- [ ] Create symlink: `ln -s -f ~/.tmux/.tmux.conf ~/.tmux.conf`
- [ ] Copy local config: `cp ~/.tmux/.tmux.conf.local ~/.tmux.conf.local`
- [ ] Install TPM: `git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm`
- [ ] Edit `.tmux.conf.local` with essential plugins
- [ ] Reload config: `tmux source-file ~/.tmux.conf`
- [ ] Test navigation: `Ctrl-h/j/k/l` (should work in vim + tmux)

### Short-term (1-2 weeks)

- [ ] Configure status line for your workflow
- [ ] Set up vim-tmux-navigator in Neovim
- [ ] Install Neovim AI plugin (sidekick.nvim or claude-code.nvim)
- [ ] Create tmux session template for your main project
- [ ] Test multi-pane setup (editor + tests + logs)
- [ ] Benchmark escape-time with `:set timeoutlen=100` in vim

### Medium-term (1 month)

- [ ] Adapt multi-agent workflow for Shipwright pipeline
- [ ] Set up git worktree pattern for parallel development
- [ ] Configure hooks for your workflow
- [ ] Implement floating popup bindings (fzf, git status)
- [ ] Set up automatic session resurrection
- [ ] Document your custom keybindings

### Long-term (ongoing)

- [ ] Monitor performance with `watch ps aux | grep tmux`
- [ ] Keep Oh My Tmux! updated (pull from upstream)
- [ ] Stay current with plugin updates (TPM: `C-a U`)
- [ ] Contribute improvements back to Shipwright
- [ ] Share your configuration with team

---

## FAQ

**Q: Do I need to use Oh My Tmux! or can I start from scratch?**
A: Oh My Tmux! is recommended for consistency and ease of updates. If you prefer minimal configs, use the templates from TMUX-QUICK-REFERENCE.md section "Minimal Production Config".

**Q: How do I integrate with existing Vim/Neovim config?**
A: Install `vim-tmux-navigator` plugin via your plugin manager, then add the keybindings from TMUX-BEST-PRACTICES-2025-2026.md section 5.1 to `.tmux.conf.local`.

**Q: Can I use this with Shipwright's daemon?**
A: Yes! See TMUX-BEST-PRACTICES-2025-2026.md section 8 for daemon-specific configuration, including vitals monitoring and cost tracking in the status line.

**Q: What's the minimum tmux version I need?**
A: tmux 3.0+ for modern features. For floating popups (display-popup), you need 3.2+. Older versions work but lack advanced features.

**Q: How do I handle mouse conflicts with AI tools?**
A: See TMUX-ARCHITECTURE.md section 7 and TMUX-BEST-PRACTICES-2025-2026.md section 3.4. Recommendation: keep mouse OFF for AI workflows, use Shift+drag when needed.

**Q: How much does tmux actually slow down my terminal?**
A: Very little. Most overhead is terminal rendering, not tmux logic. See TMUX-ARCHITECTURE.md section 11 for benchmarks.

**Q: Should I set up tmux before or after installing Claude Code?**
A: Either order works. Recommend setting up tmux first (basic config), then install Claude Code plugins. They complement each other.

---

## Notes

- All configuration snippets have been tested with tmux 3.2+ on macOS and Linux
- Plugin versions reflect active maintenance as of February 2026
- Shipwright integration examples assume Shipwright 1.x+ with daemon support
- Performance metrics are typical; actual numbers vary by system and workload

---

**Document Version**: 1.0
**Last Updated**: February 12, 2026
**Status**: Complete

For corrections, clarifications, or additions, refer to the source documents:

- TMUX-BEST-PRACTICES-2025-2026.md
- TMUX-ARCHITECTURE.md
- TMUX-QUICK-REFERENCE.md
