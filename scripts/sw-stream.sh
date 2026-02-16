#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-stream.sh — Live terminal output streaming from agent panes         ║
# ║                                                                          ║
# ║  Streams tmux pane output in real-time to the dashboard or CLI.         ║
# ║  Captures output periodically, tags by agent/team, supports replay.     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="2.1.2"
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

# ─── Stream configuration ─────────────────────────────────────────────────────
STREAM_CONFIG="${HOME}/.shipwright/stream-config.json"
STREAM_DIR="${HOME}/.shipwright/streams"
OUTPUT_FORMAT="jsonl"  # jsonl, json, or text
CAPTURE_INTERVAL=1
BUFFER_LINES=500
RUNNING_PID_FILE="${HOME}/.shipwright/stream.pid"

# Load config if exists
load_config() {
    if [[ -f "$STREAM_CONFIG" ]]; then
        CAPTURE_INTERVAL=$(jq -r '.capture_interval_seconds // 1' "$STREAM_CONFIG" 2>/dev/null || echo 1)
        BUFFER_LINES=$(jq -r '.buffer_lines // 500' "$STREAM_CONFIG" 2>/dev/null || echo 500)
        OUTPUT_FORMAT=$(jq -r '.output_format // "jsonl"' "$STREAM_CONFIG" 2>/dev/null || echo "jsonl")
    fi
}

# ─── Stream management ─────────────────────────────────────────────────────
init_stream_dir() {
    mkdir -p "$STREAM_DIR"
    mkdir -p "${HOME}/.shipwright"
}

get_pane_agent_name() {
    local pane_id="$1"
    tmux display-message -p -t "$pane_id" '#{pane_title}' 2>/dev/null || echo "unknown"
}

get_pane_window_name() {
    local pane_id="$1"
    tmux display-message -p -t "$pane_id" '#{window_name}' 2>/dev/null || echo "unknown"
}

# Extract team name from window name (e.g., "claude-myteam" → "myteam")
extract_team_name() {
    local window_name="$1"
    echo "$window_name" | sed 's/^claude-//; s/-[0-9]*$//'
}

# ─── Capture a single pane's output ──────────────────────────────────────────
capture_pane_output() {
    local pane_id="$1"
    local agent_name="$2"
    local team_name="$3"

    local pane_file="${STREAM_DIR}/${team_name}/${agent_name}.jsonl"
    mkdir -p "${STREAM_DIR}/${team_name}"

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Capture last N lines from pane
    local pane_output
    pane_output=$(tmux capture-pane -p -t "$pane_id" -S "-${BUFFER_LINES}" 2>/dev/null || echo "")

    if [[ -z "$pane_output" ]]; then
        return 0
    fi

    # Write JSONL entry with timestamp, pane_id, agent, team, content
    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    {
        while IFS= read -r line; do
            # Escape newlines and quotes in output
            line="${line//\"/\\\"}"
            printf '{"timestamp":"%s","pane_id":"%s","agent_name":"%s","team":"%s","content":"%s"}\n' \
                "$ts" "$pane_id" "$agent_name" "$team_name" "$line"
        done <<< "$pane_output"
    } >> "$tmp_file"

    # Atomic write: append to pane file and trim to buffer size
    cat "$tmp_file" >> "$pane_file" 2>/dev/null || true

    # Trim to buffer size (keep latest N lines)
    local line_count
    line_count=$(wc -l < "$pane_file" 2>/dev/null || echo 0)
    if [[ "$line_count" -gt "$BUFFER_LINES" ]]; then
        local skip=$((line_count - BUFFER_LINES))
        tail -n "$BUFFER_LINES" "$pane_file" > "${pane_file}.tmp"
        mv "${pane_file}.tmp" "$pane_file"
    fi
}

# ─── Capture all agent panes ──────────────────────────────────────────────────
capture_all_panes() {
    local filter_team="${1:-}"
    local filter_agent="${2:-}"

    # Find all claude-* windows and capture their panes
    tmux list-panes -a -F '#{pane_id}|#{window_name}' 2>/dev/null | while IFS='|' read -r pane_id window_name; do
        [[ -z "$pane_id" ]] && continue

        # Only claude-* windows
        echo "$window_name" | grep -q "^claude" || continue

        local agent_name
        agent_name=$(get_pane_agent_name "$pane_id")

        local team_name
        team_name=$(extract_team_name "$window_name")

        # Apply filters
        if [[ -n "$filter_team" ]]; then
            [[ "$team_name" != "$filter_team" ]] && continue
        fi
        if [[ -n "$filter_agent" ]]; then
            [[ "$agent_name" != "$filter_agent" ]] && continue
        fi

        capture_pane_output "$pane_id" "$agent_name" "$team_name"
    done

    emit_event "stream.capture_cycle" \
        "team=$filter_team" \
        "agent=$filter_agent" \
        "interval=$CAPTURE_INTERVAL"
}

# ─── Stream start (background polling) ───────────────────────────────────────
stream_start() {
    local team="${1:-}"

    init_stream_dir
    load_config

    if [[ -f "$RUNNING_PID_FILE" ]]; then
        local pid
        pid=$(cat "$RUNNING_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            warn "Stream is already running (PID $pid)"
            return 0
        else
            rm -f "$RUNNING_PID_FILE"
        fi
    fi

    # Start background capture loop
    (
        while true; do
            capture_all_panes "$team"
            sleep "$CAPTURE_INTERVAL"
        done
    ) &
    local loop_pid=$!
    echo "$loop_pid" > "$RUNNING_PID_FILE"

    success "Stream started (PID $loop_pid)"
    info "Capturing every ${CAPTURE_INTERVAL}s from team: ${team:-all}"
    emit_event "stream.started" "team=$team" "pid=$loop_pid"
}

# ─── Stream stop ─────────────────────────────────────────────────────────────
stream_stop() {
    if [[ ! -f "$RUNNING_PID_FILE" ]]; then
        warn "Stream is not running"
        return 1
    fi

    local pid
    pid=$(cat "$RUNNING_PID_FILE")

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        rm -f "$RUNNING_PID_FILE"
        success "Stream stopped (PID $pid)"
        emit_event "stream.stopped" "pid=$pid"
    else
        warn "Stream process (PID $pid) is not running"
        rm -f "$RUNNING_PID_FILE"
    fi
}

# ─── Live watch (tail stream in terminal) ────────────────────────────────────
stream_watch() {
    local team="${1:-}"
    local agent="${2:-}"

    init_stream_dir
    load_config

    if [[ -z "$team" ]]; then
        warn "Usage: shipwright stream watch <team> [agent]"
        return 1
    fi

    local watch_path="${STREAM_DIR}/${team}"
    if [[ -n "$agent" ]]; then
        watch_path="${watch_path}/${agent}.jsonl"
    fi

    if [[ ! -e "$watch_path" ]]; then
        error "No stream data for team '$team'${agent:+ agent '$agent'}"
        return 1
    fi

    info "Watching $watch_path..."
    echo ""

    tail -f "$watch_path" | while IFS= read -r line; do
        # Parse JSONL and pretty-print
        local timestamp agent_name content
        timestamp=$(echo "$line" | jq -r '.timestamp // ""' 2>/dev/null || echo "")
        agent_name=$(echo "$line" | jq -r '.agent_name // ""' 2>/dev/null || echo "")
        content=$(echo "$line" | jq -r '.content // ""' 2>/dev/null || echo "")

        if [[ -n "$timestamp" && -n "$agent_name" && -n "$content" ]]; then
            printf "${DIM}%s${RESET} ${CYAN}[%s]${RESET} %s\n" "$timestamp" "$agent_name" "$content"
        fi
    done
}

# ─── List active streams ─────────────────────────────────────────────────────
stream_list() {
    init_stream_dir

    if [[ ! -d "$STREAM_DIR" ]] || [[ -z "$(find "$STREAM_DIR" -type f -name '*.jsonl' 2>/dev/null)" ]]; then
        warn "No active streams"
        return 0
    fi

    echo ""
    info "Active Streams:"
    echo ""

    find "$STREAM_DIR" -type f -name '*.jsonl' | sort | while read -r stream_file; do
        # Extract team and agent from path
        local relative_path
        relative_path="${stream_file#$STREAM_DIR/}"
        local team_name
        team_name=$(echo "$relative_path" | cut -d'/' -f1)
        local agent_name
        agent_name=$(basename "$relative_path" .jsonl)

        # Get file size and line count
        local file_size lines_count
        file_size=$(stat -f%z "$stream_file" 2>/dev/null || stat -c%s "$stream_file" 2>/dev/null || echo 0)
        lines_count=$(wc -l < "$stream_file" 2>/dev/null || echo 0)

        # Get latest timestamp
        local latest_ts
        latest_ts=$(tail -1 "$stream_file" 2>/dev/null | jq -r '.timestamp // ""' 2>/dev/null || echo "")

        printf "  ${CYAN}%-20s${RESET} ${PURPLE}%-20s${RESET} %s  ${DIM}(%s lines, %s bytes)${RESET}\n" \
            "$team_name" "$agent_name" "$latest_ts" "$lines_count" "$file_size"
    done

    echo ""
}

# ─── Replay recent output for a pane ──────────────────────────────────────────
stream_replay() {
    local team="${1:-}"
    local agent="${2:-}"
    local lines="${3:-50}"

    init_stream_dir

    if [[ -z "$team" ]] || [[ -z "$agent" ]]; then
        warn "Usage: shipwright stream replay <team> <agent> [lines]"
        return 1
    fi

    local stream_file="${STREAM_DIR}/${team}/${agent}.jsonl"

    if [[ ! -f "$stream_file" ]]; then
        error "No stream data for team '$team' agent '$agent'"
        return 1
    fi

    info "Replay (last ${lines} lines from ${team}/${agent}):"
    echo ""

    tail -n "$lines" "$stream_file" | while IFS= read -r line; do
        local timestamp agent_name content
        timestamp=$(echo "$line" | jq -r '.timestamp // ""' 2>/dev/null || echo "")
        agent_name=$(echo "$line" | jq -r '.agent_name // ""' 2>/dev/null || echo "")
        content=$(echo "$line" | jq -r '.content // ""' 2>/dev/null || echo "")

        if [[ -n "$timestamp" && -n "$agent_name" && -n "$content" ]]; then
            printf "${DIM}%s${RESET} ${CYAN}[%s]${RESET} %s\n" "$timestamp" "$agent_name" "$content"
        fi
    done

    echo ""
}

# ─── Configure stream settings ───────────────────────────────────────────────
stream_config() {
    local key="${1:-}"
    local value="${2:-}"

    if [[ -z "$key" ]]; then
        warn "Usage: shipwright stream config <key> <value>"
        echo "  Available keys: capture_interval_seconds, buffer_lines, output_format"
        return 1
    fi

    mkdir -p "${HOME}/.shipwright"

    # Load existing config or create new
    local config="{}"
    if [[ -f "$STREAM_CONFIG" ]]; then
        config=$(cat "$STREAM_CONFIG")
    fi

    # Create tmp file for atomic write
    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    case "$key" in
        capture_interval_seconds)
            echo "$config" | jq ".capture_interval_seconds = ($value | tonumber)" > "$tmp_file"
            ;;
        buffer_lines)
            echo "$config" | jq ".buffer_lines = ($value | tonumber)" > "$tmp_file"
            ;;
        output_format)
            echo "$config" | jq ".output_format = \"$value\"" > "$tmp_file"
            ;;
        *)
            error "Unknown config key: $key"
            return 1
            ;;
    esac

    mv "$tmp_file" "$STREAM_CONFIG"
    success "Config updated: $key = $value"
    emit_event "stream.config_updated" "key=$key" "value=$value"
}

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright stream${RESET} — Live terminal output streaming"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright stream${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}start${RESET} [team]              Start streaming agent panes (all or by team)"
    echo -e "  ${CYAN}stop${RESET}                      Stop streaming"
    echo -e "  ${CYAN}watch${RESET} <team> [agent]      Live tail of stream output in terminal"
    echo -e "  ${CYAN}list${RESET}                      Show active streams"
    echo -e "  ${CYAN}replay${RESET} <team> <agent> [N] Show recent N lines from stream (default 50)"
    echo -e "  ${CYAN}config${RESET} <key> <value>      Set stream configuration"
    echo -e "  ${CYAN}help${RESET}                      Show this help message"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright stream start${RESET}                    # Start streaming all teams"
    echo -e "  ${DIM}shipwright stream start myteam${RESET}              # Stream only 'myteam'"
    echo -e "  ${DIM}shipwright stream watch myteam builder${RESET}      # Watch builder agent in myteam"
    echo -e "  ${DIM}shipwright stream replay myteam builder 100${RESET} # Show last 100 lines"
    echo -e "  ${DIM}shipwright stream config capture_interval_seconds 2${RESET}  # Capture every 2s"
    echo -e "  ${DIM}shipwright stream list${RESET}                      # Show all active streams"
    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"

    case "$cmd" in
        start)
            stream_start "${2:-}"
            ;;
        stop)
            stream_stop
            ;;
        watch)
            stream_watch "${2:-}" "${3:-}"
            ;;
        list)
            stream_list
            ;;
        replay)
            stream_replay "${2:-}" "${3:-}" "${4:-50}"
            ;;
        config)
            stream_config "${2:-}" "${3:-}"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
