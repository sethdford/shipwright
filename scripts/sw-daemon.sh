#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright daemon — Autonomous GitHub Issue Watcher                          ║
# ║  Polls for labeled issues · Spawns pipelines · Manages worktrees      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# Allow spawning Claude CLI from within a Claude Code session (daemon, fleet, etc.)
unset CLAUDECODE 2>/dev/null || true

VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# ─── Intelligence Engine (optional) ──────────────────────────────────────────
# shellcheck source=sw-intelligence.sh
[[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]] && source "$SCRIPT_DIR/sw-intelligence.sh"
# shellcheck source=sw-pipeline-composer.sh
[[ -f "$SCRIPT_DIR/sw-pipeline-composer.sh" ]] && source "$SCRIPT_DIR/sw-pipeline-composer.sh"
# shellcheck source=sw-self-optimize.sh
[[ -f "$SCRIPT_DIR/sw-self-optimize.sh" ]] && source "$SCRIPT_DIR/sw-self-optimize.sh"
# shellcheck source=sw-predictive.sh
[[ -f "$SCRIPT_DIR/sw-predictive.sh" ]] && source "$SCRIPT_DIR/sw-predictive.sh"
# shellcheck source=sw-pipeline-vitals.sh
[[ -f "$SCRIPT_DIR/sw-pipeline-vitals.sh" ]] && source "$SCRIPT_DIR/sw-pipeline-vitals.sh"

# ─── SQLite Persistence (optional) ──────────────────────────────────────────
# shellcheck source=sw-db.sh
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"

# ─── GitHub API Modules (optional) ────────────────────────────────────────
# shellcheck source=sw-github-graphql.sh
[[ -f "$SCRIPT_DIR/sw-github-graphql.sh" ]] && source "$SCRIPT_DIR/sw-github-graphql.sh"
# shellcheck source=sw-github-checks.sh
[[ -f "$SCRIPT_DIR/sw-github-checks.sh" ]] && source "$SCRIPT_DIR/sw-github-checks.sh"
# shellcheck source=sw-github-deploy.sh
[[ -f "$SCRIPT_DIR/sw-github-deploy.sh" ]] && source "$SCRIPT_DIR/sw-github-deploy.sh"

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

epoch_to_iso() {
    local epoch="$1"
    date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp($epoch).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null || \
    echo "1970-01-01T00:00:00Z"
}

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

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

emit_event() {
    local event_type="$1"
    shift
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            local escaped_val
            escaped_val=$(printf '%s' "$val" | jq -Rs '.' 2>/dev/null || printf '"%s"' "${val//\"/\\\"}")
            json_fields="${json_fields},\"${key}\":${escaped_val}"
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Event Log Rotation ─────────────────────────────────────────────────────
rotate_event_log() {
    local max_size=$((50 * 1024 * 1024))  # 50MB
    local max_rotations=3

    # Rotate events.jsonl if too large
    if [[ -f "$EVENTS_FILE" ]]; then
        local size
        size=$(wc -c < "$EVENTS_FILE" 2>/dev/null || echo 0)
        if [[ "$size" -gt "$max_size" ]]; then
            # Shift rotations: .3 → delete, .2 → .3, .1 → .2, current → .1
            local i=$max_rotations
            while [[ $i -gt 1 ]]; do
                local prev=$((i - 1))
                [[ -f "${EVENTS_FILE}.${prev}" ]] && mv "${EVENTS_FILE}.${prev}" "${EVENTS_FILE}.${i}"
                i=$((i - 1))
            done
            mv "$EVENTS_FILE" "${EVENTS_FILE}.1"
            touch "$EVENTS_FILE"
            emit_event "daemon.log_rotated" "previous_size=$size"
            info "Rotated events.jsonl (was $(( size / 1048576 ))MB)"
        fi
    fi

    # Clean old heartbeat files (> 24h)
    local heartbeat_dir="$HOME/.shipwright/heartbeats"
    if [[ -d "$heartbeat_dir" ]]; then
        find "$heartbeat_dir" -name "*.json" -mmin +1440 -delete 2>/dev/null || true
    fi
}

# ─── GitHub Context (loaded once at startup) ──────────────────────────────

daemon_github_context() {
    # Skip if no GitHub
    [[ "${NO_GITHUB:-false}" == "true" ]] && return 0
    type gh_repo_context &>/dev/null 2>&1 || return 0
    type _gh_detect_repo &>/dev/null 2>&1 || return 0

    _gh_detect_repo 2>/dev/null || return 0
    local owner="${GH_OWNER:-}" repo="${GH_REPO:-}"
    [[ -z "$owner" || -z "$repo" ]] && return 0

    local context
    context=$(gh_repo_context "$owner" "$repo" 2>/dev/null || echo "{}")
    if [[ -n "$context" && "$context" != "{}" ]]; then
        daemon_log INFO "GitHub context loaded: $(echo "$context" | jq -r '.contributor_count // 0') contributors, $(echo "$context" | jq -r '.security_alert_count // 0') security alerts"
    fi
}

# ─── GitHub API Retry with Backoff ────────────────────────────────────────
# Retries gh commands up to 3 times with exponential backoff (1s, 3s, 9s).
# Detects rate-limit (403/429) and transient errors. Returns the gh exit code.
gh_retry() {
    local max_retries=3
    local backoff=1
    local attempt=0
    local exit_code=0

    while [[ $attempt -lt $max_retries ]]; do
        attempt=$((attempt + 1))
        # Run the gh command; capture exit code
        if output=$("$@" 2>&1); then
            echo "$output"
            return 0
        fi
        exit_code=$?

        # Check for rate-limit or server error indicators
        if echo "$output" | grep -qiE "rate limit|403|429|502|503"; then
            daemon_log WARN "gh_retry: rate limit / server error on attempt ${attempt}/${max_retries} — backoff ${backoff}s" >&2
        else
            daemon_log WARN "gh_retry: transient error on attempt ${attempt}/${max_retries} (exit ${exit_code}) — backoff ${backoff}s" >&2
        fi

        if [[ $attempt -lt $max_retries ]]; then
            sleep "$backoff"
            backoff=$((backoff * 3))
        fi
    done

    # Return last output and exit code after exhausting retries
    echo "$output"
    return "$exit_code"
}

# ─── Defaults ───────────────────────────────────────────────────────────────
DAEMON_DIR="$HOME/.shipwright"
PID_FILE="$DAEMON_DIR/daemon.pid"
SHUTDOWN_FLAG="$DAEMON_DIR/daemon.shutdown"
STATE_FILE=""
LOG_FILE=""
LOG_DIR=""
WORKTREE_DIR=""

# Config defaults (overridden by daemon-config.json)
WATCH_LABEL="ready-to-build"
POLL_INTERVAL=60
MAX_PARALLEL=2
PIPELINE_TEMPLATE="autonomous"
SKIP_GATES=true
MODEL="opus"
BASE_BRANCH="main"
ON_SUCCESS_REMOVE_LABEL="ready-to-build"
ON_SUCCESS_ADD_LABEL="pipeline/complete"
ON_SUCCESS_CLOSE_ISSUE=false
ON_FAILURE_ADD_LABEL="pipeline/failed"
ON_FAILURE_LOG_LINES=50
SLACK_WEBHOOK=""

# Priority lane defaults
PRIORITY_LANE=false
PRIORITY_LANE_LABELS="hotfix,incident,p0,urgent"
PRIORITY_LANE_MAX=1

# Org-wide daemon defaults
WATCH_MODE="repo"
ORG=""
REPO_FILTER=""

# Auto-scaling defaults
AUTO_SCALE=false
AUTO_SCALE_INTERVAL=5
MAX_WORKERS=8
MIN_WORKERS=1
WORKER_MEM_GB=4
EST_COST_PER_JOB=5.0
FLEET_MAX_PARALLEL=""

# Patrol defaults (overridden by daemon-config.json or env)
PATROL_INTERVAL="${PATROL_INTERVAL:-3600}"
PATROL_MAX_ISSUES="${PATROL_MAX_ISSUES:-5}"
PATROL_LABEL="${PATROL_LABEL:-auto-patrol}"
PATROL_DRY_RUN=false
PATROL_AUTO_WATCH=false
PATROL_FAILURES_THRESHOLD=3
PATROL_DORA_ENABLED=true
PATROL_UNTESTED_ENABLED=true
PATROL_RETRY_ENABLED=true
PATROL_RETRY_THRESHOLD=2
LAST_PATROL_EPOCH=0

# Team dashboard coordination
DASHBOARD_URL="${DASHBOARD_URL:-http://localhost:8767}"

# Runtime
NO_GITHUB=false
CONFIG_PATH=""
DETACH=false
FOLLOW=false
BACKOFF_SECS=0

# ─── CLI Argument Parsing ──────────────────────────────────────────────────

SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_PATH="${2:-}"
            shift 2
            ;;
        --config=*)
            CONFIG_PATH="${1#--config=}"
            shift
            ;;
        --detach|-d)
            DETACH=true
            shift
            ;;
        --follow|-f)
            FOLLOW=true
            shift
            ;;
        --no-github)
            NO_GITHUB=true
            shift
            ;;
        --help|-h)
            SUBCOMMAND="help"
            shift
            ;;
        *)
            # Pass unrecognized flags to subcommands (e.g. metrics --period 7)
            break
            ;;
    esac
done

# Remaining args available as "$@" for subcommands

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright daemon${RESET} ${DIM}v${VERSION}${RESET} — Autonomous GitHub Issue Watcher"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright daemon${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}start${RESET}    [--config path] [--detach]   Start the issue watcher"
    echo -e "  ${CYAN}stop${RESET}                                  Graceful shutdown via PID file"
    echo -e "  ${CYAN}status${RESET}                                Show active pipelines and queue"
    echo -e "  ${CYAN}init${RESET}                                  Generate default daemon-config.json"
    echo -e "  ${CYAN}logs${RESET}     [--follow]                   Tail daemon activity log"
    echo -e "  ${CYAN}metrics${RESET}  [--period N] [--json]        DORA/DX metrics dashboard"
    echo -e "  ${CYAN}triage${RESET}                                Show issue triage scores and priority"
    echo -e "  ${CYAN}patrol${RESET}   [--once] [--dry-run]         Run proactive codebase patrol"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--config${RESET} <path>   Path to daemon-config.json ${DIM}(default: .claude/daemon-config.json)${RESET}"
    echo -e "  ${CYAN}--detach${RESET}, ${CYAN}-d${RESET}     Run in a detached tmux session"
    echo -e "  ${CYAN}--follow${RESET}, ${CYAN}-f${RESET}     Follow log output (with ${CYAN}logs${RESET} command)"
    echo -e "  ${CYAN}--no-github${RESET}       Disable GitHub API calls (dry-run mode)"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright daemon init${RESET}                        # Generate config file"
    echo -e "  ${DIM}shipwright daemon start${RESET}                       # Start watching in foreground"
    echo -e "  ${DIM}shipwright daemon start --detach${RESET}               # Start in background tmux session"
    echo -e "  ${DIM}shipwright daemon start --config my-config.json${RESET} # Custom config"
    echo -e "  ${DIM}shipwright daemon status${RESET}                      # Show active jobs and queue"
    echo -e "  ${DIM}shipwright daemon stop${RESET}                        # Graceful shutdown"
    echo -e "  ${DIM}shipwright daemon logs --follow${RESET}               # Tail the daemon log"
    echo -e "  ${DIM}shipwright daemon metrics${RESET}                     # DORA + DX metrics (last 7 days)"
    echo -e "  ${DIM}shipwright daemon metrics --period 30${RESET}         # Last 30 days"
    echo -e "  ${DIM}shipwright daemon metrics --json${RESET}              # JSON output for dashboards"
    echo -e "  ${DIM}shipwright daemon triage${RESET}                      # Show issue triage scores"
    echo -e "  ${DIM}shipwright daemon patrol${RESET}                      # Run proactive codebase patrol"
    echo -e "  ${DIM}shipwright daemon patrol --dry-run${RESET}            # Show what patrol would find"
    echo -e "  ${DIM}shipwright daemon patrol --once${RESET}               # Run patrol once and exit"
    echo ""
    echo -e "${BOLD}CONFIG FILE${RESET}  ${DIM}(.claude/daemon-config.json)${RESET}"
    echo -e "  ${DIM}watch_label${RESET}         GitHub label to watch for         ${DIM}(default: ready-to-build)${RESET}"
    echo -e "  ${DIM}poll_interval${RESET}       Seconds between polls             ${DIM}(default: 60)${RESET}"
    echo -e "  ${DIM}max_parallel${RESET}        Max concurrent pipeline jobs      ${DIM}(default: 2)${RESET}"
    echo -e "  ${DIM}pipeline_template${RESET}   Pipeline template to use          ${DIM}(default: autonomous)${RESET}"
    echo -e "  ${DIM}base_branch${RESET}         Branch to create worktrees from   ${DIM}(default: main)${RESET}"
    echo ""
    echo -e "  ${BOLD}Priority Lanes${RESET}"
    echo -e "  ${DIM}priority_lane${RESET}        Enable priority bypass queue     ${DIM}(default: false)${RESET}"
    echo -e "  ${DIM}priority_lane_labels${RESET} Labels that trigger priority     ${DIM}(default: hotfix,incident,p0,urgent)${RESET}"
    echo -e "  ${DIM}priority_lane_max${RESET}    Max extra slots for priority     ${DIM}(default: 1)${RESET}"
    echo ""
    echo -e "  ${BOLD}Org-Wide Mode${RESET}"
    echo -e "  ${DIM}watch_mode${RESET}          \"repo\" or \"org\"                    ${DIM}(default: repo)${RESET}"
    echo -e "  ${DIM}org${RESET}                 GitHub org name                   ${DIM}(required for org mode)${RESET}"
    echo -e "  ${DIM}repo_filter${RESET}         Regex filter for repo names       ${DIM}(e.g. \"api-.*|web-.*\")${RESET}"
    echo ""
    echo -e "${BOLD}HOW IT WORKS${RESET}"
    echo -e "  1. Polls GitHub for issues with the ${CYAN}${WATCH_LABEL}${RESET} label"
    echo -e "  2. For each new issue, creates a git worktree and spawns a pipeline"
    echo -e "  3. On success: removes label, adds ${GREEN}pipeline/complete${RESET}, comments on issue"
    echo -e "  4. On failure: adds ${RED}pipeline/failed${RESET}, comments with log tail"
    echo -e "  5. Respects ${CYAN}max_parallel${RESET} limit — excess issues are queued"
    echo -e "  6. Priority lane: ${CYAN}hotfix${RESET}/${CYAN}incident${RESET} issues bypass the queue"
    echo -e "  7. Org mode: watches issues across all repos in a GitHub org"
    echo ""
    echo -e "${DIM}Docs: https://sethdford.github.io/shipwright  |  GitHub: https://github.com/sethdford/shipwright${RESET}"
}

# ─── Config Loading ─────────────────────────────────────────────────────────

load_config() {
    local config_file="${CONFIG_PATH:-.claude/daemon-config.json}"

    if [[ ! -f "$config_file" ]]; then
        warn "Config not found at $config_file — using defaults"
        warn "Run ${CYAN}shipwright daemon init${RESET} to generate a config file"
        return 0
    fi

    info "Loading config: ${DIM}${config_file}${RESET}"

    WATCH_LABEL=$(jq -r '.watch_label // "ready-to-build"' "$config_file")
    POLL_INTERVAL=$(jq -r '.poll_interval // 60' "$config_file")
    MAX_PARALLEL=$(jq -r '.max_parallel // 2' "$config_file")
    PIPELINE_TEMPLATE=$(jq -r '.pipeline_template // "autonomous"' "$config_file")
    SKIP_GATES=$(jq -r '.skip_gates // true' "$config_file")
    MODEL=$(jq -r '.model // "opus"' "$config_file")
    BASE_BRANCH=$(jq -r '.base_branch // "main"' "$config_file")

    # on_success settings
    ON_SUCCESS_REMOVE_LABEL=$(jq -r '.on_success.remove_label // "ready-to-build"' "$config_file")
    ON_SUCCESS_ADD_LABEL=$(jq -r '.on_success.add_label // "pipeline/complete"' "$config_file")
    ON_SUCCESS_CLOSE_ISSUE=$(jq -r '.on_success.close_issue // false' "$config_file")

    # on_failure settings
    ON_FAILURE_ADD_LABEL=$(jq -r '.on_failure.add_label // "pipeline/failed"' "$config_file")
    ON_FAILURE_LOG_LINES=$(jq -r '.on_failure.comment_log_lines // 50' "$config_file")

    # notifications
    SLACK_WEBHOOK=$(jq -r '.notifications.slack_webhook // ""' "$config_file")
    if [[ "$SLACK_WEBHOOK" == "null" ]]; then SLACK_WEBHOOK=""; fi

    # health monitoring
    HEALTH_STALE_TIMEOUT=$(jq -r '.health.stale_timeout_s // 1800' "$config_file")

    # priority labels
    PRIORITY_LABELS=$(jq -r '.priority_labels // "urgent,p0,high,p1,normal,p2,low,p3"' "$config_file")

    # degradation alerting
    DEGRADATION_WINDOW=$(jq -r '.alerts.degradation_window // 5' "$config_file")
    DEGRADATION_CFR_THRESHOLD=$(jq -r '.alerts.cfr_threshold // 30' "$config_file")
    DEGRADATION_SUCCESS_THRESHOLD=$(jq -r '.alerts.success_threshold // 50' "$config_file")

    # patrol settings
    PATROL_INTERVAL=$(jq -r '.patrol.interval // 3600' "$config_file")
    PATROL_MAX_ISSUES=$(jq -r '.patrol.max_issues // 5' "$config_file")
    PATROL_LABEL=$(jq -r '.patrol.label // "auto-patrol"' "$config_file")
    PATROL_AUTO_WATCH=$(jq -r '.patrol.auto_watch // false' "$config_file")
    PATROL_FAILURES_THRESHOLD=$(jq -r '.patrol.checks.recurring_failures.threshold // 3' "$config_file")
    PATROL_DORA_ENABLED=$(jq -r '.patrol.checks.dora_degradation.enabled // true' "$config_file")
    PATROL_UNTESTED_ENABLED=$(jq -r '.patrol.checks.untested_scripts.enabled // true' "$config_file")
    PATROL_RETRY_ENABLED=$(jq -r '.patrol.checks.retry_exhaustion.enabled // true' "$config_file")
    PATROL_RETRY_THRESHOLD=$(jq -r '.patrol.checks.retry_exhaustion.threshold // 2' "$config_file")

    # adaptive template selection
    AUTO_TEMPLATE=$(jq -r '.auto_template // false' "$config_file")
    TEMPLATE_MAP=$(jq -r '.template_map // "{}" | @json' "$config_file" 2>/dev/null || echo '"{}"')

    # auto-retry with escalation
    MAX_RETRIES=$(jq -r '.max_retries // 2' "$config_file")
    RETRY_ESCALATION=$(jq -r '.retry_escalation // true' "$config_file")

    # session restart + fast test passthrough
    MAX_RESTARTS_CFG=$(jq -r '.max_restarts // 3' "$config_file" 2>/dev/null || echo "3")
    if ! [[ "$MAX_RESTARTS_CFG" =~ ^[0-9]+$ ]]; then
        daemon_log WARN "Invalid max_restarts in config: $MAX_RESTARTS_CFG (using default: 3)"
        MAX_RESTARTS_CFG="3"
    fi
    FAST_TEST_CMD_CFG=$(jq -r '.fast_test_cmd // ""' "$config_file" 2>/dev/null || echo "")

    # self-optimization
    SELF_OPTIMIZE=$(jq -r '.self_optimize // false' "$config_file")
    OPTIMIZE_INTERVAL=$(jq -r '.optimize_interval // 10' "$config_file")

    # intelligence engine settings
    INTELLIGENCE_ENABLED=$(jq -r '.intelligence.enabled // false' "$config_file")
    INTELLIGENCE_CACHE_TTL=$(jq -r '.intelligence.cache_ttl_seconds // 3600' "$config_file")
    COMPOSER_ENABLED=$(jq -r '.intelligence.composer_enabled // false' "$config_file")
    OPTIMIZATION_ENABLED=$(jq -r '.intelligence.optimization_enabled // false' "$config_file")
    PREDICTION_ENABLED=$(jq -r '.intelligence.prediction_enabled // false' "$config_file")
    ANOMALY_THRESHOLD=$(jq -r '.intelligence.anomaly_threshold // 3.0' "$config_file")

    # adaptive thresholds (intelligence-driven operational tuning)
    ADAPTIVE_THRESHOLDS_ENABLED=$(jq -r '.intelligence.adaptive_enabled // false' "$config_file")
    PRIORITY_STRATEGY=$(jq -r '.intelligence.priority_strategy // "quick-wins-first"' "$config_file")

    # gh_retry: enable retry wrapper on critical GitHub API calls
    GH_RETRY_ENABLED=$(jq -r '.gh_retry // true' "$config_file")

    # stale state reaper: clean old worktrees, artifacts, state entries
    STALE_REAPER_ENABLED=$(jq -r '.stale_reaper // true' "$config_file")
    STALE_REAPER_INTERVAL=$(jq -r '.stale_reaper_interval // 10' "$config_file")
    STALE_REAPER_AGE_DAYS=$(jq -r '.stale_reaper_age_days // 7' "$config_file")

    # priority lane settings
    PRIORITY_LANE=$(jq -r '.priority_lane // false' "$config_file")
    PRIORITY_LANE_LABELS=$(jq -r '.priority_lane_labels // "hotfix,incident,p0,urgent"' "$config_file")
    PRIORITY_LANE_MAX=$(jq -r '.priority_lane_max // 1' "$config_file")

    # org-wide daemon mode
    WATCH_MODE=$(jq -r '.watch_mode // "repo"' "$config_file")
    ORG=$(jq -r '.org // ""' "$config_file")
    if [[ "$ORG" == "null" ]]; then ORG=""; fi
    REPO_FILTER=$(jq -r '.repo_filter // ""' "$config_file")
    if [[ "$REPO_FILTER" == "null" ]]; then REPO_FILTER=""; fi

    # auto-scaling
    AUTO_SCALE=$(jq -r '.auto_scale // false' "$config_file")
    AUTO_SCALE_INTERVAL=$(jq -r '.auto_scale_interval // 5' "$config_file")
    MAX_WORKERS=$(jq -r '.max_workers // 8' "$config_file")
    MIN_WORKERS=$(jq -r '.min_workers // 1' "$config_file")
    WORKER_MEM_GB=$(jq -r '.worker_mem_gb // 4' "$config_file")
    EST_COST_PER_JOB=$(jq -r '.estimated_cost_per_job_usd // 5.0' "$config_file")

    # heartbeat + checkpoint recovery
    HEALTH_HEARTBEAT_TIMEOUT=$(jq -r '.health.heartbeat_timeout_s // 120' "$config_file")
    CHECKPOINT_ENABLED=$(jq -r '.health.checkpoint_enabled // true' "$config_file")

    # progress-based health monitoring (replaces static timeouts)
    PROGRESS_MONITORING=$(jq -r '.health.progress_based // true' "$config_file")
    PROGRESS_CHECKS_BEFORE_WARN=$(jq -r '.health.stale_checks_before_warn // 20' "$config_file")
    PROGRESS_CHECKS_BEFORE_KILL=$(jq -r '.health.stale_checks_before_kill // 120' "$config_file")
    PROGRESS_HARD_LIMIT_S=$(jq -r '.health.hard_limit_s // 0' "$config_file")  # 0 = disabled (no hard kill)
    NUDGE_ENABLED=$(jq -r '.health.nudge_enabled // true' "$config_file")
    NUDGE_AFTER_CHECKS=$(jq -r '.health.nudge_after_checks // 40' "$config_file")

    # team dashboard URL (for coordinated claiming)
    local cfg_dashboard_url
    cfg_dashboard_url=$(jq -r '.dashboard_url // ""' "$config_file")
    if [[ -n "$cfg_dashboard_url" && "$cfg_dashboard_url" != "null" ]]; then
        DASHBOARD_URL="$cfg_dashboard_url"
    fi

    # Auto-enable self_optimize when auto_template is on
    if [[ "${AUTO_TEMPLATE:-false}" == "true" && "${SELF_OPTIMIZE:-false}" == "false" ]]; then
        SELF_OPTIMIZE="true"
        daemon_log INFO "Auto-enabling self_optimize (auto_template is true)"
    fi

    success "Config loaded"
}

# ─── Directory Setup ────────────────────────────────────────────────────────

setup_dirs() {
    mkdir -p "$DAEMON_DIR"
    mkdir -p "$HOME/.shipwright"

    STATE_FILE="$DAEMON_DIR/daemon-state.json"
    LOG_FILE="$DAEMON_DIR/daemon.log"
    LOG_DIR="$DAEMON_DIR/logs"
    WORKTREE_DIR=".worktrees"
    PAUSE_FLAG="${HOME}/.shipwright/daemon-pause.flag"

    mkdir -p "$LOG_DIR"
    mkdir -p "$HOME/.shipwright/progress"
}

# ─── Adaptive Threshold Helpers ──────────────────────────────────────────────
# When intelligence.adaptive_enabled=true, operational thresholds are learned
# from historical data instead of using fixed defaults.
# Every function falls back to the current hardcoded value when no data exists.

ADAPTIVE_THRESHOLDS_ENABLED="${ADAPTIVE_THRESHOLDS_ENABLED:-false}"
PRIORITY_STRATEGY="${PRIORITY_STRATEGY:-quick-wins-first}"
EMPTY_QUEUE_CYCLES=0

# Adapt poll interval based on queue state
# Empty queue 5+ cycles → 120s; queue has items → 30s; processing → 60s
get_adaptive_poll_interval() {
    local queue_depth="$1"
    local active_count="$2"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        echo "$POLL_INTERVAL"
        return
    fi

    if [[ "$queue_depth" -eq 0 && "$active_count" -eq 0 ]]; then
        EMPTY_QUEUE_CYCLES=$((EMPTY_QUEUE_CYCLES + 1))
    else
        EMPTY_QUEUE_CYCLES=0
    fi

    local interval="$POLL_INTERVAL"
    if [[ "$EMPTY_QUEUE_CYCLES" -ge 5 ]]; then
        interval=120
    elif [[ "$queue_depth" -gt 0 ]]; then
        interval=30
    else
        interval=60
    fi

    # Persist current setting for dashboard visibility
    local tuning_file="$HOME/.shipwright/optimization/daemon-tuning.json"
    mkdir -p "$HOME/.shipwright/optimization"
    local tmp_tuning="${tuning_file}.tmp.$$"
    if [[ -f "$tuning_file" ]]; then
        jq --argjson pi "$interval" --argjson eqc "$EMPTY_QUEUE_CYCLES" \
            '.poll_interval = $pi | .empty_queue_cycles = $eqc' \
            "$tuning_file" > "$tmp_tuning" 2>/dev/null && mv "$tmp_tuning" "$tuning_file"
    else
        jq -n --argjson pi "$interval" --argjson eqc "$EMPTY_QUEUE_CYCLES" \
            '{poll_interval: $pi, empty_queue_cycles: $eqc}' > "$tmp_tuning" \
            && mv "$tmp_tuning" "$tuning_file"
    fi

    echo "$interval"
}

# Rolling average cost per template from costs.json (last 10 runs)
get_adaptive_cost_estimate() {
    local template="${1:-autonomous}"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        echo "$EST_COST_PER_JOB"
        return
    fi

    local costs_file="$HOME/.shipwright/costs.json"
    if [[ ! -f "$costs_file" ]]; then
        echo "$EST_COST_PER_JOB"
        return
    fi

    local avg_cost
    avg_cost=$(jq -r --arg tpl "$template" '
        [.sessions // [] | .[] | select(.template == $tpl) | .total_cost_usd // 0] |
        .[-10:] | if length > 0 then (add / length) else null end
    ' "$costs_file" 2>/dev/null || echo "")

    if [[ -n "$avg_cost" && "$avg_cost" != "null" && "$avg_cost" != "0" ]]; then
        echo "$avg_cost"
    else
        echo "$EST_COST_PER_JOB"
    fi
}

# Per-stage adaptive heartbeat timeout from learned stage durations
get_adaptive_heartbeat_timeout() {
    local stage="${1:-unknown}"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        echo "${HEALTH_HEARTBEAT_TIMEOUT:-120}"
        return
    fi

    # Stage-specific defaults (used when no learned data)
    local default_timeout="${HEALTH_HEARTBEAT_TIMEOUT:-120}"
    case "$stage" in
        build)  default_timeout=300 ;;
        test)   default_timeout=180 ;;
        review|compound_quality) default_timeout=180 ;;
        lint|format|intake|plan|design) default_timeout=60 ;;
    esac

    local durations_file="$HOME/.shipwright/optimization/stage-durations.json"
    if [[ ! -f "$durations_file" ]]; then
        echo "$default_timeout"
        return
    fi

    local learned_duration
    learned_duration=$(jq -r --arg s "$stage" \
        '.stages[$s].p90_duration_s // 0' "$durations_file" 2>/dev/null || echo "0")

    if [[ "$learned_duration" -gt 0 ]]; then
        # 150% of p90 duration, floor of 60s
        local adaptive_timeout=$(( (learned_duration * 3) / 2 ))
        [[ "$adaptive_timeout" -lt 60 ]] && adaptive_timeout=60
        echo "$adaptive_timeout"
    else
        echo "$default_timeout"
    fi
}

# Adaptive stale pipeline timeout using 95th percentile of historical durations
get_adaptive_stale_timeout() {
    local template="${1:-autonomous}"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        echo "${HEALTH_STALE_TIMEOUT:-1800}"
        return
    fi

    local durations_file="$HOME/.shipwright/optimization/pipeline-durations.json"
    if [[ ! -f "$durations_file" ]]; then
        echo "${HEALTH_STALE_TIMEOUT:-1800}"
        return
    fi

    local p95_duration
    p95_duration=$(jq -r --arg tpl "$template" \
        '.templates[$tpl].p95_duration_s // 0' "$durations_file" 2>/dev/null || echo "0")

    if [[ "$p95_duration" -gt 0 ]]; then
        # 1.5x safety margin, clamped 600s-7200s
        local adaptive_timeout=$(( (p95_duration * 3) / 2 ))
        [[ "$adaptive_timeout" -lt 600 ]] && adaptive_timeout=600
        [[ "$adaptive_timeout" -gt 7200 ]] && adaptive_timeout=7200
        echo "$adaptive_timeout"
    else
        echo "${HEALTH_STALE_TIMEOUT:-1800}"
    fi
}

# Record pipeline duration for future threshold learning
record_pipeline_duration() {
    local template="$1" duration_s="$2" result="$3"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        return
    fi
    [[ ! "$duration_s" =~ ^[0-9]+$ ]] && return

    local durations_file="$HOME/.shipwright/optimization/pipeline-durations.json"
    mkdir -p "$HOME/.shipwright/optimization"

    if [[ ! -f "$durations_file" ]]; then
        echo '{"templates":{}}' > "$durations_file"
    fi

    local tmp_dur="${durations_file}.tmp.$$"
    jq --arg tpl "$template" --argjson dur "$duration_s" --arg res "$result" --arg ts "$(now_iso)" '
        .templates[$tpl] = (
            (.templates[$tpl] // {durations: [], p95_duration_s: 0}) |
            .durations = ((.durations + [{duration_s: $dur, result: $res, ts: $ts}]) | .[-50:]) |
            .p95_duration_s = (
                [.durations[].duration_s] | sort |
                if length > 0 then .[((length * 95 / 100) | floor)] else 0 end
            )
        )
    ' "$durations_file" > "$tmp_dur" 2>/dev/null && mv "$tmp_dur" "$durations_file"
}

# ─── Progress-Based Health Monitoring ─────────────────────────────────────────
# Instead of killing jobs after a static timeout, we check for forward progress.
# Progress signals: stage transitions, iteration advances, git diff growth, new files.
# Graduated response: healthy → slowing → stalled → stuck → kill.

PROGRESS_DIR="$HOME/.shipwright/progress"

# Collect a progress snapshot for an active job
# Returns JSON with stage, iteration, diff_lines, files_changed
daemon_collect_snapshot() {
    local issue_num="$1" worktree="$2" pid="$3"

    local stage="" iteration=0 diff_lines=0 files_changed=0 last_error=""

    # Get stage and iteration from heartbeat (fastest source)
    local heartbeat_dir="$HOME/.shipwright/heartbeats"
    if [[ -d "$heartbeat_dir" ]]; then
        local hb_file
        for hb_file in "$heartbeat_dir"/*.json; do
            [[ ! -f "$hb_file" ]] && continue
            local hb_pid
            hb_pid=$(jq -r '.pid // 0' "$hb_file" 2>/dev/null || echo 0)
            if [[ "$hb_pid" == "$pid" ]]; then
                stage=$(jq -r '.stage // "unknown"' "$hb_file" 2>/dev/null || echo "unknown")
                iteration=$(jq -r '.iteration // 0' "$hb_file" 2>/dev/null || echo 0)
                [[ "$iteration" == "null" ]] && iteration=0
                break
            fi
        done
    fi

    # Fallback: read stage from pipeline-state.md in worktree
    if [[ -z "$stage" || "$stage" == "unknown" ]] && [[ -d "$worktree" ]]; then
        local state_file="$worktree/.claude/pipeline-state.md"
        if [[ -f "$state_file" ]]; then
            stage=$(grep -m1 '^current_stage:' "$state_file" 2>/dev/null | sed 's/^current_stage: *//' || echo "unknown")
        fi
    fi

    # Get git diff stats from worktree (how much code has been written)
    if [[ -d "$worktree/.git" ]] || [[ -f "$worktree/.git" ]]; then
        diff_lines=$(cd "$worktree" && git diff --stat 2>/dev/null | tail -1 | grep -o '[0-9]* insertion' | grep -o '[0-9]*' || echo "0")
        [[ -z "$diff_lines" ]] && diff_lines=0
        files_changed=$(cd "$worktree" && git diff --name-only 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        # Also count untracked files the agent has created
        local untracked
        untracked=$(cd "$worktree" && git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        files_changed=$((files_changed + untracked))
    fi

    # Check last error from error log
    if [[ -d "$worktree" ]]; then
        local error_log="$worktree/.claude/pipeline-artifacts/error-log.jsonl"
        if [[ -f "$error_log" ]]; then
            last_error=$(tail -1 "$error_log" 2>/dev/null | jq -r '.signature // ""' 2>/dev/null || echo "")
        fi
    fi

    # Output JSON snapshot
    jq -n \
        --arg stage "$stage" \
        --argjson iteration "${iteration:-0}" \
        --argjson diff_lines "${diff_lines:-0}" \
        --argjson files_changed "${files_changed:-0}" \
        --arg last_error "$last_error" \
        --arg ts "$(now_iso)" \
        '{
            stage: $stage,
            iteration: $iteration,
            diff_lines: $diff_lines,
            files_changed: $files_changed,
            last_error: $last_error,
            ts: $ts
        }'
}

# Assess job progress by comparing current snapshot to previous
# Returns: healthy | slowing | stalled | stuck
daemon_assess_progress() {
    local issue_num="$1" current_snapshot="$2"

    mkdir -p "$PROGRESS_DIR"
    local progress_file="$PROGRESS_DIR/issue-${issue_num}.json"

    # If no previous snapshot, store this one and return healthy
    if [[ ! -f "$progress_file" ]]; then
        jq -n \
            --argjson snap "$current_snapshot" \
            --arg issue "$issue_num" \
            '{
                issue: $issue,
                snapshots: [$snap],
                no_progress_count: 0,
                last_progress_at: $snap.ts,
                repeated_error_count: 0
            }' > "$progress_file"
        echo "healthy"
        return
    fi

    local prev_data
    prev_data=$(cat "$progress_file")

    # Get previous snapshot values
    local prev_stage prev_iteration prev_diff_lines prev_files prev_error prev_no_progress
    prev_stage=$(echo "$prev_data" | jq -r '.snapshots[-1].stage // "unknown"')
    prev_iteration=$(echo "$prev_data" | jq -r '.snapshots[-1].iteration // 0')
    prev_diff_lines=$(echo "$prev_data" | jq -r '.snapshots[-1].diff_lines // 0')
    prev_files=$(echo "$prev_data" | jq -r '.snapshots[-1].files_changed // 0')
    prev_error=$(echo "$prev_data" | jq -r '.snapshots[-1].last_error // ""')
    prev_no_progress=$(echo "$prev_data" | jq -r '.no_progress_count // 0')
    local prev_repeated_errors
    prev_repeated_errors=$(echo "$prev_data" | jq -r '.repeated_error_count // 0')

    # Get current values
    local cur_stage cur_iteration cur_diff cur_files cur_error
    cur_stage=$(echo "$current_snapshot" | jq -r '.stage')
    cur_iteration=$(echo "$current_snapshot" | jq -r '.iteration')
    cur_diff=$(echo "$current_snapshot" | jq -r '.diff_lines')
    cur_files=$(echo "$current_snapshot" | jq -r '.files_changed')
    cur_error=$(echo "$current_snapshot" | jq -r '.last_error')

    # Detect progress
    local has_progress=false

    # Stage advanced → clear progress
    if [[ "$cur_stage" != "$prev_stage" && "$cur_stage" != "unknown" ]]; then
        has_progress=true
        daemon_log INFO "Progress: issue #${issue_num} stage ${prev_stage} → ${cur_stage}"
    fi

    # Iteration increased → clear progress (agent is looping but advancing)
    if [[ "$cur_iteration" -gt "$prev_iteration" ]]; then
        has_progress=true
        daemon_log INFO "Progress: issue #${issue_num} iteration ${prev_iteration} → ${cur_iteration}"
    fi

    # Diff lines grew (agent is writing code)
    if [[ "$cur_diff" -gt "$prev_diff_lines" ]]; then
        has_progress=true
    fi

    # More files touched
    if [[ "$cur_files" -gt "$prev_files" ]]; then
        has_progress=true
    fi

    # Claude subprocess is alive and consuming CPU — agent is thinking/working
    # During build stage, Claude can spend 10+ minutes thinking before any
    # visible git changes appear.  Detect this as progress.
    if [[ "$has_progress" != "true" ]]; then
        local _pid_for_check
        _pid_for_check=$(echo "$current_snapshot" | jq -r '.pid // empty' 2>/dev/null || true)
        if [[ -z "$_pid_for_check" ]]; then
            # Fallback: get PID from active_jobs
            _pid_for_check=$(jq -r --argjson num "$issue_num" \
                '.active_jobs[] | select(.issue == ($num | tonumber)) | .pid' "$STATE_FILE" 2>/dev/null | head -1 || true)
        fi
        if [[ -n "$_pid_for_check" ]]; then
            # Check if any child process (claude) is alive and using CPU
            local child_cpu=0
            child_cpu=$(ps -o pid=,pcpu= -p "$_pid_for_check" 2>/dev/null | awk '{sum+=$2} END{printf "%d", sum+0}' || echo "0")
            if [[ "$child_cpu" -eq 0 ]]; then
                # Check children of the pipeline process
                child_cpu=$(pgrep -P "$_pid_for_check" 2>/dev/null | xargs -I{} ps -o pcpu= -p {} 2>/dev/null | awk '{sum+=$1} END{printf "%d", sum+0}' || echo "0")
            fi
            if [[ "${child_cpu:-0}" -gt 0 ]]; then
                has_progress=true
            fi
        fi
    fi

    # Detect repeated errors (same error signature hitting again)
    local repeated_errors="$prev_repeated_errors"
    if [[ -n "$cur_error" && "$cur_error" == "$prev_error" ]]; then
        repeated_errors=$((repeated_errors + 1))
    elif [[ -n "$cur_error" && "$cur_error" != "$prev_error" ]]; then
        # Different error — reset counter (agent is making different mistakes, that's progress)
        repeated_errors=0
    fi

    # Update no_progress counter
    local no_progress_count
    if [[ "$has_progress" == "true" ]]; then
        no_progress_count=0
        repeated_errors=0
    else
        no_progress_count=$((prev_no_progress + 1))
    fi

    # Update progress file (keep last 10 snapshots)
    local tmp_progress="${progress_file}.tmp.$$"
    jq \
        --argjson snap "$current_snapshot" \
        --argjson npc "$no_progress_count" \
        --argjson rec "$repeated_errors" \
        --arg ts "$(now_iso)" \
        '
        .snapshots = ((.snapshots + [$snap]) | .[-10:]) |
        .no_progress_count = $npc |
        .repeated_error_count = $rec |
        if $npc == 0 then .last_progress_at = $ts else . end
        ' "$progress_file" > "$tmp_progress" 2>/dev/null && mv "$tmp_progress" "$progress_file"

    # ── Vitals-based verdict (preferred over static thresholds) ──
    if type pipeline_compute_vitals &>/dev/null 2>&1 && type pipeline_health_verdict &>/dev/null 2>&1; then
        # Compute vitals using the worktree's pipeline state if available
        local _worktree_state=""
        local _worktree_artifacts=""
        local _worktree_dir
        _worktree_dir=$(jq -r --arg i "$issue_num" '.active_jobs[] | select(.issue == ($i | tonumber)) | .worktree // ""' "$STATE_FILE" 2>/dev/null || echo "")
        if [[ -n "$_worktree_dir" && -d "$_worktree_dir/.claude" ]]; then
            _worktree_state="$_worktree_dir/.claude/pipeline-state.md"
            _worktree_artifacts="$_worktree_dir/.claude/pipeline-artifacts"
        fi

        local _vitals_json
        _vitals_json=$(pipeline_compute_vitals "$_worktree_state" "$_worktree_artifacts" "$issue_num" 2>/dev/null) || true
        if [[ -n "$_vitals_json" && "$_vitals_json" != "{}" ]]; then
            local _health_verdict _health_score
            _health_verdict=$(echo "$_vitals_json" | jq -r '.verdict // "continue"' 2>/dev/null || echo "continue")
            _health_score=$(echo "$_vitals_json" | jq -r '.health_score // 50' 2>/dev/null || echo "50")

            emit_event "pipeline.vitals_check" \
                "issue=$issue_num" \
                "health_score=$_health_score" \
                "verdict=$_health_verdict" \
                "no_progress=$no_progress_count" \
                "repeated_errors=$repeated_errors"

            # Map vitals verdict to daemon verdict
            case "$_health_verdict" in
                continue)
                    echo "healthy"
                    return
                    ;;
                warn)
                    # Sluggish but not dead — equivalent to slowing
                    echo "slowing"
                    return
                    ;;
                intervene)
                    echo "stalled"
                    return
                    ;;
                abort)
                    echo "stuck"
                    return
                    ;;
            esac
        fi
    fi

    # ── Fallback: static threshold verdict ──
    local warn_threshold="${PROGRESS_CHECKS_BEFORE_WARN:-3}"
    local kill_threshold="${PROGRESS_CHECKS_BEFORE_KILL:-6}"

    # Stuck in same error loop — accelerate to kill
    if [[ "$repeated_errors" -ge 3 ]]; then
        echo "stuck"
        return
    fi

    if [[ "$no_progress_count" -ge "$kill_threshold" ]]; then
        echo "stuck"
    elif [[ "$no_progress_count" -ge "$warn_threshold" ]]; then
        echo "stalled"
    elif [[ "$no_progress_count" -ge 1 ]]; then
        echo "slowing"
    else
        echo "healthy"
    fi
}

# Clean up progress tracking for a completed/failed job
daemon_clear_progress() {
    local issue_num="$1"
    rm -f "$PROGRESS_DIR/issue-${issue_num}.json"
}

# Learn actual worker memory from peak RSS of pipeline processes
learn_worker_memory() {
    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        return
    fi
    if [[ ! -f "$STATE_FILE" ]]; then
        return
    fi

    local total_rss=0
    local process_count=0

    while IFS= read -r job; do
        local pid
        pid=$(echo "$job" | jq -r '.pid // empty')
        [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && continue
        if kill -0 "$pid" 2>/dev/null; then
            local rss_kb
            rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")
            [[ ! "$rss_kb" =~ ^[0-9]+$ ]] && rss_kb=0
            if [[ "$rss_kb" -gt 0 ]]; then
                total_rss=$((total_rss + rss_kb))
                process_count=$((process_count + 1))
            fi
        fi
    done < <(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null || true)

    if [[ "$process_count" -gt 0 ]]; then
        local avg_rss_gb=$(( total_rss / process_count / 1048576 ))
        # 125% headroom, minimum 1GB, max 16GB
        local learned_mem_gb=$(( (avg_rss_gb * 5 + 3) / 4 ))
        [[ "$learned_mem_gb" -lt 1 ]] && learned_mem_gb=1
        [[ "$learned_mem_gb" -gt 16 ]] && learned_mem_gb=16

        local tuning_file="$HOME/.shipwright/optimization/daemon-tuning.json"
        mkdir -p "$HOME/.shipwright/optimization"
        local tmp_tuning="${tuning_file}.tmp.$$"
        if [[ -f "$tuning_file" ]]; then
            jq --argjson mem "$learned_mem_gb" --argjson rss "$total_rss" --argjson cnt "$process_count" \
                '.learned_worker_mem_gb = $mem | .last_rss_total_kb = $rss | .last_rss_process_count = $cnt' \
                "$tuning_file" > "$tmp_tuning" 2>/dev/null && mv "$tmp_tuning" "$tuning_file"
        else
            jq -n --argjson mem "$learned_mem_gb" \
                '{learned_worker_mem_gb: $mem}' > "$tmp_tuning" && mv "$tmp_tuning" "$tuning_file"
        fi

        WORKER_MEM_GB="$learned_mem_gb"
    fi
}

# Record scaling outcome for learning optimal parallelism
record_scaling_outcome() {
    local parallelism="$1" result="$2"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        return
    fi

    local tuning_file="$HOME/.shipwright/optimization/daemon-tuning.json"
    mkdir -p "$HOME/.shipwright/optimization"
    local tmp_tuning="${tuning_file}.tmp.$$"
    if [[ -f "$tuning_file" ]]; then
        jq --argjson p "$parallelism" --arg r "$result" --arg ts "$(now_iso)" '
            .scaling_history = ((.scaling_history // []) + [{parallelism: $p, result: $r, ts: $ts}]) |
            .scaling_history |= .[-50:]
        ' "$tuning_file" > "$tmp_tuning" 2>/dev/null && mv "$tmp_tuning" "$tuning_file"
    else
        jq -n --argjson p "$parallelism" --arg r "$result" --arg ts "$(now_iso)" '
            {scaling_history: [{parallelism: $p, result: $r, ts: $ts}]}
        ' > "$tmp_tuning" && mv "$tmp_tuning" "$tuning_file"
    fi
}

# Get success rate at a given parallelism level (for gradual scaling decisions)
get_success_rate_at_parallelism() {
    local target_parallelism="$1"

    local tuning_file="$HOME/.shipwright/optimization/daemon-tuning.json"
    if [[ ! -f "$tuning_file" ]]; then
        echo "100"
        return
    fi

    local rate
    rate=$(jq -r --argjson p "$target_parallelism" '
        [.scaling_history // [] | .[] | select(.parallelism == $p)] |
        if length > 0 then
            ([.[] | select(.result == "success")] | length) * 100 / length | floor
        else 100 end
    ' "$tuning_file" 2>/dev/null || echo "100")

    echo "${rate:-100}"
}

# Adapt patrol limits based on hit rate
adapt_patrol_limits() {
    local findings="$1" max_issues="$2"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        return
    fi

    local tuning_file="$HOME/.shipwright/optimization/daemon-tuning.json"
    mkdir -p "$HOME/.shipwright/optimization"

    local new_max="$max_issues"
    if [[ "$findings" -ge "$max_issues" ]]; then
        # Consistently hitting limit — increase
        new_max=$((max_issues + 2))
        [[ "$new_max" -gt 20 ]] && new_max=20
    elif [[ "$findings" -eq 0 ]]; then
        # Finds nothing — reduce
        if [[ "$max_issues" -gt 3 ]]; then
            new_max=$((max_issues - 1))
        else
            new_max=3
        fi
    fi

    local tmp_tuning="${tuning_file}.tmp.$$"
    if [[ -f "$tuning_file" ]]; then
        jq --argjson pm "$new_max" --argjson lf "$findings" --arg ts "$(now_iso)" \
            '.patrol_max_issues = $pm | .last_patrol_findings = $lf | .patrol_adapted_at = $ts' \
            "$tuning_file" > "$tmp_tuning" 2>/dev/null && mv "$tmp_tuning" "$tuning_file"
    else
        jq -n --argjson pm "$new_max" --argjson lf "$findings" --arg ts "$(now_iso)" \
            '{patrol_max_issues: $pm, last_patrol_findings: $lf, patrol_adapted_at: $ts}' \
            > "$tmp_tuning" && mv "$tmp_tuning" "$tuning_file"
    fi
}

# Load adaptive patrol limits from tuning config
load_adaptive_patrol_limits() {
    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        return
    fi

    local tuning_file="$HOME/.shipwright/optimization/daemon-tuning.json"
    if [[ ! -f "$tuning_file" ]]; then
        return
    fi

    local adaptive_max_issues
    adaptive_max_issues=$(jq -r '.patrol_max_issues // 0' "$tuning_file" 2>/dev/null || echo "0")
    if [[ "$adaptive_max_issues" -gt 0 ]]; then
        PATROL_MAX_ISSUES="$adaptive_max_issues"
    fi
}

# Extract dependency issue numbers from issue text
extract_issue_dependencies() {
    local text="$1"

    echo "$text" | grep -oE '(depends on|blocked by|after) #[0-9]+' | grep -oE '#[0-9]+' | sort -u || true
}

# ─── Logging ─────────────────────────────────────────────────────────────────
DAEMON_LOG_WRITE_COUNT=0

daemon_log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(now_iso)
    echo "[$ts] [$level] $msg" >> "$LOG_FILE"

    # Rotate daemon.log if over 20MB (checked every 100 writes)
    DAEMON_LOG_WRITE_COUNT=$(( DAEMON_LOG_WRITE_COUNT + 1 ))
    if [[ $(( DAEMON_LOG_WRITE_COUNT % 100 )) -eq 0 ]] && [[ -f "$LOG_FILE" ]]; then
        local log_size
        log_size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$log_size" -gt 20971520 ]]; then
            [[ -f "${LOG_FILE}.2" ]] && mv "${LOG_FILE}.2" "${LOG_FILE}.3"
            [[ -f "${LOG_FILE}.1" ]] && mv "${LOG_FILE}.1" "${LOG_FILE}.2"
            mv "$LOG_FILE" "${LOG_FILE}.1"
            touch "$LOG_FILE"
        fi
    fi

    # Print to stderr (NOT stdout) to avoid corrupting command substitution captures.
    # This is critical: functions like select_pipeline_template(), triage_score_issue(),
    # gh_retry(), and locked_get_active_count() return values via echo/stdout and are
    # called via $(). If daemon_log writes to stdout, the log text corrupts return values.
    case "$level" in
        INFO)    info "$msg" >&2 ;;
        SUCCESS) success "$msg" >&2 ;;
        WARN)    warn "$msg" >&2 ;;
        ERROR)   error "$msg" ;;
    esac
}

# ─── Notification Helper ────────────────────────────────────────────────────

notify() {
    local title="$1" message="$2" level="${3:-info}"
    local emoji
    case "$level" in
        success) emoji="✅" ;;
        error)   emoji="❌" ;;
        warn)    emoji="⚠️" ;;
        *)       emoji="🔔" ;;
    esac

    # Slack webhook
    if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
        local payload
        payload=$(jq -n \
            --arg text "${emoji} *${title}*\n${message}" \
            '{text: $text}')
        curl -sf -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$SLACK_WEBHOOK" >/dev/null 2>&1 || true
    fi

    # Custom webhook (env var SHIPWRIGHT_WEBHOOK_URL, with CCT_WEBHOOK_URL fallback)
    local _webhook_url="${SHIPWRIGHT_WEBHOOK_URL:-${CCT_WEBHOOK_URL:-}}"
    if [[ -n "$_webhook_url" ]]; then
        local payload
        payload=$(jq -n \
            --arg title "$title" --arg message "$message" \
            --arg level "$level" \
            '{title:$title, message:$message, level:$level}')
        curl -sf -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$_webhook_url" >/dev/null 2>&1 || true
    fi
}

# ─── GitHub Rate-Limit Circuit Breaker ─────────────────────────────────────
# Tracks consecutive GitHub API failures. If we hit too many failures in a row,
# we back off exponentially to avoid hammering a rate-limited API.

GH_CONSECUTIVE_FAILURES=0
GH_BACKOFF_UNTIL=0  # epoch seconds — skip gh calls until this time

gh_rate_limited() {
    # Returns 0 (true) if we should skip GitHub API calls
    local now_e
    now_e=$(now_epoch)
    if [[ "$GH_BACKOFF_UNTIL" -gt "$now_e" ]]; then
        return 0
    fi
    return 1
}

gh_record_success() {
    GH_CONSECUTIVE_FAILURES=0
    GH_BACKOFF_UNTIL=0
}

gh_record_failure() {
    GH_CONSECUTIVE_FAILURES=$((GH_CONSECUTIVE_FAILURES + 1))
    if [[ "$GH_CONSECUTIVE_FAILURES" -ge 3 ]]; then
        # Exponential backoff: 30s, 60s, 120s, 240s (capped at 5min)
        # Cap shift to avoid integer overflow for large failure counts
        local shift_amt=$(( GH_CONSECUTIVE_FAILURES - 3 ))
        [[ "$shift_amt" -gt 4 ]] && shift_amt=4
        local backoff_secs=$((30 * (1 << shift_amt)))
        [[ "$backoff_secs" -gt 300 ]] && backoff_secs=300
        GH_BACKOFF_UNTIL=$(( $(now_epoch) + backoff_secs ))
        daemon_log WARN "GitHub rate-limit circuit breaker: backing off ${backoff_secs}s after ${GH_CONSECUTIVE_FAILURES} failures"
        emit_event "daemon.rate_limit" "failures=$GH_CONSECUTIVE_FAILURES" "backoff_s=$backoff_secs"
    fi
}

# ─── Runtime Auth Check ──────────────────────────────────────────────────────

LAST_AUTH_CHECK_EPOCH=0
AUTH_CHECK_INTERVAL=300  # 5 minutes

daemon_preflight_auth_check() {
    local now_e
    now_e=$(now_epoch)
    if [[ $((now_e - LAST_AUTH_CHECK_EPOCH)) -lt "$AUTH_CHECK_INTERVAL" ]]; then
        return 0
    fi
    LAST_AUTH_CHECK_EPOCH="$now_e"

    # gh auth check
    if [[ "${NO_GITHUB:-false}" != "true" ]]; then
        if ! gh auth status &>/dev/null 2>&1; then
            daemon_log ERROR "GitHub auth check failed — auto-pausing daemon"
            local pause_json
            pause_json=$(jq -n --arg reason "gh_auth_failure" --arg ts "$(now_iso)" \
                '{reason: $reason, timestamp: $ts}')
            local _tmp_pause
            _tmp_pause=$(mktemp "${TMPDIR:-/tmp}/sw-pause.XXXXXX")
            echo "$pause_json" > "$_tmp_pause"
            mv "$_tmp_pause" "$PAUSE_FLAG"
            emit_event "daemon.auto_pause" "reason=gh_auth_failure"
            return 1
        fi
    fi

    # claude auth check with 15s timeout (macOS has no timeout command)
    local claude_auth_ok=false
    local _auth_tmp
    _auth_tmp=$(mktemp "${TMPDIR:-/tmp}/sw-auth.XXXXXX")
    ( claude --print -p "ok" --max-turns 1 > "$_auth_tmp" 2>/dev/null ) &
    local _auth_pid=$!
    local _auth_waited=0
    while kill -0 "$_auth_pid" 2>/dev/null && [[ "$_auth_waited" -lt 15 ]]; do
        sleep 1
        _auth_waited=$((_auth_waited + 1))
    done
    if kill -0 "$_auth_pid" 2>/dev/null; then
        kill "$_auth_pid" 2>/dev/null || true
        wait "$_auth_pid" 2>/dev/null || true
    else
        wait "$_auth_pid" 2>/dev/null || true
    fi

    if [[ -s "$_auth_tmp" ]]; then
        claude_auth_ok=true
    fi
    rm -f "$_auth_tmp"

    if [[ "$claude_auth_ok" != "true" ]]; then
        daemon_log ERROR "Claude auth check failed — auto-pausing daemon"
        local pause_json
        pause_json=$(jq -n --arg reason "claude_auth_failure" --arg ts "$(now_iso)" \
            '{reason: $reason, timestamp: $ts}')
        local _tmp_pause
        _tmp_pause=$(mktemp "${TMPDIR:-/tmp}/sw-pause.XXXXXX")
        echo "$pause_json" > "$_tmp_pause"
        mv "$_tmp_pause" "$PAUSE_FLAG"
        emit_event "daemon.auto_pause" "reason=claude_auth_failure"
        return 1
    fi

    return 0
}

# ─── Pre-flight Checks ──────────────────────────────────────────────────────

preflight_checks() {
    local errors=0

    echo -e "${PURPLE}${BOLD}━━━ Pre-flight Checks ━━━${RESET}"
    echo ""

    # 1. Required tools
    local required_tools=("git" "jq" "gh" "claude")
    local optional_tools=("tmux" "curl")

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${RED}✗${RESET} $tool ${RED}(required)${RESET}"
            errors=$((errors + 1))
        fi
    done

    for tool in "${optional_tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${DIM}○${RESET} $tool ${DIM}(optional — some features disabled)${RESET}"
        fi
    done

    # 2. Git state
    echo ""
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} Inside git repo"
    else
        echo -e "  ${RED}✗${RESET} Not inside a git repository"
        errors=$((errors + 1))
    fi

    # Check base branch exists
    if git rev-parse --verify "$BASE_BRANCH" &>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} Base branch: $BASE_BRANCH"
    else
        echo -e "  ${RED}✗${RESET} Base branch not found: $BASE_BRANCH"
        errors=$((errors + 1))
    fi

    # 3. GitHub auth (required for daemon — it needs to poll issues)
    if [[ "$NO_GITHUB" != "true" ]]; then
        if gh auth status &>/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} GitHub authenticated"
        else
            echo -e "  ${RED}✗${RESET} GitHub not authenticated (required for daemon)"
            errors=$((errors + 1))
        fi
    else
        echo -e "  ${DIM}○${RESET} GitHub disabled (--no-github)"
    fi

    # 4. Pipeline script
    if [[ -x "$SCRIPT_DIR/sw-pipeline.sh" ]]; then
        echo -e "  ${GREEN}✓${RESET} sw-pipeline.sh available"
    else
        echo -e "  ${RED}✗${RESET} sw-pipeline.sh not found at $SCRIPT_DIR"
        errors=$((errors + 1))
    fi

    # 5. Disk space check (warn if < 1GB free)
    local free_space_kb
    free_space_kb=$(df -k "." 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$free_space_kb" ]] && [[ "$free_space_kb" -lt 1048576 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}⚠${RESET} Low disk space: $(( free_space_kb / 1024 ))MB free"
    fi

    echo ""

    if [[ "$errors" -gt 0 ]]; then
        error "Pre-flight failed: $errors error(s)"
        return 1
    fi

    success "Pre-flight passed"
    echo ""
    return 0
}

# ─── State Management ───────────────────────────────────────────────────────

# State file lock FD (used by locked_state_update for serialized read-modify-write)
STATE_LOCK_FD=7

# Atomic write: write to tmp file, then mv (prevents corruption on crash)
atomic_write_state() {
    local content="$1"
    local tmp_file
    tmp_file=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || {
        daemon_log ERROR "Failed to create temp file for state write"
        return 1
    }
    echo "$content" > "$tmp_file" || {
        daemon_log ERROR "Failed to write state to temp file"
        rm -f "$tmp_file"
        return 1
    }
    mv "$tmp_file" "$STATE_FILE" || {
        daemon_log ERROR "Failed to move temp state file into place"
        rm -f "$tmp_file"
        return 1
    }
}

# Locked read-modify-write: prevents TOCTOU race on state file.
# Usage: locked_state_update '.queued += [42]'
# The jq expression is applied to the current state file atomically.
locked_state_update() {
    local jq_expr="$1"
    shift
    local lock_file="${STATE_FILE}.lock"
    (
        if command -v flock &>/dev/null; then
            flock -w 5 200 2>/dev/null || {
                daemon_log ERROR "locked_state_update: lock acquisition timed out — aborting"
                return 1
            }
        fi
        local tmp
        tmp=$(jq "$jq_expr" "$@" "$STATE_FILE" 2>&1) || {
            daemon_log ERROR "locked_state_update: jq failed — $(echo "$tmp" | head -1)"
            return 1
        }
        atomic_write_state "$tmp" || {
            daemon_log ERROR "locked_state_update: atomic_write_state failed"
            return 1
        }
    ) 200>"$lock_file"
}

init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        local init_json
        init_json=$(jq -n \
            --arg pid "$$" \
            --arg started "$(now_iso)" \
            --argjson interval "$POLL_INTERVAL" \
            --argjson max_parallel "$MAX_PARALLEL" \
            --arg label "$WATCH_LABEL" \
            --arg watch_mode "$WATCH_MODE" \
            '{
                version: 1,
                pid: ($pid | tonumber),
                started_at: $started,
                last_poll: null,
                config: {
                    poll_interval: $interval,
                    max_parallel: $max_parallel,
                    watch_label: $label,
                    watch_mode: $watch_mode
                },
                active_jobs: [],
                queued: [],
                completed: [],
                retry_counts: {},
                failure_history: [],
                priority_lane_active: [],
                titles: {}
            }')
        local lock_file="${STATE_FILE}.lock"
        (
            if command -v flock &>/dev/null; then
                flock -w 5 200 2>/dev/null || {
                    daemon_log ERROR "init_state: lock acquisition timed out"
                    return 1
                }
            fi
            atomic_write_state "$init_json"
        ) 200>"$lock_file"
    else
        # Update PID and start time in existing state
        locked_state_update \
            --arg pid "$$" \
            --arg started "$(now_iso)" \
            '.pid = ($pid | tonumber) | .started_at = $started'
    fi
}

update_state_field() {
    local field="$1" value="$2"
    locked_state_update --arg field "$field" --arg val "$value" \
        '.[$field] = $val'
}

# ─── Inflight Check ─────────────────────────────────────────────────────────

daemon_is_inflight() {
    local issue_num="$1"

    if [[ ! -f "$STATE_FILE" ]]; then
        return 1
    fi

    # Check active_jobs
    local active_match
    active_match=$(jq -r --argjson num "$issue_num" \
        '.active_jobs[] | select(.issue == $num) | .issue' \
        "$STATE_FILE" 2>/dev/null || true)
    if [[ -n "$active_match" ]]; then
        return 0
    fi

    # Check queued
    local queued_match
    queued_match=$(jq -r --argjson num "$issue_num" \
        '.queued[] | select(. == $num)' \
        "$STATE_FILE" 2>/dev/null || true)
    if [[ -n "$queued_match" ]]; then
        return 0
    fi

    return 1
}

# ─── Active Job Count ───────────────────────────────────────────────────────

get_active_count() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo 0
        return
    fi
    jq -r '.active_jobs | length' "$STATE_FILE" 2>/dev/null || echo 0
}

# Race-safe active count: acquires state lock before reading.
# Returns MAX_PARALLEL on lock timeout (safe fail — prevents over-spawning).
locked_get_active_count() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo 0
        return
    fi
    local lock_file="${STATE_FILE}.lock"
    local count
    count=$(
        (
            if command -v flock &>/dev/null; then
                flock -w 5 200 2>/dev/null || {
                    daemon_log WARN "locked_get_active_count: lock timeout — returning MAX_PARALLEL as safe default" >&2
                    echo "$MAX_PARALLEL"
                    exit 0
                }
            fi
            jq -r '.active_jobs | length' "$STATE_FILE" 2>/dev/null || echo "$MAX_PARALLEL"
        ) 200>"$lock_file"
    )
    echo "${count:-0}"
}

# ─── Queue Management ───────────────────────────────────────────────────────

enqueue_issue() {
    local issue_num="$1"
    locked_state_update --argjson num "$issue_num" \
        '.queued += [$num] | .queued |= unique'
    daemon_log INFO "Queued issue #${issue_num} (at capacity)"
}

dequeue_next() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return
    fi

    local next
    next=$(jq -r '.queued[0] // empty' "$STATE_FILE" 2>/dev/null || true)
    if [[ -n "$next" ]]; then
        # Remove from queue (locked to prevent race with enqueue)
        locked_state_update '.queued = .queued[1:]'
        echo "$next"
    fi
}

# ─── Priority Lane Helpers ─────────────────────────────────────────────────

is_priority_issue() {
    local labels_csv="$1"
    local IFS=','
    local lane_labels
    read -ra lane_labels <<< "$PRIORITY_LANE_LABELS"
    for lane_label in "${lane_labels[@]}"; do
        # Trim whitespace
        lane_label="${lane_label## }"
        lane_label="${lane_label%% }"
        if [[ ",$labels_csv," == *",$lane_label,"* ]]; then
            return 0
        fi
    done
    return 1
}

get_priority_active_count() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo 0
        return
    fi
    jq -r '.priority_lane_active // [] | length' "$STATE_FILE" 2>/dev/null || echo 0
}

track_priority_job() {
    local issue_num="$1"
    locked_state_update --argjson num "$issue_num" \
        '.priority_lane_active = ((.priority_lane_active // []) + [$num] | unique)'
}

untrack_priority_job() {
    local issue_num="$1"
    if [[ ! -f "$STATE_FILE" ]]; then
        return
    fi
    locked_state_update --argjson num "$issue_num" \
        '.priority_lane_active = [(.priority_lane_active // [])[] | select(. != $num)]'
}

# ─── Distributed Issue Claiming ───────────────────────────────────────────

claim_issue() {
    local issue_num="$1"
    local machine_name="$2"

    [[ "$NO_GITHUB" == "true" ]] && return 0  # No claiming in no-github mode

    # Try dashboard-coordinated claim first (atomic label-based)
    local resp
    resp=$(curl -s --max-time 5 -X POST "${DASHBOARD_URL}/api/claim" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --argjson issue "$issue_num" --arg machine "$machine_name" \
            '{issue: $issue, machine: $machine}')" 2>/dev/null || echo "")

    if [[ -n "$resp" ]] && echo "$resp" | jq -e '.approved == true' &>/dev/null; then
        return 0
    elif [[ -n "$resp" ]] && echo "$resp" | jq -e '.approved == false' &>/dev/null; then
        local claimed_by
        claimed_by=$(echo "$resp" | jq -r '.claimed_by // "another machine"')
        daemon_log INFO "Issue #${issue_num} claimed by ${claimed_by} (via dashboard)"
        return 1
    fi

    # Fallback: direct GitHub label check (dashboard unreachable)
    daemon_log WARN "Dashboard unreachable — falling back to direct GitHub label claim"
    local existing_claim
    existing_claim=$(gh issue view "$issue_num" --json labels --jq \
        '[.labels[].name | select(startswith("claimed:"))] | .[0] // ""' 2>/dev/null || true)

    if [[ -n "$existing_claim" ]]; then
        daemon_log INFO "Issue #${issue_num} already claimed: ${existing_claim}"
        return 1
    fi

    gh issue edit "$issue_num" --add-label "claimed:${machine_name}" 2>/dev/null || return 1
    return 0
}

release_claim() {
    local issue_num="$1"
    local machine_name="$2"

    [[ "$NO_GITHUB" == "true" ]] && return 0

    # Try dashboard-coordinated release first
    curl -s --max-time 5 -X POST "${DASHBOARD_URL}/api/claim/release" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --argjson issue "$issue_num" --arg machine "$machine_name" \
            '{issue: $issue, machine: $machine}')" 2>/dev/null || true

    # Also remove label directly as backup (idempotent)
    gh issue edit "$issue_num" --remove-label "claimed:${machine_name}" 2>/dev/null || true
}

# ─── Org-Wide Repo Management ─────────────────────────────────────────────

daemon_ensure_repo() {
    local owner="$1" repo="$2"
    local repo_dir="$DAEMON_DIR/repos/${owner}/${repo}"

    if [[ -d "$repo_dir/.git" ]]; then
        # Pull latest
        (cd "$repo_dir" && git pull --ff-only 2>/dev/null) || {
            daemon_log WARN "Failed to update ${owner}/${repo} — using existing clone"
        }
    else
        mkdir -p "$DAEMON_DIR/repos/${owner}"
        if ! git clone --depth=1 "https://github.com/${owner}/${repo}.git" "$repo_dir" 2>/dev/null; then
            daemon_log ERROR "Failed to clone ${owner}/${repo}"
            return 1
        fi
        daemon_log INFO "Cloned ${owner}/${repo} to ${repo_dir}"
    fi

    echo "$repo_dir"
}

# ─── Spawn Pipeline ─────────────────────────────────────────────────────────

daemon_spawn_pipeline() {
    local issue_num="$1"
    local issue_title="${2:-}"
    local repo_full_name="${3:-}"  # owner/repo (org mode only)
    shift 3 2>/dev/null || true
    local extra_pipeline_args=("$@")  # Optional extra args passed to sw-pipeline.sh

    daemon_log INFO "Spawning pipeline for issue #${issue_num}: ${issue_title}"

    # ── Issue decomposition (if decomposer available) ──
    local decompose_script="${SCRIPT_DIR}/sw-decompose.sh"
    if [[ -x "$decompose_script" && "$NO_GITHUB" != "true" ]]; then
        local decompose_result=""
        decompose_result=$("$decompose_script" auto "$issue_num" 2>/dev/null) || true
        if [[ "$decompose_result" == *"decomposed"* ]]; then
            daemon_log INFO "Issue #${issue_num} decomposed into subtasks — skipping pipeline"
            # Remove the shipwright label so decomposed parent doesn't re-queue
            gh issue edit "$issue_num" --remove-label "shipwright" 2>/dev/null || true
            return 0
        fi
    fi

    # Extract goal text from issue (title + first line of body)
    local issue_goal="$issue_title"
    if [[ "$NO_GITHUB" != "true" ]]; then
        local issue_body_first
        issue_body_first=$(gh issue view "$issue_num" --json body --jq '.body' 2>/dev/null | head -3 | tr '\n' ' ' | cut -c1-200 || true)
        if [[ -n "$issue_body_first" ]]; then
            issue_goal="${issue_title}: ${issue_body_first}"
        fi
    fi

    # ── Predictive risk assessment (if enabled) ──
    if [[ "${PREDICTION_ENABLED:-false}" == "true" ]] && type predict_pipeline_risk &>/dev/null 2>&1; then
        local issue_json_for_pred=""
        if [[ "$NO_GITHUB" != "true" ]]; then
            issue_json_for_pred=$(gh issue view "$issue_num" --json number,title,body,labels 2>/dev/null || echo "")
        fi
        if [[ -n "$issue_json_for_pred" ]]; then
            local risk_result
            risk_result=$(predict_pipeline_risk "$issue_json_for_pred" "" 2>/dev/null || echo "")
            if [[ -n "$risk_result" ]]; then
                local overall_risk
                overall_risk=$(echo "$risk_result" | jq -r '.overall_risk // 50' 2>/dev/null || echo "50")
                if [[ "$overall_risk" -gt 80 ]]; then
                    daemon_log WARN "HIGH RISK (${overall_risk}%) predicted for issue #${issue_num} — upgrading model"
                    export CLAUDE_MODEL="opus"
                elif [[ "$overall_risk" -lt 30 ]]; then
                    daemon_log INFO "LOW RISK (${overall_risk}%) predicted for issue #${issue_num}"
                fi
            fi
        fi
    fi

    # Check disk space before spawning
    local free_space_kb
    free_space_kb=$(df -k "." 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$free_space_kb" ]] && [[ "$free_space_kb" -lt 1048576 ]] 2>/dev/null; then
        daemon_log WARN "Low disk space ($(( free_space_kb / 1024 ))MB) — skipping issue #${issue_num}"
        return 1
    fi

    local work_dir="" branch_name="daemon/issue-${issue_num}"

    if [[ "$WATCH_MODE" == "org" && -n "$repo_full_name" ]]; then
        # Org mode: use cloned repo directory
        local owner="${repo_full_name%%/*}"
        local repo="${repo_full_name##*/}"
        work_dir=$(daemon_ensure_repo "$owner" "$repo") || return 1

        # Create branch in the cloned repo
        (
            cd "$work_dir"
            git checkout -B "$branch_name" "${BASE_BRANCH}" 2>/dev/null
        ) || {
            daemon_log ERROR "Failed to create branch in ${repo_full_name}"
            return 1
        }
        daemon_log INFO "Org mode: working in ${work_dir} (${repo_full_name})"
    else
        # Standard mode: use git worktree
        work_dir="${WORKTREE_DIR}/daemon-issue-${issue_num}"

        # Serialize worktree operations with a lock file (run in subshell to auto-close FD)
        mkdir -p "$WORKTREE_DIR"
        local wt_ok=0
        (
            flock -w 30 200 2>/dev/null || true

            # Clean up stale worktree if it exists
            if [[ -d "$work_dir" ]]; then
                git worktree remove "$work_dir" --force 2>/dev/null || true
            fi
            git branch -D "$branch_name" 2>/dev/null || true

            git worktree add "$work_dir" -b "$branch_name" "$BASE_BRANCH" 2>/dev/null
        ) 200>"${WORKTREE_DIR}/.worktree.lock"
        wt_ok=$?

        if [[ $wt_ok -ne 0 ]]; then
            daemon_log ERROR "Failed to create worktree for issue #${issue_num}"
            return 1
        fi
        daemon_log INFO "Worktree created at ${work_dir}"
    fi

    # If template is "composed", copy the composed spec into the worktree
    if [[ "$PIPELINE_TEMPLATE" == "composed" ]]; then
        local _src_composed="${REPO_DIR:-.}/.claude/pipeline-artifacts/composed-pipeline.json"
        if [[ -f "$_src_composed" ]]; then
            local _dst_artifacts="${work_dir}/.claude/pipeline-artifacts"
            mkdir -p "$_dst_artifacts"
            cp "$_src_composed" "$_dst_artifacts/composed-pipeline.json" 2>/dev/null || true
            daemon_log INFO "Copied composed pipeline spec to worktree"
        fi
    fi

    # Build pipeline args
    local pipeline_args=("start" "--issue" "$issue_num" "--pipeline" "$PIPELINE_TEMPLATE")
    if [[ "$SKIP_GATES" == "true" ]]; then
        pipeline_args+=("--skip-gates")
    fi
    if [[ -n "$MODEL" ]]; then
        pipeline_args+=("--model" "$MODEL")
    fi
    if [[ "$NO_GITHUB" == "true" ]]; then
        pipeline_args+=("--no-github")
    fi
    # Pass session restart config
    if [[ "${MAX_RESTARTS_CFG:-0}" -gt 0 ]]; then
        pipeline_args+=("--max-restarts" "$MAX_RESTARTS_CFG")
    fi
    # Pass fast test command
    if [[ -n "${FAST_TEST_CMD_CFG:-}" ]]; then
        pipeline_args+=("--fast-test-cmd" "$FAST_TEST_CMD_CFG")
    fi

    # Append any extra pipeline args (from retry escalation, etc.)
    if [[ ${#extra_pipeline_args[@]} -gt 0 ]]; then
        pipeline_args+=("${extra_pipeline_args[@]}")
    fi

    # Run pipeline in work directory (background)
    # Ignore SIGHUP so tmux attach/detach and process group changes don't kill the pipeline
    echo -e "\n\n===== Pipeline run $(date -u +%Y-%m-%dT%H:%M:%SZ) =====" >> "$LOG_DIR/issue-${issue_num}.log" 2>/dev/null || true
    (
        trap '' HUP
        cd "$work_dir"
        exec "$SCRIPT_DIR/sw-pipeline.sh" "${pipeline_args[@]}"
    ) >> "$LOG_DIR/issue-${issue_num}.log" 2>&1 200>&- &
    local pid=$!

    daemon_log INFO "Pipeline started for issue #${issue_num} (PID: ${pid})"

    # Track the job (include repo and goal for org mode)
    daemon_track_job "$issue_num" "$pid" "$work_dir" "$issue_title" "$repo_full_name" "$issue_goal"
    emit_event "daemon.spawn" "issue=$issue_num" "pid=$pid" "repo=${repo_full_name:-local}"
    "$SCRIPT_DIR/sw-tracker.sh" notify "spawn" "$issue_num" 2>/dev/null || true

    # Comment on the issue
    if [[ "$NO_GITHUB" != "true" ]]; then
        local gh_args=()
        if [[ -n "$repo_full_name" ]]; then
            gh_args+=("--repo" "$repo_full_name")
        fi
        gh issue comment "$issue_num" ${gh_args[@]+"${gh_args[@]}"} --body "## 🤖 Pipeline Started

**Delivering:** ${issue_title}

| Field | Value |
|-------|-------|
| Template | \`${PIPELINE_TEMPLATE}\` |
| Branch | \`${branch_name}\` |
| Repo | \`${repo_full_name:-local}\` |
| Started | $(now_iso) |

_Progress updates will appear below as the pipeline advances through each stage._" 2>/dev/null || true
    fi
}

# ─── Track Job ───────────────────────────────────────────────────────────────

daemon_track_job() {
    local issue_num="$1" pid="$2" worktree="$3" title="${4:-}" repo="${5:-}" goal="${6:-}"

    # Write to SQLite (non-blocking, best-effort)
    if type db_save_job &>/dev/null; then
        local job_id="daemon-${issue_num}-$(now_epoch)"
        db_save_job "$job_id" "$issue_num" "$title" "$pid" "$worktree" "" "${PIPELINE_TEMPLATE:-autonomous}" "$goal" 2>/dev/null || true
    fi

    # Always write to JSON state file (primary for now)
    locked_state_update \
        --argjson num "$issue_num" \
        --argjson pid "$pid" \
        --arg wt "$worktree" \
        --arg title "$title" \
        --arg started "$(now_iso)" \
        --arg repo "$repo" \
        --arg goal "$goal" \
        '.active_jobs += [{
            issue: $num,
            pid: $pid,
            worktree: $wt,
            title: $title,
            started_at: $started,
            repo: $repo,
            goal: $goal
        }]'
}

# ─── Reap Completed Jobs ────────────────────────────────────────────────────

daemon_reap_completed() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return
    fi

    local jobs
    jobs=$(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null || true)
    if [[ -z "$jobs" ]]; then
        return
    fi

    local _retry_spawned_for=""

    while IFS= read -r job; do
        local issue_num pid worktree
        issue_num=$(echo "$job" | jq -r '.issue // empty')
        pid=$(echo "$job" | jq -r '.pid // empty')
        worktree=$(echo "$job" | jq -r '.worktree // empty')

        # Skip malformed entries (corrupted state file)
        [[ -z "$issue_num" || ! "$issue_num" =~ ^[0-9]+$ ]] && continue
        [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && continue

        # Check if process is still running
        if kill -0 "$pid" 2>/dev/null; then
            continue
        fi

        # Process is dead — determine exit code
        # Note: wait returns 127 if process was already reaped (e.g., by init)
        # In that case, check pipeline log for success/failure indicators
        local exit_code=0
        wait "$pid" 2>/dev/null || exit_code=$?
        if [[ "$exit_code" -eq 127 ]]; then
            # Process already reaped — check log file for real outcome
            local issue_log="$LOG_DIR/issue-${issue_num}.log"
            if [[ -f "$issue_log" ]]; then
                if grep -q "Pipeline completed successfully" "$issue_log" 2>/dev/null; then
                    exit_code=0
                elif grep -q "Pipeline failed\|ERROR.*stage.*failed\|exited with status" "$issue_log" 2>/dev/null; then
                    exit_code=1
                else
                    daemon_log WARN "Could not determine exit code for issue #${issue_num} (PID ${pid} already reaped) — marking as failure"
                    exit_code=1
                fi
            else
                exit_code=1
            fi
        fi

        local started_at duration_str="" start_epoch=0 end_epoch=0
        started_at=$(echo "$job" | jq -r '.started_at // empty')
        if [[ -n "$started_at" ]]; then
            # macOS date -j for parsing ISO dates (TZ=UTC to parse Z-suffix correctly)
            start_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || date -d "$started_at" +%s 2>/dev/null || echo "0")
            end_epoch=$(now_epoch)
            if [[ "$start_epoch" -gt 0 ]]; then
                duration_str=$(format_duration $((end_epoch - start_epoch)))
            fi
        fi

        local result_str="success"
        [[ "$exit_code" -ne 0 ]] && result_str="failure"
        local dur_s=0
        [[ "$start_epoch" -gt 0 ]] && dur_s=$((end_epoch - start_epoch))
        emit_event "daemon.reap" "issue=$issue_num" "result=$result_str" "duration_s=$dur_s"

        # Update SQLite (mark job complete/failed)
        if type db_complete_job &>/dev/null && type db_fail_job &>/dev/null; then
            local _db_job_id="daemon-${issue_num}-${start_epoch}"
            if [[ "$exit_code" -eq 0 ]]; then
                db_complete_job "$_db_job_id" "$result_str" 2>/dev/null || true
            else
                db_fail_job "$_db_job_id" "$result_str" 2>/dev/null || true
            fi
        fi

        if [[ "$exit_code" -eq 0 ]]; then
            daemon_on_success "$issue_num" "$duration_str"
        else
            daemon_on_failure "$issue_num" "$exit_code" "$duration_str"

            # Cancel any lingering in_progress GitHub Check Runs for failed job
            if [[ "${NO_GITHUB:-false}" != "true" && -n "$worktree" ]]; then
                local check_ids_file="${worktree}/.claude/pipeline-artifacts/check-run-ids.json"
                if [[ -f "$check_ids_file" ]]; then
                    daemon_log INFO "Cancelling in-progress check runs for issue #${issue_num}"
                    local _stage
                    while IFS= read -r _stage; do
                        [[ -z "$_stage" ]] && continue
                        # Direct API call since we're in daemon context
                        local _run_id
                        _run_id=$(jq -r --arg s "$_stage" '.[$s] // empty' "$check_ids_file" 2>/dev/null || true)
                        if [[ -n "$_run_id" && "$_run_id" != "null" ]]; then
                            local _detected
                            _detected=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]\(.*\)\.git$|\1|' || true)
                            if [[ -n "$_detected" ]]; then
                                local _owner="${_detected%%/*}" _repo="${_detected##*/}"
                                gh api "repos/${_owner}/${_repo}/check-runs/${_run_id}" \
                                    --method PATCH \
                                    --field status=completed \
                                    --field conclusion=cancelled \
                                    --silent 2>/dev/null || true
                            fi
                        fi
                    done < <(jq -r 'keys[]' "$check_ids_file" 2>/dev/null || true)
                fi
            fi
        fi

        # Finalize memory (capture failure patterns for future runs)
        if type memory_finalize_pipeline &>/dev/null 2>&1; then
            local _job_state _job_artifacts
            _job_state="${worktree:-.}/.claude/pipeline-state.md"
            _job_artifacts="${worktree:-.}/.claude/pipeline-artifacts"
            memory_finalize_pipeline "$_job_state" "$_job_artifacts" 2>/dev/null || true
        fi

        # Clean up progress tracking for this job
        daemon_clear_progress "$issue_num"

        # Release claim lock (label-based coordination)
        local reap_machine_name
        reap_machine_name=$(jq -r '.machines[] | select(.role == "primary") | .name' "$HOME/.shipwright/machines.json" 2>/dev/null || hostname -s)
        release_claim "$issue_num" "$reap_machine_name"

        # Always remove the OLD job entry from active_jobs to prevent
        # re-reaping of the dead PID on the next cycle.  When a retry was
        # spawned, daemon_spawn_pipeline already added a fresh entry with
        # the new PID — we must not leave the stale one behind.
        locked_state_update --argjson num "$issue_num" \
            --argjson old_pid "${pid:-0}" \
            '.active_jobs = [.active_jobs[] | select(.issue != $num or .pid != $old_pid)]'
        untrack_priority_job "$issue_num"

        if [[ "$_retry_spawned_for" == "$issue_num" ]]; then
            daemon_log INFO "Retry spawned for issue #${issue_num} — skipping worktree cleanup"
        else
            # Clean up worktree (skip for org-mode clones — they persist)
            local job_repo
            job_repo=$(echo "$job" | jq -r '.repo // ""')
            if [[ -z "$job_repo" ]] && [[ -d "$worktree" ]]; then
                git worktree remove "$worktree" --force 2>/dev/null || true
                daemon_log INFO "Cleaned worktree: $worktree"
                git branch -D "daemon/issue-${issue_num}" 2>/dev/null || true
            elif [[ -n "$job_repo" ]]; then
                daemon_log INFO "Org-mode: preserving clone for ${job_repo}"
            fi
        fi

        # Dequeue next issue if available AND we have capacity
        # NOTE: locked_get_active_count prevents TOCTOU race with the
        # active_jobs removal above.  A tiny window remains between
        # the count read and dequeue_next's own lock acquisition, but
        # dequeue_next is itself locked, so the worst case is a
        # missed dequeue that the next poll cycle will pick up.
        local current_active
        current_active=$(locked_get_active_count)
        if [[ "$current_active" -lt "$MAX_PARALLEL" ]]; then
            local next_issue
            next_issue=$(dequeue_next)
            if [[ -n "$next_issue" ]]; then
                local next_title
                next_title=$(jq -r --arg n "$next_issue" '.titles[$n] // ""' "$STATE_FILE" 2>/dev/null || true)
                daemon_log INFO "Dequeuing issue #${next_issue}: ${next_title}"
                daemon_spawn_pipeline "$next_issue" "$next_title"
            fi
        fi
    done <<< "$jobs"
}

# ─── Success Handler ────────────────────────────────────────────────────────

daemon_on_success() {
    local issue_num="$1" duration="${2:-}"

    # Reset consecutive failure tracking on any success
    reset_failure_tracking

    daemon_log SUCCESS "Pipeline completed for issue #${issue_num} (${duration:-unknown})"

    # Record pipeline duration for adaptive threshold learning
    if [[ -n "$duration" && "$duration" != "unknown" ]]; then
        # Parse duration string back to seconds (e.g. "5m 30s" → 330)
        local dur_secs=0
        local _h _m _s
        _h=$(echo "$duration" | grep -oE '[0-9]+h' | grep -oE '[0-9]+' || true)
        _m=$(echo "$duration" | grep -oE '[0-9]+m' | grep -oE '[0-9]+' || true)
        _s=$(echo "$duration" | grep -oE '[0-9]+s' | grep -oE '[0-9]+' || true)
        dur_secs=$(( ${_h:-0} * 3600 + ${_m:-0} * 60 + ${_s:-0} ))
        if [[ "$dur_secs" -gt 0 ]]; then
            record_pipeline_duration "$PIPELINE_TEMPLATE" "$dur_secs" "success"
            record_scaling_outcome "$MAX_PARALLEL" "success"
        fi
    fi

    # Record in completed list + clear retry count for this issue
    locked_state_update \
        --argjson num "$issue_num" \
        --arg result "success" \
        --arg dur "${duration:-unknown}" \
        --arg completed_at "$(now_iso)" \
        '.completed += [{
            issue: $num,
            result: $result,
            duration: $dur,
            completed_at: $completed_at
        }] | .completed = .completed[-500:]
        | del(.retry_counts[($num | tostring)])'

    if [[ "$NO_GITHUB" != "true" ]]; then
        # Remove watch label, add success label
        gh issue edit "$issue_num" \
            --remove-label "$ON_SUCCESS_REMOVE_LABEL" \
            --add-label "$ON_SUCCESS_ADD_LABEL" 2>/dev/null || true

        # Comment on issue
        gh issue comment "$issue_num" --body "## ✅ Pipeline Complete

The autonomous pipeline finished successfully.

| Field | Value |
|-------|-------|
| Duration | ${duration:-unknown} |
| Completed | $(now_iso) |

Check the associated PR for the implementation." 2>/dev/null || true

        # Optionally close the issue
        if [[ "$ON_SUCCESS_CLOSE_ISSUE" == "true" ]]; then
            gh issue close "$issue_num" 2>/dev/null || true
        fi
    fi

    notify "Pipeline Complete — Issue #${issue_num}" \
        "Duration: ${duration:-unknown}" "success"
    "$SCRIPT_DIR/sw-tracker.sh" notify "completed" "$issue_num" 2>/dev/null || true

    # PM agent: record success for learning
    if [[ -x "$SCRIPT_DIR/sw-pm.sh" ]]; then
        bash "$SCRIPT_DIR/sw-pm.sh" learn "$issue_num" success 2>/dev/null || true
    fi
}

# ─── Failure Classification ─────────────────────────────────────────────────

classify_failure() {
    local issue_num="$1"
    if [[ -z "${LOG_DIR:-}" ]]; then
        echo "unknown"
        return
    fi
    local log_path="$LOG_DIR/issue-${issue_num}.log"
    if [[ ! -f "$log_path" ]]; then
        echo "unknown"
        return
    fi
    local tail_content
    tail_content=$(tail -200 "$log_path" 2>/dev/null || true)

    # Auth errors
    if echo "$tail_content" | grep -qiE 'not logged in|unauthorized|auth.*fail|401 |invalid.*token|CLAUDE_CODE_OAUTH_TOKEN|api key.*invalid|authentication required'; then
        echo "auth_error"
        return
    fi
    # API errors (rate limits, timeouts, server errors)
    if echo "$tail_content" | grep -qiE 'rate limit|429 |503 |502 |overloaded|timeout|ETIMEDOUT|ECONNRESET|socket hang up|service unavailable'; then
        echo "api_error"
        return
    fi
    # Invalid issue (not found, empty body)
    if echo "$tail_content" | grep -qiE 'issue not found|404 |no body|could not resolve|GraphQL.*not found|issue.*does not exist'; then
        echo "invalid_issue"
        return
    fi
    # Context exhaustion — check progress file
    local issue_worktree_path="${WORKTREE_DIR:-${REPO_DIR}/.worktrees}/daemon-issue-${issue_num}"
    local progress_file="${issue_worktree_path}/.claude/loop-logs/progress.md"
    if [[ -f "$progress_file" ]]; then
        local cf_iter
        cf_iter=$(grep -oE 'Iteration: [0-9]+' "$progress_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo "0")
        if ! [[ "${cf_iter:-0}" =~ ^[0-9]+$ ]]; then cf_iter="0"; fi
        local cf_tests
        cf_tests=$(grep -oE 'Tests passing: (true|false)' "$progress_file" 2>/dev/null | awk '{print $NF}' || echo "unknown")
        if [[ "${cf_iter:-0}" -gt 0 ]] && { [[ "$cf_tests" == "false" ]] || [[ "$cf_tests" == "unknown" ]]; }; then
            echo "context_exhaustion"
            return
        fi
    fi
    # Build failure (test errors, compile errors)
    if echo "$tail_content" | grep -qiE 'test.*fail|FAIL|build.*error|compile.*error|lint.*fail|npm ERR|exit code [1-9]'; then
        echo "build_failure"
        return
    fi
    echo "unknown"
}

# ─── Consecutive Failure Tracking (persisted + adaptive) ─────────────────────

DAEMON_CONSECUTIVE_FAILURE_CLASS=""
DAEMON_CONSECUTIVE_FAILURE_COUNT=0

# Max retries per failure class (adaptive retry strategy)
get_max_retries_for_class() {
    local class="${1:-unknown}"
    case "$class" in
        auth_error|invalid_issue) echo 0 ;;
        api_error)                echo "${MAX_RETRIES_API_ERROR:-4}" ;;
        context_exhaustion)       echo "${MAX_RETRIES_CONTEXT_EXHAUSTION:-2}" ;;
        build_failure)           echo "${MAX_RETRIES_BUILD:-2}" ;;
        *)                       echo "${MAX_RETRIES:-2}" ;;
    esac
}

# Append failure to persisted history and compute consecutive count; smart pause with exponential backoff
record_failure_class() {
    local failure_class="$1"
    # In-memory consecutive (for backward compat)
    if [[ "$failure_class" == "$DAEMON_CONSECUTIVE_FAILURE_CLASS" ]]; then
        DAEMON_CONSECUTIVE_FAILURE_COUNT=$((DAEMON_CONSECUTIVE_FAILURE_COUNT + 1))
    else
        DAEMON_CONSECUTIVE_FAILURE_CLASS="$failure_class"
        DAEMON_CONSECUTIVE_FAILURE_COUNT=1
    fi

    # Persist failure to state (failure_history) for pattern tracking
    if [[ -f "${STATE_FILE:-}" ]]; then
        local entry
        entry=$(jq -n --arg ts "$(now_iso)" --arg class "$failure_class" '{ts: $ts, class: $class}')
        locked_state_update --argjson entry "$entry" \
            '.failure_history = ((.failure_history // []) + [$entry] | .[-100:])' 2>/dev/null || true
    fi

    # Consecutive count from persisted tail: count only the unbroken run of $failure_class
    # from the newest entry backwards (not total occurrences)
    local consecutive="$DAEMON_CONSECUTIVE_FAILURE_COUNT"
    if [[ -f "${STATE_FILE:-}" ]]; then
        local from_state
        from_state=$(jq -r --arg c "$failure_class" '
            (.failure_history // []) | [.[].class] | reverse |
            if length == 0 then 0
            elif .[0] != $c then 0
            else
                reduce .[] as $x (
                    {count: 0, done: false};
                    if .done then . elif $x == $c then .count += 1 else .done = true end
                ) | .count
            end
        ' "$STATE_FILE" 2>/dev/null || echo "1")
        consecutive="${from_state:-1}"
        [[ "$consecutive" -eq 0 ]] && consecutive="$DAEMON_CONSECUTIVE_FAILURE_COUNT"
        DAEMON_CONSECUTIVE_FAILURE_COUNT="$consecutive"
    fi

    # Smart pause: exponential backoff instead of hard stop (resume_after so daemon can auto-resume)
    if [[ "$consecutive" -ge 3 ]]; then
        local pause_mins=$((5 * (1 << (consecutive - 3))))
        [[ "$pause_mins" -gt 480 ]] && pause_mins=480
        local resume_ts resume_after
        resume_ts=$(($(date +%s) + pause_mins * 60))
        resume_after=$(epoch_to_iso "$resume_ts")
        daemon_log ERROR "${consecutive} consecutive failures (class: ${failure_class}) — auto-pausing until ${resume_after} (${pause_mins}m backoff)"
        local pause_json
        pause_json=$(jq -n \
            --arg reason "consecutive_${failure_class}" \
            --arg ts "$(now_iso)" \
            --arg resume "$resume_after" \
            --argjson count "$consecutive" \
            '{reason: $reason, timestamp: $ts, resume_after: $resume, consecutive_count: $count}')
        local _tmp_pause
        _tmp_pause=$(mktemp "${TMPDIR:-/tmp}/sw-pause.XXXXXX")
        echo "$pause_json" > "$_tmp_pause"
        mv "$_tmp_pause" "$PAUSE_FLAG"
        emit_event "daemon.auto_pause" "reason=consecutive_failures" "class=$failure_class" "count=$consecutive" "resume_after=$resume_after"
    fi
}

reset_failure_tracking() {
    DAEMON_CONSECUTIVE_FAILURE_CLASS=""
    DAEMON_CONSECUTIVE_FAILURE_COUNT=0
}

# ─── Failure Handler ────────────────────────────────────────────────────────

daemon_on_failure() {
    local issue_num="$1" exit_code="${2:-1}" duration="${3:-}"

    daemon_log ERROR "Pipeline failed for issue #${issue_num} (exit: ${exit_code}, ${duration:-unknown})"

    # Record pipeline duration for adaptive threshold learning
    if [[ -n "$duration" && "$duration" != "unknown" ]]; then
        local dur_secs=0
        local _h _m _s
        _h=$(echo "$duration" | grep -oE '[0-9]+h' | grep -oE '[0-9]+' || true)
        _m=$(echo "$duration" | grep -oE '[0-9]+m' | grep -oE '[0-9]+' || true)
        _s=$(echo "$duration" | grep -oE '[0-9]+s' | grep -oE '[0-9]+' || true)
        dur_secs=$(( ${_h:-0} * 3600 + ${_m:-0} * 60 + ${_s:-0} ))
        if [[ "$dur_secs" -gt 0 ]]; then
            record_pipeline_duration "$PIPELINE_TEMPLATE" "$dur_secs" "failure"
            record_scaling_outcome "$MAX_PARALLEL" "failure"
        fi
    fi

    # Record in completed list
    locked_state_update \
        --argjson num "$issue_num" \
        --arg result "failed" \
        --argjson code "$exit_code" \
        --arg dur "${duration:-unknown}" \
        --arg completed_at "$(now_iso)" \
        '.completed += [{
            issue: $num,
            result: $result,
            exit_code: $code,
            duration: $dur,
            completed_at: $completed_at
        }] | .completed = .completed[-500:]'

    # ── Classify failure and decide retry strategy ──
    local failure_class
    failure_class=$(classify_failure "$issue_num")
    daemon_log INFO "Failure classified as: ${failure_class} for issue #${issue_num}"
    emit_event "daemon.failure_classified" "issue=$issue_num" "class=$failure_class"
    record_failure_class "$failure_class"

    # ── Auto-retry with strategy escalation ──
    if [[ "${RETRY_ESCALATION:-true}" == "true" ]]; then
        local retry_count
        retry_count=$(jq -r --arg num "$issue_num" \
            '.retry_counts[$num] // 0' "$STATE_FILE" 2>/dev/null || echo "0")

        # Non-retryable failures — skip retry entirely
        case "$failure_class" in
            auth_error)
                daemon_log ERROR "Auth error for issue #${issue_num} — skipping retry"
                emit_event "daemon.skip_retry" "issue=$issue_num" "reason=auth_error"
                if [[ "$NO_GITHUB" != "true" ]]; then
                    gh issue edit "$issue_num" --add-label "pipeline/auth-error" 2>/dev/null || true
                fi
                ;;
            invalid_issue)
                daemon_log ERROR "Invalid issue #${issue_num} — skipping retry"
                emit_event "daemon.skip_retry" "issue=$issue_num" "reason=invalid_issue"
                if [[ "$NO_GITHUB" != "true" ]]; then
                    gh issue comment "$issue_num" --body "Pipeline skipped retry: issue appears invalid or has no body." 2>/dev/null || true
                fi
                ;;
            *)
                # Retryable failures — per-class max retries and escalation
                local effective_max
                effective_max=$(get_max_retries_for_class "$failure_class")
                if [[ "$retry_count" -lt "$effective_max" ]]; then
                    retry_count=$((retry_count + 1))

                    # Update retry count in state (locked to prevent race)
                    locked_state_update \
                        --arg num "$issue_num" --argjson count "$retry_count" \
                        '.retry_counts[$num] = $count'

                    daemon_log WARN "Auto-retry #${retry_count}/${effective_max} for issue #${issue_num} (class: ${failure_class})"
                    emit_event "daemon.retry" "issue=$issue_num" "retry=$retry_count" "max=$effective_max" "class=$failure_class"

                    # Check for checkpoint to enable resume-from-checkpoint
                    local checkpoint_args=()
                    if [[ "${CHECKPOINT_ENABLED:-true}" == "true" ]]; then
                        local issue_worktree="${REPO_DIR}/.worktrees/daemon-issue-${issue_num}"
                        if [[ -d "$issue_worktree/.claude/pipeline-artifacts/checkpoints" ]]; then
                            local latest_checkpoint=""
                            for cp_file in "$issue_worktree/.claude/pipeline-artifacts/checkpoints"/*-checkpoint.json; do
                                [[ -f "$cp_file" ]] && latest_checkpoint="$cp_file"
                            done
                            if [[ -n "$latest_checkpoint" ]]; then
                                daemon_log INFO "Found checkpoint: $latest_checkpoint"
                                emit_event "daemon.recovery" "issue=$issue_num" "checkpoint=$latest_checkpoint"
                                checkpoint_args+=("--resume")
                            fi
                        fi
                    fi

                    # Build escalated pipeline args
                    local retry_template="$PIPELINE_TEMPLATE"
                    local retry_model="${MODEL:-opus}"
                    local extra_args=()

                    if [[ "$retry_count" -eq 1 ]]; then
                        retry_model="opus"
                        extra_args+=("--max-iterations" "30")
                        daemon_log INFO "Escalation: model=opus, max_iterations=30"
                    elif [[ "$retry_count" -ge 2 ]]; then
                        retry_template="full"
                        retry_model="opus"
                        extra_args+=("--max-iterations" "30" "--compound-cycles" "5")
                        daemon_log INFO "Escalation: template=full, compound_cycles=5"
                    fi

                    # Increase restarts on context exhaustion
                    if [[ "$failure_class" == "context_exhaustion" ]]; then
                        local boosted_restarts=$(( ${MAX_RESTARTS_CFG:-3} + retry_count ))
                        if [[ "$boosted_restarts" -gt 5 ]]; then
                            boosted_restarts=5
                        fi
                        extra_args+=("--max-restarts" "$boosted_restarts")
                        daemon_log INFO "Boosting max-restarts to $boosted_restarts (context exhaustion)"
                    fi

                    # Exponential backoff (per-class base); cap at 1h
                    local base_secs=30
                    [[ "$failure_class" == "api_error" ]] && base_secs=300
                    local backoff_secs=$((base_secs * (1 << (retry_count - 1))))
                    [[ "$backoff_secs" -gt 3600 ]] && backoff_secs=3600
                    [[ "$failure_class" == "api_error" ]] && daemon_log INFO "API error — exponential backoff ${backoff_secs}s"

                    if [[ "$NO_GITHUB" != "true" ]]; then
                        gh issue comment "$issue_num" --body "## 🔄 Auto-Retry #${retry_count}

Pipeline failed (${failure_class}) — retrying with escalated strategy.

| Field | Value |
|-------|-------|
| Retry | ${retry_count} / ${MAX_RETRIES:-2} |
| Failure | \`${failure_class}\` |
| Template | \`${retry_template}\` |
| Model | \`${retry_model}\` |
| Started | $(now_iso) |

_Escalation: $(if [[ "$retry_count" -eq 1 ]]; then echo "upgraded model + increased iterations"; else echo "full template + compound quality"; fi)_" 2>/dev/null || true
                    fi

                    daemon_log INFO "Waiting ${backoff_secs}s before retry #${retry_count}"
                    sleep "$backoff_secs"

                    # Merge checkpoint args + extra args for passthrough
                    local all_extra_args=()
                    if [[ ${#checkpoint_args[@]} -gt 0 ]]; then
                        all_extra_args+=("${checkpoint_args[@]}")
                    fi
                    if [[ ${#extra_args[@]} -gt 0 ]]; then
                        all_extra_args+=("${extra_args[@]}")
                    fi

                    # Re-spawn with escalated strategy
                    local orig_template="$PIPELINE_TEMPLATE"
                    local orig_model="$MODEL"
                    PIPELINE_TEMPLATE="$retry_template"
                    MODEL="$retry_model"
                    daemon_spawn_pipeline "$issue_num" "retry-${retry_count}" "" "${all_extra_args[@]}"
                    _retry_spawned_for="$issue_num"
                    PIPELINE_TEMPLATE="$orig_template"
                    MODEL="$orig_model"
                    return
                fi

                daemon_log WARN "Max retries (${effective_max}) exhausted for issue #${issue_num}"
                emit_event "daemon.retry_exhausted" "issue=$issue_num" "retries=$retry_count"
                ;;
        esac
    fi

    # ── No retry — report final failure ──
    # PM agent: record failure for learning (only when we're done with this issue)
    if [[ -x "$SCRIPT_DIR/sw-pm.sh" ]]; then
        bash "$SCRIPT_DIR/sw-pm.sh" learn "$issue_num" failure 2>/dev/null || true
    fi

    if [[ "$NO_GITHUB" != "true" ]]; then
        # Add failure label and remove watch label (prevent re-processing)
        gh issue edit "$issue_num" \
            --add-label "$ON_FAILURE_ADD_LABEL" \
            --remove-label "$WATCH_LABEL" 2>/dev/null || true

        # Close any draft PR created for this issue (cleanup abandoned work)
        local draft_pr
        draft_pr=$(gh pr list --head "daemon/issue-${issue_num}" --head "pipeline/pipeline-issue-${issue_num}" \
            --json number,isDraft --jq '.[] | select(.isDraft == true) | .number' 2>/dev/null | head -1 || true)
        if [[ -n "$draft_pr" ]]; then
            gh pr close "$draft_pr" --delete-branch 2>/dev/null || true
            daemon_log INFO "Closed draft PR #${draft_pr} for failed issue #${issue_num}"
        fi

        # Comment with log tail
        local log_tail=""
        local log_path="$LOG_DIR/issue-${issue_num}.log"
        if [[ -f "$log_path" ]]; then
            log_tail=$(tail -"$ON_FAILURE_LOG_LINES" "$log_path" 2>/dev/null || true)
        fi

        local retry_info=""
        if [[ "${RETRY_ESCALATION:-true}" == "true" ]]; then
            local final_count final_max
            final_count=$(jq -r --arg num "$issue_num" \
                '.retry_counts[$num] // 0' "$STATE_FILE" 2>/dev/null || echo "0")
            final_max=$(get_max_retries_for_class "$failure_class")
            retry_info="| Retries | ${final_count} / ${final_max} (exhausted) |"
        fi

        gh issue comment "$issue_num" --body "## ❌ Pipeline Failed

The autonomous pipeline encountered an error.

| Field | Value |
|-------|-------|
| Exit Code | ${exit_code} |
| Duration | ${duration:-unknown} |
| Failed At | $(now_iso) |
${retry_info}

<details>
<summary>Last ${ON_FAILURE_LOG_LINES} lines of log</summary>

\`\`\`
${log_tail}
\`\`\`

</details>

_Re-add the \`${WATCH_LABEL}\` label to retry._" 2>/dev/null || true
    fi

    notify "Pipeline Failed — Issue #${issue_num}" \
        "Exit code: ${exit_code}, Duration: ${duration:-unknown}" "error"
    "$SCRIPT_DIR/sw-tracker.sh" notify "failed" "$issue_num" "Exit code: ${exit_code}, Duration: ${duration:-unknown}" 2>/dev/null || true
}

# ─── Intelligent Triage ──────────────────────────────────────────────────────

# Score an issue from 0-100 based on multiple signals for intelligent prioritization.
# Combines priority labels, age, complexity, dependencies, type, and memory signals.
# When intelligence engine is enabled, uses semantic AI analysis for richer scoring.
triage_score_issue() {
    local issue_json="$1"
    local issue_num issue_title issue_body labels_csv created_at
    issue_num=$(echo "$issue_json" | jq -r '.number')
    issue_title=$(echo "$issue_json" | jq -r '.title // ""')
    issue_body=$(echo "$issue_json" | jq -r '.body // ""')

    # ── Intelligence-powered triage (if enabled) ──
    if [[ "${INTELLIGENCE_ENABLED:-false}" == "true" ]] && type intelligence_analyze_issue &>/dev/null 2>&1; then
        daemon_log INFO "Intelligence: using AI triage (intelligence enabled)" >&2
        local analysis
        analysis=$(intelligence_analyze_issue "$issue_json" 2>/dev/null || echo "")
        if [[ -n "$analysis" && "$analysis" != "{}" && "$analysis" != "null" ]]; then
            # Extract complexity (1-10) and convert to score (0-100)
            local ai_complexity ai_risk ai_success_prob
            ai_complexity=$(echo "$analysis" | jq -r '.complexity // 0' 2>/dev/null || echo "0")
            ai_risk=$(echo "$analysis" | jq -r '.risk_level // "medium"' 2>/dev/null || echo "medium")
            ai_success_prob=$(echo "$analysis" | jq -r '.success_probability // 50' 2>/dev/null || echo "50")

            # Store analysis for downstream use (composer, predictions)
            export INTELLIGENCE_ANALYSIS="$analysis"
            export INTELLIGENCE_COMPLEXITY="$ai_complexity"

            # Convert AI analysis to triage score:
            # Higher success probability + lower complexity = higher score (process sooner)
            local ai_score
            ai_score=$(( ai_success_prob - (ai_complexity * 3) ))
            # Risk adjustment
            case "$ai_risk" in
                critical) ai_score=$((ai_score + 15)) ;;  # Critical = process urgently
                high)     ai_score=$((ai_score + 10)) ;;
                low)      ai_score=$((ai_score - 5)) ;;
            esac
            # Clamp
            [[ "$ai_score" -lt 0 ]] && ai_score=0
            [[ "$ai_score" -gt 100 ]] && ai_score=100

            emit_event "intelligence.triage" \
                "issue=$issue_num" \
                "complexity=$ai_complexity" \
                "risk=$ai_risk" \
                "success_prob=$ai_success_prob" \
                "score=$ai_score"

            echo "$ai_score"
            return
        fi
        # Fall through to heuristic scoring if intelligence call failed
        daemon_log INFO "Intelligence: AI triage failed, falling back to heuristic scoring" >&2
    else
        daemon_log INFO "Intelligence: using heuristic triage (intelligence disabled, enable with intelligence.enabled=true)" >&2
    fi
    labels_csv=$(echo "$issue_json" | jq -r '[.labels[].name] | join(",")')
    created_at=$(echo "$issue_json" | jq -r '.createdAt // ""')

    local score=0

    # ── 1. Priority labels (0-30 points) ──
    local priority_score=0
    if echo "$labels_csv" | grep -qiE "urgent|p0"; then
        priority_score=30
    elif echo "$labels_csv" | grep -qiE "^high$|^high,|,high,|,high$|p1"; then
        priority_score=20
    elif echo "$labels_csv" | grep -qiE "normal|p2"; then
        priority_score=10
    elif echo "$labels_csv" | grep -qiE "^low$|^low,|,low,|,low$|p3"; then
        priority_score=5
    fi

    # ── 2. Issue age (0-15 points) — older issues boosted to prevent starvation ──
    local age_score=0
    if [[ -n "$created_at" ]]; then
        local created_epoch now_e age_secs
        created_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || \
                       date -d "$created_at" +%s 2>/dev/null || echo "0")
        now_e=$(now_epoch)
        if [[ "$created_epoch" -gt 0 ]]; then
            age_secs=$((now_e - created_epoch))
            if [[ "$age_secs" -gt 604800 ]]; then    # > 7 days
                age_score=15
            elif [[ "$age_secs" -gt 259200 ]]; then   # > 3 days
                age_score=10
            elif [[ "$age_secs" -gt 86400 ]]; then    # > 1 day
                age_score=5
            fi
        fi
    fi

    # ── 3. Complexity estimate (0-20 points, INVERTED — simpler = higher) ──
    local complexity_score=0
    local body_len=${#issue_body}
    local file_refs
    file_refs=$(echo "$issue_body" | grep -coE '[a-zA-Z0-9_/-]+\.(ts|js|py|go|rs|sh|json|yaml|yml|md)' || true)
    file_refs=${file_refs:-0}

    if [[ "$body_len" -lt 200 ]] && [[ "$file_refs" -lt 3 ]]; then
        complexity_score=20   # Short + few files = likely simple
    elif [[ "$body_len" -lt 1000 ]]; then
        complexity_score=10   # Medium
    elif [[ "$file_refs" -lt 5 ]]; then
        complexity_score=5    # Long but not many files
    fi
    # Long + many files = complex = 0 points (lower throughput)

    # ── 4. Dependencies (0-15 points / -15 for blocked) ──
    local dep_score=0
    local combined_text="${issue_title} ${issue_body}"

    # Check if this issue is blocked
    local blocked_refs
    blocked_refs=$(echo "$combined_text" | grep -oE '(blocked by|depends on) #[0-9]+' | grep -oE '#[0-9]+' || true)
    if [[ -n "$blocked_refs" ]] && [[ "$NO_GITHUB" != "true" ]]; then
        local all_closed=true
        while IFS= read -r ref; do
            local ref_num="${ref#\#}"
            local ref_state
            ref_state=$(gh issue view "$ref_num" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
            if [[ "$ref_state" != "CLOSED" ]]; then
                all_closed=false
                break
            fi
        done <<< "$blocked_refs"
        if [[ "$all_closed" == "false" ]]; then
            dep_score=-15
        fi
    fi

    # Check if this issue blocks others (search issue references)
    if [[ "$NO_GITHUB" != "true" ]]; then
        local mentions
        mentions=$(gh api "repos/{owner}/{repo}/issues/${issue_num}/timeline" --paginate -q '
            [.[] | select(.event == "cross-referenced") | .source.issue.body // ""] |
            map(select(test("blocked by #'"${issue_num}"'|depends on #'"${issue_num}"'"; "i"))) | length
        ' 2>/dev/null || echo "0")
        mentions=${mentions:-0}
        if [[ "$mentions" -gt 0 ]]; then
            dep_score=15
        fi
    fi

    # ── 5. Type bonus (0-10 points) ──
    local type_score=0
    if echo "$labels_csv" | grep -qiE "security"; then
        type_score=10
    elif echo "$labels_csv" | grep -qiE "bug"; then
        type_score=10
    elif echo "$labels_csv" | grep -qiE "feature|enhancement"; then
        type_score=5
    fi

    # ── 6. Memory bonus (0-10 points / -5 for prior failures) ──
    local memory_score=0
    if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        local memory_result
        memory_result=$("$SCRIPT_DIR/sw-memory.sh" search --issue "$issue_num" --json 2>/dev/null || true)
        if [[ -n "$memory_result" ]]; then
            local prior_result
            prior_result=$(echo "$memory_result" | jq -r '.last_result // ""' 2>/dev/null || true)
            if [[ "$prior_result" == "success" ]]; then
                memory_score=10
            elif [[ "$prior_result" == "failure" ]]; then
                memory_score=-5
            fi
        fi
    fi

    # ── Total ──
    score=$((priority_score + age_score + complexity_score + dep_score + type_score + memory_score))
    # Clamp to 0-100
    [[ "$score" -lt 0 ]] && score=0
    [[ "$score" -gt 100 ]] && score=100

    emit_event "daemon.triage" \
        "issue=$issue_num" \
        "score=$score" \
        "priority=$priority_score" \
        "age=$age_score" \
        "complexity=$complexity_score" \
        "dependency=$dep_score" \
        "type=$type_score" \
        "memory=$memory_score"

    echo "$score"
}

# Auto-select pipeline template based on issue labels
# When intelligence/composer is enabled, composes a custom pipeline instead of static selection.
select_pipeline_template() {
    local labels="$1"
    local score="${2:-50}"
    local _selected_template=""

    # When auto_template is disabled, use default pipeline template
    if [[ "${AUTO_TEMPLATE:-false}" != "true" ]]; then
        echo "$PIPELINE_TEMPLATE"
        return
    fi

    # ── Intelligence-composed pipeline (if enabled) ──
    if [[ "${COMPOSER_ENABLED:-false}" == "true" ]] && type composer_create_pipeline &>/dev/null 2>&1; then
        daemon_log INFO "Intelligence: using AI pipeline composition (composer enabled)" >&2
        local analysis="${INTELLIGENCE_ANALYSIS:-{}}"
        local repo_context=""
        if [[ -f "${REPO_DIR:-}/.claude/pipeline-state.md" ]]; then
            repo_context="has_pipeline_state"
        fi
        local budget_json="{}"
        if [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
            local remaining
            remaining=$(bash "$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
            if [[ -n "$remaining" ]]; then
                budget_json="{\"remaining_usd\": $remaining}"
            fi
        fi
        local composed_path
        composed_path=$(composer_create_pipeline "$analysis" "$repo_context" "$budget_json" 2>/dev/null || echo "")
        if [[ -n "$composed_path" && -f "$composed_path" ]]; then
            emit_event "daemon.composed_pipeline" "labels=$labels" "score=$score"
            echo "composed"
            return
        fi
        # Fall through to static selection if composition failed
        daemon_log INFO "Intelligence: AI pipeline composition failed, falling back to static template selection" >&2
    else
        daemon_log INFO "Intelligence: using static template selection (composer disabled, enable with intelligence.composer_enabled=true)" >&2
    fi

    # ── DORA-driven template escalation ──
    if [[ -f "${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}" ]]; then
        local _dora_events _dora_total _dora_failures _dora_cfr
        _dora_events=$(tail -500 "${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}" \
            | grep '"type":"pipeline.completed"' 2>/dev/null \
            | tail -5 || true)
        _dora_total=$(echo "$_dora_events" | grep -c '.' 2>/dev/null || echo "0")
        _dora_total="${_dora_total:-0}"
        if [[ "$_dora_total" -ge 3 ]]; then
            _dora_failures=$(echo "$_dora_events" | grep -c '"result":"failure"' 2>/dev/null || true)
            _dora_failures="${_dora_failures:-0}"
            _dora_cfr=$(( _dora_failures * 100 / _dora_total ))
            if [[ "$_dora_cfr" -gt 40 ]]; then
                daemon_log INFO "DORA escalation: CFR ${_dora_cfr}% > 40% — forcing enterprise template" >&2
                emit_event "daemon.dora_escalation" \
                    "cfr=$_dora_cfr" \
                    "total=$_dora_total" \
                    "failures=$_dora_failures" \
                    "template=enterprise"
                echo "enterprise"
                return
            fi
            if [[ "$_dora_cfr" -lt 10 && "$score" -ge 60 ]]; then
                daemon_log INFO "DORA: CFR ${_dora_cfr}% < 10% — fast template eligible" >&2
                # Fall through to allow other factors to also vote for fast
            fi

            # ── DORA multi-factor ──
            # Cycle time: if median > 120min, prefer faster templates
            local _dora_cycle_time=0
            _dora_cycle_time=$(echo "$_dora_events" | jq -r 'select(.duration_s) | .duration_s' 2>/dev/null \
                | sort -n | awk '{ a[NR]=$1 } END { if (NR>0) print int(a[int(NR/2)+1]/60); else print 0 }' 2>/dev/null) || _dora_cycle_time=0
            _dora_cycle_time="${_dora_cycle_time:-0}"
            if [[ "${_dora_cycle_time:-0}" -gt 120 ]]; then
                daemon_log INFO "DORA: cycle time ${_dora_cycle_time}min > 120 — preferring fast template" >&2
                if [[ "${score:-0}" -ge 60 ]]; then
                    echo "fast"
                    return
                fi
            fi

            # Deploy frequency: if < 1/week, use cost-aware
            local _dora_deploy_freq=0
            local _dora_first_epoch _dora_last_epoch _dora_span_days
            _dora_first_epoch=$(echo "$_dora_events" | head -1 | jq -r '.timestamp // empty' 2>/dev/null | xargs -I{} date -j -f "%Y-%m-%dT%H:%M:%SZ" {} +%s 2>/dev/null || echo "0")
            _dora_last_epoch=$(echo "$_dora_events" | tail -1 | jq -r '.timestamp // empty' 2>/dev/null | xargs -I{} date -j -f "%Y-%m-%dT%H:%M:%SZ" {} +%s 2>/dev/null || echo "0")
            if [[ "${_dora_first_epoch:-0}" -gt 0 && "${_dora_last_epoch:-0}" -gt 0 ]]; then
                _dora_span_days=$(( (_dora_last_epoch - _dora_first_epoch) / 86400 ))
                if [[ "${_dora_span_days:-0}" -gt 0 ]]; then
                    _dora_deploy_freq=$(awk -v t="$_dora_total" -v d="$_dora_span_days" 'BEGIN { printf "%.1f", t * 7 / d }' 2>/dev/null) || _dora_deploy_freq=0
                fi
            fi
            if [[ -n "${_dora_deploy_freq:-}" ]] && awk -v f="${_dora_deploy_freq:-0}" 'BEGIN{exit !(f > 0 && f < 1)}' 2>/dev/null; then
                daemon_log INFO "DORA: deploy freq ${_dora_deploy_freq}/week — using cost-aware" >&2
                echo "cost-aware"
                return
            fi
        fi
    fi

    # ── Branch protection escalation (highest priority) ──
    if type gh_branch_protection &>/dev/null 2>&1 && [[ "${NO_GITHUB:-false}" != "true" ]]; then
        if type _gh_detect_repo &>/dev/null 2>&1; then
            _gh_detect_repo 2>/dev/null || true
        fi
        local gh_owner="${GH_OWNER:-}" gh_repo="${GH_REPO:-}"
        if [[ -n "$gh_owner" && -n "$gh_repo" ]]; then
            local protection
            protection=$(gh_branch_protection "$gh_owner" "$gh_repo" "${BASE_BRANCH:-main}" 2>/dev/null || echo '{"protected": false}')
            local strict_protection
            strict_protection=$(echo "$protection" | jq -r '.enforce_admins.enabled // false' 2>/dev/null || echo "false")
            local required_reviews
            required_reviews=$(echo "$protection" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null || echo "0")
            if [[ "$strict_protection" == "true" ]] || [[ "${required_reviews:-0}" -gt 1 ]]; then
                daemon_log INFO "Branch has strict protection — escalating to enterprise template" >&2
                echo "enterprise"
                return
            fi
        fi
    fi

    # ── Label-based overrides ──
    if echo "$labels" | grep -qi "hotfix\|incident"; then
        echo "hotfix"
        return
    fi
    if echo "$labels" | grep -qi "security"; then
        echo "enterprise"
        return
    fi

    # ── Config-driven template_map overrides ──
    local map="${TEMPLATE_MAP:-\"{}\"}"
    # Unwrap double-encoded JSON if needed
    local decoded_map
    decoded_map=$(echo "$map" | jq -r 'if type == "string" then . else tostring end' 2>/dev/null || echo "{}")
    if [[ "$decoded_map" != "{}" ]]; then
        local matched
        matched=$(echo "$decoded_map" | jq -r --arg labels "$labels" '
            to_entries[] |
            select($labels | test(.key; "i")) |
            .value' 2>/dev/null | head -1)
        if [[ -n "$matched" ]]; then
            echo "$matched"
            return
        fi
    fi

    # ── Quality memory-driven selection ──
    local quality_scores_file="${HOME}/.shipwright/optimization/quality-scores.jsonl"
    if [[ -f "$quality_scores_file" ]]; then
        local repo_hash
        repo_hash=$(cd "${REPO_DIR:-.}" && git rev-parse --show-toplevel 2>/dev/null | shasum -a 256 | cut -c1-16 || echo "unknown")
        # Get last 5 quality scores for this repo
        local recent_scores avg_quality has_critical
        recent_scores=$(grep "\"repo\":\"$repo_hash\"" "$quality_scores_file" 2>/dev/null | tail -5 || true)
        if [[ -n "$recent_scores" ]]; then
            avg_quality=$(echo "$recent_scores" | jq -r '.quality_score // 70' 2>/dev/null | awk '{ sum += $1; count++ } END { if (count > 0) printf "%.0f", sum/count; else print 70 }')
            has_critical=$(echo "$recent_scores" | jq -r '.findings.critical // 0' 2>/dev/null | awk '{ sum += $1 } END { print (sum > 0) ? "yes" : "no" }')

            # Critical findings in recent history → force enterprise
            if [[ "$has_critical" == "yes" ]]; then
                daemon_log INFO "Quality memory: critical findings in recent runs — using enterprise template" >&2
                echo "enterprise"
                return
            fi

            # Poor quality history → use full template
            if [[ "${avg_quality:-70}" -lt 60 ]]; then
                daemon_log INFO "Quality memory: avg score ${avg_quality}/100 in recent runs — using full template" >&2
                echo "full"
                return
            fi

            # Excellent quality history → allow faster template
            if [[ "${avg_quality:-70}" -gt 80 ]]; then
                daemon_log INFO "Quality memory: avg score ${avg_quality}/100 in recent runs — eligible for fast template" >&2
                # Only upgrade if score also suggests fast
                if [[ "$score" -ge 60 ]]; then
                    echo "fast"
                    return
                fi
            fi
        fi
    fi

    # ── Learned template weights ──
    local _tw_file="${HOME}/.shipwright/optimization/template-weights.json"
    if [[ -f "$_tw_file" ]]; then
        local _best_template _best_rate
        _best_template=$(jq -r '
            .weights // {} | to_entries
            | map(select(.value.sample_size >= 3))
            | sort_by(-.value.success_rate)
            | .[0].key // ""
        ' "$_tw_file" 2>/dev/null) || true
        if [[ -n "${_best_template:-}" && "${_best_template:-}" != "null" && "${_best_template:-}" != "" ]]; then
            _best_rate=$(jq -r --arg t "$_best_template" '.weights[$t].success_rate // 0' "$_tw_file" 2>/dev/null) || _best_rate=0
            daemon_log INFO "Template weights: ${_best_template} (${_best_rate} success rate)" >&2
            echo "$_best_template"
            return
        fi
    fi

    # ── Score-based selection ──
    if [[ "$score" -ge 70 ]]; then
        echo "fast"
    elif [[ "$score" -ge 40 ]]; then
        echo "standard"
    else
        echo "full"
    fi
}

# ─── Triage Display ──────────────────────────────────────────────────────────

daemon_triage_show() {
    if [[ "$NO_GITHUB" == "true" ]]; then
        error "Triage requires GitHub access (--no-github is set)"
        exit 1
    fi

    load_config

    echo -e "${PURPLE}${BOLD}━━━ Issue Triage Scores ━━━${RESET}"
    echo ""

    local issues_json
    issues_json=$(gh issue list \
        --label "$WATCH_LABEL" \
        --state open \
        --json number,title,labels,body,createdAt \
        --limit 50 2>/dev/null) || {
        error "Failed to fetch issues from GitHub"
        exit 1
    }

    local issue_count
    issue_count=$(echo "$issues_json" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$issue_count" -eq 0 ]]; then
        echo -e "  ${DIM}No open issues with label '${WATCH_LABEL}'${RESET}"
        return 0
    fi

    # Score each issue and collect results
    local scored_lines=()
    while IFS= read -r issue; do
        local num title labels_csv score template
        num=$(echo "$issue" | jq -r '.number')
        title=$(echo "$issue" | jq -r '.title // "—"')
        labels_csv=$(echo "$issue" | jq -r '[.labels[].name] | join(", ")')
        score=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
        score=$(printf '%s' "$score" | tr -cd '[:digit:]')
        [[ -z "$score" ]] && score=50
        template=$(select_pipeline_template "$labels_csv" "$score" 2>/dev/null | tail -1)
        template=$(printf '%s' "$template" | sed $'s/\x1b\\[[0-9;]*m//g' | tr -cd '[:alnum:]-_')
        [[ -z "$template" ]] && template="$PIPELINE_TEMPLATE"

        scored_lines+=("${score}|${num}|${title}|${labels_csv}|${template}")
    done < <(echo "$issues_json" | jq -c '.[]')

    # Sort by score descending
    local sorted
    sorted=$(printf '%s\n' "${scored_lines[@]}" | sort -t'|' -k1 -rn)

    # Print header
    printf "  ${BOLD}%-6s  %-7s  %-45s  %-12s  %s${RESET}\n" "Score" "Issue" "Title" "Template" "Labels"
    echo -e "  ${DIM}$(printf '%.0s─' {1..90})${RESET}"

    while IFS='|' read -r score num title labels_csv template; do
        # Color score by tier
        local score_color="$RED"
        [[ "$score" -ge 20 ]] && score_color="$YELLOW"
        [[ "$score" -ge 40 ]] && score_color="$CYAN"
        [[ "$score" -ge 60 ]] && score_color="$GREEN"

        # Truncate title
        [[ ${#title} -gt 42 ]] && title="${title:0:39}..."

        printf "  ${score_color}%-6s${RESET}  ${CYAN}#%-6s${RESET}  %-45s  ${DIM}%-12s  %s${RESET}\n" \
            "$score" "$num" "$title" "$template" "$labels_csv"
    done <<< "$sorted"

    echo ""
    echo -e "  ${DIM}${issue_count} issue(s) scored  |  Higher score = higher processing priority${RESET}"
    echo ""
}

# ─── Patrol Self-Labeling ─────────────────────────────────────────────────
patrol_build_labels() {
    local check_label="$1"
    local labels="${PATROL_LABEL},${check_label}"
    if [[ "$PATROL_AUTO_WATCH" == "true" && -n "${WATCH_LABEL:-}" ]]; then
        labels="${labels},${WATCH_LABEL}"
    fi
    echo "$labels"
}

# ─── Proactive Patrol Mode ───────────────────────────────────────────────────

daemon_patrol() {
    local once=false
    local dry_run="$PATROL_DRY_RUN"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --once)    once=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            *)         shift ;;
        esac
    done

    echo -e "${PURPLE}${BOLD}━━━ Codebase Patrol ━━━${RESET}"
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        echo -e "  ${YELLOW}DRY RUN${RESET} — findings will be reported but no issues created"
        echo ""
    fi

    emit_event "patrol.started" "dry_run=$dry_run"

    local total_findings=0
    local issues_created=0

    # ── 1. Dependency Security Audit ──
    patrol_security_audit() {
        daemon_log INFO "Patrol: running dependency security audit"
        local findings=0

        # npm audit
        if [[ -f "package.json" ]] && command -v npm &>/dev/null; then
            local audit_json
            audit_json=$(npm audit --json 2>/dev/null || true)
            if [[ -n "$audit_json" ]]; then
                while IFS= read -r vuln; do
                    local severity name advisory_url title
                    severity=$(echo "$vuln" | jq -r '.severity // "unknown"')
                    name=$(echo "$vuln" | jq -r '.name // "unknown"')
                    advisory_url=$(echo "$vuln" | jq -r '.url // ""')
                    title=$(echo "$vuln" | jq -r '.title // "vulnerability"')

                    # Only report critical/high
                    if [[ "$severity" != "critical" ]] && [[ "$severity" != "high" ]]; then
                        continue
                    fi

                    findings=$((findings + 1))
                    emit_event "patrol.finding" "check=security" "severity=$severity" "package=$name"

                    # Check if issue already exists
                    if [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
                        local existing
                        existing=$(gh issue list --label "$PATROL_LABEL" --label "security" \
                            --search "Security: $name" --json number -q 'length' 2>/dev/null || echo "0")
                        if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                            gh issue create \
                                --title "Security: ${title} in ${name}" \
                                --body "## Dependency Security Finding

| Field | Value |
|-------|-------|
| Package | \`${name}\` |
| Severity | **${severity}** |
| Advisory | ${advisory_url} |
| Found by | Shipwright patrol |
| Date | $(now_iso) |

Auto-detected by \`shipwright daemon patrol\`." \
                                --label "$(patrol_build_labels "security")" 2>/dev/null || true
                            issues_created=$((issues_created + 1))
                            emit_event "patrol.issue_created" "check=security" "package=$name"
                        fi
                    else
                        echo -e "    ${RED}●${RESET} ${BOLD}${severity}${RESET}: ${title} in ${CYAN}${name}${RESET}"
                    fi
                done < <(echo "$audit_json" | jq -c '.vulnerabilities | to_entries[] | .value' 2>/dev/null)
            fi
        fi

        # pip-audit
        if [[ -f "requirements.txt" ]] && command -v pip-audit &>/dev/null; then
            local pip_json
            pip_json=$(pip-audit --format=json 2>/dev/null || true)
            if [[ -n "$pip_json" ]]; then
                local vuln_count
                vuln_count=$(echo "$pip_json" | jq '[.dependencies[] | select(.vulns | length > 0)] | length' 2>/dev/null || echo "0")
                findings=$((findings + ${vuln_count:-0}))
            fi
        fi

        # cargo audit
        if [[ -f "Cargo.toml" ]] && command -v cargo-audit &>/dev/null; then
            local cargo_json
            cargo_json=$(cargo audit --json 2>/dev/null || true)
            if [[ -n "$cargo_json" ]]; then
                local vuln_count
                vuln_count=$(echo "$cargo_json" | jq '.vulnerabilities.found' 2>/dev/null || echo "0")
                findings=$((findings + ${vuln_count:-0}))
            fi
        fi

        # Enrich with GitHub security alerts
        if type gh_security_alerts &>/dev/null 2>&1 && [[ "${NO_GITHUB:-false}" != "true" ]]; then
            if type _gh_detect_repo &>/dev/null 2>&1; then
                _gh_detect_repo 2>/dev/null || true
            fi
            local gh_owner="${GH_OWNER:-}" gh_repo="${GH_REPO:-}"
            if [[ -n "$gh_owner" && -n "$gh_repo" ]]; then
                local gh_alerts
                gh_alerts=$(gh_security_alerts "$gh_owner" "$gh_repo" 2>/dev/null || echo "[]")
                local gh_alert_count
                gh_alert_count=$(echo "$gh_alerts" | jq 'length' 2>/dev/null || echo "0")
                if [[ "${gh_alert_count:-0}" -gt 0 ]]; then
                    daemon_log WARN "Patrol: $gh_alert_count GitHub security alert(s) found"
                    findings=$((findings + gh_alert_count))
                fi
            fi
        fi

        # Enrich with GitHub Dependabot alerts
        if type gh_dependabot_alerts &>/dev/null 2>&1 && [[ "${NO_GITHUB:-false}" != "true" ]]; then
            local gh_owner="${GH_OWNER:-}" gh_repo="${GH_REPO:-}"
            if [[ -n "$gh_owner" && -n "$gh_repo" ]]; then
                local dep_alerts
                dep_alerts=$(gh_dependabot_alerts "$gh_owner" "$gh_repo" 2>/dev/null || echo "[]")
                local dep_alert_count
                dep_alert_count=$(echo "$dep_alerts" | jq 'length' 2>/dev/null || echo "0")
                if [[ "${dep_alert_count:-0}" -gt 0 ]]; then
                    daemon_log WARN "Patrol: $dep_alert_count Dependabot alert(s) found"
                    findings=$((findings + dep_alert_count))
                fi
            fi
        fi

        total_findings=$((total_findings + findings))
        if [[ "$findings" -gt 0 ]]; then
            daemon_log INFO "Patrol: found ${findings} security vulnerability(ies)"
        else
            daemon_log INFO "Patrol: no security vulnerabilities found"
        fi
    }

    # ── 2. Stale Dependency Check ──
    patrol_stale_dependencies() {
        daemon_log INFO "Patrol: checking for stale dependencies"
        local findings=0

        if [[ -f "package.json" ]] && command -v npm &>/dev/null; then
            local outdated_json
            outdated_json=$(npm outdated --json 2>/dev/null || true)
            if [[ -n "$outdated_json" ]] && [[ "$outdated_json" != "{}" ]]; then
                local stale_packages=""
                while IFS= read -r pkg; do
                    local name current latest current_major latest_major
                    name=$(echo "$pkg" | jq -r '.key')
                    current=$(echo "$pkg" | jq -r '.value.current // "0.0.0"')
                    latest=$(echo "$pkg" | jq -r '.value.latest // "0.0.0"')
                    current_major="${current%%.*}"
                    latest_major="${latest%%.*}"

                    # Only flag if > 2 major versions behind
                    if [[ "$latest_major" =~ ^[0-9]+$ ]] && [[ "$current_major" =~ ^[0-9]+$ ]]; then
                        local diff=$((latest_major - current_major))
                        if [[ "$diff" -ge 2 ]]; then
                            findings=$((findings + 1))
                            stale_packages="${stale_packages}\n- \`${name}\`: ${current} → ${latest} (${diff} major versions behind)"
                            emit_event "patrol.finding" "check=stale_dependency" "package=$name" "current=$current" "latest=$latest"

                            if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                                echo -e "    ${YELLOW}●${RESET} ${CYAN}${name}${RESET}: ${current} → ${latest} (${diff} major versions behind)"
                            fi
                        fi
                    fi
                done < <(echo "$outdated_json" | jq -c 'to_entries[]' 2>/dev/null)

                # Create a single issue for all stale deps
                if [[ "$findings" -gt 0 ]] && [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
                    local existing
                    existing=$(gh issue list --label "$PATROL_LABEL" --label "dependencies" \
                        --search "Stale dependencies" --json number -q 'length' 2>/dev/null || echo "0")
                    if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                        gh issue create \
                            --title "Update ${findings} stale dependencies" \
                            --body "## Stale Dependencies

The following packages are 2+ major versions behind:
$(echo -e "$stale_packages")

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                            --label "$(patrol_build_labels "dependencies")" 2>/dev/null || true
                        issues_created=$((issues_created + 1))
                        emit_event "patrol.issue_created" "check=stale_dependency" "count=$findings"
                    fi
                fi
            fi
        fi

        total_findings=$((total_findings + findings))
        daemon_log INFO "Patrol: found ${findings} stale dependency(ies)"
    }

    # ── 3. Dead Code Detection ──
    patrol_dead_code() {
        daemon_log INFO "Patrol: scanning for dead code"
        local findings=0
        local dead_files=""

        # For JS/TS projects: find exported files not imported anywhere
        if [[ -f "package.json" ]] || [[ -f "tsconfig.json" ]]; then
            local src_dirs=("src" "lib" "app")
            for dir in "${src_dirs[@]}"; do
                [[ -d "$dir" ]] || continue
                while IFS= read -r file; do
                    local basename_no_ext
                    basename_no_ext=$(basename "$file" | sed 's/\.\(ts\|js\|tsx\|jsx\)$//')
                    # Skip index files and test files
                    [[ "$basename_no_ext" == "index" ]] && continue
                    [[ "$basename_no_ext" =~ \.(test|spec)$ ]] && continue

                    # Check if this file is imported anywhere
                    local import_count
                    import_count=$(grep -rlE "(from|require).*['\"].*${basename_no_ext}['\"]" \
                        --include="*.ts" --include="*.js" --include="*.tsx" --include="*.jsx" \
                        . 2>/dev/null | grep -cv "$file" || true)
                    import_count=${import_count:-0}

                    if [[ "$import_count" -eq 0 ]]; then
                        findings=$((findings + 1))
                        dead_files="${dead_files}\n- \`${file}\`"
                        if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                            echo -e "    ${DIM}●${RESET} ${file} ${DIM}(not imported)${RESET}"
                        fi
                    fi
                done < <(find "$dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.tsx" -o -name "*.jsx" \) \
                    ! -name "*.test.*" ! -name "*.spec.*" ! -name "*.d.ts" 2>/dev/null)
            done
        fi

        if [[ "$findings" -gt 0 ]] && [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
            local existing
            existing=$(gh issue list --label "$PATROL_LABEL" --label "tech-debt" \
                --search "Dead code candidates" --json number -q 'length' 2>/dev/null || echo "0")
            if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                gh issue create \
                    --title "Dead code candidates (${findings} files)" \
                    --body "## Dead Code Detection

These files appear to have no importers — they may be unused:
$(echo -e "$dead_files")

> **Note:** Some files may be entry points or dynamically loaded. Verify before removing.

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                    --label "$(patrol_build_labels "tech-debt")" 2>/dev/null || true
                issues_created=$((issues_created + 1))
                emit_event "patrol.issue_created" "check=dead_code" "count=$findings"
            fi
        fi

        total_findings=$((total_findings + findings))
        daemon_log INFO "Patrol: found ${findings} dead code candidate(s)"
    }

    # ── 4. Test Coverage Gaps ──
    patrol_coverage_gaps() {
        daemon_log INFO "Patrol: checking test coverage gaps"
        local findings=0
        local low_cov_files=""

        # Look for coverage reports from last pipeline run
        local coverage_file=""
        for candidate in \
            ".claude/pipeline-artifacts/coverage/coverage-summary.json" \
            "coverage/coverage-summary.json" \
            ".coverage/coverage-summary.json"; do
            if [[ -f "$candidate" ]]; then
                coverage_file="$candidate"
                break
            fi
        done

        if [[ -z "$coverage_file" ]]; then
            daemon_log INFO "Patrol: no coverage report found — skipping"
            return
        fi

        while IFS= read -r entry; do
            local file_path line_pct
            file_path=$(echo "$entry" | jq -r '.key')
            line_pct=$(echo "$entry" | jq -r '.value.lines.pct // 100')

            # Skip total and well-covered files
            [[ "$file_path" == "total" ]] && continue
            if awk "BEGIN{exit !($line_pct >= 50)}" 2>/dev/null; then continue; fi

            findings=$((findings + 1))
            low_cov_files="${low_cov_files}\n- \`${file_path}\`: ${line_pct}% line coverage"

            if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                echo -e "    ${YELLOW}●${RESET} ${file_path}: ${line_pct}% coverage"
            fi
        done < <(jq -c 'to_entries[]' "$coverage_file" 2>/dev/null)

        if [[ "$findings" -gt 0 ]] && [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
            local existing
            existing=$(gh issue list --label "$PATROL_LABEL" --label "testing" \
                --search "Test coverage gaps" --json number -q 'length' 2>/dev/null || echo "0")
            if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                gh issue create \
                    --title "Improve test coverage for ${findings} file(s)" \
                    --body "## Test Coverage Gaps

These files have < 50% line coverage:
$(echo -e "$low_cov_files")

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                    --label "$(patrol_build_labels "testing")" 2>/dev/null || true
                issues_created=$((issues_created + 1))
                emit_event "patrol.issue_created" "check=coverage" "count=$findings"
            fi
        fi

        total_findings=$((total_findings + findings))
        daemon_log INFO "Patrol: found ${findings} low-coverage file(s)"
    }

    # ── 5. Documentation Staleness ──
    patrol_doc_staleness() {
        daemon_log INFO "Patrol: checking documentation staleness"
        local findings=0
        local stale_docs=""

        # Check if README is older than recent source changes
        if [[ -f "README.md" ]]; then
            local readme_epoch src_epoch
            readme_epoch=$(git log -1 --format=%ct -- README.md 2>/dev/null || echo "0")
            src_epoch=$(git log -1 --format=%ct -- "*.ts" "*.js" "*.py" "*.go" "*.rs" "*.sh" 2>/dev/null || echo "0")

            if [[ "$src_epoch" -gt 0 ]] && [[ "$readme_epoch" -gt 0 ]]; then
                local drift=$((src_epoch - readme_epoch))
                # Flag if README is > 30 days behind source
                if [[ "$drift" -gt 2592000 ]]; then
                    findings=$((findings + 1))
                    local days_behind=$((drift / 86400))
                    stale_docs="${stale_docs}\n- \`README.md\`: ${days_behind} days behind source code"
                    if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                        echo -e "    ${YELLOW}●${RESET} README.md is ${days_behind} days behind source code"
                    fi
                fi
            fi
        fi

        # Check if CHANGELOG is behind latest tag
        if [[ -f "CHANGELOG.md" ]]; then
            local latest_tag changelog_epoch tag_epoch
            latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
            if [[ -n "$latest_tag" ]]; then
                changelog_epoch=$(git log -1 --format=%ct -- CHANGELOG.md 2>/dev/null || echo "0")
                tag_epoch=$(git log -1 --format=%ct "$latest_tag" 2>/dev/null || echo "0")
                if [[ "$tag_epoch" -gt "$changelog_epoch" ]] && [[ "$changelog_epoch" -gt 0 ]]; then
                    findings=$((findings + 1))
                    stale_docs="${stale_docs}\n- \`CHANGELOG.md\`: not updated since tag \`${latest_tag}\`"
                    if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                        echo -e "    ${YELLOW}●${RESET} CHANGELOG.md not updated since ${latest_tag}"
                    fi
                fi
            fi
        fi

        # Check CLAUDE.md staleness (same pattern as README)
        if [[ -f ".claude/CLAUDE.md" ]]; then
            local claudemd_epoch claudemd_src_epoch
            claudemd_src_epoch=$(git log -1 --format=%ct -- "*.ts" "*.js" "*.py" "*.go" "*.rs" "*.sh" 2>/dev/null || echo "0")
            claudemd_epoch=$(git log -1 --format=%ct -- ".claude/CLAUDE.md" 2>/dev/null || echo "0")
            if [[ "$claudemd_src_epoch" -gt 0 ]] && [[ "$claudemd_epoch" -gt 0 ]]; then
                local claude_drift=$((claudemd_src_epoch - claudemd_epoch))
                if [[ "$claude_drift" -gt 2592000 ]]; then
                    findings=$((findings + 1))
                    local claude_days_behind=$((claude_drift / 86400))
                    stale_docs="${stale_docs}\n- \`.claude/CLAUDE.md\`: ${claude_days_behind} days behind source code"
                    if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                        echo -e "    ${YELLOW}●${RESET} CLAUDE.md is ${claude_days_behind} days behind source code"
                    fi
                fi
            fi
        fi

        # Check AUTO section freshness (if sw-docs.sh available)
        if [[ -x "$SCRIPT_DIR/sw-docs.sh" ]]; then
            local docs_stale=false
            bash "$SCRIPT_DIR/sw-docs.sh" check >/dev/null 2>&1 || docs_stale=true
            if [[ "$docs_stale" == "true" ]]; then
                findings=$((findings + 1))
                stale_docs="${stale_docs}\n- AUTO sections: some documentation sections are stale"
                if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                    echo -e "    ${YELLOW}●${RESET} AUTO documentation sections are stale"
                fi
                # Auto-sync if not dry run
                if [[ "$dry_run" != "true" ]] && [[ "$NO_GITHUB" != "true" ]]; then
                    daemon_log INFO "Auto-syncing stale documentation sections"
                    bash "$SCRIPT_DIR/sw-docs.sh" sync 2>/dev/null || true
                    if ! git diff --quiet -- '*.md' 2>/dev/null; then
                        git add -A '*.md' 2>/dev/null || true
                        git commit -m "docs: auto-sync stale documentation sections" 2>/dev/null || true
                    fi
                fi
            fi
        fi

        if [[ "$findings" -gt 0 ]] && [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
            local existing
            existing=$(gh issue list --label "$PATROL_LABEL" --label "documentation" \
                --search "Stale documentation" --json number -q 'length' 2>/dev/null || echo "0")
            if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                gh issue create \
                    --title "Stale documentation detected" \
                    --body "## Documentation Staleness

The following docs may need updating:
$(echo -e "$stale_docs")

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                    --label "$(patrol_build_labels "documentation")" 2>/dev/null || true
                issues_created=$((issues_created + 1))
                emit_event "patrol.issue_created" "check=documentation" "count=$findings"
            fi
        fi

        total_findings=$((total_findings + findings))
        daemon_log INFO "Patrol: found ${findings} stale documentation item(s)"
    }

    # ── 6. Performance Baseline ──
    patrol_performance_baseline() {
        daemon_log INFO "Patrol: checking performance baseline"

        # Look for test timing in recent pipeline events
        if [[ ! -f "$EVENTS_FILE" ]]; then
            daemon_log INFO "Patrol: no events file — skipping performance check"
            return
        fi

        local baseline_file="$DAEMON_DIR/patrol-perf-baseline.json"
        local recent_test_dur
        recent_test_dur=$(tail -500 "$EVENTS_FILE" | \
            jq -s '[.[] | select(.type == "stage.completed" and .stage == "test") | .duration_s] | if length > 0 then .[-1] else null end' \
            2>/dev/null || echo "null")

        if [[ "$recent_test_dur" == "null" ]] || [[ -z "$recent_test_dur" ]]; then
            daemon_log INFO "Patrol: no recent test duration found — skipping"
            return
        fi

        if [[ -f "$baseline_file" ]]; then
            local baseline_dur
            baseline_dur=$(jq -r '.test_duration_s // 0' "$baseline_file" 2>/dev/null || echo "0")
            if [[ "$baseline_dur" -gt 0 ]]; then
                local threshold=$(( baseline_dur * 130 / 100 ))  # 30% slower
                if [[ "$recent_test_dur" -gt "$threshold" ]]; then
                    total_findings=$((total_findings + 1))
                    local pct_slower=$(( (recent_test_dur - baseline_dur) * 100 / baseline_dur ))
                    emit_event "patrol.finding" "check=performance" "baseline=${baseline_dur}s" "current=${recent_test_dur}s" "regression=${pct_slower}%"

                    if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                        echo -e "    ${RED}●${RESET} Test suite ${pct_slower}% slower than baseline (${baseline_dur}s → ${recent_test_dur}s)"
                    elif [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                        local existing
                        existing=$(gh issue list --label "$PATROL_LABEL" --label "performance" \
                            --search "Test suite performance regression" --json number -q 'length' 2>/dev/null || echo "0")
                        if [[ "${existing:-0}" -eq 0 ]]; then
                            gh issue create \
                                --title "Test suite performance regression (${pct_slower}% slower)" \
                                --body "## Performance Regression

| Metric | Value |
|--------|-------|
| Baseline | ${baseline_dur}s |
| Current | ${recent_test_dur}s |
| Regression | ${pct_slower}% |

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                                --label "$(patrol_build_labels "performance")" 2>/dev/null || true
                            issues_created=$((issues_created + 1))
                            emit_event "patrol.issue_created" "check=performance"
                        fi
                    fi

                    daemon_log WARN "Patrol: test suite ${pct_slower}% slower than baseline"
                    return
                fi
            fi
        fi

        # Save/update baseline
        jq -n --argjson dur "$recent_test_dur" --arg ts "$(now_iso)" \
            '{test_duration_s: $dur, updated_at: $ts}' > "$baseline_file"
        daemon_log INFO "Patrol: performance baseline updated (${recent_test_dur}s)"
    }

    # ── 7. Recurring Failure Patterns ──
    patrol_recurring_failures() {
        if [[ "$PATROL_FAILURES_THRESHOLD" -le 0 ]]; then return; fi
        daemon_log INFO "Patrol: checking recurring failure patterns"
        local findings=0

        # Source memory functions if available
        local memory_script="$SCRIPT_DIR/sw-memory.sh"
        if [[ ! -f "$memory_script" ]]; then
            daemon_log INFO "Patrol: memory script not found — skipping recurring failures"
            return
        fi

        # Get actionable failures from memory
        # Note: sw-memory.sh runs its CLI router on source, so we must redirect
        # the source's stdout to /dev/null and only capture the function's output
        local failures_json
        failures_json=$(
            (
                source "$memory_script" > /dev/null 2>&1 || true
                if command -v memory_get_actionable_failures &>/dev/null; then
                    memory_get_actionable_failures "$PATROL_FAILURES_THRESHOLD"
                else
                    echo "[]"
                fi
            )
        )

        local count
        count=$(echo "$failures_json" | jq 'length' 2>/dev/null || echo "0")
        if [[ "${count:-0}" -eq 0 ]]; then
            daemon_log INFO "Patrol: no recurring failures above threshold ($PATROL_FAILURES_THRESHOLD)"
            return
        fi

        while IFS= read -r failure; do
            local pattern stage seen_count last_seen root_cause
            pattern=$(echo "$failure" | jq -r '.pattern // "unknown"')
            stage=$(echo "$failure" | jq -r '.stage // "unknown"')
            seen_count=$(echo "$failure" | jq -r '.seen_count // 0')
            last_seen=$(echo "$failure" | jq -r '.last_seen // "unknown"')
            root_cause=$(echo "$failure" | jq -r '.root_cause // "Not yet identified"')

            # Truncate pattern for title (first 60 chars)
            local short_pattern
            short_pattern=$(echo "$pattern" | cut -c1-60)

            findings=$((findings + 1))
            emit_event "patrol.finding" "check=recurring_failure" "pattern=$short_pattern" "seen_count=$seen_count"

            if [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
                # Deduplicate
                local existing
                existing=$(gh issue list --label "$PATROL_LABEL" --label "recurring-failure" \
                    --search "Fix recurring: ${short_pattern}" --json number -q 'length' 2>/dev/null || echo "0")
                if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                    gh issue create \
                        --title "Fix recurring: ${short_pattern}" \
                        --body "## Recurring Failure Pattern

| Field | Value |
|-------|-------|
| Stage | \`${stage}\` |
| Pattern | \`${pattern}\` |
| Seen count | **${seen_count}** |
| Last seen | ${last_seen} |
| Root cause | ${root_cause} |
| Found by | Shipwright patrol |
| Date | $(now_iso) |

### Suggested Actions
- Investigate the root cause in the \`${stage}\` stage
- Check if recent changes introduced the failure
- Add a targeted test to prevent regression

Auto-detected by \`shipwright daemon patrol\`." \
                        --label "$(patrol_build_labels "recurring-failure")" 2>/dev/null || true
                    issues_created=$((issues_created + 1))
                    emit_event "patrol.issue_created" "check=recurring_failure" "pattern=$short_pattern"
                fi
            else
                echo -e "    ${RED}●${RESET} ${BOLD}recurring${RESET}: ${short_pattern} (${seen_count}x in ${CYAN}${stage}${RESET})"
            fi
        done < <(echo "$failures_json" | jq -c '.[]' 2>/dev/null)

        total_findings=$((total_findings + findings))
        daemon_log INFO "Patrol: found ${findings} recurring failure pattern(s)"
    }

    # ── 8. DORA Metric Degradation ──
    patrol_dora_degradation() {
        if [[ "$PATROL_DORA_ENABLED" != "true" ]]; then return; fi
        daemon_log INFO "Patrol: checking DORA metric degradation"

        if [[ ! -f "$EVENTS_FILE" ]]; then
            daemon_log INFO "Patrol: no events file — skipping DORA check"
            return
        fi

        local now_e
        now_e=$(now_epoch)

        # Current 7-day window
        local current_start=$((now_e - 604800))
        # Previous 7-day window
        local prev_start=$((now_e - 1209600))
        local prev_end=$current_start

        # Get events for both windows
        local current_events prev_events
        current_events=$(jq -s --argjson start "$current_start" \
            '[.[] | select(.ts_epoch >= $start)]' "$EVENTS_FILE" 2>/dev/null || echo "[]")
        prev_events=$(jq -s --argjson start "$prev_start" --argjson end "$prev_end" \
            '[.[] | select(.ts_epoch >= $start and .ts_epoch < $end)]' "$EVENTS_FILE" 2>/dev/null || echo "[]")

        # Helper: calculate DORA metrics from an event set
        calc_dora() {
            local events="$1"
            local total successes failures
            total=$(echo "$events" | jq '[.[] | select(.type == "pipeline.completed")] | length' 2>/dev/null || echo "0")
            successes=$(echo "$events" | jq '[.[] | select(.type == "pipeline.completed" and .result == "success")] | length' 2>/dev/null || echo "0")
            failures=$(echo "$events" | jq '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length' 2>/dev/null || echo "0")

            local deploy_freq="0"
            [[ "$total" -gt 0 ]] && deploy_freq=$(echo "$successes 7" | awk '{printf "%.1f", $1 / ($2 / 7)}')

            local cfr="0"
            [[ "$total" -gt 0 ]] && cfr=$(echo "$failures $total" | awk '{printf "%.1f", ($1 / $2) * 100}')

            local cycle_time="0"
            cycle_time=$(echo "$events" | jq '[.[] | select(.type == "pipeline.completed" and .result == "success") | .duration_s] | sort | if length > 0 then .[length/2 | floor] else 0 end' 2>/dev/null || echo "0")

            echo "{\"deploy_freq\":$deploy_freq,\"cfr\":$cfr,\"cycle_time\":$cycle_time,\"total\":$total}"
        }

        local current_metrics prev_metrics
        current_metrics=$(calc_dora "$current_events")
        prev_metrics=$(calc_dora "$prev_events")

        local prev_total
        prev_total=$(echo "$prev_metrics" | jq '.total' 2>/dev/null || echo "0")
        local current_total
        current_total=$(echo "$current_metrics" | jq '.total' 2>/dev/null || echo "0")

        # Need data in both windows to compare
        if [[ "${prev_total:-0}" -lt 3 ]] || [[ "${current_total:-0}" -lt 3 ]]; then
            daemon_log INFO "Patrol: insufficient data for DORA comparison (prev=$prev_total, current=$current_total)"
            return
        fi

        # Grade each metric using dora_grade (defined in daemon_metrics, redefined here inline)
        local_dora_grade() {
            local metric="$1" value="$2"
            case "$metric" in
                deploy_freq)
                    if awk "BEGIN{exit !($value >= 7)}" 2>/dev/null; then echo "Elite"; return; fi
                    if awk "BEGIN{exit !($value >= 1)}" 2>/dev/null; then echo "High"; return; fi
                    if awk "BEGIN{exit !($value >= 0.25)}" 2>/dev/null; then echo "Medium"; return; fi
                    echo "Low" ;;
                cfr)
                    if awk "BEGIN{exit !($value < 5)}" 2>/dev/null; then echo "Elite"; return; fi
                    if awk "BEGIN{exit !($value < 10)}" 2>/dev/null; then echo "High"; return; fi
                    if awk "BEGIN{exit !($value < 15)}" 2>/dev/null; then echo "Medium"; return; fi
                    echo "Low" ;;
                cycle_time)
                    [[ "$value" -lt 3600 ]] && echo "Elite" && return
                    [[ "$value" -lt 86400 ]] && echo "High" && return
                    [[ "$value" -lt 604800 ]] && echo "Medium" && return
                    echo "Low" ;;
            esac
        }

        grade_rank() {
            case "$1" in
                Elite) echo 4 ;; High) echo 3 ;; Medium) echo 2 ;; Low) echo 1 ;; *) echo 0 ;;
            esac
        }

        local degraded_metrics=""
        local degradation_details=""

        # Check deploy frequency
        local prev_df curr_df
        prev_df=$(echo "$prev_metrics" | jq -r '.deploy_freq')
        curr_df=$(echo "$current_metrics" | jq -r '.deploy_freq')
        local prev_df_grade curr_df_grade
        prev_df_grade=$(local_dora_grade deploy_freq "$prev_df")
        curr_df_grade=$(local_dora_grade deploy_freq "$curr_df")
        if [[ "$(grade_rank "$curr_df_grade")" -lt "$(grade_rank "$prev_df_grade")" ]]; then
            degraded_metrics="${degraded_metrics}deploy_freq "
            degradation_details="${degradation_details}\n| Deploy Frequency | ${prev_df_grade} (${prev_df}/wk) | ${curr_df_grade} (${curr_df}/wk) | Check for blocked PRs, increase automation |"
        fi

        # Check CFR
        local prev_cfr curr_cfr
        prev_cfr=$(echo "$prev_metrics" | jq -r '.cfr')
        curr_cfr=$(echo "$current_metrics" | jq -r '.cfr')
        local prev_cfr_grade curr_cfr_grade
        prev_cfr_grade=$(local_dora_grade cfr "$prev_cfr")
        curr_cfr_grade=$(local_dora_grade cfr "$curr_cfr")
        if [[ "$(grade_rank "$curr_cfr_grade")" -lt "$(grade_rank "$prev_cfr_grade")" ]]; then
            degraded_metrics="${degraded_metrics}cfr "
            degradation_details="${degradation_details}\n| Change Failure Rate | ${prev_cfr_grade} (${prev_cfr}%) | ${curr_cfr_grade} (${curr_cfr}%) | Investigate recent failures, improve test coverage |"
        fi

        # Check Cycle Time
        local prev_ct curr_ct
        prev_ct=$(echo "$prev_metrics" | jq -r '.cycle_time')
        curr_ct=$(echo "$current_metrics" | jq -r '.cycle_time')
        local prev_ct_grade curr_ct_grade
        prev_ct_grade=$(local_dora_grade cycle_time "$prev_ct")
        curr_ct_grade=$(local_dora_grade cycle_time "$curr_ct")
        if [[ "$(grade_rank "$curr_ct_grade")" -lt "$(grade_rank "$prev_ct_grade")" ]]; then
            degraded_metrics="${degraded_metrics}cycle_time "
            degradation_details="${degradation_details}\n| Cycle Time | ${prev_ct_grade} (${prev_ct}s) | ${curr_ct_grade} (${curr_ct}s) | Profile slow stages, check for new slow tests |"
        fi

        if [[ -z "$degraded_metrics" ]]; then
            daemon_log INFO "Patrol: no DORA degradation detected"
            return
        fi

        local findings=0
        findings=1
        total_findings=$((total_findings + findings))
        emit_event "patrol.finding" "check=dora_regression" "metrics=$degraded_metrics"

        if [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
            local trimmed
            trimmed=$(echo "$degraded_metrics" | sed 's/ *$//' | tr ' ' ',')
            local existing
            existing=$(gh issue list --label "$PATROL_LABEL" --label "dora-regression" \
                --search "DORA regression" --json number -q 'length' 2>/dev/null || echo "0")
            if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                gh issue create \
                    --title "DORA regression: ${trimmed}" \
                    --body "## DORA Metric Degradation

| Metric | Previous (7d) | Current (7d) | Suggested Action |
|--------|---------------|--------------|------------------|$(echo -e "$degradation_details")

> Compared: previous 7-day window vs current 7-day window.

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                    --label "$(patrol_build_labels "dora-regression")" 2>/dev/null || true
                issues_created=$((issues_created + 1))
                emit_event "patrol.issue_created" "check=dora_regression" "metrics=$trimmed"
            fi
        else
            local trimmed
            trimmed=$(echo "$degraded_metrics" | sed 's/ *$//')
            echo -e "    ${RED}●${RESET} ${BOLD}DORA regression${RESET}: ${trimmed}"
        fi

        daemon_log INFO "Patrol: DORA degradation detected in: ${degraded_metrics}"
    }

    # ── 9. Untested Scripts ──
    patrol_untested_scripts() {
        if [[ "$PATROL_UNTESTED_ENABLED" != "true" ]]; then return; fi
        daemon_log INFO "Patrol: checking for untested scripts"
        local findings=0
        local untested_list=""

        local scripts_dir="$SCRIPT_DIR"
        if [[ ! -d "$scripts_dir" ]]; then
            daemon_log INFO "Patrol: scripts directory not found — skipping"
            return
        fi

        # Collect untested scripts with usage counts
        local untested_entries=""
        while IFS= read -r script; do
            local basename
            basename=$(basename "$script")
            # Skip test scripts themselves
            [[ "$basename" == *-test.sh ]] && continue
            # Skip the main CLI router
            [[ "$basename" == "sw" ]] && continue

            # Extract the name part (sw-NAME.sh -> NAME)
            local name
            name=$(echo "$basename" | sed 's/^sw-//' | sed 's/\.sh$//')

            # Check if a test file exists
            if [[ ! -f "$scripts_dir/sw-${name}-test.sh" ]]; then
                # Count usage across other scripts
                local usage_count
                usage_count=$(grep -rl "sw-${name}" "$scripts_dir"/sw-*.sh 2>/dev/null | grep -cv "$basename" 2>/dev/null || echo "0")
                usage_count=${usage_count:-0}

                local line_count
                line_count=$(wc -l < "$script" 2>/dev/null | tr -d ' ' || echo "0")
                line_count=${line_count:-0}

                untested_entries="${untested_entries}${usage_count}|${basename}|${line_count}\n"
                findings=$((findings + 1))
            fi
        done < <(find "$scripts_dir" -maxdepth 1 -name "sw-*.sh" -type f 2>/dev/null | sort)

        if [[ "$findings" -eq 0 ]]; then
            daemon_log INFO "Patrol: all scripts have test files"
            return
        fi

        # Sort by usage count descending
        local sorted_entries
        sorted_entries=$(echo -e "$untested_entries" | sort -t'|' -k1 -rn | head -10)

        while IFS='|' read -r usage_count basename line_count; do
            [[ -z "$basename" ]] && continue
            untested_list="${untested_list}\n- \`${basename}\` (${line_count} lines, referenced by ${usage_count} scripts)"
            emit_event "patrol.finding" "check=untested_script" "script=$basename" "lines=$line_count" "usage=$usage_count"

            if [[ "$dry_run" == "true" ]] || [[ "$NO_GITHUB" == "true" ]]; then
                echo -e "    ${YELLOW}●${RESET} ${CYAN}${basename}${RESET} (${line_count} lines, ${usage_count} refs)"
            fi
        done <<< "$sorted_entries"

        total_findings=$((total_findings + findings))

        if [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
            local existing
            existing=$(gh issue list --label "$PATROL_LABEL" --label "test-coverage" \
                --search "Add tests for untested scripts" --json number -q 'length' 2>/dev/null || echo "0")
            if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                gh issue create \
                    --title "Add tests for ${findings} untested script(s)" \
                    --body "## Untested Scripts

The following scripts have no corresponding test file (\`sw-*-test.sh\`):
$(echo -e "$untested_list")

### How to Add Tests
Each test file should follow the pattern in existing test scripts (e.g., \`sw-daemon-test.sh\`):
- Mock environment with TEMP_DIR
- PASS/FAIL counters
- \`run_test\` harness
- Register in \`package.json\` test script

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                    --label "$(patrol_build_labels "test-coverage")" 2>/dev/null || true
                issues_created=$((issues_created + 1))
                emit_event "patrol.issue_created" "check=untested_scripts" "count=$findings"
            fi
        fi

        daemon_log INFO "Patrol: found ${findings} untested script(s)"
    }

    # ── 10. Retry Exhaustion Patterns ──
    patrol_retry_exhaustion() {
        if [[ "$PATROL_RETRY_ENABLED" != "true" ]]; then return; fi
        daemon_log INFO "Patrol: checking retry exhaustion patterns"
        local findings=0

        if [[ ! -f "$EVENTS_FILE" ]]; then
            daemon_log INFO "Patrol: no events file — skipping retry check"
            return
        fi

        local seven_days_ago
        seven_days_ago=$(($(now_epoch) - 604800))

        # Find retry_exhausted events in last 7 days
        local exhausted_events
        exhausted_events=$(jq -s --argjson since "$seven_days_ago" \
            '[.[] | select(.type == "daemon.retry_exhausted" and (.ts_epoch // 0) >= $since)]' \
            "$EVENTS_FILE" 2>/dev/null || echo "[]")

        local exhausted_count
        exhausted_count=$(echo "$exhausted_events" | jq 'length' 2>/dev/null || echo "0")

        if [[ "${exhausted_count:-0}" -lt "$PATROL_RETRY_THRESHOLD" ]]; then
            daemon_log INFO "Patrol: retry exhaustions ($exhausted_count) below threshold ($PATROL_RETRY_THRESHOLD)"
            return
        fi

        findings=1
        total_findings=$((total_findings + findings))

        # Get unique issue patterns
        local issue_list
        issue_list=$(echo "$exhausted_events" | jq -r '[.[] | .issue // "unknown"] | unique | join(", ")' 2>/dev/null || echo "unknown")

        local first_ts last_ts
        first_ts=$(echo "$exhausted_events" | jq -r '[.[] | .ts] | sort | first // "unknown"' 2>/dev/null || echo "unknown")
        last_ts=$(echo "$exhausted_events" | jq -r '[.[] | .ts] | sort | last // "unknown"' 2>/dev/null || echo "unknown")

        emit_event "patrol.finding" "check=retry_exhaustion" "count=$exhausted_count" "issues=$issue_list"

        if [[ "$NO_GITHUB" != "true" ]] && [[ "$dry_run" != "true" ]]; then
            local existing
            existing=$(gh issue list --label "$PATROL_LABEL" --label "reliability" \
                --search "Retry exhaustion pattern" --json number -q 'length' 2>/dev/null || echo "0")
            if [[ "${existing:-0}" -eq 0 ]] && [[ "$issues_created" -lt "$PATROL_MAX_ISSUES" ]]; then
                gh issue create \
                    --title "Retry exhaustion pattern (${exhausted_count} in 7 days)" \
                    --body "## Retry Exhaustion Pattern

| Field | Value |
|-------|-------|
| Exhaustions (7d) | **${exhausted_count}** |
| Threshold | ${PATROL_RETRY_THRESHOLD} |
| Affected issues | ${issue_list} |
| First occurrence | ${first_ts} |
| Latest occurrence | ${last_ts} |

### Investigation Steps
1. Check the affected issues for common patterns
2. Review pipeline logs for root cause
3. Consider if max_retries needs adjustment
4. Investigate if an external dependency is flaky

Auto-detected by \`shipwright daemon patrol\` on $(now_iso)." \
                    --label "$(patrol_build_labels "reliability")" 2>/dev/null || true
                issues_created=$((issues_created + 1))
                emit_event "patrol.issue_created" "check=retry_exhaustion" "count=$exhausted_count"
            fi
        else
            echo -e "    ${RED}●${RESET} ${BOLD}retry exhaustion${RESET}: ${exhausted_count} exhaustions in 7 days (issues: ${issue_list})"
        fi

        daemon_log INFO "Patrol: found retry exhaustion pattern (${exhausted_count} in 7 days)"
    }

    # ── Stage 1: Run all grep-based patrol checks (fast pre-filter) ──
    local patrol_findings_summary=""
    local pre_check_findings=0

    echo -e "  ${BOLD}Security Audit${RESET}"
    pre_check_findings=$total_findings
    patrol_security_audit
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}security: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Stale Dependencies${RESET}"
    pre_check_findings=$total_findings
    patrol_stale_dependencies
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}stale_deps: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Dead Code Detection${RESET}"
    pre_check_findings=$total_findings
    patrol_dead_code
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}dead_code: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Test Coverage Gaps${RESET}"
    pre_check_findings=$total_findings
    patrol_coverage_gaps
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}coverage: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Documentation Staleness${RESET}"
    pre_check_findings=$total_findings
    patrol_doc_staleness
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}docs: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Performance Baseline${RESET}"
    pre_check_findings=$total_findings
    patrol_performance_baseline
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}performance: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Recurring Failures${RESET}"
    pre_check_findings=$total_findings
    patrol_recurring_failures
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}recurring_failures: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}DORA Degradation${RESET}"
    pre_check_findings=$total_findings
    patrol_dora_degradation
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}dora: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Untested Scripts${RESET}"
    pre_check_findings=$total_findings
    patrol_untested_scripts
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}untested: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    echo -e "  ${BOLD}Retry Exhaustion${RESET}"
    pre_check_findings=$total_findings
    patrol_retry_exhaustion
    if [[ "$total_findings" -gt "$pre_check_findings" ]]; then
        patrol_findings_summary="${patrol_findings_summary}retry_exhaustion: $((total_findings - pre_check_findings)) finding(s); "
    fi
    echo ""

    # ── Stage 2: AI-Powered Confirmation (if enabled) ──
    if [[ "${PREDICTION_ENABLED:-false}" == "true" ]] && type patrol_ai_analyze &>/dev/null 2>&1; then
        daemon_log INFO "Intelligence: using AI patrol analysis (prediction enabled)"
        echo -e "  ${BOLD}AI Deep Analysis${RESET}"
        # Sample recent source files for AI analysis
        local sample_files=""
        local git_log_recent=""
        sample_files=$(git diff --name-only HEAD~5 2>/dev/null | head -10 | tr '\n' ',' || echo "")
        git_log_recent=$(git log --oneline -10 2>/dev/null || echo "")
        # Include grep-based findings summary as context for AI confirmation
        if [[ -n "$patrol_findings_summary" ]]; then
            git_log_recent="${git_log_recent}

Patrol pre-filter findings to confirm: ${patrol_findings_summary}"
            daemon_log INFO "Patrol: passing ${total_findings} grep findings to AI for confirmation"
        fi
        if [[ -n "$sample_files" ]]; then
            local ai_findings
            ai_findings=$(patrol_ai_analyze "$sample_files" "$git_log_recent" 2>/dev/null || echo "[]")
            if [[ -n "$ai_findings" && "$ai_findings" != "[]" ]]; then
                local ai_count
                ai_count=$(echo "$ai_findings" | jq 'length' 2>/dev/null || echo "0")
                ai_count=${ai_count:-0}
                total_findings=$((total_findings + ai_count))
                echo -e "    ${CYAN}●${RESET} AI confirmed findings + found ${ai_count} additional issue(s)"
                emit_event "patrol.ai_analysis" "findings=$ai_count" "grep_findings=${patrol_findings_summary:-none}"
            else
                echo -e "    ${GREEN}●${RESET} AI analysis: grep findings confirmed, no additional issues"
            fi
        fi
        echo ""
    else
        daemon_log INFO "Intelligence: using grep-only patrol (prediction disabled, enable with intelligence.prediction_enabled=true)"
    fi

    # ── Meta Self-Improvement Patrol ──
    if [[ -f "$SCRIPT_DIR/sw-patrol-meta.sh" ]]; then
        # shellcheck source=sw-patrol-meta.sh
        source "$SCRIPT_DIR/sw-patrol-meta.sh"
        patrol_meta_run
    fi

    # ── Strategic Intelligence Patrol (requires CLAUDE_CODE_OAUTH_TOKEN) ──
    if [[ -f "$SCRIPT_DIR/sw-strategic.sh" ]] && [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        # shellcheck source=sw-strategic.sh
        source "$SCRIPT_DIR/sw-strategic.sh"
        strategic_patrol_run || true
    fi

    # ── Summary ──
    emit_event "patrol.completed" "findings=$total_findings" "issues_created=$issues_created" "dry_run=$dry_run"

    echo -e "${PURPLE}${BOLD}━━━ Patrol Summary ━━━${RESET}"
    echo -e "  Findings:       ${total_findings}"
    echo -e "  Issues created: ${issues_created}"
    if [[ "$dry_run" == "true" ]]; then
        echo -e "  ${DIM}(dry run — no issues were created)${RESET}"
    fi
    echo ""

    daemon_log INFO "Patrol complete: ${total_findings} findings, ${issues_created} issues created"

    # Adapt patrol limits based on hit rate
    adapt_patrol_limits "$total_findings" "$PATROL_MAX_ISSUES"
}

# ─── Poll Issues ─────────────────────────────────────────────────────────────

daemon_poll_issues() {
    if [[ "$NO_GITHUB" == "true" ]]; then
        daemon_log INFO "Polling skipped (--no-github)"
        return
    fi

    # Check for pause flag (set by dashboard, disk_low, or consecutive-failure backoff)
    local pause_file="${PAUSE_FLAG:-$HOME/.shipwright/daemon-pause.flag}"
    if [[ -f "$pause_file" ]]; then
        local resume_after
        resume_after=$(jq -r '.resume_after // empty' "$pause_file" 2>/dev/null || true)
        if [[ -n "$resume_after" ]]; then
            local now_epoch resume_epoch
            now_epoch=$(date +%s)
            resume_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$resume_after" +%s 2>/dev/null || \
                date -d "$resume_after" +%s 2>/dev/null || echo 0)
            if [[ "$resume_epoch" -gt 0 ]] && [[ "$now_epoch" -ge "$resume_epoch" ]]; then
                rm -f "$pause_file"
                daemon_log INFO "Auto-resuming after backoff (resume_after passed)"
            else
                daemon_log INFO "Daemon paused until ${resume_after} — skipping poll"
                return
            fi
        else
            daemon_log INFO "Daemon paused — skipping poll"
            return
        fi
    fi

    # Circuit breaker: skip poll if in backoff window
    if gh_rate_limited; then
        daemon_log INFO "Polling skipped (rate-limit backoff until $(epoch_to_iso "$GH_BACKOFF_UNTIL"))"
        return
    fi

    local issues_json

    # Select gh command wrapper: gh_retry for critical poll calls when enabled
    local gh_cmd="gh"
    if [[ "${GH_RETRY_ENABLED:-true}" == "true" ]]; then
        gh_cmd="gh_retry gh"
    fi

    if [[ "$WATCH_MODE" == "org" && -n "$ORG" ]]; then
        # Org-wide mode: search issues across all org repos
        issues_json=$($gh_cmd search issues \
            --label "$WATCH_LABEL" \
            --owner "$ORG" \
            --state open \
            --json repository,number,title,labels,body,createdAt \
            --limit 20 2>/dev/null) || {
            # Handle rate limiting with exponential backoff
            if [[ $BACKOFF_SECS -eq 0 ]]; then
                BACKOFF_SECS=30
            elif [[ $BACKOFF_SECS -lt 300 ]]; then
                BACKOFF_SECS=$((BACKOFF_SECS * 2))
                if [[ $BACKOFF_SECS -gt 300 ]]; then
                    BACKOFF_SECS=300
                fi
            fi
            daemon_log WARN "GitHub API error (org search) — backing off ${BACKOFF_SECS}s"
            gh_record_failure
            sleep "$BACKOFF_SECS"
            return
        }

        # Filter by repo_filter regex if set
        if [[ -n "$REPO_FILTER" ]]; then
            issues_json=$(echo "$issues_json" | jq -c --arg filter "$REPO_FILTER" \
                '[.[] | select(.repository.nameWithOwner | test($filter))]')
        fi
    else
        # Standard single-repo mode
        issues_json=$($gh_cmd issue list \
            --label "$WATCH_LABEL" \
            --state open \
            --json number,title,labels,body,createdAt \
            --limit 20 2>/dev/null) || {
            # Handle rate limiting with exponential backoff
            if [[ $BACKOFF_SECS -eq 0 ]]; then
                BACKOFF_SECS=30
            elif [[ $BACKOFF_SECS -lt 300 ]]; then
                BACKOFF_SECS=$((BACKOFF_SECS * 2))
                if [[ $BACKOFF_SECS -gt 300 ]]; then
                    BACKOFF_SECS=300
                fi
            fi
            daemon_log WARN "GitHub API error — backing off ${BACKOFF_SECS}s"
            gh_record_failure
            sleep "$BACKOFF_SECS"
            return
        }
    fi

    # Reset backoff on success
    BACKOFF_SECS=0
    gh_record_success

    local issue_count
    issue_count=$(echo "$issues_json" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$issue_count" -eq 0 ]]; then
        return
    fi

    local mode_label="repo"
    [[ "$WATCH_MODE" == "org" ]] && mode_label="org:${ORG}"
    daemon_log INFO "Found ${issue_count} issue(s) with label '${WATCH_LABEL}' (${mode_label})"
    emit_event "daemon.poll" "issues_found=$issue_count" "active=$(get_active_count)" "mode=$WATCH_MODE"

    # Score each issue using intelligent triage and sort by descending score
    local scored_issues=()
    local dep_graph=""  # "issue:dep1,dep2" entries for dependency ordering
    while IFS= read -r issue; do
        local num score
        num=$(echo "$issue" | jq -r '.number')
        score=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
        score=$(printf '%s' "$score" | tr -cd '[:digit:]')
        [[ -z "$score" ]] && score=50
        # For org mode, include repo name in the scored entry
        local repo_name=""
        if [[ "$WATCH_MODE" == "org" ]]; then
            repo_name=$(echo "$issue" | jq -r '.repository.nameWithOwner // ""')
        fi
        scored_issues+=("${score}|${num}|${repo_name}")

        # Issue dependency detection (adaptive: extract "depends on #X", "blocked by #X")
        if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" == "true" ]]; then
            local issue_text
            issue_text=$(echo "$issue" | jq -r '(.title // "") + " " + (.body // "")')
            local deps
            deps=$(extract_issue_dependencies "$issue_text")
            if [[ -n "$deps" ]]; then
                local dep_nums
                dep_nums=$(echo "$deps" | tr -d '#' | tr '\n' ',' | sed 's/,$//')
                dep_graph="${dep_graph}${num}:${dep_nums}\n"
                daemon_log INFO "Issue #${num} depends on: ${deps//$'\n'/, }"
            fi
        fi
    done < <(echo "$issues_json" | jq -c '.[]')

    # Sort by score — strategy determines ascending vs descending
    local sorted_order
    if [[ "${PRIORITY_STRATEGY:-quick-wins-first}" == "complex-first" ]]; then
        # Complex-first: lower score (more complex) first
        sorted_order=$(printf '%s\n' "${scored_issues[@]}" | sort -t'|' -k1,1 -n -k2,2 -n)
    else
        # Quick-wins-first (default): higher score (simpler) first, lowest issue# first on ties
        sorted_order=$(printf '%s\n' "${scored_issues[@]}" | sort -t'|' -k1,1 -rn -k2,2 -n)
    fi

    # Dependency-aware reordering: move dependencies before dependents
    if [[ -n "$dep_graph" && "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" == "true" ]]; then
        local reordered=""
        local scheduled=""
        # Multiple passes to resolve transitive dependencies (max 3)
        local pass=0
        while [[ $pass -lt 3 ]]; do
            local changed=false
            local new_order=""
            while IFS='|' read -r s_score s_num s_repo; do
                [[ -z "$s_num" ]] && continue
                # Check if this issue has unscheduled dependencies
                local issue_deps
                issue_deps=$(echo -e "$dep_graph" | grep "^${s_num}:" | head -1 | cut -d: -f2 || true)
                if [[ -n "$issue_deps" ]]; then
                    # Check if all deps are scheduled (or not in our issue set)
                    local all_deps_ready=true
                    local IFS_SAVE="$IFS"
                    IFS=','
                    for dep in $issue_deps; do
                        dep="${dep## }"
                        dep="${dep%% }"
                        # Is this dep in our scored set and not yet scheduled?
                        if echo "$sorted_order" | grep -q "|${dep}|" && ! echo "$scheduled" | grep -q "|${dep}|"; then
                            all_deps_ready=false
                            break
                        fi
                    done
                    IFS="$IFS_SAVE"
                    if [[ "$all_deps_ready" == "false" ]]; then
                        # Defer this issue — append at end
                        new_order="${new_order}${s_score}|${s_num}|${s_repo}\n"
                        changed=true
                        continue
                    fi
                fi
                reordered="${reordered}${s_score}|${s_num}|${s_repo}\n"
                scheduled="${scheduled}|${s_num}|"
            done <<< "$sorted_order"
            # Append deferred issues
            reordered="${reordered}${new_order}"
            sorted_order=$(echo -e "$reordered" | grep -v '^$')
            reordered=""
            scheduled=""
            if [[ "$changed" == "false" ]]; then
                break
            fi
            pass=$((pass + 1))
        done
    fi

    local active_count
    active_count=$(locked_get_active_count)

    # Process each issue in triage order (process substitution keeps state in current shell)
    while IFS='|' read -r score issue_num repo_name; do
        [[ -z "$issue_num" ]] && continue

        local issue_title labels_csv
        issue_title=$(echo "$issues_json" | jq -r --argjson n "$issue_num" '.[] | select(.number == $n) | .title')
        labels_csv=$(echo "$issues_json" | jq -r --argjson n "$issue_num" '.[] | select(.number == $n) | [.labels[].name] | join(",")')

        # Cache title in state for dashboard visibility
        if [[ -n "$issue_title" ]]; then
            locked_state_update --arg num "$issue_num" --arg title "$issue_title" \
                '.titles[$num] = $title'
        fi

        # Skip if already inflight
        if daemon_is_inflight "$issue_num"; then
            continue
        fi

        # Distributed claim (skip if no machines registered)
        if [[ -f "$HOME/.shipwright/machines.json" ]]; then
            local machine_name
            machine_name=$(jq -r '.machines[] | select(.role == "primary") | .name' "$HOME/.shipwright/machines.json" 2>/dev/null || hostname -s)
            if ! claim_issue "$issue_num" "$machine_name"; then
                daemon_log INFO "Issue #${issue_num} claimed by another machine — skipping"
                continue
            fi
        fi

        # Priority lane: bypass queue for critical issues
        if [[ "$PRIORITY_LANE" == "true" ]]; then
            local priority_active
            priority_active=$(get_priority_active_count)
            if is_priority_issue "$labels_csv" && [[ "$priority_active" -lt "$PRIORITY_LANE_MAX" ]]; then
                daemon_log WARN "PRIORITY LANE: issue #${issue_num} bypassing queue (${labels_csv})"
                emit_event "daemon.priority_lane" "issue=$issue_num" "score=$score"

                local template
                template=$(select_pipeline_template "$labels_csv" "$score" 2>/dev/null | tail -1)
                template=$(printf '%s' "$template" | sed $'s/\x1b\\[[0-9;]*m//g' | tr -cd '[:alnum:]-_')
                [[ -z "$template" ]] && template="$PIPELINE_TEMPLATE"
                daemon_log INFO "Triage: issue #${issue_num} scored ${score}, template=${template} [PRIORITY]"

                local orig_template="$PIPELINE_TEMPLATE"
                PIPELINE_TEMPLATE="$template"
                daemon_spawn_pipeline "$issue_num" "$issue_title" "$repo_name"
                PIPELINE_TEMPLATE="$orig_template"
                track_priority_job "$issue_num"
                continue
            fi
        fi

        # Check capacity
        active_count=$(locked_get_active_count)
        if [[ "$active_count" -ge "$MAX_PARALLEL" ]]; then
            enqueue_issue "$issue_num"
            continue
        fi

        # Auto-select pipeline template: PM recommendation (if available) else labels + triage score
        local template
        if [[ "$NO_GITHUB" != "true" ]] && [[ -x "$SCRIPT_DIR/sw-pm.sh" ]]; then
            local pm_rec
            pm_rec=$(bash "$SCRIPT_DIR/sw-pm.sh" recommend --json "$issue_num" 2>/dev/null) || true
            if [[ -n "$pm_rec" ]]; then
                template=$(echo "$pm_rec" | jq -r '.team_composition.template // empty' 2>/dev/null) || true
                # Capability self-assessment: low confidence → upgrade to full template
                local confidence
                confidence=$(echo "$pm_rec" | jq -r '.team_composition.confidence_percent // 100' 2>/dev/null) || true
                if [[ -n "$confidence" && "$confidence" != "null" && "$confidence" -lt 60 ]]; then
                    daemon_log INFO "Low PM confidence (${confidence}%) — upgrading to full template"
                    template="full"
                fi
            fi
        fi
        if [[ -z "$template" ]]; then
            template=$(select_pipeline_template "$labels_csv" "$score" 2>/dev/null | tail -1)
        fi
        template=$(printf '%s' "$template" | sed $'s/\x1b\\[[0-9;]*m//g' | tr -cd '[:alnum:]-_')
        [[ -z "$template" ]] && template="$PIPELINE_TEMPLATE"
        daemon_log INFO "Triage: issue #${issue_num} scored ${score}, template=${template}"

        # Spawn pipeline (template selection applied via PIPELINE_TEMPLATE override)
        local orig_template="$PIPELINE_TEMPLATE"
        PIPELINE_TEMPLATE="$template"
        daemon_spawn_pipeline "$issue_num" "$issue_title" "$repo_name"
        PIPELINE_TEMPLATE="$orig_template"

        # Stagger delay between spawns to avoid API contention
        local stagger_delay="${SPAWN_STAGGER_SECONDS:-15}"
        if [[ "$stagger_delay" -gt 0 ]]; then
            sleep "$stagger_delay"
        fi
    done <<< "$sorted_order"

    # ── Drain queue if we have capacity (prevents deadlock when queue is
    #    populated but no active jobs exist to trigger dequeue) ──
    local drain_active
    drain_active=$(locked_get_active_count)
    while [[ "$drain_active" -lt "$MAX_PARALLEL" ]]; do
        local drain_issue
        drain_issue=$(dequeue_next)
        [[ -z "$drain_issue" ]] && break
        local drain_title
        drain_title=$(jq -r --arg n "$drain_issue" '.titles[$n] // ""' "$STATE_FILE" 2>/dev/null || true)

        local drain_labels drain_score drain_template
        drain_labels=$(echo "$issues_json" | jq -r --argjson n "$drain_issue" \
            '.[] | select(.number == $n) | [.labels[].name] | join(",")' 2>/dev/null || echo "")
        drain_score=$(echo "$sorted_order" | grep "|${drain_issue}|" | cut -d'|' -f1 || echo "50")
        drain_template=$(select_pipeline_template "$drain_labels" "${drain_score:-50}" 2>/dev/null | tail -1)
        drain_template=$(printf '%s' "$drain_template" | sed $'s/\x1b\\[[0-9;]*m//g' | tr -cd '[:alnum:]-_')
        [[ -z "$drain_template" ]] && drain_template="$PIPELINE_TEMPLATE"

        daemon_log INFO "Draining queue: issue #${drain_issue}, template=${drain_template}"
        local orig_template="$PIPELINE_TEMPLATE"
        PIPELINE_TEMPLATE="$drain_template"
        daemon_spawn_pipeline "$drain_issue" "$drain_title"
        PIPELINE_TEMPLATE="$orig_template"
        drain_active=$(locked_get_active_count)
    done

    # Update last poll
    update_state_field "last_poll" "$(now_iso)"
}

# ─── Health Check ─────────────────────────────────────────────────────────────

daemon_health_check() {
    local findings=0
    local now_e
    now_e=$(now_epoch)

    if [[ -f "$STATE_FILE" ]]; then
        # ── Intelligent Health Monitoring ──
        # Instead of killing after a countdown, sense what the agent is doing.
        # Agents think for long stretches — that's normal and expected.
        # Strategy: sense → understand → be patient → nudge → only kill as last resort.

        local hard_limit="${PROGRESS_HARD_LIMIT_S:-0}"
        local use_progress="${PROGRESS_MONITORING:-true}"
        local nudge_enabled="${NUDGE_ENABLED:-true}"
        local nudge_after="${NUDGE_AFTER_CHECKS:-40}"

        while IFS= read -r job; do
            local pid started_at issue_num worktree
            pid=$(echo "$job" | jq -r '.pid')
            started_at=$(echo "$job" | jq -r '.started_at // empty')
            issue_num=$(echo "$job" | jq -r '.issue')
            worktree=$(echo "$job" | jq -r '.worktree // ""')

            # Skip dead processes
            if ! kill -0 "$pid" 2>/dev/null; then
                continue
            fi

            local elapsed=0
            if [[ -n "$started_at" ]]; then
                local start_e
                start_e=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || date -d "$started_at" +%s 2>/dev/null || echo "0")
                elapsed=$(( now_e - start_e ))
            fi

            # Hard wall-clock limit — disabled by default (0 = off)
            if [[ "$hard_limit" -gt 0 && "$elapsed" -gt "$hard_limit" ]]; then
                daemon_log WARN "Hard limit exceeded: issue #${issue_num} (${elapsed}s > ${hard_limit}s, PID $pid) — killing"
                emit_event "daemon.hard_limit" "issue=$issue_num" "elapsed_s=$elapsed" "limit_s=$hard_limit" "pid=$pid"
                kill "$pid" 2>/dev/null || true
                daemon_clear_progress "$issue_num"
                findings=$((findings + 1))
                continue
            fi

            # ── Intelligent Progress Sensing ──
            if [[ "$use_progress" == "true" && -n "$worktree" ]]; then
                local snapshot verdict
                snapshot=$(daemon_collect_snapshot "$issue_num" "$worktree" "$pid" 2>/dev/null || echo '{}')

                if [[ "$snapshot" != "{}" ]]; then
                    verdict=$(daemon_assess_progress "$issue_num" "$snapshot" 2>/dev/null || echo "healthy")

                    local no_progress_count=0
                    no_progress_count=$(jq -r '.no_progress_count // 0' "$PROGRESS_DIR/issue-${issue_num}.json" 2>/dev/null || echo 0)
                    local cur_stage
                    cur_stage=$(echo "$snapshot" | jq -r '.stage // "unknown"')

                    case "$verdict" in
                        healthy)
                            # All good — agent is making progress
                            ;;
                        slowing)
                            daemon_log INFO "Issue #${issue_num} slowing (no visible changes for ${no_progress_count} checks, ${elapsed}s elapsed, stage=${cur_stage})"
                            ;;
                        stalled)
                            # Check if agent subprocess is alive and consuming CPU
                            local agent_alive=false
                            local child_cpu=0
                            child_cpu=$(pgrep -P "$pid" 2>/dev/null | xargs -I{} ps -o pcpu= -p {} 2>/dev/null | awk '{sum+=$1} END{printf "%d", sum+0}' || echo "0")
                            if [[ "${child_cpu:-0}" -gt 0 ]]; then
                                agent_alive=true
                            fi

                            if [[ "$agent_alive" == "true" ]]; then
                                daemon_log INFO "Issue #${issue_num} no visible progress (${no_progress_count} checks) but agent is alive (CPU: ${child_cpu}%, stage=${cur_stage}, ${elapsed}s) — being patient"
                            else
                                daemon_log WARN "Issue #${issue_num} stalled: no progress for ${no_progress_count} checks, no CPU activity (${elapsed}s elapsed, PID $pid)"
                                emit_event "daemon.stalled" "issue=$issue_num" "no_progress=$no_progress_count" "elapsed_s=$elapsed" "pid=$pid"
                            fi
                            ;;
                        stuck)
                            local repeated_errors
                            repeated_errors=$(jq -r '.repeated_error_count // 0' "$PROGRESS_DIR/issue-${issue_num}.json" 2>/dev/null || echo 0)

                            # Even "stuck" — check if the process tree is alive first
                            local agent_alive=false
                            local child_cpu=0
                            child_cpu=$(pgrep -P "$pid" 2>/dev/null | xargs -I{} ps -o pcpu= -p {} 2>/dev/null | awk '{sum+=$1} END{printf "%d", sum+0}' || echo "0")
                            if [[ "${child_cpu:-0}" -gt 0 ]]; then
                                agent_alive=true
                            fi

                            if [[ "$agent_alive" == "true" && "$repeated_errors" -lt 3 ]]; then
                                # Agent is alive — nudge instead of kill
                                if [[ "$nudge_enabled" == "true" && "$no_progress_count" -ge "$nudge_after" ]]; then
                                    local nudge_file="${worktree}/.claude/nudge.md"
                                    if [[ ! -f "$nudge_file" ]]; then
                                        cat > "$nudge_file" <<NUDGE_EOF
# Nudge from Daemon Health Monitor

The daemon has noticed no visible progress for $(( no_progress_count * 30 / 60 )) minutes.
Current stage: ${cur_stage}

If you're stuck, consider:
- Breaking the task into smaller steps
- Committing partial progress
- Running tests to validate current state

This is just a gentle check-in — take your time if you're working through a complex problem.
NUDGE_EOF
                                        daemon_log INFO "Issue #${issue_num} nudged (${no_progress_count} checks, stage=${cur_stage}, CPU=${child_cpu}%) — file written to worktree"
                                        emit_event "daemon.nudge" "issue=$issue_num" "no_progress=$no_progress_count" "stage=$cur_stage" "elapsed_s=$elapsed"
                                    fi
                                else
                                    daemon_log INFO "Issue #${issue_num} no visible progress (${no_progress_count} checks) but agent is alive (CPU: ${child_cpu}%, stage=${cur_stage}) — waiting"
                                fi
                            elif [[ "$repeated_errors" -ge 5 ]]; then
                                # Truly stuck in an error loop — kill as last resort
                                daemon_log WARN "Issue #${issue_num} in error loop: ${repeated_errors} repeated errors (stage=${cur_stage}, ${elapsed}s, PID $pid) — killing"
                                emit_event "daemon.stuck_kill" "issue=$issue_num" "no_progress=$no_progress_count" "repeated_errors=$repeated_errors" "stage=$cur_stage" "elapsed_s=$elapsed" "pid=$pid" "reason=error_loop"
                                kill "$pid" 2>/dev/null || true
                                daemon_clear_progress "$issue_num"
                                findings=$((findings + 1))
                            elif [[ "$agent_alive" != "true" && "$no_progress_count" -ge "$((PROGRESS_CHECKS_BEFORE_KILL * 2))" ]]; then
                                # Process tree is dead AND no progress for very long time
                                daemon_log WARN "Issue #${issue_num} appears dead: no CPU, no progress for ${no_progress_count} checks (${elapsed}s, PID $pid) — killing"
                                emit_event "daemon.stuck_kill" "issue=$issue_num" "no_progress=$no_progress_count" "repeated_errors=$repeated_errors" "stage=$cur_stage" "elapsed_s=$elapsed" "pid=$pid" "reason=dead_process"
                                kill "$pid" 2>/dev/null || true
                                daemon_clear_progress "$issue_num"
                                findings=$((findings + 1))
                            else
                                daemon_log WARN "Issue #${issue_num} struggling (${no_progress_count} checks, ${repeated_errors} errors, CPU=${child_cpu}%, stage=${cur_stage}) — monitoring"
                            fi
                            ;;
                    esac
                fi
            else
                # Fallback: legacy time-based detection when progress monitoring is off
                local stale_timeout
                stale_timeout=$(get_adaptive_stale_timeout "$PIPELINE_TEMPLATE")
                if [[ "$elapsed" -gt "$stale_timeout" ]]; then
                    daemon_log WARN "Stale job (legacy): issue #${issue_num} (${elapsed}s > ${stale_timeout}s, PID $pid)"
                    # Don't kill — just log. Let the process run.
                    emit_event "daemon.stale_warning" "issue=$issue_num" "elapsed_s=$elapsed" "pid=$pid"
                    findings=$((findings + 1))
                fi
            fi
        done < <(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null || true)
    fi

    # Disk space warning (check both repo dir and ~/.shipwright)
    local free_kb
    free_kb=$(df -k "." 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$free_kb" ]] && [[ "$free_kb" -lt 1048576 ]] 2>/dev/null; then
        daemon_log WARN "Low disk space: $(( free_kb / 1024 ))MB free"
        findings=$((findings + 1))
    fi

    # Critical disk space on ~/.shipwright — pause spawning
    local sw_free_kb
    sw_free_kb=$(df -k "$HOME/.shipwright" 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$sw_free_kb" ]] && [[ "$sw_free_kb" -lt 512000 ]] 2>/dev/null; then
        daemon_log WARN "Critical disk space on ~/.shipwright: $(( sw_free_kb / 1024 ))MB — pausing spawns"
        emit_event "daemon.disk_low" "free_mb=$(( sw_free_kb / 1024 ))"
        mkdir -p "$HOME/.shipwright"
        echo '{"paused":true,"reason":"disk_low"}' > "$HOME/.shipwright/daemon-pause.flag"
        findings=$((findings + 1))
    fi

    # Events file size warning
    if [[ -f "$EVENTS_FILE" ]]; then
        local events_size
        events_size=$(wc -c < "$EVENTS_FILE" 2>/dev/null || echo 0)
        if [[ "$events_size" -gt 104857600 ]]; then  # 100MB
            daemon_log WARN "Events file large ($(( events_size / 1048576 ))MB) — consider rotating"
            findings=$((findings + 1))
        fi
    fi

    if [[ "$findings" -gt 0 ]]; then
        emit_event "daemon.health" "findings=$findings"
    fi
}

# ─── Degradation Alerting ─────────────────────────────────────────────────────

daemon_check_degradation() {
    if [[ ! -f "$EVENTS_FILE" ]]; then return; fi

    local window="${DEGRADATION_WINDOW:-5}"
    local cfr_threshold="${DEGRADATION_CFR_THRESHOLD:-30}"
    local success_threshold="${DEGRADATION_SUCCESS_THRESHOLD:-50}"

    # Get last N pipeline completions
    local recent
    recent=$(tail -200 "$EVENTS_FILE" | jq -s "[.[] | select(.type == \"pipeline.completed\")] | .[-${window}:]" 2>/dev/null)
    local count
    count=$(echo "$recent" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$count" -lt "$window" ]]; then return; fi

    local failures successes
    failures=$(echo "$recent" | jq '[.[] | select(.result == "failure")] | length')
    successes=$(echo "$recent" | jq '[.[] | select(.result == "success")] | length')
    local cfr_pct=0 success_pct=0
    if [[ "${count:-0}" -gt 0 ]]; then
        cfr_pct=$(( failures * 100 / count ))
        success_pct=$(( successes * 100 / count ))
    fi

    local alerts=""
    if [[ "$cfr_pct" -gt "$cfr_threshold" ]]; then
        alerts="CFR ${cfr_pct}% exceeds threshold ${cfr_threshold}%"
        daemon_log WARN "DEGRADATION: $alerts"
    fi
    if [[ "$success_pct" -lt "$success_threshold" ]]; then
        local msg="Success rate ${success_pct}% below threshold ${success_threshold}%"
        [[ -n "$alerts" ]] && alerts="$alerts; $msg" || alerts="$msg"
        daemon_log WARN "DEGRADATION: $msg"
    fi

    if [[ -n "$alerts" ]]; then
        emit_event "daemon.alert" "alerts=$alerts" "cfr_pct=$cfr_pct" "success_pct=$success_pct"

        # Slack notification
        if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
            notify "Pipeline Degradation Alert" "$alerts" "warn"
        fi
    fi
}

# ─── Auto-Scaling ─────────────────────────────────────────────────────────
# Dynamically adjusts MAX_PARALLEL based on CPU, memory, budget, and queue depth

daemon_auto_scale() {
    if [[ "${AUTO_SCALE:-false}" != "true" ]]; then
        return
    fi

    local prev_max="$MAX_PARALLEL"

    # ── Learn worker memory from actual RSS (adaptive) ──
    learn_worker_memory

    # ── Adaptive cost estimate per template ──
    local effective_cost_per_job
    effective_cost_per_job=$(get_adaptive_cost_estimate "$PIPELINE_TEMPLATE")

    # ── CPU cores ──
    local cpu_cores=2
    if [[ "$(uname -s)" == "Darwin" ]]; then
        cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
    else
        cpu_cores=$(nproc 2>/dev/null || echo 2)
    fi
    local max_by_cpu=$(( (cpu_cores * 3) / 4 ))  # 75% utilization cap
    [[ "$max_by_cpu" -lt 1 ]] && max_by_cpu=1

    # ── Load average check — gradual scaling curve (replaces 90% cliff) ──
    local load_avg
    load_avg=$(uptime | awk -F'load averages?: ' '{print $2}' | awk -F'[, ]+' '{print $1}' 2>/dev/null || echo "0")
    if [[ ! "$load_avg" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        load_avg="0"
    fi
    local load_ratio=0
    if [[ "$cpu_cores" -gt 0 ]]; then
        load_ratio=$(awk -v load="$load_avg" -v cores="$cpu_cores" 'BEGIN { printf "%.0f", (load / cores) * 100 }')
    fi
    # Gradual load scaling curve (replaces binary 90% cliff)
    if [[ "$load_ratio" -gt 95 ]]; then
        # 95%+: minimum workers only
        max_by_cpu="$MIN_WORKERS"
        daemon_log WARN "Auto-scale: critical load (${load_ratio}%) — minimum workers only"
    elif [[ "$load_ratio" -gt 85 ]]; then
        # 85-95%: reduce by 50%
        max_by_cpu=$(( max_by_cpu / 2 ))
        [[ "$max_by_cpu" -lt "$MIN_WORKERS" ]] && max_by_cpu="$MIN_WORKERS"
        daemon_log WARN "Auto-scale: high load (${load_ratio}%) — reducing capacity 50%"
    elif [[ "$load_ratio" -gt 70 ]]; then
        # 70-85%: reduce by 25%
        max_by_cpu=$(( (max_by_cpu * 3) / 4 ))
        [[ "$max_by_cpu" -lt "$MIN_WORKERS" ]] && max_by_cpu="$MIN_WORKERS"
        daemon_log INFO "Auto-scale: moderate load (${load_ratio}%) — reducing capacity 25%"
    fi
    # 0-70%: full capacity (no change)

    # ── Available memory ──
    local avail_mem_gb=8
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local page_size free_pages inactive_pages purgeable_pages speculative_pages
        page_size=$(vm_stat | awk '/page size of/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) print $i}')
        page_size="${page_size:-16384}"
        free_pages=$(vm_stat | awk '/^Pages free:/ {gsub(/\./, "", $NF); print $NF}')
        free_pages="${free_pages:-0}"
        speculative_pages=$(vm_stat | awk '/^Pages speculative:/ {gsub(/\./, "", $NF); print $NF}')
        speculative_pages="${speculative_pages:-0}"
        inactive_pages=$(vm_stat | awk '/^Pages inactive:/ {gsub(/\./, "", $NF); print $NF}')
        inactive_pages="${inactive_pages:-0}"
        purgeable_pages=$(vm_stat | awk '/^Pages purgeable:/ {gsub(/\./, "", $NF); print $NF}')
        purgeable_pages="${purgeable_pages:-0}"
        local avail_pages=$(( free_pages + speculative_pages + inactive_pages + purgeable_pages ))
        if [[ "$avail_pages" -gt 0 && "$page_size" -gt 0 ]]; then
            local free_bytes=$(( avail_pages * page_size ))
            avail_mem_gb=$(( free_bytes / 1073741824 ))
        fi
    else
        local avail_kb
        avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo "8388608")
        avail_mem_gb=$(( avail_kb / 1048576 ))
    fi
    [[ "$avail_mem_gb" -lt 1 ]] && avail_mem_gb=1
    local max_by_mem=$(( avail_mem_gb / WORKER_MEM_GB ))
    [[ "$max_by_mem" -lt 1 ]] && max_by_mem=1

    # ── Budget remaining (adaptive cost estimate) ──
    local max_by_budget="$MAX_WORKERS"
    local remaining_usd
    remaining_usd=$("$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "unlimited")
    if [[ "$remaining_usd" != "unlimited" && -n "$remaining_usd" ]]; then
        if awk -v r="$remaining_usd" -v c="$effective_cost_per_job" 'BEGIN { exit !(r > 0 && c > 0) }'; then
            max_by_budget=$(awk -v r="$remaining_usd" -v c="$effective_cost_per_job" 'BEGIN { printf "%.0f", r / c }')
            [[ "$max_by_budget" -lt 0 ]] && max_by_budget=0
        else
            max_by_budget=0
        fi
    fi

    # ── Queue depth (don't over-provision) ──
    local queue_depth active_count
    queue_depth=$(jq -r '.queued | length' "$STATE_FILE" 2>/dev/null || echo 0)
    queue_depth="${queue_depth:-0}"
    [[ ! "$queue_depth" =~ ^[0-9]+$ ]] && queue_depth=0
    active_count=$(get_active_count)
    active_count="${active_count:-0}"
    [[ ! "$active_count" =~ ^[0-9]+$ ]] && active_count=0
    local max_by_queue=$(( queue_depth + active_count ))
    [[ "$max_by_queue" -lt 1 ]] && max_by_queue=1

    # ── Vitals-driven scaling factor ──
    local max_by_vitals="$MAX_WORKERS"
    if type pipeline_compute_vitals &>/dev/null 2>&1 && [[ -f "$STATE_FILE" ]]; then
        local _total_health=0 _health_count=0
        while IFS= read -r _job; do
            local _job_issue _job_worktree
            _job_issue=$(echo "$_job" | jq -r '.issue // 0')
            _job_worktree=$(echo "$_job" | jq -r '.worktree // ""')
            if [[ -n "$_job_worktree" && -d "$_job_worktree/.claude" ]]; then
                local _job_vitals _job_health
                _job_vitals=$(pipeline_compute_vitals "$_job_worktree/.claude/pipeline-state.md" "$_job_worktree/.claude/pipeline-artifacts" "$_job_issue" 2>/dev/null) || true
                if [[ -n "$_job_vitals" && "$_job_vitals" != "{}" ]]; then
                    _job_health=$(echo "$_job_vitals" | jq -r '.health_score // 50' 2>/dev/null || echo "50")
                    _total_health=$((_total_health + _job_health))
                    _health_count=$((_health_count + 1))
                fi
            fi
        done < <(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null || true)

        if [[ "$_health_count" -gt 0 ]]; then
            local _avg_health=$((_total_health / _health_count))
            if [[ "$_avg_health" -lt 50 ]]; then
                # Pipelines struggling — reduce workers to give each more resources
                max_by_vitals=$(( MAX_WORKERS * _avg_health / 100 ))
                [[ "$max_by_vitals" -lt "$MIN_WORKERS" ]] && max_by_vitals="$MIN_WORKERS"
                daemon_log INFO "Auto-scale: vitals avg health ${_avg_health}% — capping at ${max_by_vitals} workers"
            fi
            # avg_health > 70: no reduction (full capacity available)
        fi
    fi

    # ── Compute final value ──
    local computed="$max_by_cpu"
    [[ "$max_by_mem" -lt "$computed" ]] && computed="$max_by_mem"
    [[ "$max_by_budget" -lt "$computed" ]] && computed="$max_by_budget"
    [[ "$max_by_queue" -lt "$computed" ]] && computed="$max_by_queue"
    [[ "$max_by_vitals" -lt "$computed" ]] && computed="$max_by_vitals"
    [[ "$MAX_WORKERS" -lt "$computed" ]] && computed="$MAX_WORKERS"

    # Respect fleet-assigned ceiling if set
    if [[ -n "${FLEET_MAX_PARALLEL:-}" && "$FLEET_MAX_PARALLEL" -lt "$computed" ]]; then
        computed="$FLEET_MAX_PARALLEL"
    fi

    # Clamp to min_workers
    [[ "$computed" -lt "$MIN_WORKERS" ]] && computed="$MIN_WORKERS"

    # ── Gradual scaling: change by at most 1 at a time (adaptive) ──
    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" == "true" ]]; then
        if [[ "$computed" -gt "$prev_max" ]]; then
            # Check success rate at target parallelism before scaling up
            local target_rate
            target_rate=$(get_success_rate_at_parallelism "$((prev_max + 1))")
            if [[ "$target_rate" -lt 50 ]]; then
                # Poor success rate at higher parallelism — hold steady
                computed="$prev_max"
                daemon_log INFO "Auto-scale: holding at ${prev_max} (success rate ${target_rate}% at $((prev_max + 1)))"
            else
                # Scale up by 1, not jump to target
                computed=$((prev_max + 1))
            fi
        elif [[ "$computed" -lt "$prev_max" ]]; then
            # Scale down by 1, not drop to minimum
            computed=$((prev_max - 1))
            [[ "$computed" -lt "$MIN_WORKERS" ]] && computed="$MIN_WORKERS"
        fi
    fi

    MAX_PARALLEL="$computed"

    if [[ "$MAX_PARALLEL" -ne "$prev_max" ]]; then
        daemon_log INFO "Auto-scale: ${prev_max} → ${MAX_PARALLEL} (cpu=${max_by_cpu} mem=${max_by_mem} budget=${max_by_budget} queue=${max_by_queue} load=${load_ratio}%)"
        emit_event "daemon.scale" \
            "from=$prev_max" \
            "to=$MAX_PARALLEL" \
            "max_by_cpu=$max_by_cpu" \
            "max_by_mem=$max_by_mem" \
            "max_by_budget=$max_by_budget" \
            "max_by_queue=$max_by_queue" \
            "cpu_cores=$cpu_cores" \
            "avail_mem_gb=$avail_mem_gb" \
            "remaining_usd=$remaining_usd" \
            "load_ratio=$load_ratio"
    fi
}

# ─── Fleet Config Reload ──────────────────────────────────────────────────
# Checks for fleet-reload.flag and reloads MAX_PARALLEL from fleet-managed config

daemon_reload_config() {
    local reload_flag="$HOME/.shipwright/fleet-reload.flag"
    if [[ ! -f "$reload_flag" ]]; then
        return
    fi

    local fleet_config=".claude/.fleet-daemon-config.json"
    if [[ -f "$fleet_config" ]]; then
        local new_max
        new_max=$(jq -r '.max_parallel // empty' "$fleet_config" 2>/dev/null || true)
        if [[ -n "$new_max" && "$new_max" != "null" ]]; then
            local prev="$MAX_PARALLEL"
            FLEET_MAX_PARALLEL="$new_max"
            MAX_PARALLEL="$new_max"
            daemon_log INFO "Fleet reload: max_parallel ${prev} → ${MAX_PARALLEL} (fleet ceiling: ${FLEET_MAX_PARALLEL})"
            emit_event "daemon.fleet_reload" "from=$prev" "to=$MAX_PARALLEL"
        fi
    fi

    rm -f "$reload_flag"
}

# ─── Self-Optimizing Metrics Loop ──────────────────────────────────────────

daemon_self_optimize() {
    if [[ "${SELF_OPTIMIZE:-false}" != "true" ]]; then
        return
    fi

    if [[ ! -f "$EVENTS_FILE" ]]; then
        return
    fi

    # ── Intelligence-powered optimization (if enabled) ──
    if [[ "${OPTIMIZATION_ENABLED:-false}" == "true" ]] && type optimize_full_analysis &>/dev/null 2>&1; then
        daemon_log INFO "Running intelligence-powered optimization"
        optimize_full_analysis 2>/dev/null || {
            daemon_log WARN "Intelligence optimization failed — falling back to DORA-based tuning"
        }
        # Still run DORA-based tuning below as a complement
    fi

    daemon_log INFO "Running self-optimization check"

    # Read DORA metrics from recent events (last 7 days)
    local cutoff_epoch
    cutoff_epoch=$(( $(now_epoch) - (7 * 86400) ))

    local period_events
    period_events=$(jq -c "select(.ts_epoch >= $cutoff_epoch)" "$EVENTS_FILE" 2>/dev/null || true)

    if [[ -z "$period_events" ]]; then
        daemon_log INFO "No recent events for optimization"
        return
    fi

    local total_completed successes failures
    total_completed=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed")] | length')
    successes=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success")] | length')
    failures=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length')

    # Change Failure Rate
    local cfr=0
    if [[ "$total_completed" -gt 0 ]]; then
        cfr=$(echo "$failures $total_completed" | awk '{printf "%.0f", ($1 / $2) * 100}')
    fi

    # Cycle time (median, in seconds)
    local cycle_time_median
    cycle_time_median=$(echo "$period_events" | \
        jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success") | .duration_s // 0] | sort | if length > 0 then .[length/2 | floor] else 0 end')

    # Deploy frequency (per week)
    local deploy_freq
    deploy_freq=$(echo "$successes" | awk '{printf "%.1f", $1 / 1}')  # Already 7 days

    # MTTR
    local mttr
    mttr=$(echo "$period_events" | \
        jq -s '
            [.[] | select(.type == "pipeline.completed")] | sort_by(.ts_epoch // 0) |
            [range(length) as $i |
                if .[$i].result == "failure" then
                    [.[$i+1:][] | select(.result == "success")][0] as $next |
                    if $next and $next.ts_epoch and .[$i].ts_epoch then
                        ($next.ts_epoch - .[$i].ts_epoch)
                    else null end
                else null end
            ] | map(select(. != null)) |
            if length > 0 then (add / length | floor) else 0 end
        ')

    local adjustments=()

    # ── CFR > 20%: enable compound_quality, increase max_cycles ──
    if [[ "$cfr" -gt 40 ]]; then
        PIPELINE_TEMPLATE="full"
        adjustments+=("template→full (CFR ${cfr}% > 40%)")
        daemon_log WARN "Self-optimize: CFR ${cfr}% critical — switching to full template"
    elif [[ "$cfr" -gt 20 ]]; then
        adjustments+=("compound_quality enabled (CFR ${cfr}% > 20%)")
        daemon_log WARN "Self-optimize: CFR ${cfr}% elevated — enabling compound quality"
    fi

    # ── Lead time > 4hrs: increase max_parallel, reduce poll_interval ──
    if [[ "$cycle_time_median" -gt 14400 ]]; then
        MAX_PARALLEL=$((MAX_PARALLEL + 1))
        if [[ "$POLL_INTERVAL" -gt 30 ]]; then
            POLL_INTERVAL=$((POLL_INTERVAL / 2))
        fi
        adjustments+=("max_parallel→${MAX_PARALLEL}, poll_interval→${POLL_INTERVAL}s (lead time > 4hrs)")
        daemon_log WARN "Self-optimize: lead time $(format_duration "$cycle_time_median") — increasing parallelism"
    elif [[ "$cycle_time_median" -gt 7200 ]]; then
        # ── Lead time > 2hrs: enable auto_template for fast-pathing ──
        AUTO_TEMPLATE="true"
        adjustments+=("auto_template enabled (lead time > 2hrs)")
        daemon_log INFO "Self-optimize: lead time $(format_duration "$cycle_time_median") — enabling adaptive templates"
    fi

    # ── Deploy freq < 1/day (< 7/week): enable merge stage ──
    if [[ "$(echo "$deploy_freq < 7" | bc -l 2>/dev/null || echo 0)" == "1" ]]; then
        adjustments+=("merge stage recommended (deploy freq ${deploy_freq}/week)")
        daemon_log INFO "Self-optimize: low deploy frequency — consider enabling merge stage"
    fi

    # ── MTTR > 2hrs: enable auto_rollback ──
    if [[ "$mttr" -gt 7200 ]]; then
        adjustments+=("auto_rollback recommended (MTTR $(format_duration "$mttr"))")
        daemon_log WARN "Self-optimize: high MTTR $(format_duration "$mttr") — consider enabling auto-rollback"
    fi

    # Write adjustments to state and persist to config
    if [[ ${#adjustments[@]} -gt 0 ]]; then
        local adj_str
        adj_str=$(printf '%s; ' "${adjustments[@]}")

        locked_state_update \
            --arg adj "$adj_str" \
            --arg ts "$(now_iso)" \
            '.last_optimization = {timestamp: $ts, adjustments: $adj}'

        # ── Persist adjustments to daemon-config.json (survives restart) ──
        local config_file="${CONFIG_PATH:-.claude/daemon-config.json}"
        if [[ -f "$config_file" ]]; then
            local tmp_config
            tmp_config=$(jq \
                --argjson max_parallel "$MAX_PARALLEL" \
                --argjson poll_interval "$POLL_INTERVAL" \
                --arg template "$PIPELINE_TEMPLATE" \
                --arg auto_template "${AUTO_TEMPLATE:-false}" \
                --arg ts "$(now_iso)" \
                --arg adj "$adj_str" \
                '.max_parallel = $max_parallel |
                 .poll_interval = $poll_interval |
                 .pipeline_template = $template |
                 .auto_template = ($auto_template == "true") |
                 .last_optimization = {timestamp: $ts, adjustments: $adj}' \
                "$config_file")
            # Atomic write: tmp file + mv
            local tmp_cfg_file="${config_file}.tmp.$$"
            echo "$tmp_config" > "$tmp_cfg_file"
            mv "$tmp_cfg_file" "$config_file"
            daemon_log INFO "Self-optimize: persisted adjustments to ${config_file}"
        fi

        emit_event "daemon.optimize" "adjustments=${adj_str}" "cfr=$cfr" "cycle_time=$cycle_time_median" "deploy_freq=$deploy_freq" "mttr=$mttr"
        daemon_log SUCCESS "Self-optimization applied ${#adjustments[@]} adjustment(s)"
    else
        daemon_log INFO "Self-optimization: all metrics within thresholds"
    fi
}

# ─── Stale State Reaper ──────────────────────────────────────────────────────
# Cleans old worktrees, pipeline artifacts, and completed state entries.
# Called every N poll cycles (configurable via stale_reaper_interval).

daemon_cleanup_stale() {
    if [[ "${STALE_REAPER_ENABLED:-true}" != "true" ]]; then
        return
    fi

    daemon_log INFO "Running stale state reaper"
    local cleaned=0
    local age_days="${STALE_REAPER_AGE_DAYS:-7}"
    local age_secs=$((age_days * 86400))
    local now_e
    now_e=$(now_epoch)

    # ── 1. Clean old git worktrees ──
    if command -v git &>/dev/null; then
        while IFS= read -r line; do
            local wt_path
            wt_path=$(echo "$line" | awk '{print $1}')
            # Only clean daemon-created worktrees
            [[ "$wt_path" == *"daemon-issue-"* ]] || continue
            # Check worktree age via directory mtime
            local mtime
            mtime=$(stat -f '%m' "$wt_path" 2>/dev/null || stat -c '%Y' "$wt_path" 2>/dev/null || echo "0")
            if [[ $((now_e - mtime)) -gt $age_secs ]]; then
                daemon_log INFO "Removing stale worktree: ${wt_path}"
                git worktree remove "$wt_path" --force 2>/dev/null || true
                cleaned=$((cleaned + 1))
            fi
        done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //')
    fi

    # ── 2. Expire old checkpoints ──
    if [[ -x "$SCRIPT_DIR/sw-checkpoint.sh" ]]; then
        local expired_output
        expired_output=$(bash "$SCRIPT_DIR/sw-checkpoint.sh" expire --hours "$((age_days * 24))" 2>/dev/null || true)
        if [[ -n "$expired_output" ]] && echo "$expired_output" | grep -q "Expired"; then
            local expired_count
            expired_count=$(echo "$expired_output" | grep -c "Expired" || true)
            cleaned=$((cleaned + ${expired_count:-0}))
            daemon_log INFO "Expired ${expired_count:-0} old checkpoint(s)"
        fi
    fi

    # ── 3. Clean old pipeline artifacts (subdirectories only) ──
    local artifacts_dir=".claude/pipeline-artifacts"
    if [[ -d "$artifacts_dir" ]]; then
        while IFS= read -r artifact_dir; do
            [[ -d "$artifact_dir" ]] || continue
            local mtime
            mtime=$(stat -f '%m' "$artifact_dir" 2>/dev/null || stat -c '%Y' "$artifact_dir" 2>/dev/null || echo "0")
            if [[ $((now_e - mtime)) -gt $age_secs ]]; then
                daemon_log INFO "Removing stale artifact: ${artifact_dir}"
                rm -rf "$artifact_dir"
                cleaned=$((cleaned + 1))
            fi
        done < <(find "$artifacts_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi

    # ── 3. Clean orphaned daemon/* branches (no matching worktree or active job) ──
    if command -v git &>/dev/null; then
        while IFS= read -r branch; do
            [[ -z "$branch" ]] && continue
            branch="${branch## }"  # trim leading spaces
            # Only clean daemon-created branches
            [[ "$branch" == daemon/issue-* ]] || continue
            # Extract issue number
            local branch_issue_num="${branch#daemon/issue-}"
            # Skip if there's an active job for this issue
            if daemon_is_inflight "$branch_issue_num" 2>/dev/null; then
                continue
            fi
            daemon_log INFO "Removing orphaned branch: ${branch}"
            git branch -D "$branch" 2>/dev/null || true
            cleaned=$((cleaned + 1))
        done < <(git branch --list 'daemon/issue-*' 2>/dev/null)
    fi

    # ── 4. Prune completed/failed state entries older than age_days ──
    if [[ -f "$STATE_FILE" ]]; then
        local cutoff_iso
        cutoff_iso=$(epoch_to_iso $((now_e - age_secs)))
        local before_count
        before_count=$(jq '.completed | length' "$STATE_FILE" 2>/dev/null || echo 0)
        locked_state_update --arg cutoff "$cutoff_iso" \
            '.completed = [.completed[] | select(.completed_at > $cutoff)]' 2>/dev/null || true
        local after_count
        after_count=$(jq '.completed | length' "$STATE_FILE" 2>/dev/null || echo 0)
        local pruned=$((before_count - after_count))
        if [[ "$pruned" -gt 0 ]]; then
            daemon_log INFO "Pruned ${pruned} old completed state entries"
            cleaned=$((cleaned + pruned))
        fi
    fi

    # ── 5. Prune stale retry_counts (issues no longer in flight or queued) ──
    if [[ -f "$STATE_FILE" ]]; then
        local retry_keys
        retry_keys=$(jq -r '.retry_counts // {} | keys[]' "$STATE_FILE" 2>/dev/null || true)
        local stale_keys=()
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            if ! daemon_is_inflight "$key" 2>/dev/null; then
                stale_keys+=("$key")
            fi
        done <<< "$retry_keys"
        if [[ ${#stale_keys[@]} -gt 0 ]]; then
            for sk in "${stale_keys[@]}"; do
                locked_state_update --arg k "$sk" 'del(.retry_counts[$k])' 2>/dev/null || continue
            done
            daemon_log INFO "Pruned ${#stale_keys[@]} stale retry count(s)"
            cleaned=$((cleaned + ${#stale_keys[@]}))
        fi
    fi

    if [[ "$cleaned" -gt 0 ]]; then
        emit_event "daemon.cleanup" "cleaned=$cleaned" "age_days=$age_days"
        daemon_log SUCCESS "Stale reaper cleaned ${cleaned} item(s)"
    else
        daemon_log INFO "Stale reaper: nothing to clean"
    fi
}

# ─── Poll Loop ───────────────────────────────────────────────────────────────

POLL_CYCLE_COUNT=0

daemon_poll_loop() {
    daemon_log INFO "Entering poll loop (interval: ${POLL_INTERVAL}s, max_parallel: ${MAX_PARALLEL})"
    daemon_log INFO "Watching for label: ${CYAN}${WATCH_LABEL}${RESET}"

    while [[ ! -f "$SHUTDOWN_FLAG" ]]; do
        # All poll loop calls are error-guarded to prevent set -e from killing the daemon.
        # The || operator disables set -e for the entire call chain, so transient failures
        # (GitHub API timeouts, jq errors, intelligence failures) are logged and skipped.
        daemon_preflight_auth_check || daemon_log WARN "Auth check failed — daemon may be paused"
        daemon_poll_issues || daemon_log WARN "daemon_poll_issues failed — continuing"
        daemon_reap_completed || daemon_log WARN "daemon_reap_completed failed — continuing"
        daemon_health_check || daemon_log WARN "daemon_health_check failed — continuing"

        # Increment cycle counter (must be before all modulo checks)
        POLL_CYCLE_COUNT=$((POLL_CYCLE_COUNT + 1))

        # Fleet config reload every 3 cycles
        if [[ $((POLL_CYCLE_COUNT % 3)) -eq 0 ]]; then
            daemon_reload_config || daemon_log WARN "daemon_reload_config failed — continuing"
        fi

        # Check degradation every 5 poll cycles
        if [[ $((POLL_CYCLE_COUNT % 5)) -eq 0 ]]; then
            daemon_check_degradation || daemon_log WARN "daemon_check_degradation failed — continuing"
        fi

        # Auto-scale every N cycles (default: 5)
        if [[ $((POLL_CYCLE_COUNT % ${AUTO_SCALE_INTERVAL:-5})) -eq 0 ]]; then
            daemon_auto_scale || daemon_log WARN "daemon_auto_scale failed — continuing"
        fi

        # Self-optimize every N cycles (default: 10)
        if [[ $((POLL_CYCLE_COUNT % ${OPTIMIZE_INTERVAL:-10})) -eq 0 ]]; then
            daemon_self_optimize || daemon_log WARN "daemon_self_optimize failed — continuing"
        fi

        # Stale state reaper every N cycles (default: 10)
        if [[ $((POLL_CYCLE_COUNT % ${STALE_REAPER_INTERVAL:-10})) -eq 0 ]]; then
            daemon_cleanup_stale || daemon_log WARN "daemon_cleanup_stale failed — continuing"
        fi

        # Rotate event log every 10 cycles (~10 min with 60s interval)
        if [[ $((POLL_CYCLE_COUNT % 10)) -eq 0 ]]; then
            rotate_event_log || true
        fi

        # Proactive patrol during quiet periods (with adaptive limits)
        local issue_count_now active_count_now
        issue_count_now=$(jq -r '.queued | length' "$STATE_FILE" 2>/dev/null || echo 0)
        active_count_now=$(get_active_count || echo 0)
        if [[ "$issue_count_now" -eq 0 ]] && [[ "$active_count_now" -eq 0 ]]; then
            local now_e
            now_e=$(now_epoch || date +%s)
            if [[ $((now_e - LAST_PATROL_EPOCH)) -ge "$PATROL_INTERVAL" ]]; then
                load_adaptive_patrol_limits || true
                daemon_log INFO "No active work — running patrol"
                daemon_patrol --once || daemon_log WARN "daemon_patrol failed — continuing"
                LAST_PATROL_EPOCH=$now_e
            fi
        fi

        # ── Adaptive poll interval: adjust sleep based on queue state ──
        local effective_interval
        effective_interval=$(get_adaptive_poll_interval "$issue_count_now" "$active_count_now" || echo "${POLL_INTERVAL:-30}")

        # Sleep in 1s intervals so we can catch shutdown quickly
        local i=0
        while [[ $i -lt $effective_interval ]] && [[ ! -f "$SHUTDOWN_FLAG" ]]; do
            sleep 1 || true  # Guard against signal interruption under set -e
            i=$((i + 1))
        done
    done

    daemon_log INFO "Shutdown flag detected — exiting poll loop"
}

# ─── Graceful Shutdown Handler ───────────────────────────────────────────────

cleanup_on_exit() {
    local exit_code=$?
    local last_cmd="${BASH_COMMAND:-unknown}"
    daemon_log INFO "Cleaning up... (exit_code=${exit_code}, last_command=${last_cmd})"

    # Kill all active pipeline child processes
    if [[ -f "$STATE_FILE" ]]; then
        local child_pids
        child_pids=$(jq -r '.active_jobs[].pid // empty' "$STATE_FILE" 2>/dev/null || true)
        if [[ -n "$child_pids" ]]; then
            local killed=0
            while IFS= read -r cpid; do
                [[ -z "$cpid" ]] && continue
                if kill -0 "$cpid" 2>/dev/null; then
                    daemon_log INFO "Killing pipeline process tree PID ${cpid}"
                    pkill -TERM -P "$cpid" 2>/dev/null || true
                    kill "$cpid" 2>/dev/null || true
                    killed=$((killed + 1))
                fi
            done <<< "$child_pids"
            if [[ $killed -gt 0 ]]; then
                daemon_log INFO "Sent SIGTERM to ${killed} pipeline process(es) — waiting 5s"
                sleep 5
                # Force-kill any that didn't exit
                while IFS= read -r cpid; do
                    [[ -z "$cpid" ]] && continue
                    if kill -0 "$cpid" 2>/dev/null; then
                        daemon_log WARN "Force-killing pipeline tree PID ${cpid}"
                        pkill -9 -P "$cpid" 2>/dev/null || true
                        kill -9 "$cpid" 2>/dev/null || true
                    fi
                done <<< "$child_pids"
            fi
        fi
    fi

    rm -f "$PID_FILE" "$SHUTDOWN_FLAG"
    daemon_log INFO "Daemon stopped"
    emit_event "daemon.stopped" "pid=$$"
}

# ─── daemon start ───────────────────────────────────────────────────────────

daemon_start() {
    echo -e "${PURPLE}${BOLD}━━━ shipwright daemon v${VERSION} ━━━${RESET}"
    echo ""

    # Acquire exclusive lock on PID file (prevents race between concurrent starts)
    exec 9>"$PID_FILE"
    if ! flock -n 9 2>/dev/null; then
        # flock unavailable or lock held — fall back to PID check
        local existing_pid
        existing_pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            exec 9>&-  # Release FD before exiting
            error "Daemon already running (PID: ${existing_pid})"
            info "Use ${CYAN}shipwright daemon stop${RESET} to stop it first"
            exit 1
        else
            warn "Stale PID file found — removing"
            rm -f "$PID_FILE"
            exec 9>&-  # Release old FD
            exec 9>"$PID_FILE"
        fi
    fi
    # Release FD 9 — we only needed it for the startup race check
    exec 9>&-

    # Load config
    load_config

    # Pre-flight
    if ! preflight_checks; then
        exit 1
    fi

    # Detach mode: re-exec in a tmux session
    if [[ "$DETACH" == "true" ]]; then
        if ! command -v tmux &>/dev/null; then
            error "tmux required for --detach mode"
            exit 1
        fi

        info "Starting daemon in detached tmux session: ${CYAN}sw-daemon${RESET}"

        # Build the command to run in tmux
        local cmd_args=("$SCRIPT_DIR/sw-daemon.sh" "start")
        if [[ -n "$CONFIG_PATH" ]]; then
            cmd_args+=("--config" "$CONFIG_PATH")
        fi
        if [[ "$NO_GITHUB" == "true" ]]; then
            cmd_args+=("--no-github")
        fi

        # Export current PATH so detached session finds claude, gh, etc.
        local tmux_cmd="export PATH='${PATH}'; ${cmd_args[*]}"
        tmux new-session -d -s "sw-daemon" "$tmux_cmd" 2>/dev/null || {
            # Session may already exist — try killing and recreating
            tmux kill-session -t "sw-daemon" 2>/dev/null || true
            tmux new-session -d -s "sw-daemon" "$tmux_cmd"
        }

        success "Daemon started in tmux session ${CYAN}sw-daemon${RESET}"
        info "Attach with: ${DIM}tmux attach -t sw-daemon${RESET}"
        info "View logs:   ${DIM}shipwright daemon logs --follow${RESET}"
        return 0
    fi

    # Foreground mode
    info "Starting daemon (PID: $$)"

    # Write PID file atomically
    local pid_tmp="${PID_FILE}.tmp.$$"
    echo "$$" > "$pid_tmp"
    mv "$pid_tmp" "$PID_FILE"

    # Remove stale shutdown flag
    rm -f "$SHUTDOWN_FLAG"

    # Initialize SQLite database (if available)
    if type init_schema &>/dev/null; then
        init_schema 2>/dev/null || true
    fi

    # Initialize state
    init_state

    # Trap signals for graceful shutdown
    trap cleanup_on_exit EXIT
    trap '{ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [WARN] SIGINT/SIGTERM received — initiating shutdown" >> "$LOG_FILE" 2>/dev/null; } || true; touch "$SHUTDOWN_FLAG"' SIGINT SIGTERM
    # Ignore SIGHUP — tmux sends this on attach/detach and we must survive it
    trap '' SIGHUP
    # Ignore SIGPIPE — broken pipes in command substitutions must not kill the daemon
    trap '' SIGPIPE

    # Override global ERR trap to log to daemon log file (not stderr, which is lost when tmux dies)
    trap '{ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ERROR] ERR trap: line=$LINENO exit=$? cmd=$BASH_COMMAND" >> "$LOG_FILE" 2>/dev/null; } || true' ERR

    # Reap any orphaned jobs from previous runs
    daemon_reap_completed || daemon_log WARN "Failed to reap orphaned jobs — continuing"

    # Clean up stale temp files from previous crashes
    find "$(dirname "$STATE_FILE")" -name "*.tmp.*" -mmin +5 -delete 2>/dev/null || true

    # Rotate event log on startup
    rotate_event_log || true

    # Load GitHub context (repo metadata, security alerts, etc.)
    daemon_github_context || daemon_log WARN "Failed to load GitHub context — continuing without it"

    daemon_log INFO "Daemon started successfully"
    daemon_log INFO "Config: poll_interval=${POLL_INTERVAL}s, max_parallel=${MAX_PARALLEL}, label=${WATCH_LABEL}"

    emit_event "daemon.started" \
        "pid=$$" \
        "poll_interval=$POLL_INTERVAL" \
        "max_parallel=$MAX_PARALLEL" \
        "watch_label=$WATCH_LABEL"

    # Enter poll loop
    daemon_poll_loop
}

# ─── daemon stop ─────────────────────────────────────────────────────────────

daemon_stop() {
    if [[ ! -f "$PID_FILE" ]]; then
        error "No daemon PID file found at $PID_FILE"
        info "Is the daemon running?"
        exit 1
    fi

    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)

    if [[ -z "$pid" ]]; then
        error "Empty PID file"
        rm -f "$PID_FILE"
        exit 1
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        warn "Daemon process (PID: ${pid}) is not running — cleaning up"
        rm -f "$PID_FILE" "$SHUTDOWN_FLAG"
        return 0
    fi

    info "Sending shutdown signal to daemon (PID: ${pid})..."

    # Touch shutdown flag for graceful exit
    touch "$SHUTDOWN_FLAG"

    # Wait for graceful shutdown (up to 30s)
    local wait_secs=0
    while kill -0 "$pid" 2>/dev/null && [[ $wait_secs -lt 30 ]]; do
        sleep 1
        wait_secs=$((wait_secs + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        warn "Daemon didn't stop gracefully — sending SIGTERM"
        kill "$pid" 2>/dev/null || true
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            warn "Sending SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    rm -f "$PID_FILE" "$SHUTDOWN_FLAG"

    # Also kill tmux session if it exists
    tmux kill-session -t "sw-daemon" 2>/dev/null || true

    success "Daemon stopped"
}

# ─── daemon status ───────────────────────────────────────────────────────────

daemon_status() {
    echo -e "${PURPLE}${BOLD}━━━ Daemon Status ━━━${RESET}"
    echo ""

    # Check if running
    local running=false
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            running=true
            echo -e "  ${GREEN}●${RESET} ${BOLD}Running${RESET} ${DIM}(PID: ${pid})${RESET}"
        else
            echo -e "  ${RED}●${RESET} ${BOLD}Stopped${RESET} ${DIM}(stale PID file)${RESET}"
        fi
    else
        echo -e "  ${RED}●${RESET} ${BOLD}Stopped${RESET}"
    fi

    if [[ ! -f "$STATE_FILE" ]]; then
        echo ""
        echo -e "  ${DIM}No state file found. Start the daemon first.${RESET}"
        return
    fi

    # Read state
    local last_poll started_at
    last_poll=$(jq -r '.last_poll // "never"' "$STATE_FILE" 2>/dev/null)
    started_at=$(jq -r '.started_at // "unknown"' "$STATE_FILE" 2>/dev/null)

    echo -e "  Started:   ${DIM}${started_at}${RESET}"
    echo -e "  Last poll: ${DIM}${last_poll}${RESET}"
    echo ""

    # Active jobs
    local active_count
    active_count=$(jq -r '.active_jobs | length' "$STATE_FILE" 2>/dev/null || echo 0)

    echo -e "${BOLD}  Active Jobs (${active_count}/${MAX_PARALLEL})${RESET}"
    if [[ "$active_count" -gt 0 ]]; then
        while IFS=$'\t' read -r num title started; do
            local age=""
            if [[ "$started" != "—" ]] && [[ "$running" == "true" ]]; then
                local start_epoch
                start_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null || echo 0)
                if [[ "$start_epoch" -gt 0 ]]; then
                    age=" ($(format_duration $(($(now_epoch) - start_epoch))))"
                fi
            fi
            echo -e "    ${CYAN}#${num}${RESET}  ${title}  ${DIM}${age}${RESET}"
        done < <(jq -r '.active_jobs[] | "    \(.issue)\t\(.title // "—")\t\(.started_at // "—")"' "$STATE_FILE" 2>/dev/null)
    else
        echo -e "    ${DIM}None${RESET}"
    fi
    echo ""

    # Queue
    local queue_count
    queue_count=$(jq -r '.queued | length' "$STATE_FILE" 2>/dev/null || echo 0)

    echo -e "${BOLD}  Queued (${queue_count})${RESET}"
    if [[ "$queue_count" -gt 0 ]]; then
        while read -r num; do
            echo -e "    ${DIM}#${num}${RESET}"
        done < <(jq -r '.queued[]' "$STATE_FILE" 2>/dev/null)
    else
        echo -e "    ${DIM}None${RESET}"
    fi
    echo ""

    # Recent completed
    local completed_count
    completed_count=$(jq -r '.completed | length' "$STATE_FILE" 2>/dev/null || echo 0)

    echo -e "${BOLD}  Recently Completed (${completed_count})${RESET}"
    if [[ "$completed_count" -gt 0 ]]; then
        # Show last 10
        while IFS=$'\t' read -r num result dur; do
            local icon
            if [[ "$result" == "success" ]]; then
                icon="${GREEN}✓${RESET}"
            else
                icon="${RED}✗${RESET}"
            fi
            echo -e "    ${icon} ${CYAN}#${num}${RESET}  ${result}  ${DIM}(${dur})${RESET}"
        done < <(jq -r '.completed | reverse | .[:10][] | "\(.issue)\t\(.result)\t\(.duration // "—")"' "$STATE_FILE" 2>/dev/null)
    else
        echo -e "    ${DIM}None${RESET}"
    fi
    echo ""
}

# ─── daemon init ─────────────────────────────────────────────────────────────

daemon_init() {
    local config_dir=".claude"
    local config_file="${config_dir}/daemon-config.json"

    if [[ -f "$config_file" ]]; then
        warn "Config file already exists: $config_file"
        info "Delete it first if you want to regenerate"
        return 0
    fi

    mkdir -p "$config_dir"

    cat > "$config_file" << 'CONFIGEOF'
{
  "watch_label": "ready-to-build",
  "poll_interval": 60,
  "max_parallel": 2,
  "pipeline_template": "autonomous",
  "skip_gates": true,
  "model": "opus",
  "base_branch": "main",
  "on_success": {
    "remove_label": "ready-to-build",
    "add_label": "pipeline/complete",
    "close_issue": false
  },
  "on_failure": {
    "add_label": "pipeline/failed",
    "comment_log_lines": 50
  },
  "notifications": {
    "slack_webhook": null
  },
  "health": {
    "stale_timeout_s": 1800
  },
  "priority_labels": "urgent,p0,high,p1,normal,p2,low,p3",
  "alerts": {
    "degradation_window": 5,
    "cfr_threshold": 30,
    "success_threshold": 50
  },
  "patrol": {
    "interval": 3600,
    "max_issues": 5,
    "label": "auto-patrol",
    "auto_watch": false,
    "checks": {
      "recurring_failures": { "enabled": true, "threshold": 3 },
      "dora_degradation": { "enabled": true },
      "untested_scripts": { "enabled": true },
      "retry_exhaustion": { "enabled": true, "threshold": 2 }
    }
  },
  "auto_template": false,
  "template_map": {
    "hotfix|incident": "hotfix",
    "security": "enterprise"
  },
  "max_retries": 2,
  "retry_escalation": true,
  "self_optimize": false,
  "optimize_interval": 10,
  "priority_lane": false,
  "priority_lane_labels": "hotfix,incident,p0,urgent",
  "priority_lane_max": 1,
  "watch_mode": "repo",
  "org": null,
  "repo_filter": null,
  "auto_scale": false,
  "auto_scale_interval": 5,
  "max_workers": 8,
  "min_workers": 1,
  "worker_mem_gb": 4,
  "estimated_cost_per_job_usd": 5.0,
  "intelligence": {
    "enabled": true,
    "cache_ttl_seconds": 3600,
    "composer_enabled": true,
    "optimization_enabled": true,
    "prediction_enabled": true,
    "adversarial_enabled": false,
    "simulation_enabled": false,
    "architecture_enabled": false,
    "ab_test_ratio": 0.2,
    "anomaly_threshold": 3.0
  }
}
CONFIGEOF

    success "Generated config: ${config_file}"
    echo ""
    echo -e "${DIM}Edit this file to customize the daemon behavior, then run:${RESET}"
    echo -e "  ${CYAN}shipwright daemon start${RESET}"
}

# ─── daemon logs ─────────────────────────────────────────────────────────────

daemon_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        warn "No log file found at $LOG_FILE"
        info "Start the daemon first with ${CYAN}shipwright daemon start${RESET}"
        return 0
    fi

    if [[ "$FOLLOW" == "true" ]]; then
        info "Following daemon log (Ctrl-C to stop)..."
        echo ""
        tail -f "$LOG_FILE"
    else
        tail -100 "$LOG_FILE"
    fi
}

# ─── Metrics Dashboard ─────────────────────────────────────────────────────

daemon_metrics() {
    local period_days=7
    local json_output=false

    # Parse metrics flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --period) period_days="${2:-7}"; shift 2 ;;
            --json)   json_output=true; shift ;;
            *)        shift ;;
        esac
    done

    if [[ ! -f "$EVENTS_FILE" ]]; then
        error "No events file found at $EVENTS_FILE"
        info "Events are generated when running ${CYAN}shipwright pipeline${RESET} or ${CYAN}shipwright daemon${RESET}"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        error "jq is required for metrics. Install: brew install jq"
        exit 1
    fi

    # Calculate cutoff timestamp
    local cutoff_epoch
    cutoff_epoch=$(( $(now_epoch) - (period_days * 86400) ))
    local cutoff_iso
    cutoff_iso=$(epoch_to_iso "$cutoff_epoch")

    # Filter events within period (prefer ts_epoch when available)
    local period_events
    period_events=$(jq -c "select(.ts_epoch >= $cutoff_epoch // .ts >= \"$cutoff_iso\")" "$EVENTS_FILE" 2>/dev/null)

    if [[ -z "$period_events" ]]; then
        warn "No events in the last ${period_days} day(s)"
        return 0
    fi

    # ── DORA: Deployment Frequency ──
    local total_completed successes failures
    total_completed=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed")] | length')
    successes=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success")] | length')
    failures=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length')

    local deploy_freq=""
    if [[ "$period_days" -gt 0 ]]; then
        deploy_freq=$(echo "$successes $period_days" | awk '{printf "%.1f", $1 / ($2 / 7)}')
    fi

    # ── DORA: Cycle Time (median pipeline duration for successes) ──
    local cycle_time_median cycle_time_p95
    cycle_time_median=$(echo "$period_events" | \
        jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success") | .duration_s] | sort | if length > 0 then .[length/2 | floor] else 0 end')
    cycle_time_p95=$(echo "$period_events" | \
        jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success") | .duration_s] | sort | if length > 0 then .[length * 95 / 100 | floor] else 0 end')

    # ── DORA: Change Failure Rate ──
    local cfr="0"
    if [[ "$total_completed" -gt 0 ]]; then
        cfr=$(echo "$failures $total_completed" | awk '{printf "%.1f", ($1 / $2) * 100}')
    fi

    # ── DORA: MTTR (average time between failure and next success) ──
    local mttr="0"
    # Real MTTR: time gap between each failure event and the next success event
    mttr=$(echo "$period_events" | \
        jq -s '
            [.[] | select(.type == "pipeline.completed")] | sort_by(.ts_epoch // 0) |
            [range(length) as $i |
                if .[$i].result == "failure" then
                    [.[$i+1:][] | select(.result == "success")][0] as $next |
                    if $next and $next.ts_epoch and .[$i].ts_epoch then
                        ($next.ts_epoch - .[$i].ts_epoch)
                    else null end
                else null end
            ] | map(select(. != null)) |
            if length > 0 then (add / length | floor) else 0 end
        ')

    # ── DX: Compound quality first-pass rate ──
    local compound_events first_pass_total first_pass_success
    first_pass_total=$(echo "$period_events" | \
        jq -s '[.[] | select(.type == "compound.cycle" and .cycle == 1)] | length')
    first_pass_success=$(echo "$period_events" | \
        jq -s '[.[] | select(.type == "compound.cycle" and .cycle == 1 and .passed == "true")] | length')
    local first_pass_pct="0"
    [[ "$first_pass_total" -gt 0 ]] && first_pass_pct=$(echo "$first_pass_success $first_pass_total" | awk '{printf "%.0f", ($1/$2)*100}')

    local avg_cycles
    avg_cycles=$(echo "$period_events" | \
        jq -s '[.[] | select(.type == "compound.cycle")] | if length > 0 then (group_by(.issue) | map(max_by(.cycle) | .cycle) | add / length) else 0 end | . * 10 | floor / 10')

    # ── Throughput ──
    local issues_processed prs_created
    issues_processed=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.started") | .issue] | unique | length')
    prs_created=$successes

    # ── Stage Timings ──
    local avg_stage_timings
    avg_stage_timings=$(echo "$period_events" | \
        jq -s '[.[] | select(.type == "stage.completed")] | group_by(.stage) | map({stage: .[0].stage, avg: ([.[].duration_s] | add / length | floor)}) | sort_by(.avg) | reverse')

    # ── Autonomy ──
    local daemon_spawns daemon_reaps daemon_success
    daemon_spawns=$(echo "$period_events" | jq -s '[.[] | select(.type == "daemon.spawn")] | length')
    daemon_reaps=$(echo "$period_events" | jq -s '[.[] | select(.type == "daemon.reap")] | length')
    daemon_success=$(echo "$period_events" | jq -s '[.[] | select(.type == "daemon.reap" and .result == "success")] | length')
    local autonomy_pct="0"
    [[ "$daemon_reaps" -gt 0 ]] && autonomy_pct=$(echo "$daemon_success $daemon_reaps" | awk '{printf "%.1f", ($1/$2)*100}')

    # ── Patrol ──
    local patrol_runs patrol_findings patrol_issues_created patrol_auto_resolved
    patrol_runs=$(echo "$period_events" | jq -s '[.[] | select(.type == "patrol.completed")] | length')
    patrol_findings=$(echo "$period_events" | jq -s '[.[] | select(.type == "patrol.finding")] | length')
    patrol_issues_created=$(echo "$period_events" | jq -s '[.[] | select(.type == "patrol.issue_created")] | length')
    # Auto-resolved: patrol issues that were later fixed by a pipeline
    patrol_auto_resolved=$(echo "$period_events" | jq -s '
        [.[] | select(.type == "patrol.issue_created") | .issue // empty] as $patrol_issues |
        [.[] | select(.type == "daemon.reap" and .result == "success") | .issue // empty] as $completed |
        [$patrol_issues[] | select(. as $p | $completed | any(. == $p))] | length
    ' 2>/dev/null || echo "0")

    # ── DORA Scoring ──
    dora_grade() {
        local metric="$1" value="$2"
        case "$metric" in
            deploy_freq)
                if awk "BEGIN{exit !($value >= 7)}" 2>/dev/null; then echo "Elite"; return; fi
                if awk "BEGIN{exit !($value >= 1)}" 2>/dev/null; then echo "High"; return; fi
                if awk "BEGIN{exit !($value >= 0.25)}" 2>/dev/null; then echo "Medium"; return; fi
                echo "Low" ;;
            cycle_time)
                [[ "$value" -lt 3600 ]] && echo "Elite" && return
                [[ "$value" -lt 86400 ]] && echo "High" && return
                [[ "$value" -lt 604800 ]] && echo "Medium" && return
                echo "Low" ;;
            cfr)
                if awk "BEGIN{exit !($value < 5)}" 2>/dev/null; then echo "Elite"; return; fi
                if awk "BEGIN{exit !($value < 10)}" 2>/dev/null; then echo "High"; return; fi
                if awk "BEGIN{exit !($value < 15)}" 2>/dev/null; then echo "Medium"; return; fi
                echo "Low" ;;
            mttr)
                [[ "$value" -lt 3600 ]] && echo "Elite" && return
                [[ "$value" -lt 86400 ]] && echo "High" && return
                echo "Medium" ;;
        esac
    }

    local df_grade ct_grade cfr_grade mttr_grade
    df_grade=$(dora_grade deploy_freq "${deploy_freq:-0}")
    ct_grade=$(dora_grade cycle_time "${cycle_time_median:-0}")
    cfr_grade=$(dora_grade cfr "${cfr:-0}")
    mttr_grade=$(dora_grade mttr "${mttr:-0}")

    grade_icon() {
        case "$1" in
            Elite)  echo "${GREEN}★${RESET}" ;;
            High)   echo "${CYAN}●${RESET}" ;;
            Medium) echo "${YELLOW}◐${RESET}" ;;
            Low)    echo "${RED}○${RESET}" ;;
        esac
    }

    # ── JSON Output ──
    if [[ "$json_output" == "true" ]]; then
        jq -n \
            --arg period "${period_days}d" \
            --argjson deploy_freq "${deploy_freq:-0}" \
            --argjson cycle_time_median "${cycle_time_median:-0}" \
            --argjson cycle_time_p95 "${cycle_time_p95:-0}" \
            --arg cfr "$cfr" \
            --argjson mttr "${mttr:-0}" \
            --arg df_grade "$df_grade" \
            --arg ct_grade "$ct_grade" \
            --arg cfr_grade "$cfr_grade" \
            --arg mttr_grade "$mttr_grade" \
            --argjson total_completed "$total_completed" \
            --argjson successes "$successes" \
            --argjson failures "$failures" \
            --arg first_pass_pct "$first_pass_pct" \
            --arg avg_cycles "${avg_cycles:-0}" \
            --argjson issues_processed "$issues_processed" \
            --argjson daemon_spawns "$daemon_spawns" \
            --arg autonomy_pct "$autonomy_pct" \
            --argjson patrol_runs "$patrol_runs" \
            --argjson patrol_findings "$patrol_findings" \
            --argjson patrol_issues_created "$patrol_issues_created" \
            --argjson patrol_auto_resolved "${patrol_auto_resolved:-0}" \
            '{
                period: $period,
                dora: {
                    deploy_frequency: { value: $deploy_freq, unit: "PRs/week", grade: $df_grade },
                    cycle_time: { median_s: $cycle_time_median, p95_s: $cycle_time_p95, grade: $ct_grade },
                    change_failure_rate: { pct: ($cfr | tonumber), grade: $cfr_grade },
                    mttr: { avg_s: $mttr, grade: $mttr_grade }
                },
                effectiveness: {
                    first_pass_pct: ($first_pass_pct | tonumber),
                    avg_compound_cycles: ($avg_cycles | tonumber)
                },
                throughput: {
                    issues_processed: $issues_processed,
                    pipelines_completed: $total_completed,
                    successes: $successes,
                    failures: $failures
                },
                autonomy: {
                    daemon_spawns: $daemon_spawns,
                    autonomy_pct: ($autonomy_pct | tonumber)
                },
                patrol: {
                    patrols_run: $patrol_runs,
                    findings: $patrol_findings,
                    issues_created: $patrol_issues_created,
                    auto_resolved: $patrol_auto_resolved
                }
            }'
        return 0
    fi

    # ── Dashboard Output ──
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Autonomous Team Metrics ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Period: last ${period_days} day(s)    ${DIM}$(now_iso)${RESET}"
    echo ""

    echo -e "${BOLD}  DORA FOUR KEYS${RESET}"
    echo -e "    Deploy Frequency    ${deploy_freq:-0} PRs/week          $(grade_icon "$df_grade") $df_grade"
    echo -e "    Cycle Time (median) $(format_duration "${cycle_time_median:-0}")              $(grade_icon "$ct_grade") $ct_grade"
    echo -e "    Change Failure      ${cfr}%  (${failures}/${total_completed})             $(grade_icon "$cfr_grade") $cfr_grade"
    echo -e "    MTTR                $(format_duration "${mttr:-0}")              $(grade_icon "$mttr_grade") $mttr_grade"
    echo ""

    echo -e "${BOLD}  EFFECTIVENESS${RESET}"
    echo -e "    First-pass quality  ${first_pass_pct}%  (${first_pass_success}/${first_pass_total})"
    echo -e "    Compound cycles avg ${avg_cycles:-0}"
    echo ""

    echo -e "${BOLD}  THROUGHPUT${RESET}"
    echo -e "    Issues processed    ${issues_processed}"
    echo -e "    Pipelines completed ${total_completed}  (${GREEN}${successes} passed${RESET}, ${RED}${failures} failed${RESET})"
    echo ""

    # Stage breakdown
    local stage_count
    stage_count=$(echo "$avg_stage_timings" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$stage_count" -gt 0 ]]; then
        echo -e "${BOLD}  STAGE TIMINGS (avg)${RESET}"
        echo "$avg_stage_timings" | jq -r '.[] | "    \(.stage)\t\(.avg)s"' 2>/dev/null | \
            while IFS=$'\t' read -r stage dur; do
                printf "    %-20s %s\n" "$stage" "$(format_duration "${dur%s}")"
            done
        echo ""
    fi

    echo -e "${BOLD}  AUTONOMY${RESET}"
    echo -e "    Daemon-spawned      ${daemon_spawns} pipeline(s)"
    if [[ "$daemon_reaps" -gt 0 ]]; then
        echo -e "    Success rate        ${autonomy_pct}%  (${daemon_success}/${daemon_reaps})"
    fi
    echo ""

    echo -e "${BOLD}  PATROL${RESET}"
    echo -e "    Patrols run         ${patrol_runs}"
    echo -e "    Findings            ${patrol_findings}"
    echo -e "    Issues created      ${patrol_issues_created}"
    echo -e "    Auto-resolved       ${patrol_auto_resolved:-0}"
    echo ""

    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ─── Command Router ─────────────────────────────────────────────────────────

setup_dirs

case "$SUBCOMMAND" in
    start)
        daemon_start
        ;;
    stop)
        daemon_stop
        ;;
    status)
        daemon_status
        ;;
    init)
        daemon_init
        ;;
    logs)
        daemon_logs
        ;;
    metrics)
        daemon_metrics "$@"
        ;;
    triage)
        daemon_triage_show "$@"
        ;;
    patrol)
        daemon_patrol "$@"
        ;;
    test)
        exec "$SCRIPT_DIR/sw-daemon-test.sh" "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        error "Unknown command: ${SUBCOMMAND}"
        echo ""
        show_help
        exit 1
        ;;
esac
