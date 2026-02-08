# Shipwright — Full Demo
# Records a comprehensive walkthrough of all features
# Run: vhs demo/full-demo.tape

Output demo/full-demo.gif

Require shipwright
Require tmux
Require jq

Set Shell "bash"
Set FontSize 13
Set Width 1400
Set Height 800
Set Padding 16
Set Theme { "name": "shipwright", "black": "#1a1a2e", "red": "#f87171", "green": "#4ade80", "yellow": "#facc15", "blue": "#0066ff", "magenta": "#7c3aed", "cyan": "#00d4ff", "white": "#e4e4e7", "brightBlack": "#71717a", "brightRed": "#f87171", "brightGreen": "#4ade80", "brightYellow": "#facc15", "brightBlue": "#0066ff", "brightMagenta": "#7c3aed", "brightCyan": "#00d4ff", "brightWhite": "#ffffff", "background": "#1a1a2e", "foreground": "#e4e4e7", "selection": "#333355", "cursor": "#00d4ff" }

# === Section 1: Overview ===
Sleep 500ms
Type "# === Shipwright ==="
Enter
Type "# Autonomous delivery — pipeline, fleet, DORA metrics, persistent memory"
Enter
Enter
Sleep 1s

Type "shipwright version"
Enter
Sleep 1.5s

# === Section 2: Quick Setup ===
Enter
Type "# --- Quick Setup (one command, no prompts) ---"
Enter
Sleep 500ms
Type "# shipwright init  <-- installs tmux config + overlay + templates"
Enter
Sleep 2s

# === Section 3: Health Check ===
Enter
Type "# --- Health Check ---"
Enter
Sleep 500ms
Type "shipwright doctor"
Enter
Sleep 5s

# === Section 4: Team Templates ===
Enter
Type "# --- Team Templates (12 covering full SDLC) ---"
Enter
Sleep 500ms
Type "shipwright templates list"
Enter
Sleep 7s

Type "shipwright templates show feature-dev"
Enter
Sleep 3s

Type "shipwright templates show security-audit"
Enter
Sleep 3s

# === Section 5: Pipeline Templates ===
Enter
Type "# --- Pipeline Templates (8 delivery workflows) ---"
Enter
Sleep 500ms
Type "shipwright pipeline list"
Enter
Sleep 5s

# === Section 6: CLI Overview ===
Enter
Type "# --- Full CLI ---"
Enter
Sleep 500ms
Type "shipwright help"
Enter
Sleep 5s

# === Section 7: Continuous Loop ===
Enter
Type "# --- Continuous Agent Loop ---"
Enter
Sleep 500ms
Type "# Autonomous development with test verification and audit:"
Enter
Type '# shipwright loop "Build user auth" --test-cmd "npm test" --audit'
Enter
Sleep 2s
Type "# Multi-agent with quality gates:"
Enter
Type '# shipwright loop "Refactor API" --agents 3 --quality-gates'
Enter
Sleep 2s

# === Section 8: Cost Intelligence ===
Enter
Type "# --- Cost Intelligence ---"
Enter
Sleep 500ms
Type "# shipwright cost show               <-- 7-day cost summary"
Enter
Type "# shipwright cost show --by-stage    <-- breakdown by pipeline stage"
Enter
Type "# shipwright cost budget set 50.00   <-- set daily budget ($50/day)"
Enter
Type "# shipwright cost budget show        <-- check remaining budget"
Enter
Sleep 3s

# === Section 9: Fleet Operations ===
Enter
Type "# --- Fleet Operations (multi-repo orchestration) ---"
Enter
Sleep 500ms
Type "# shipwright fleet init    <-- generate fleet-config.json"
Enter
Type "# shipwright fleet start   <-- start daemons for all repos"
Enter
Type "# shipwright fleet status  <-- fleet-wide dashboard"
Enter
Type "# shipwright fleet metrics <-- aggregate DORA metrics"
Enter
Sleep 3s

# === Section 10: Bulk Fix ===
Enter
Type "# --- Bulk Fix (same fix across repos) ---"
Enter
Sleep 500ms
Type '# shipwright fix "Update lodash" --repos ~/api,~/web,~/mobile'
Enter
Type '# shipwright fix "Bump Node 22" --repos-from repos.txt --pipeline hotfix'
Enter
Sleep 3s

# === Section 11: Layout Presets ===
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
Type "# Docs: sethdford.github.io/shipwright"
Enter
Type "# MIT License | v1.7.0"
Enter
Sleep 3s
