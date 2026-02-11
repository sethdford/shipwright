#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  tmux-adapter.sh — Terminal adapter for tmux pane management            ║
# ║                                                                          ║
# ║  Default adapter. Creates tmux panes within a named window.             ║
# ║  Sourced by sw-session.sh — exports: spawn_agent, list_agents,         ║
# ║  kill_agent, focus_agent.                                                ║
# ║                                                                          ║
# ║  Uses pane IDs (%N) instead of indices to avoid the pane-base-index    ║
# ║  bug where teammate instructions are sent to wrong panes when           ║
# ║  pane-base-index != 0. See: claude-code#23527                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Track spawned panes by agent name → pane ID (file-based for bash 3.2 compat)
_TMUX_PANE_MAP="${TMPDIR:-/tmp}/shipwright-tmux-pane-map.$$"
: > "$_TMUX_PANE_MAP"
trap 'rm -f "$_TMUX_PANE_MAP"' EXIT

spawn_agent() {
    local name="$1"
    local working_dir="${2:-#{pane_current_path}}"
    local command="${3:-}"

    local new_pane_id=""

    # If no window exists yet, create one and capture the pane ID
    if ! tmux list-windows -F '#W' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
        # -P prints the new pane's ID (e.g. %5)
        new_pane_id=$(tmux new-window -n "$WINDOW_NAME" -c "$working_dir" -P -F '#{pane_id}')
    else
        # Split the current window and capture the new pane ID
        new_pane_id=$(tmux split-window -t "$WINDOW_NAME" -c "$working_dir" -P -F '#{pane_id}')
    fi

    # Record the mapping: name → pane_id
    echo "${name}=${new_pane_id}" >> "$_TMUX_PANE_MAP"

    sleep 0.1

    # Set the pane title using the stable pane ID (not index)
    tmux send-keys -t "$new_pane_id" "printf '\\033]2;${name}\\033\\\\'" Enter
    sleep 0.1
    tmux send-keys -t "$new_pane_id" "clear" Enter

    # Apply dark theme to the new pane
    tmux select-pane -t "$new_pane_id" -P 'bg=#1a1a2e,fg=#e4e4e7' 2>/dev/null || true

    # Run the command if provided
    if [[ -n "$command" ]]; then
        sleep 0.1
        tmux send-keys -t "$new_pane_id" "$command" Enter
    fi

    # Re-tile after adding each pane
    tmux select-layout -t "$WINDOW_NAME" tiled 2>/dev/null || true
}

list_agents() {
    # List all panes in the window with their titles and IDs
    if tmux list-windows -F '#W' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
        tmux list-panes -t "$WINDOW_NAME" -F '#{pane_id}: #{pane_title} (#{pane_current_command})' 2>/dev/null
    fi
}

kill_agent() {
    local name="$1"

    if ! tmux list-windows -F '#W' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
        return 1
    fi

    # First try: look up from our pane map
    local pane_id=""
    if [[ -f "$_TMUX_PANE_MAP" ]]; then
        pane_id=$(grep "^${name}=" "$_TMUX_PANE_MAP" 2>/dev/null | tail -1 | cut -d= -f2) || true
    fi

    # Fallback: find the pane with the matching title (handles external spawns)
    if [[ -z "$pane_id" ]]; then
        pane_id=$(tmux list-panes -t "$WINDOW_NAME" -F '#{pane_id} #{pane_title}' 2>/dev/null \
            | grep " ${name}$" | head -1 | cut -d' ' -f1) || true
    fi

    if [[ -n "$pane_id" ]]; then
        tmux kill-pane -t "$pane_id"
        return 0
    fi
    return 1
}

focus_agent() {
    local name="$1"

    if ! tmux list-windows -F '#W' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
        return 1
    fi

    # First try: look up from our pane map
    local pane_id=""
    if [[ -f "$_TMUX_PANE_MAP" ]]; then
        pane_id=$(grep "^${name}=" "$_TMUX_PANE_MAP" 2>/dev/null | tail -1 | cut -d= -f2) || true
    fi

    # Fallback: find the pane by title
    if [[ -z "$pane_id" ]]; then
        pane_id=$(tmux list-panes -t "$WINDOW_NAME" -F '#{pane_id} #{pane_title}' 2>/dev/null \
            | grep " ${name}$" | head -1 | cut -d' ' -f1) || true
    fi

    if [[ -n "$pane_id" ]]; then
        tmux select-window -t "$WINDOW_NAME"
        tmux select-pane -t "$pane_id"
        return 0
    fi
    return 1
}
