#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  convergence.sh — Build Loop Iteration Progress Quality Scorer           ║
# ║                                                                           ║
# ║  Scores each build loop iteration's progress (0-100) and detects when   ║
# ║  the loop has converged, diverging, oscillating, or needs escalation.   ║
# ║                                                                           ║
# ║  Usage: Source from sw-loop.sh, call convergence_integrate() after      ║
# ║  test evaluation. Returns exit codes: 0=continue, 1=stop-success,       ║
# ║  2=stop-fail, 3=escalate.                                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_CONVERGENCE_LOADED:-}" ]] && return 0
_CONVERGENCE_LOADED=1

# ─── Defaults ────────────────────────────────────────────────────────────────
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ─── Score an iteration's progress (0-100) ───────────────────────────────────
#
# Evaluates:
# - Tests newly passing (+25 points)
# - Tests newly failing (-15 points)
# - Meaningful code changes (+20 points)
# - Same error repeated (-10 points per repeat)
# - New files created (+5 points each, capped at +15)
#
convergence_score_iteration() {
    local iteration="${1:-0}"
    local test_passed="${2:-false}"
    local test_changed="${3:-false}"
    local git_diff_lines="${4:-0}"
    local error_count="${5:-0}"
    local prev_score="${6:-50}"

    local score=50  # Baseline
    local signals=()

    # Signal 1: Test transitions
    if [[ "$test_passed" == "true" ]]; then
        if [[ "$test_changed" == "true" ]]; then
            # Newly passing tests — major progress
            score=$((score + 25))
            signals+=("newly_passing_tests:+25")
        else
            # Already passing — maintain score
            signals+=("tests_already_passing:0")
        fi
    else
        # Tests failing
        if [[ "$test_changed" == "true" ]]; then
            # Newly failing tests — regression
            score=$((score - 15))
            signals+=("newly_failing_tests:-15")
        else
            # Already failing — decay
            score=$((score - 5))
            signals+=("tests_still_failing:-5")
        fi
    fi

    # Signal 2: Code changes (meaningful = >5 lines)
    if [[ "$git_diff_lines" -gt 5 ]]; then
        local change_bonus=20
        # Scaling: cap at 50 line changes for max bonus
        if [[ "$git_diff_lines" -gt 50 ]]; then
            change_bonus=$((20 - (git_diff_lines - 50) / 10))
            [[ "$change_bonus" -lt 5 ]] && change_bonus=5
        fi
        score=$((score + change_bonus))
        signals+=("code_changes:+${change_bonus}")
    elif [[ "$git_diff_lines" -gt 0 ]]; then
        # Minimal changes — slight penalty
        score=$((score - 5))
        signals+=("minimal_changes:-5")
    else
        # No changes — stalled
        score=$((score - 10))
        signals+=("no_code_changes:-10")
    fi

    # Signal 3: Error repetition (from error-log.jsonl)
    if [[ "$error_count" -gt 2 ]]; then
        local err_penalty
        err_penalty=$((error_count - 2))
        err_penalty=$((err_penalty * 5))
        [[ "$err_penalty" -gt 20 ]] && err_penalty=20
        score=$((score - err_penalty))
        signals+=("repeated_errors:-${err_penalty}")
    fi

    # Clamp score to 0-100
    [[ "$score" -lt 0 ]] && score=0
    [[ "$score" -gt 100 ]] && score=100

    # Determine trend vs previous score
    local trend="stable"
    local trend_delta=$((score - prev_score))
    if [[ "$trend_delta" -gt 5 ]]; then
        trend="improving"
    elif [[ "$trend_delta" -lt -5 ]]; then
        trend="declining"
    fi

    # Output JSON
    cat <<JSON
{
  "score": $score,
  "trend": "$trend",
  "trend_delta": $trend_delta,
  "signals": [$(printf '"%s"' "${signals[@]}" | sed 's/" *"/, /g')],
  "iteration": $iteration,
  "test_passed": $test_passed,
  "code_changed": $([ "$git_diff_lines" -gt 0 ] && echo "true" || echo "false"),
  "code_lines": $git_diff_lines,
  "errors": $error_count
}
JSON
}

# ─── Detect convergence status ────────────────────────────────────────────────
#
# Reads convergence-history.json and determines the loop's state:
# - converged: Score >80 for 2+ consecutive iterations
# - diverging: Score dropping for 3+ consecutive iterations
# - oscillating: Score bouncing up/down for 4+ iterations
# - progressing: Score improving overall
# - stalled: Score unchanged for 3+ iterations
#
convergence_detect() {
    local history_file="${ARTIFACTS_DIR}/convergence-history.json"

    # If no history yet, can't detect
    if [[ ! -f "$history_file" ]]; then
        cat <<JSON
{
  "status": "progressing",
  "recommendation": "continue",
  "reason": "first_iteration",
  "confidence": 0.5
}
JSON
        return 0
    fi

    # Parse history (array of {score, trend, iteration})
    local scores=()
    local trends=()
    local last_4=()

    # Extract last 6 scores and trends
    local history
    history=$(jq -r '.[] | "\(.score),\(.trend)"' "$history_file" 2>/dev/null | tail -6)

    if [[ -z "$history" ]]; then
        cat <<JSON
{
  "status": "progressing",
  "recommendation": "continue",
  "reason": "malformed_history",
  "confidence": 0.5
}
JSON
        return 0
    fi

    while IFS=',' read -r s t; do
        [[ -z "$s" ]] && continue
        scores+=("$s")
        trends+=("$t")
        last_4+=("$s")
        # Keep only last 4
        [[ "${#last_4[@]}" -gt 4 ]] && last_4=("${last_4[@]:1}")
    done <<< "$history"

    local num_scores=${#scores[@]}
    [[ "$num_scores" -lt 2 ]] && {
        cat <<JSON
{
  "status": "progressing",
  "recommendation": "continue",
  "reason": "insufficient_history",
  "confidence": 0.5,
  "scores": $(printf '[%s]' "$(printf '%s,' "${scores[@]}" | sed 's/,$//')")
}
JSON
        return 0
    }

    local first_score="${scores[0]}"
    local last_idx=$((num_scores - 1))
    local last_score="${scores[$last_idx]}"

    # Detection logic

    # 1. Converged: Last 2 scores >= 80 and stable
    if [[ "$num_scores" -ge 2 ]]; then
        local last1_idx=$((num_scores - 1))
        local last2_idx=$((num_scores - 2))
        local last1="${scores[$last1_idx]}"
        local last2="${scores[$last2_idx]}"
        if [[ "$last1" -ge 80 && "$last2" -ge 80 ]]; then
            local delta=$((last1 - last2))
            [[ "$delta" -lt -5 ]] && delta=$((0 - delta))
            if [[ "$delta" -le 5 ]]; then
                cat <<JSON
{
  "status": "converged",
  "recommendation": "stop",
  "reason": "high_score_stable",
  "confidence": 0.95,
  "last_scores": [$(printf '%s' "${last_4[@]}" | sed 's/ /, /g')],
  "latest_score": $last1
}
JSON
                return 0
            fi
        fi
    fi

    # 2. Diverging: 3+ consecutive declining iterations
    if [[ "$num_scores" -ge 3 ]]; then
        local diverging_count=0
        for i in $(seq 1 $((num_scores - 1))); do
            local prev="${scores[$((i - 1))]}"
            local curr="${scores[$i]}"
            [[ "$curr" -lt "$prev" ]] && diverging_count=$((diverging_count + 1))
        done
        if [[ "$diverging_count" -ge 3 ]]; then
            cat <<JSON
{
  "status": "diverging",
  "recommendation": "stop",
  "reason": "consistent_decline",
  "confidence": 0.85,
  "last_scores": [$(printf '%s' "${last_4[@]}" | sed 's/ /, /g')],
  "declining_iterations": $diverging_count
}
JSON
            return 0
        fi
    fi

    # 3. Oscillating: 4+ iterations with alternating up/down
    if [[ "$num_scores" -ge 4 ]]; then
        local oscillations=0
        local last_dir=""
        for i in $(seq 1 $((num_scores - 1))); do
            local prev="${scores[$((i - 1))]}"
            local curr="${scores[$i]}"
            local direction=""
            [[ "$curr" -gt "$prev" ]] && direction="up"
            [[ "$curr" -lt "$prev" ]] && direction="down"

            if [[ -n "$last_dir" && "$direction" != "$last_dir" ]]; then
                oscillations=$((oscillations + 1))
            fi
            last_dir="$direction"
        done

        if [[ "$oscillations" -ge 3 ]]; then
            cat <<JSON
{
  "status": "oscillating",
  "recommendation": "escalate",
  "reason": "bouncing_scores",
  "confidence": 0.80,
  "last_scores": [$(printf '%s' "${last_4[@]}" | sed 's/ /, /g')],
  "oscillations": $oscillations
}
JSON
            return 0
        fi
    fi

    # 4. Stalled: Score unchanged for 3+ iterations
    if [[ "$num_scores" -ge 3 ]]; then
        local stalled_count=0
        local start_idx=$((num_scores - 3))
        local end_idx=$((num_scores - 1))
        for i in $(seq "$start_idx" "$end_idx"); do
            [[ "$i" -lt 0 ]] && continue
            local prev_idx=$((i - 1))
            [[ "$prev_idx" -lt 0 ]] && continue
            local prev="${scores[$prev_idx]:-0}"
            local curr="${scores[$i]}"
            local delta=$((curr - prev))
            [[ "$delta" -lt 0 ]] && delta=$((0 - delta))
            [[ "$delta" -le 3 ]] && stalled_count=$((stalled_count + 1))
        done
        if [[ "$stalled_count" -ge 2 ]]; then
            cat <<JSON
{
  "status": "stalled",
  "recommendation": "change_strategy",
  "reason": "no_progress",
  "confidence": 0.75,
  "last_scores": [$(printf '%s' "${last_4[@]}" | sed 's/ /, /g')]
}
JSON
            return 0
        fi
    fi

    # 5. Default: progressing
    cat <<JSON
{
  "status": "progressing",
  "recommendation": "continue",
  "reason": "improving_or_stable",
  "confidence": 0.70,
  "last_scores": [$(printf '%s' "${last_4[@]}" | sed 's/ /, /g')],
  "trend": "$([ "$last_score" -gt "$first_score" ] && echo "up" || echo "down")"
}
JSON
}

# ─── Track history of scores across iterations ────────────────────────────────
#
convergence_history() {
    local iteration="${1:-0}"
    local score="${2:-50}"
    local trend="${3:-stable}"

    local history_file="${ARTIFACTS_DIR}/convergence-history.json"
    mkdir -p "$ARTIFACTS_DIR"

    # Initialize if doesn't exist
    if [[ ! -f "$history_file" ]]; then
        echo "[]" > "$history_file.tmp.$$"
        mv "$history_file.tmp.$$" "$history_file"
    fi

    # Append new entry
    local entry="{\"iteration\": $iteration, \"score\": $score, \"trend\": \"$trend\", \"ts\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}"
    local tmp_hist="${history_file}.tmp.$$"

    # Use jq to append safely
    if jq ". += [$(echo "$entry" | jq '.')  ]" "$history_file" > "$tmp_hist" 2>/dev/null; then
        mv "$tmp_hist" "$history_file"
    else
        # Fallback: if jq fails, manually append JSON
        {
            cat "$history_file" | jq '.' 2>/dev/null | head -n -1
            echo "  $entry"
            echo "]"
        } > "$tmp_hist" 2>/dev/null
        mv "$tmp_hist" "$history_file" || rm -f "$tmp_hist"
    fi
}

# ─── Suggest action when stalled/diverging ────────────────────────────────────
#
convergence_suggest_action() {
    local status="${1:-progressing}"
    local iteration="${2:-0}"
    local context="${3:-}"

    case "$status" in
        stalled)
            cat <<ACTION
{
  "action": "change_approach",
  "reason": "score_unchanged_for_multiple_iterations",
  "suggestions": [
    "Break the remaining work into smaller, more granular steps",
    "Try a completely different implementation strategy",
    "Verify that dependencies are installed and working",
    "Read error messages more carefully — focus on root cause, not symptoms"
  ],
  "escalation": "if_still_stuck_after_next_iteration"
}
ACTION
            ;;
        diverging)
            cat <<ACTION
{
  "action": "escalate_model",
  "reason": "score_declining_consistently",
  "suggestions": [
    "Problem may be too complex for current model",
    "Try a fundamentally different approach",
    "Consider splitting into independent subproblems"
  ],
  "escalation": "use_opus_model_or_manual_review"
}
ACTION
            ;;
        oscillating)
            cat <<ACTION
{
  "action": "restart_session",
  "reason": "context_pollution_or_conflicting_approaches",
  "suggestions": [
    "Context may be polluted from previous attempts",
    "Previous approaches may be conflicting with new ones",
    "Start fresh session with progress.md carrying over key learnings"
  ],
  "escalation": "manual_review_recommended"
}
ACTION
            ;;
        *)
            cat <<ACTION
{
  "action": "continue",
  "reason": "progressing_normally",
  "suggestions": []
}
ACTION
            ;;
    esac
}

# ─── Integration hook for sw-loop.sh ──────────────────────────────────────────
#
# Called after test gate + quality gates. Scores iteration, detects convergence,
# and returns:
#   0 = continue
#   1 = stop-success (converged)
#   2 = stop-fail (diverging)
#   3 = escalate (oscillating)
#
convergence_integrate() {
    local iteration="${ITERATION:-0}"
    local test_passed="${TEST_PASSED:-false}"
    local quality_passed="${QUALITY_GATE_PASSED:-false}"

    # For first iteration, can't compute trend
    if [[ "$iteration" -lt 1 ]]; then
        return 0
    fi

    # ── LOOP_COMPLETE signal check ─────────────────────────────────────────
    # If the agent explicitly signaled completion and tests pass, stop immediately.
    # This prevents wasting iterations when the work is done but scores stay ~50.
    local _log_file="${LOG_DIR:-}/iteration-${iteration}.log"
    if [[ "$test_passed" == "true" ]] && grep -q "LOOP_COMPLETE" "$_log_file" 2>/dev/null; then
        # Write a converged recommendation so the pipeline knows why we stopped
        local rec_file="${ARTIFACTS_DIR}/convergence-recommendation.json"
        mkdir -p "$ARTIFACTS_DIR"
        cat > "$rec_file.tmp.$$" <<CONV_JSON
{
  "status": "converged",
  "recommendation": "stop",
  "reason": "agent_signaled_complete_tests_pass",
  "confidence": 0.95
}
CONV_JSON
        mv "$rec_file.tmp.$$" "$rec_file"
        if type emit_event >/dev/null 2>&1; then
            emit_event "convergence.agent_complete" \
                "iteration=$iteration" \
                "test_passed=$test_passed" 2>/dev/null || true
        fi
        return 1  # Stop success
    fi

    # Compute test transition (newly passing/failing)
    local test_changed="false"
    if [[ -f "$LOG_DIR/iteration-$((iteration - 1)).log" ]]; then
        local prev_test=""
        # Try to extract previous test status from state
        if [[ -f "${STATE_FILE:-}" ]]; then
            prev_test=$(grep "TEST_PASSED=" "${STATE_FILE}" | tail -1 | cut -d'=' -f2 || echo "")
        fi
        if [[ -n "$prev_test" && "$prev_test" != "$test_passed" ]]; then
            test_changed="true"
        fi
    fi

    # Git diff stats
    local diff_lines=0
    if [[ "$iteration" -gt 0 ]]; then
        diff_lines=$(git diff HEAD~1 --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion|0 file' | grep -oE '[0-9]+' | head -1 || echo "0")
        diff_lines="${diff_lines:-0}"
    fi

    # Count repeated errors from error-log.jsonl
    local error_count=0
    local error_log="${ARTIFACTS_DIR}/error-log.jsonl"
    if [[ -f "$error_log" ]]; then
        # Count unique errors in last 5 entries
        error_count=$(tail -5 "$error_log" 2>/dev/null | jq -r '.error // .message // empty' 2>/dev/null | sort | uniq -c | sort -rn | head -1 | awk '{print $1}' || echo "0")
        error_count="${error_count:-0}"
    fi

    # Get previous score (default 50)
    local prev_score=50
    if [[ -f "${ARTIFACTS_DIR}/convergence-history.json" ]]; then
        prev_score=$(jq -r '.[-1].score // 50' "${ARTIFACTS_DIR}/convergence-history.json" 2>/dev/null || echo "50")
        prev_score="${prev_score:-50}"
    fi

    # Score this iteration
    local score_json
    score_json=$(convergence_score_iteration "$iteration" "$test_passed" "$test_changed" "$diff_lines" "$error_count" "$prev_score")
    local score
    score=$(echo "$score_json" | jq -r '.score // 50' 2>/dev/null || echo "50")
    local trend
    trend=$(echo "$score_json" | jq -r '.trend // "stable"' 2>/dev/null || echo "stable")

    # Track history
    convergence_history "$iteration" "$score" "$trend"

    # Detect convergence
    local detect_json
    detect_json=$(convergence_detect)
    local status
    status=$(echo "$detect_json" | jq -r '.status // "progressing"' 2>/dev/null || echo "progressing")
    local recommendation
    recommendation=$(echo "$detect_json" | jq -r '.recommendation // "continue"' 2>/dev/null || echo "continue")

    # Write recommendation to artifact
    local rec_file="${ARTIFACTS_DIR}/convergence-recommendation.json"
    mkdir -p "$ARTIFACTS_DIR"
    echo "$detect_json" > "$rec_file.tmp.$$"
    mv "$rec_file.tmp.$$" "$rec_file"

    # Log via emit_event if available
    if type emit_event >/dev/null 2>&1; then
        emit_event "convergence.scored" \
            "iteration=$iteration" \
            "score=$score" \
            "trend=$trend" \
            "status=$status" \
            "recommendation=$recommendation" \
            "test_passed=$test_passed" \
            "code_lines=$diff_lines" 2>/dev/null || true
    fi

    # Return based on recommendation
    case "$recommendation" in
        stop)
            # Diverging also recommends stop, but it is a failure, never a success.
            [[ "$status" == "diverging" ]] && return 2
            # A converged score only counts as done when the tests pass.
            [[ "$test_passed" == "true" ]] && return 1  # Stop success
            return 0
            ;;
        escalate)
            return 3  # Escalate
            ;;
        change_strategy)
            # Suggest action but continue for one more iteration
            local action_json
            action_json=$(convergence_suggest_action "$status" "$iteration")
            local action_file="${ARTIFACTS_DIR}/convergence-action.json"
            echo "$action_json" > "$action_file.tmp.$$"
            mv "$action_file.tmp.$$" "$action_file"

            # Log suggestion
            if type warn >/dev/null 2>&1; then
                warn "Convergence stalled — $(echo "$action_json" | jq -r '.reason' 2>/dev/null || echo 'no progress')"
            fi
            return 0  # Continue but with warning
            ;;
        *)
            return 0  # Continue
            ;;
    esac
}

# ─── Utilities ────────────────────────────────────────────────────────────────

# Force history flush (for testing)
convergence_clear_history() {
    rm -f "${ARTIFACTS_DIR}/convergence-history.json" "${ARTIFACTS_DIR}/convergence-recommendation.json" "${ARTIFACTS_DIR}/convergence-action.json"
}

# Read current convergence status
convergence_read_status() {
    local rec_file="${ARTIFACTS_DIR}/convergence-recommendation.json"
    if [[ -f "$rec_file" ]]; then
        local status
        status=$(jq -r '.status // "unknown"' "$rec_file" 2>/dev/null || echo "unknown")
        echo "$status"
    else
        # If no recommendation file, check history and detect
        if [[ -f "${ARTIFACTS_DIR}/convergence-history.json" ]]; then
            local detect_out
            detect_out=$(convergence_detect 2>/dev/null || echo '{"status":"unknown"}')
            echo "$detect_out" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown"
        else
            echo "unknown"
        fi
    fi
}

# Export for use by sw-loop.sh
export -f convergence_score_iteration
export -f convergence_detect
export -f convergence_history
export -f convergence_suggest_action
export -f convergence_integrate
export -f convergence_clear_history
export -f convergence_read_status
