#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fleet-viz — Multi-Repo Fleet Visualization                   ║
# ║  Cross-repo insights, queue management, worker allocation, cost tracking  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.0"
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

# ─── Data Paths ────────────────────────────────────────────────────────────
FLEET_DIR="${HOME}/.shipwright"
FLEET_STATE="${FLEET_DIR}/fleet-state.json"
EVENTS_FILE="${FLEET_DIR}/events.jsonl"
COSTS_FILE="${FLEET_DIR}/costs.json"
MACHINES_FILE="${FLEET_DIR}/machines.json"

# ─── Health Status Helpers ─────────────────────────────────────────────────
get_health_status() {
    local repo="$1"
    # Calculate health from recent events/pipeline state
    # healthy (green) = no recent failures
    # degraded (yellow) = some failures but recovering
    # failing (red) = persistent failures

    if ! command -v jq &>/dev/null; then
        echo "unknown"
        return
    fi

    # Check if any active jobs are stuck (queued >30min)
    local stuck_count
    stuck_count=$(jq -r "[.active_jobs[] | select(.repo==\"$repo\" and (.queued_at|todateiso8601|length) and (now - (.queued_at | fromdateiso8601) > 1800))] | length" "$FLEET_STATE" 2>/dev/null || echo "0")

    if [[ "$stuck_count" -gt 0 ]]; then
        echo "failing"
    else
        echo "healthy"
    fi
}

color_health() {
    local status="$1"
    case "$status" in
        healthy)  echo "${GREEN}${status}${RESET}" ;;
        degraded) echo "${YELLOW}${status}${RESET}" ;;
        failing)  echo "${RED}${status}${RESET}" ;;
        *)        echo "${DIM}${status}${RESET}" ;;
    esac
}

# ─── Overview Subcommand ───────────────────────────────────────────────────
show_overview() {
    if ! command -v jq &>/dev/null; then
        error "jq is required for fleet visualization"
        exit 1
    fi

    [[ ! -f "$FLEET_STATE" ]] && {
        warn "No fleet state found at $FLEET_STATE"
        echo "Run 'shipwright fleet start' first"
        return
    }

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Fleet Overview ━━━${RESET}"
    echo ""

    # Extract metrics
    local active_pipelines queued_agents repos
    active_pipelines=$(jq '[.active_jobs[]? | select(.status=="running")] | length' "$FLEET_STATE" 2>/dev/null || echo "0")
    queued_agents=$(jq '[.active_jobs[]? | select(.status=="queued")] | length' "$FLEET_STATE" 2>/dev/null || echo "0")
    repos=$(jq '[.active_jobs[]? | .repo] | unique | length' "$FLEET_STATE" 2>/dev/null || echo "0")

    echo -e "${BOLD}Active:${RESET} ${CYAN}${active_pipelines}${RESET} pipelines  |  ${BOLD}Queued:${RESET} ${YELLOW}${queued_agents}${RESET} jobs  |  ${BOLD}Repos:${RESET} ${PURPLE}${repos}${RESET}"
    echo ""

    # Per-repo breakdown
    if [[ "$(jq '.active_jobs | length' "$FLEET_STATE" 2>/dev/null || echo "0")" -gt 0 ]]; then
        echo -e "${BOLD}Repos:${RESET}"
        echo ""

        jq -r '.active_jobs[]? | .repo' "$FLEET_STATE" 2>/dev/null | sort -u | while read -r repo; do
            local repo_active repo_queued health
            repo_active=$(jq "[.active_jobs[]? | select(.repo==\"$repo\" and .status==\"running\")] | length" "$FLEET_STATE" 2>/dev/null || echo "0")
            repo_queued=$(jq "[.active_jobs[]? | select(.repo==\"$repo\" and .status==\"queued\")] | length" "$FLEET_STATE" 2>/dev/null || echo "0")
            health=$(get_health_status "$repo")

            echo -e "  ${CYAN}$(basename "$repo")${RESET}  ${repo_active} active  ${repo_queued} queued  [$(color_health "$health")]"
        done
    else
        echo -e "${DIM}No active pipelines${RESET}"
    fi

    echo ""
}

# ─── Workers Subcommand ────────────────────────────────────────────────────
show_workers() {
    if ! command -v jq &>/dev/null; then
        error "jq is required for fleet visualization"
        exit 1
    fi

    [[ ! -f "$FLEET_STATE" ]] && {
        warn "No fleet state found at $FLEET_STATE"
        return
    }

    [[ ! -f "$MACHINES_FILE" ]] && {
        warn "No machines file found at $MACHINES_FILE"
        return
    }

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Worker Allocation ━━━${RESET}"
    echo ""

    # Get per-repo worker counts
    local total_workers_allocated=0
    jq -r '.active_jobs[]? | .repo' "$FLEET_STATE" 2>/dev/null | sort -u | while read -r repo; do
        local worker_count job_count utilization
        worker_count=$(jq "[.active_jobs[]? | select(.repo==\"$repo\")] | map(.worker_id) | unique | length" "$FLEET_STATE" 2>/dev/null || echo "0")
        job_count=$(jq "[.active_jobs[]? | select(.repo==\"$repo\")] | length" "$FLEET_STATE" 2>/dev/null || echo "0")

        if [[ "$worker_count" -gt 0 ]]; then
            utilization=$((job_count * 100 / worker_count))
        else
            utilization=0
        fi

        echo -e "  ${CYAN}$(basename "$repo")${RESET}  ${worker_count} workers  ${job_count} jobs  ${utilization}% util"
    done

    # Remote machines
    echo ""
    echo -e "${BOLD}Remote Machines:${RESET}"
    echo ""

    if jq '.machines[]?' "$MACHINES_FILE" 2>/dev/null | grep -q .; then
        jq -r '.machines[]? | "\(.name) (\(.hostname)) — \(.status) — \(.active_jobs // 0) active"' "$MACHINES_FILE" 2>/dev/null | while read -r machine; do
            echo -e "  ${machine}"
        done
    else
        echo -e "  ${DIM}No remote machines configured${RESET}"
    fi

    echo ""
}

# ─── Insights Subcommand ───────────────────────────────────────────────────
show_insights() {
    if ! command -v jq &>/dev/null; then
        error "jq is required for fleet visualization"
        exit 1
    fi

    [[ ! -f "$EVENTS_FILE" ]] && {
        warn "No events found at $EVENTS_FILE"
        return
    }

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Fleet Insights ━━━${RESET}"
    echo ""

    # Fleet-wide success rate (last 30 days)
    local total_pipelines successful_pipelines
    total_pipelines=$(grep '"type":"pipeline_complete"' "$EVENTS_FILE" 2>/dev/null | tail -5000 | wc -l || echo "0")
    successful_pipelines=$(grep '"type":"pipeline_complete".*"status":"success"' "$EVENTS_FILE" 2>/dev/null | tail -5000 | wc -l || echo "0")

    local success_rate=0
    if [[ "$total_pipelines" -gt 0 ]]; then
        success_rate=$((successful_pipelines * 100 / total_pipelines))
    fi

    echo -e "${BOLD}Success Rate:${RESET} ${success_rate}% (${successful_pipelines}/${total_pipelines})"

    # Most expensive repo
    if [[ -f "$COSTS_FILE" ]]; then
        echo ""
        echo -e "${BOLD}Cost Leaders:${RESET}"
        jq -r '.entries[]? | select(.repo != null) | .repo as $repo | {repo: $repo, cost: .cost} | @csv' "$COSTS_FILE" 2>/dev/null | \
        awk -F, '{r=$1; gsub(/"/, "", r); sum[r]+=$2} END {for (r in sum) print r, sum[r]}' | sort -k2 -nr | head -5 | while read -r repo cost; do
            printf "  ${CYAN}%s${RESET} — \$%.2f\n" "$repo" "$cost"
        done
    fi

    echo ""
}

# ─── Queue Subcommand ──────────────────────────────────────────────────────
show_queue() {
    if ! command -v jq &>/dev/null; then
        error "jq is required for fleet visualization"
        exit 1
    fi

    [[ ! -f "$FLEET_STATE" ]] && {
        warn "No fleet state found at $FLEET_STATE"
        return
    }

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Issue Queue ━━━${RESET}"
    echo ""

    local queued_count
    queued_count=$(jq '[.active_jobs[]? | select(.status=="queued")] | length' "$FLEET_STATE" 2>/dev/null || echo "0")

    if [[ "$queued_count" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET} No queued issues"
        echo ""
        return
    fi

    echo -e "${BOLD}${queued_count} Issues Queued:${RESET}"
    echo ""
    echo -e "  ${BOLD}Repo${RESET}          ${BOLD}Issue${RESET}    ${BOLD}Priority${RESET}    ${BOLD}Wait Time${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────────${RESET}"

    jq -r '.active_jobs[]? | select(.status=="queued") | "\(.repo) #\(.issue_number) \(.priority // "normal") \(.queued_for // "0s")"' "$FLEET_STATE" 2>/dev/null | while read -r repo issue priority wait; do
        local priority_color
        case "$priority" in
            urgent|hotfix) priority_color="${RED}${priority}${RESET}" ;;
            high)          priority_color="${YELLOW}${priority}${RESET}" ;;
            *)             priority_color="${DIM}${priority}${RESET}" ;;
        esac
        printf "  %-20s %-8s %-10b %-12s\n" "$(basename "$repo")" "$issue" "$priority_color" "$wait"
    done

    echo ""
}

# ─── Costs Subcommand ──────────────────────────────────────────────────────
show_costs() {
    if ! command -v jq &>/dev/null; then
        error "jq is required for fleet visualization"
        exit 1
    fi

    [[ ! -f "$COSTS_FILE" ]] && {
        warn "No cost data found at $COSTS_FILE"
        return
    }

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Fleet Costs ━━━${RESET}"
    echo ""

    # Total spend
    local total_spend
    total_spend=$(jq '[.entries[]? | .cost // 0] | add // 0' "$COSTS_FILE" 2>/dev/null || echo "0")
    printf "${BOLD}Total Spend:${RESET} \$%.2f\n" "$total_spend"

    # Per-repo breakdown
    echo ""
    echo -e "${BOLD}Per-Repo:${RESET}"
    jq -r '.entries[]? | select(.repo != null) | "\(.repo) \(.cost // 0) \(.model // "unknown")"' "$COSTS_FILE" 2>/dev/null | \
    awk '{repo=$1; split(repo,a,"/"); r=a[length(a)]; cost=$2; model=$3; sum[r]+=cost} END {for (r in sum) print r, sum[r]}' | \
    sort -k2 -nr | while read -r repo cost; do
        printf "  %-20s \$%.2f\n" "$repo" "$cost"
    done

    # Per-model breakdown
    echo ""
    echo -e "${BOLD}Per-Model:${RESET}"
    jq -r '.entries[]? | .model // "unknown"' "$COSTS_FILE" 2>/dev/null | sort | uniq -c | sort -rn | while read -r count model; do
        local model_cost
        model_cost=$(jq "[.entries[]? | select(.model==\"$model\") | .cost // 0] | add // 0" "$COSTS_FILE" 2>/dev/null || echo "0")
        printf "  %-20s %d uses  \$%.2f\n" "$model" "$count" "$model_cost"
    done

    echo ""
}

# ─── Export Subcommand ─────────────────────────────────────────────────────
show_export() {
    if ! command -v jq &>/dev/null; then
        error "jq is required for fleet visualization"
        exit 1
    fi

    [[ ! -f "$FLEET_STATE" ]] && {
        error "No fleet state found at $FLEET_STATE"
        exit 1
    }

    # Merge all available data into single JSON export
    local export_json
    export_json=$(cat "$FLEET_STATE" 2>/dev/null || echo '{}')

    if [[ -f "$COSTS_FILE" ]]; then
        export_json=$(echo "$export_json" | jq --slurpfile costs "$COSTS_FILE" '.costs = $costs[0]')
    fi

    if [[ -f "$MACHINES_FILE" ]]; then
        export_json=$(echo "$export_json" | jq --slurpfile machines "$MACHINES_FILE" '.machines = $machines[0]')
    fi

    echo "$export_json" | jq .
}

# ─── Help ──────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ shipwright fleet-viz v${VERSION} ━━━${RESET}"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright fleet-viz${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}overview${RESET}     Show fleet-wide status (pipelines, queues, repos)"
    echo -e "  ${CYAN}workers${RESET}      Show worker allocation and remote machines"
    echo -e "  ${CYAN}insights${RESET}     Show cross-repo metrics and trends"
    echo -e "  ${CYAN}queue${RESET}        Show combined queue across all repos"
    echo -e "  ${CYAN}costs${RESET}        Show fleet-wide cost breakdown"
    echo -e "  ${CYAN}export${RESET}       Export fleet state as JSON"
    echo -e "  ${CYAN}help${RESET}         Show this help message"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright fleet-viz overview${RESET}     # Fleet dashboard"
    echo -e "  ${DIM}shipwright fleet-viz workers${RESET}      # Worker status"
    echo -e "  ${DIM}shipwright fleet-viz queue${RESET}        # Show issue queue"
    echo -e "  ${DIM}shipwright fleet-viz export | jq .${RESET} # Export as JSON"
    echo ""
}

# ─── Main Router ───────────────────────────────────────────────────────────
main() {
    local cmd="${1:-overview}"
    shift 2>/dev/null || true

    case "$cmd" in
        overview)
            show_overview
            ;;
        workers)
            show_workers
            ;;
        insights)
            show_insights
            ;;
        queue)
            show_queue
            ;;
        costs)
            show_costs
            ;;
        export)
            show_export
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
