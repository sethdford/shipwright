#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  tmux-adapter.sh — Terminal adapter for tmux pane management            ║
# ║                                                                          ║
# ║  Default adapter. Creates tmux panes within a named window.             ║
# ║  Sourced by cct-session.sh — exports: spawn_agent, list_agents,         ║
# ║  kill_agent, focus_agent.                                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Track spawned panes by agent name (file-based for bash 3.2 compat)
_TMUX_PANE_MAP="${TMPDIR:-/tmp}/shipwright-tmux-pane-map.$$"
: > "$_TMUX_PANE_MAP"
trap 'rm -f "$_TMUX_PANE_MAP"' EXIT

spawn_agent() {
    local name="$1"
    local working_dir="${2:-#{pane_current_path}}"
    local command="${3:-}"

    # If no window exists yet, create one
    if ! tmux list-windows -F '#W' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
        tmux new-window -n "$WINDOW_NAME" -c "$working_dir"
    else
        # Split the current window to add a pane
        tmux split-window -t "$WINDOW_NAME" -c "$working_dir"
    fi

    sleep 0.1

    # Set the pane title
    tmux send-keys -t "$WINDOW_NAME" "printf '\\033]2;${name}\\033\\\\'" Enter
    sleep 0.1
    tmux send-keys -t "$WINDOW_NAME" "clear" Enter

    # Run the command if provided
    if [[ -n "$command" ]]; then
        sleep 0.1
        tmux send-keys -t "$WINDOW_NAME" "$command" Enter
    fi

    # Re-tile after adding each pane
    tmux select-layout -t "$WINDOW_NAME" tiled 2>/dev/null || true
}

list_agents() {
    # List all panes in the window with their titles
    if tmux list-windows -F '#W' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
        tmux list-panes -t "$WINDOW_NAME" -F '#{pane_index}: #{pane_title} (#{pane_current_command})' 2>/dev/null
    fi
}

kill_agent() {
    local name="$1"

    if ! tmux list-windows -F '#W' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
        return 1
    fi

    # Find the pane with the matching title
    local pane_id
    pane_id=$(tmux list-panes -t "$WINDOW_NAME" -F '#{pane_id} #{pane_title}' 2>/dev/null \
        | grep " ${name}$" | head -1 | cut -d' ' -f1)

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

    # Find the pane with the matching title
    local pane_index
    pane_index=$(tmux list-panes -t "$WINDOW_NAME" -F '#{pane_index} #{pane_title}' 2>/dev/null \
        | grep " ${name}$" | head -1 | cut -d' ' -f1)

    if [[ -n "$pane_index" ]]; then
        tmux select-window -t "$WINDOW_NAME"
        tmux select-pane -t "$WINDOW_NAME.$pane_index"
        return 0
    fi
    return 1
}
