#!/usr/bin/env bash
# Module: pipeline-util
# Utility functions: coverage parsing, cost estimation, notifications, error classification
set -euo pipefail

# Agents run without GitHub credentials (#8614): claude is launched through agent-exec.sh.
SW_AGENT_EXEC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-exec.sh"

# Module guard
[[ -n "${_MODULE_PIPELINE_UTIL_LOADED:-}" ]] && return 0; _MODULE_PIPELINE_UTIL_LOADED=1

# ─── Defaults (needed if sourced independently) ──────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="${STATE_DIR:-$PROJECT_ROOT/.claude}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/pipeline-state.md}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$STATE_DIR/pipeline-artifacts}"
EVENTS_FILE="${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}"

# Variables referenced by util functions (set by sw-pipeline.sh, defaults here for safety)
HEARTBEAT_PID="${HEARTBEAT_PID:-}"
PIPELINE_STATUS="${PIPELINE_STATUS:-}"
STASHED_CHANGES="${STASHED_CHANGES:-false}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
CURRENT_STAGE_ID="${CURRENT_STAGE_ID:-}"

# Ensure helpers are loaded
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
[[ "$(type -t info 2>/dev/null)" == "function" ]] || info() { echo "$*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]] || warn() { echo "$*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]] || error() { echo "$*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { true; }
[[ "$(type -t now_epoch 2>/dev/null)" == "function" ]] || now_epoch() { date +%s; }

# ─── Coverage Parsing ──────────────────────────────────────────────
parse_coverage_from_output() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return
    local cov=""
    # Jest/Istanbul: "Statements : 85.5%"
    cov=$(grep -oE 'Statements\s*:\s*[0-9.]+' "$log_file" 2>/dev/null | grep -oE '[0-9.]+$' || true)
    # Istanbul table: "All files | 85.5"
    [[ -z "$cov" ]] && cov=$(grep -oE 'All files\s*\|\s*[0-9.]+' "$log_file" 2>/dev/null | grep -oE '[0-9.]+$' || true)
    # pytest-cov: "TOTAL    500    75    85%"
    [[ -z "$cov" ]] && cov=$(grep -oE 'TOTAL\s+[0-9]+\s+[0-9]+\s+[0-9]+%' "$log_file" 2>/dev/null | grep -oE '[0-9]+%' | tr -d '%' | tail -1 || true)
    # Vitest: "All files  |  85.5  |"
    [[ -z "$cov" ]] && cov=$(grep -oE 'All files\s*\|\s*[0-9.]+\s*\|' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | head -1 || true)
    # Go coverage: "coverage: 85.5% of statements"
    [[ -z "$cov" ]] && cov=$(grep -oE 'coverage:\s*[0-9.]+%' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # Cargo tarpaulin: "85.50% coverage"
    [[ -z "$cov" ]] && cov=$(grep -oE '[0-9.]+%\s*coverage' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | head -1 || true)
    # Generic: "Coverage: 85.5%"
    [[ -z "$cov" ]] && cov=$(grep -oiE 'coverage:?\s*[0-9.]+%' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    echo "$cov"
}

# ─── Duration Formatting ───────────────────────────────────────────
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

# ─── Event Log Rotation ────────────────────────────────────────────
rotate_event_log_if_needed() {
    local events_file="${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}"
    local max_lines=10000
    [[ ! -f "$events_file" ]] && return
    local lines
    lines=$(wc -l < "$events_file" 2>/dev/null || true)
    lines="${lines:-0}"
    if [[ "$lines" -gt "$max_lines" ]]; then
        local tmp="${events_file}.rotating"
        if tail -5000 "$events_file" > "$tmp" 2>/dev/null && mv "$tmp" "$events_file" 2>/dev/null; then
            info "Rotated events.jsonl: ${lines} -> 5000 lines"
        fi
    fi
}

# ─── Goal Compaction for Context ───────────────────────────────────
_pipeline_compact_goal() {
    local goal="$1"
    local plan_file="${2:-}"
    local design_file="${3:-}"
    local compact="$goal"

    # Include plan summary (first 20 lines only)
    if [[ -n "$plan_file" && -f "$plan_file" ]]; then
        compact="${compact}

## Plan Summary
$(head -20 "$plan_file" 2>/dev/null || true)
[... full plan in .claude/pipeline-artifacts/plan.md]"
    fi

    # Include design key decisions only (grep for headers)
    if [[ -n "$design_file" && -f "$design_file" ]]; then
        compact="${compact}

## Key Design Decisions
$(grep -E '^#{1,3} ' "$design_file" 2>/dev/null | head -10 || true)
[... full design in .claude/pipeline-artifacts/design.md]"
    fi

    echo "$compact"
}

# ─── Token & Cost Parsing ──────────────────────────────────────────
parse_claude_tokens() {
    local log_file="$1"
    local input_tok output_tok
    input_tok=$(grep -oE 'input[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")
    output_tok=$(grep -oE 'output[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")

    TOTAL_INPUT_TOKENS=$(( TOTAL_INPUT_TOKENS + ${input_tok:-0} ))
    TOTAL_OUTPUT_TOKENS=$(( TOTAL_OUTPUT_TOKENS + ${output_tok:-0} ))
}

# Estimate pipeline cost using historical averages from completed pipelines.
# Falls back to per-stage estimates when no history exists.
estimate_pipeline_cost() {
    local stages="$1"
    local stage_count
    stage_count=$(echo "$stages" | jq 'length' 2>/dev/null || echo "6")
    [[ ! "$stage_count" =~ ^[0-9]+$ ]] && stage_count=6

    local events_file="${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}"
    local avg_input=0 avg_output=0
    if [[ -f "$events_file" ]]; then
        local hist
        hist=$(grep '"type":"pipeline.completed"' "$events_file" 2>/dev/null | tail -10)
        if [[ -n "$hist" ]]; then
            avg_input=$(echo "$hist" | jq -s -r '[.[] | .input_tokens // 0 | tonumber] | if length > 0 then (add / length | floor | tostring) else "0" end' 2>/dev/null | head -1)
            avg_output=$(echo "$hist" | jq -s -r '[.[] | .output_tokens // 0 | tonumber] | if length > 0 then (add / length | floor | tostring) else "0" end' 2>/dev/null | head -1)
        fi
    fi
    [[ ! "$avg_input" =~ ^[0-9]+$ ]] && avg_input=0
    [[ ! "$avg_output" =~ ^[0-9]+$ ]] && avg_output=0

    # Fall back to reasonable per-stage estimates only if no history
    if [[ "$avg_input" -eq 0 ]]; then
        avg_input=$(( stage_count * 8000 ))   # More realistic: ~8K input per stage
        avg_output=$(( stage_count * 4000 ))  # ~4K output per stage
    fi

    echo "{\"input_tokens\":${avg_input},\"output_tokens\":${avg_output}}"
}

# ─── Heartbeat Management ──────────────────────────────────────────
start_heartbeat() {
    local job_id="${PIPELINE_NAME:-pipeline-$$}"
    (
        while true; do
            "$SCRIPT_DIR/sw-heartbeat.sh" write "$job_id" \
                --pid $$ \
                --issue "${ISSUE_NUMBER:-0}" \
                --stage "${CURRENT_STAGE_ID:-unknown}" \
                --iteration "0" \
                --activity "$(get_stage_description "${CURRENT_STAGE_ID:-}" 2>/dev/null || echo "Running pipeline")" 2>/dev/null || true
            sleep "$(_config_get_int "pipeline.heartbeat_interval" 30 2>/dev/null || echo 30)"
        done
    ) >/dev/null 2>&1 &
    HEARTBEAT_PID=$!
}

stop_heartbeat() {
    if [[ -n "${HEARTBEAT_PID:-}" ]]; then
        kill "$HEARTBEAT_PID" 2>/dev/null || true
        wait "$HEARTBEAT_PID" 2>/dev/null || true
        "$SCRIPT_DIR/sw-heartbeat.sh" clear "${PIPELINE_NAME:-pipeline-$$}" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi
}

# ─── CI Integration ────────────────────────────────────────────────
ci_push_partial_work() {
    [[ "${CI_MODE:-false}" != "true" ]] && return 0
    [[ -z "${ISSUE_NUMBER:-}" ]] && return 0

    local branch="shipwright/issue-${ISSUE_NUMBER}"

    # Only push if we have uncommitted changes
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        git add -A 2>/dev/null || true
        git commit -m "WIP: partial pipeline progress for #${ISSUE_NUMBER}" --no-verify 2>/dev/null || true
    fi

    # Push branch (create if needed, force to overwrite previous WIP)
    if ! git push origin "HEAD:refs/heads/$branch" --force 2>/dev/null; then
        warn "git push failed for $branch — remote may be out of sync"
        emit_event "pipeline.push_failed" "branch=$branch"
    fi
}

ci_post_stage_event() {
    [[ "${CI_MODE:-false}" != "true" ]] && return 0
    [[ -z "${ISSUE_NUMBER:-}" ]] && return 0
    [[ "${GH_AVAILABLE:-false}" != "true" ]] && return 0

    local stage="$1" status="$2" elapsed="${3:-0s}"
    local comment="<!-- SHIPWRIGHT-STAGE: ${stage}:${status}:${elapsed} -->"
    _timeout "$(_config_get_int "network.gh_timeout" 30 2>/dev/null || echo 30)" gh issue comment "$ISSUE_NUMBER" --body "$comment" 2>/dev/null || true
}

# ─── Cleanup on Exit ───────────────────────────────────────────────
cleanup_on_exit() {
    [[ "${_cleanup_done:-}" == "true" ]] && return 0
    _cleanup_done=true
    local exit_code=$?

    # Stop heartbeat writer
    stop_heartbeat

    # Save state if we were running
    if [[ "$PIPELINE_STATUS" == "running" && -n "$STATE_FILE" ]]; then
        PIPELINE_STATUS="interrupted"
        UPDATED_AT="$(now_iso)"
        write_state 2>/dev/null || true
        echo ""
        warn "Pipeline interrupted — state saved."
        echo -e "  Resume: ${DIM}shipwright pipeline resume${RESET}"

        # Push partial work in CI mode so retries can pick it up
        ci_push_partial_work
    fi

    # Restore stashed changes
    if [[ "$STASHED_CHANGES" == "true" ]]; then
        git stash pop --quiet 2>/dev/null || true
    fi

    # Release durable pipeline lock
    if [[ -n "${_PIPELINE_LOCK_ID:-}" ]] && type release_lock >/dev/null 2>&1; then
        release_lock "$_PIPELINE_LOCK_ID" 2>/dev/null || true
    fi

    # Cancel lingering in_progress GitHub Check Runs
    pipeline_cancel_check_runs 2>/dev/null || true

    # Update GitHub
    if [[ -n "${ISSUE_NUMBER:-}" && "${GH_AVAILABLE:-false}" == "true" ]]; then
        if ! _timeout "$(_config_get_int "network.gh_timeout" 30 2>/dev/null || echo 30)" gh issue comment "$ISSUE_NUMBER" --body "⏸️ **Pipeline interrupted** at stage: ${CURRENT_STAGE_ID:-unknown}" 2>/dev/null; then
            warn "gh issue comment failed — status update may not have been posted"
            emit_event "pipeline.comment_failed" "issue=$ISSUE_NUMBER"
        fi
    fi

    exit "$exit_code"
}

# ─── Preflight Checks ──────────────────────────────────────────────
preflight_checks() {
    local errors=0

    echo -e "${PURPLE}${BOLD}━━━ Pre-flight Checks ━━━${RESET}"
    echo ""

    # 1. Required tools
    local required_tools=("git" "jq")
    local optional_tools=("gh" "claude" "bc" "curl")

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${RED}✗${RESET} $tool ${RED}(required)${RESET}"
            errors=$((errors + 1))
        fi
    done

    for tool in "${optional_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${DIM}○${RESET} $tool ${DIM}(optional — some features disabled)${RESET}"
        fi
    done

    # 2. Git state
    echo ""
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${RESET} Inside git repo"
    else
        echo -e "  ${RED}✗${RESET} Not inside a git repository"
        errors=$((errors + 1))
    fi

    # Check for uncommitted changes — offer to stash
    local dirty_files
    dirty_files=$(git status --porcelain 2>/dev/null | wc -l | xargs)
    if [[ "$dirty_files" -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠${RESET} $dirty_files uncommitted change(s)"
        if [[ "$SKIP_GATES" == "true" ]]; then
            info "Auto-stashing uncommitted changes..."
            git stash push -m "sw-pipeline: auto-stash before pipeline" --quiet 2>/dev/null && STASHED_CHANGES=true
            if [[ "$STASHED_CHANGES" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Changes stashed (will restore on exit)"
            fi
        else
            echo -e "    ${DIM}Tip: Use --skip-gates to auto-stash, or commit/stash manually${RESET}"
        fi
    else
        echo -e "  ${GREEN}✓${RESET} Working tree clean"
    fi

    # Check if base branch exists
    if git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${RESET} Base branch: $BASE_BRANCH"
    else
        echo -e "  ${RED}✗${RESET} Base branch not found: $BASE_BRANCH"
        errors=$((errors + 1))
    fi

    # 3. GitHub auth (if gh available and not disabled)
    if [[ "$NO_GITHUB" != "true" ]] && command -v gh >/dev/null 2>&1; then
        if gh auth status >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} GitHub authenticated"
        else
            echo -e "  ${YELLOW}⚠${RESET} GitHub not authenticated (features disabled)"
        fi
    fi

    # 4. Claude CLI
    if command -v claude >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${RESET} Claude CLI available"
    else
        echo -e "  ${RED}✗${RESET} Claude CLI not found — plan/build stages will fail"
        errors=$((errors + 1))
    fi

    # 5. sw loop (needed for build stage)
    if [[ -x "$SCRIPT_DIR/sw-loop.sh" ]]; then
        echo -e "  ${GREEN}✓${RESET} shipwright loop available"
    else
        echo -e "  ${RED}✗${RESET} sw-loop.sh not found at $SCRIPT_DIR"
        errors=$((errors + 1))
    fi

    # 6. Disk space check (warn if < 1GB free)
    local free_space_kb
    free_space_kb=$(df -k "$PROJECT_ROOT" 2>/dev/null | tail -1 | awk '{print $4}')
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

# ─── Notifications ─────────────────────────────────────────────────
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
        curl -sf --connect-timeout "$(_config_get_int "network.connect_timeout" 10 2>/dev/null || echo 10)" --max-time "$(_config_get_int "network.max_time" 60 2>/dev/null || echo 60)" -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$SLACK_WEBHOOK" >/dev/null 2>&1 || true
    fi

    # Custom webhook (env var SHIPWRIGHT_WEBHOOK_URL)
    local _webhook_url="${SHIPWRIGHT_WEBHOOK_URL:-}"
    if [[ -n "$_webhook_url" ]]; then
        local payload
        payload=$(jq -n \
            --arg title "$title" --arg message "$message" \
            --arg level "$level" --arg pipeline "${PIPELINE_NAME:-}" \
            --arg goal "${GOAL:-}" --arg stage "${CURRENT_STAGE_ID:-}" \
            '{title:$title, message:$message, level:$level, pipeline:$pipeline, goal:$goal, stage:$stage}')
        curl -sf --connect-timeout 10 --max-time 30 -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$_webhook_url" >/dev/null 2>&1 || true
    fi
}

# ─── Error Classification ──────────────────────────────────────────
classify_error() {
    local stage_id="$1"
    local log_file="${ARTIFACTS_DIR}/${stage_id}-results.log"
    [[ ! -f "$log_file" ]] && log_file="${ARTIFACTS_DIR}/test-results.log"
    [[ ! -f "$log_file" ]] && { echo "unknown"; return; }

    local log_tail
    log_tail=$(tail -50 "$log_file" 2>/dev/null || echo "")

    # Generate error signature for history lookup
    local error_sig
    error_sig=$(echo "$log_tail" | grep -iE 'error|fail|exception|fatal' 2>/dev/null | head -3 | cksum | awk '{print $1}' || echo "0")

    # Check classification history first (learned from previous runs)
    local class_history="${HOME}/.shipwright/optimization/error-classifications.json"
    if [[ -f "$class_history" ]]; then
        local cached_class
        cached_class=$(jq -r --arg sig "$error_sig" '.[$sig].classification // empty' "$class_history" 2>/dev/null || true)
        if [[ -n "$cached_class" && "$cached_class" != "null" ]]; then
            echo "$cached_class"
            return
        fi
    fi

    local classification="unknown"

    # Infrastructure errors: timeout, OOM, network — retry makes sense
    if echo "$log_tail" | grep -qiE 'timeout|timed out|ETIMEDOUT|ECONNREFUSED|ECONNRESET|network|socket hang up|OOM|out of memory|killed|signal 9|Cannot allocate memory'; then
        classification="infrastructure"
    # Configuration errors: missing env, wrong path — don't retry, escalate
    elif echo "$log_tail" | grep -qiE 'ENOENT|not found|No such file|command not found|MODULE_NOT_FOUND|Cannot find module|missing.*env|undefined variable|permission denied|EACCES'; then
        classification="configuration"
    # Logic errors: assertion failures, type errors — retry won't help without code change
    elif echo "$log_tail" | grep -qiE 'AssertionError|assert.*fail|Expected.*but.*got|TypeError|ReferenceError|SyntaxError|CompileError|type mismatch|cannot assign|incompatible type'; then
        classification="logic"
    # Build errors: compilation failures
    elif echo "$log_tail" | grep -qiE 'error\[E[0-9]+\]|error: aborting|FAILED.*compile|build failed|tsc.*error|eslint.*error'; then
        classification="logic"
    # Intelligence fallback: Claude classification for unknown errors
    elif [[ "$classification" == "unknown" ]] && type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
        local ai_class
        ai_class=$("$SW_AGENT_EXEC" claude --print --output-format text -p "Classify this error as exactly one of: infrastructure, configuration, logic, unknown.

Error output:
$(echo "$log_tail" | tail -20)

Reply with ONLY the classification word, nothing else." --model "$(_smart_model classification haiku)" < /dev/null 2>/dev/null || true)
        ai_class=$(echo "$ai_class" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        case "$ai_class" in
            infrastructure|configuration|logic) classification="$ai_class" ;;
        esac
    fi

    # Map retry categories to shared taxonomy (from lib/compat.sh SW_ERROR_CATEGORIES)
    # Retry uses: infrastructure, configuration, logic, unknown
    # Shared uses: test_failure, build_error, lint_error, timeout, dependency, flaky, config, security, permission, unknown
    local canonical_category="unknown"
    case "$classification" in
        infrastructure) canonical_category="timeout" ;;
        configuration)  canonical_category="config" ;;
        logic)
            case "$stage_id" in
                test) canonical_category="test_failure" ;;
                *)    canonical_category="build_error" ;;
            esac
            ;;
    esac

    # Record classification for future runs (using both retry and canonical categories)
    if [[ -n "$error_sig" && "$error_sig" != "0" ]]; then
        local class_dir="${HOME}/.shipwright/optimization"
        mkdir -p "$class_dir" 2>/dev/null || true
        local tmp_class
        tmp_class="$(mktemp)" || { warn "mktemp failed"; return 1; }
        # shellcheck disable=SC2064  # intentional expansion at definition time
        trap "rm -f '$tmp_class'" RETURN
        if [[ -f "$class_history" ]]; then
            jq --arg sig "$error_sig" --arg cls "$classification" --arg canon "$canonical_category" --arg stage "$stage_id" \
                '.[$sig] = {"classification": $cls, "canonical": $canon, "stage": $stage, "recorded_at": now}' \
                "$class_history" > "$tmp_class" 2>/dev/null && \
                mv "$tmp_class" "$class_history" || rm -f "$tmp_class"
        else
            jq -n --arg sig "$error_sig" --arg cls "$classification" --arg canon "$canonical_category" --arg stage "$stage_id" \
                '{($sig): {"classification": $cls, "canonical": $canon, "stage": $stage, "recorded_at": now}}' \
                > "$tmp_class" 2>/dev/null && \
                mv "$tmp_class" "$class_history" || rm -f "$tmp_class"
        fi
    fi

    echo "$classification"
}
