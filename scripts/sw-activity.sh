#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright activity — Live agent activity stream                         ║
# ║  Watch Claude think in real-time with formatted event streaming           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[ -f "$SCRIPT_DIR/lib/compat.sh" ] && source "$SCRIPT_DIR/lib/compat.sh"

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
# ─── Event File & Filters ─────────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"
FILTER_TYPE=""
FILTER_AGENT=""
FILTER_TEAM=""
FILTER_STAGE=""
FILTER_START=""
FILTER_END=""

# Event type icons for terminal display (bash 3.2 compatible)
get_icon_for_type() {
    local type="$1"
    case "$type" in
        commit)            echo "📦" ;;
        test.passed)       echo "✅" ;;
        test.failed)       echo "❌" ;;
        build)             echo "🔨" ;;
        review)            echo "👀" ;;
        stage.started)     echo "▶" ;;
        stage.completed)   echo "⏹" ;;
        pipeline.started)  echo "🚀" ;;
        pipeline.completed) echo "🎯" ;;
        file.modified)     echo "✏" ;;
        error)             echo "⚠" ;;
        *)                 echo "•" ;;
    esac
}

# Color agents by a simple hash (bash 3.2 compatible)
agent_color() {
    local agent="$1"
    local hash=0
    local i
    for (( i=0; i<${#agent}; i++ )); do
        hash=$(( (hash << 5) - hash + $(printf '%d' "'${agent:$i:1}") ))
    done
    # Simple modulo to pick a color
    local idx=$(( (hash % 5 + 5) % 5 ))
    case "$idx" in
        0) echo "$CYAN" ;;
        1) echo "$PURPLE" ;;
        2) echo "$BLUE" ;;
        3) echo "$GREEN" ;;
        4) echo "$YELLOW" ;;
    esac
}

# ─── Formatting Helpers ────────────────────────────────────────────────────────
format_timestamp() {
    local ts="$1"
    echo "$ts" | sed 's/T/ /; s/Z//'
}

get_event_icon() {
    local event_type="$1"
    get_icon_for_type "$event_type"
}

format_event_line() {
    local ts="$1"
    local type="$2"
    local agent="${3:-system}"
    local message="$4"

    local ts_fmt
    ts_fmt=$(format_timestamp "$ts")
    local icon
    icon=$(get_event_icon "$type")
    local agent_color_code
    agent_color_code=$(agent_color "$agent")

    printf "%s  %s  ${BOLD}%s${RESET}  %s  %s\n" \
        "${DIM}${ts_fmt}${RESET}" \
        "$icon" \
        "${agent_color_code}${agent:0:12}${RESET}" \
        "${BLUE}${type}${RESET}" \
        "$message"
}

# ─── Live Watch Mode (default) ──────────────────────────────────────────────────
cmd_watch() {
    local poll_interval=1
    local last_size=0

    info "Watching agent activity (Ctrl+C to stop)..."
    echo ""

    # Create initial size check
    if [ ! -f "$EVENTS_FILE" ]; then
        warn "No events file yet (waiting for first pipeline run)..."
        touch "$EVENTS_FILE"
    fi

    last_size=$(wc -c < "$EVENTS_FILE" 2>/dev/null || echo 0)

    while true; do
        local current_size
        current_size=$(wc -c < "$EVENTS_FILE" 2>/dev/null || echo 0)

        # If file grew, tail new lines
        if [ $current_size -gt $last_size ]; then
            tail -c $((current_size - last_size)) "$EVENTS_FILE" 2>/dev/null | while IFS= read -r line; do
                [ -z "$line" ] && continue

                # Extract JSON fields
                local ts type agent stage issue
                ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null || true)
                type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null || true)
                agent=$(echo "$line" | jq -r '.agent_id // .agent // "system"' 2>/dev/null || true)
                stage=$(echo "$line" | jq -r '.stage // ""' 2>/dev/null || true)
                issue=$(echo "$line" | jq -r '.issue // ""' 2>/dev/null || true)

                # Apply filters
                if [ -n "$FILTER_TYPE" ] && [ "$type" != "$FILTER_TYPE" ]; then
                    continue
                fi
                if [ -n "$FILTER_AGENT" ] && [ "$agent" != "$FILTER_AGENT" ]; then
                    continue
                fi
                if [ -n "$FILTER_STAGE" ] && [ "$stage" != "$FILTER_STAGE" ]; then
                    continue
                fi

                # Format message based on event type
                local msg=""
                case "$type" in
                    stage.started)
                        msg="Started ${stage} stage"
                        if [ -n "$issue" ]; then
                            msg="$msg (issue #${issue})"
                        fi
                        ;;
                    stage.completed)
                        local duration
                        duration=$(echo "$line" | jq -r '.duration_s // "?"' 2>/dev/null || true)
                        msg="Completed ${stage} in ${duration}s"
                        ;;
                    pipeline.started)
                        local pipeline
                        pipeline=$(echo "$line" | jq -r '.pipeline // "unknown"' 2>/dev/null || true)
                        msg="Started ${pipeline} pipeline"
                        ;;
                    pipeline.completed)
                        local result
                        result=$(echo "$line" | jq -r '.result // "?"' 2>/dev/null || true)
                        msg="Pipeline finished: ${result}"
                        ;;
                    file.modified)
                        local file
                        file=$(echo "$line" | jq -r '.file // "?"' 2>/dev/null || true)
                        msg="Modified: ${file}"
                        ;;
                    test.passed)
                        local test_count
                        test_count=$(echo "$line" | jq -r '.count // "1"' 2>/dev/null || true)
                        msg="Tests passed: ${test_count}"
                        ;;
                    test.failed)
                        local failure
                        failure=$(echo "$line" | jq -r '.reason // "unknown"' 2>/dev/null || true)
                        msg="Test failed: ${failure}"
                        ;;
                    commit)
                        local commit_msg
                        commit_msg=$(echo "$line" | jq -r '.message // "?"' 2>/dev/null | cut -c1-50)
                        msg="Committed: ${commit_msg}"
                        ;;
                    *)
                        msg="$type"
                        ;;
                esac

                format_event_line "$ts" "$type" "$agent" "$msg"
            done
            last_size=$current_size
        fi

        sleep "$poll_interval"
    done
}

# ─── Snapshot Mode ────────────────────────────────────────────────────────────
cmd_snapshot() {
    [ ! -f "$EVENTS_FILE" ] && { error "No events yet"; exit 1; }

    info "Current agent activity snapshot:"
    echo ""

    # Group by agent, show last event for each
    local last_agent=""
    local last_time=""
    local last_event=""

    tac "$EVENTS_FILE" 2>/dev/null | while IFS= read -r line; do
        [ -z "$line" ] && continue

        local agent stage ts
        agent=$(echo "$line" | jq -r '.agent_id // .agent // "system"' 2>/dev/null || true)
        stage=$(echo "$line" | jq -r '.stage // ""' 2>/dev/null || true)
        ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null || true)

        # Skip if we've seen this agent already
        if [ "$agent" = "$last_agent" ]; then
            continue
        fi

        local msg
        local type
        type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null || true)
        msg=$(echo "$line" | jq -r '.type // "unknown"' 2>/dev/null || true)

        printf "%s  ${BOLD}%s${RESET}\n" \
            "${DIM}${ts}${RESET}" \
            "$(agent_color "$agent")${agent}${RESET}"
        printf "  └─ %s (${DIM}${type}${RESET})\n" "$msg"
        echo ""

        last_agent="$agent"
    done
}

# ─── History Mode ────────────────────────────────────────────────────────────
cmd_history() {
    local range="$1"  # "1h", "10m", "all", or ISO timestamp

    [ ! -f "$EVENTS_FILE" ] && { error "No events yet"; exit 1; }

    local cutoff_epoch=0

    # Parse time range
    if [ "$range" = "all" ]; then
        cutoff_epoch=0
    elif echo "$range" | grep -qE '^[0-9]+[smhd]$'; then
        local num="${range%[smhd]}"
        local unit="${range##[0-9]}"
        local seconds=0
        case "$unit" in
            s) seconds="$num" ;;
            m) seconds=$((num * 60)) ;;
            h) seconds=$((num * 3600)) ;;
            d) seconds=$((num * 86400)) ;;
        esac
        cutoff_epoch=$(($(date +%s) - seconds))
    else
        # Assume ISO timestamp
        cutoff_epoch=$(date -d "$range" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$range" +%s 2>/dev/null || echo 0)
    fi

    info "Activity from last ${range}:"
    echo ""

    grep -v '^$' "$EVENTS_FILE" 2>/dev/null | while IFS= read -r line; do
        [ -z "$line" ] && continue

        local epoch agent ts type
        epoch=$(echo "$line" | jq -r '.ts_epoch // 0' 2>/dev/null || true)
        agent=$(echo "$line" | jq -r '.agent_id // .agent // "system"' 2>/dev/null || true)
        ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null || true)
        type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null || true)

        if [ $epoch -lt $cutoff_epoch ]; then
            continue
        fi

        local msg="$type"
        case "$type" in
            stage.started)
                local stage
                stage=$(echo "$line" | jq -r '.stage // ""' 2>/dev/null || true)
                msg="Started ${stage} stage"
                ;;
            pipeline.completed)
                local result
                result=$(echo "$line" | jq -r '.result // "?"' 2>/dev/null || true)
                msg="Pipeline completed: ${result}"
                ;;
        esac

        format_event_line "$ts" "$type" "$agent" "$msg"
    done
}

# ─── Statistics Mode ────────────────────────────────────────────────────────────
cmd_stats() {
    [ ! -f "$EVENTS_FILE" ] && { error "No events yet"; exit 1; }

    info "Activity statistics:"
    echo ""

    local total_events=0
    local commits=0
    local tests=0
    local stages=0
    local pipelines=0
    local agents_seen=""
    local start_time=""
    local end_time=""

    # Read directly to avoid subshell issues
    echo "DEBUG: Starting read loop..." >&2
    while IFS= read -r line; do
        [ -z "$line" ] && continue

        total_events=$((total_events + 1))

        local type agent ts
        type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null || true)
        agent=$(echo "$line" | jq -r '.agent_id // .agent // "system"' 2>/dev/null || true)
        ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null || true)

        # Track unique agents
        if [ -n "$agent" ] && [ "$agent" != "system" ]; then
            agents_seen="${agents_seen}${agent}"$'\n'
        fi

        # Track event types
        case "$type" in
            commit) commits=$((commits + 1)) ;;
            test.*) tests=$((tests + 1)) ;;
            stage.*) stages=$((stages + 1)) ;;
            pipeline.*) pipelines=$((pipelines + 1)) ;;
        esac

        # Track first and last event times
        if [ -z "$start_time" ]; then
            start_time="$ts"
        fi
        end_time="$ts"
    done < <(grep -v '^$' "$EVENTS_FILE" 2>/dev/null)

    echo "DEBUG: Read complete, total=$total_events" >&2
    echo "DEBUG: agents_seen length: ${#agents_seen}" >&2
    local unique_agents
    echo "DEBUG: About to compute unique..." >&2
    unique_agents=$(sort -u <<< "$agents_seen" | grep -v '^$' | wc -l | tr -d ' ')
    echo "DEBUG: unique_agents=$unique_agents" >&2

    echo "DEBUG: About to print results..." >&2
    printf "${BOLD}Total Events:${RESET} %d\n" "$total_events"
    printf "${BOLD}Commits:${RESET} %d\n" "$commits"
    printf "${BOLD}Tests:${RESET} %d\n" "$tests"
    printf "${BOLD}Stages:${RESET} %d\n" "$stages"
    printf "${BOLD}Pipelines:${RESET} %d\n" "$pipelines"
    printf "${BOLD}Unique Agents:${RESET} %d\n" "$unique_agents"
    printf "${BOLD}Time Range:${RESET} ${DIM}%s${RESET} to ${DIM}%s${RESET}\n" "$start_time" "$end_time"
}

# ─── Agents Mode ────────────────────────────────────────────────────────────────
cmd_agents() {
    [ ! -f "$EVENTS_FILE" ] && { error "No events yet"; exit 1; }

    info "Known agents and last activity:"
    echo ""

    # Use tac to go backwards and capture unique agents
    tac "$EVENTS_FILE" 2>/dev/null | while IFS= read -r line; do
        [ -z "$line" ] && continue

        local agent ts type
        agent=$(echo "$line" | jq -r '.agent_id // .agent // "system"' 2>/dev/null || true)
        ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null || true)
        type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null || true)

        if [ "$agent" = "system" ] || [ -z "$agent" ]; then
            continue
        fi

        # Only print once per agent (first occurrence in reverse iteration)
        local seen_file="${HOME}/.shipwright/activity-agents-seen"
        mkdir -p "$(dirname "$seen_file")"
        if ! grep -q "^${agent}$" "$seen_file" 2>/dev/null; then
            printf "%s  ${BOLD}%s${RESET}  ${DIM}%s${RESET}  ${BLUE}%s${RESET}\n" \
                "$ts" \
                "$(agent_color "$agent")${agent}${RESET}" \
                "$type" \
                ""
            echo "$agent" >> "$seen_file"
        fi
    done
}

# ─── Help ────────────────────────────────────────────────────────────────────
cmd_help() {
    echo -e "${CYAN}${BOLD}shipwright activity${RESET} — Live agent activity stream"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo "  shipwright activity [subcommand] [options]"
    echo ""
    echo -e "${BOLD}SUBCOMMANDS${RESET}"
    echo "  watch                      Live stream of agent activity (default)"
    echo "  snapshot                   Current state of all active agents"
    echo "  history [range]            Replay past activity (e.g., '1h', '10m', 'all')"
    echo "  stats                      Running counters (events, commits, tests, agents)"
    echo "  agents                     List known agents and last activity"
    echo "  help                       Show this help message"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo "  --type <type>              Filter events by type (e.g., 'stage.completed')"
    echo "  --agent <name>             Filter by agent name"
    echo "  --team <name>              Filter by team"
    echo "  --stage <name>             Filter by pipeline stage (e.g., 'build')"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo "  ${DIM}shipwright activity${RESET}                    # Live stream"
    echo "  ${DIM}shipwright activity watch --type stage.*${RESET}  # Only stage events"
    echo "  ${DIM}shipwright activity history 1h${RESET}           # Last hour"
    echo "  ${DIM}shipwright activity snapshot${RESET}             # Current state"
    echo "  ${DIM}shipwright activity stats${RESET}                # Counters"
}

# ─── Main ────────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-watch}"
    shift 2>/dev/null || true

    # Parse global options
    while [ $# -gt 0 ]; do
        case "$1" in
            --type)   FILTER_TYPE="$2"; shift 2 ;;
            --agent)  FILTER_AGENT="$2"; shift 2 ;;
            --team)   FILTER_TEAM="$2"; shift 2 ;;
            --stage)  FILTER_STAGE="$2"; shift 2 ;;
            *)        break ;;
        esac
    done

    case "$cmd" in
        watch)    cmd_watch "$@" ;;
        snapshot) cmd_snapshot ;;
        history)  cmd_history "${1:-1h}" ;;
        stats)    cmd_stats ;;
        agents)   cmd_agents ;;
        help|-h|--help) cmd_help ;;
        *)
            error "Unknown command: $cmd"
            cmd_help
            exit 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
