#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_FLATLINE_LOADED:-}" ]] && return 0
_LOOP_FLATLINE_LOADED=1

# ─── Flatline Detection ───────────────────────────────────────────────────────
# A "flatline" is a run of iterations that change nothing and fail the same way.
# It is distinct from context exhaustion (the window filled up): more fresh
# sessions help the latter and merely replay the former.
#
# This module owns its own change/error fingerprints instead of reusing the
# stuckness tracking columns, which are blind or constant in common cases:
#   - check_progress diffs HEAD~1, so an iteration with no commit re-measures
#     the previous commit and looks productive forever
#   - the stuckness diff_hash is the empty-input md5 whenever the tree is clean
#   - the stuckness error_hash tracks Bash-tool errors, not test failures
#
# Every function fails open (returns 0, defaults to "productive") so a missing
# git repo, md5 tool or summary file can never abort the loop or invent a flatline.

# md5 of empty input — a constant that must never count as "the same failure"
_FLATLINE_EMPTY_MD5="d41d8cd98f00b204e9800998ecf8427e"

_flatline_threshold() {
    local val=""
    if type _smart_int >/dev/null 2>&1; then
        val=$(_smart_int "loop.flatline_threshold" 3 2>/dev/null || true)
    fi
    if [[ ! "${val:-}" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; then
        val=3
    fi
    echo "$val"
}

FLATLINE_THRESHOLD="$(_flatline_threshold)"
FLATLINE_STREAK=0
FLATLINE_TOTAL=0
FLATLINE_LAST_HEAD=""
FLATLINE_LAST_ERR_FP=""
FLATLINE_LAST_EXIT=""
LAST_ITERATION_CLASS=""
LOOP_EXIT_CLASS=""

# Hash stdin; echoes "" when no md5 tool is available.
_flatline_md5() {
    local out=""
    if command -v md5sum >/dev/null 2>&1; then
        out=$(md5sum 2>/dev/null | cut -d' ' -f1 || true)
    elif command -v md5 >/dev/null 2>&1; then
        out=$(md5 -q 2>/dev/null || true)
    else
        cat >/dev/null
    fi
    echo "${out:-}"
}

# Fingerprint of the current failure, or "" if none is available.
# Digit runs are normalized so timings/line numbers don't make one failure look new.
flatline_error_fingerprint() {
    local lines=""
    local summary="${LOG_DIR:-}/error-summary.json"
    if [[ -n "${LOG_DIR:-}" && -f "$summary" ]] && command -v jq >/dev/null 2>&1; then
        lines=$(jq -r '(.error_lines // [])[]' "$summary" 2>/dev/null | sort || true)
    fi
    if [[ -z "$lines" && -n "${TEST_OUTPUT:-}" ]]; then
        lines=$(printf '%s\n' "$TEST_OUTPUT" | grep -iE '(error|fail|assert|exception|panic)' 2>/dev/null | tail -10 | sort || true)
    fi
    # A test command that failed without printing anything recognizable is still
    # a failure, and failing silently twice in a row is the same failure.
    if [[ -z "$lines" && "${TEST_PASSED:-}" == "false" ]]; then
        lines="test command failed with no recognizable error output"
    fi
    [[ -z "$lines" ]] && { echo ""; return 0; }

    local fp
    fp=$(printf '%s\n' "$lines" | sed -E 's/[0-9]+/N/g' | _flatline_md5)
    if [[ "$fp" == "$_FLATLINE_EMPTY_MD5" ]]; then
        fp=""
    fi
    echo "${fp:-}"
    return 0
}

# True when two fingerprints are equal AND meaningful.
_flatline_fp_same() {
    local a="${1:-}" b="${2:-}"
    [[ -z "$a" || -z "$b" ]] && return 1
    [[ "$a" == "none" || "$a" == "$_FLATLINE_EMPTY_MD5" ]] && return 1
    [[ "$a" == "$b" ]]
}

# flatline_classify_iteration <log_file> <made_progress:true|false> <exit_code>
# Must run after tests and after git_auto_commit for this iteration.
# Sets LAST_ITERATION_CLASS (productive|flat|context_exhaustion) and updates the
# streak counters. Called directly (not in $(...)) so the globals survive.
flatline_classify_iteration() {
    local log_file="${1:-}" made_progress="${2:-true}" exit_code="${3:-0}"
    local root="${PROJECT_ROOT:-.}"
    local cls="productive"

    local head=""
    head=$(git -C "$root" rev-parse HEAD 2>/dev/null || true)
    local err_fp=""
    err_fp=$(flatline_error_fingerprint 2>/dev/null || true)

    # 1. Context exhaustion is a known cause and wins over everything else
    local stderr_file="${log_file%.log}.stderr"
    if [[ -n "${CONTEXT_EXHAUSTION_PATTERNS:-}" ]]; then
        if { [[ -f "$log_file" ]] && grep -qiE "$CONTEXT_EXHAUSTION_PATTERNS" "$log_file" 2>/dev/null; } ||
           { [[ -f "$stderr_file" ]] && grep -qiE "$CONTEXT_EXHAUSTION_PATTERNS" "$stderr_file" 2>/dev/null; }; then
            cls="context_exhaustion"
        fi
    fi

    if [[ "$cls" != "context_exhaustion" && "${TEST_PASSED:-}" != "true" ]]; then
        # 2a. No change: HEAD did not move and the tree is clean, or no measurable progress
        local no_change=false
        if [[ "$made_progress" == "false" ]]; then
            no_change=true
        elif [[ -n "$head" && -n "${FLATLINE_LAST_HEAD:-}" ]]; then
            # HEAD moves every iteration because git_auto_commit also commits the
            # loop's own .claude/ bookkeeping, so compare the code outside it.
            local dirty=""
            dirty=$(git -C "$root" status --porcelain -- . ':(exclude).claude' 2>/dev/null || echo "unknown")
            if [[ -z "$dirty" ]] &&
               git -C "$root" diff --quiet "$FLATLINE_LAST_HEAD" "$head" -- . ':(exclude).claude' 2>/dev/null; then
                no_change=true
            fi
        fi

        # 2b. Repeated failure: same meaningful fingerprint, or same non-zero exit code
        local same_failure=false
        if _flatline_fp_same "$err_fp" "$FLATLINE_LAST_ERR_FP"; then
            same_failure=true
        elif [[ "$exit_code" =~ ^[0-9]+$ && "$exit_code" -ne 0 && "$exit_code" == "${FLATLINE_LAST_EXIT:-}" ]]; then
            same_failure=true
        fi

        if [[ "$no_change" == "true" && "$same_failure" == "true" ]]; then
            cls="flat"
        fi
    fi

    if [[ "$cls" == "flat" ]]; then
        FLATLINE_STREAK=$(( FLATLINE_STREAK + 1 ))
        FLATLINE_TOTAL=$(( FLATLINE_TOTAL + 1 ))
    else
        FLATLINE_STREAK=0
    fi

    LAST_ITERATION_CLASS="$cls"
    FLATLINE_LAST_HEAD="$head"
    FLATLINE_LAST_ERR_FP="$err_fp"
    FLATLINE_LAST_EXIT="$exit_code"
    return 0
}

# Clear per-session state on a session restart. FLATLINE_TOTAL survives.
flatline_reset_session() {
    FLATLINE_STREAK=0
    FLATLINE_LAST_HEAD=""
    FLATLINE_LAST_ERR_FP=""
    FLATLINE_LAST_EXIT=""
    LAST_ITERATION_CLASS=""
    return 0
}

# Pure function of STATUS + flatline globals. Echoes one exit class.
loop_resolve_exit_class() {
    local status="${STATUS:-}"
    local threshold="${FLATLINE_THRESHOLD:-3}"
    local streak="${FLATLINE_STREAK:-0}"

    if [[ "$status" == "complete" ]]; then
        echo "complete"
    elif [[ "$status" == context_exhaustion* || "${LAST_ITERATION_CLASS:-}" == "context_exhaustion" ]]; then
        echo "context_exhaustion"
    elif [[ "$streak" -ge "$threshold" ]] ||
         { [[ "$status" == "stuck_restart" || "$status" == "circuit_breaker" ]] && [[ "$streak" -ge 2 ]]; }; then
        echo "flatline"
    elif [[ "$status" == "max_iterations" ]] ||
         { [[ "${ITERATION:-0}" -ge "${MAX_ITERATIONS:-0}" && "${MAX_ITERATIONS:-0}" -gt 0 && "${TEST_PASSED:-}" != "true" ]]; }; then
        echo "iteration_exhaustion"
    else
        echo "${status:-running}"
    fi
    return 0
}

# Read the last "Exit class:" from a progress.md. The one parser shared by the
# pipeline and the daemon so they cannot drift apart. Echoes "" when the file
# or the line is missing (pre-flatline progress files); never fails.
loop_read_exit_class() {
    local progress_file="${1:-}"
    [[ -n "$progress_file" && -f "$progress_file" ]] || return 0
    grep -oE 'Exit class: [a-z_]+' "$progress_file" 2>/dev/null | tail -1 | awk '{print $NF}' || true
    return 0
}

# Atomically write $LOG_DIR/flatline.json. Diagnostic only — never fails the loop.
flatline_write_artifact() {
    [[ -z "${LOG_DIR:-}" || ! -d "${LOG_DIR:-}" ]] && return 0
    command -v jq >/dev/null 2>&1 || return 0
    local out="$LOG_DIR/flatline.json"
    local tmp="${out}.tmp.$$"
    local exit_class="${LOOP_EXIT_CLASS:-}"
    [[ -z "$exit_class" ]] && exit_class=$(loop_resolve_exit_class)
    if jq -n \
        --argjson iteration "${ITERATION:-0}" \
        --argjson streak "${FLATLINE_STREAK:-0}" \
        --argjson total "${FLATLINE_TOTAL:-0}" \
        --argjson threshold "${FLATLINE_THRESHOLD:-3}" \
        --arg last_class "${LAST_ITERATION_CLASS:-}" \
        --arg exit_class "$exit_class" \
        '{iteration: $iteration, streak: $streak, total: $total, threshold: $threshold,
          last_class: $last_class, exit_class: $exit_class}' > "$tmp" 2>/dev/null; then
        mv "$tmp" "$out" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
        rm -f "$tmp" 2>/dev/null || true
        type warn >/dev/null 2>&1 && warn "Could not write flatline.json" || true
    fi
    return 0
}
