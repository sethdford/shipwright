# daemon-state.sh — State, queue, claim (for sw-daemon.sh)
# Source from sw-daemon.sh. Requires STATE_FILE, helpers.
[[ -n "${_DAEMON_STATE_LOADED:-}" ]] && return 0
_DAEMON_STATE_LOADED=1

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

    # Custom webhook (env var SHIPWRIGHT_WEBHOOK_URL)
    local _webhook_url="${SHIPWRIGHT_WEBHOOK_URL:-}"
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
