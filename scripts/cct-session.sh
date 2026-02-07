#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  cct-session.sh — Launch a Claude Code team session in a new tmux window║
# ║                                                                          ║
# ║  Uses new-window (NOT split-window) to avoid the tmux send-keys race    ║
# ║  condition that affects 4+ agents. See KNOWN-ISSUES.md for details.     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }

# ─── Configuration ───────────────────────────────────────────────────────────

TEAM_NAME="${1:-team-$(date +%s)}"
WINDOW_NAME="claude-${TEAM_NAME}"

# ─── Create Window ───────────────────────────────────────────────────────────

# Check if a window with this name already exists
if tmux list-windows -F '#W' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
    warn "Window '${WINDOW_NAME}' already exists. Switching to it."
    tmux select-window -t "$WINDOW_NAME"
    exit 0
fi

info "Creating team session: ${CYAN}${BOLD}${TEAM_NAME}${RESET}"

# Create a new window (not split-window — avoids race condition #23615)
# The window inherits the current pane's working directory
tmux new-window -n "$WINDOW_NAME" -c "#{pane_current_path}"

# Set the pane title so the overlay shows the team name
tmux send-keys -t "$WINDOW_NAME" "printf '\\033]2;${TEAM_NAME}-lead\\033\\\\'" Enter

# Brief pause for the title to set
sleep 0.2

# Clear the screen for a clean start
tmux send-keys -t "$WINDOW_NAME" "clear" Enter

echo ""
success "Team session ${CYAN}${BOLD}${TEAM_NAME}${RESET} ready!"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo -e "  ${CYAN}1.${RESET} Switch to window ${DIM}${WINDOW_NAME}${RESET}  ${DIM}(prefix + $(tmux list-windows -F '#I #W' | grep "$WINDOW_NAME" | cut -d' ' -f1))${RESET}"
echo -e "  ${CYAN}2.${RESET} Start Claude Code:"
echo -e "     ${DIM}claude${RESET}"
echo -e "  ${CYAN}3.${RESET} Ask Claude to create a team:"
echo -e "     ${DIM}\"Create a team with 2 agents to refactor the auth module\"${RESET}"
echo ""
echo -e "${PURPLE}${BOLD}Tip:${RESET} For file isolation between agents, use git worktrees:"
echo -e "  ${DIM}git worktree add ../project-${TEAM_NAME} -b ${TEAM_NAME}${RESET}"
echo -e "  Then launch Claude inside the worktree directory."
echo ""
echo -e "${DIM}Settings: ~/.claude/settings.json (see settings.json.template)${RESET}"
echo -e "${DIM}Keybinding: prefix + T re-runs this command${RESET}"
