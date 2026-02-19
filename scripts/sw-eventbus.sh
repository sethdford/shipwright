#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright eventbus — Durable event bus for real-time inter-component   ║
# ║  communication with publishing, subscribing, process monitoring, file     ║
# ║  watching, event replay, and lifecycle management.                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# shellcheck source=sw-db.sh
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"
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
# ─── Configuration ──────────────────────────────────────────────────────────
EVENTS_FILE="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"
EVENT_TTL_DAYS=7  # Default TTL for events (seconds = 7 * 86400)

# ─── Initialize eventbus directory ──────────────────────────────────────────
ensure_eventbus_dir() {
    local dir
    dir="$(dirname "$EVENTS_FILE")"
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
    local correlation_id="${3:-}"
    local payload_json="${4:-{}}"

    if [[ -z "$event_type" ]]; then
        error "publish requires event_type, source, [correlation_id], [payload_json]"
        return 1
    fi

    ensure_eventbus_dir

    if [[ -z "$correlation_id" ]]; then
        correlation_id="$(generate_uuid)"
    fi

    emit_event "$event_type" "source=$source" "correlation_id=$correlation_id" "payload=$payload_json"

    success "Published event: $event_type (correlation_id: $correlation_id)"
}

# ─── Subscribe command ──────────────────────────────────────────────────────
cmd_subscribe() {
    local filter="${1:-}"
    local poll_interval=1
    local last_id=0

    # Try to resume from last consumer offset
    if db_available 2>/dev/null; then
        last_id=$(db_get_consumer_offset "eventbus-subscribe-$$" 2>/dev/null || echo "0")
    fi

    info "Subscribing to events (${filter:-(all types)})..."
    echo ""

    while true; do
        if db_available 2>/dev/null; then
            local events batch_last_id=0
            events=$(sqlite3 -json "$DB_FILE" "SELECT * FROM events WHERE id > $last_id ORDER BY id ASC LIMIT 50;" 2>/dev/null || echo "[]")
            if [[ "$events" != "[]" && -n "$events" ]]; then
                while IFS= read -r event; do
                    [[ -z "$event" ]] && continue
                    local etype
                    etype=$(echo "$event" | jq -r '.type // ""')
                    if [[ -z "$filter" || "$etype" == *"$filter"* ]]; then
                        echo "$event"
                    fi
                    batch_last_id=$(echo "$event" | jq -r '.id // 0')
                    [[ "${batch_last_id:-0}" -gt 0 ]] && last_id="$batch_last_id"
                done < <(echo "$events" | jq -c '.[]' 2>/dev/null)
                [[ "$last_id" -gt 0 ]] && db_set_consumer_offset "eventbus-subscribe-$$" "$last_id" 2>/dev/null || true
            fi
        else
            # Fallback: tail the JSONL
            [[ ! -f "$EVENTS_FILE" ]] && touch "$EVENTS_FILE"
            tail -n 0 -f "$EVENTS_FILE" 2>/dev/null | while IFS= read -r line; do
                if [[ -z "$filter" ]] || echo "$line" | jq -r '.type // ""' 2>/dev/null | grep -q "$filter"; then
                    echo "$line"
                fi
            done
            return
        fi
        sleep "$poll_interval"
    done
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
    if command -v fswatch >/dev/null 2>&1; then
        # macOS with fswatch
        fswatch -r "$watch_dir" | while read -r file; do
            local payload
            payload="{\"file\": \"$file\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
            cmd_publish "file.changed" "watcher" "$(generate_uuid)" "$payload"
        done
    elif command -v inotifywait >/dev/null 2>&1; then
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

    info "Replaying events from the last ${minutes} minutes..."
    echo ""

    local cutoff_epoch
    cutoff_epoch=$(($(date +%s) - (minutes * 60)))

    if db_available 2>/dev/null; then
        sqlite3 -json "$DB_FILE" "SELECT * FROM events WHERE ts_epoch >= $cutoff_epoch ORDER BY id ASC;" 2>/dev/null | jq -c '.[]' 2>/dev/null | while IFS= read -r event; do
            [[ -n "$event" ]] && echo "$event"
        done
    elif [[ -f "$EVENTS_FILE" ]]; then
        local cutoff_iso
        cutoff_iso="$(date -u -j -f %s "$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @"$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
        grep "ts" "$EVENTS_FILE" 2>/dev/null | while read -r line; do
            local ts
            ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null)
            [[ -n "$ts" && "$ts" > "$cutoff_iso" ]] && echo "$line"
        done
    else
        warn "Event bus is empty or does not exist yet"
    fi
}

# ─── Status command ────────────────────────────────────────────────────────
cmd_status() {
    ensure_eventbus_dir

    echo ""
    echo -e "${CYAN}${BOLD}Event Bus Status${RESET}"
    echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo ""

    if db_available 2>/dev/null; then
        local total_events last_event_ts
        total_events=$(_db_query "SELECT COUNT(*) FROM events;" 2>/dev/null || echo "0")
        last_event_ts=$(_db_query "SELECT ts FROM events ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "never")
        echo -e "  ${CYAN}Event Store:${RESET} SQLite ($DB_FILE)"
        echo -e "  ${CYAN}Total Events:${RESET} ${BOLD}${total_events}${RESET}"
        echo -e "  ${CYAN}Last Event:${RESET} $last_event_ts"
        echo ""
        if [[ "${total_events:-0}" -gt 0 ]]; then
            echo -e "  ${PURPLE}${BOLD}Events by Type${RESET}"
            _db_query "SELECT type, COUNT(*) as cnt FROM events GROUP BY type ORDER BY cnt DESC;" 2>/dev/null | while IFS='|' read -r etype count; do
                printf "    ${DIM}%-40s${RESET} %3d events\n" "$etype" "$count"
            done
        fi
    elif [[ -f "$EVENTS_FILE" ]]; then
        local total_events last_event_ts
        total_events=$(wc -l < "$EVENTS_FILE" || echo 0)
        last_event_ts=$(tail -1 "$EVENTS_FILE" | jq -r '.ts // "never"' 2>/dev/null || echo "never")
        echo -e "  ${CYAN}Event Store:${RESET} $EVENTS_FILE (file fallback)"
        echo -e "  ${CYAN}Total Events:${RESET} ${BOLD}${total_events}${RESET}"
        echo -e "  ${CYAN}Last Event:${RESET} $last_event_ts"
        echo ""
        if [[ "${total_events:-0}" -gt 0 ]]; then
            echo -e "  ${PURPLE}${BOLD}Events by Type${RESET}"
            jq -r '.type' "$EVENTS_FILE" 2>/dev/null | sort | uniq -c | sort -rn | while read -r count type; do
                printf "    ${DIM}%-40s${RESET} %3d events\n" "$type" "$count"
            done
        fi
    else
        echo -e "  ${YELLOW}Event bus not yet initialized${RESET}"
    fi
    echo ""
}

# ─── Clean command (remove old events) ─────────────────────────────────────
cmd_clean() {
    local ttl_days="${1:-$EVENT_TTL_DAYS}"

    ensure_eventbus_dir

    local cutoff_epoch
    cutoff_epoch=$(($(date +%s) - (ttl_days * 86400)))
    local cutoff_iso
    cutoff_iso="$(date -u -j -f %s "$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @"$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

    if db_available 2>/dev/null; then
        local old_count new_count removed
        old_count=$(_db_query "SELECT COUNT(*) FROM events;" 2>/dev/null || echo 0)
        _db_exec "DELETE FROM events WHERE ts < '${cutoff_iso}';" 2>/dev/null || true
        new_count=$(_db_query "SELECT COUNT(*) FROM events;" 2>/dev/null || echo 0)
        removed=$((old_count - new_count))
        success "Removed $removed old events. Remaining: $new_count"
    elif [[ -f "$EVENTS_FILE" ]]; then
        info "Cleaning events older than ${ttl_days} days..."
        local old_count tmp_file new_count removed
        old_count=$(grep -c "ts" "$EVENTS_FILE" 2>/dev/null || echo 0)
        tmp_file="$(mktemp)"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local ts
            ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null)
            [[ -n "$ts" && "$ts" > "$cutoff_iso" ]] && echo "$line" >> "$tmp_file"
        done < "$EVENTS_FILE"
        mv "$tmp_file" "$EVENTS_FILE"
        new_count=$(wc -l < "$EVENTS_FILE" || echo 0)
        removed=$((old_count - new_count))
        success "Removed $removed old events. Remaining: $new_count"
    else
        success "Event bus is empty"
    fi
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
