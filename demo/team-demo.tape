# Shipwright — Multi-Pane Team Demo
# Shows the tmux team experience with multiple agents working in parallel
# Run: vhs demo/team-demo.tape

Output demo/team-demo.gif

Require shipwright
Require tmux
Require jq

Set Shell "bash"
Set FontSize 12
Set Width 1600
Set Height 900
Set Padding 10
Set Theme { "name": "shipwright", "black": "#1a1a2e", "red": "#f87171", "green": "#4ade80", "yellow": "#facc15", "blue": "#0066ff", "magenta": "#7c3aed", "cyan": "#00d4ff", "white": "#e4e4e7", "brightBlack": "#71717a", "brightRed": "#f87171", "brightGreen": "#4ade80", "brightYellow": "#facc15", "brightBlue": "#0066ff", "brightMagenta": "#7c3aed", "brightCyan": "#00d4ff", "brightWhite": "#ffffff", "background": "#1a1a2e", "foreground": "#e4e4e7", "selection": "#333355", "cursor": "#00d4ff" }

# === Intro ===
Sleep 500ms
Type "# Shipwright — Agent Teams in tmux"
Enter
Type "# Three-pane layout: leader + backend + test agents"
Enter
Sleep 1.5s

# === Start tmux session ===
Type "tmux new -s dev"
Enter
Sleep 1.5s

# === Create 3-pane layout ===
# Split vertical: leader (left 65%) | agent (right 35%)
Ctrl+a
Sleep 200ms
Type "|"
Sleep 1s

# Split right pane horizontal: agent-1 (top) | agent-2 (bottom)
Ctrl+a
Sleep 200ms
Type "-"
Sleep 1s

# === Pane 2 (bottom-right) — test-agent ===
# Cursor starts here after the last split
Type "echo '--- test-agent ---'"
Enter
Sleep 500ms
Type "shipwright doctor"
Enter
Sleep 5s

# === Navigate to Pane 1 (top-right) — backend-agent ===
Ctrl+a
Sleep 200ms
Type "k"
Sleep 500ms

Type "echo '--- backend-agent ---'"
Enter
Sleep 500ms
Type "shipwright templates show feature-dev"
Enter
Sleep 4s

# === Navigate to Pane 0 (left) — leader ===
Ctrl+a
Sleep 200ms
Type "h"
Sleep 500ms

# === Leader pane: show the CLI ===
Type "shipwright version"
Enter
Sleep 1.5s

# Pipeline templates available
Type "shipwright pipeline list"
Enter
Sleep 5s

# Show pipeline detail
Type "shipwright pipeline show autonomous"
Enter
Sleep 4s

# Fleet operations preview
Type "shipwright fleet --help"
Enter
Sleep 5s

# === Closing ===
Enter
Type "# shipwright fleet start   — multi-repo daemon orchestration"
Enter
Type "# shipwright fix '...'     — bulk fix across repos"
Enter
Type "# shipwright daemon start  — autonomous GitHub issue delivery"
Enter
Sleep 3s

Type "# Docs: sethdford.github.io/shipwright"
Enter
Sleep 2s
