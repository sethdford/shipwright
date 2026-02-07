#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  cct daemon — Autonomous GitHub Issue Watcher                          ║
# ║  Polls for labeled issues · Spawns pipelines · Manages worktrees      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="1.5.1"
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
EVENTS_FILE="${HOME}/.claude-teams/events.jsonl"

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
            val="${val//\"/\\\"}"
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.claude-teams"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Defaults ───────────────────────────────────────────────────────────────
DAEMON_DIR="$HOME/.claude-teams"
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
    echo -e "${CYAN}${BOLD}cct daemon${RESET} ${DIM}v${VERSION}${RESET} — Autonomous GitHub Issue Watcher"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}cct daemon${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}start${RESET}    [--config path] [--detach]   Start the issue watcher"
    echo -e "  ${CYAN}stop${RESET}                                  Graceful shutdown via PID file"
    echo -e "  ${CYAN}status${RESET}                                Show active pipelines and queue"
    echo -e "  ${CYAN}init${RESET}                                  Generate default daemon-config.json"
    echo -e "  ${CYAN}logs${RESET}     [--follow]                   Tail daemon activity log"
    echo -e "  ${CYAN}metrics${RESET}  [--period N] [--json]        DORA/DX metrics dashboard"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--config${RESET} <path>   Path to daemon-config.json ${DIM}(default: .claude/daemon-config.json)${RESET}"
    echo -e "  ${CYAN}--detach${RESET}, ${CYAN}-d${RESET}     Run in a detached tmux session"
    echo -e "  ${CYAN}--follow${RESET}, ${CYAN}-f${RESET}     Follow log output (with ${CYAN}logs${RESET} command)"
    echo -e "  ${CYAN}--no-github${RESET}       Disable GitHub API calls (dry-run mode)"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}cct daemon init${RESET}                        # Generate config file"
    echo -e "  ${DIM}cct daemon start${RESET}                       # Start watching in foreground"
    echo -e "  ${DIM}cct daemon start --detach${RESET}               # Start in background tmux session"
    echo -e "  ${DIM}cct daemon start --config my-config.json${RESET} # Custom config"
    echo -e "  ${DIM}cct daemon status${RESET}                      # Show active jobs and queue"
    echo -e "  ${DIM}cct daemon stop${RESET}                        # Graceful shutdown"
    echo -e "  ${DIM}cct daemon logs --follow${RESET}               # Tail the daemon log"
    echo -e "  ${DIM}cct daemon metrics${RESET}                     # DORA + DX metrics (last 7 days)"
    echo -e "  ${DIM}cct daemon metrics --period 30${RESET}         # Last 30 days"
    echo -e "  ${DIM}cct daemon metrics --json${RESET}              # JSON output for dashboards"
    echo ""
    echo -e "${BOLD}CONFIG FILE${RESET}  ${DIM}(.claude/daemon-config.json)${RESET}"
    echo -e "  ${DIM}watch_label${RESET}       GitHub label to watch for       ${DIM}(default: ready-to-build)${RESET}"
    echo -e "  ${DIM}poll_interval${RESET}     Seconds between polls           ${DIM}(default: 60)${RESET}"
    echo -e "  ${DIM}max_parallel${RESET}      Max concurrent pipeline jobs    ${DIM}(default: 2)${RESET}"
    echo -e "  ${DIM}pipeline_template${RESET} Pipeline template to use        ${DIM}(default: autonomous)${RESET}"
    echo -e "  ${DIM}base_branch${RESET}       Branch to create worktrees from ${DIM}(default: main)${RESET}"
    echo ""
    echo -e "${BOLD}HOW IT WORKS${RESET}"
    echo -e "  1. Polls GitHub for issues with the ${CYAN}${WATCH_LABEL}${RESET} label"
    echo -e "  2. For each new issue, creates a git worktree and spawns a pipeline"
    echo -e "  3. On success: removes label, adds ${GREEN}pipeline/complete${RESET}, comments on issue"
    echo -e "  4. On failure: adds ${RED}pipeline/failed${RESET}, comments with log tail"
    echo -e "  5. Respects ${CYAN}max_parallel${RESET} limit — excess issues are queued"
    echo ""
    echo -e "${DIM}Docs: https://sethdford.github.io/shipwright  |  GitHub: https://github.com/sethdford/shipwright${RESET}"
}

# ─── Config Loading ─────────────────────────────────────────────────────────

load_config() {
    local config_file="${CONFIG_PATH:-.claude/daemon-config.json}"

    if [[ ! -f "$config_file" ]]; then
        warn "Config not found at $config_file — using defaults"
        warn "Run ${CYAN}cct daemon init${RESET} to generate a config file"
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

    success "Config loaded"
}

# ─── Directory Setup ────────────────────────────────────────────────────────

setup_dirs() {
    mkdir -p "$DAEMON_DIR"

    STATE_FILE="$DAEMON_DIR/daemon-state.json"
    LOG_FILE="$DAEMON_DIR/daemon.log"
    LOG_DIR="$DAEMON_DIR/logs"
    WORKTREE_DIR=".worktrees"

    mkdir -p "$LOG_DIR"
}

# ─── Logging ─────────────────────────────────────────────────────────────────

daemon_log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(now_iso)
    echo "[$ts] [$level] $msg" >> "$LOG_FILE"

    # Also print to stdout
    case "$level" in
        INFO)    info "$msg" ;;
        SUCCESS) success "$msg" ;;
        WARN)    warn "$msg" ;;
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

    # Custom webhook (env var CCT_WEBHOOK_URL)
    if [[ -n "${CCT_WEBHOOK_URL:-}" ]]; then
        local payload
        payload=$(jq -n \
            --arg title "$title" --arg message "$message" \
            --arg level "$level" \
            '{title:$title, message:$message, level:$level}')
        curl -sf -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$CCT_WEBHOOK_URL" >/dev/null 2>&1 || true
    fi
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
    if [[ -x "$SCRIPT_DIR/cct-pipeline.sh" ]]; then
        echo -e "  ${GREEN}✓${RESET} cct-pipeline.sh available"
    else
        echo -e "  ${RED}✗${RESET} cct-pipeline.sh not found at $SCRIPT_DIR"
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

# Atomic write: write to tmp file, then mv (prevents corruption on crash)
atomic_write_state() {
    local content="$1"
    local tmp_file="${STATE_FILE}.tmp.$$"
    echo "$content" > "$tmp_file"
    mv "$tmp_file" "$STATE_FILE"
}

init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        jq -n \
            --arg pid "$$" \
            --arg started "$(now_iso)" \
            --argjson interval "$POLL_INTERVAL" \
            --argjson max_parallel "$MAX_PARALLEL" \
            --arg label "$WATCH_LABEL" \
            '{
                version: 1,
                pid: ($pid | tonumber),
                started_at: $started,
                last_poll: null,
                config: {
                    poll_interval: $interval,
                    max_parallel: $max_parallel,
                    watch_label: $label
                },
                active_jobs: [],
                queued: [],
                completed: []
            }' > "$STATE_FILE"
    else
        # Update PID and start time in existing state
        local tmp
        tmp=$(jq \
            --arg pid "$$" \
            --arg started "$(now_iso)" \
            '.pid = ($pid | tonumber) | .started_at = $started' \
            "$STATE_FILE")
        atomic_write_state "$tmp"
    fi
}

update_state_field() {
    local field="$1" value="$2"
    local tmp
    tmp=$(jq --arg val "$value" ".${field} = \$val" "$STATE_FILE")
    atomic_write_state "$tmp"
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

# ─── Queue Management ───────────────────────────────────────────────────────

enqueue_issue() {
    local issue_num="$1"
    local tmp
    tmp=$(jq --argjson num "$issue_num" \
        '.queued += [$num] | .queued |= unique' \
        "$STATE_FILE")
    atomic_write_state "$tmp"
    daemon_log INFO "Queued issue #${issue_num} (at capacity)"
}

dequeue_next() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return
    fi

    local next
    next=$(jq -r '.queued[0] // empty' "$STATE_FILE" 2>/dev/null || true)
    if [[ -n "$next" ]]; then
        # Remove from queue
        local tmp
        tmp=$(jq '.queued = .queued[1:]' "$STATE_FILE")
        atomic_write_state "$tmp"
        echo "$next"
    fi
}

# ─── Spawn Pipeline ─────────────────────────────────────────────────────────

daemon_spawn_pipeline() {
    local issue_num="$1"
    local issue_title="${2:-}"

    daemon_log INFO "Spawning pipeline for issue #${issue_num}: ${issue_title}"

    # Check disk space before spawning
    local free_space_kb
    free_space_kb=$(df -k "." 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$free_space_kb" ]] && [[ "$free_space_kb" -lt 1048576 ]] 2>/dev/null; then
        daemon_log WARN "Low disk space ($(( free_space_kb / 1024 ))MB) — skipping issue #${issue_num}"
        return 1
    fi

    # Create worktree
    local worktree_path="${WORKTREE_DIR}/daemon-issue-${issue_num}"
    local branch_name="daemon/issue-${issue_num}"

    # Clean up stale worktree if it exists
    if [[ -d "$worktree_path" ]]; then
        git worktree remove "$worktree_path" --force 2>/dev/null || true
    fi
    git branch -D "$branch_name" 2>/dev/null || true

    if ! git worktree add "$worktree_path" -b "$branch_name" "$BASE_BRANCH" 2>/dev/null; then
        daemon_log ERROR "Failed to create worktree for issue #${issue_num}"
        return 1
    fi

    daemon_log INFO "Worktree created at ${worktree_path}"

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

    # Run pipeline in worktree (background)
    (
        cd "$worktree_path"
        "$SCRIPT_DIR/cct-pipeline.sh" "${pipeline_args[@]}"
    ) > "$LOG_DIR/issue-${issue_num}.log" 2>&1 &
    local pid=$!

    daemon_log INFO "Pipeline started for issue #${issue_num} (PID: ${pid})"

    # Track the job
    daemon_track_job "$issue_num" "$pid" "$worktree_path" "$issue_title"
    emit_event "daemon.spawn" "issue=$issue_num" "pid=$pid"

    # Comment on the issue
    if [[ "$NO_GITHUB" != "true" ]]; then
        gh issue comment "$issue_num" --body "## 🤖 Pipeline Started

**Daemon** picked up this issue and started an autonomous pipeline.

| Field | Value |
|-------|-------|
| Template | \`${PIPELINE_TEMPLATE}\` |
| Branch | \`${branch_name}\` |
| Started | $(now_iso) |

_Progress updates will be posted as the pipeline advances._" 2>/dev/null || true
    fi
}

# ─── Track Job ───────────────────────────────────────────────────────────────

daemon_track_job() {
    local issue_num="$1" pid="$2" worktree="$3" title="${4:-}"
    local tmp
    tmp=$(jq \
        --argjson num "$issue_num" \
        --argjson pid "$pid" \
        --arg wt "$worktree" \
        --arg title "$title" \
        --arg started "$(now_iso)" \
        '.active_jobs += [{
            issue: $num,
            pid: $pid,
            worktree: $wt,
            title: $title,
            started_at: $started
        }]' \
        "$STATE_FILE")
    atomic_write_state "$tmp"
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

    while IFS= read -r job; do
        local issue_num pid worktree
        issue_num=$(echo "$job" | jq -r '.issue')
        pid=$(echo "$job" | jq -r '.pid')
        worktree=$(echo "$job" | jq -r '.worktree')

        # Check if process is still running
        if kill -0 "$pid" 2>/dev/null; then
            continue
        fi

        # Process is dead — determine exit code
        local exit_code=0
        wait "$pid" 2>/dev/null || exit_code=$?

        local started_at duration_str=""
        started_at=$(echo "$job" | jq -r '.started_at // empty')
        if [[ -n "$started_at" ]]; then
            local start_epoch end_epoch
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

        if [[ "$exit_code" -eq 0 ]]; then
            daemon_on_success "$issue_num" "$duration_str"
        else
            daemon_on_failure "$issue_num" "$exit_code" "$duration_str"
        fi

        # Remove from active_jobs
        local tmp
        tmp=$(jq --argjson num "$issue_num" \
            '.active_jobs = [.active_jobs[] | select(.issue != $num)]' \
            "$STATE_FILE")
        atomic_write_state "$tmp"

        # Clean up worktree
        if [[ -d "$worktree" ]]; then
            git worktree remove "$worktree" --force 2>/dev/null || true
            daemon_log INFO "Cleaned worktree: $worktree"
        fi
        git branch -D "daemon/issue-${issue_num}" 2>/dev/null || true

        # Dequeue next issue if available
        local next_issue
        next_issue=$(dequeue_next)
        if [[ -n "$next_issue" ]]; then
            daemon_log INFO "Dequeuing issue #${next_issue}"
            daemon_spawn_pipeline "$next_issue"
        fi
    done <<< "$jobs"
}

# ─── Success Handler ────────────────────────────────────────────────────────

daemon_on_success() {
    local issue_num="$1" duration="${2:-}"

    daemon_log SUCCESS "Pipeline completed for issue #${issue_num} (${duration:-unknown})"

    # Record in completed list
    local tmp
    tmp=$(jq \
        --argjson num "$issue_num" \
        --arg result "success" \
        --arg dur "${duration:-unknown}" \
        --arg completed_at "$(now_iso)" \
        '.completed += [{
            issue: $num,
            result: $result,
            duration: $dur,
            completed_at: $completed_at
        }]' \
        "$STATE_FILE")
    atomic_write_state "$tmp"

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
}

# ─── Failure Handler ────────────────────────────────────────────────────────

daemon_on_failure() {
    local issue_num="$1" exit_code="${2:-1}" duration="${3:-}"

    daemon_log ERROR "Pipeline failed for issue #${issue_num} (exit: ${exit_code}, ${duration:-unknown})"

    # Record in completed list
    local tmp
    tmp=$(jq \
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
        }]' \
        "$STATE_FILE")
    atomic_write_state "$tmp"

    if [[ "$NO_GITHUB" != "true" ]]; then
        # Add failure label
        gh issue edit "$issue_num" \
            --add-label "$ON_FAILURE_ADD_LABEL" 2>/dev/null || true

        # Comment with log tail
        local log_tail=""
        local log_path="$LOG_DIR/issue-${issue_num}.log"
        if [[ -f "$log_path" ]]; then
            log_tail=$(tail -"$ON_FAILURE_LOG_LINES" "$log_path" 2>/dev/null || true)
        fi

        gh issue comment "$issue_num" --body "## ❌ Pipeline Failed

The autonomous pipeline encountered an error.

| Field | Value |
|-------|-------|
| Exit Code | ${exit_code} |
| Duration | ${duration:-unknown} |
| Failed At | $(now_iso) |

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
}

# ─── Poll Issues ─────────────────────────────────────────────────────────────

daemon_poll_issues() {
    if [[ "$NO_GITHUB" == "true" ]]; then
        daemon_log INFO "Polling skipped (--no-github)"
        return
    fi

    local issues_json
    issues_json=$(gh issue list \
        --label "$WATCH_LABEL" \
        --state open \
        --json number,title,labels \
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
        sleep "$BACKOFF_SECS"
        return
    }

    # Reset backoff on success
    BACKOFF_SECS=0

    local issue_count
    issue_count=$(echo "$issues_json" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$issue_count" -eq 0 ]]; then
        return
    fi

    daemon_log INFO "Found ${issue_count} issue(s) with label '${WATCH_LABEL}'"
    emit_event "daemon.poll" "issues_found=$issue_count" "active=$(get_active_count)"

    # Sort by priority labels
    local priority_labels="${PRIORITY_LABELS:-urgent,p0,high,p1,normal,p2,low,p3}"
    issues_json=$(echo "$issues_json" | jq --arg plist "$priority_labels" '
        ($plist | split(",")) as $priorities |
        sort_by(
            [.labels[].name] as $issue_labels |
            ($priorities | to_entries | map(select(.value as $p | $issue_labels | any(. == $p))) | if length > 0 then .[0].key else 999 end)
        )
    ')

    local active_count
    active_count=$(get_active_count)

    # Process each issue (process substitution keeps state changes in current shell)
    while IFS= read -r issue; do
        local issue_num issue_title
        issue_num=$(echo "$issue" | jq -r '.number')
        issue_title=$(echo "$issue" | jq -r '.title')

        # Skip if already inflight
        if daemon_is_inflight "$issue_num"; then
            continue
        fi

        # Check capacity
        active_count=$(get_active_count)
        if [[ "$active_count" -ge "$MAX_PARALLEL" ]]; then
            enqueue_issue "$issue_num"
            continue
        fi

        # Spawn pipeline
        daemon_spawn_pipeline "$issue_num" "$issue_title"
    done < <(echo "$issues_json" | jq -c '.[]')

    # Update last poll
    update_state_field "last_poll" "$(now_iso)"
}

# ─── Health Check ─────────────────────────────────────────────────────────────

daemon_health_check() {
    local findings=0

    # Stale jobs: kill processes running > timeout
    local stale_timeout="${HEALTH_STALE_TIMEOUT:-1800}"  # default 30min
    local now_e
    now_e=$(now_epoch)

    if [[ -f "$STATE_FILE" ]]; then
        while IFS= read -r job; do
            local pid started_at issue_num
            pid=$(echo "$job" | jq -r '.pid')
            started_at=$(echo "$job" | jq -r '.started_at // empty')
            issue_num=$(echo "$job" | jq -r '.issue')

            if [[ -n "$started_at" ]]; then
                local start_e
                start_e=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || date -d "$started_at" +%s 2>/dev/null || echo "0")
                local elapsed=$(( now_e - start_e ))
                if [[ "$elapsed" -gt "$stale_timeout" ]] && kill -0 "$pid" 2>/dev/null; then
                    daemon_log WARN "Stale job detected: issue #${issue_num} (${elapsed}s, PID $pid) — killing"
                    kill "$pid" 2>/dev/null || true
                    findings=$((findings + 1))
                fi
            fi
        done < <(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null)
    fi

    # Disk space warning
    local free_kb
    free_kb=$(df -k "." 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$free_kb" ]] && [[ "$free_kb" -lt 1048576 ]] 2>/dev/null; then
        daemon_log WARN "Low disk space: $(( free_kb / 1024 ))MB free"
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
    local cfr_pct=$(( failures * 100 / count ))
    local success_pct=$(( successes * 100 / count ))

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

# ─── Poll Loop ───────────────────────────────────────────────────────────────

POLL_CYCLE_COUNT=0

daemon_poll_loop() {
    daemon_log INFO "Entering poll loop (interval: ${POLL_INTERVAL}s, max_parallel: ${MAX_PARALLEL})"
    daemon_log INFO "Watching for label: ${CYAN}${WATCH_LABEL}${RESET}"

    while [[ ! -f "$SHUTDOWN_FLAG" ]]; do
        daemon_poll_issues
        daemon_reap_completed
        daemon_health_check

        # Check degradation every 5 poll cycles
        POLL_CYCLE_COUNT=$((POLL_CYCLE_COUNT + 1))
        if [[ $((POLL_CYCLE_COUNT % 5)) -eq 0 ]]; then
            daemon_check_degradation
        fi

        # Sleep in 1s intervals so we can catch shutdown quickly
        local i=0
        while [[ $i -lt $POLL_INTERVAL ]] && [[ ! -f "$SHUTDOWN_FLAG" ]]; do
            sleep 1
            i=$((i + 1))
        done
    done

    daemon_log INFO "Shutdown flag detected — exiting poll loop"
}

# ─── Graceful Shutdown Handler ───────────────────────────────────────────────

cleanup_on_exit() {
    daemon_log INFO "Cleaning up..."
    rm -f "$PID_FILE" "$SHUTDOWN_FLAG"
    daemon_log INFO "Daemon stopped"
    emit_event "daemon.stopped" "pid=$$"
}

# ─── daemon start ───────────────────────────────────────────────────────────

daemon_start() {
    echo -e "${PURPLE}${BOLD}━━━ cct daemon v${VERSION} ━━━${RESET}"
    echo ""

    # Acquire exclusive lock on PID file (prevents race between concurrent starts)
    exec 9>"$PID_FILE"
    if ! flock -n 9 2>/dev/null; then
        # flock unavailable or lock held — fall back to PID check
        local existing_pid
        existing_pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            error "Daemon already running (PID: ${existing_pid})"
            info "Use ${CYAN}cct daemon stop${RESET} to stop it first"
            exit 1
        else
            warn "Stale PID file found — removing"
            rm -f "$PID_FILE"
            exec 9>"$PID_FILE"
        fi
    fi

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

        info "Starting daemon in detached tmux session: ${CYAN}cct-daemon${RESET}"

        # Build the command to run in tmux
        local cmd_args=("$SCRIPT_DIR/cct-daemon.sh" "start")
        if [[ -n "$CONFIG_PATH" ]]; then
            cmd_args+=("--config" "$CONFIG_PATH")
        fi
        if [[ "$NO_GITHUB" == "true" ]]; then
            cmd_args+=("--no-github")
        fi

        tmux new-session -d -s "cct-daemon" "${cmd_args[*]}" 2>/dev/null || {
            # Session may already exist — try killing and recreating
            tmux kill-session -t "cct-daemon" 2>/dev/null || true
            tmux new-session -d -s "cct-daemon" "${cmd_args[*]}"
        }

        success "Daemon started in tmux session ${CYAN}cct-daemon${RESET}"
        info "Attach with: ${DIM}tmux attach -t cct-daemon${RESET}"
        info "View logs:   ${DIM}cct daemon logs --follow${RESET}"
        return 0
    fi

    # Foreground mode
    info "Starting daemon (PID: $$)"

    # Write PID file
    echo "$$" > "$PID_FILE"

    # Remove stale shutdown flag
    rm -f "$SHUTDOWN_FLAG"

    # Initialize state
    init_state

    # Trap signals for graceful shutdown
    trap cleanup_on_exit EXIT
    trap 'touch "$SHUTDOWN_FLAG"' SIGINT SIGTERM

    # Reap any orphaned jobs from previous runs
    daemon_reap_completed

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
    tmux kill-session -t "cct-daemon" 2>/dev/null || true

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
  }
}
CONFIGEOF

    success "Generated config: ${config_file}"
    echo ""
    echo -e "${DIM}Edit this file to customize the daemon behavior, then run:${RESET}"
    echo -e "  ${CYAN}cct daemon start${RESET}"
}

# ─── daemon logs ─────────────────────────────────────────────────────────────

daemon_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        warn "No log file found at $LOG_FILE"
        info "Start the daemon first with ${CYAN}cct daemon start${RESET}"
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
        info "Events are generated when running ${CYAN}cct pipeline${RESET} or ${CYAN}cct daemon${RESET}"
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
    test)
        exec "$SCRIPT_DIR/cct-daemon-test.sh" "$@"
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
