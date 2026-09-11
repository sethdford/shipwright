# daemon-failure.sh — Failure classification, retry, backoff (for sw-daemon.sh)
# Source from sw-daemon.sh. Requires state, helpers.
[[ -n "${_DAEMON_FAILURE_LOADED:-}" ]] && return 0
_DAEMON_FAILURE_LOADED=1

# Defaults for variables normally set by sw-daemon.sh (safe under set -u).
DAEMON_DIR="${DAEMON_DIR:-${HOME}/.shipwright}"
STATE_FILE="${STATE_FILE:-${DAEMON_DIR}/daemon-state.json}"
PAUSE_FLAG="${PAUSE_FLAG:-${DAEMON_DIR}/daemon-pause.flag}"
LOG_DIR="${LOG_DIR:-${DAEMON_DIR}/logs}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PIPELINE_TEMPLATE="${PIPELINE_TEMPLATE:-autonomous}"
MAX_PARALLEL="${MAX_PARALLEL:-2}"
MODEL="${MODEL:-opus}"
EFFORT_LEVEL="${EFFORT_LEVEL:-}"
WATCH_LABEL="${WATCH_LABEL:-shipwright}"
ON_SUCCESS_REMOVE_LABEL="${ON_SUCCESS_REMOVE_LABEL:-shipwright}"
ON_SUCCESS_ADD_LABEL="${ON_SUCCESS_ADD_LABEL:-pipeline/complete}"
ON_FAILURE_ADD_LABEL="${ON_FAILURE_ADD_LABEL:-pipeline/failed}"
ON_FAILURE_LOG_LINES="${ON_FAILURE_LOG_LINES:-50}"
NO_GITHUB="${NO_GITHUB:-false}"
EVENTS_FILE="${EVENTS_FILE:-${DAEMON_DIR}/events.jsonl}"

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

# ─── Failure Signature Normalization & Escalation ────────────────────────────
#
# classify_failure() gives a coarse class (auth_error/api_error/build_failure/…).
# That is enough to decide *whether* to retry, but not *how hard* to retry: two
# consecutive build_failures may be entirely different bugs, or the exact same
# one. A signature answers that second question — it is a path- and
# digit-independent fingerprint of the error text, stable across retries of the
# same defect and different for a different defect.

# _escalation_cfg_int <config.key> <default>
# Thin, dependency-free wrapper around _smart_int (lib/compat.sh). daemon-failure.sh
# is sourced by sw-daemon.sh *after* bootstrap, so _smart_int is normally present;
# the fallback keeps the lib usable (and unit-testable) on its own.
_escalation_cfg_int() {
    local key="$1" default="$2" val="$2"
    if command -v _smart_int >/dev/null 2>&1; then
        val=$(_smart_int "$key" "$default" 2>/dev/null || echo "$default")
    fi
    [[ "$val" =~ ^[0-9]+$ ]] || val="$default"
    echo "$val"
}

# normalize_failure_signature <issue_num> <failure_class>
# Emits "<class>:<8 hex digits>", or "<class>:none" when there is nothing to
# fingerprint. Normalization strips everything that varies between two runs of
# the *same* failure: ANSI colour, timestamps, absolute directories (the
# basename is kept — the file is part of the identity), and all digits (line
# numbers, PIDs, durations, byte counts).
normalize_failure_signature() {
    local issue_num="$1" failure_class="${2:-unknown}"
    local log_path="${LOG_DIR:-}/issue-${issue_num}.log"
    if [[ -z "${LOG_DIR:-}" || ! -f "$log_path" ]]; then
        echo "${failure_class}:none"
        return
    fi

    local esc
    esc=$(printf '\033')

    # Prefer error-shaped lines; fall back to the raw tail when none match, so a
    # failure with an unusual vocabulary still gets a stable fingerprint.
    local raw
    raw=$(tail -200 "$log_path" 2>/dev/null | grep -iE 'error|fail|exception|cannot|not found|undefined|expected|assert|ERR!|Traceback|panic' | tail -20 || true)
    if [[ -z "$raw" ]]; then
        raw=$(tail -20 "$log_path" 2>/dev/null | grep -v '^[[:space:]]*$' || true)
    fi
    if [[ -z "$raw" ]]; then
        echo "${failure_class}:none"
        return
    fi

    local normalized
    normalized=$(printf '%s\n' "$raw" \
        | sed "s/${esc}\[[0-9;]*[a-zA-Z]//g" \
        | sed -e 's/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9][.,0-9]*Z*//g' \
              -e 's/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]//g' \
              -e 's/[0-9][0-9]:[0-9][0-9]:[0-9][0-9]//g' \
        | sed 's#[A-Za-z0-9_.+-]*/##g' \
        | sed -e 's/[0-9][0-9]*/N/g' \
              -e 's/[[:space:]][[:space:]]*/ /g' \
              -e 's/^ //' -e 's/ $//' \
        | tr '[:upper:]' '[:lower:]' \
        | grep -v '^$' || true)

    if [[ -z "$normalized" ]]; then
        echo "${failure_class}:none"
        return
    fi

    local sum
    sum=$(printf '%s\n' "$normalized" | cksum | awk '{print $1}')
    [[ "$sum" =~ ^[0-9]+$ ]] || { echo "${failure_class}:none"; return; }
    printf '%s:%08x\n' "$failure_class" "$sum"
}

# escalate_effort_level <level>
# One rung up the low→medium→high→xhigh→max ladder pinned by
# sw-lib-compat-test.sh. "max" is the ceiling and escalating it is a no-op
# (idempotent, never an error). An unrecognised level normalizes to "high".
escalate_effort_level() {
    case "${1:-}" in
        low)    echo "medium" ;;
        medium) echo "high" ;;
        high)   echo "xhigh" ;;
        xhigh)  echo "max" ;;
        max)    echo "max" ;;
        *)      echo "high" ;;
    esac
}

# escalate_model_tier <model>
# Escalates to the model configured for high-risk work (model_routing.high_risk).
# Already being on that tier is the ceiling: the input is returned unchanged, and
# the caller reports at_ceiling rather than logging a no-op "escalation".
escalate_model_tier() {
    local current="${1:-}"
    local high_risk="opus"
    if command -v _smart_model >/dev/null 2>&1; then
        high_risk=$(_smart_model high_risk opus 2>/dev/null || echo "opus")
    fi
    [[ -z "$high_risk" ]] && high_risk="opus"
    if [[ "$current" == "$high_risk" ]]; then
        echo "$current"
    else
        echo "$high_risk"
    fi
}

# record_failure_signature <issue_num> <signature>
# Persists the signature for this issue and echoes how many times in a row it has
# now been seen. The count is re-read from state rather than tracked in memory:
# retries can span daemon restarts, and the state file is the only thing that
# survives them.
record_failure_signature() {
    local issue_num="$1" signature="$2"
    local consecutive=1

    if [[ ! -f "${STATE_FILE:-}" ]]; then
        echo "$consecutive"
        return
    fi

    locked_state_update --arg num "$issue_num" --arg sig "$signature" --arg ts "$(now_iso)" '
        .failure_signatures = (.failure_signatures // {})
        | .failure_signatures[$num] = (
            (.failure_signatures[$num] // {signature: "", count: 0, history: []}) as $prev
            | {
                signature: $sig,
                count: (if $prev.signature == $sig then (($prev.count // 0) + 1) else 1 end),
                last_seen: $ts,
                history: ((($prev.history // []) + [$sig]) | .[-5:])
              }
          )
    ' 2>/dev/null || true

    local from_state
    from_state=$(jq -r --arg num "$issue_num" \
        '.failure_signatures[$num].count // 1' "$STATE_FILE" 2>/dev/null || echo "1")
    if [[ "$from_state" =~ ^[0-9]+$ ]] && [[ "$from_state" -gt 0 ]]; then
        consecutive="$from_state"
    fi
    echo "$consecutive"
}

# clear_failure_signature <issue_num>
clear_failure_signature() {
    local issue_num="$1"
    [[ -f "${STATE_FILE:-}" ]] || return 0
    locked_state_update --arg num "$issue_num" \
        'if (.failure_signatures | type) == "object" then del(.failure_signatures[$num]) else . end' 2>/dev/null || true
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
        _tmp_pause=$(mktemp "${TMPDIR:-/tmp}/sw-pause.XXXXXX") || { daemon_log ERROR "mktemp failed for pause flag"; return 0; }
        echo "$pause_json" > "$_tmp_pause"
        mv "$_tmp_pause" "$PAUSE_FLAG" || rm -f "$_tmp_pause"
        emit_event "daemon.auto_pause" "reason=consecutive_failures" "class=$failure_class" "count=$consecutive" "resume_after=$resume_after"
    fi
}

# reset_failure_tracking [issue_num]
# Clears the in-memory consecutive-class run. With an issue number, also drops
# that issue's persisted failure signature, so a later unrelated failure starts
# counting from one instead of inheriting a stale streak.
reset_failure_tracking() {
    DAEMON_CONSECUTIVE_FAILURE_CLASS=""
    DAEMON_CONSECUTIVE_FAILURE_COUNT=0
    if [[ -n "${1:-}" ]]; then
        clear_failure_signature "$1"
    fi
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
        # Read retry count from SQLite first (durable across daemon restarts),
        # then fall back to JSON state file
        local _db_file="${DAEMON_DIR}/shipwright.db"
        if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$_db_file" ]]; then
            retry_count=$(sqlite3 -cmd ".timeout 3000" "$_db_file" \
                "SELECT COALESCE(MAX(retry_count), 0) FROM daemon_state WHERE issue_number = ${issue_num};" 2>/dev/null || echo "0")
        else
            retry_count=$(jq -r --arg num "$issue_num" \
                '.retry_counts[$num] // 0' "$STATE_FILE" 2>/dev/null || echo "0")
        fi

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

                    # Also persist to SQLite (survives daemon restarts/state resets)
                    if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$_db_file" ]]; then
                        sqlite3 -cmd ".timeout 3000" "$_db_file" \
                            "UPDATE daemon_state SET retry_count = ${retry_count} WHERE issue_number = ${issue_num} AND status = 'active';" 2>/dev/null || true
                    fi

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

                    # ── Repeated-signature escalation ──
                    # The block above is keyed on retry *count* — it escalates the
                    # same way whether the pipeline hit a new bug each time or the
                    # identical one twice. This block looks at *what* failed: when
                    # the normalized signature repeats, throw a stronger model and
                    # a deeper effort level at it rather than re-running the same
                    # configuration into the same wall.
                    local retry_effort="${EFFORT_LEVEL:-}"
                    local failure_signature="" sig_count=0
                    local sig_enabled sig_threshold
                    sig_enabled=$(_escalation_cfg_int "escalation.on_repeat_signature" 1)
                    sig_threshold=$(_escalation_cfg_int "escalation.repeat_threshold" 2)
                    [[ "$sig_threshold" -lt 1 ]] && sig_threshold=1

                    if [[ "$sig_enabled" != "0" ]]; then
                        failure_signature=$(normalize_failure_signature "$issue_num" "$failure_class")
                        sig_count=$(record_failure_signature "$issue_num" "$failure_signature")
                        emit_event "daemon.failure_signature" "issue=$issue_num" \
                            "signature=$failure_signature" "consecutive=$sig_count" "retry=$retry_count"

                        if [[ "$sig_count" -ge "$sig_threshold" ]]; then
                            # EFFORT_LEVEL is usually empty (the pipeline then picks a
                            # level per stage). Escalating from "nothing" is meaningless,
                            # so the base is the build stage's own level — build is the
                            # stage that produced the failure we are escalating against.
                            local effort_base="$retry_effort"
                            if [[ -z "$effort_base" ]] && command -v _smart_effort >/dev/null 2>&1; then
                                effort_base=$(_smart_effort build 2>/dev/null || true)
                            fi
                            [[ -z "$effort_base" ]] && effort_base="high"

                            local esc_model esc_effort
                            esc_model=$(escalate_model_tier "$retry_model")
                            esc_effort=$(escalate_effort_level "$effort_base")

                            if [[ "$esc_model" == "$retry_model" && "$esc_effort" == "$effort_base" ]]; then
                                daemon_log INFO "Repeated failure signature ${failure_signature} (x${sig_count}) — already at model/effort ceiling"
                                emit_event "daemon.escalation" "issue=$issue_num" "result=at_ceiling" \
                                    "signature=$failure_signature" "consecutive=$sig_count" \
                                    "model=$retry_model" "effort=$effort_base"
                            else
                                daemon_log WARN "Repeated failure signature ${failure_signature} (x${sig_count}) — escalating model ${retry_model}→${esc_model}, effort ${effort_base}→${esc_effort}"
                                emit_event "daemon.escalation" "issue=$issue_num" "result=escalated" \
                                    "signature=$failure_signature" "consecutive=$sig_count" \
                                    "from_model=$retry_model" "to_model=$esc_model" \
                                    "from_effort=$effort_base" "to_effort=$esc_effort"
                                retry_model="$esc_model"
                                retry_effort="$esc_effort"
                            fi
                        fi
                    fi

                    # Increase restarts on context exhaustion
                    if [[ "$failure_class" == "context_exhaustion" ]]; then
                        local restart_cap
                        restart_cap=$(_escalation_cfg_int "loop.hard_restart_cap" 5)
                        [[ "$restart_cap" -lt 1 ]] && restart_cap=1
                        local boosted_restarts=$(( ${MAX_RESTARTS_CFG:-3} + retry_count ))
                        if [[ "$boosted_restarts" -gt "$restart_cap" ]]; then
                            boosted_restarts="$restart_cap"
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
| Effort | \`${retry_effort:-per-stage default}\` |
| Signature | \`${failure_signature:-n/a}\` (seen ${sig_count}x in a row) |
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
                    local orig_effort="${EFFORT_LEVEL:-}"
                    PIPELINE_TEMPLATE="$retry_template"
                    MODEL="$retry_model"
                    EFFORT_LEVEL="$retry_effort"
                    daemon_spawn_pipeline "$issue_num" "retry-${retry_count}" "" "${all_extra_args[@]}"
                    _retry_spawned_for="$issue_num"
                    PIPELINE_TEMPLATE="$orig_template"
                    MODEL="$orig_model"
                    EFFORT_LEVEL="$orig_effort"
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
