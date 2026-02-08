#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  wezterm-adapter.sh — Terminal adapter for WezTerm pane management      ║
# ║                                                                          ║
# ║  Uses `wezterm cli` to spawn panes/tabs with named titles and working   ║
# ║  directories. Cross-platform.                                            ║
# ║  Sourced by cct-session.sh — exports: spawn_agent, list_agents,         ║
# ║  kill_agent, focus_agent.                                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Verify wezterm CLI is available
if ! command -v wezterm &>/dev/null; then
    echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m wezterm CLI not found. Install WezTerm first." >&2
    exit 1
fi

# Track spawned pane IDs for agent management (file-based for bash 3.2 compat)
_WEZTERM_PANE_MAP="${TMPDIR:-/tmp}/shipwright-wezterm-pane-map.$$"
: > "$_WEZTERM_PANE_MAP"
trap 'rm -f "$_WEZTERM_PANE_MAP"' EXIT

spawn_agent() {
    local name="$1"
    local working_dir="${2:-$PWD}"
    local command="${3:-}"

    # Resolve working_dir — tmux format won't work here
    if [[ "$working_dir" == *"pane_current_path"* || "$working_dir" == "." ]]; then
        working_dir="$PWD"
    fi

    local pane_id

    # Spawn a new pane in the current tab (split right by default)
    local pane_count
    pane_count=$(wc -l < "$_WEZTERM_PANE_MAP" 2>/dev/null | tr -d ' ')
    pane_count="${pane_count:-0}"
    if [[ "$pane_count" -eq 0 ]]; then
        # First agent: create a new tab
        pane_id=$(wezterm cli spawn --cwd "$working_dir" 2>/dev/null)
    else
        # Subsequent agents: split from the first pane
        local first_pane
        first_pane=$(head -1 "$_WEZTERM_PANE_MAP" 2>/dev/null | cut -d= -f2-)
        pane_id=$(wezterm cli split-pane --cwd "$working_dir" --right --pane-id "${first_pane:-0}" 2>/dev/null) || \
        pane_id=$(wezterm cli split-pane --cwd "$working_dir" --bottom 2>/dev/null)
    fi

    if [[ -z "$pane_id" ]]; then
        echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m Failed to spawn WezTerm pane for '${name}'." >&2
        return 1
    fi

    # Store mapping (file-based)
    echo "${name}=${pane_id}" >> "$_WEZTERM_PANE_MAP"

    # Set the pane title
    wezterm cli set-tab-title --pane-id "$pane_id" "$name" 2>/dev/null || true

    # Clear the pane
    wezterm cli send-text --pane-id "$pane_id" -- "clear" 2>/dev/null
    wezterm cli send-text --pane-id "$pane_id" --no-paste $'\n' 2>/dev/null || true

    # Run the command if provided
    if [[ -n "$command" ]]; then
        sleep 0.2
        wezterm cli send-text --pane-id "$pane_id" -- "$command" 2>/dev/null
        wezterm cli send-text --pane-id "$pane_id" --no-paste $'\n' 2>/dev/null || true
    fi
}

list_agents() {
    # List panes via wezterm CLI
    wezterm cli list 2>/dev/null | while IFS=$'\t' read -r pane_id title workspace rest; do
        echo "${pane_id}: ${title}"
    done

    # Also show our tracked agents
    if [[ -s "$_WEZTERM_PANE_MAP" ]]; then
        echo ""
        echo "Tracked agents:"
        while IFS='=' read -r _name _pid; do
            echo "  ${_name} → pane ${_pid}"
        done < "$_WEZTERM_PANE_MAP"
    fi
}

kill_agent() {
    local name="$1"
    local pane_id
    pane_id=$(grep "^${name}=" "$_WEZTERM_PANE_MAP" 2>/dev/null | head -1 | cut -d= -f2-)

    if [[ -z "$pane_id" ]]; then
        return 1
    fi

    wezterm cli kill-pane --pane-id "$pane_id" 2>/dev/null
    # Remove entry from pane map
    local _tmp
    _tmp=$(mktemp)
    grep -v "^${name}=" "$_WEZTERM_PANE_MAP" > "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$_WEZTERM_PANE_MAP"
}

focus_agent() {
    local name="$1"
    local pane_id
    pane_id=$(grep "^${name}=" "$_WEZTERM_PANE_MAP" 2>/dev/null | head -1 | cut -d= -f2-)

    if [[ -z "$pane_id" ]]; then
        return 1
    fi

    wezterm cli activate-pane --pane-id "$pane_id" 2>/dev/null
}
