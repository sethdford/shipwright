#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_CONVERGENCE_LOADED:-}" ]] && return 0
_LOOP_CONVERGENCE_LOADED=1

# ─── Auto-Recovery Integration ───────────────────────────────────────────────
# Source the autonomous recovery system for pre-circuit-breaker recovery attempts.
_CONVERGENCE_SCRIPT_DIR="${_CONVERGENCE_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[[ -f "${_CONVERGENCE_SCRIPT_DIR}/auto-recovery.sh" ]] && source "${_CONVERGENCE_SCRIPT_DIR}/auto-recovery.sh"

# ─── Convergence Detection ────────────────────────────────────────────────────

track_iteration_velocity() {
    local changes
    changes="$(git -C "$PROJECT_ROOT" diff --stat HEAD~1 2>/dev/null | tail -1 || echo "")"
    local insertions
    insertions="$(echo "$changes" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    ITERATION_LINES_CHANGED="${insertions:-0}"
    if [[ -n "$VELOCITY_HISTORY" ]]; then
        VELOCITY_HISTORY="${VELOCITY_HISTORY},${ITERATION_LINES_CHANGED}"
    else
        VELOCITY_HISTORY="${ITERATION_LINES_CHANGED}"
    fi
}

# Compute average lines/iteration from recent history
compute_velocity_avg() {
    if [[ -z "$VELOCITY_HISTORY" ]]; then
        echo "0"
        return 0
    fi
    local total=0 count=0
    local IFS=','
    local val
    for val in $VELOCITY_HISTORY; do
        total=$((total + val))
        count=$((count + 1))
    done
    if [[ "$count" -gt 0 ]]; then
        echo $((total / count))
    else
        echo "0"
    fi
}

check_progress() {
    local changes
    # Exclude loop bookkeeping files — only count real code changes as progress
    changes="$(git -C "$PROJECT_ROOT" diff --stat HEAD~1 \
        -- . ':!.claude/loop-state.md' ':!.claude/pipeline-state.md' \
        ':!**/progress.md' ':!**/error-summary.json' \
        2>/dev/null | tail -1 || echo "")"
    local insertions
    insertions="$(echo "$changes" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    if [[ "${insertions:-0}" -lt "$MIN_PROGRESS_LINES" ]]; then
        return 1  # No meaningful progress
    fi
    return 0
}

check_completion() {
    local log_file="$1"
    grep -q "LOOP_COMPLETE" "$log_file" 2>/dev/null
}

check_circuit_breaker() {
    # Vitals-driven circuit breaker (preferred over static threshold)
    if type pipeline_compute_vitals >/dev/null 2>&1 && type pipeline_health_verdict >/dev/null 2>&1; then
        local _vitals_json _verdict
        local _loop_state="${STATE_FILE:-}"
        local _loop_artifacts="${ARTIFACTS_DIR:-}"
        local _loop_issue="${ISSUE_NUMBER:-}"
        _vitals_json=$(pipeline_compute_vitals "$_loop_state" "$_loop_artifacts" "$_loop_issue" 2>/dev/null) || true
        if [[ -n "$_vitals_json" && "$_vitals_json" != "{}" ]]; then
            _verdict=$(echo "$_vitals_json" | jq -r '.verdict // "continue"' 2>/dev/null || echo "continue")
            if [[ "$_verdict" == "abort" ]]; then
                local _health_score
                _health_score=$(echo "$_vitals_json" | jq -r '.health_score // 0' 2>/dev/null || echo "0")
                error "Vitals circuit breaker: health score ${_health_score}/100 — aborting (${CONSECUTIVE_FAILURES} stagnant iterations)"
                STATUS="circuit_breaker"
                return 1
            fi
            # Vitals say continue/warn/intervene — don't trip circuit breaker yet
            if [[ "$_verdict" == "continue" || "$_verdict" == "warn" ]]; then
                return 0
            fi
        fi
    fi

    # ─── Auto-Recovery: attempt fix before aborting ────────────────────────
    if [[ "$CONSECUTIVE_FAILURES" -ge "$CIRCUIT_BREAKER_THRESHOLD" ]]; then
        if type recovery_before_circuit_breaker >/dev/null 2>&1; then
            local error_log="${ARTIFACTS_DIR:-${PROJECT_ROOT:-.}/.claude/pipeline-artifacts}/error-log.jsonl"
            if recovery_before_circuit_breaker "$error_log" "${PROJECT_ROOT:-.}" "${TEST_CMD:-}"; then
                info "Auto-recovery succeeded — resetting circuit breaker"
                CONSECUTIVE_FAILURES=0
                return 0
            fi
        fi
        error "Circuit breaker tripped: ${CIRCUIT_BREAKER_THRESHOLD} consecutive iterations with no meaningful progress."
        STATUS="circuit_breaker"
        return 1
    fi
    return 0
}

check_max_iterations() {
    if [[ "$ITERATION" -le "$MAX_ITERATIONS" ]]; then
        return 0
    fi

    # Hit the cap — check if we should auto-extend
    if ! $AUTO_EXTEND || [[ "$EXTENSION_COUNT" -ge "$MAX_EXTENSIONS" ]]; then
        if [[ "$EXTENSION_COUNT" -ge "$MAX_EXTENSIONS" ]]; then
            warn "Hard cap reached: ${EXTENSION_COUNT} extensions applied (max ${MAX_EXTENSIONS})."
        fi
        warn "Max iterations ($MAX_ITERATIONS) reached."
        STATUS="max_iterations"
        return 1
    fi

    # Checkpoint audit: is there meaningful progress worth extending for?
    echo -e "\n  ${CYAN}${BOLD}▸ Checkpoint${RESET} — max iterations ($MAX_ITERATIONS) reached, evaluating progress..."

    local should_extend=false
    local extension_reason=""

    # Check 1: recent meaningful progress (not stuck)
    if [[ "${CONSECUTIVE_FAILURES:-0}" -lt 2 ]]; then
        # Check 2: agent hasn't signaled completion (if it did, guard_completion handles it)
        local last_log="$LOG_DIR/iteration-$(( ITERATION - 1 )).log"
        if [[ -f "$last_log" ]] && ! grep -q "LOOP_COMPLETE" "$last_log" 2>/dev/null; then
            should_extend=true
            extension_reason="work in progress with recent progress"
        fi
    fi

    # Check 3: if quality gates or tests are failing, extend to let agent fix them
    if [[ "$TEST_PASSED" == "false" ]] || ! $QUALITY_GATE_PASSED; then
        should_extend=true
        extension_reason="quality gates or tests not yet passing"
    fi

    if $should_extend; then
        # Scale extension size by velocity — good progress earns more iterations
        local velocity_avg
        velocity_avg="$(compute_velocity_avg)"
        local effective_extension="$EXTENSION_SIZE"
        if [[ "$velocity_avg" -gt 20 ]]; then
            # High velocity: grant more iterations
            effective_extension=$(( EXTENSION_SIZE + 3 ))
        elif [[ "$velocity_avg" -lt 5 ]]; then
            # Low velocity: grant fewer iterations
            effective_extension=$(( EXTENSION_SIZE > 2 ? EXTENSION_SIZE - 2 : 1 ))
        fi
        EXTENSION_COUNT=$(( EXTENSION_COUNT + 1 ))
        MAX_ITERATIONS=$(( MAX_ITERATIONS + effective_extension ))
        echo -e "  ${GREEN}✓${RESET} Auto-extending: +${effective_extension} iterations (now ${MAX_ITERATIONS} max, extension ${EXTENSION_COUNT}/${MAX_EXTENSIONS})"
        echo -e "  ${DIM}Reason: ${extension_reason} | velocity: ~${velocity_avg} lines/iter${RESET}"
        return 0
    fi

    warn "Max iterations reached — no recent progress detected."
    STATUS="max_iterations"
    return 1
}

record_iteration_stuckness_data() {
    local exit_code="${1:-0}"
    [[ -z "$LOG_DIR" ]] && return 0
    local tracking_file="${STUCKNESS_TRACKING_FILE:-$LOG_DIR/stuckness-tracking.txt}"
    local diff_hash error_hash
    diff_hash=$(git -C "${PROJECT_ROOT:-.}" diff HEAD 2>/dev/null | (md5 -q 2>/dev/null || md5sum 2>/dev/null | cut -d' ' -f1) || echo "none")
    local error_log="${ARTIFACTS_DIR:-${STATE_DIR:-${PROJECT_ROOT:-.}/.claude}/pipeline-artifacts}/error-log.jsonl"
    if [[ -f "$error_log" ]]; then
        error_hash=$(tail -5 "$error_log" 2>/dev/null | sort -u | (md5 -q 2>/dev/null || md5sum 2>/dev/null | cut -d' ' -f1) || echo "none")
    else
        error_hash="none"
    fi
    echo "${diff_hash}|${error_hash}|${exit_code}" >> "$tracking_file"
}

detect_stuckness() {
    STUCKNESS_HINT=""
    local iteration="${ITERATION:-0}"
    local stuckness_signals=0
    local stuckness_reasons=()
    local tracking_file="${STUCKNESS_TRACKING_FILE:-$LOG_DIR/stuckness-tracking.txt}"
    local tracking_lines
    tracking_lines=$(wc -l < "$tracking_file" 2>/dev/null || true)
    tracking_lines="${tracking_lines:-0}"

    # Signal 1: Text overlap (existing logic) — compare last 2 iteration logs
    if [[ "$iteration" -ge 3 ]]; then
        local log1="$LOG_DIR/iteration-$(( iteration - 1 )).log"
        local log2="$LOG_DIR/iteration-$(( iteration - 2 )).log"
        local log3="$LOG_DIR/iteration-$(( iteration - 3 )).log"

        if [[ -f "$log1" && -f "$log2" ]]; then
            local lines1 lines2 common total overlap_pct
            lines1=$(tail -50 "$log1" 2>/dev/null | grep -v '^$' | sort || true)
            lines2=$(tail -50 "$log2" 2>/dev/null | grep -v '^$' | sort || true)

            if [[ -n "$lines1" && -n "$lines2" ]]; then
                total=$(echo "$lines1" | wc -l | tr -d ' ')
                common=$(comm -12 <(echo "$lines1") <(echo "$lines2") 2>/dev/null | wc -l | tr -d ' ' || true)
                common="${common:-0}"
                if [[ "$total" -gt 0 ]]; then
                    overlap_pct=$(( common * 100 / total ))
                else
                    overlap_pct=0
                fi
                if [[ "${overlap_pct:-0}" -ge 90 ]]; then
                    stuckness_signals=$((stuckness_signals + 1))
                    stuckness_reasons+=("high text overlap (${overlap_pct}%) between iterations")
                fi
            fi
        fi
    fi

    # Signal 2: Git diff hash — last 3 iterations produced zero or identical diffs
    if [[ -f "$tracking_file" ]] && [[ "$tracking_lines" -ge 3 ]]; then
        local last_three
        last_three=$(tail -3 "$tracking_file" 2>/dev/null | cut -d'|' -f1 || true)
        local unique_hashes
        unique_hashes=$(echo "$last_three" | sort -u | grep -v '^$' | wc -l | tr -d ' ')
        if [[ "$unique_hashes" -le 1 ]] && [[ -n "$last_three" ]]; then
            stuckness_signals=$((stuckness_signals + 1))
            stuckness_reasons+=("identical or zero git diffs in last 3 iterations")
        fi
    fi

    # Signal 3: Error repetition — same error hash in last 3 iterations
    if [[ -f "$tracking_file" ]] && [[ "$tracking_lines" -ge 3 ]]; then
        local last_three_errors
        last_three_errors=$(tail -3 "$tracking_file" 2>/dev/null | cut -d'|' -f2 || true)
        local unique_error_hashes
        unique_error_hashes=$(echo "$last_three_errors" | sort -u | grep -v '^none$' | grep -v '^$' | wc -l | tr -d ' ')
        if [[ "$unique_error_hashes" -eq 1 ]] && [[ -n "$(echo "$last_three_errors" | grep -v '^none$')" ]]; then
            stuckness_signals=$((stuckness_signals + 1))
            stuckness_reasons+=("same error in last 3 iterations")
        fi
    fi

    # Signal 4: Same error repeating 3+ times (legacy check on error-log content)
    local error_log
    error_log="${ARTIFACTS_DIR:-$PROJECT_ROOT/.claude/pipeline-artifacts}/error-log.jsonl"
    if [[ -f "$error_log" ]]; then
        local last_errors
        last_errors=$(tail -5 "$error_log" 2>/dev/null | jq -r '.error // .message // .error_hash // empty' 2>/dev/null | sort | uniq -c | sort -rn | head -1 || true)
        local repeat_count
        repeat_count=$(echo "$last_errors" | awk '{print $1}' 2>/dev/null || echo "0")
        if [[ "${repeat_count:-0}" -ge 3 ]]; then
            stuckness_signals=$((stuckness_signals + 1))
            stuckness_reasons+=("same error repeated ${repeat_count} times")
        fi
    fi

    # Signal 5: Exit code pattern — last 3 iterations had same non-zero exit code
    if [[ -f "$tracking_file" ]] && [[ "$tracking_lines" -ge 3 ]]; then
        local last_three_exits
        last_three_exits=$(tail -3 "$tracking_file" 2>/dev/null | cut -d'|' -f3 || true)
        local first_exit
        first_exit=$(echo "$last_three_exits" | head -1)
        if [[ "$first_exit" =~ ^[0-9]+$ ]] && [[ "$first_exit" -ne 0 ]]; then
            local all_same=true
            while IFS= read -r ex; do
                [[ "$ex" != "$first_exit" ]] && all_same=false
            done <<< "$last_three_exits"
            if [[ "$all_same" == true ]]; then
                stuckness_signals=$((stuckness_signals + 1))
                stuckness_reasons+=("same non-zero exit code (${first_exit}) in last 3 iterations")
            fi
        fi
    fi

    # Signal 6: Git diff size — no or minimal code changes (existing)
    local diff_lines
    diff_lines=$(git -C "${PROJECT_ROOT:-.}" diff HEAD 2>/dev/null | wc -l | tr -d ' ' || true)
    diff_lines="${diff_lines:-0}"
    if [[ "${diff_lines:-0}" -lt 5 ]] && [[ "$iteration" -gt 2 ]]; then
        stuckness_signals=$((stuckness_signals + 1))
        stuckness_reasons+=("no code changes in last iteration")
    fi

    # Signal 7: Iteration budget — used >70% without passing tests
    local max_iter="${MAX_ITERATIONS:-20}"
    local progress_pct=0
    if [[ "$max_iter" -gt 0 ]]; then
        progress_pct=$(( iteration * 100 / max_iter ))
    fi
    if [[ "$progress_pct" -gt 70 ]] && [[ "${TEST_PASSED:-false}" != "true" ]]; then
        stuckness_signals=$((stuckness_signals + 1))
        stuckness_reasons+=("used ${progress_pct}% of iteration budget without passing tests")
    fi

    # Gate-aware dampening: if tests pass and the agent has made progress overall,
    # reduce stuckness signal count. The "no code changes" and "identical diffs" signals
    # fire when code is already complete and the agent is fighting evaluator quirks —
    # that's not genuine stuckness, it's "done but gates disagree."
    if [[ "${TEST_PASSED:-}" == "true" ]] && [[ "$stuckness_signals" -ge 2 ]]; then
        # If at least one quality signal is positive, dampen by 1
        if [[ "${AUDIT_RESULT:-}" == "pass" ]] || $QUALITY_GATE_PASSED 2>/dev/null; then
            stuckness_signals=$((stuckness_signals - 1))
        fi
    fi

    # Decision: 2+ signals = stuck
    if [[ "$stuckness_signals" -ge 2 ]]; then
        STUCKNESS_COUNT=$(( STUCKNESS_COUNT + 1 ))
        STUCKNESS_DIAGNOSIS="${stuckness_reasons[*]}"
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.stuckness_detected" "signals=$stuckness_signals" "count=$STUCKNESS_COUNT" "iteration=$iteration" "reasons=${stuckness_reasons[*]}"
        fi
        STUCKNESS_HINT="IMPORTANT: The loop appears stuck. Previous approaches have not worked. You MUST try a fundamentally different strategy. Reasons: ${stuckness_reasons[*]}"
        warn "Stuckness detected (${stuckness_signals} signals, count ${STUCKNESS_COUNT}): ${stuckness_reasons[*]}"

        local diff_summary=""
        local log1="$LOG_DIR/iteration-$(( iteration - 1 )).log"
        local log3="$LOG_DIR/iteration-$(( iteration - 3 )).log"
        if [[ -f "$log3" && -f "$log1" ]]; then
            diff_summary=$(diff <(tail -30 "$log3" 2>/dev/null) <(tail -30 "$log1" 2>/dev/null) 2>/dev/null | head -10 || true)
        fi

        local alternatives=""
        if type memory_inject_context >/dev/null 2>&1; then
            alternatives=$(memory_inject_context "build" 2>/dev/null | grep -i "fix:" | head -3 || true)
        fi

        cat <<STUCK_SECTION
## Stuckness Detected
${STUCKNESS_HINT}

${diff_summary:+Changes between recent iterations:
$diff_summary
}
${alternatives:+Consider these alternative approaches from past fixes:
$alternatives
}
Try a fundamentally different approach:
- Break the problem into smaller steps
- Look for an entirely different implementation strategy
- Check if there's a dependency or configuration issue blocking progress
- Read error messages more carefully — the root cause may differ from your assumption
STUCK_SECTION
        return 0
    fi

    return 1
}

# ─── Adaptive Iteration Budget ──────────────────────────────────────────────
# Reads tuning config for smarter iteration/circuit-breaker thresholds.
apply_adaptive_budget() {
    local tuning_file="$HOME/.shipwright/optimization/loop-tuning.json"
    if [[ -f "$tuning_file" ]] && command -v jq >/dev/null 2>&1; then
        local tuned_max tuned_ext tuned_ext_count tuned_cb
        tuned_max=$(jq -r '.max_iterations // ""' "$tuning_file" 2>/dev/null || echo "")
        tuned_ext=$(jq -r '.extension_size // ""' "$tuning_file" 2>/dev/null || echo "")
        tuned_ext_count=$(jq -r '.max_extensions // ""' "$tuning_file" 2>/dev/null || echo "")
        tuned_cb=$(jq -r '.circuit_breaker_threshold // ""' "$tuning_file" 2>/dev/null || echo "")

        # Only apply tuned values if user didn't explicitly set them
        if ! $MAX_ITERATIONS_EXPLICIT && [[ -n "$tuned_max" && "$tuned_max" != "null" ]]; then
            MAX_ITERATIONS="$tuned_max"
        fi
        [[ -n "$tuned_ext" && "$tuned_ext" != "null" ]] && EXTENSION_SIZE="$tuned_ext"
        [[ -n "$tuned_ext_count" && "$tuned_ext_count" != "null" ]] && MAX_EXTENSIONS="$tuned_ext_count"
        [[ -n "$tuned_cb" && "$tuned_cb" != "null" ]] && CIRCUIT_BREAKER_THRESHOLD="$tuned_cb"
    fi

    # Read learned iteration model
    local _iter_model="${HOME}/.shipwright/optimization/iteration-model.json"
    if [[ -f "$_iter_model" ]] && ! $MAX_ITERATIONS_EXPLICIT && command -v jq >/dev/null 2>&1; then
        local _complexity="${ISSUE_COMPLEXITY:-${COMPLEXITY:-medium}}"
        local _predicted_max
        _predicted_max=$(jq -r --arg c "$_complexity" '.predictions[$c].max_iterations // ""' "$_iter_model" 2>/dev/null) || true
        if [[ -n "${_predicted_max:-}" && "${_predicted_max:-}" != "null" && "${_predicted_max:-0}" -gt 0 ]]; then
            MAX_ITERATIONS="${_predicted_max}"
            info "Iteration model: ${_complexity} complexity → max ${_predicted_max} iterations"
        fi
    fi

    # Try intelligence-based iteration estimate
    if type intelligence_estimate_iterations >/dev/null 2>&1 && ! $MAX_ITERATIONS_EXPLICIT; then
        local est
        est=$(intelligence_estimate_iterations "${GOAL:-}" "${COMPLEXITY:-5}" 2>/dev/null || echo "")
        if [[ -n "$est" && "$est" =~ ^[0-9]+$ ]]; then
            MAX_ITERATIONS="$est"
        fi
    fi
}

# ─── Failure Diagnosis ────────────────────────────────────────────────────────
# Pattern-based root-cause classification for smarter retries (no Claude needed).
# Returns markdown context to inject into the next iteration's goal.
diagnose_failure() {
    local error_output="$1"
    local changed_files="$2"
    local iteration="$3"

    local diagnosis=""
    local strategy="retry_with_context"  # default

    # Pattern-based classification (fast, no Claude needed)
    if echo "$error_output" | grep -qiE 'import.*not found|cannot find module|no module named'; then
        diagnosis="missing_import"
        strategy="fix_imports"
    elif echo "$error_output" | grep -qiE 'syntax error|unexpected token|parse error'; then
        diagnosis="syntax_error"
        strategy="fix_syntax"
    elif echo "$error_output" | grep -qiE 'type.*not assignable|type error|TypeError'; then
        diagnosis="type_error"
        strategy="fix_types"
    elif echo "$error_output" | grep -qiE 'undefined.*variable|not defined|ReferenceError'; then
        diagnosis="undefined_reference"
        strategy="fix_references"
    elif echo "$error_output" | grep -qiE 'timeout|timed out|ETIMEDOUT'; then
        diagnosis="timeout"
        strategy="optimize_performance"
    elif echo "$error_output" | grep -qiE 'assertion.*fail|expect.*to|AssertionError'; then
        diagnosis="test_assertion"
        strategy="fix_logic"
    elif echo "$error_output" | grep -qiE 'permission denied|EACCES|forbidden'; then
        diagnosis="permission_error"
        strategy="fix_permissions"
    elif echo "$error_output" | grep -qiE 'out of memory|heap|OOM|ENOMEM'; then
        diagnosis="resource_error"
        strategy="reduce_resource_usage"
    else
        diagnosis="unknown"
        strategy="retry_with_context"
    fi

    # Check if we've seen this diagnosis before in this session
    local diagnosis_file="${LOG_DIR}/diagnoses.txt"
    local repeat_count=0
    if [[ -f "$diagnosis_file" ]]; then
        repeat_count=$(grep -c "^${diagnosis}$" "$diagnosis_file" 2>/dev/null || true)
        repeat_count="${repeat_count:-0}"
    fi
    echo "$diagnosis" >> "$diagnosis_file"

    # Escalate strategy if same diagnosis repeats
    if [[ "$repeat_count" -ge 2 ]]; then
        strategy="alternative_approach"
    fi

    # Try memory-based fix lookup
    local known_fix=""
    if type memory_query_fix_for_error &>/dev/null; then
        local fix_json
        fix_json=$(memory_query_fix_for_error "$error_output" 2>/dev/null || true)
        if [[ -n "$fix_json" && "$fix_json" != "null" ]]; then
            known_fix=$(echo "$fix_json" | jq -r '.fix // ""' 2>/dev/null | head -5)
        fi
    fi

    # Build diagnosis context for Claude
    local diagnosis_context="## Failure Diagnosis (Iteration $iteration)
Classification: $diagnosis
Strategy: $strategy
Repeat count: $repeat_count"

    if [[ -n "$known_fix" ]]; then
        diagnosis_context+="
Known fix from memory: $known_fix"
    fi

    # Strategy-specific guidance
    case "$strategy" in
        fix_imports)
            diagnosis_context+="
INSTRUCTION: The error is about missing imports/modules. Check that all imports are correct, packages are installed, and paths are right. Do NOT change the logic - just fix the imports."
            ;;
        fix_syntax)
            diagnosis_context+="
INSTRUCTION: This is a syntax error. Carefully check the exact line mentioned in the error. Look for missing brackets, semicolons, commas, or mismatched quotes."
            ;;
        fix_types)
            diagnosis_context+="
INSTRUCTION: Type mismatch error. Check the types at the error location. Ensure function signatures match their usage."
            ;;
        fix_logic)
            diagnosis_context+="
INSTRUCTION: Test assertion failure. The code logic is wrong, not the syntax. Re-read the test expectations and fix the implementation to match."
            ;;
        alternative_approach)
            diagnosis_context+="
INSTRUCTION: This error has occurred $repeat_count times. The previous approach is not working. Try a FUNDAMENTALLY DIFFERENT approach:
- If you were modifying existing code, try rewriting the function from scratch
- If you were using one library, try a different one
- If you were adding to a file, try creating a new file instead
- Step back and reconsider the requirements"
            ;;
    esac

    echo "$diagnosis_context"
}

# ─── Quality Gates ────────────────────────────────────────────────────────────
run_quality_gates() {
    if ! $QUALITY_GATES_ENABLED; then
        QUALITY_GATE_PASSED=true
        return
    fi

    QUALITY_GATE_PASSED=true
    local gate_failures=()

    echo -e "  ${PURPLE}▸${RESET} Running quality gates..."

    # Gate 1: Tests pass (if TEST_CMD set)
    if [[ -n "$TEST_CMD" ]] && [[ "$TEST_PASSED" == "false" ]]; then
        gate_failures+=("tests failing")
    fi

    # Gate 2: No uncommitted changes
    if ! git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null || \
       ! git -C "$PROJECT_ROOT" diff --cached --quiet 2>/dev/null; then
        gate_failures+=("uncommitted changes present")
    fi

    # Gate 3: No TODO/FIXME/HACK/XXX in new source code
    # Exclude .claude/, docs/plans/, and markdown files (which legitimately contain task markers)
    local todo_count
    todo_count="$(git -C "$PROJECT_ROOT" diff HEAD~1 -- ':!.claude/' ':!docs/plans/' ':!*.md' 2>/dev/null \
        | grep -cE '^\+.*(TODO|FIXME|HACK|XXX)' || true)"
    todo_count="${todo_count:-0}"
    if [[ "${todo_count:-0}" -gt 0 ]]; then
        gate_failures+=("${todo_count} TODO/FIXME/HACK/XXX markers in new code")
    fi

    # Gate 4: Definition of Done (if DOD_FILE set)
    if [[ -n "$DOD_FILE" ]]; then
        if ! check_definition_of_done; then
            gate_failures+=("definition of done not satisfied")
        fi
    fi

    if [[ ${#gate_failures[@]} -gt 0 ]]; then
        QUALITY_GATE_PASSED=false
        local failures_str
        failures_str="$(printf ', %s' "${gate_failures[@]}")"
        failures_str="${failures_str:2}"  # trim leading ", "
        echo -e "  ${RED}✗${RESET} Quality gates: FAILED (${failures_str})"
    else
        echo -e "  ${GREEN}✓${RESET} Quality gates: all passed"
    fi
}

check_definition_of_done() {
    if [[ ! -f "$DOD_FILE" ]]; then
        warn "Definition of done file not found: $DOD_FILE"
        return 1
    fi

    local dod_content
    dod_content="$(cat "$DOD_FILE")"

    # Use cumulative diff from loop start (not just HEAD~1) so the evaluator
    # can see ALL work done across every iteration, not just the latest commit.
    local diff_content
    if [[ -n "${LOOP_START_COMMIT:-}" ]]; then
        diff_content="$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null || echo "(no diff)")"
        diff_content="${diff_content}

## Detailed Changes (cumulative diff, truncated to 200 lines)
$(git -C "$PROJECT_ROOT" diff "${LOOP_START_COMMIT}..HEAD" 2>/dev/null | head -200 || echo "(no diff)")"
    else
        diff_content="$(git -C "$PROJECT_ROOT" diff HEAD~1 2>/dev/null || echo "(no diff)")"
    fi

    # Inject verified runtime facts so the evaluator doesn't have to guess
    local runtime_facts=""
    if [[ -n "$TEST_CMD" ]]; then
        if [[ "${TEST_PASSED:-}" == "true" ]]; then
            runtime_facts="## Verified Runtime Facts (from the loop harness, not from the agent)
- Tests: ALL PASSING (verified by running '${TEST_CMD}' after this iteration)
- Test output (last 10 lines):
$(echo "${TEST_OUTPUT:-}" | tail -10)"
        else
            runtime_facts="## Verified Runtime Facts
- Tests: FAILING (verified by running '${TEST_CMD}')
- Test output (last 10 lines):
$(echo "${TEST_OUTPUT:-}" | tail -10)"
        fi
    fi

    local dod_prompt
    read -r -d '' dod_prompt <<DOD_PROMPT || true
You are evaluating whether a project satisfies a Definition of Done checklist.
You are reviewing the CUMULATIVE work across all iterations, not just the latest commit.

## Definition of Done
${dod_content}

${runtime_facts}

## Cumulative Changes Made (git diff from start of loop to now)
${diff_content}

## Your Task
For each item in the Definition of Done, determine if the project satisfies it.
The runtime facts above are verified by the harness — trust them as ground truth.
If ALL items are satisfied, output exactly: DOD_PASS
Otherwise, list which items are NOT satisfied and why.
DOD_PROMPT

    local dod_log="$LOG_DIR/dod-iter-${ITERATION}.log"
    local dod_model
    dod_model="$(select_audit_model)"
    local dod_flags=()
    dod_flags+=("--model" "$dod_model")
    if $SKIP_PERMISSIONS; then
        dod_flags+=("--dangerously-skip-permissions")
    fi

    claude -p "$dod_prompt" "${dod_flags[@]}" > "$dod_log" 2>&1 || true

    if grep -q "DOD_PASS" "$dod_log" 2>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} Definition of Done: satisfied"
        return 0
    else
        echo -e "  ${YELLOW}⚠${RESET} Definition of Done: not satisfied"
        return 1
    fi
}

# ─── Guarded Completion ───────────────────────────────────────────────────────
guard_completion() {
    local log_file="$LOG_DIR/iteration-${ITERATION}.log"

    # Check if LOOP_COMPLETE is in the log
    if ! grep -q "LOOP_COMPLETE" "$log_file" 2>/dev/null; then
        return 1  # No completion claim
    fi

    echo -e "  ${CYAN}▸${RESET} LOOP_COMPLETE detected — validating..."

    local rejection_reasons=()

    # Check quality gates
    if ! $QUALITY_GATE_PASSED; then
        rejection_reasons+=("quality gates failed")
    fi

    # Check audit agent
    if $AUDIT_AGENT_ENABLED && [[ "$AUDIT_RESULT" != "pass" ]]; then
        rejection_reasons+=("audit agent found issues")
    fi

    # Check tests
    if [[ -n "$TEST_CMD" ]] && [[ "$TEST_PASSED" == "false" ]]; then
        rejection_reasons+=("tests failing")
    fi

    # Holistic final gate: when all other gates pass, run a project-level assessment
    # that evaluates the entire codebase against the goal (not just the latest diff)
    if [[ ${#rejection_reasons[@]} -eq 0 ]]; then
        if ! run_holistic_gate; then
            rejection_reasons+=("holistic project assessment found gaps")
        fi
    fi

    if [[ ${#rejection_reasons[@]} -gt 0 ]]; then
        local reasons_str
        reasons_str="$(printf ', %s' "${rejection_reasons[@]}")"
        reasons_str="${reasons_str:2}"
        echo -e "  ${RED}✗${RESET} Completion REJECTED: ${reasons_str}"
        COMPLETION_REJECTED=true
        return 1
    fi

    echo -e "  ${GREEN}${BOLD}✓ LOOP_COMPLETE accepted — all gates passed!${RESET}"
    return 0
}

# Holistic gate: evaluates the full project against the original goal.
# Only runs when all other gates pass (final checkpoint before acceptance).
run_holistic_gate() {
    # Skip if no starting commit (can't compute cumulative diff)
    [[ -z "${LOOP_START_COMMIT:-}" ]] && return 0

    local holistic_log="$LOG_DIR/holistic-iter-${ITERATION}.log"

    # Build a project summary: file tree, test count, cumulative diff stats
    local file_count
    file_count=$(git -C "$PROJECT_ROOT" ls-files | wc -l | tr -d ' ')
    local cumulative_stat
    cumulative_stat="$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null | tail -1 || echo "(no changes)")"
    local test_summary=""
    if [[ -n "${TEST_OUTPUT:-}" ]]; then
        test_summary="$(echo "$TEST_OUTPUT" | tail -5)"
    fi

    local holistic_prompt
    read -r -d '' holistic_prompt <<HOLISTIC_PROMPT || true
You are a final quality gate evaluating whether an autonomous coding agent has FULLY achieved its goal.

## Original Goal
${GOAL}

## Project Stats
- Files in repo: ${file_count}
- Iterations completed: ${ITERATION}
- Cumulative changes: ${cumulative_stat}
- Tests: ${TEST_PASSED:-unknown} (command: ${TEST_CMD:-none})
${test_summary:+- Test output: ${test_summary}}

## Cumulative Git Changes (diff --stat from start)
$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null | head -40 || echo "(none)")

## Your Task
Based on the goal and the cumulative work done:
1. Has the goal been FULLY achieved (not partially)?
2. Is there any critical gap that would make this unacceptable for production?

If the goal is fully achieved, output exactly: HOLISTIC_PASS
Otherwise, list the specific gaps remaining.
HOLISTIC_PROMPT

    echo -e "  ${PURPLE}▸${RESET} Running holistic project assessment..."

    local hol_model
    hol_model="$(select_audit_model)"
    local hol_flags=("--model" "$hol_model")
    if $SKIP_PERMISSIONS; then
        hol_flags+=("--dangerously-skip-permissions")
    fi

    claude -p "$holistic_prompt" "${hol_flags[@]}" > "$holistic_log" 2>&1 || true

    if grep -q "HOLISTIC_PASS" "$holistic_log" 2>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} Holistic assessment: passed"
        return 0
    else
        echo -e "  ${YELLOW}⚠${RESET} Holistic assessment: gaps found"
        return 1
    fi
}
