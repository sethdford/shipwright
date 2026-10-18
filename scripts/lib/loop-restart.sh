#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_RESTART_LOADED:-}" ]] && return 0
_LOOP_RESTART_LOADED=1

# ─── State Management ────────────────────────────────────────────────────────

initialize_state() {
    ITERATION=0
    CONSECUTIVE_FAILURES=0
    TOTAL_COMMITS=0
    START_EPOCH="$(now_epoch)"
    STATUS="running"
    LOG_ENTRIES=""

    # Record starting commit for cumulative diff in quality gates
    LOOP_START_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")"

    write_state
}

resume_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        error "No state file found at $STATE_FILE"
        echo -e "  Start a new loop instead: ${DIM}shipwright loop \"<goal>\"${RESET}"
        exit 1
    fi

    info "Resuming from $STATE_FILE"

    # Save CLI values before parsing state (CLI takes precedence)
    local cli_max_iterations="$MAX_ITERATIONS"

    # Parse YAML front matter
    local in_frontmatter=false
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if $in_frontmatter; then
                break
            else
                in_frontmatter=true
                continue
            fi
        fi
        if $in_frontmatter; then
            case "$line" in
                goal:*)          [[ -z "$GOAL" ]] && GOAL="$(echo "${line#goal:}" | sed 's/^ *"//;s/" *$//')" ;;
                iteration:*)     ITERATION="$(echo "${line#iteration:}" | tr -d ' ')" ;;
                max_iterations:*) MAX_ITERATIONS="$(echo "${line#max_iterations:}" | tr -d ' ')" ;;
                status:*)        STATUS="$(echo "${line#status:}" | tr -d ' ')" ;;
                test_cmd:*)      [[ -z "$TEST_CMD" ]] && TEST_CMD="$(echo "${line#test_cmd:}" | sed 's/^ *"//;s/" *$//')" ;;
                model:*)         MODEL="$(echo "${line#model:}" | tr -d ' ')" ;;
                agents:*)        AGENTS="$(echo "${line#agents:}" | tr -d ' ')" ;;
                consecutive_failures:*) CONSECUTIVE_FAILURES="$(echo "${line#consecutive_failures:}" | tr -d ' ')" ;;
                total_commits:*) TOTAL_COMMITS="$(echo "${line#total_commits:}" | tr -d ' ')" ;;
                audit_enabled:*)         AUDIT_ENABLED="$(echo "${line#audit_enabled:}" | tr -d ' ')" ;;
                audit_agent_enabled:*)   AUDIT_AGENT_ENABLED="$(echo "${line#audit_agent_enabled:}" | tr -d ' ')" ;;
                quality_gates_enabled:*) QUALITY_GATES_ENABLED="$(echo "${line#quality_gates_enabled:}" | tr -d ' ')" ;;
                dod_file:*)              DOD_FILE="$(echo "${line#dod_file:}" | sed 's/^ *"//;s/" *$//')" ;;
                auto_extend:*)           AUTO_EXTEND="$(echo "${line#auto_extend:}" | tr -d ' ')" ;;
                extension_count:*)       EXTENSION_COUNT="$(echo "${line#extension_count:}" | tr -d ' ')" ;;
                max_extensions:*)        MAX_EXTENSIONS="$(echo "${line#max_extensions:}" | tr -d ' ')" ;;
                loop_start_commit:*)     LOOP_START_COMMIT="$(echo "${line#loop_start_commit:}" | sed 's/^ *"//;s/" *$//')" ;;
            esac
        fi
    done < "$STATE_FILE"

    # CLI --max-iterations overrides state file
    if $MAX_ITERATIONS_EXPLICIT; then
        MAX_ITERATIONS="$cli_max_iterations"
    fi

    # Extract the log section (everything after ## Log)
    LOG_ENTRIES="$(sed -n '/^## Log$/,$ { /^## Log$/d; p; }' "$STATE_FILE" 2>/dev/null || true)"

    if [[ -z "$GOAL" ]]; then
        error "Could not parse goal from state file."
        exit 1
    fi

    if [[ "$STATUS" == "complete" ]]; then
        warn "Previous loop completed. Start a new one or edit the state file."
        exit 0
    fi

    # Reset circuit breaker on resume
    CONSECUTIVE_FAILURES=0
    START_EPOCH="$(now_epoch)"
    STATUS="running"

    # If we hit max iterations before, warn user to extend
    if [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]] && ! $MAX_ITERATIONS_EXPLICIT; then
        warn "Previous run stopped at iteration $ITERATION/$MAX_ITERATIONS."
        echo -e "  Extend with: ${DIM}shipwright loop --resume --max-iterations $(( MAX_ITERATIONS + 10 ))${RESET}"
        exit 0
    fi

    # Restore Claude context for meaningful resume (source so exports persist to this shell)
    if [[ -f "$SCRIPT_DIR/sw-checkpoint.sh" ]] && [[ -d "${PROJECT_ROOT:-}" ]]; then
        source "$SCRIPT_DIR/sw-checkpoint.sh"
        local _orig_pwd="$PWD"
        cd "$PROJECT_ROOT" 2>/dev/null || true
        if checkpoint_restore_context "build" 2>/dev/null; then
            RESUMED_FROM_ITERATION="${RESTORED_ITERATION:-}"
            RESUMED_MODIFIED="${RESTORED_MODIFIED:-}"
            RESUMED_FINDINGS="${RESTORED_FINDINGS:-}"
            RESUMED_TEST_OUTPUT="${RESTORED_TEST_OUTPUT:-}"
            [[ -n "${RESTORED_ITERATION:-}" && "${RESTORED_ITERATION:-0}" -gt 0 ]] && info "Restored context from iteration ${RESTORED_ITERATION}"
        fi
        cd "$_orig_pwd" 2>/dev/null || true
    fi

    success "Resumed: iteration $ITERATION/$MAX_ITERATIONS"
}

write_state() {
    local tmp_state="${STATE_FILE}.tmp.$$"
    # Use printf instead of heredoc to avoid delimiter injection from GOAL
    {
        printf -- '---\n'
        printf 'goal: "%s"\n' "$GOAL"
        printf 'iteration: %s\n' "$ITERATION"
        printf 'max_iterations: %s\n' "$MAX_ITERATIONS"
        printf 'status: %s\n' "$STATUS"
        printf 'test_cmd: "%s"\n' "$TEST_CMD"
        printf 'model: %s\n' "$MODEL"
        printf 'agents: %s\n' "$AGENTS"
        printf 'started_at: %s\n' "$(now_iso)"
        printf 'last_iteration_at: %s\n' "$(now_iso)"
        printf 'consecutive_failures: %s\n' "$CONSECUTIVE_FAILURES"
        printf 'total_commits: %s\n' "$TOTAL_COMMITS"
        printf 'audit_enabled: %s\n' "$AUDIT_ENABLED"
        printf 'audit_agent_enabled: %s\n' "$AUDIT_AGENT_ENABLED"
        printf 'quality_gates_enabled: %s\n' "$QUALITY_GATES_ENABLED"
        printf 'dod_file: "%s"\n' "$DOD_FILE"
        printf 'auto_extend: %s\n' "$AUTO_EXTEND"
        printf 'extension_count: %s\n' "$EXTENSION_COUNT"
        printf 'max_extensions: %s\n' "$MAX_EXTENSIONS"
        printf 'loop_start_commit: "%s"\n' "${LOOP_START_COMMIT:-}"
        printf -- '---\n\n'
        printf '## Log\n'
        printf '%s\n' "$LOG_ENTRIES"
    } > "$tmp_state"
    if ! mv "$tmp_state" "$STATE_FILE" 2>/dev/null; then
        warn "Failed to write state file: $STATE_FILE"
        rm -f "$tmp_state"
    fi
}

check_fatal_error() {
    local log_file="$1"
    local cli_exit_code="${2:-0}"
    [[ -f "$log_file" ]] || return 1

    # Known fatal error patterns from Claude CLI / Anthropic API
    local fatal_patterns="Invalid API key|invalid_api_key|authentication_error|API key expired"
    fatal_patterns="${fatal_patterns}|rate_limit_error|overloaded_error|billing"
    fatal_patterns="${fatal_patterns}|Could not resolve host|connection refused|ECONNREFUSED"
    fatal_patterns="${fatal_patterns}|ANTHROPIC_API_KEY.*not set|No API key"

    if grep -qiE "$fatal_patterns" "$log_file" 2>/dev/null; then
        local match
        match=$(grep -iE "$fatal_patterns" "$log_file" 2>/dev/null | head -1 | cut -c1-120)
        error "Fatal CLI error: $match"
        return 1  # fatal error detected
    fi

    # Non-zero exit + tiny output = likely CLI crash
    if [[ "$cli_exit_code" -ne 0 ]]; then
        local line_count
        line_count=$(grep -cv '^$' "$log_file" 2>/dev/null || true)
        line_count="${line_count:-0}"
        if [[ "$line_count" -lt 3 ]]; then
            local content
            content=$(head -3 "$log_file" 2>/dev/null | cut -c1-120)
            error "CLI exited $cli_exit_code with minimal output: $content"
            return 0
        fi
    fi

    return 1  # no fatal error
}
