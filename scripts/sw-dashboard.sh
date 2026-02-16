#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright dashboard — Fleet Command Dashboard                          ║
# ║  Real-time WebSocket dashboard for fleet monitoring                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.1"
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
UNDERLINE='\033[4m'

# ─── Paths ──────────────────────────────────────────────────────────────────
TEAMS_DIR="${HOME}/.shipwright"
PID_FILE="${TEAMS_DIR}/dashboard.pid"
LOG_DIR="${TEAMS_DIR}/logs"
LOG_FILE="${LOG_DIR}/dashboard.log"
EVENTS_FILE="${TEAMS_DIR}/events.jsonl"
DEFAULT_PORT=8767

# ─── Header ────────────────────────────────────────────────────────────────
dashboard_header() {
    echo ""
    echo -e "${CYAN}${BOLD}╭─────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}${BOLD}│${RESET}  ${BOLD}⚓ Shipwright Fleet Command Dashboard${RESET}  ${CYAN}${BOLD}│${RESET}"
    echo -e "${CYAN}${BOLD}│${RESET}  ${DIM}v${VERSION}${RESET}                               ${CYAN}${BOLD}│${RESET}"
    echo -e "${CYAN}${BOLD}╰─────────────────────────────────────────╯${RESET}"
    echo ""
}

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    dashboard_header
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright dashboard${RESET} [command] [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}start${RESET}              Start the dashboard server ${DIM}(background)${RESET}"
    echo -e "  ${CYAN}stop${RESET}               Stop the dashboard server"
    echo -e "  ${CYAN}status${RESET}             Show dashboard server status"
    echo -e "  ${CYAN}open${RESET}               Open dashboard in browser"
    echo -e "  ${CYAN}help${RESET}               Show this help message"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--port${RESET} <N>         Port to run on ${DIM}(default: ${DEFAULT_PORT})${RESET}"
    echo -e "  ${CYAN}--foreground${RESET}       Run in foreground ${DIM}(don't daemonize)${RESET}"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright dashboard${RESET}                # Start in foreground"
    echo -e "  ${DIM}shipwright dashboard start${RESET}           # Start in background"
    echo -e "  ${DIM}shipwright dashboard start --port 9000${RESET}"
    echo -e "  ${DIM}shipwright dashboard open${RESET}            # Open in browser"
    echo -e "  ${DIM}shipwright dashboard stop${RESET}            # Stop background server"
    echo -e "  ${DIM}shipwright dash status${RESET}               # Check if running"
    echo ""
}

# ─── Prerequisite Check ────────────────────────────────────────────────────
check_bun() {
    if ! command -v bun &>/dev/null; then
        error "Bun is required but not installed"
        info "Install Bun: ${UNDERLINE}https://bun.sh${RESET}"
        exit 1
    fi
}

# ─── Find Server ───────────────────────────────────────────────────────────
find_server() {
    # Look for dashboard/server.ts relative to the script's repo location
    local repo_dir
    repo_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
    local server_ts="${repo_dir}/dashboard/server.ts"

    if [[ ! -f "$server_ts" ]]; then
        # Also check in installed locations
        for search_dir in \
            "${HOME}/.local/share/shipwright/dashboard" \
            "${HOME}/.shipwright/dashboard"; do
            if [[ -f "${search_dir}/server.ts" ]]; then
                server_ts="${search_dir}/server.ts"
                break
            fi
        done
    fi

    if [[ ! -f "$server_ts" ]]; then
        error "Dashboard server not found at ${server_ts}"
        info "Expected at: ${DIM}${repo_dir}/dashboard/server.ts${RESET}"
        exit 1
    fi

    echo "$server_ts"
}

# ─── Is Running? ───────────────────────────────────────────────────────────
is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

get_pid() {
    cat "$PID_FILE" 2>/dev/null || true
}

# ─── Start (Background) ───────────────────────────────────────────────────
dashboard_start_bg() {
    local port="$1"

    dashboard_header

    if is_running; then
        local pid
        pid=$(get_pid)
        error "Dashboard already running (PID: ${pid})"
        info "Use ${CYAN}shipwright dashboard stop${RESET} to stop it first"
        exit 1
    fi

    check_bun

    local server_ts
    server_ts=$(find_server)

    # Ensure directories exist
    mkdir -p "$LOG_DIR" "$TEAMS_DIR"

    info "Starting dashboard server on port ${CYAN}${port}${RESET}..."

    # Start in background
    nohup bun run "$server_ts" "$port" > "$LOG_FILE" 2>&1 &
    local bg_pid=$!

    # Write PID file
    echo "$bg_pid" > "$PID_FILE"

    # Wait briefly and verify process is alive
    sleep 1

    if kill -0 "$bg_pid" 2>/dev/null; then
        success "Dashboard started (PID: ${bg_pid})"
        echo ""
        echo -e "  ${BOLD}URL:${RESET}  ${UNDERLINE}http://localhost:${port}${RESET}"
        echo -e "  ${BOLD}PID:${RESET}  ${bg_pid}"
        echo -e "  ${BOLD}Log:${RESET}  ${DIM}${LOG_FILE}${RESET}"
        echo ""
        info "Open in browser:  ${DIM}shipwright dashboard open${RESET}"
        info "Connect agents:  ${DIM}shipwright connect start --url http://localhost:${port}${RESET}"
        info "Stop server:     ${DIM}shipwright dashboard stop${RESET}"

        emit_event "dashboard.started" \
            "pid=$bg_pid" \
            "port=$port"
    else
        rm -f "$PID_FILE"
        error "Dashboard failed to start"
        info "Check logs: ${DIM}cat ${LOG_FILE}${RESET}"
        exit 1
    fi
}

# ─── Start (Foreground) ───────────────────────────────────────────────────
dashboard_start_fg() {
    local port="$1"

    dashboard_header

    if is_running; then
        local pid
        pid=$(get_pid)
        error "Dashboard already running in background (PID: ${pid})"
        info "Use ${CYAN}shipwright dashboard stop${RESET} to stop it first"
        exit 1
    fi

    check_bun

    local server_ts
    server_ts=$(find_server)

    mkdir -p "$TEAMS_DIR"

    info "Starting dashboard server on port ${CYAN}${port}${RESET} ${DIM}(foreground)${RESET}"
    echo -e "  ${BOLD}URL:${RESET}  ${UNDERLINE}http://localhost:${port}${RESET}"
    echo -e "  ${BOLD}Connect:${RESET} ${DIM}shipwright connect start --url http://localhost:${port}${RESET}"
    echo -e "  ${DIM}Press Ctrl-C to stop${RESET}"
    echo ""

    emit_event "dashboard.started" \
        "pid=$$" \
        "port=$port" \
        "mode=foreground"

    # Run in foreground — exec replaces this process
    exec bun run "$server_ts" "$port"
}

# ─── Stop ───────────────────────────────────────────────────────────────────
dashboard_stop() {
    dashboard_header

    if [[ ! -f "$PID_FILE" ]]; then
        error "No dashboard PID file found"
        info "Is the dashboard running?"
        exit 1
    fi

    local pid
    pid=$(get_pid)

    if [[ -z "$pid" ]]; then
        error "Empty PID file"
        rm -f "$PID_FILE"
        exit 1
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        warn "Dashboard process (PID: ${pid}) is not running — cleaning up"
        rm -f "$PID_FILE"
        return 0
    fi

    info "Stopping dashboard (PID: ${pid})..."

    kill "$pid" 2>/dev/null || true

    # Wait for graceful shutdown (up to 5s)
    local wait_secs=0
    while kill -0 "$pid" 2>/dev/null && [[ $wait_secs -lt 5 ]]; do
        sleep 1
        wait_secs=$((wait_secs + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        warn "Dashboard didn't stop gracefully — sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"

    success "Dashboard stopped"

    emit_event "dashboard.stopped" \
        "pid=$pid"
}

# ─── Status ─────────────────────────────────────────────────────────────────
dashboard_status() {
    dashboard_header

    if is_running; then
        local pid
        pid=$(get_pid)
        echo -e "  ${GREEN}●${RESET} ${BOLD}Running${RESET} ${DIM}(PID: ${pid})${RESET}"

        # Try to get port from /proc or lsof
        local port=""
        if command -v lsof &>/dev/null; then
            port=$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$pid" 2>/dev/null | grep -oE ':\d+' | head -1 | tr -d ':' || true)
        fi

        if [[ -n "$port" ]]; then
            echo -e "  ${BOLD}Port:${RESET}    ${port}"
            echo -e "  ${BOLD}URL:${RESET}     ${UNDERLINE}http://localhost:${port}${RESET}"
        fi

        echo -e "  ${BOLD}PID:${RESET}     ${pid}"

        # Uptime from PID file modification time
        if [[ -f "$PID_FILE" ]]; then
            local pid_mtime
            if [[ "$(uname)" == "Darwin" ]]; then
                pid_mtime=$(stat -f %m "$PID_FILE" 2>/dev/null || echo "0")
            else
                pid_mtime=$(stat -c %Y "$PID_FILE" 2>/dev/null || echo "0")
            fi
            if [[ "$pid_mtime" -gt 0 ]]; then
                local uptime_secs=$(( $(now_epoch) - pid_mtime ))
                local uptime_str
                if [[ "$uptime_secs" -ge 3600 ]]; then
                    uptime_str=$(printf "%dh %dm %ds" $((uptime_secs/3600)) $((uptime_secs%3600/60)) $((uptime_secs%60)))
                elif [[ "$uptime_secs" -ge 60 ]]; then
                    uptime_str=$(printf "%dm %ds" $((uptime_secs/60)) $((uptime_secs%60)))
                else
                    uptime_str=$(printf "%ds" "$uptime_secs")
                fi
                echo -e "  ${BOLD}Uptime:${RESET}  ${uptime_str}"
            fi
        fi

        # Try to get health info from the server
        if [[ -n "$port" ]]; then
            local health
            health=$(curl -s --max-time 2 "http://localhost:${port}/api/health" 2>/dev/null || true)
            if [[ -n "$health" ]] && command -v jq &>/dev/null; then
                local connections
                connections=$(echo "$health" | jq -r '.connections // empty' 2>/dev/null || true)
                if [[ -n "$connections" ]]; then
                    echo -e "  ${BOLD}Clients:${RESET} ${connections} WebSocket connection(s)"
                fi
            fi
        fi

        echo -e "  ${BOLD}Log:${RESET}     ${DIM}${LOG_FILE}${RESET}"
    else
        echo -e "  ${RED}●${RESET} ${BOLD}Stopped${RESET}"

        if [[ -f "$PID_FILE" ]]; then
            warn "Stale PID file found — cleaning up"
            rm -f "$PID_FILE"
        fi
    fi

    echo ""
}

# ─── Open ───────────────────────────────────────────────────────────────────
dashboard_open() {
    local port="$1"

    # Try to detect port from running server
    if is_running; then
        local pid
        pid=$(get_pid)
        if command -v lsof &>/dev/null; then
            local detected_port
            detected_port=$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$pid" 2>/dev/null | grep -oE ':\d+' | head -1 | tr -d ':' || true)
            if [[ -n "$detected_port" ]]; then
                port="$detected_port"
            fi
        fi
    else
        warn "Dashboard doesn't appear to be running"
        info "Start it first: ${DIM}shipwright dashboard start${RESET}"
        exit 1
    fi

    local url="http://localhost:${port}"
    info "Opening ${UNDERLINE}${url}${RESET}"

    if open_url "$url" 2>/dev/null; then
        : # opened via compat.sh
    elif command -v powershell.exe &>/dev/null; then
        powershell.exe -Command "Start-Process '$url'" 2>/dev/null
    else
        error "No browser opener found"
        info "Open manually: ${UNDERLINE}${url}${RESET}"
        exit 1
    fi
}

# ─── Parse Args ─────────────────────────────────────────────────────────────
SUBCOMMAND=""
PORT="$DEFAULT_PORT"
FOREGROUND=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        start)
            SUBCOMMAND="start"
            shift
            ;;
        stop)
            SUBCOMMAND="stop"
            shift
            ;;
        status)
            SUBCOMMAND="status"
            shift
            ;;
        open)
            SUBCOMMAND="open"
            shift
            ;;
        help|--help|-h)
            show_help
            exit 0
            ;;
        --port)
            if [[ -z "${2:-}" ]]; then
                error "--port requires a value"
                exit 1
            fi
            PORT="$2"
            shift 2
            ;;
        --foreground|-f)
            FOREGROUND=true
            shift
            ;;
        --version|-v)
            echo "shipwright dashboard v${VERSION}"
            exit 0
            ;;
        *)
            error "Unknown argument: ${1}"
            echo ""
            show_help
            exit 1
            ;;
    esac
done

# ─── Command Router ─────────────────────────────────────────────────────────

# No subcommand = foreground mode (like running `shipwright dashboard`)
if [[ -z "$SUBCOMMAND" ]]; then
    dashboard_start_fg "$PORT"
    exit 0
fi

case "$SUBCOMMAND" in
    start)
        if [[ "$FOREGROUND" == "true" ]]; then
            dashboard_start_fg "$PORT"
        else
            dashboard_start_bg "$PORT"
        fi
        ;;
    stop)
        dashboard_stop
        ;;
    status)
        dashboard_status
        ;;
    open)
        dashboard_open "$PORT"
        ;;
esac
