#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  session-restart — Intelligent session restart with enhanced resume      ║
# ║                                                                         ║
# ║  Captures rich context before restart, generates strategic briefings    ║
# ║  for new sessions, and tracks progress across multiple restarts.        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard - prevent double-sourcing
[[ -n "${_SESSION_RESTART_LOADED:-}" ]] && return 0
_SESSION_RESTART_LOADED=1

VERSION="3.3.0"

# ─── State Capture ─────────────────────────────────────────────────────────

restart_capture_state() {
    local state_file="${ARTIFACTS_DIR:-${LOG_DIR}}/restart-state.json"
    local tmp_state="${state_file}.tmp.$$"

    # Ensure ARTIFACTS_DIR exists
    mkdir -p "${ARTIFACTS_DIR:-${LOG_DIR}}" 2>/dev/null || true

    # Capture git state
    local current_branch commit_hash diff_stat uncommitted_changes
    current_branch="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    commit_hash="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")"
    diff_stat="$(git -C "$PROJECT_ROOT" diff --stat HEAD 2>/dev/null || echo "")"
    uncommitted_changes=$(git -C "$PROJECT_ROOT" status --short 2>/dev/null | wc -l)

    # Capture test state
    local test_status test_results
    test_status="${TEST_PASSED:-unknown}"
    test_results=""
    if [[ -f "$LOG_DIR/tests-iter-${ITERATION}.log" ]]; then
        test_results="$(tail -20 "$LOG_DIR/tests-iter-${ITERATION}.log" 2>/dev/null || echo "")"
    fi

    # Capture progress metrics
    local iterations_completed failed_iterations tests_passed_count tests_failed_count
    iterations_completed="${ITERATION:-0}"
    failed_iterations="${CONSECUTIVE_FAILURES:-0}"
    tests_passed_count=$(grep -c "✓ PASSED" "$LOG_DIR/progress.md" 2>/dev/null || echo "0")
    tests_failed_count=$(grep -c "✗ FAILED" "$LOG_DIR/progress.md" 2>/dev/null || echo "0")

    # Capture modified files
    local modified_files created_files deleted_files
    modified_files="$(git -C "$PROJECT_ROOT" diff --name-only HEAD~5 2>/dev/null | head -30 || echo "")"
    created_files="$(git -C "$PROJECT_ROOT" diff --diff-filter=A --name-only HEAD~5 2>/dev/null | head -10 || echo "")"
    deleted_files="$(git -C "$PROJECT_ROOT" diff --diff-filter=D --name-only HEAD~5 2>/dev/null | head -10 || echo "")"

    # Recent error summary
    local recent_error=""
    if [[ -f "$LOG_DIR/error-summary.json" ]]; then
        recent_error="$(jq -r '.error_summary // ""' "$LOG_DIR/error-summary.json" 2>/dev/null || echo "")"
    fi

    # Build JSON atomically
    {
        printf '{\n'
        printf '  "timestamp": "%s",\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf '  "restart_count": %d,\n' "${RESTART_COUNT:-0}"
        printf '  "max_restarts": %d,\n' "${MAX_RESTARTS:-0}"
        printf '  "goal": %s,\n' "$(echo "$GOAL" | jq -Rs .)"
        printf '  "git": {\n'
        printf '    "branch": %s,\n' "$(echo "$current_branch" | jq -Rs .)"
        printf '    "commit": %s,\n' "$(echo "$commit_hash" | jq -Rs .)"
        printf '    "uncommitted_changes": %d\n' "$uncommitted_changes"
        printf '  },\n'
        printf '  "progress": {\n'
        printf '    "iteration": %d,\n' "$iterations_completed"
        printf '    "max_iterations": %d,\n' "${MAX_ITERATIONS:-0}"
        printf '    "test_status": %s,\n' "$(echo "$test_status" | jq -Rs .)"
        printf '    "tests_passed": %d,\n' "$tests_passed_count"
        printf '    "tests_failed": %d,\n' "$tests_failed_count"
        printf '    "consecutive_failures": %d\n' "$failed_iterations"
        printf '  },\n'
        printf '  "files": {\n'
        printf '    "modified": %s,\n' "$(echo "$modified_files" | jq -Rs .)"
        printf '    "created": %s,\n' "$(echo "$created_files" | jq -Rs .)"
        printf '    "deleted": %s\n' "$(echo "$deleted_files" | jq -Rs .)"
        printf '  },\n'
        printf '  "errors": %s\n' "$(echo "$recent_error" | jq -Rs .)"
        printf '}\n'
    } > "$tmp_state" 2>/dev/null

    if mv "$tmp_state" "$state_file" 2>/dev/null; then
        emit_event "session.restart_capture" "state_file=$state_file" "iteration=$ITERATION" "restart=$RESTART_COUNT" 2>/dev/null || true
        echo "$state_file"
        return 0
    else
        warn "Failed to write restart state to $state_file"
        rm -f "$tmp_state"
        return 1
    fi
}

# ─── Briefing Generation ──────────────────────────────────────────────────

restart_generate_briefing() {
    local state_file="${1:-${ARTIFACTS_DIR:-${LOG_DIR}}/restart-state.json}"
    local briefing_file="${ARTIFACTS_DIR:-${LOG_DIR}}/restart-briefing.md"
    local tmp_briefing="${briefing_file}.tmp.$$"

    [[ ! -f "$state_file" ]] && {
        warn "Restart state file not found: $state_file"
        return 1
    }

    # Parse state JSON
    local goal iteration max_iter test_status tests_passed tests_failed
    local modified_files recent_error restart_count
    goal="$(jq -r '.goal // ""' "$state_file" 2>/dev/null || echo "")"
    iteration="$(jq -r '.progress.iteration // 0' "$state_file" 2>/dev/null || echo "0")"
    max_iter="$(jq -r '.progress.max_iterations // 0' "$state_file" 2>/dev/null || echo "0")"
    test_status="$(jq -r '.progress.test_status // "unknown"' "$state_file" 2>/dev/null || echo "unknown")"
    tests_passed="$(jq -r '.progress.tests_passed // 0' "$state_file" 2>/dev/null || echo "0")"
    tests_failed="$(jq -r '.progress.tests_failed // 0' "$state_file" 2>/dev/null || echo "0")"
    modified_files="$(jq -r '.files.modified // ""' "$state_file" 2>/dev/null || echo "")"
    recent_error="$(jq -r '.errors // ""' "$state_file" 2>/dev/null || echo "")"
    restart_count="$(jq -r '.restart_count // 0' "$state_file" 2>/dev/null || echo "0")"

    # Generate briefing sections
    {
        printf '# Session Restart Briefing #%d\n\n' "$restart_count"

        printf '## What'"'"'s Done ✓\n'
        printf '- Completed **%d of %d** iterations\n' "$iteration" "$max_iter"
        printf '- Tests: %d passed, %d failed\n' "$tests_passed" "$tests_failed"
        if [[ "$test_status" == "true" ]]; then
            printf '- **Tests are currently PASSING** — maintain momentum\n'
        else
            printf '- **Tests are currently FAILING** — focus on fixing\n'
        fi
        printf '\n'

        printf '## What'"'"'s Failing 🔴\n'
        if [[ -n "$recent_error" && "$recent_error" != "null" ]]; then
            printf '%s\n\n' "$recent_error"
        else
            printf '- No specific error captured yet — check test output\n\n'
        fi

        printf '## Modified Files 📝\n'
        if [[ -n "$modified_files" && "$modified_files" != "null" && "$modified_files" != "" ]]; then
            printf '%s\n\n' "$modified_files"
        else
            printf '- No files modified yet\n\n'
        fi

        printf '## What to Try Next 🎯\n'
        if [[ "$test_status" == "true" ]]; then
            printf '- Tests are passing: focus on incomplete features\n'
            printf '- Do NOT re-run passing tests — save context\n'
            printf '- Commit frequently to preserve progress\n'
        elif [[ "$tests_failed" -gt "$tests_passed" ]]; then
            printf '- Fix the FAILING tests first\n'
            printf '- Start with the most common error pattern\n'
            printf '- Read error output carefully before changing code\n'
        else
            printf '- Balance between fixing tests and adding features\n'
        fi
        printf '\n'

        printf '## What NOT to Try (Previous Failures) 🚫\n'
        printf '- Do not repeat failed iterations without understanding why\n'
        printf '- Do not ignore test failures — they indicate real problems\n'
        printf '- Do not modify files already committed unless necessary\n'
        printf '\n'

        printf '---\n'
        printf 'Resume point: Iteration %d/%d at %s\n' "$iteration" "$max_iter" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf 'Use %s for detailed state.\n' "$(basename "$state_file")"

    } > "$tmp_briefing" 2>/dev/null

    if mv "$tmp_briefing" "$briefing_file" 2>/dev/null; then
        emit_event "session.briefing_generated" "briefing_file=$briefing_file" "iteration=$iteration" 2>/dev/null || true
        echo "$briefing_file"
        return 0
    else
        warn "Failed to write briefing to $briefing_file"
        rm -f "$tmp_briefing"
        return 1
    fi
}

# ─── Restart Reason Detection ──────────────────────────────────────────────

restart_detect_reason() {
    local iteration="${1:-${ITERATION:-0}}"
    local max_iterations="${2:-${MAX_ITERATIONS:-0}}"
    local test_status="${3:-${TEST_PASSED:-unknown}}"
    local consecutive_failures="${4:-${CONSECUTIVE_FAILURES:-0}}"
    local manual="${5:-false}"

    local reason classification evidence

    # Check for manual restart (from user signal)
    if [[ "$manual" == "true" ]]; then
        reason="manual"
        evidence="User triggered restart via signal or command"
        classification="manual"
    # Context exhaustion needs evidence (the classifier matched the window-full
    # patterns) — running out of iterations alone is not running out of context
    elif [[ "${LAST_ITERATION_CLASS:-}" == "context_exhaustion" ]] ||
         [[ "${LOOP_EXIT_CLASS:-}" == "context_exhaustion" ]] ||
         [[ "${STATUS:-}" == context_exhaustion* ]]; then
        reason="context_exhaustion"
        evidence="Context window exhaustion detected at iteration $iteration/$max_iterations"
        classification="context_exhaustion"
    # Flatline: iterations ran but changed nothing and failed the same way
    elif [[ "${LOOP_EXIT_CLASS:-}" == "flatline" ]] ||
         { [[ "${FLATLINE_STREAK:-0}" =~ ^[0-9]+$ ]] && [[ "${FLATLINE_STREAK:-0}" -ge "${FLATLINE_THRESHOLD:-3}" ]]; }; then
        reason="flatline"
        evidence="${FLATLINE_STREAK:-0} consecutive iterations with no code change and the same failure"
        classification="flatline"
    # Check for iteration limit hit
    elif [[ "$iteration" -ge "$max_iterations" ]] && [[ "$max_iterations" -gt 0 ]]; then
        reason="iteration_limit"
        evidence="Hit max iterations ($max_iterations)"
        classification="iteration_limit"
    # Check for stuck loop (same error multiple times)
    elif [[ "$consecutive_failures" -ge 3 ]]; then
        reason="stuck_loop"
        evidence="$consecutive_failures consecutive failures without progress"
        classification="stuck_loop"
    else
        reason="unknown"
        evidence="Unable to classify restart reason"
        classification="unknown"
    fi

    # Output as JSON for machine parsing
    local tmp_reason="${ARTIFACTS_DIR:-${LOG_DIR}}/restart-reason.json"
    mkdir -p "${ARTIFACTS_DIR:-${LOG_DIR}}" 2>/dev/null || true
    {
        printf '{\n'
        printf '  "classification": %s,\n' "$(echo "$classification" | jq -Rs .)"
        printf '  "reason": %s,\n' "$(echo "$reason" | jq -Rs .)"
        printf '  "evidence": %s,\n' "$(echo "$evidence" | jq -Rs .)"
        printf '  "iteration": %d,\n' "$iteration"
        printf '  "max_iterations": %d,\n' "$max_iterations"
        printf '  "consecutive_failures": %d,\n' "$consecutive_failures"
        printf '  "timestamp": %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ" | jq -Rs .)"
        printf '}\n'
    } > "$tmp_reason" 2>/dev/null
    mv "$tmp_reason" "${tmp_reason%.tmp.$$}" 2>/dev/null || true

    emit_event "session.restart_reason" "classification=$classification" "reason=$reason" "iteration=$iteration" 2>/dev/null || true

    # Also output to stdout for caller to capture
    echo "$classification"
    return 0
}

# ─── Strategy Suggestion ───────────────────────────────────────────────────

restart_suggest_strategy() {
    local reason="${1:-unknown}"
    local goal="${2:-${GOAL:-}}"
    local test_status="${3:-${TEST_PASSED:-unknown}}"

    local strategy priority focus avoid

    case "$reason" in
        context_exhaustion)
            strategy="Focus on remaining failing tests, don't re-read files already committed"
            priority="high"
            focus="Complete failing tests and features"
            avoid="Re-reading entire files, verbose exploration"
            ;;
        iteration_limit)
            strategy="Prioritize the highest-impact remaining work"
            priority="high"
            focus="Most critical features for goal completion"
            avoid="Low-impact improvements, refactoring"
            ;;
        flatline)
            strategy="Stop repeating the last attempt — recent iterations changed no code and hit the same failure. Re-read the exact error and try a different approach"
            priority="critical"
            focus="The single repeated failure and the assumption behind the failed attempts"
            avoid="Re-running the same fix, exploring without committing a change"
            ;;
        stuck_loop)
            strategy="Try a fundamentally different approach to the current problem"
            priority="critical"
            focus="Root cause analysis of the stuck point"
            avoid="Repeated small changes that didn't work before"
            ;;
        manual)
            strategy="Continue from where you left off with fresh context"
            priority="normal"
            focus="Completing the goal"
            avoid="Repeating already-completed work"
            ;;
        *)
            strategy="Analyze progress and continue toward goal"
            priority="normal"
            focus="Making measurable progress on the goal"
            avoid="Repeating failed approaches"
            ;;
    esac

    # Output structured strategy JSON
    local tmp_strat="${ARTIFACTS_DIR:-${LOG_DIR}}/restart-strategy.json"
    mkdir -p "${ARTIFACTS_DIR:-${LOG_DIR}}" 2>/dev/null || true
    {
        printf '{\n'
        printf '  "reason": %s,\n' "$(echo "$reason" | jq -Rs .)"
        printf '  "strategy": %s,\n' "$(echo "$strategy" | jq -Rs .)"
        printf '  "priority": %s,\n' "$(echo "$priority" | jq -Rs .)"
        printf '  "focus": %s,\n' "$(echo "$focus" | jq -Rs .)"
        printf '  "avoid": %s,\n' "$(echo "$avoid" | jq -Rs .)"
        printf '  "goal": %s,\n' "$(echo "$goal" | jq -Rs .)"
        printf '  "test_status": %s,\n' "$(echo "$test_status" | jq -Rs .)"
        printf '  "timestamp": %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ" | jq -Rs .)"
        printf '}\n'
    } > "$tmp_strat" 2>/dev/null
    mv "$tmp_strat" "${tmp_strat%.tmp.$$}" 2>/dev/null || true

    emit_event "session.strategy_suggested" "reason=$reason" "priority=$priority" 2>/dev/null || true

    echo "$strategy"
    return 0
}

# ─── Cross-Session Tracking ───────────────────────────────────────────────

restart_track_across_sessions() {
    local history_file="${ARTIFACTS_DIR:-${LOG_DIR}}/restart-history.json"
    mkdir -p "${ARTIFACTS_DIR:-${LOG_DIR}}" 2>/dev/null || true

    # Get current state snapshot
    local restart_num="${RESTART_COUNT:-0}"
    local iteration="${ITERATION:-0}"
    local test_passed="${TEST_PASSED:-unknown}"
    local consecutive_failures="${CONSECUTIVE_FAILURES:-0}"

    # Build JSON entry first (avoid newline issues with proper escaping)
    local timestamp_clean="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local new_entry
    new_entry=$(printf '{"restart_number": %d, "iteration": %d, "test_passed": %s, "consecutive_failures": %d, "timestamp": %s}' \
        "$restart_num" \
        "$iteration" \
        "$(printf '%s' "$test_passed" | jq -Rs .)" \
        "$consecutive_failures" \
        "$(printf '%s' "$timestamp_clean" | jq -Rs .)")

    # Read existing array
    local existing_array="[]"
    if [[ -f "$history_file" ]] && jq . "$history_file" > /dev/null 2>&1; then
        existing_array=$(cat "$history_file")
    fi

    # Append new entry using jq
    local tmp_history="${history_file}.tmp.$$"
    if echo "$existing_array" | jq --argjson entry "$new_entry" '. += [$entry]' > "$tmp_history" 2>/dev/null; then
        if mv "$tmp_history" "$history_file" 2>/dev/null; then
            emit_event "session.tracked_restart" "restart=$restart_num" "iteration=$iteration" "history_file=$history_file" 2>/dev/null || true

            # Analyze pattern: if 3+ restarts with no test progress, recommend escalation
            local restart_count
            restart_count=$(jq 'length' "$history_file" 2>/dev/null || echo "0")
            if [[ "$restart_count" -ge 3 ]]; then
                local first_test last_test
                first_test=$(jq -r '.[0].test_passed // "unknown"' "$history_file" 2>/dev/null || echo "unknown")
                last_test=$(jq -r '.[-1].test_passed // "unknown"' "$history_file" 2>/dev/null || echo "unknown")
                if [[ "$first_test" == "$last_test" && "$last_test" == "false" ]]; then
                    warn "Pattern detected: 3+ restarts with no test progress. Consider escalation to human or different strategy."
                    emit_event "session.escalation_recommended" "restart=$restart_count" "test_status=$last_test" 2>/dev/null || true
                    return 1
                fi
            fi
            return 0
        else
            warn "Failed to move history file to $history_file"
            rm -f "$tmp_history"
            return 1
        fi
    else
        warn "Failed to append entry to restart history"
        rm -f "$tmp_history"
        return 1
    fi
}

# ─── Enhanced Progress File Writer ────────────────────────────────────────

restart_enhance_progress_md() {
    local progress_file="${1:-${LOG_DIR}/progress.md}"
    local tmp_progress="${progress_file}.tmp.$$"

    # Read existing progress if available
    local existing_content=""
    [[ -f "$progress_file" ]] && existing_content="$(cat "$progress_file" 2>/dev/null || true)"

    # Determine test summary
    local test_summary
    if [[ "${TEST_PASSED:-}" == "true" ]]; then
        test_summary="✓ PASSING"
    elif [[ "${TEST_PASSED:-}" == "false" ]]; then
        test_summary="✗ FAILING"
    else
        test_summary="? UNKNOWN"
    fi

    # Detect anti-patterns from log
    local antipatterns=""
    if [[ -f "$LOG_DIR/error-summary.json" ]]; then
        local err_count
        err_count=$(jq -r '.error_count // 0' "$LOG_DIR/error-summary.json" 2>/dev/null || echo "0")
        if [[ "$err_count" -gt 5 ]]; then
            antipatterns="$antipatterns
- Too many distinct errors — narrow focus to one problem at a time"
        fi
    fi
    if [[ "${CONSECUTIVE_FAILURES:-0}" -ge 2 ]]; then
        antipatterns="$antipatterns
- Multiple consecutive failures — reconsider the current approach"
    fi

    # Write enhanced progress (atomic)
    {
        printf -- '# Build Loop Progress — Iteration %d/%d\n\n' "${ITERATION:-0}" "${MAX_ITERATIONS:-0}"
        printf -- '## Status Summary\n'
        printf -- '- **Tests**: %s\n' "$test_summary"
        printf -- '- **Session Restart**: %d/%d\n' "${RESTART_COUNT:-0}" "${MAX_RESTARTS:-0}"
        printf -- '- **Consecutive Failures**: %d\n' "${CONSECUTIVE_FAILURES:-0}"
        printf -- '- **Updated**: %s\n\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

        if [[ -n "$existing_content" ]]; then
            printf -- '## Previous Content\n%s\n' "$existing_content"
        fi

        if [[ -n "$antipatterns" ]]; then
            printf -- '## Anti-Patterns to Avoid%s\n' "$antipatterns"
        fi

    } > "$tmp_progress" 2>/dev/null

    if mv "$tmp_progress" "$progress_file" 2>/dev/null; then
        emit_event "session.progress_enhanced" "progress_file=$progress_file" "iteration=${ITERATION:-0}" 2>/dev/null || true
        return 0
    else
        warn "Failed to write enhanced progress to $progress_file"
        rm -f "$tmp_progress"
        return 1
    fi
}

# ─── Main Integration Points ──────────────────────────────────────────────

# Called before session restart to save context
restart_before_restart() {
    info "Capturing restart state and briefing..."

    # Capture comprehensive state
    local state_file
    state_file=$(restart_capture_state) || {
        error "Failed to capture restart state"
        return 1
    }

    # Generate briefing for new session
    local briefing_file
    briefing_file=$(restart_generate_briefing "$state_file") || {
        error "Failed to generate restart briefing"
        return 1
    }

    # Detect restart reason
    local reason
    reason=$(restart_detect_reason) || true

    # Suggest strategy based on reason
    local strategy
    strategy=$(restart_suggest_strategy "$reason") || true

    # Track this restart across session history
    restart_track_across_sessions || {
        warn "Failed to track restart in history (continuing anyway)"
    }

    # Enhance progress.md with anti-patterns and summary
    restart_enhance_progress_md || {
        warn "Failed to enhance progress.md (continuing anyway)"
    }

    success "Restart preparation complete"
    info "State: $state_file"
    info "Briefing: $briefing_file"
    info "Strategy: $strategy"

    return 0
}

# Called after session restart to inject briefing into prompt
