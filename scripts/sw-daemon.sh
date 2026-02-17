#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright daemon — Autonomous GitHub Issue Watcher                          ║
# ║  Polls for labeled issues · Spawns pipelines · Manages worktrees      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# Allow spawning Claude CLI from within a Claude Code session (daemon, fleet, etc.)
unset CLAUDECODE 2>/dev/null || true

VERSION="2.3.0"
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

# Policy (config/policy.json) — daemon defaults when daemon-config.json missing or silent
[[ -f "$SCRIPT_DIR/lib/policy.sh" ]] && source "$SCRIPT_DIR/lib/policy.sh"
# Daemon health timeouts from policy (lib/daemon-health.sh)
[[ -f "$SCRIPT_DIR/lib/daemon-health.sh" ]] && source "$SCRIPT_DIR/lib/daemon-health.sh"
# shellcheck source=lib/daemon-state.sh
[[ -f "$SCRIPT_DIR/lib/daemon-state.sh" ]] && source "$SCRIPT_DIR/lib/daemon-state.sh"
# shellcheck source=lib/daemon-adaptive.sh
[[ -f "$SCRIPT_DIR/lib/daemon-adaptive.sh" ]] && source "$SCRIPT_DIR/lib/daemon-adaptive.sh"
# shellcheck source=lib/daemon-triage.sh
[[ -f "$SCRIPT_DIR/lib/daemon-triage.sh" ]] && source "$SCRIPT_DIR/lib/daemon-triage.sh"
# shellcheck source=lib/daemon-failure.sh
[[ -f "$SCRIPT_DIR/lib/daemon-failure.sh" ]] && source "$SCRIPT_DIR/lib/daemon-failure.sh"
# shellcheck source=lib/daemon-dispatch.sh
[[ -f "$SCRIPT_DIR/lib/daemon-dispatch.sh" ]] && source "$SCRIPT_DIR/lib/daemon-dispatch.sh"
# shellcheck source=lib/daemon-patrol.sh
[[ -f "$SCRIPT_DIR/lib/daemon-patrol.sh" ]] && source "$SCRIPT_DIR/lib/daemon-patrol.sh"
# shellcheck source=lib/daemon-poll.sh
[[ -f "$SCRIPT_DIR/lib/daemon-poll.sh" ]] && source "$SCRIPT_DIR/lib/daemon-poll.sh"

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

# Config defaults (overridden by daemon-config.json; policy overrides when present)
WATCH_LABEL="ready-to-build"
POLL_INTERVAL=60
if type policy_get &>/dev/null 2>&1; then
    POLL_INTERVAL=$(policy_get ".daemon.poll_interval_seconds" "60")
fi
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

# Auto-scaling defaults (policy overrides when present)
AUTO_SCALE=false
AUTO_SCALE_INTERVAL=5
if type policy_get &>/dev/null 2>&1; then
    AUTO_SCALE_INTERVAL=$(policy_get ".daemon.auto_scale_interval_cycles" "5")
fi
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
    echo -e "${DIM}Docs: $(_sw_docs_url)  |  GitHub: $(_sw_github_url)${RESET}"
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
    POLL_INTERVAL=$(jq -r '.poll_interval // '"$(type policy_get &>/dev/null 2>&1 && policy_get ".daemon.poll_interval_seconds" "60" || echo "60")"'' "$config_file")
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
    OPTIMIZE_INTERVAL=$(jq -r '.optimize_interval // '"$(type policy_get &>/dev/null 2>&1 && policy_get ".daemon.optimize_interval_cycles" "10" || echo "10")"'' "$config_file")

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
    STALE_REAPER_INTERVAL=$(jq -r '.stale_reaper_interval // '"$(type policy_get &>/dev/null 2>&1 && policy_get ".daemon.stale_reaper_interval_cycles" "10" || echo "10")"'' "$config_file")
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
    AUTO_SCALE_INTERVAL=$(jq -r '.auto_scale_interval // '"$(type policy_get &>/dev/null 2>&1 && policy_get ".daemon.auto_scale_interval_cycles" "5" || echo "5")"'' "$config_file")
    MAX_WORKERS=$(jq -r '.max_workers // 8' "$config_file")
    MIN_WORKERS=$(jq -r '.min_workers // 1' "$config_file")
    WORKER_MEM_GB=$(jq -r '.worker_mem_gb // 4' "$config_file")
    EST_COST_PER_JOB=$(jq -r '.estimated_cost_per_job_usd // 5.0' "$config_file")

    # heartbeat + checkpoint recovery (policy fallback when config silent)
    HEALTH_HEARTBEAT_TIMEOUT=$(jq -r '.health.heartbeat_timeout_s // '"$(type policy_get &>/dev/null 2>&1 && policy_get ".daemon.health_heartbeat_timeout" "120" || echo "120")"'' "$config_file")
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

    # Enter poll loop with watchdog self-restart on unexpected exit
    local _watchdog_restarts=0
    local _watchdog_max=${WATCHDOG_MAX_RESTARTS:-5}
    local _watchdog_backoff=5

    while true; do
        daemon_poll_loop || true  # poll_loop only returns on shutdown or crash

        # If shutdown was requested, exit cleanly
        if [[ -f "$SHUTDOWN_FLAG" ]]; then
            daemon_log INFO "Poll loop exited due to shutdown flag"
            break
        fi

        # Unexpected exit — attempt watchdog restart
        _watchdog_restarts=$((_watchdog_restarts + 1))
        if [[ "$_watchdog_restarts" -gt "$_watchdog_max" ]]; then
            daemon_log ERROR "Watchdog: exceeded max restarts ($_watchdog_max) — giving up"
            emit_event "daemon.watchdog_exhausted" "restarts=$_watchdog_restarts"
            break
        fi

        daemon_log WARN "Watchdog: poll loop exited unexpectedly — restart #${_watchdog_restarts}/${_watchdog_max} in ${_watchdog_backoff}s"
        emit_event "daemon.watchdog_restart" "restart=$_watchdog_restarts" "backoff=$_watchdog_backoff"

        sleep "$_watchdog_backoff" || true
        _watchdog_backoff=$((_watchdog_backoff * 2))
        [[ "$_watchdog_backoff" -gt 300 ]] && _watchdog_backoff=300

        # Re-validate state before restarting
        if [[ -f "$STATE_FILE" ]]; then
            if ! jq '.' "$STATE_FILE" >/dev/null 2>&1; then
                daemon_log WARN "Watchdog: state file corrupt — recovering from backup"
                type validate_json &>/dev/null 2>&1 && validate_json "$STATE_FILE" || true
            fi
        fi
    done
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
