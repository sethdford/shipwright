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

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
CYAN="${CYAN:-\033[38;2;0;212;255m}"
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"
BLUE="${BLUE:-\033[38;2;0;102;255m}"
GREEN="${GREEN:-\033[38;2;74;222;128m}"
YELLOW="${YELLOW:-\033[38;2;250;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
RESET="${RESET:-\033[0m}"

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
