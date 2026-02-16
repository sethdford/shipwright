#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright eventbus — Durable event bus for real-time inter-component   ║
# ║  communication with publishing, subscribing, process monitoring, file     ║
# ║  watching, event replay, and lifecycle management.                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.2"
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

# ─── Configuration ──────────────────────────────────────────────────────────
EVENTBUS_FILE="${HOME}/.shipwright/eventbus.jsonl"
EVENT_TTL_DAYS=7  # Default TTL for events (seconds = 7 * 86400)

# ─── Initialize eventbus directory ──────────────────────────────────────────
ensure_eventbus_dir() {
    local dir
    dir="$(dirname "$EVENTBUS_FILE")"
    [[ -d "$dir" ]] || mkdir -p "$dir"
}

# ─── Generate UUID (simple) ────────────────────────────────────────────────
generate_uuid() {
    local uuid
    uuid=$(od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3, $4, $5, $6, $7$8$9}' | sed 's/-/-/g' | cut -c1-36)
    echo "$uuid"
}

# ─── Publish command ────────────────────────────────────────────────────────
cmd_publish() {
    local event_type="$1"
    local source="${2:-unknown}"
    local correlation_id="$3"
    local payload_json="${4:-{}}"

    if [[ -z "$event_type" ]]; then
        error "publish requires event_type, source, [correlation_id], [payload_json]"
        return 1
    fi

    ensure_eventbus_dir

    if [[ -z "$correlation_id" ]]; then
        correlation_id="$(generate_uuid)"
    fi

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Build event JSON on single line
    local event_json
    event_json="{\"type\": \"$event_type\", \"source\": \"$source\", \"correlation_id\": \"$correlation_id\", \"timestamp\": \"$timestamp\", \"payload\": $payload_json}"


    # Atomic write (append to JSONL file)
    local tmp_file
    tmp_file="$(mktemp)"
    if [[ -f "$EVENTBUS_FILE" ]]; then
        cat "$EVENTBUS_FILE" > "$tmp_file"
    fi
    echo "$event_json" >> "$tmp_file"
    mv "$tmp_file" "$EVENTBUS_FILE"

    success "Published event: $event_type (correlation_id: $correlation_id)"
}

# ─── Subscribe command ──────────────────────────────────────────────────────
cmd_subscribe() {
    local event_type_filter="${1:-}"
    local max_lines="${2:-}"

    ensure_eventbus_dir

    [[ ! -f "$EVENTBUS_FILE" ]] && {
        warn "Event bus is empty or does not exist yet"
        return 0
    }

    info "Subscribing to event bus (${event_type_filter:-(all types)})..."
    echo ""

    # Tail the file with optional grep filter
    if [[ -n "$event_type_filter" ]]; then
        tail -f "$EVENTBUS_FILE" | grep "\"type\": \"$event_type_filter\""
    else
        tail -f "$EVENTBUS_FILE"
    fi
}

# ─── Process reaper (SIGCHLD monitor) ──────────────────────────────────────
cmd_reaper() {
    local pid_list=()

    info "Starting process reaper. Press Ctrl+C to exit."
    echo -e "${DIM}Monitoring child processes and emitting process.exited events...${RESET}"
    echo ""

    ensure_eventbus_dir

    # Monitor child processes
    while true; do
        # Get list of all child processes
        local pids
        pids=$(jobs -p 2>/dev/null || echo "")

        if [[ -n "$pids" ]]; then
            while IFS= read -r pid; do
                [[ -z "$pid" ]] && continue

                # Check if process is still alive
                if ! kill -0 "$pid" 2>/dev/null; then
                    # Process died — emit event
                    local payload="{\"pid\": $pid, \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
                    cmd_publish "process.exited" "reaper" "$(generate_uuid)" "$payload"
                fi
            done <<< "$pids"
        fi

        sleep 2
    done
}

# ─── File watcher (fswatch or inotifywait) ────────────────────────────────
cmd_watch() {
    local watch_dir="$1"
    [[ -z "$watch_dir" ]] && {
        error "watch requires a directory path"
        return 1
    }

    [[ ! -d "$watch_dir" ]] && {
        error "Directory not found: $watch_dir"
        return 1
    }

    ensure_eventbus_dir

    info "Watching directory: $watch_dir"
    echo -e "${DIM}Press Ctrl+C to stop...${RESET}"
    echo ""

    # Determine platform and use appropriate watcher
    if command -v fswatch &>/dev/null; then
        # macOS with fswatch
        fswatch -r "$watch_dir" | while read -r file; do
            local payload
            payload="{\"file\": \"$file\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
            cmd_publish "file.changed" "watcher" "$(generate_uuid)" "$payload"
        done
    elif command -v inotifywait &>/dev/null; then
        # Linux with inotify-tools
        inotifywait -m -r "$watch_dir" | while read -r dir action file; do
            local filepath="${dir}${file}"
            local payload
            payload="{\"file\": \"$filepath\", \"action\": \"$action\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
            cmd_publish "file.changed" "watcher" "$(generate_uuid)" "$payload"
        done
    else
        error "Neither fswatch (macOS) nor inotifywait (Linux) is installed"
        return 1
    fi
}

# ─── Event replay command ──────────────────────────────────────────────────
cmd_replay() {
    local minutes="${1:-}"
    [[ -z "$minutes" ]] && minutes=60

    ensure_eventbus_dir

    [[ ! -f "$EVENTBUS_FILE" ]] && {
        warn "Event bus is empty or does not exist yet"
        return 0
    }

    info "Replaying events from the last ${minutes} minutes..."
    echo ""

    # Calculate cutoff timestamp
    local cutoff_epoch
    cutoff_epoch=$(($(date +%s) - (minutes * 60)))
    local cutoff_iso
    cutoff_iso="$(date -u -j -f %s "$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @"$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

    # Grep and display events after cutoff
    grep "timestamp" "$EVENTBUS_FILE" | while read -r line; do
        local ts
        ts=$(echo "$line" | grep -o '"timestamp": "[^"]*"' | cut -d'"' -f4)
        if [[ "$ts" > "$cutoff_iso" ]]; then
            echo "$line"
        fi
    done
}

# ─── Status command ────────────────────────────────────────────────────────
cmd_status() {
    ensure_eventbus_dir

    echo ""
    echo -e "${CYAN}${BOLD}Event Bus Status${RESET}"
    echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo ""

    if [[ ! -f "$EVENTBUS_FILE" ]]; then
        echo -e "  ${YELLOW}Event bus not yet initialized${RESET}"
        echo ""
        return 0
    fi

    local total_events
    total_events=$(wc -l < "$EVENTBUS_FILE" || echo 0)

    local last_event_ts
    last_event_ts=$(tail -1 "$EVENTBUS_FILE" | grep -o '"timestamp": "[^"]*"' | cut -d'"' -f4 || echo "never")

    echo -e "  ${CYAN}Event Bus:${RESET} $EVENTBUS_FILE"
    echo -e "  ${CYAN}Total Events:${RESET} ${BOLD}${total_events}${RESET}"
    echo -e "  ${CYAN}Last Event:${RESET} $last_event_ts"
    echo ""

    # Count events by type
    if [[ $total_events -gt 0 ]]; then
        echo -e "  ${PURPLE}${BOLD}Events by Type${RESET}"
        grep '"type"' "$EVENTBUS_FILE" | cut -d'"' -f4 | sort | uniq -c | sort -rn | while read -r count type; do
            printf "    ${DIM}%-40s${RESET} %3d events\n" "$type" "$count"
        done
    fi

    echo ""
}

# ─── Clean command (remove old events) ─────────────────────────────────────
cmd_clean() {
    local ttl_days="${1:-$EVENT_TTL_DAYS}"

    ensure_eventbus_dir

    [[ ! -f "$EVENTBUS_FILE" ]] && {
        success "Event bus is empty"
        return 0
    }

    info "Cleaning events older than ${ttl_days} days..."

    # Calculate cutoff timestamp
    local cutoff_epoch
    cutoff_epoch=$(($(date +%s) - (ttl_days * 86400)))
    local cutoff_iso
    cutoff_iso="$(date -u -j -f %s "$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @"$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

    local old_count
    old_count=$(grep -c "timestamp" "$EVENTBUS_FILE" 2>/dev/null || echo 0)

    # Keep only recent events
    local tmp_file
    tmp_file="$(mktemp)"
    grep "timestamp" "$EVENTBUS_FILE" | while read -r line; do
        local ts
        ts=$(echo "$line" | grep -o '"timestamp": "[^"]*"' | cut -d'"' -f4)
        if [[ "$ts" > "$cutoff_iso" ]]; then
            echo "$line" >> "$tmp_file"
        fi
    done

    mv "$tmp_file" "$EVENTBUS_FILE"

    local new_count
    new_count=$(wc -l < "$EVENTBUS_FILE" || echo 0)
    local removed=$((old_count - new_count))

    success "Removed $removed old events. Remaining: $new_count"
}

# ─── Help command ──────────────────────────────────────────────────────────
cmd_help() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright eventbus${RESET} — Durable event bus for real-time inter-component communication"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright eventbus${RESET} <subcommand> [options]"
    echo ""
    echo -e "${BOLD}SUBCOMMANDS${RESET}"
    echo ""
    echo -e "  ${CYAN}publish${RESET} <type> <source> [correlation_id] [payload_json]"
    echo -e "    Publish a structured event to the event bus"
    echo -e "    ${DIM}shipwright eventbus publish stage.complete pipeline 123 '{\"stage\": \"build\"}'${RESET}"
    echo ""
    echo -e "  ${CYAN}subscribe${RESET} [event_type]"
    echo -e "    Subscribe to events (tail with optional type filter)"
    echo -e "    ${DIM}shipwright eventbus subscribe${RESET}                    # All events"
    echo -e "    ${DIM}shipwright eventbus subscribe stage.complete${RESET}    # Only stage events"
    echo ""
    echo -e "  ${CYAN}reaper${RESET}"
    echo -e "    Monitor child processes and emit process.exited events"
    echo -e "    ${DIM}shipwright eventbus reaper${RESET}"
    echo ""
    echo -e "  ${CYAN}watch${RESET} <directory>"
    echo -e "    Watch directory for file changes and emit file.changed events"
    echo -e "    ${DIM}shipwright eventbus watch /tmp/project${RESET}"
    echo ""
    echo -e "  ${CYAN}replay${RESET} [minutes]"
    echo -e "    Replay events from the last N minutes (default: 60)"
    echo -e "    ${DIM}shipwright eventbus replay 30${RESET}"
    echo ""
    echo -e "  ${CYAN}status${RESET}"
    echo -e "    Show event bus statistics and event counts by type"
    echo -e "    ${DIM}shipwright eventbus status${RESET}"
    echo ""
    echo -e "  ${CYAN}clean${RESET} [ttl_days]"
    echo -e "    Remove events older than TTL (default: 7 days)"
    echo -e "    ${DIM}shipwright eventbus clean 3${RESET}"
    echo ""
    echo -e "  ${CYAN}help${RESET}"
    echo -e "    Show this help message"
    echo ""
    echo -e "${BOLD}EVENT FORMAT${RESET}"
    echo -e "  Events are stored as JSONL with fields: type, source, correlation_id, timestamp, payload"
    echo -e "  ${DIM}Example:${RESET}"
    echo -e "  ${DIM}{\"type\": \"stage.complete\", \"source\": \"pipeline\", \"correlation_id\": \"123\", \"timestamp\": \"2025-02-14T12:34:56Z\", \"payload\": {...}}${RESET}"
    echo ""
}

# ─── Main command router ───────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"

    case "$cmd" in
        publish)
            shift
            cmd_publish "$@"
            ;;
        subscribe)
            shift
            cmd_subscribe "$@"
            ;;
        reaper)
            shift
            cmd_reaper "$@"
            ;;
        watch)
            shift
            cmd_watch "$@"
            ;;
        replay)
            shift
            cmd_replay "$@"
            ;;
        status)
            shift
            cmd_status "$@"
            ;;
        clean)
            shift
            cmd_clean "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            error "Unknown subcommand: $cmd"
            cmd_help
            exit 1
            ;;
    esac
}

# ─── Source guard ──────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
