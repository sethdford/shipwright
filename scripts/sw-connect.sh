#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-connect.sh — Sync local state to team dashboard                    ║
# ║                                                                          ║
# ║  Background heartbeat process that streams developer status, daemon      ║
# ║  state, and events to a remote or local Shipwright dashboard.            ║
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

# ─── Constants ──────────────────────────────────────────────────────────────
SHIPWRIGHT_DIR="$HOME/.shipwright"
PID_FILE="$SHIPWRIGHT_DIR/connect.pid"
TEAM_CONFIG="$SHIPWRIGHT_DIR/team-config.json"
DAEMON_PID_FILE="$SHIPWRIGHT_DIR/daemon.pid"
DAEMON_STATE_FILE="$SHIPWRIGHT_DIR/daemon-state.json"
EVENTS_FILE="$SHIPWRIGHT_DIR/events.jsonl"
CONNECT_LOG="$SHIPWRIGHT_DIR/connect.log"
DEFAULT_URL="http://localhost:8767"
HEARTBEAT_INTERVAL=10

ensure_dir() {
    mkdir -p "$SHIPWRIGHT_DIR"
}

# ─── Resolve identity ──────────────────────────────────────────────────────

resolve_developer_id() {
    if [[ -n "${DEVELOPER_ID:-}" ]]; then
        echo "$DEVELOPER_ID"
        return
    fi
    local git_name
    git_name="$(git config user.name 2>/dev/null || true)"
    if [[ -n "$git_name" ]]; then
        echo "$git_name"
        return
    fi
    echo "${USER:-unknown}"
}

resolve_machine_name() {
    if [[ -n "${MACHINE_NAME:-}" ]]; then
        echo "$MACHINE_NAME"
        return
    fi
    hostname -s 2>/dev/null || echo "unknown"
}

resolve_dashboard_url() {
    local url_flag="${1:-}"

    # 1. --url flag
    if [[ -n "$url_flag" ]]; then
        echo "$url_flag"
        return
    fi

    # 2. Environment variable
    if [[ -n "${DASHBOARD_URL:-}" ]]; then
        echo "$DASHBOARD_URL"
        return
    fi

    # 3. team-config.json
    if [[ -f "$TEAM_CONFIG" ]]; then
        local cfg_url
        cfg_url="$(jq -r '.dashboard_url // empty' "$TEAM_CONFIG" 2>/dev/null || true)"
        if [[ -n "$cfg_url" ]]; then
            echo "$cfg_url"
            return
        fi
    fi

    # 4. Default
    echo "$DEFAULT_URL"
}

# ─── Daemon state helpers ──────────────────────────────────────────────────

check_daemon_running() {
    if [[ -f "$DAEMON_PID_FILE" ]]; then
        local pid
        pid="$(cat "$DAEMON_PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return
        fi
    fi
    echo ""
}

get_active_jobs() {
    if [[ -f "$DAEMON_STATE_FILE" ]]; then
        jq -c '[.active_jobs // [] | .[] | {issue: .issue, title: (.title // ""), stage: (.stage // "")}]' "$DAEMON_STATE_FILE" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

get_queued_issues() {
    if [[ -f "$DAEMON_STATE_FILE" ]]; then
        jq -c '[.queued // [] | .[]]' "$DAEMON_STATE_FILE" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

# ─── Events delta ──────────────────────────────────────────────────────────

get_new_events() {
    local last_ts="$1"

    if [[ ! -f "$EVENTS_FILE" ]]; then
        echo "[]"
        return
    fi

    if [[ -z "$last_ts" || "$last_ts" == "null" ]]; then
        # First sync — send last 20 events
        tail -n 20 "$EVENTS_FILE" 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]"
    else
        # Send events newer than last_ts (events use "ts" field)
        jq -c --arg ts "$last_ts" 'select(.ts > $ts)' "$EVENTS_FILE" 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]"
    fi
}

get_latest_event_ts() {
    local events_json="$1"
    echo "$events_json" | jq -r 'if length > 0 then .[-1].ts // "" else "" end' 2>/dev/null || echo ""
}

# ─── Heartbeat loop ────────────────────────────────────────────────────────

run_heartbeat_loop() {
    local dashboard_url="$1"
    local developer_id="$2"
    local machine_name="$3"
    local full_hostname
    full_hostname="$(hostname 2>/dev/null || echo "unknown")"
    local platform
    platform="$(uname -s | tr '[:upper:]' '[:lower:]')"

    local last_event_ts=""
    local backoff=5
    local max_backoff=30
    local consecutive_failures=0

    # Load invite token from team config if present (for auth)
    local invite_token=""
    if [[ -f "$TEAM_CONFIG" ]]; then
        invite_token="$(jq -r '.invite_token // ""' "$TEAM_CONFIG" 2>/dev/null || true)"
    fi

    # Trap for graceful shutdown
    trap 'send_disconnect "$dashboard_url" "$developer_id" "$machine_name"; exit 0' SIGTERM SIGINT

    info "Connect heartbeat started (PID $$)"
    info "Dashboard: ${dashboard_url}"
    info "Developer: ${developer_id} @ ${machine_name}"

    while true; do
        # Collect state
        local daemon_pid
        daemon_pid="$(check_daemon_running)"
        local daemon_running="false"
        local daemon_pid_json="null"
        if [[ -n "$daemon_pid" ]]; then
            daemon_running="true"
            daemon_pid_json="$daemon_pid"
        fi

        local active_jobs
        active_jobs="$(get_active_jobs)"
        local queued
        queued="$(get_queued_issues)"
        local events
        events="$(get_new_events "$last_event_ts")"

        # Build JSON payload with jq
        local payload
        payload="$(jq -n \
            --arg developer_id "$developer_id" \
            --arg machine_name "$machine_name" \
            --arg hostname "$full_hostname" \
            --arg platform "$platform" \
            --argjson daemon_running "$daemon_running" \
            --argjson daemon_pid "$daemon_pid_json" \
            --argjson active_jobs "$active_jobs" \
            --argjson queued "$queued" \
            --argjson events "$events" \
            --arg ts "$(now_iso)" \
            --arg invite_token "$invite_token" \
            '{
                developer_id: $developer_id,
                machine_name: $machine_name,
                hostname: $hostname,
                platform: $platform,
                daemon_running: $daemon_running,
                daemon_pid: $daemon_pid,
                active_jobs: $active_jobs,
                queued: $queued,
                events: $events,
                ts: $ts
            } + (if $invite_token != "" then {invite_token: $invite_token} else {} end)')"

        # Send heartbeat
        local http_code
        http_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "${dashboard_url}/api/connect/heartbeat" 2>/dev/null || echo "000")"

        if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "204" ]]; then
            # Success — update event bookmark and reset backoff
            local new_ts
            new_ts="$(get_latest_event_ts "$events")"
            if [[ -n "$new_ts" ]]; then
                last_event_ts="$new_ts"
            fi
            backoff=5
            consecutive_failures=0
        else
            consecutive_failures=$((consecutive_failures + 1))
            if [[ "$consecutive_failures" -le 3 ]]; then
                echo "$(now_iso) WARN: Dashboard unreachable (HTTP $http_code), retrying in ${backoff}s" >> "$CONNECT_LOG"
            fi
            sleep "$backoff"
            # Exponential backoff: 5 → 10 → 20 → 30 (capped)
            backoff=$((backoff * 2))
            if [[ "$backoff" -gt "$max_backoff" ]]; then
                backoff="$max_backoff"
            fi
            continue
        fi

        sleep "$HEARTBEAT_INTERVAL"
    done
}

send_disconnect() {
    local dashboard_url="$1"
    local developer_id="$2"
    local machine_name="$3"

    local payload
    payload="$(jq -n \
        --arg developer_id "$developer_id" \
        --arg machine_name "$machine_name" \
        '{developer_id: $developer_id, machine_name: $machine_name}')"

    curl -s -o /dev/null --max-time 5 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${dashboard_url}/api/connect/disconnect" 2>/dev/null || true

    info "Disconnected from dashboard"
}

# ─── Start ──────────────────────────────────────────────────────────────────

cmd_start() {
    local url_flag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)
                url_flag="${2:-}"
                shift 2
                ;;
            --url=*)
                url_flag="${1#--url=}"
                shift
                ;;
            --help|-h)
                show_help
                return 0
                ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    ensure_dir

    # Check if already running
    if [[ -f "$PID_FILE" ]]; then
        local existing_pid
        existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            error "Connect already running (PID ${existing_pid})"
            echo -e "  ${DIM}Stop it first: shipwright connect stop${RESET}"
            return 1
        fi
        # Stale PID file — clean up
        rm -f "$PID_FILE"
    fi

    local dashboard_url
    dashboard_url="$(resolve_dashboard_url "$url_flag")"
    local developer_id
    developer_id="$(resolve_developer_id)"
    local machine_name
    machine_name="$(resolve_machine_name)"

    info "Starting connect to ${BOLD}${dashboard_url}${RESET}"
    info "Developer: ${BOLD}${developer_id}${RESET} @ ${BOLD}${machine_name}${RESET}"

    # Fork heartbeat loop to background
    run_heartbeat_loop "$dashboard_url" "$developer_id" "$machine_name" >> "$CONNECT_LOG" 2>&1 &
    local bg_pid=$!

    # Write PID file atomically
    local tmp_pid
    tmp_pid="$(mktemp "$SHIPWRIGHT_DIR/.connect-pid.XXXXXX")"
    echo "$bg_pid" > "$tmp_pid"
    mv "$tmp_pid" "$PID_FILE"

    success "Connect started (PID ${bg_pid})"
    echo -e "  ${DIM}Logs: ${CONNECT_LOG}${RESET}"
    echo -e "  ${DIM}Stop: shipwright connect stop${RESET}"
}

# ─── Stop ───────────────────────────────────────────────────────────────────

cmd_stop() {
    if [[ ! -f "$PID_FILE" ]]; then
        warn "Connect is not running (no PID file)"
        return 0
    fi

    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"

    if [[ -z "$pid" ]]; then
        warn "Empty PID file — cleaning up"
        rm -f "$PID_FILE"
        return 0
    fi

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        # Wait briefly for graceful shutdown
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt 5 ]]; do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        success "Connect stopped (PID ${pid})"
    else
        warn "Process ${pid} not running — cleaning up stale PID file"
    fi

    rm -f "$PID_FILE"
}

# ─── Status ─────────────────────────────────────────────────────────────────

cmd_status() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright Connect${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""

    local running=false
    local pid=""

    if [[ -f "$PID_FILE" ]]; then
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            running=true
        fi
    fi

    if [[ "$running" == "true" ]]; then
        echo -e "  Status:    ${GREEN}${BOLD}connected${RESET} (PID ${pid})"
    else
        echo -e "  Status:    ${RED}${BOLD}disconnected${RESET}"
    fi

    # Show dashboard URL
    local dashboard_url
    dashboard_url="$(resolve_dashboard_url "")"
    echo -e "  Dashboard: ${CYAN}${dashboard_url}${RESET}"

    # Show identity
    local developer_id
    developer_id="$(resolve_developer_id)"
    local machine_name
    machine_name="$(resolve_machine_name)"
    echo -e "  Developer: ${BOLD}${developer_id}${RESET}"
    echo -e "  Machine:   ${BOLD}${machine_name}${RESET}"

    # Show uptime if running
    if [[ "$running" == "true" && -n "$pid" ]]; then
        local start_time
        # macOS: ps -o lstart= gives human-readable start time
        start_time="$(ps -o lstart= -p "$pid" 2>/dev/null || true)"
        if [[ -n "$start_time" ]]; then
            echo -e "  Started:   ${DIM}${start_time}${RESET}"
        fi
    fi

    # Show team config if exists
    if [[ -f "$TEAM_CONFIG" ]]; then
        local team_name
        team_name="$(jq -r '.team_name // "—"' "$TEAM_CONFIG" 2>/dev/null || echo "—")"
        echo -e "  Team:      ${BOLD}${team_name}${RESET}"
    fi

    echo ""
}

# ─── Join ───────────────────────────────────────────────────────────────────

cmd_join() {
    local token=""
    local url_flag=""

    # Parse args: supports both positional and flag styles
    #   shipwright connect join <token>
    #   shipwright connect join --url <url> --token <token>
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token)  token="${2:-}"; shift 2 ;;
            --token=*) token="${1#--token=}"; shift ;;
            --url)    url_flag="${2:-}"; shift 2 ;;
            --url=*)  url_flag="${1#--url=}"; shift ;;
            --help|-h) show_help; return 0 ;;
            -*)       warn "Unknown flag: $1"; shift ;;
            *)
                # Positional: if no token yet, treat as token
                if [[ -z "$token" ]]; then
                    token="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$token" ]]; then
        error "Usage: shipwright connect join <token>"
        echo -e "  ${DIM}Or: shipwright connect join --url <dashboard-url> --token <token>${RESET}"
        echo -e "  ${DIM}Get a token from the dashboard: Settings → Team → Invite${RESET}"
        return 1
    fi

    ensure_dir

    # Determine dashboard URL to verify against
    local verify_url
    verify_url="${url_flag:-$(resolve_dashboard_url "")}"

    info "Verifying invite token against ${BOLD}${verify_url}${RESET}..."

    # Try invite token verification endpoint first
    local response
    response="$(curl -s --max-time 10 "${verify_url}/api/team/invite/${token}" 2>/dev/null || true)"

    if [[ -z "$response" ]]; then
        error "Could not reach dashboard at ${verify_url}"
        echo -e "  ${DIM}Make sure the dashboard is running: shipwright dashboard start${RESET}"
        return 1
    fi

    # Check if token is valid
    local valid
    valid="$(echo "$response" | jq -r '.valid // false' 2>/dev/null || echo "false")"

    if [[ "$valid" != "true" ]]; then
        local err_msg
        err_msg="$(echo "$response" | jq -r '.error // "Unknown error"' 2>/dev/null || echo "Unknown error")"
        error "Invalid invite token: ${err_msg}"
        return 1
    fi

    # Parse response
    local join_url join_team
    join_url="$(echo "$response" | jq -r '.dashboard_url // empty' 2>/dev/null || true)"
    join_team="$(echo "$response" | jq -r '.team_name // empty' 2>/dev/null || true)"

    if [[ -z "$join_url" ]]; then
        # Fallback: use the URL we verified against
        join_url="$verify_url"
    fi

    local developer_id
    developer_id="$(resolve_developer_id)"
    local machine_name
    machine_name="$(resolve_machine_name)"

    # Save team config atomically
    local tmp_config
    tmp_config="$(mktemp "$SHIPWRIGHT_DIR/.team-config.XXXXXX")"

    jq -n \
        --arg dashboard_url "$join_url" \
        --arg team_name "${join_team:-}" \
        --arg developer_id "$developer_id" \
        --arg machine_name "$machine_name" \
        --arg invite_token "$token" \
        --argjson auto_connect true \
        '{
            dashboard_url: $dashboard_url,
            team_name: $team_name,
            developer_id: $developer_id,
            machine_name: $machine_name,
            invite_token: $invite_token,
            auto_connect: $auto_connect
        }' > "$tmp_config"

    mv "$tmp_config" "$TEAM_CONFIG"

    success "Joined team ${BOLD}${join_team:-unknown}${RESET}"
    echo -e "  ${DIM}Dashboard: ${join_url}${RESET}"
    echo -e "  ${DIM}Config: ${TEAM_CONFIG}${RESET}"

    # Auto-start connection
    info "Starting connection..."
    cmd_start --url "$join_url"
}

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright Connect${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright connect <command> [options]"
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo -e "    ${CYAN}start${RESET} [--url <url>]    Start syncing local state to dashboard"
    echo -e "    ${CYAN}stop${RESET}                   Stop the connect process"
    echo -e "    ${CYAN}status${RESET}                 Show connection status"
    echo -e "    ${CYAN}join${RESET} <token>            Join a team using an invite token"
    echo ""
    echo -e "  ${BOLD}START OPTIONS${RESET}"
    echo -e "    --url <url>          Dashboard URL (default: from team-config or localhost:8767)"
    echo ""
    echo -e "  ${BOLD}IDENTITY${RESET}  ${DIM}(auto-detected, override with env vars)${RESET}"
    echo -e "    DEVELOPER_ID         Developer name (default: git user.name or \$USER)"
    echo -e "    MACHINE_NAME         Machine name (default: hostname -s)"
    echo -e "    DASHBOARD_URL        Dashboard URL (default: http://localhost:8767)"
    echo ""
    echo -e "  ${BOLD}EXAMPLES${RESET}"
    echo -e "    ${DIM}# Start syncing to local dashboard${RESET}"
    echo -e "    shipwright connect start"
    echo ""
    echo -e "    ${DIM}# Connect to a remote dashboard${RESET}"
    echo -e "    shipwright connect start --url http://team-server:8767"
    echo ""
    echo -e "    ${DIM}# Join a team with an invite token${RESET}"
    echo -e "    shipwright connect join abc123"
    echo ""
    echo -e "    ${DIM}# Check connection status${RESET}"
    echo -e "    shipwright connect status"
    echo ""
    echo -e "    ${DIM}# Stop syncing${RESET}"
    echo -e "    shipwright connect stop"
    echo ""
}

# ─── Command Router ────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        start)              cmd_start "$@" ;;
        stop)               cmd_stop ;;
        status)             cmd_status ;;
        join)               cmd_join "$@" ;;
        help|--help|-h)     show_help ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
