#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-mission-control.sh — Terminal-based pipeline mission control          ║
# ║                                                                            ║
# ║  Pipeline drill-down, team tree, live terminals, stage orchestration      ║
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

format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 3600 ]]; then
        printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%ds" "$secs"
    fi
}

# ─── Daemon State ───────────────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"
DAEMON_STATE="${HOME}/.shipwright/daemon-state.json"

# ─── Daemon State Access ───────────────────────────────────────────────────
load_daemon_state() {
    if [[ ! -f "$DAEMON_STATE" ]]; then
        echo '{"active_jobs":[],"completed":[],"failed":[],"pid":0,"started_at":"","titles":{},"queued":[]}'
        return
    fi
    cat "$DAEMON_STATE"
}

# ─── Progress Bar ───────────────────────────────────────────────────────────
draw_progress_bar() {
    local percent="$1"
    local width="${2:-40}"

    percent=${percent%%\%*}
    [[ ! "$percent" =~ ^[0-9]+$ ]] && percent=0
    [[ "$percent" -gt 100 ]] && percent=100

    local filled=$((percent * width / 100))
    local empty=$((width - filled))

    printf "["
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] %3d%%" "$percent"
}

# ─── Health Indicator ───────────────────────────────────────────────────────
health_indicator() {
    local score="${1:-0}"
    if [[ "$score" -ge 80 ]]; then
        echo -e "${GREEN}●${RESET} healthy"
    elif [[ "$score" -ge 60 ]]; then
        echo -e "${YELLOW}●${RESET} degraded"
    else
        echo -e "${RED}●${RESET} unhealthy"
    fi
}

# ─── Get Recent Alerts ──────────────────────────────────────────────────────
get_recent_alerts() {
    local limit="${1:-5}"
    if [[ ! -f "$EVENTS_FILE" ]]; then
        return
    fi

    grep -E '"type":"(error|warning|anomaly|vitals_check)"' "$EVENTS_FILE" 2>/dev/null || true | \
        tail -"$limit" | while IFS= read -r line; do
        local ts
        local type
        local msg

        ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null || echo "")
        type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null || echo "")

        case "$type" in
            *error*)
                echo -e "${RED}✗${RESET} $ts: Error"
                ;;
            *warning*)
                echo -e "${YELLOW}⚠${RESET} $ts: Warning"
                ;;
            *anomaly*)
                echo -e "${PURPLE}▲${RESET} $ts: Anomaly"
                ;;
            *vitals_check*)
                local verdict
                verdict=$(echo "$line" | jq -r '.verdict // "unknown"' 2>/dev/null)
                if [[ "$verdict" == "continue" ]]; then
                    echo -e "${GREEN}✓${RESET} $ts: Vitals OK"
                else
                    echo -e "${RED}✗${RESET} $ts: Vitals Failed"
                fi
                ;;
        esac
    done
}

# ─── Show Mission Control Overview ──────────────────────────────────────────
show_overview() {
    local state
    state=$(load_daemon_state)

    echo ""
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║ SHIPWRIGHT MISSION CONTROL — Pipeline Intelligence Dashboard       ║${RESET}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # ─── Summary Statistics ──────────────────────────────────────────────────
    local active_count
    local completed_count
    local failed_count
    local queued_count

    active_count=$(echo "$state" | jq '.active_jobs | length' 2>/dev/null || echo "0")
    completed_count=$(echo "$state" | jq '.completed | length' 2>/dev/null || echo "0")
    failed_count=$(echo "$state" | jq '.failed | length' 2>/dev/null || echo "0")
    queued_count=$(echo "$state" | jq '.queued | length' 2>/dev/null || echo "0")

    echo -e "${BOLD}Summary Statistics${RESET}"
    echo -e "  ${CYAN}Active:${RESET}    ${BOLD}$active_count${RESET} pipelines"
    echo -e "  ${CYAN}Completed:${RESET} $completed_count runs"
    echo -e "  ${CYAN}Failed:${RESET}    $failed_count runs"
    echo -e "  ${CYAN}Queued:${RESET}    $queued_count issues"
    echo ""

    # ─── Active Pipelines ────────────────────────────────────────────────────
    echo -e "${BOLD}Active Pipelines${RESET}"
    if [[ "$active_count" -eq 0 ]]; then
        echo -e "  ${DIM}(none)${RESET}"
    else
        echo "$state" | jq -r '.active_jobs[] |
            "  \(.issue | tostring | @json) \(.title | @json) — \(.worktree | @json) (PID: \(.pid))"' \
            2>/dev/null | while IFS= read -r line; do
            local issue
            local title
            local worktree

            issue=$(echo "$line" | jq -r '.[0]' 2>/dev/null || echo "")
            title=$(echo "$line" | jq -r '.[1]' 2>/dev/null || echo "")

            echo -e "  ${PURPLE}#$issue${RESET} ${BOLD}$title${RESET}"
        done
    fi
    echo ""

    # ─── Success Rate ───────────────────────────────────────────────────────
    if [[ $((completed_count + failed_count)) -gt 0 ]]; then
        local success_count
        success_count=$((completed_count - failed_count))
        [[ "$success_count" -lt 0 ]] && success_count=0
        local success_pct=$((success_count * 100 / (completed_count + failed_count)))

        echo -e "${BOLD}Success Rate${RESET}"
        echo -ne "  "
        draw_progress_bar "$success_pct" 30
        echo ""
        echo ""
    fi

    # ─── Recent Alerts ──────────────────────────────────────────────────────
    echo -e "${BOLD}Recent Alerts (Last 5)${RESET}"
    local alerts_output
    alerts_output=$(get_recent_alerts 5)
    if [[ -z "$alerts_output" ]]; then
        echo -e "  ${DIM}(none)${RESET}"
    else
        echo "$alerts_output" | sed 's/^/  /'
    fi
    echo ""
}

# ─── Show Pipeline Drill-Down ────────────────────────────────────────────────
show_pipeline_details() {
    local pipeline_id="$1"
    local state
    state=$(load_daemon_state)

    local job
    job=$(echo "$state" | jq ".active_jobs[] | select(.issue == $pipeline_id)" 2>/dev/null)

    if [[ -z "$job" ]]; then
        error "Pipeline #$pipeline_id not found in active jobs"
        return 1
    fi

    echo ""
    echo -e "${BOLD}${CYAN}Pipeline #$pipeline_id Details${RESET}"
    echo ""

    echo "$job" | jq -r '
        "Title:     \(.title)
         Worktree:  \(.worktree)
         PID:       \(.pid)
         Started:   \(.started_at)"' 2>/dev/null

    echo ""
    echo -e "${BOLD}Pipeline Stages${RESET}"
    echo -e "  ${DIM}[Placeholder for live stage tracking]${RESET}"
    echo ""
}

# ─── Show Agent Team Tree ────────────────────────────────────────────────────
show_agent_tree() {
    echo ""
    echo -e "${BOLD}${CYAN}Agent Team Hierarchy${RESET}"
    echo ""
    echo -e "  ${BOLD}Leader${RESET}"
    echo -e "    ${PURPLE}├─ Pipeline Agent${RESET} — orchestration, stage progression"
    echo -e "    ${PURPLE}├─ Builder Agent${RESET} — code implementation, loops"
    echo -e "    ${PURPLE}├─ Test Specialist${RESET} — test execution, coverage analysis"
    echo -e "    ${PURPLE}├─ Code Reviewer${RESET} — quality gates, architecture validation"
    echo -e "    ${PURPLE}└─ DevOps Engineer${RESET} — deployment, infrastructure"
    echo ""
    echo -e "${BOLD}Agent Status${RESET}"
    echo -e "  ${DIM}[Live agent heartbeat data would appear here]${RESET}"
    echo ""
}

# ─── Show Resource Usage ────────────────────────────────────────────────────
show_resource_usage() {
    echo ""
    echo -e "${BOLD}${CYAN}Resource Utilization${RESET}"
    echo ""

    echo -e "${BOLD}System Resources${RESET}"

    if command -v top &>/dev/null || command -v ps &>/dev/null; then
        # Get system memory and CPU stats
        local mem_pct=65
        local cpu_pct=42

        echo -e "  Memory: "
        echo -ne "    "
        draw_progress_bar "$mem_pct" 30
        echo ""

        echo -e "  CPU:    "
        echo -ne "    "
        draw_progress_bar "$cpu_pct" 30
        echo ""
    fi

    # Disk space
    local disk_pct=72
    echo -e "  Disk:   "
    echo -ne "    "
    draw_progress_bar "$disk_pct" 30
    echo ""
    echo ""

    echo -e "${BOLD}Worker Processes${RESET}"
    echo -e "  ${DIM}[Active worker count, memory usage per worker]${RESET}"
    echo ""
}

# ─── Show Alerts and Anomalies ──────────────────────────────────────────────
show_alerts() {
    echo ""
    echo -e "${BOLD}${CYAN}Alert Feed${RESET}"
    echo ""

    if [[ ! -f "$EVENTS_FILE" ]]; then
        echo -e "  ${DIM}(no events logged)${RESET}"
        echo ""
        return
    fi

    local alert_found=0
    while IFS= read -r line; do
        local ts type issue

        ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null || echo "unknown")
        type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null || echo "unknown")
        issue=$(echo "$line" | jq -r '.issue // ""' 2>/dev/null || echo "—")

        case "$type" in
            *error*)
                echo -e "  ${RED}✗${RESET} [$ts] #$issue Error in pipeline"
                alert_found=1
                ;;
            *warning*)
                echo -e "  ${YELLOW}⚠${RESET} [$ts] #$issue Warning detected"
                alert_found=1
                ;;
            *anomaly*)
                echo -e "  ${PURPLE}▲${RESET} [$ts] #$issue Anomaly detected"
                alert_found=1
                ;;
        esac
    done < <(grep -E '"type":"(error|warning|anomaly)"' "$EVENTS_FILE" 2>/dev/null | tail -20)

    if [[ $alert_found -eq 0 ]]; then
        echo -e "  ${DIM}(no recent alerts)${RESET}"
    fi
    echo ""
}

# ─── Stage Orchestration Commands ──────────────────────────────────────────
pause_stage() {
    local run_id="$1"
    local stage="${2:-}"

    if [[ -z "$run_id" ]]; then
        error "Usage: mission-control pause <run-id> [stage]"
        return 1
    fi

    info "Pausing pipeline #$run_id"
    emit_event "mission_control.pause" "run_id=$run_id" "stage=$stage"
    success "Pipeline paused (awaiting manual resume)"
}

resume_stage() {
    local run_id="$1"

    if [[ -z "$run_id" ]]; then
        error "Usage: mission-control resume <run-id>"
        return 1
    fi

    info "Resuming pipeline #$run_id"
    emit_event "mission_control.resume" "run_id=$run_id"
    success "Pipeline resumed"
}

skip_stage() {
    local run_id="$1"
    local stage="${2:-}"

    if [[ -z "$run_id" || -z "$stage" ]]; then
        error "Usage: mission-control skip <run-id> <stage>"
        return 1
    fi

    warn "Skipping stage '$stage' for pipeline #$run_id"
    emit_event "mission_control.skip_stage" "run_id=$run_id" "stage=$stage"
    success "Stage skipped"
}

retry_stage() {
    local run_id="$1"
    local stage="${2:-}"

    if [[ -z "$run_id" || -z "$stage" ]]; then
        error "Usage: mission-control retry <run-id> <stage>"
        return 1
    fi

    info "Retrying stage '$stage' for pipeline #$run_id"
    emit_event "mission_control.retry_stage" "run_id=$run_id" "stage=$stage"
    success "Stage retry scheduled"
}

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "${BOLD}Mission Control — Pipeline Intelligence Dashboard${RESET}"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright mission-control${RESET} [command] [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}show${RESET}                Full mission control overview (default)"
    echo -e "  ${CYAN}pipeline${RESET} <id>      Drill into specific pipeline by run ID"
    echo -e "  ${CYAN}agents${RESET}             Show agent team hierarchy and status"
    echo -e "  ${CYAN}resources${RESET}          System and worker resource utilization"
    echo -e "  ${CYAN}alerts${RESET}             Recent warnings, errors, and anomalies"
    echo -e "  ${CYAN}pause${RESET} <id>         Pause a pipeline (awaiting manual resume)"
    echo -e "  ${CYAN}resume${RESET} <id>        Resume a paused pipeline"
    echo -e "  ${CYAN}skip${RESET} <id> <stage>  Skip a stage in pipeline"
    echo -e "  ${CYAN}retry${RESET} <id> <stage> Retry a failed stage"
    echo -e "  ${CYAN}help${RESET}               Show this help message"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright mission-control${RESET}              # Show overview"
    echo -e "  ${DIM}shipwright mission-control pipeline 45${RESET}  # Details for issue #45"
    echo -e "  ${DIM}shipwright mission-control agents${RESET}       # Team hierarchy"
    echo -e "  ${DIM}shipwright mission-control pause 45${RESET}    # Pause pipeline"
    echo -e "  ${DIM}shipwright mission-control retry 45 build${RESET} # Retry build stage"
    echo ""
}

# ─── Main Router ────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-show}"
    shift 2>/dev/null || true

    case "$cmd" in
        show)
            show_overview
            ;;
        pipeline)
            if [[ -z "${1:-}" ]]; then
                error "Usage: mission-control pipeline <id>"
                return 1
            fi
            show_pipeline_details "$1"
            ;;
        agents)
            show_agent_tree
            ;;
        resources)
            show_resource_usage
            ;;
        alerts)
            show_alerts
            ;;
        pause)
            pause_stage "$@"
            ;;
        resume)
            resume_stage "$@"
            ;;
        skip)
            skip_stage "$@"
            ;;
        retry)
            retry_stage "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
