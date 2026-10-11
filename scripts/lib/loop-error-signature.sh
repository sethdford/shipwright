#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_ERROR_SIGNATURE_LOADED:-}" ]] && return 0
_LOOP_ERROR_SIGNATURE_LOADED=1

# ─── Error Signature Deduplication ───────────────────────────────────────────
# The build loop used to re-send the same failing prompt iteration after
# iteration: error-summary.json carried the same lines, compose_prompt injected
# the same block, and the model made the same attempt. detect_stuckness() only
# reacts after several multi-signal iterations, so an identical failure could
# burn 5-7 iterations before anything changed.
#
# This module hashes the normalized error lines of each FAILING iteration and
# compares with the previous one. Consecutive repeats escalate:
#   count == threshold      → widen_context (hint + wider test output, rotate
#                             the continuity session if one is in use)
#   count >= threshold + 1  → session_restart, when restarts are available and
#                             this signature has not already caused one
#
# State (globals, all per loop run):
#   ERRSIG_LAST_HASH         signature of the previous failing iteration
#   ERRSIG_REPEAT_COUNT      consecutive iterations with ERRSIG_LAST_HASH
#   ERRSIG_ACTION            "", widen_context, or session_restart
#   ERRSIG_HINT              prompt section text when escalated, else ""
#   ERRSIG_RESTARTED_HASHES  space-separated signatures that already restarted
#
# Config: ERROR_DEDUP_ENABLED (true/false), ERROR_DEDUP_THRESHOLD (int >= 2),
# resolved by errsig_load_config from LOOP_ERROR_DEDUP / SW_LOOP_ERROR_DEDUP_* /
# daemon-config loop.error_dedup_* / defaults (true, 2).

ERRSIG_LAST_HASH="${ERRSIG_LAST_HASH:-}"
ERRSIG_REPEAT_COUNT="${ERRSIG_REPEAT_COUNT:-0}"
ERRSIG_ACTION="${ERRSIG_ACTION:-}"
ERRSIG_HINT="${ERRSIG_HINT:-}"
ERRSIG_RESTARTED_HASHES="${ERRSIG_RESTARTED_HASHES:-}"

# Resolve ERROR_DEDUP_ENABLED / ERROR_DEDUP_THRESHOLD from env and config.
errsig_load_config() {
    local enabled="${LOOP_ERROR_DEDUP:-}"
    if [[ -z "$enabled" ]]; then
        if type _smart_int >/dev/null 2>&1; then
            enabled=$(_smart_int "loop.error_dedup_enabled" "true" 2>/dev/null || echo "true")
        else
            enabled="true"
        fi
    fi
    case "$(printf '%s' "$enabled" | tr '[:upper:]' '[:lower:]')" in
        0|false|off|no) ERROR_DEDUP_ENABLED="false" ;;
        *) ERROR_DEDUP_ENABLED="true" ;;
    esac

    local threshold=2
    if type _smart_int >/dev/null 2>&1; then
        threshold=$(_smart_int "loop.error_dedup_threshold" 2 2>/dev/null || echo 2)
    fi
    # Below 2 a single failure would count as a "repeat"
    if [[ ! "$threshold" =~ ^[0-9]+$ ]] || [[ "$threshold" -lt 2 ]]; then
        threshold=2
    fi
    ERROR_DEDUP_THRESHOLD="$threshold"
}

_errsig_enabled() {
    [[ "${ERROR_DEDUP_ENABLED:-true}" != "false" ]]
}

# Filter: normalize error lines on stdin, one per line, dropping volatile tokens
# (ANSI codes, timestamps, durations, hex addresses, temp paths) but keeping
# file:line and the message text. Empty results are dropped.
_errsig_normalize_stream() {
    local esc
    esc=$(printf '\033')
    sed -E \
        -e "s/${esc}\[[0-9;]*[A-Za-z]//g" \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?/<ts>/g' \
        -e 's/[0-9]+(\.[0-9]+)? ?(ms|s)([^A-Za-z0-9]|$)/<dur>\3/g' \
        -e 's/0x[0-9a-fA-F]+/<addr>/g' \
        -e 's#(/private)?/(tmp|var/folders)/[^ :]+#<tmp>#g' \
        2>/dev/null \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E -e 's/[[:space:]]+/ /g' -e 's/^ //' -e 's/ $//' 2>/dev/null \
    | grep -v '^$' || true
}

# errsig_normalize_line <line> → normalized line on stdout (may be empty)
errsig_normalize_line() {
    printf '%s\n' "${1:-}" | _errsig_normalize_stream
}

# errsig_compute <error-summary.json> → md5 of the sorted, de-duplicated,
# normalized error lines. Empty when the file is missing/invalid, jq is
# unavailable, or nothing survives normalization. Never fails.
errsig_compute() {
    local json_file="${1:-}"
    [[ -n "$json_file" && -f "$json_file" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local raw normalized
    raw=$(jq -r '(.error_lines // [])[]? | strings' "$json_file" 2>/dev/null || true)
    [[ -z "$raw" ]] && return 0
    normalized=$(printf '%s\n' "$raw" | _errsig_normalize_stream | LC_ALL=C sort -u || true)
    [[ -z "$normalized" ]] && return 0

    compute_md5 --string "$normalized" 2>/dev/null || true
}

# Distinct file:line locations from the error lines (max 10), one per line.
_errsig_locations() {
    local json_file="$1"
    command -v jq >/dev/null 2>&1 || return 0
    jq -r '(.error_lines // [])[]? | strings' "$json_file" 2>/dev/null \
        | grep -oE '[A-Za-z0-9._/-]+\.[A-Za-z]+:[0-9]+' 2>/dev/null \
        | awk '!seen[$0]++' | head -10 || true
}

_errsig_emit() {
    local action="$1"
    if type emit_event >/dev/null 2>&1; then
        emit_event "loop.error_signature_repeat" \
            "signature=${ERRSIG_LAST_HASH}" \
            "repeat_count=${ERRSIG_REPEAT_COUNT}" \
            "threshold=${ERROR_DEDUP_THRESHOLD:-2}" \
            "action=${action}" \
            "iteration=${ITERATION:-0}" 2>/dev/null || true
    fi
}

_errsig_build_hint() {
    local json_file="$1"
    local locations test_log
    locations=$(_errsig_locations "$json_file")
    test_log="${TEST_LOG_FILE:-${LOG_DIR:-.}/tests-iter-${ITERATION:-0}.log}"

    ERRSIG_HINT=$(
        printf 'The last %s iterations failed with the SAME error signature — the previous approach did not change the failing output. Do NOT repeat it.\n' "$ERRSIG_REPEAT_COUNT"
        printf -- '- Re-read the failing assertion and question your assumption about the root cause.\n'
        if [[ -n "$locations" ]]; then
            printf -- '- Read these locations, their callers, and the test that exercises them:\n'
            printf '%s\n' "$locations" | sed 's/^/    - /'
        fi
        printf -- '- Full test log: %s (wider output is included below).\n' "$test_log"
        printf -- '- Try a materially different fix, or revert the last change if it made no difference.\n'
    )
}

# Decide the escalation level for the current repeat count.
errsig_escalate() {
    local json_file="${1:-${LOG_DIR:-.}/error-summary.json}"
    local threshold="${ERROR_DEDUP_THRESHOLD:-2}"

    if [[ "${ERRSIG_REPEAT_COUNT:-0}" -lt "$threshold" ]]; then
        ERRSIG_ACTION=""
        ERRSIG_HINT=""
        return 0
    fi

    _errsig_build_hint "$json_file"

    if [[ "$ERRSIG_REPEAT_COUNT" -eq "$threshold" ]]; then
        ERRSIG_ACTION="widen_context"
        # A carried conversation is part of what is stuck — start a new one
        if [[ -n "${LOOP_SESSION_ID:-}" ]] && type new_uuid >/dev/null 2>&1; then
            LOOP_SESSION_ID=$(new_uuid)
        fi
        _errsig_emit "widen_context"
        return 0
    fi

    # Level 2: restart, if the restart budget allows and this signature has
    # not already caused one (a restart that didn't help won't help twice).
    local max_restarts="${MAX_RESTARTS:-0}" restart_count="${RESTART_COUNT:-0}"
    [[ "$max_restarts" =~ ^[0-9]+$ ]] || max_restarts=0
    [[ "$restart_count" =~ ^[0-9]+$ ]] || restart_count=0

    ERRSIG_ACTION="widen_context"
    if [[ "$max_restarts" -eq 0 ]]; then
        _errsig_emit "restart_unavailable"
    elif [[ "$restart_count" -ge "$max_restarts" ]] \
        || [[ " ${ERRSIG_RESTARTED_HASHES} " == *" ${ERRSIG_LAST_HASH} "* ]]; then
        _errsig_emit "restart_exhausted"
    else
        ERRSIG_ACTION="session_restart"
        _errsig_emit "session_restart"
    fi
}

# Main entry point — call once per iteration, after write_error_summary.
errsig_update() {
    _errsig_enabled || return 0

    local json_file="${LOG_DIR:-.}/error-summary.json"

    # Only test-gate failures count: write_error_summary also fires on passing
    # iterations whose log merely mentions "error", which would false-positive.
    if [[ "${TEST_PASSED:-}" != "false" ]]; then
        ERRSIG_LAST_HASH=""
        ERRSIG_REPEAT_COUNT=0
        ERRSIG_ACTION=""
        ERRSIG_HINT=""
        return 0
    fi

    local hash
    hash=$(errsig_compute "$json_file")
    if [[ -z "$hash" ]]; then
        # No usable signature — can't claim a repeat, so break the chain
        ERRSIG_LAST_HASH=""
        ERRSIG_REPEAT_COUNT=0
        ERRSIG_ACTION=""
        ERRSIG_HINT=""
        return 0
    fi

    if [[ "$hash" == "$ERRSIG_LAST_HASH" ]]; then
        ERRSIG_REPEAT_COUNT=$((ERRSIG_REPEAT_COUNT + 1))
    else
        ERRSIG_LAST_HASH="$hash"
        ERRSIG_REPEAT_COUNT=1
    fi

    if [[ -n "${LOG_DIR:-}" && -d "$LOG_DIR" ]]; then
        printf '%s|%s|%s\n' "${ITERATION:-0}" "$hash" "$ERRSIG_REPEAT_COUNT" \
            >> "$LOG_DIR/error-signatures.txt" 2>/dev/null || true
    fi

    # Additive fields; existing readers only use error_count/error_lines
    local tmp_json="${json_file}.tmp.$$"
    if jq --arg sig "$hash" --argjson n "$ERRSIG_REPEAT_COUNT" \
        '. + {signature: $sig, signature_repeat_count: $n}' \
        "$json_file" > "$tmp_json" 2>/dev/null; then
        mv "$tmp_json" "$json_file" 2>/dev/null || rm -f "$tmp_json" 2>/dev/null || true
    else
        rm -f "$tmp_json" 2>/dev/null || true
    fi

    errsig_escalate "$json_file"
}

# Clear per-session state on restart. ERRSIG_RESTARTED_HASHES is kept on
# purpose so one signature cannot trigger restart after restart.
errsig_reset() {
    ERRSIG_LAST_HASH=""
    ERRSIG_REPEAT_COUNT=0
    ERRSIG_ACTION=""
    ERRSIG_HINT=""
}
