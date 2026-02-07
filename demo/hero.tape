# Claude Code Teams + tmux — Hero Demo
# Records a short GIF showing the core experience
# Run: vhs demo/hero.tape

Output demo/hero.gif

Require cct
Require tmux
Require jq

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Padding 20
Set Theme { "name": "cct", "black": "#1a1a2e", "red": "#f87171", "green": "#4ade80", "yellow": "#facc15", "blue": "#0066ff", "magenta": "#7c3aed", "cyan": "#00d4ff", "white": "#e4e4e7", "brightBlack": "#71717a", "brightRed": "#f87171", "brightGreen": "#4ade80", "brightYellow": "#facc15", "brightBlue": "#0066ff", "brightMagenta": "#7c3aed", "brightCyan": "#00d4ff", "brightWhite": "#ffffff", "background": "#1a1a2e", "foreground": "#e4e4e7", "selection": "#333355", "cursor": "#00d4ff" }

# Title card
Sleep 500ms
Type "# Claude Code Teams + tmux"
Enter
Type "# 12 team templates covering the full SDLC"
Enter
Enter
Sleep 1s

# Show version
Type "cct version"
Enter
Sleep 1.5s

# Show help (overview of all commands)
Type "cct help"
Enter
Sleep 4s

# List templates (12 templates now)
Type "cct templates list"
Enter
Sleep 6s

# Show a template — security-audit to highlight new ones
Type "cct templates show security-audit"
Enter
Sleep 3s

# Doctor check
Type "cct doctor"
Enter
Sleep 4s

# Closing
Enter
Type "# Get started: github.com/sethdford/shipwright"
Enter
Sleep 2s
