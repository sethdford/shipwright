#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_PROGRESS_LOADED:-}" ]] && return 0
_LOOP_PROGRESS_LOADED=1

# ─── Progress File Management ──────────────────────────────────────────────────

write_progress() {
    local progress_file="$LOG_DIR/progress.md"
    local recent_commits
    recent_commits=$(git -C "$PROJECT_ROOT" log --oneline -5 2>/dev/null || echo "(no commits)")
    local changed_files
    changed_files=$(git -C "$PROJECT_ROOT" diff --name-only HEAD~3 2>/dev/null | head -20 || echo "(none)")
    local last_error=""
    local prev_test_log="$LOG_DIR/tests-iter-${ITERATION}.log"
    if [[ -f "$prev_test_log" ]] && [[ "${TEST_PASSED:-}" == "false" ]]; then
        last_error=$(tail -10 "$prev_test_log" 2>/dev/null || true)
    fi

    # Exit class distinguishes flatline from context exhaustion for the daemon
    local exit_class="${LOOP_EXIT_CLASS:-}"
    if [[ -z "$exit_class" ]] && type loop_resolve_exit_class >/dev/null 2>&1; then
        exit_class=$(loop_resolve_exit_class)
    fi
    exit_class="${exit_class:-${STATUS:-running}}"

    # Use printf to avoid heredoc delimiter injection from GOAL content
    local tmp_progress="${progress_file}.tmp.$$"
    {
        printf '# Session Progress (Auto-Generated)\n\n'
        printf '## Goal\n%s\n\n' "${GOAL}"
        printf '## Status\n'
        printf -- '- Iteration: %s/%s\n' "${ITERATION}" "${MAX_ITERATIONS}"
        printf -- '- Session restart: %s/%s\n' "${RESTART_COUNT:-0}" "${MAX_RESTARTS:-0}"
        printf -- '- Tests passing: %s\n' "${TEST_PASSED:-unknown}"
        printf -- '- Status: %s\n' "${STATUS:-running}"
        printf -- '- Exit class: %s\n' "$exit_class"
        printf -- '- Flatline streak: %s/%s\n\n' "${FLATLINE_STREAK:-0}" "${FLATLINE_THRESHOLD:-3}"
        printf '## Recent Commits\n%s\n\n' "${recent_commits}"
        printf '## Changed Files\n%s\n\n' "${changed_files}"
        if [[ -n "$last_error" ]]; then
            printf '## Last Error\n%s\n\n' "$last_error"
        fi
        printf '## Timestamp\n%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    } > "$tmp_progress" 2>/dev/null
    mv "$tmp_progress" "$progress_file" 2>/dev/null || rm -f "$tmp_progress" 2>/dev/null
}

append_log_entry() {
    local entry="$1"
    if [[ -n "$LOG_ENTRIES" ]]; then
        LOG_ENTRIES="${LOG_ENTRIES}
${entry}"
    else
        LOG_ENTRIES="$entry"
    fi
}
