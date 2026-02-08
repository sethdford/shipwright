#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  cct-session.sh — Launch a Claude Code team session in a new tmux window║
# ║                                                                          ║
# ║  Uses new-window (NOT split-window) to avoid the tmux send-keys race    ║
# ║  condition that affects 4+ agents. See KNOWN-ISSUES.md for details.     ║
# ║                                                                          ║
# ║  Supports --template to scaffold from a team template and --terminal    ║
# ║  to select a terminal adapter (tmux, iterm2, wezterm).                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

# ─── Parse Arguments ────────────────────────────────────────────────────────

TEAM_NAME=""
TEMPLATE_NAME=""
TERMINAL_ADAPTER=""
AUTO_LAUNCH=true
GOAL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --template|-t)
            TEMPLATE_NAME="${2:-}"
            [[ -z "$TEMPLATE_NAME" ]] && { error "Missing template name after --template"; exit 1; }
            shift 2
            ;;
        --terminal)
            TERMINAL_ADAPTER="${2:-}"
            [[ -z "$TERMINAL_ADAPTER" ]] && { error "Missing adapter name after --terminal"; exit 1; }
            shift 2
            ;;
        --goal|-g)
            GOAL="${2:-}"
            [[ -z "$GOAL" ]] && { error "Missing goal after --goal"; exit 1; }
            shift 2
            ;;
        --no-launch)
            AUTO_LAUNCH=false
            shift
            ;;
        --help|-h)
            echo -e "${CYAN}${BOLD}shipwright session${RESET} — Create and launch a team session"
            echo ""
            echo -e "${BOLD}USAGE${RESET}"
            echo -e "  shipwright session [name] [--template <name>] [--goal \"...\"]"
            echo ""
            echo -e "${BOLD}OPTIONS${RESET}"
            echo -e "  ${CYAN}--template, -t${RESET} <name>   Use a team template (see: shipwright templates list)"
            echo -e "  ${CYAN}--goal, -g${RESET} <text>       Goal for the team (what to build/fix/refactor)"
            echo -e "  ${CYAN}--terminal${RESET} <adapter>    Terminal adapter: tmux (default), iterm2, wezterm"
            echo -e "  ${CYAN}--no-launch${RESET}             Create window only, don't auto-launch Claude"
            echo ""
            echo -e "${BOLD}EXAMPLES${RESET}"
            echo -e "  ${DIM}shipwright session auth-refactor -t feature-dev -g \"Refactor auth to use JWT\"${RESET}"
            echo -e "  ${DIM}shipwright session my-feature --template feature-dev${RESET}"
            echo -e "  ${DIM}shipwright session bugfix -t bug-fix -g \"Fix login timeout issue\"${RESET}"
            echo -e "  ${DIM}shipwright session explore --no-launch${RESET}"
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            exit 1
            ;;
        *)
            # Positional: team name
            [[ -z "$TEAM_NAME" ]] && TEAM_NAME="$1" || { error "Unexpected argument: $1"; exit 1; }
            shift
            ;;
    esac
done

TEAM_NAME="${TEAM_NAME:-team-$(date +%s)}"
WINDOW_NAME="claude-${TEAM_NAME}"

# ─── Template Loading ───────────────────────────────────────────────────────

TEMPLATE_FILE=""
TEMPLATE_LAYOUT=""
TEMPLATE_LAYOUT_STYLE=""
TEMPLATE_MAIN_PANE_PERCENT=""
TEMPLATE_DESC=""
TEMPLATE_AGENTS=()  # Populated as "name|role|focus" entries

if [[ -n "$TEMPLATE_NAME" ]]; then
    # Search for template: user dir first, then repo dir
    USER_TEMPLATES_DIR="${HOME}/.claude-teams/templates"
    REPO_TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../tmux/templates" 2>/dev/null && pwd)" || REPO_TEMPLATES_DIR=""

    TEMPLATE_NAME="${TEMPLATE_NAME%.json}"

    if [[ -f "$USER_TEMPLATES_DIR/${TEMPLATE_NAME}.json" ]]; then
        TEMPLATE_FILE="$USER_TEMPLATES_DIR/${TEMPLATE_NAME}.json"
    elif [[ -n "$REPO_TEMPLATES_DIR" && -f "$REPO_TEMPLATES_DIR/${TEMPLATE_NAME}.json" ]]; then
        TEMPLATE_FILE="$REPO_TEMPLATES_DIR/${TEMPLATE_NAME}.json"
    else
        error "Template '${TEMPLATE_NAME}' not found."
        echo -e "  Run ${DIM}shipwright templates list${RESET} to see available templates."
        exit 1
    fi

    info "Loading template: ${PURPLE}${BOLD}${TEMPLATE_NAME}${RESET}"

    # Parse template — single jq call extracts all fields + agents in one pass
    if command -v jq &>/dev/null; then
        # Single jq call: outputs metadata lines then agent lines
        # Format: META<tab>field<tab>value for metadata, AGENT<tab>name|role|focus for agents
        while IFS=$'\t' read -r tag key value; do
            case "$tag" in
                META)
                    case "$key" in
                        description)       TEMPLATE_DESC="$value" ;;
                        layout)            TEMPLATE_LAYOUT="$value" ;;
                        layout_style)      TEMPLATE_LAYOUT_STYLE="$value" ;;
                        main_pane_percent) TEMPLATE_MAIN_PANE_PERCENT="$value" ;;
                    esac
                    ;;
                AGENT) [[ -n "$key" ]] && TEMPLATE_AGENTS+=("$key") ;;
            esac
        done < <(jq -r '
            "META\tdescription\t\(.description // "")",
            "META\tlayout\t\(.layout // "tiled")",
            "META\tlayout_style\t\(.layout_style // "")",
            "META\tmain_pane_percent\t\(.main_pane_percent // "")",
            (.agents // [] | .[] | "AGENT\t\(.name)|\(.role // "")|\(.focus // "")\t")
        ' "$TEMPLATE_FILE")
    else
        error "jq is required for template parsing."
        echo -e "  ${DIM}brew install jq${RESET}"
        exit 1
    fi

    echo -e "  ${DIM}${TEMPLATE_DESC}${RESET}"
    echo -e "  ${DIM}Agents: ${#TEMPLATE_AGENTS[@]}  Layout: ${TEMPLATE_LAYOUT}${RESET}"
fi

# ─── Resolve Terminal Adapter ───────────────────────────────────────────────

# Auto-detect if not specified
if [[ -z "$TERMINAL_ADAPTER" ]]; then
    TERMINAL_ADAPTER="tmux"
fi

ADAPTER_FILE="$SCRIPT_DIR/adapters/${TERMINAL_ADAPTER}-adapter.sh"
if [[ -f "$ADAPTER_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ADAPTER_FILE"
else
    # Default to inline tmux behavior (backwards compatible)
    if [[ "$TERMINAL_ADAPTER" != "tmux" ]]; then
        error "Terminal adapter '${TERMINAL_ADAPTER}' not found."
        echo -e "  Available: tmux (default), iterm2, wezterm"
        echo -e "  Adapter dir: ${DIM}${SCRIPT_DIR}/adapters/${RESET}"
        exit 1
    fi
fi

# ─── Build Team Prompt ───────────────────────────────────────────────────────
# Claude Code's TeamCreate + Task tools handle pane creation automatically.
# We create ONE window, launch claude with a team setup prompt, and let
# Claude orchestrate the agents. No pre-splitting needed.

build_team_prompt() {
    local prompt=""

    if [[ ${#TEMPLATE_AGENTS[@]} -gt 0 ]]; then
        prompt="Create a team called \"${TEAM_NAME}\" and spawn these agents as teammates using the Task tool with team_name=\"${TEAM_NAME}\":"
        prompt+=$'\n'

        for agent_entry in "${TEMPLATE_AGENTS[@]}"; do
            IFS='|' read -r aname arole afocus <<< "$agent_entry"
            prompt+=$'\n'"- Agent named \"${aname}\": ${arole}"
            if [[ -n "$afocus" ]]; then
                prompt+=". Focus on files: ${afocus}"
            fi
        done

        prompt+=$'\n\n'"Give each agent a detailed prompt describing their role and which files they own. Agents should work on DIFFERENT files to avoid merge conflicts."

        if [[ -n "$GOAL" ]]; then
            prompt+=$'\n\n'"The team goal is: ${GOAL}"
        fi
    else
        # No template — simple team creation prompt
        if [[ -n "$GOAL" ]]; then
            prompt="Create a team called \"${TEAM_NAME}\" to accomplish this goal: ${GOAL}"
            prompt+=$'\n\n'"Decide the right number and types of agents, create tasks, and spawn them as teammates. Assign different files to each agent to avoid conflicts."
        fi
    fi

    echo "$prompt"
}

# ─── Create Session ──────────────────────────────────────────────────────────

if [[ "$TERMINAL_ADAPTER" == "tmux" ]]; then
    # ─── tmux session creation ─────────────────────────────────────────────
    # Uses launcher script passed to `tmux new-window` as command argument
    # to eliminate the send-keys race condition (shell startup vs keystrokes).

    # Check if a window with this name already exists
    if tmux list-windows -F '#W' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
        warn "Window '${WINDOW_NAME}' already exists. Switching to it."
        tmux select-window -t "$WINDOW_NAME"
        exit 0
    fi

    info "Creating team session: ${CYAN}${BOLD}${TEAM_NAME}${RESET}"

    # Resolve project directory (use current pane's path)
    PROJECT_DIR="$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || pwd)"

    TEAM_PROMPT="$(build_team_prompt)"

    if [[ "$AUTO_LAUNCH" == true && -n "$TEAM_PROMPT" ]]; then
        info "Launching Claude Code with team setup..."

        # Write prompt to a file (avoids all quoting/escaping issues)
        PROMPT_FILE="/tmp/shipwright-prompt-${TEAM_NAME}.txt"
        printf '%s' "$TEAM_PROMPT" > "$PROMPT_FILE"

        # Build launcher — quoted heredoc (no expansion), then sed for variables.
        # When claude exits, falls back to interactive shell so pane stays alive.
        LAUNCHER="/tmp/shipwright-launch-${TEAM_NAME}.sh"
        cat > "$LAUNCHER" << 'LAUNCHER_STATIC'
#!/usr/bin/env bash
# Auto-generated by shipwright session — safe to delete
cd __DIR__ || exit 1
printf '\033]2;__TEAM__-lead\033\\'
PROMPT=$(cat __PROMPT__)
rm -f __PROMPT__ "$0"
claude "$PROMPT"
echo ""
echo "Claude exited. Type 'claude' to restart, or 'exit' to close."
exec "$SHELL" -l
LAUNCHER_STATIC
        sed "s|__DIR__|${PROJECT_DIR}|g;s|__TEAM__|${TEAM_NAME}|g;s|__PROMPT__|${PROMPT_FILE}|g" \
            "$LAUNCHER" > "${LAUNCHER}.tmp" && mv "${LAUNCHER}.tmp" "$LAUNCHER"
        chmod +x "$LAUNCHER"

        # Create window with command — no race condition!
        # bash --login loads PATH (needed for ~/.local/bin/claude)
        tmux new-window -n "$WINDOW_NAME" -c "$PROJECT_DIR" \
            "bash --login ${LAUNCHER}"

    elif [[ "$AUTO_LAUNCH" == true && -z "$TEAM_PROMPT" ]]; then
        # No template and no goal — just launch claude interactively
        info "Launching Claude Code..."

        LAUNCHER="/tmp/shipwright-launch-${TEAM_NAME}.sh"
        cat > "$LAUNCHER" << 'LAUNCHER_STATIC'
#!/usr/bin/env bash
cd __DIR__ || exit 1
printf '\033]2;__TEAM__-lead\033\\'
rm -f "$0"
claude
echo ""
echo "Claude exited. Type 'claude' to restart, or 'exit' to close."
exec "$SHELL" -l
LAUNCHER_STATIC
        sed "s|__DIR__|${PROJECT_DIR}|g;s|__TEAM__|${TEAM_NAME}|g" \
            "$LAUNCHER" > "${LAUNCHER}.tmp" && mv "${LAUNCHER}.tmp" "$LAUNCHER"
        chmod +x "$LAUNCHER"

        tmux new-window -n "$WINDOW_NAME" -c "$PROJECT_DIR" \
            "bash --login ${LAUNCHER}"

    else
        # --no-launch: create window with a regular shell
        tmux new-window -n "$WINDOW_NAME" -c "$PROJECT_DIR"
        info "Window ready. Launch Claude manually: ${DIM}claude${RESET}"
    fi

    # Apply dark theme (safe to run immediately — no race with pane content)
    tmux select-pane -t "$WINDOW_NAME" -P 'bg=#1a1a2e,fg=#e4e4e7'

elif [[ -f "$ADAPTER_FILE" ]] && type -t spawn_agent &>/dev/null; then
    # ─── Non-tmux adapter session (iterm2, wezterm, etc.) ──────────────────
    info "Creating team session: ${CYAN}${BOLD}${TEAM_NAME}${RESET} ${DIM}(${TERMINAL_ADAPTER})${RESET}"

    # Spawn leader only — Claude Code handles agent pane creation
    spawn_agent "${TEAM_NAME}-lead" "#{pane_current_path}" ""

else
    error "Terminal adapter '${TERMINAL_ADAPTER}' not available."
    exit 1
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
success "Team session ${CYAN}${BOLD}${TEAM_NAME}${RESET} launched!"

if [[ ${#TEMPLATE_AGENTS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BOLD}Team from template ${PURPLE}${TEMPLATE_NAME}${RESET}${BOLD}:${RESET}"
    echo -e "  ${CYAN}${BOLD}lead${RESET}  ${DIM}— Team coordinator (Claude Code)${RESET}"
    for agent_entry in "${TEMPLATE_AGENTS[@]}"; do
        IFS='|' read -r aname arole afocus <<< "$agent_entry"
        echo -e "  ${PURPLE}${BOLD}${aname}${RESET}  ${DIM}— ${arole}${RESET}"
    done
    if [[ -n "$GOAL" ]]; then
        echo ""
        echo -e "${BOLD}Goal:${RESET} ${GOAL}"
    fi
fi

if [[ "$AUTO_LAUNCH" == true ]]; then
    echo ""
    echo -e "${GREEN}${BOLD}Claude Code is starting in window ${DIM}${WINDOW_NAME}${RESET}"
    echo -e "${DIM}Claude will create the team, spawn agents in their own panes, and begin work.${RESET}"
    WIN_NUM="$(tmux list-windows -F '#I #W' 2>/dev/null | grep "$WINDOW_NAME" | cut -d' ' -f1)" || WIN_NUM="?"
    echo -e "${DIM}Switch to it: prefix + ${WIN_NUM}${RESET}"
else
    echo ""
    echo -e "${BOLD}Next steps:${RESET}"
    WIN_NUM="$(tmux list-windows -F '#I #W' 2>/dev/null | grep "$WINDOW_NAME" | cut -d' ' -f1)" || WIN_NUM="?"
    echo -e "  ${CYAN}1.${RESET} Switch to window ${DIM}${WINDOW_NAME}${RESET}  ${DIM}(prefix + ${WIN_NUM})${RESET}"
    echo -e "  ${CYAN}2.${RESET} Start ${DIM}claude${RESET} and ask it to create a team"
fi

echo ""
echo -e "${DIM}Keybinding: prefix + T re-runs this command${RESET}"
