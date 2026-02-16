#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tmux-pipeline — Spawn and manage pipelines in tmux windows   ║
# ║  Native tmux integration for pipeline visibility and control             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# Get daemon session name
get_daemon_session() {
    echo "sw-daemon"
}

# Get pipeline window name from issue number
get_window_name() {
    local issue_num="$1"
    echo "pipeline-${issue_num}"
}

# ─── Spawn subcommand ──────────────────────────────────────────────────────

cmd_spawn() {
    local issue_num=""
    local daemon_session
    daemon_session="$(get_daemon_session)"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)
                issue_num="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [[ -z "$issue_num" ]]; then
        error "Issue number required: --issue <number>"
        return 1
    fi

    # Check if daemon session exists
    if ! tmux has-session -t "$daemon_session" 2>/dev/null; then
        error "Daemon session not running: $daemon_session"
        echo "  Start with: ${DIM}shipwright daemon start --detach${RESET}"
        return 1
    fi

    local window_name
    window_name="$(get_window_name "$issue_num")"

    # Check if window already exists
    if tmux list-windows -t "$daemon_session" 2>/dev/null | grep -q "^[0-9]*: $window_name"; then
        warn "Pipeline window already exists: $window_name"
        return 1
    fi

    # Create new window in daemon session
    info "Creating pipeline window: ${CYAN}${window_name}${RESET}"
    local pane_id
    pane_id=$(tmux new-window -t "$daemon_session" -n "$window_name" -P -F "#{pane_id}")

    if [[ -z "$pane_id" ]]; then
        error "Failed to create tmux window"
        return 1
    fi

    # Send pipeline command to pane
    local pipeline_cmd="cd '$REPO_DIR' && env -u CLAUDECODE '$SCRIPT_DIR/sw-pipeline.sh' start --issue $issue_num"
    tmux send-keys -t "$pane_id" "$pipeline_cmd" Enter

    # Store pane ID in heartbeat
    local heartbeat_file
    heartbeat_file="${HOME}/.shipwright/heartbeats/pipeline-${issue_num}.json"
    mkdir -p "$(dirname "$heartbeat_file")"

    local tmp_file
    tmp_file=$(mktemp)
    cat > "$tmp_file" << EOF
{
  "job_id": "pipeline-${issue_num}",
  "type": "pipeline",
  "issue": "$issue_num",
  "pane_id": "$pane_id",
  "window": "$window_name",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "running"
}
EOF
    mv "$tmp_file" "$heartbeat_file"

    success "Pipeline spawned in window: ${CYAN}${window_name}${RESET}"
    echo -e "  Pane ID: ${DIM}${pane_id}${RESET}"
    echo -e "  Attach: ${DIM}tmux attach-session -t $daemon_session -c $window_name${RESET}"

    emit_event "pipeline_spawn" "issue=$issue_num" "pane_id=$pane_id" "window=$window_name"
}

# ─── Attach subcommand ────────────────────────────────────────────────────

cmd_attach() {
    local issue_num=""
    local daemon_session
    daemon_session="$(get_daemon_session)"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)
                issue_num="$2"
                shift 2
                ;;
            *)
                issue_num="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$issue_num" ]]; then
        error "Issue number required"
        return 1
    fi

    # Check if daemon session exists
    if ! tmux has-session -t "$daemon_session" 2>/dev/null; then
        error "Daemon session not running: $daemon_session"
        return 1
    fi

    local window_name
    window_name="$(get_window_name "$issue_num")"

    # Check if window exists
    if ! tmux list-windows -t "$daemon_session" 2>/dev/null | grep -q "^[0-9]*: $window_name"; then
        error "Pipeline window not found: $window_name"
        return 1
    fi

    info "Attaching to: ${CYAN}${window_name}${RESET}"
    tmux select-window -t "$daemon_session:$window_name"
    tmux attach-session -t "$daemon_session"
}

# ─── Capture subcommand ───────────────────────────────────────────────────

cmd_capture() {
    local issue_num=""
    local daemon_session
    daemon_session="$(get_daemon_session)"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)
                issue_num="$2"
                shift 2
                ;;
            *)
                issue_num="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$issue_num" ]]; then
        error "Issue number required"
        return 1
    fi

    local window_name
    window_name="$(get_window_name "$issue_num")"

    # Check if window exists
    if ! tmux list-windows -t "$daemon_session" 2>/dev/null | grep -q "^[0-9]*: $window_name"; then
        error "Pipeline window not found: $window_name"
        return 1
    fi

    # Get pane ID from window
    local pane_id
    pane_id=$(tmux list-panes -t "$daemon_session:$window_name" -F "#{pane_id}" | head -1)

    if [[ -z "$pane_id" ]]; then
        error "Failed to get pane ID for window: $window_name"
        return 1
    fi

    # Capture pane output
    info "Capturing output from: ${CYAN}${window_name}${RESET}"
    tmux capture-pane -t "$pane_id" -p
}

# ─── Stream subcommand ────────────────────────────────────────────────────

cmd_stream() {
    local issue_num=""
    local daemon_session
    daemon_session="$(get_daemon_session)"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)
                issue_num="$2"
                shift 2
                ;;
            *)
                issue_num="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$issue_num" ]]; then
        error "Issue number required"
        return 1
    fi

    local window_name
    window_name="$(get_window_name "$issue_num")"

    # Check if window exists
    if ! tmux list-windows -t "$daemon_session" 2>/dev/null | grep -q "^[0-9]*: $window_name"; then
        error "Pipeline window not found: $window_name"
        return 1
    fi

    # Get pane ID from window
    local pane_id
    pane_id=$(tmux list-panes -t "$daemon_session:$window_name" -F "#{pane_id}" | head -1)

    if [[ -z "$pane_id" ]]; then
        error "Failed to get pane ID for window: $window_name"
        return 1
    fi

    info "Streaming output from: ${CYAN}${window_name}${RESET}"
    info "Press Ctrl-C to stop streaming"
    echo ""

    # Stream with continuous capture
    while true; do
        tmux capture-pane -t "$pane_id" -p -S -100
        sleep 1
        # Clear previous output
        printf '\033[2J\033[H'
    done
}

# ─── List subcommand ──────────────────────────────────────────────────────

cmd_list() {
    local daemon_session
    daemon_session="$(get_daemon_session)"

    # Check if daemon session exists
    if ! tmux has-session -t "$daemon_session" 2>/dev/null; then
        warn "Daemon session not running: $daemon_session"
        return
    fi

    info "Pipeline windows in: ${CYAN}${daemon_session}${RESET}"
    echo ""

    local has_pipelines=false
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Parse window line: "0: pipeline-42 (1 panes)"
        local window_num window_name status
        window_num=$(echo "$line" | cut -d: -f1)
        window_name=$(echo "$line" | cut -d' ' -f2)

        # Check if it's a pipeline window
        if [[ "$window_name" =~ ^pipeline- ]]; then
            has_pipelines=true

            # Extract issue number
            local issue_num="${window_name#pipeline-}"

            # Get pane info
            local pane_id
            pane_id=$(tmux list-panes -t "$daemon_session:$window_num" -F "#{pane_id}" | head -1)

            # Get pane status
            local pane_status
            pane_status=$(tmux list-panes -t "$daemon_session:$window_num" -F "#{pane_title}" | head -1)
            [[ -z "$pane_status" ]] && pane_status="running"

            echo -e "  ${CYAN}#${issue_num}${RESET} ${DIM}(window ${window_num})${RESET} — ${pane_status}"
            echo -e "    ${DIM}pane: ${pane_id}${RESET}"
        fi
    done < <(tmux list-windows -t "$daemon_session" 2>/dev/null)

    if ! $has_pipelines; then
        warn "No pipeline windows found"
    fi

    echo ""
}

# ─── Kill subcommand ──────────────────────────────────────────────────────

cmd_kill() {
    local issue_num=""
    local daemon_session
    daemon_session="$(get_daemon_session)"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)
                issue_num="$2"
                shift 2
                ;;
            *)
                issue_num="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$issue_num" ]]; then
        error "Issue number required"
        return 1
    fi

    local window_name
    window_name="$(get_window_name "$issue_num")"

    # Check if window exists
    if ! tmux list-windows -t "$daemon_session" 2>/dev/null | grep -q "^[0-9]*: $window_name"; then
        warn "Pipeline window not found: $window_name"
        return
    fi

    # Get window number
    local window_num
    window_num=$(tmux list-windows -t "$daemon_session" 2>/dev/null | grep "^[0-9]*: $window_name" | cut -d: -f1)

    info "Killing pipeline window: ${CYAN}${window_name}${RESET}"
    tmux kill-window -t "$daemon_session:$window_num"

    # Clean up heartbeat
    local heartbeat_file
    heartbeat_file="${HOME}/.shipwright/heartbeats/pipeline-${issue_num}.json"
    rm -f "$heartbeat_file"

    success "Pipeline killed"
    emit_event "pipeline_kill" "issue=$issue_num" "window=$window_name"
}

# ─── Layout subcommand ────────────────────────────────────────────────────

cmd_layout() {
    local layout="${1:-tiled}"
    local daemon_session
    daemon_session="$(get_daemon_session)"

    # Check if daemon session exists
    if ! tmux has-session -t "$daemon_session" 2>/dev/null; then
        error "Daemon session not running: $daemon_session"
        return 1
    fi

    info "Applying layout: ${CYAN}${layout}${RESET}"

    case "$layout" in
        tiled|tile)
            tmux select-layout -t "$daemon_session" tiled
            success "Layout applied: tiled"
            ;;
        even-horizontal|horizontal|h)
            tmux select-layout -t "$daemon_session" even-horizontal
            success "Layout applied: even-horizontal"
            ;;
        even-vertical|vertical|v)
            tmux select-layout -t "$daemon_session" even-vertical
            success "Layout applied: even-vertical"
            ;;
        *)
            error "Unknown layout: $layout"
            echo "  Available: tiled, horizontal, vertical"
            return 1
            ;;
    esac
}

# ─── Help subcommand ──────────────────────────────────────────────────────

cmd_help() {
    cat << 'EOF'
shipwright tmux-pipeline — Spawn and manage pipelines in tmux windows

USAGE
  shipwright tmux-pipeline <command> [options]

COMMANDS
  spawn --issue <N>
      Create a new tmux window for a pipeline and run it
      Window name: pipeline-<N>
      Stores pane ID in ~/.shipwright/heartbeats/pipeline-<N>.json

  attach [--issue] <N>
      Attach to a running pipeline's tmux window
      Example: shipwright tmux-pipeline attach 42

  capture [--issue] <N>
      Capture and print current output of a pipeline pane
      Example: shipwright tmux-pipeline capture 42

  stream [--issue] <N>
      Continuously stream a pipeline's output to stdout
      Like "tail -f" for tmux panes
      Press Ctrl-C to stop

  list
      Show all pipeline windows with status
      Displays issue numbers, pane IDs, and status

  kill [--issue] <N>
      Terminate a pipeline window gracefully
      Cleans up associated heartbeat file
      Example: shipwright tmux-pipeline kill 42

  layout <type>
      Arrange pipeline windows in a grid layout
      Types: tiled, horizontal, vertical

  help
      Show this help message

OPTIONS
  --issue <N>     Specify issue number (can also be positional arg)

EXAMPLES
  # Create and spawn a pipeline for issue #42
  shipwright tmux-pipeline spawn --issue 42

  # Attach to the pipeline window
  shipwright tmux-pipeline attach 42

  # Capture current output
  shipwright tmux-pipeline capture 42

  # Stream output continuously
  shipwright tmux-pipeline stream 42

  # List all running pipelines
  shipwright tmux-pipeline list

  # Kill the pipeline
  shipwright tmux-pipeline kill 42

  # Arrange windows in a tiled grid
  shipwright tmux-pipeline layout tiled

INTEGRATION
  Works with: shipwright daemon start --detach
  Requires: tmux session "sw-daemon" running
  State: ~/.shipwright/heartbeats/pipeline-<N>.json

EOF
}

# ─── Main router ──────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        spawn)
            cmd_spawn "$@"
            ;;
        attach)
            cmd_attach "$@"
            ;;
        capture)
            cmd_capture "$@"
            ;;
        stream)
            cmd_stream "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        kill)
            cmd_kill "$@"
            ;;
        layout)
            cmd_layout "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

# Only run main if this script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
