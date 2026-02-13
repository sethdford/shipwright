# tmux Quick Reference 2025-2026

## Installation

```bash
# macOS
brew install tmux

# Ubuntu/Debian
sudo apt-get install tmux

# Build from source (latest features)
git clone https://github.com/tmux/tmux.git
cd tmux
./configure && make
sudo make install
```

---

## Oh My Tmux! Quick Setup

```bash
# Clone into home
git clone https://github.com/gpakosz/.tmux.git ~/.tmux
ln -s -f ~/.tmux/.tmux.conf ~/.tmux.conf

# Copy local customization file (edit this, never edit .tmux.conf)
cp ~/.tmux/.tmux.conf.local ~/.tmux.conf.local

# Edit with: vim ~/.tmux.conf.local
```

---

## Essential Keybindings (C-a prefix)

### Session Management

| Binding | Action            |
| ------- | ----------------- |
| `C-a :` | Command prompt    |
| `C-a ?` | Show keybindings  |
| `C-a d` | Detach session    |
| `C-a n` | Next window       |
| `C-a p` | Previous window   |
| `C-a l` | Last window       |
| `C-a c` | New window        |
| `C-a ,` | Rename window     |
| `C-a w` | List windows      |
| `C-a s` | List sessions     |
| `C-a $` | Rename session    |
| `C-a [` | Enter copy-mode   |
| `C-a ]` | Paste from buffer |
| `C-a r` | Reload config     |

### Pane Navigation (vim-tmux-navigator)

| Binding  | Action                |
| -------- | --------------------- |
| `C-h`    | Move left (vim/tmux)  |
| `C-j`    | Move down (vim/tmux)  |
| `C-k`    | Move up (vim/tmux)    |
| `C-l`    | Move right (vim/tmux) |
| `C-a H`  | Resize left           |
| `C-a J`  | Resize down           |
| `C-a K`  | Resize up             |
| `C-a L`  | Resize right          |
| `C-a \|` | Split vertical        |
| `C-a -`  | Split horizontal      |
| `C-a x`  | Kill pane             |
| `C-a z`  | Zoom pane (toggle)    |

### Copy Mode (vi-style)

| Binding       | Action                    |
| ------------- | ------------------------- |
| `C-a [`       | Enter copy-mode           |
| `v`           | Begin selection           |
| `y`           | Copy to buffer            |
| `Y`           | Copy entire line          |
| `H` / `L`     | Start / End of line       |
| `/` / `?`     | Search forward / backward |
| `n` / `N`     | Next / Previous match     |
| `j` / `k`     | Down / Up                 |
| `C-f` / `C-b` | Page down / Page up       |
| `Enter`       | Exit copy-mode            |

### Custom Additions (2025)

| Binding | Action                    |
| ------- | ------------------------- |
| `C-a m` | Toggle mouse mode         |
| `C-g`   | Floating scratch terminal |
| `C-s`   | Floating session switcher |
| `C-j`   | Floating git status       |
| `C-f`   | Floating file search      |
| `C-p`   | Floating process monitor  |

---

## Command-Line Essentials

### Session Operations

```bash
# Create new session (in detached mode)
tmux new-session -d -s mysession

# Attach to session
tmux attach-session -t mysession
tmux a -t mysession                    # Short form

# List sessions
tmux list-sessions
tmux ls                                # Short form

# Kill session
tmux kill-session -t mysession

# Rename session
tmux rename-session -t old-name new-name

# Switch to another session (from within tmux)
tmux switch-client -t other-session
```

### Window Operations

```bash
# Create window in existing session
tmux new-window -t mysession -n editor -c ~/project

# Send command to window
tmux send-keys -t mysession:editor "nvim main.go" Enter

# Split window
tmux split-window -h -t mysession:editor -c ~/project
tmux split-window -v -t mysession:editor -c ~/project

# Select pane
tmux select-pane -t mysession:editor.0
```

### Advanced Commands

```bash
# Capture pane output (for logs/debugging)
tmux capture-pane -t mysession:editor -p > output.txt

# Display message
tmux display-message "Hello from tmux"

# Set option
tmux set-option -g history-limit 250000

# Bind key
tmux bind-key -n C-g display-popup -E -h 50% -w 80%

# Show environment variables
tmux show-environment -t mysession
```

---

## Essential Configuration Patterns

### Minimal Production Config

```tmux
# ~/.tmux.conf

set -g default-terminal "xterm-256color"
set -as terminal-overrides ",xterm*:RGB"
set -g allow-passthrough on
set -g extended-keys on
set -g focus-events on

set -g escape-time 0
set -g history-limit 250000
set -g mouse on

unbind C-b
set -g prefix C-a
bind C-a send-prefix

bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

bind r source-file ~/.tmux.conf \; display "Reloaded!"

# Plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'christoomey/vim-tmux-navigator'
set -g @plugin 'tmux-plugins/tmux-yank'
set -g @plugin 'tmux-plugins/tmux-resurrect'

run '~/.tmux/plugins/tpm/tpm'
```

### Enable Popups (tmux 3.2+)

```tmux
# Floating scratch terminal
bind -n C-g display-popup -E -h 60% -w 80% -x C -y S \
  "cd '#{pane_current_path}' && $SHELL"

# Floating fzf session switcher
bind -n C-s display-popup -E -h 50% -w 80% -x C -y C \
  "tmux list-sessions | cut -d: -f1 | fzf | xargs tmux switch-client -t"
```

### Vim/Neovim Navigation

```tmux
is_vim="ps -o state= -o comm= -t '#{pane_tty}' | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|n?vim?x?)(diff)?$'"

bind -n C-h if-shell "$is_vim" 'send-keys C-h' 'select-pane -L'
bind -n C-j if-shell "$is_vim" 'send-keys C-j' 'select-pane -D'
bind -n C-k if-shell "$is_vim" 'send-keys C-k' 'select-pane -U'
bind -n C-l if-shell "$is_vim" 'send-keys C-l' 'select-pane -R'
```

### Status Line (Minimal)

```tmux
set -g status-style "bg=#1e1e2e,fg=#a6adc8"
set -g status-left "#{session_name} "
set -g status-right "#[fg=#7aa2f7]%H:%M#[default]"
set -g status-interval 10

set -g window-status-format " #I:#W "
set -g window-status-current-format "#[bg=#45475a,bold] #I:#W #[default]"
```

---

## Plugin Manager (TPM)

### Install TPM

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

### Common Plugins

```tmux
set -g @plugin 'tmux-plugins/tpm'                    # Plugin manager
set -g @plugin 'tmux-plugins/tmux-sensible'          # Sensible defaults
set -g @plugin 'christoomey/vim-tmux-navigator'      # Vim navigation
set -g @plugin 'tmux-plugins/tmux-yank'              # System clipboard
set -g @plugin 'tmux-plugins/tmux-resurrect'         # Persist sessions
set -g @plugin 'tmux-plugins/tmux-continuum'         # Auto-save
set -g @plugin 'NHDaly/tmux-better-mouse-mode'       # Better mouse
set -g @plugin 'aserowy/tmux.nvim'                   # Neovim integration
set -g @plugin 'tmux-plugins/tmux-fzf-url'           # Open URLs with fzf

# Plugin configuration
set -g @continuum-restore 'on'
set -g @continuum-save-interval '5'
set -g @resurrect-strategy-nvim 'session'

# Install: C-a I
# Update:  C-a U
# Remove:  C-a Alt-u

run '~/.tmux/plugins/tpm/tpm'
```

---

## Scripting Examples

### Create Multi-Pane Session

```bash
#!/bin/bash
# setup-dev.sh

SESSION="dev"
PROJECT="~/myproject"

tmux new-session -d -s $SESSION -c $PROJECT

# Window 1: Editor + Tests
tmux new-window -t $SESSION:0 -n editor
tmux send-keys -t $SESSION:editor "nvim" Enter

tmux split-window -h -t $SESSION:editor -c $PROJECT
tmux send-keys -t $SESSION:editor.1 "npm test -- --watch" Enter

# Window 2: Logs
tmux new-window -t $SESSION:1 -n logs -c $PROJECT
tmux send-keys -t $SESSION:logs "tail -f logs/*.log" Enter

# Attach
tmux attach-session -t $SESSION
```

### Multi-Agent Workflow

```bash
#!/bin/bash
# setup-agents.sh

SESSION="agents"
PROJECT="~/myproject"

# Create session
tmux new-session -d -s $SESSION -c $PROJECT

# Agent 1: Backend (git worktree)
tmux send-keys -t $SESSION \
  "git worktree add /tmp/wt-backend feat/api && cd /tmp/wt-backend && claude code" Enter

# Agent 2: Frontend (git worktree)
tmux new-window -t $SESSION -n frontend
tmux send-keys -t $SESSION:frontend \
  "git worktree add /tmp/wt-frontend feat/ui && cd /tmp/wt-frontend && claude code" Enter

# Monitor
tmux new-window -t $SESSION -n monitor
tmux send-keys -t $SESSION:monitor "shipwright status" Enter

# Orchestrator
tmux new-window -t $SESSION -n orchestrator
tmux send-keys -t $SESSION:orchestrator "watch -n 5 'shipwright vitals'" Enter

tmux attach-session -t $SESSION
```

### Send Keys from Shell

```bash
#!/bin/bash
# Auto-run tests when code changes (file watcher pattern)

SESSION="myapp"
WINDOW="tests"

while true; do
  inotifywait -e modify -r src/ && \
  tmux send-keys -t $SESSION:$WINDOW "npm test" Enter
done
```

---

## Troubleshooting

### Colors Not Working

```tmux
# Check terminal support
echo $TERM

# Fix: Use proper terminal value
set -g default-terminal "xterm-256color"
set -as terminal-overrides ",xterm*:RGB"
set -as terminal-overrides ",alacritty:RGB"
```

### Vim/Neovim ESC Delay

```tmux
# Critical fix for responsiveness
set -g escape-time 0

# Verify it's set
tmux show-option -g escape-time
```

### Mouse Selection Across Panes

```tmux
# Hold Shift while selecting text to bypass tmux capture
set -g mouse on

# OR: Disable mouse and use keyboard navigation
set -g mouse off
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
```

### Clipboard Not Working

```bash
# macOS
brew install reattach-to-user-namespace

# Linux
sudo apt-get install xclip

# Then configure in tmux:
# For macOS:
bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "pbcopy"

# For Linux:
bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "xclip -in -selection clipboard"
```

### Session Persists After Kill

```bash
# Kill all sessions and server
tmux kill-server

# Kill specific session
tmux kill-session -t mysession
```

### Check Version

```bash
tmux -V
# Output: tmux 3.2a (or similar)
```

---

## Performance Tuning

### For High-Throughput (Claude Code)

```tmux
set -g history-limit 250000           # Increase scrollback
set -g buffer-limit 20                # Keep buffers reasonable
set -g status-interval 10             # Update status every 10s (not 1s)
set -g escape-time 0                  # No ESC delay
set -g repeat-time 500                # Allow rapid key repeats
set -g allow-passthrough on           # For TUI apps
```

### Monitor Session Usage

```bash
# Watch memory/CPU in real-time
tmux capture-pane -t mysession -p | wc -l
ps aux | grep tmux | grep -v grep
```

---

## Integration with External Tools

### Git Worktree + tmux

```bash
# Create branch-specific workspace
tmux new-session -d -s feature-x

# Inside session:
git worktree add /tmp/wt-feature-x feature/x
cd /tmp/wt-feature-x
nvim

# Later, clean up:
git worktree remove /tmp/wt-feature-x
tmux kill-session -t feature-x
```

### FZF Session Switcher

```tmux
bind -n C-s display-popup -E \
  "tmux list-sessions -F '#{session_name}' | fzf | xargs tmux switch-client -t"
```

### GitHub Copilot Integration

```tmux
# In Neovim with copilot.vim plugin
bind -n C-x send-keys -t editor "i<Tab>"  # Accept suggestion
```

---

## Useful One-Liners

```bash
# List all tmux commands
tmux list-commands

# Kill all tmux sessions
tmux kill-server

# Backup session state
tmux list-sessions -F "#{session_name}" | while read s; do
  tmux list-windows -t $s
done

# Count panes in session
tmux list-panes -t mysession | wc -l

# Send same command to all panes in window
tmux send-keys -t mysession C-a :set-window-option synchronize-panes on Enter

# Capture pane and write to file with timestamp
tmux capture-pane -t mysession -p > ~/tmux-$(date +%s).log

# Watch a pane in real-time
watch -n 0.5 "tmux capture-pane -t mysession:0 -p"

# Find the pane with a specific command
tmux list-panes -a -F "#{pane_id} #{pane_current_command}" | grep "nvim"
```

---

## Version Compatibility

| Feature               | Min Version | Status                |
| --------------------- | ----------- | --------------------- |
| `display-popup`       | 3.2+        | Floating windows      |
| `allow-passthrough`   | 3.2+        | DEC 2026 sync         |
| `extended-keys`       | 3.0+        | Alt key support       |
| `if-shell` versioning | 2.4+        | %if syntax            |
| `focus-events`        | 2.2+        | Window focus tracking |
| `set-clipboard`       | 3.2+        | Native OSC 52         |

---

## Additional Resources

| Resource             | Link                                              |
| -------------------- | ------------------------------------------------- |
| Official Manual      | https://man7.org/linux/man-pages/man1/tmux.1.html |
| GitHub Repository    | https://github.com/tmux/tmux                      |
| Oh My Tmux!          | https://github.com/gpakosz/.tmux                  |
| Awesome tmux         | https://github.com/rothgar/awesome-tmux           |
| Plugin Manager (TPM) | https://github.com/tmux-plugins/tpm               |

---

**Quick Tip**: Always reload config after editing with `C-a r` or `tmux source-file ~/.tmux.conf`

**Pro Tip**: Use session names that match your projects for faster switching (`myapp-dev`, `myapp-api`, etc.)

**Claude Code Tip**: Set up one tmux window per agent, use git worktrees for isolation, and monitor with `shipwright status`
