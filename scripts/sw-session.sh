#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-session.sh — Launch a Claude Code team session in a new tmux window║
# ║                                                                          ║
# ║  Uses new-window (NOT split-window) to avoid the tmux send-keys race    ║
# ║  condition that affects 4+ agents. See KNOWN-ISSUES.md for details.     ║
# ║                                                                          ║
# ║  Supports --template to scaffold from a team template and --terminal    ║
# ║  to select a terminal adapter (tmux, iterm2, wezterm).                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="2.3.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

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

# ─── Parse Arguments ────────────────────────────────────────────────────────

TEAM_NAME=""
TEMPLATE_NAME=""
TERMINAL_ADAPTER=""
AUTO_LAUNCH=true
DRY_RUN=false
SKIP_PERMISSIONS="auto"
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
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-permissions)
            SKIP_PERMISSIONS=true
            shift
            ;;
        --no-skip-permissions)
            SKIP_PERMISSIONS=false
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
            echo -e "  ${CYAN}--skip-permissions${RESET}     Pass --dangerously-skip-permissions (default with agents)"
            echo -e "  ${CYAN}--no-skip-permissions${RESET}  Require permission prompts even with agents"
            echo -e "  ${CYAN}--dry-run${RESET}              Print team prompt and launcher script, don't create anything"
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

# ─── Template Suggestion ──────────────────────────────────────────────────────

suggest_template() {
    local goal="$1" templates_dir="$2"
    local best="" best_score=0
    [[ -d "$templates_dir" ]] || return 1

    local goal_lower
    goal_lower=$(echo "$goal" | tr '[:upper:]' '[:lower:]')

    for tpl in "$templates_dir"/*.json; do
        [[ -f "$tpl" ]] || continue
        local name score=0
        name=$(jq -r '.name // ""' "$tpl" 2>/dev/null) || continue

        while IFS= read -r kw; do
            [[ -z "$kw" ]] && continue
            if echo "$goal_lower" | grep -qi "$kw"; then
                score=$((score + 1))
            fi
        done < <(jq -r '(.keywords // []) | .[]' "$tpl" 2>/dev/null)

        if [[ $score -gt $best_score ]]; then
            best_score=$score
            best="$name"
        fi
    done

    [[ $best_score -gt 0 ]] && echo "$best"
}

# ─── Template Auto-Suggestion ────────────────────────────────────────────
if [[ -z "$TEMPLATE_NAME" && -n "$GOAL" ]]; then
    REPO_TPL_DIR="$(cd "$SCRIPT_DIR/../tmux/templates" 2>/dev/null && pwd)" || REPO_TPL_DIR=""
    USER_TPL_DIR="${HOME}/.shipwright/templates"
    SUGGESTED=""

    if [[ -d "$USER_TPL_DIR" ]]; then
        SUGGESTED=$(suggest_template "$GOAL" "$USER_TPL_DIR") || true
    fi
    if [[ -z "$SUGGESTED" && -n "$REPO_TPL_DIR" ]]; then
        SUGGESTED=$(suggest_template "$GOAL" "$REPO_TPL_DIR") || true
    fi

    if [[ -n "$SUGGESTED" ]]; then
        info "Auto-suggesting template: ${PURPLE}${BOLD}${SUGGESTED}${RESET}"
        TEMPLATE_NAME="$SUGGESTED"
    fi
fi

# ─── Template Loading ───────────────────────────────────────────────────────

TEMPLATE_FILE=""
TEMPLATE_LAYOUT=""
TEMPLATE_LAYOUT_STYLE=""
TEMPLATE_MAIN_PANE_PERCENT=""
TEMPLATE_DESC=""
TEMPLATE_AGENTS=()  # Populated as "name|role|focus" entries

if [[ -n "$TEMPLATE_NAME" ]]; then
    # Search for template: user dir first, then repo dir
    USER_TEMPLATES_DIR="${HOME}/.shipwright/templates"
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

    # Validate template parsed correctly — if jq failed, TEMPLATE_AGENTS is empty
    if [[ ${#TEMPLATE_AGENTS[@]} -eq 0 ]]; then
        error "Template '${TEMPLATE_NAME}' parsed with no agents. Check template JSON."
        echo -e "  ${DIM}File: ${TEMPLATE_FILE}${RESET}"
        exit 1
    fi

    echo -e "  ${DIM}${TEMPLATE_DESC}${RESET}"
    echo -e "  ${DIM}Agents: ${#TEMPLATE_AGENTS[@]}  Layout: ${TEMPLATE_LAYOUT}${RESET}"
fi

# ─── Resolve Permissions ──────────────────────────────────────────────────
# Default: skip permissions when agents are being spawned (autonomous teams)
if [[ "$SKIP_PERMISSIONS" == "auto" ]]; then
    if [[ ${#TEMPLATE_AGENTS[@]} -gt 0 || -n "$GOAL" ]]; then
        SKIP_PERMISSIONS=true
    else
        SKIP_PERMISSIONS=false
    fi
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
    local project_dir
    project_dir="$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || pwd)"

    local memory_context=""
    if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        memory_context=$(bash "$SCRIPT_DIR/sw-memory.sh" inject "build" 2>/dev/null) || true
    fi

    if [[ ${#TEMPLATE_AGENTS[@]} -gt 0 ]]; then
        if [[ -n "$GOAL" ]]; then
            prompt="GOAL: ${GOAL}"
            prompt+=$'\n\n'
        fi

        prompt+="You are the team lead for \"${TEAM_NAME}\". You are in: ${project_dir}"
        prompt+=$'\n\n'"Follow these steps:"
        prompt+=$'\n'"1. Call TeamCreate with team_name=\"${TEAM_NAME}\""
        prompt+=$'\n'"2. Create tasks using TaskCreate for each agent's work"
        prompt+=$'\n'"3. Spawn each agent using the Task tool with team_name=\"${TEAM_NAME}\" and the agent name below"
        prompt+=$'\n'"4. Assign tasks using TaskUpdate with owner set to each agent's name"
        prompt+=$'\n'"5. Coordinate work and monitor progress"
        prompt+=$'\n\n'"Agents to spawn:"

        for agent_entry in "${TEMPLATE_AGENTS[@]}"; do
            IFS='|' read -r aname arole afocus <<< "$agent_entry"
            prompt+=$'\n'"- name=\"${aname}\": ${arole}"
            if [[ -n "$afocus" ]]; then
                prompt+=". Focus on files: ${afocus}"
            fi
        done

        prompt+=$'\n\n'"Give each agent a detailed prompt describing their role and which files they own. Agents should work on DIFFERENT files to avoid merge conflicts."
    else
        # No template — simple team creation prompt
        if [[ -n "$GOAL" ]]; then
            prompt="GOAL: ${GOAL}"
            prompt+=$'\n\n'"You are the team lead for \"${TEAM_NAME}\". You are in: ${project_dir}"
            prompt+=$'\n\n'"Follow these steps:"
            prompt+=$'\n'"1. Call TeamCreate with team_name=\"${TEAM_NAME}\""
            prompt+=$'\n'"2. Decide the right number and types of agents for this goal"
            prompt+=$'\n'"3. Create tasks using TaskCreate, then spawn agents with the Task tool (team_name=\"${TEAM_NAME}\")"
            prompt+=$'\n'"4. Assign tasks and coordinate work"
            prompt+=$'\n\n'"Assign different files to each agent to avoid merge conflicts."
        fi
    fi

    if [[ -n "$prompt" ]]; then
        if [[ -n "$memory_context" ]]; then
            prompt+=$'\n\n'"Historical context (lessons from previous runs):"
            prompt+=$'\n'"${memory_context}"
        fi

        prompt+=$'\n\n'"IMPORTANT: Read .claude/CLAUDE.md for project-specific conventions, patterns, and instructions."
    fi

    echo "$prompt"
}

# ─── Dry Run ────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == true ]]; then
    TEAM_PROMPT="$(build_team_prompt)"
    PROJECT_DIR="$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || pwd)"
    DRY_RUN_FLAGS=""
    [[ "$SKIP_PERMISSIONS" == true ]] && DRY_RUN_FLAGS=" --dangerously-skip-permissions"

    echo -e "${CYAN}${BOLD}═══ Team Prompt ═══${RESET}"
    echo ""
    if [[ -n "$TEAM_PROMPT" ]]; then
        echo "$TEAM_PROMPT"
    else
        echo -e "${DIM}(empty — no template or goal specified)${RESET}"
    fi

    echo ""
    echo -e "${CYAN}${BOLD}═══ Launcher Script ═══${RESET}"
    echo ""
    if [[ -n "$TEAM_PROMPT" ]]; then
        cat << EOF
#!/usr/bin/env bash
# Auto-generated by shipwright session — safe to delete
cd ${PROJECT_DIR} || exit 1
printf '\\033]2;${TEAM_NAME}-lead\\033\\\\'
PROMPT=\$(cat <prompt-file>)
rm -f <prompt-file> "\$0"
claude${DRY_RUN_FLAGS} "\$PROMPT"
echo ""
echo "Claude exited. Type 'claude' to restart, or 'exit' to close."
exec "\$SHELL" -l
EOF
    else
        cat << EOF
#!/usr/bin/env bash
cd ${PROJECT_DIR} || exit 1
printf '\\033]2;${TEAM_NAME}-lead\\033\\\\'
rm -f "\$0"
claude${DRY_RUN_FLAGS}
echo ""
echo "Claude exited. Type 'claude' to restart, or 'exit' to close."
exec "\$SHELL" -l
EOF
    fi

    echo ""
    echo -e "${DIM}Window name: ${WINDOW_NAME}${RESET}"
    echo -e "${DIM}Terminal adapter: ${TERMINAL_ADAPTER}${RESET}"
    echo -e "${DIM}Auto-launch: ${AUTO_LAUNCH}${RESET}"
    exit 0
fi

# ─── Create Session ──────────────────────────────────────────────────────────

if [[ "$TERMINAL_ADAPTER" == "tmux" ]]; then
    # ─── tmux session creation ─────────────────────────────────────────────
    # Uses launcher script passed to `tmux new-window` as command argument
    # to eliminate the send-keys race condition (shell startup vs keystrokes).

    # Secure temp directory — restrictive permissions for prompt/launcher files
    SECURE_TMPDIR=$(mktemp -d) || { error "Cannot create temp dir"; exit 1; }
    chmod 700 "$SECURE_TMPDIR"
    trap 'rm -rf "$SECURE_TMPDIR"' EXIT

    # Check if a window with this name already exists
    if tmux list-windows -F '#W' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
        warn "Window '${WINDOW_NAME}' already exists. Switching to it."
        tmux select-window -t "$WINDOW_NAME"
        exit 0
    fi

    info "Creating team session: ${CYAN}${BOLD}${TEAM_NAME}${RESET}"
    if [[ "$SKIP_PERMISSIONS" == true ]]; then
        warn "${YELLOW}--dangerously-skip-permissions enabled${RESET}"
    fi

    # Resolve project directory (use current pane's path)
    PROJECT_DIR="$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || pwd)"

    TEAM_PROMPT="$(build_team_prompt)"

    if [[ "$AUTO_LAUNCH" == true && -n "$TEAM_PROMPT" ]]; then
        info "Launching Claude Code with team setup..."

        # Write prompt to a file (avoids all quoting/escaping issues)
        PROMPT_FILE="$SECURE_TMPDIR/prompt.txt"
        printf '%s' "$TEAM_PROMPT" > "$PROMPT_FILE"

        # Build launcher — quoted heredoc (no expansion), then sed for variables.
        # When claude exits, falls back to interactive shell so pane stays alive.
        LAUNCHER="$SECURE_TMPDIR/launcher.sh"
        cat > "$LAUNCHER" << 'LAUNCHER_STATIC'
#!/usr/bin/env bash
# Auto-generated by shipwright session — safe to delete
cd __DIR__ || exit 1
printf '\033]2;__TEAM__-lead\033\\'
PROMPT=$(cat __PROMPT__)
rm -f __PROMPT__ "$0"
claude __CLAUDE_FLAGS__ "$PROMPT"
echo ""
echo "Claude exited. Type 'claude' to restart, or 'exit' to close."
exec "$SHELL" -l
LAUNCHER_STATIC
        CLAUDE_FLAGS=""
        if [[ "$SKIP_PERMISSIONS" == true ]]; then
            CLAUDE_FLAGS="--dangerously-skip-permissions"
        fi
        # Use awk for safe string replacement — sed breaks on & | \ in paths
        awk -v dir="$PROJECT_DIR" -v team="$TEAM_NAME" -v prompt="$PROMPT_FILE" -v flags="$CLAUDE_FLAGS" \
            '{gsub(/__DIR__/, dir); gsub(/__TEAM__/, team); gsub(/__PROMPT__/, prompt); gsub(/__CLAUDE_FLAGS__/, flags); print}' \
            "$LAUNCHER" > "${LAUNCHER}.tmp" && mv "${LAUNCHER}.tmp" "$LAUNCHER"
        chmod +x "$LAUNCHER"

        # Create window with command — no race condition!
        # bash --login loads PATH (needed for ~/.local/bin/claude)
        if ! tmux new-window -n "$WINDOW_NAME" -c "$PROJECT_DIR" \
            "bash --login ${LAUNCHER}"; then
            error "Failed to create tmux window '${WINDOW_NAME}'"
            exit 1
        fi

    elif [[ "$AUTO_LAUNCH" == true && -z "$TEAM_PROMPT" ]]; then
        # No template and no goal — just launch claude interactively
        info "Launching Claude Code..."

        LAUNCHER="$SECURE_TMPDIR/launcher.sh"
        cat > "$LAUNCHER" << 'LAUNCHER_STATIC'
#!/usr/bin/env bash
cd __DIR__ || exit 1
printf '\033]2;__TEAM__-lead\033\\'
rm -f "$0"
claude __CLAUDE_FLAGS__
echo ""
echo "Claude exited. Type 'claude' to restart, or 'exit' to close."
exec "$SHELL" -l
LAUNCHER_STATIC
        CLAUDE_FLAGS=""
        if [[ "$SKIP_PERMISSIONS" == true ]]; then
            CLAUDE_FLAGS="--dangerously-skip-permissions"
        fi
        # Use awk for safe string replacement — sed breaks on & | \ in paths
        awk -v dir="$PROJECT_DIR" -v team="$TEAM_NAME" -v flags="$CLAUDE_FLAGS" \
            '{gsub(/__DIR__/, dir); gsub(/__TEAM__/, team); gsub(/__CLAUDE_FLAGS__/, flags); print}' \
            "$LAUNCHER" > "${LAUNCHER}.tmp" && mv "${LAUNCHER}.tmp" "$LAUNCHER"
        chmod +x "$LAUNCHER"

        if ! tmux new-window -n "$WINDOW_NAME" -c "$PROJECT_DIR" \
            "bash --login ${LAUNCHER}"; then
            error "Failed to create tmux window '${WINDOW_NAME}'"
            exit 1
        fi

    else
        # --no-launch: create window with a regular shell
        tmux new-window -n "$WINDOW_NAME" -c "$PROJECT_DIR"
        info "Window ready. Launch Claude manually: ${DIM}claude${RESET}"
    fi

    # Apply dark theme after a brief delay to ensure the shell has started.
    # Without this, select-pane -P can race with shell initialization and
    # the styling may not apply to the final pane state.
    {
        sleep 0.3
        tmux select-pane -t "$WINDOW_NAME" -P 'bg=#1a1a2e,fg=#e4e4e7' 2>/dev/null || true
    } &

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
