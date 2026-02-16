#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-role-color.sh — Set pane border color by agent role            ║
# ║                                                                         ║
# ║  Called from a tmux hook (after-select-pane) or manually.              ║
# ║  Reads #{pane_title} and sets the active border color to match the     ║
# ║  agent's role. Falls back to cyan (#00d4ff) for unknown roles.        ║
# ║                                                                         ║
# ║  Role → Color mapping:                                                 ║
# ║    leader/pm     → #00d4ff (cyan)    — command & control              ║
# ║    builder/dev   → #0066ff (blue)    — implementation                 ║
# ║    reviewer      → #f97316 (orange)  — scrutiny                       ║
# ║    tester        → #facc15 (yellow)  — validation                     ║
# ║    security      → #ef4444 (red)     — vigilance                     ║
# ║    docs/writer   → #a78bfa (violet)  — documentation                 ║
# ║    optimizer     → #4ade80 (green)   — performance                   ║
# ║    researcher    → #7c3aed (purple)  — exploration                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Get the active pane's title
PANE_TITLE="$(tmux display-message -p '#{pane_title}' 2>/dev/null || echo "")"

# Normalize to lowercase for matching
TITLE_LOWER="$(echo "$PANE_TITLE" | tr '[:upper:]' '[:lower:]')"

# Map role keywords to colors
COLOR="#00d4ff"  # default: cyan

case "$TITLE_LOWER" in
    *leader*|*lead*|*pm*|*manager*|*orchestrat*)
        COLOR="#00d4ff"  # cyan — command & control
        ;;
    *build*|*dev*|*implement*|*code*|*engineer*)
        COLOR="#0066ff"  # blue — implementation
        ;;
    *review*|*audit*|*inspect*|*oversight*)
        COLOR="#f97316"  # orange — scrutiny
        ;;
    *test*|*qa*|*validat*|*verify*)
        COLOR="#facc15"  # yellow — validation
        ;;
    *secur*|*vuln*|*threat*|*pentest*)
        COLOR="#ef4444"  # red — vigilance
        ;;
    *doc*|*writ*|*readme*|*changelog*)
        COLOR="#a78bfa"  # violet — documentation
        ;;
    *optim*|*perf*|*speed*|*deploy*)
        COLOR="#4ade80"  # green — performance/deploy
        ;;
    *research*|*explor*|*investigat*|*analyz*)
        COLOR="#7c3aed"  # purple — exploration
        ;;
esac

# Set the active pane border color
tmux set -g pane-active-border-style "fg=${COLOR},bg=#1a1a2e" 2>/dev/null || true
