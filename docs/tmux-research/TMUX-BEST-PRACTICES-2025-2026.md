# Best-in-Class tmux Configuration Report 2025-2026

**Date**: February 2026
**Scope**: Modern tmux configurations, plugins, patterns, and integrations for developers and AI agent workflows

---

## Executive Summary

tmux in 2025-2026 has evolved from a terminal multiplexer for remote server access to a full-featured **terminal-native IDE replacement**. The most compelling use cases now involve:

- **Multi-agent AI workflows**: Parallel Claude Code sessions with git worktrees + tmux windows
- **Persistent development environments**: Session resurrection across restarts with tmux-continuum
- **Seamless Neovim integration**: vim-tmux-navigator + Neovim AI plugins (claude-code.nvim, sidekick.nvim)
- **Floating popup workflows**: Quick tasks without disrupting main layout (display-popup, fzf integration)
- **DORA metrics monitoring**: Real-time pipeline vitals in tmux status line

---

## 1. Core Configuration Patterns

### 1.1 The Gold Standard: Oh My Tmux! (gpakosz/.tmux)

**Status**: Actively maintained as of 2025, 100+ contributors
**Philosophy**: Never edit the main config; customize via `.tmux.conf.local`

**Why it's best-in-class**:

- Dual prefix support (C-a + C-b)
- Powerline-inspired theming with custom separators
- Pane maximization without losing splits
- SSH-aware status line
- Vim-style keybindings out of the box

**Install**:

```bash
git clone https://github.com/gpakosz/.tmux.git ~/.tmux
ln -s -f ~/.tmux/.tmux.conf ~/.tmux.conf
cp ~/.tmux/.tmux.conf.local ~/.tmux.conf.local  # Customize this file only
```

### 1.2 Essential Core Configuration Snippet

```tmux
# ~/.tmux.conf or ~/.tmux.conf.local

# Platform compatibility with conditional configuration
%if "#{==:#{client_termname},screen}"
  # Fallback for older terminals
  set -g default-terminal "screen-256color"
%else
  # Modern terminal with TrueColor support
  set -g default-terminal "xterm-256color"
  set -as terminal-overrides ",xterm*:RGB"
%endif

# Prefix and basic bindings
unbind C-b
set -g prefix C-a
bind C-a send-prefix
set -g prefix2 C-b  # Secondary prefix for nested sessions

# Core performance settings
set -g escape-time 0           # Critical for Neovim responsiveness
set -g history-limit 250000    # Claude Code generates high output volume
set -g buffer-limit 20         # Keep memory usage reasonable
set -g mouse on                # Toggle with: prefix + m

# DEC 2026 synchronized output (eliminates TUI flicker)
set -g allow-passthrough on

# Extended keys for TUI apps (Alt combos work correctly)
set -g extended-keys on

# Focus events for TUI apps (responsive to window focus)
set -g focus-events on

# Clipboard integration (OSC 52 - works across SSH and nesting)
set -g set-clipboard on

# Key mode configuration
setw -g mode-keys vi
setw -g status-keys emacs      # Insert-style completion in command mode
```

### 1.3 Conditional Version Detection

```tmux
# Check tmux version and gate features accordingly
run-shell "tmux setenv -g TMUX_VERSION $(tmux -V | cut -d' ' -f2)"

# Version-gated configuration
%if "#{>=:#{version},3.1}"
  # tmux 3.1+ features (popup windows, better hooks)
  set -g pane-border-status top
  set -g pane-border-format "#{pane_index}: #{pane_title}"
%endif

%if "#{>=:#{version},3.2}"
  # tmux 3.2+ features (enhanced popup, display-popup improvements)
  # Floating scratch terminal
  bind -n C-g display-popup -E -h 50% -w 80% -x C -y S \
    "cd '#{pane_current_path}' && $SHELL"
%endif
```

---

## 2. Status Line Best Practices (Minimal & Informative)

### 2.1 Philosophy: Less is More

**Key principles**:

- Display only information you glance at: session name, window list, time
- Avoid status line fatigue with colors/animations
- Keep update frequency low to reduce CPU

### 2.2 Production Status Line Configuration

```tmux
# Status bar appearance
set -g status-position top
set -g status-style "bg=#1e1e2e,fg=#a6adc8"
set -g status-left-length 50
set -g status-right-length 100

# Left: Session name + branch indicator
set -g status-left "#{?session_grouped,#[fg=#f38ba8],} #{session_name} "

# Right: System info (minimal)
set -g status-right "#(whoami)@#{hostname_ssh} │ %H:%M #[fg=#7aa2f7](%a)#[default]"

# Center: Window list with current pane indicator
set -g window-status-format " #I:#W#{?window_zoomed_flag,🔍,} "
set -g window-status-current-format "#[bg=#45475a,bold,fg=#a6adc8] #I:#W#{?window_zoomed_flag,🔍,} #[default]"
set -g window-status-last-style "fg=#6c7086"

# Status bar update frequency (reduce CPU by checking less often)
set -g status-interval 5

# Disable status bar by default, enable in specific scenarios
# set -g status off
# bind -n C-s set -g status  # Toggle status on demand

# Battery indicator (if running on laptop)
# Requires: brew install battery or apt-get install acpi
# set -g status-right "#{battery_percentage} │ #(date '+%a %H:%M')"
```

### 2.3 Minimal Theme for Neovim Integration

```tmux
# Minimalist status line for Neovim workflows
# (Vim takes up visual real estate, minimize tmux competition)

set -g status-style "bg=#0a0e27,fg=#abb2bf"
set -g status-left "#[fg=#61afef,bold]#{session_name}#[default] "
set -g status-right "#[fg=#98c379]%H:%M#[default]"
set -g status-justify left

# Hide pane borders unless zoomed
set -g pane-border-style "fg=#3b4048"
set -g pane-active-border-style "fg=#61afef,bold"
set -g pane-border-status off
set -g pane-border-indicators off
```

---

## 3. Advanced Features

### 3.1 Tmux Hooks for Automation

**Available hooks** (tmux 2.4+):

```tmux
# Session lifecycle hooks
set-hook -g session-created 'display-message "Session #{session_name} created"'
set-hook -g session-closed 'display-message "Session #{session_name} closed"'

# Window/pane lifecycle
set-hook -g window-linked 'display-message "Window #{window_index} linked"'
set-hook -g pane-exited 'display-message "Pane exited with code: #{pane_exit_status}"'

# Smart automation: Auto-rename windows to match current command
set-hook -g pane-mode-changed 'select-window -t #{window_index}'
set -g automatic-rename on
set -g automatic-rename-format "#{pane_current_command}#{?pane_in_mode,[#{pane_mode}],}"

# Agent-team pattern: Auto-create a heartbeat pane on new session
set-hook -g after-new-session 'new-window -t #{session_name} -n "heartbeat" "watch -n 1 date"'
```

**Important caveat**: `pane-exited` only fires if `remain-on-exit` is off and the pane process actually exits (not forcibly killed).

### 3.2 Copy-Mode Optimization for TUI Apps

```tmux
# Copy mode bindings (vi-style)
bind -T copy-mode-vi v send-keys -X begin-selection
bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
bind -T copy-mode-vi Y send-keys -X copy-line
bind -T copy-mode-vi H send-keys -X start-of-line
bind -T copy-mode-vi L send-keys -X end-of-line
bind -T copy-mode-vi C-b send-keys -X page-up
bind -T copy-mode-vi C-f send-keys -X page-down
bind -T copy-mode-vi C-d send-keys -X halfpage-down
bind -T copy-mode-vi C-u send-keys -X halfpage-up

# Critical for TUI: Don't interfere with mouse selection in focused panes
# Users must hold Shift to select text across pane boundaries
set -g mouse on
# Note: With mouse on, Shift+drag selects and bypasses tmux capture

# Enhanced copy with system clipboard integration
# Requires: xclip (Linux) or pbcopy (macOS)
%if "#{==:#{client_platform},darwin}"
  # macOS
  bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "pbcopy"
  bind -T copy-mode-vi Y send-keys -X copy-pipe-and-cancel "pbcopy"
%else
  # Linux (requires: apt-get install xclip)
  bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "xclip -in -selection clipboard"
  bind -T copy-mode-vi Y send-keys -X copy-pipe-and-cancel "xclip -in -selection clipboard"
%endif

# Scroll wheel behavior in copy mode
bind -n WheelUpPane select-window -t:= \; send-keys -M -t:= -X scroll-up
bind -n WheelDownPane select-window -t:= \; send-keys -M -t:= -X scroll-down
```

### 3.3 Floating Popup Windows (display-popup)

**Requires**: tmux 3.2+

```tmux
# Floating scratch terminal
bind -n C-g display-popup -E -h 60% -w 80% -x C -y S \
  "cd #{pane_current_path} && $SHELL"

# Floating git status
bind -n C-j display-popup -E -h 40% -w 100% -x 0 -y S \
  "cd #{pane_current_path} && git status"

# Floating fzf session switcher
bind -n C-s display-popup -E -h 50% -w 80% -x C -y C \
  "tmux list-sessions | grep -v '^#{session_name}' | cut -d: -f1 | fzf --preview 'tmux capture-pane -t {} -p' | xargs -r tmux switch-client -t"

# Floating command history with fzf
bind -n C-h display-popup -E -h 60% -w 80% -x C -y C \
  "history 1 | fzf --reverse --preview 'echo {}' | awk '{$1=$2=$3=$4=$5=$6=$7=$8=\"\"; print $0}' | xargs -r read CMD && eval $CMD"

# Floating file search (ag/rg)
bind -n C-f display-popup -E -h 50% -w 80% -x C -y C \
  "cd #{pane_current_path} && rg --files --hidden | fzf --preview 'cat {}' --preview-window 'right:60%' | xargs -r $EDITOR"

# Floating process monitor
bind -n C-p display-popup -E -h 60% -w 100% -x 0 -y S \
  "watch -c -n 1 'ps aux --width=200 | head -20'"
```

### 3.4 Mouse Mode Considerations

```tmux
# For AI tools where mouse interferes with text selection:

# Option A: Keep mouse OFF, but enable Alt+Arrow navigation
set -g mouse off
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R

# Option B: Toggle mouse with prefix + m (useful for pair programming)
bind m set -g mouse \; display-message "Mouse mode: #{?mouse,ON,OFF}"

# Option C: Smart mouse detection (enable in macOS Terminal, disable in iTerm2)
%if "#{==:#{client_platform},darwin}"
  # iTerm2 users: disable mouse to avoid selection conflicts with AI tools
  set -g mouse off
%else
  # Linux with X11 forwarding: enable mouse
  set -g mouse on
%endif
```

---

## 4. Plugin Ecosystem 2025-2026

### 4.1 Essential Plugins (TPM)

**Install TPM** (Tmux Plugin Manager):

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

**Recommended plugin configuration**:

```tmux
# List plugins (append to .tmux.conf)
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'christoomey/vim-tmux-navigator'
set -g @plugin 'tmux-plugins/tmux-yank'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'NHDaly/tmux-better-mouse-mode'
set -g @plugin 'aserowy/tmux.nvim'
set -g @plugin 'tmux-plugins/tmux-fzf-url'
set -g @plugin 'tmux-plugins/tmux-prefix-highlight'

# Plugin configurations
set -g @resurrect-strategy-nvim 'session'
set -g @continuum-restore 'on'
set -g @continuum-save-interval '5'  # Auto-save every 5 minutes

# Install plugins: prefix + I
# Update plugins: prefix + U
# Uninstall: prefix + Alt + U

run '~/.tmux/plugins/tpm/tpm'
```

### 4.2 New Tools for 2025-2026

| Tool               | Purpose                           | Use Case                              |
| ------------------ | --------------------------------- | ------------------------------------- |
| **dmux** (Rust)    | Configurable workspace manager    | Multi-agent setups with git worktrees |
| **sessionx**       | FZF session switcher with preview | Quick context switching               |
| **sesh**           | Intelligent session manager       | Auto-detect project types             |
| **tmux-which-key** | Popup menu for keybindings        | Discoverability without cheat sheet   |
| **treemux** (Rust) | File explorer sidebar             | Visual file navigation like Nvim-Tree |
| **harpoon**        | Bookmarking sessions/files        | Jump to important contexts            |
| **laio**           | Flexbox-inspired layout manager   | Modern, declarative pane layouts      |

**Example: sessionx installation**:

```bash
npm install -g @sessionx/cli
# Then: sessionx
```

---

## 5. Neovim + AI Agent Integration

### 5.1 vim-tmux-navigator Setup

```tmux
# Enable seamless pane/window navigation
is_vim="ps -o state= -o comm= -t '#{pane_tty}' | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|n?vim?x?)(diff)?$'"

bind -n C-h if-shell "$is_vim" 'send-keys C-h' 'select-pane -L'
bind -n C-j if-shell "$is_vim" 'send-keys C-j' 'select-pane -D'
bind -n C-k if-shell "$is_vim" 'send-keys C-k' 'select-pane -U'
bind -n C-l if-shell "$is_vim" 'send-keys C-l' 'select-pane -R'

# Neovim back-navigation
bind -n C-\ if-shell "$is_vim" 'send-keys C-\\' 'select-pane -l'
```

### 5.2 Claude Code + Neovim Integration

**Plugins that work well with Claude Code + tmux**:

1. **claude-code.nvim** (Lua plugin):

   ```lua
   -- Send file/selection to Claude pane
   require('claude-code').setup({
     claude_pane = "claude-1",  -- Pane with Claude Code session
     keymaps = {
       send_file = "<leader>cf",
       send_selection = "<leader>cs",
       send_command = "<leader>cc",
     }
   })
   ```

2. **sidekick.nvim** (folke):

   ```lua
   require('sidekick').setup({
     backend = 'tmux',  -- Persistent backend
     provider = 'claude',
     auto_suggestions = true,
   })
   ```

3. **avante.nvim** (Multi-provider):
   ```lua
   require('avante').setup({
     provider = 'claude',
     auto_suggestions_provider = 'claude',
     file_selector = {
       provider = 'native',
     },
   })
   ```

### 5.3 Multi-Agent Workflow Pattern

```tmux
# .tmux.conf for coordinating multiple Claude agents

# Create a session with isolated workspaces (git worktrees)
# Usage: tmux new-session -s multi-agent

# Window 1: Orchestrator (supervisor)
new-window -t multi-agent -n orchestrator -c ~/project
send-keys -t multi-agent:orchestrator "shipwright status" Enter

# Window 2: Agent 1 (frontend task, branch: feat/ui-v2)
new-window -t multi-agent -n agent-1 -c ~/project
send-keys -t multi-agent:agent-1 "git worktree add /tmp/wt-ui feat/ui-v2 && cd /tmp/wt-ui" Enter
send-keys -t multi-agent:agent-1 "claude code" Enter

# Window 3: Agent 2 (backend task, branch: feat/api-v2)
new-window -t multi-agent -n agent-2 -c ~/project
send-keys -t multi-agent:agent-2 "git worktree add /tmp/wt-api feat/api-v2 && cd /tmp/wt-api" Enter
send-keys -t multi-agent:agent-2 "claude code" Enter

# Window 4: Tests (monitoring)
new-window -t multi-agent -n tests -c ~/project
send-keys -t multi-agent:tests "npm test -- --watch" Enter

# Bind keys for quick agent switching
bind -n C-1 select-window -t multi-agent:agent-1
bind -n C-2 select-window -t multi-agent:agent-2
bind -n C-0 select-window -t multi-agent:orchestrator
```

---

## 6. Performance Tuning for High-Throughput

### 6.1 Configuration for Claude Code (High Output Scenarios)

```tmux
# Handle Claude's massive output volume
set -g history-limit 250000     # Increase scrollback (Claude Code generates lots of output)
set -g buffer-limit 20          # Keep clipboard buffers reasonable
set -g message-limit 100        # Limit queued messages

# Reduce status bar update frequency under load
set -g status-interval 10       # Check status every 10s instead of 1s

# Optimize for responsive panes (critical for interactive tools)
set -g escape-time 0            # No ESC-key delay
set -g repeat-time 500          # Allow rapid repeat bindings

# Lazy rendering (tmux 3.3+)
# set -g do-not-render-on-key-presses off  # Default: render immediately

# Monitor output in background panes
set-hook -g pane-exited 'send-keys -t "{left}" q'  # Auto-cleanup on pane exit
```

### 6.2 System Resource Monitoring in Status Line

```tmux
# Optional: Add lightweight system monitoring
# Requires: brew install tmux-mem-cpu-load (macOS)
# or: apt-get install python3-psutil (Linux)

set -g status-right "#[fg=#a6adc8]#(tmux-mem-cpu-load --powerline-right --interval 10)#[default] │ #[fg=#7aa2f7]%H:%M#[default]"
```

---

## 7. CI/CD and Automation Patterns

### 7.1 Automated Session Setup Script

```bash
#!/bin/bash
# setup-dev-session.sh - Create reproducible dev environment

SESSION="dev-env"
PROJECT_ROOT="$1"

# Kill existing session
tmux kill-session -t $SESSION 2>/dev/null

# Create new session
tmux new-session -d -s $SESSION -x 200 -y 50 -c "$PROJECT_ROOT"

# Window 1: Editor
tmux new-window -t $SESSION:1 -n editor -c "$PROJECT_ROOT"
tmux send-keys -t $SESSION:editor "nvim" Enter

# Window 2: Build/Tests
tmux new-window -t $SESSION:2 -n build -c "$PROJECT_ROOT"
tmux send-keys -t $SESSION:build "npm test -- --watch" Enter

# Window 3: Logs
tmux new-window -t $SESSION:3 -n logs -c "$PROJECT_ROOT"
tmux send-keys -t $SESSION:logs "tail -f logs/*.log" Enter

# Window 4: Scratch (floating)
tmux new-window -t $SESSION:4 -n scratch -c "$PROJECT_ROOT"

# Attach
tmux attach-session -t $SESSION
```

### 7.2 GitHub Actions Integration with tmux

```yaml
# .github/workflows/agent-pipeline.yml
name: Autonomous Pipeline

on: [pull_request, issues]

jobs:
  pipeline:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup tmux for pipeline
        run: |
          sudo apt-get install -y tmux
          # Create isolated session for this run
          tmux new-session -d -s pipe-${{ github.run_id }} -c $GITHUB_WORKSPACE

      - name: Run agents in tmux
        run: |
          tmux send-keys -t pipe-${{ github.run_id }} \
            "shipwright pipeline start --issue ${{ github.event.issue.number }}" Enter

          # Wait for completion (with timeout)
          timeout 3600 bash -c "
            while tmux list-sessions | grep -q pipe-${{ github.run_id }}; do
              sleep 5
            done
          "

      - name: Capture logs
        if: always()
        run: |
          tmux capture-pane -t pipe-${{ github.run_id }} -p > /tmp/pipeline.log 2>/dev/null || true
          cat /tmp/pipeline.log
```

---

## 8. Shipwright-Specific tmux Configuration

### 8.1 tmux Setup for Shipwright Daemon

```tmux
# ~/.tmux.conf.local (project-specific, checked into .claude/tmux.conf)

# Color scheme for Shipwright panes
set -g @pipeline-running-color "colour33"     # Blue - pipeline active
set -g @pipeline-success-color "colour2"      # Green - success
set -g @pipeline-failed-color "colour160"     # Red - failed

# Status bar shows pipeline health
set -g status-right "#{?#{pane_current_command}=shipwright,🚀,} │ #{?session_attached,👥,} │ #[fg=#a6adc8]%H:%M#[default]"

# Pane borders show vitals status
set -g @vitals-threshold-high "0.8"           # 80% = yellow
set -g @vitals-threshold-critical "0.95"      # 95% = red

# Bind keys for common pipeline operations
bind -n C-p send-keys -t orchestrator "shipwright pipeline start --issue $(gh issue list --jq '.[0].number')" Enter
bind -n C-d send-keys -t daemon "shipwright daemon start" Enter
bind -n C-v send-keys -t monitor "shipwright vitals" Enter
bind -n C-m send-keys -t memory "shipwright memory show" Enter
```

### 8.2 Agent Team Pane Layout Template

```tmux
# Create a Shipwright team session with 4 agents
# Usage: tmux new-session -s team-feature -c $PROJECT

# Main window (orchestrator)
split-window -h
send-keys -t team-feature:0.0 "shipwright status" Enter
send-keys -t team-feature:0.1 "shipwright logs main --follow" Enter

# Agent windows (separate by file domain)
new-window -t team-feature -n backend "cd /tmp/wt-backend && claude code"
new-window -t team-feature -n frontend "cd /tmp/wt-frontend && claude code"
new-window -t team-feature -n tests "cd /tmp/wt-tests && npm test -- --watch"
new-window -t team-feature -n docs "cd /tmp/wt-docs && vim CLAUDE.md"

# Set pane titles for tmux status line
set-pane-title -t team-feature:orchestrator.0 "orchestrator-status"
set-pane-title -t team-feature:orchestrator.1 "orchestrator-logs"

# Key shortcuts for team operations
bind -n C-PageUp previous-window
bind -n C-PageDown next-window
bind -n S-C-Left swap-window -t -1
bind -n S-C-Right swap-window -t +1
```

---

## 9. Best Practices Summary

| Category           | Best Practice                                                                     |
| ------------------ | --------------------------------------------------------------------------------- |
| **Configuration**  | Never edit core config; customize via `.tmux.conf.local` (Oh My Tmux! pattern)    |
| **Performance**    | Set `escape-time 0` for Neovim, increase `history-limit` to 250K for Claude       |
| **Status Line**    | Keep minimal (session, windows, time); avoid animations; update every 5-10s       |
| **Copy Mode**      | Bind vi-style keys; use Shift+drag to select across panes with mouse on           |
| **Popups**         | Use display-popup (3.2+) for floating scratch, fzf, and file search               |
| **Hooks**          | Use after-new-session, pane-exited for automation; test hook side effects         |
| **Plugins**        | Use TPM; essential: vim-tmux-navigator, tmux-yank, tmux-resurrect, tmux-continuum |
| **AI Integration** | Combine git worktrees + tmux windows; one agent per window, one session per task  |
| **Mouse**          | Trade-off: useful for pair programming, conflicts with text selection in TUI apps |
| **CI/CD**          | Use tmux in headless mode; capture output with capture-pane; timeout long runs    |

---

## 10. Configuration Templates

### 10.1 Minimal Production Config

```tmux
# ~/.tmux.conf - Minimal, battle-tested setup

set -g default-terminal "xterm-256color"
set -as terminal-overrides ",xterm*:RGB"
set -g allow-passthrough on
set -g extended-keys on
set -g focus-events on
set -g mouse on

set -g escape-time 0
set -g history-limit 250000
set -g status-interval 10

unbind C-b
set -g prefix C-a
bind C-a send-prefix

# Panes
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"

# Navigation
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# Resize
bind H resize-pane -L 5
bind J resize-pane -D 5
bind K resize-pane -U 5
bind L resize-pane -R 5

# Reload config
bind r source-file ~/.tmux.conf \; display "Config reloaded!"

# Statusline
set -g status-style "bg=#1e1e2e,fg=#a6adc8"
set -g status-left "#{session_name} "
set -g status-right "%H:%M"

# Plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'christoomey/vim-tmux-navigator'
set -g @plugin 'tmux-plugins/tmux-yank'
set -g @plugin 'tmux-plugins/tmux-resurrect'

run '~/.tmux/plugins/tpm/tpm'
```

### 10.2 Full-Featured Config for AI Development

```tmux
# ~/.tmux.conf - Full-featured for Claude Code + Neovim

# === CORE ===
set -g default-terminal "xterm-256color"
set -as terminal-overrides ",xterm*:RGB,alacritty:RGB"
set -g allow-passthrough on
set -g extended-keys on
set -g focus-events on
set -g set-clipboard on

set -g escape-time 0
set -g history-limit 250000
set -g buffer-limit 20
set -g mouse on
set -g pane-border-indicators off

# === PREFIX ===
unbind C-b
set -g prefix C-a
bind C-a send-prefix
set -g prefix2 C-b

# === WINDOWS & PANES ===
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"
bind , command-prompt "rename-window '%%'"
set -g automatic-rename on
set -g automatic-rename-format "#{pane_current_command}"

# === NAVIGATION ===
is_vim="ps -o state= -o comm= -t '#{pane_tty}' | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|n?vim?x?)(diff)?$'"

bind -n C-h if-shell "$is_vim" 'send-keys C-h' 'select-pane -L'
bind -n C-j if-shell "$is_vim" 'send-keys C-j' 'select-pane -D'
bind -n C-k if-shell "$is_vim" 'send-keys C-k' 'select-pane -U'
bind -n C-l if-shell "$is_vim" 'send-keys C-l' 'select-pane -R'
bind -n C-\ if-shell "$is_vim" 'send-keys C-\\' 'select-pane -l'

# === RESIZE ===
bind H resize-pane -L 5
bind J resize-pane -D 5
bind K resize-pane -U 5
bind L resize-pane -R 5

# === POPUP ===
%if "#{>=:#{version},3.2}"
bind -n C-g display-popup -E -h 50% -w 80% -x C -y S \
  "cd '#{pane_current_path}' && $SHELL"
bind -n C-s display-popup -E -h 60% -w 80% -x C -y C \
  "tmux list-sessions -F '#{session_name}' | fzf | xargs -r tmux switch-client -t"
%endif

# === COPY MODE ===
bind -T copy-mode-vi v send-keys -X begin-selection
bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
%if "#{==:#{client_platform},darwin}"
bind -T copy-mode-vi Y send-keys -X copy-pipe-and-cancel "pbcopy"
%else
bind -T copy-mode-vi Y send-keys -X copy-pipe-and-cancel "xclip -in -selection clipboard"
%endif

# === STATUS ===
set -g status-style "bg=#1e1e2e,fg=#a6adc8"
set -g status-left-length 50
set -g status-right-length 100
set -g status-left "#{?session_grouped,#[fg=#f38ba8],} #{session_name} "
set -g status-right "#{?pane_in_mode,#[fg=#f38ba8]MODE#[default] │,}#[fg=#7aa2f7]%H:%M#[default]"
set -g status-interval 10

set -g window-status-format " #I:#W "
set -g window-status-current-format "#[bg=#45475a,bold] #I:#W #[default]"

# === HOOKS ===
set-hook -g window-linked 'if-shell "[[ #{window_index} -gt 1 ]]" "set-window-option -t #{window_id} automatic-rename off"'

# === PLUGINS ===
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-yank'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'aserowy/tmux.nvim'

set -g @resurrect-strategy-nvim 'session'
set -g @continuum-restore 'on'
set -g @continuum-save-interval '5'

run '~/.tmux/plugins/tpm/tpm'
```

---

## 11. Resources & References

### Official Documentation

- [tmux Manual](https://man7.org/linux/man-pages/man1/tmux.1.html) - Complete reference
- [GitHub tmux/tmux](https://github.com/tmux/tmux) - Official repo, release notes

### Popular Configs & Frameworks

- [Oh my tmux!](https://github.com/gpakosz/.tmux) - Best-in-class starting point (actively maintained 2025)
- [Awesome tmux](https://github.com/rothgar/awesome-tmux) - Curated resource list
- [tao-of-tmux](https://tao-of-tmux.readthedocs.io/) - Comprehensive guide

### AI Integration

- [claude-code.nvim](https://github.com/dreemanuel/claude-code.nvim) - Neovim + Claude Code + tmux
- [sidekick.nvim](https://github.com/folke/sidekick.nvim) - Neovim AI sidekick with tmux backend
- [avante.nvim](https://github.com/yetone/avante.nvim) - Multi-provider AI in Neovim

### Plugins

- [TPM](https://github.com/tmux-plugins/tpm) - Plugin manager
- [vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator) - Seamless pane navigation
- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) - Persist and restore sessions
- [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) - Auto-save sessions

### Multi-Agent Workflows

- [Shipwright](https://github.com/sethdford/shipwright) - Autonomous agent pipeline orchestration
- [multi-agent-workflow-kit](https://github.com/laris-co/multi-agent-workflow-kit) - Reusable patterns
- [workmux](https://github.com/raine/workmux) - git worktrees + tmux windows

---

## Appendix: Version Compatibility Matrix

| Feature                | Min Version | Notes                                    |
| ---------------------- | ----------- | ---------------------------------------- |
| `allow-passthrough`    | 3.2+        | DEC 2026 synchronized output             |
| `extended-keys`        | 3.0+        | Proper Alt key handling                  |
| `display-popup`        | 3.2+        | Floating window support                  |
| `pane-border-status`   | 3.0+        | Pane-level status lines                  |
| `if-shell` versioning  | 2.4+        | Use `%if` for 2.4+, `if-shell` for older |
| `set-clipboard`        | 3.2+        | Native OSC 52 clipboard                  |
| `focus-events`         | 2.2+        | TUI focus tracking                       |
| `copy-pipe-and-cancel` | 2.5+        | Enhanced copy behavior                   |

---

**Last Updated**: February 2026
**Tested On**: macOS 13+, Ubuntu 22.04+, Fedora 38+
**tmux Versions**: 3.2+ (recommended), 3.0+ (acceptable), 2.9 (legacy support)
