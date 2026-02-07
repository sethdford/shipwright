# Claude Code Teams + tmux — Full Demo
# Records a comprehensive walkthrough of all features
# Run: vhs demo/full-demo.tape

Output demo/full-demo.gif

Require cct
Require tmux
Require jq

Set Shell "bash"
Set FontSize 13
Set Width 1400
Set Height 800
Set Padding 16
Set Theme { "name": "cct", "black": "#1a1a2e", "red": "#f87171", "green": "#4ade80", "yellow": "#facc15", "blue": "#0066ff", "magenta": "#7c3aed", "cyan": "#00d4ff", "white": "#e4e4e7", "brightBlack": "#71717a", "brightRed": "#f87171", "brightGreen": "#4ade80", "brightYellow": "#facc15", "brightBlue": "#0066ff", "brightMagenta": "#7c3aed", "brightCyan": "#00d4ff", "brightWhite": "#ffffff", "background": "#1a1a2e", "foreground": "#e4e4e7", "selection": "#333355", "cursor": "#00d4ff" }

# === Section 1: Overview ===
Sleep 500ms
Type "# === Claude Code Teams + tmux ==="
Enter
Type "# 12 team templates covering the full SDLC"
Enter
Enter
Sleep 1s

Type "cct version"
Enter
Sleep 1.5s

# === Section 2: Quick Setup ===
Enter
Type "# --- Quick Setup (one command, no prompts) ---"
Enter
Sleep 500ms
Type "# cct init  <-- installs tmux config + overlay + templates"
Enter
Sleep 2s

# === Section 3: Health Check ===
Enter
Type "# --- Health Check ---"
Enter
Sleep 500ms
Type "cct doctor"
Enter
Sleep 5s

# === Section 4: Templates ===
Enter
Type "# --- Team Templates (12 covering full SDLC) ---"
Enter
Sleep 500ms
Type "cct templates list"
Enter
Sleep 7s

Type "cct templates show security-audit"
Enter
Sleep 3s

Type "cct templates show bug-fix"
Enter
Sleep 3s

Type "cct templates show feature-dev"
Enter
Sleep 3s

# === Section 5: CLI Overview ===
Enter
Type "# --- Full CLI ---"
Enter
Sleep 500ms
Type "cct help"
Enter
Sleep 4s

# === Section 6: Continuous Loop ===
Enter
Type "# --- Continuous Agent Loop ---"
Enter
Sleep 500ms
Type "# Autonomous development with test verification and audit:"
Enter
Type '# cct loop "Build user auth" --test-cmd "npm test" --audit'
Enter
Sleep 2s
Type "# Multi-agent with quality gates:"
Enter
Type '# cct loop "Refactor API" --agents 3 --quality-gates'
Enter
Sleep 2s
Type "# Resume an interrupted session:"
Enter
Type "# cct loop --resume"
Enter
Sleep 2s

# === Section 7: Layout Presets ===
Enter
Type "# --- Layout Presets ---"
Enter
Sleep 500ms
Type "# prefix + M-1  main-horizontal (leader 65% left)"
Enter
Type "# prefix + M-2  main-vertical (leader 60% top)"
Enter
Type "# prefix + M-3  tiled (equal sizes)"
Enter
Sleep 3s

# === Closing ===
Enter
Enter
Type "# github.com/sethdford/shipwright"
Enter
Type "# MIT License | v1.4.0"
Enter
Sleep 3s
