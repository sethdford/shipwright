# Shipwright — Hero Demo
# Records a short GIF showing the core experience
# Run: vhs demo/hero.tape

Output demo/hero.gif

Require shipwright
Require tmux
Require jq

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Padding 20
Set Theme { "name": "shipwright", "black": "#1a1a2e", "red": "#f87171", "green": "#4ade80", "yellow": "#facc15", "blue": "#0066ff", "magenta": "#7c3aed", "cyan": "#00d4ff", "white": "#e4e4e7", "brightBlack": "#71717a", "brightRed": "#f87171", "brightGreen": "#4ade80", "brightYellow": "#facc15", "brightBlue": "#0066ff", "brightMagenta": "#7c3aed", "brightCyan": "#00d4ff", "brightWhite": "#ffffff", "background": "#1a1a2e", "foreground": "#e4e4e7", "selection": "#333355", "cursor": "#00d4ff" }

# Title card
Sleep 500ms
Type "# Shipwright"
Enter
Type "# Autonomous delivery — pipeline, fleet, DORA metrics, persistent memory"
Enter
Enter
Sleep 1s

# Show version
Type "shipwright version"
Enter
Sleep 1.5s

# Show help (overview of all commands including fleet, fix, memory, cost)
Type "shipwright help"
Enter
Sleep 5s

# Pipeline templates
Type "shipwright pipeline list"
Enter
Sleep 5s

# Show a pipeline in detail
Type "shipwright pipeline show autonomous"
Enter
Sleep 4s

# Doctor check
Type "shipwright doctor"
Enter
Sleep 4s

# Closing
Enter
Type "# Get started: github.com/sethdford/shipwright"
Enter
Type "# Docs: sethdford.github.io/shipwright"
Enter
Sleep 2s
