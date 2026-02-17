#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-templates.sh — Browse and inspect team templates                   ║
# ║                                                                          ║
# ║  Templates define reusable agent team configurations (roles, layout,    ║
# ║  focus areas) that shipwright session --template can use to scaffold teams.    ║
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

# ─── Template Discovery ─────────────────────────────────────────────────────
REPO_TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../tmux/templates" 2>/dev/null && pwd)" || REPO_TEMPLATES_DIR=""
USER_TEMPLATES_DIR="${HOME}/.shipwright/templates"

# Find all template directories (user dir takes priority)
find_template_dirs() {
    local dirs=()
    [[ -d "$USER_TEMPLATES_DIR" ]] && dirs+=("$USER_TEMPLATES_DIR")
    [[ -n "$REPO_TEMPLATES_DIR" && -d "$REPO_TEMPLATES_DIR" ]] && dirs+=("$REPO_TEMPLATES_DIR")
    printf '%s\n' "${dirs[@]}"
}

# Find a specific template file by name (user templates override repo)
find_template() {
    local name="$1"
    # Strip .json extension if provided
    name="${name%.json}"

    if [[ -f "$USER_TEMPLATES_DIR/${name}.json" ]]; then
        echo "$USER_TEMPLATES_DIR/${name}.json"
        return 0
    fi
    if [[ -n "$REPO_TEMPLATES_DIR" && -f "$REPO_TEMPLATES_DIR/${name}.json" ]]; then
        echo "$REPO_TEMPLATES_DIR/${name}.json"
        return 0
    fi
    return 1
}

# ─── JSON Parsing (jq preferred, grep fallback) ──────────────────────────────

# Extract a top-level string field from JSON
json_field() {
    local file="$1" field="$2"
    if command -v jq &>/dev/null; then
        jq -r ".${field} // \"\"" "$file" 2>/dev/null
    else
        grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" | head -1 | sed 's/.*: *"//;s/"$//'
    fi
}

# Extract agent count from JSON
json_agent_count() {
    local file="$1"
    if command -v jq &>/dev/null; then
        jq -r '.agents // [] | length' "$file" 2>/dev/null
    else
        grep -c '"name"' "$file" 2>/dev/null || echo "0"
    fi
}

# Print agent details from a template
print_agents() {
    local file="$1"
    if command -v jq &>/dev/null; then
        jq -r '.agents // [] | .[] | "\(.name // "?")|\(.role // "")|\(.focus // "")"' "$file" 2>/dev/null
    else
        # Best-effort grep fallback for simple cases
        grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//;s/"$//'
    fi
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_list() {
    echo ""
    echo -e "${CYAN}${BOLD}  Team Templates${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────${RESET}"
    echo ""

    local found=0

    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        for file in "$dir"/*.json; do
            [[ -f "$file" ]] || continue
            found=1

            local name description agent_count layout layout_style display_layout source
            name="$(json_field "$file" "name")"
            description="$(json_field "$file" "description")"
            agent_count="$(json_agent_count "$file")"
            layout="$(json_field "$file" "layout")"
            layout_style="$(json_field "$file" "layout_style")"
            display_layout="${layout_style:-$layout}"

            # Tag user-created vs built-in
            if [[ "$dir" == "$USER_TEMPLATES_DIR" ]]; then
                source="${PURPLE}custom${RESET}"
            else
                source="${DIM}built-in${RESET}"
            fi

            echo -e "  ${CYAN}${BOLD}${name}${RESET}  ${DIM}(${agent_count} agents, ${display_layout})${RESET}  [${source}]"
            echo -e "    ${description}"
            echo ""
        done
    done < <(find_template_dirs)

    if [[ "$found" -eq 0 ]]; then
        warn "No templates found."
        echo -e "  Templates are loaded from:"
        echo -e "    ${DIM}${USER_TEMPLATES_DIR}/${RESET}  ${DIM}(custom)${RESET}"
        [[ -n "$REPO_TEMPLATES_DIR" ]] && echo -e "    ${DIM}${REPO_TEMPLATES_DIR}/${RESET}  ${DIM}(built-in)${RESET}"
        echo ""
        return 1
    fi

    echo -e "  ${DIM}Usage: shipwright session my-feature --template <name>${RESET}"
    echo -e "  ${DIM}Details: shipwright templates show <name>${RESET}"
    echo ""
}

cmd_show() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        error "Template name required."
        echo -e "  Usage: ${DIM}shipwright templates show <name>${RESET}"
        exit 1
    fi

    local file
    if ! file="$(find_template "$name")"; then
        error "Template '${name}' not found."
        echo ""
        echo -e "  Available templates:"
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            for f in "$dir"/*.json; do
                [[ -f "$f" ]] || continue
                local tname
                tname="$(json_field "$f" "name")"
                echo -e "    ${CYAN}${tname}${RESET}"
            done
        done < <(find_template_dirs)
        echo ""
        exit 1
    fi

    local description layout layout_style main_pane_pct
    description="$(json_field "$file" "description")"
    layout="$(json_field "$file" "layout")"
    layout_style="$(json_field "$file" "layout_style")"
    main_pane_pct="$(json_field "$file" "main_pane_percent")"

    echo ""
    echo -e "  ${CYAN}${BOLD}Template: ${name}${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────${RESET}"
    echo -e "  ${description}"
    if [[ -n "$layout_style" ]]; then
        echo -e "  Layout: ${BOLD}${layout_style}${RESET} ${DIM}(leader pane ${main_pane_pct:-65}%)${RESET}"
    else
        echo -e "  Layout: ${BOLD}${layout}${RESET}"
    fi
    echo ""
    echo -e "  ${BOLD}Agents:${RESET}"

    while IFS='|' read -r aname arole afocus; do
        [[ -z "$aname" ]] && continue
        echo -e "    ${PURPLE}${BOLD}${aname}${RESET}"
        echo -e "      Role:  ${arole}"
        echo -e "      Focus: ${DIM}${afocus}${RESET}"
        echo ""
    done < <(print_agents "$file")

    echo -e "  ${DIM}Use: shipwright session my-feature --template ${name}${RESET}"
    echo ""
}

show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  shipwright templates${RESET} — Browse and inspect team templates"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    ${CYAN}shipwright templates${RESET} list              List available templates"
    echo -e "    ${CYAN}shipwright templates${RESET} show <name>       Show template details"
    echo ""
    echo -e "  ${BOLD}TEMPLATE LOCATIONS${RESET}"
    echo -e "    ${DIM}~/.shipwright/templates/${RESET}        Custom templates ${DIM}(takes priority)${RESET}"
    [[ -n "$REPO_TEMPLATES_DIR" ]] && echo -e "    ${DIM}${REPO_TEMPLATES_DIR}/${RESET}  Built-in templates"
    echo ""
    echo -e "  ${BOLD}CREATING TEMPLATES${RESET}"
    echo -e "    Drop a JSON file in ${DIM}~/.shipwright/templates/${RESET}:"
    echo ""
    echo -e "    ${DIM}{"
    echo -e "      \"name\": \"my-template\","
    echo -e "      \"description\": \"What this team does\","
    echo -e "      \"agents\": ["
    echo -e "        {\"name\": \"agent-1\", \"role\": \"Does X\", \"focus\": \"src/\"},"
    echo -e "        {\"name\": \"agent-2\", \"role\": \"Does Y\", \"focus\": \"tests/\"}"
    echo -e "      ],"
    echo -e "      \"layout\": \"tiled\""
    echo -e "    }${RESET}"
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    local subcmd="${1:-list}"
    shift 2>/dev/null || true

    case "$subcmd" in
        list|ls)      cmd_list ;;
        show|info)    cmd_show "$@" ;;
        help|--help)  show_help ;;
        *)
            error "Unknown subcommand: ${subcmd}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
