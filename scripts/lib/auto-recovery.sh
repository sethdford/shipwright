#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_AUTO_RECOVERY_LOADED:-}" ]] && return 0
_AUTO_RECOVERY_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright auto-recovery — Autonomous Error Recovery System             ║
# ║  Classify errors → match recovery patterns → apply fix → verify         ║
# ║  Model escalation ladder: same model → escalate → fresh session → human ║
# ║  Integrates with loop-convergence: called BEFORE circuit breaker abort  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# shellcheck disable=SC2034
VERSION="3.3.0"

# ─── Output Helpers ──────────────────────────────────────────────────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi

# ─── Configuration ───────────────────────────────────────────────────────────

RECOVERY_MAX_ATTEMPTS="${RECOVERY_MAX_ATTEMPTS:-4}"
RECOVERY_STATE_FILE="${RECOVERY_STATE_FILE:-.claude/recovery-state.json}"
RECOVERY_PATTERNS_FILE="${RECOVERY_PATTERNS_FILE:-.claude/recovery-patterns.json}"
RECOVERY_LOG_FILE="${RECOVERY_LOG_FILE:-.claude/pipeline-artifacts/recovery-log.jsonl}"

# Model escalation ladder
RECOVERY_MODEL_LADDER="${RECOVERY_MODEL_LADDER:-haiku,sonnet,opus}"

# ─── Error Classification ───────────────────────────────────────────────────
# Classify an error into a category for pattern matching.
# Input: error text (from test output, build log, etc.)
# Output: error category string

recovery_classify_error() {
    local error_text="${1:-}"

    if [[ -z "$error_text" ]]; then
        echo "unknown"
        return 0
    fi

    # Normalize to lowercase for matching
    local lower_text
    lower_text=$(echo "$error_text" | tr '[:upper:]' '[:lower:]')

    # Classification by pattern (order matters — most specific first)
    if echo "$lower_text" | grep >/dev/null -E '(syntax error|unexpected token|parse error|unterminated)'; then
        echo "syntax_error"
    elif echo "$lower_text" | grep >/dev/null -E '(type error|cannot find name|is not assignable|type.*is not)'; then
        echo "type_error"
    elif echo "$lower_text" | grep >/dev/null -E '(import|require|module not found|cannot find module|no such file)'; then
        echo "import_error"
    elif echo "$lower_text" | grep >/dev/null -E '(timeout|timed out|deadline exceeded|took too long)'; then
        echo "timeout"
    elif echo "$lower_text" | grep >/dev/null -E '(out of memory|heap|oom|memory limit|segfault|sigsegv|enomem)'; then
        echo "resource_error"
    elif echo "$lower_text" | grep >/dev/null -E '(permission denied|eacces|forbidden|unauthorized|401|403)'; then
        echo "permission_error"
    elif echo "$lower_text" | grep >/dev/null -E '(connection refused|econnrefused|network|dns|enotfound)'; then
        echo "network_error"
    elif echo "$lower_text" | grep >/dev/null -E '(lock|deadlock|locked|busy|resource busy)'; then
        echo "lock_error"
    elif echo "$lower_text" | grep >/dev/null -E '(assert|expect|should|to equal|to be|not equal|mismatch)'; then
        echo "test_assertion"
    elif echo "$lower_text" | grep >/dev/null -E '(build|compile|linker|undefined reference|unresolved)'; then
        echo "build_error"
    elif echo "$lower_text" | grep >/dev/null -E '(lint|eslint|prettier|format|style)'; then
        echo "lint_error"
    elif echo "$lower_text" | grep >/dev/null -E '(deprecat|removed|obsolete|no longer supported)'; then
        echo "deprecation_error"
    elif echo "$lower_text" | grep >/dev/null -E '(null|undefined|nil|none|reference error)'; then
        echo "null_reference"
    else
        echo "unknown"
    fi
}

# ─── Recovery Pattern Matching ───────────────────────────────────────────────
# Match an error category to a recovery strategy.

recovery_get_strategy() {
    local error_category="${1:-unknown}"

    # Check custom patterns file first
    if [[ -f "$RECOVERY_PATTERNS_FILE" ]] && command -v jq >/dev/null 2>&1; then
        local custom_strategy
        custom_strategy=$(jq -r --arg cat "$error_category" \
            '.patterns[$cat].strategy // empty' "$RECOVERY_PATTERNS_FILE" 2>/dev/null || true)
        if [[ -n "$custom_strategy" ]]; then
            echo "$custom_strategy"
            return 0
        fi
    fi

    # Built-in strategies
    case "$error_category" in
        syntax_error)
            echo "retry_with_context:Focus on fixing the syntax error. Read the error line carefully and fix the exact syntax issue."
            ;;
        type_error)
            echo "retry_with_context:Fix the type error. Add explicit type annotations, check function signatures, and ensure type compatibility."
            ;;
        import_error)
            echo "retry_with_context:Fix the import/module error. Check file paths, verify the module exists, and fix any incorrect import statements."
            ;;
        timeout)
            echo "adjust_config:Increase timeout values or simplify the operation that is timing out."
            ;;
        resource_error)
            echo "escalate_model:Resource exhaustion detected. Try with a model that uses less context or break the task into smaller pieces."
            ;;
        permission_error)
            echo "flag_human:Permission error requires human intervention to fix credentials or access."
            ;;
        network_error)
            echo "retry_simple:Network error may be transient. Wait briefly and retry."
            ;;
        lock_error)
            echo "retry_with_cleanup:Clean up lock files and retry. Check for orphaned processes."
            ;;
        test_assertion)
            echo "retry_with_context:Test assertion failed. Review the test expectation and the code behavior. Fix the code to match expected behavior, not the test."
            ;;
        build_error)
            echo "retry_with_context:Build error. Check for missing dependencies, incorrect imports, or compilation issues."
            ;;
        lint_error)
            echo "retry_with_context:Lint/formatting error. Apply the formatter or fix the lint violations."
            ;;
        deprecation_error)
            echo "retry_with_context:Deprecated API usage. Update to the current API version."
            ;;
        null_reference)
            echo "retry_with_context:Null/undefined reference. Add null checks, default values, or ensure the variable is initialized."
            ;;
        *)
            echo "retry_with_context:Unknown error. Read the error carefully and apply a targeted fix."
            ;;
    esac
}

# ─── Recovery State Management ───────────────────────────────────────────────

_recovery_load_state() {
    if [[ -f "$RECOVERY_STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
        cat "$RECOVERY_STATE_FILE"
    else
        echo '{"attempts":0,"history":[],"current_model":"","escalation_level":0}'
    fi
}

_recovery_save_state() {
    local state_json="${1:-}"
    if [[ -n "$state_json" ]]; then
        mkdir -p "$(dirname "$RECOVERY_STATE_FILE")"
        local tmp_file
        tmp_file=$(mktemp 2>/dev/null || echo "${RECOVERY_STATE_FILE}.tmp")
        echo "$state_json" > "$tmp_file"
        mv "$tmp_file" "$RECOVERY_STATE_FILE"
    fi
}

_recovery_log_attempt() {
    local category="${1:-}" strategy="${2:-}" result="${3:-}" details="${4:-}"
    mkdir -p "$(dirname "$RECOVERY_LOG_FILE")"

    local entry
    entry=$(printf '{"timestamp":"%s","category":"%s","strategy":"%s","result":"%s","details":"%s"}' \
        "$(now_iso)" "$category" "$strategy" "$result" \
        "$(echo "$details" | tr '"' "'" | head -c 200)")

    echo "$entry" >> "$RECOVERY_LOG_FILE"
}

# ─── Core Recovery Function ─────────────────────────────────────────────────
# Attempt autonomous recovery from an error.
# Returns 0 if recovery succeeded (caller should continue), 1 if failed.
#
# This is the main integration point with loop-convergence.sh.
# Call this BEFORE the circuit breaker trips.

recovery_attempt() {
    local error_text="${1:-}"
    local project_dir="${2:-.}"
    local test_cmd="${3:-}"

    if [[ -z "$error_text" ]]; then
        warn "No error text provided for recovery"
        return 1
    fi

    # Load state
    local state
    state=$(_recovery_load_state)
    local attempts
    attempts=$(echo "$state" | jq -r '.attempts // 0' 2>/dev/null || echo "0")

    if [[ "$attempts" -ge "$RECOVERY_MAX_ATTEMPTS" ]]; then
        error "Recovery exhausted: ${attempts}/${RECOVERY_MAX_ATTEMPTS} attempts used"
        _recovery_log_attempt "exhausted" "none" "failed" "Max attempts reached"
        if type emit_event >/dev/null 2>&1; then
            emit_event "recovery_exhausted" "attempts=${attempts}"
        fi
        return 1
    fi

    # Classify error
    local category
    category=$(recovery_classify_error "$error_text")
    info "Error classified as: ${category}"

    # Get recovery strategy
    local strategy_raw strategy_type strategy_hint
    strategy_raw=$(recovery_get_strategy "$category")
    strategy_type=$(echo "$strategy_raw" | cut -d: -f1)
    strategy_hint=$(echo "$strategy_raw" | cut -d: -f2-)

    info "Recovery strategy: ${strategy_type}"

    # Increment attempt counter
    attempts=$((attempts + 1))
    local escalation_level
    escalation_level=$(echo "$state" | jq -r '.escalation_level // 0' 2>/dev/null || echo "0")

    # Execute strategy
    local recovery_result="failed"

    case "$strategy_type" in
        retry_simple)
            info "Retrying (attempt ${attempts}/${RECOVERY_MAX_ATTEMPTS})..."
            recovery_result="retry"
            ;;

        retry_with_context)
            info "Retrying with focused context (attempt ${attempts}/${RECOVERY_MAX_ATTEMPTS})..."
            # The hint will be injected into the next iteration prompt
            RECOVERY_HINT="${strategy_hint}"
            recovery_result="retry_with_hint"
            ;;

        retry_with_cleanup)
            info "Cleaning up and retrying..."
            # Clean common lock/temp files
            find "$project_dir" -name "*.lock" -newer "$project_dir/.git/HEAD" -delete 2>/dev/null || true
            find "$project_dir" -name ".cache" -type d -newer "$project_dir/.git/HEAD" -exec rm -rf {} + 2>/dev/null || true
            RECOVERY_HINT="${strategy_hint}"
            recovery_result="retry_with_hint"
            ;;

        adjust_config)
            info "Adjusting configuration..."
            RECOVERY_HINT="${strategy_hint}"
            recovery_result="retry_with_hint"
            ;;

        escalate_model)
            # Move up the model ladder
            escalation_level=$((escalation_level + 1))
            # Count models in ladder (Bash 3.2 compat — no read -a)
            local model_count=0
            local m
            for m in $(echo "$RECOVERY_MODEL_LADDER" | tr ',' ' '); do
                model_count=$((model_count + 1))
            done

            if [[ "$escalation_level" -lt "$model_count" ]]; then
                local target_model
                target_model=$(echo "$RECOVERY_MODEL_LADDER" | cut -d',' -f$((escalation_level + 1)))
                info "Escalating model to: ${target_model}"
                RECOVERY_ESCALATED_MODEL="$target_model"
                RECOVERY_HINT="${strategy_hint}"
                recovery_result="model_escalated"

                if type emit_event >/dev/null 2>&1; then
                    emit_event "recovery_escalated" \
                        "from_level=${escalation_level}" \
                        "to_model=${target_model}" \
                        "category=${category}"
                fi
            else
                warn "No higher model available for escalation"
                recovery_result="failed"
            fi
            ;;

        flag_human)
            warn "Error requires human intervention: ${category}"
            RECOVERY_HINT="HUMAN INTERVENTION REQUIRED: ${strategy_hint}"
            recovery_result="needs_human"

            if type emit_event >/dev/null 2>&1; then
                emit_event "recovery_needs_human" \
                    "category=${category}" \
                    "hint=${strategy_hint}"
            fi
            return 1
            ;;

        *)
            warn "Unknown recovery strategy: ${strategy_type}"
            recovery_result="failed"
            ;;
    esac

    # Update state
    local history_entry
    history_entry=$(printf '{"attempt":%d,"category":"%s","strategy":"%s","result":"%s","timestamp":"%s"}' \
        "$attempts" "$category" "$strategy_type" "$recovery_result" "$(now_iso)")

    local new_state
    new_state=$(echo "$state" | jq \
        --argjson attempt "$attempts" \
        --argjson level "$escalation_level" \
        --argjson entry "$history_entry" \
        '.attempts = $attempt | .escalation_level = $level | .history += [$entry]' \
        2>/dev/null || echo "$state")

    _recovery_save_state "$new_state"
    _recovery_log_attempt "$category" "$strategy_type" "$recovery_result" "$error_text"

    if type emit_event >/dev/null 2>&1; then
        emit_event "recovery_attempted" \
            "attempt=${attempts}" \
            "category=${category}" \
            "strategy=${strategy_type}" \
            "result=${recovery_result}"
    fi

    # Return based on result
    case "$recovery_result" in
        retry|retry_with_hint|model_escalated)
            success "Recovery action applied (attempt ${attempts}/${RECOVERY_MAX_ATTEMPTS})"
            return 0
            ;;
        *)
            error "Recovery failed (attempt ${attempts}/${RECOVERY_MAX_ATTEMPTS})"
            return 1
            ;;
    esac
}

# ─── Reset Recovery State ───────────────────────────────────────────────────
# Call when tests pass or iteration succeeds to reset the recovery counter.

recovery_reset() {
    if [[ -f "$RECOVERY_STATE_FILE" ]]; then
        local state
        state=$(_recovery_load_state)
        local prev_attempts
        prev_attempts=$(echo "$state" | jq -r '.attempts // 0' 2>/dev/null || echo "0")

        if [[ "$prev_attempts" -gt 0 ]]; then
            success "Recovery succeeded after ${prev_attempts} attempts — resetting counter"
            _recovery_log_attempt "reset" "success" "recovered" "Tests passing, resetting recovery state"
        fi
    fi

    _recovery_save_state '{"attempts":0,"history":[],"current_model":"","escalation_level":0}'
    RECOVERY_HINT=""
    RECOVERY_ESCALATED_MODEL=""
}

# ─── Recovery Status ────────────────────────────────────────────────────────


# ─── Integration Point: Pre-Circuit-Breaker Hook ────────────────────────────
# Called by loop-convergence.sh before the circuit breaker trips.
# If recovery succeeds, the caller should reset the circuit breaker counter.

recovery_before_circuit_breaker() {
    local error_log="${1:-}"
    local project_dir="${2:-.}"
    local test_cmd="${3:-}"

    # Extract the most recent error
    local recent_error=""
    if [[ -n "$error_log" && -f "$error_log" ]]; then
        recent_error=$(tail -1 "$error_log" 2>/dev/null | jq -r '.error // .message // empty' 2>/dev/null || true)
    fi

    if [[ -z "$recent_error" ]]; then
        # Try to get error from last test output
        local last_log="${LOG_DIR:-/tmp}/iteration-${ITERATION:-0}.log"
        if [[ -f "$last_log" ]]; then
            recent_error=$(grep -iE '(error|fail|exception)' "$last_log" 2>/dev/null | tail -5 | head -c 500 || true)
        fi
    fi

    if [[ -z "$recent_error" ]]; then
        warn "No error context available for recovery"
        return 1
    fi

    recovery_attempt "$recent_error" "$project_dir" "$test_cmd"
}

# ─── Custom Patterns Management ─────────────────────────────────────────────
# Add a custom recovery pattern learned from experience.

recovery_add_pattern() {
    local category="${1:-}"
    local strategy="${2:-}"
    local description="${3:-}"

    if [[ -z "$category" || -z "$strategy" ]]; then
        error "Usage: recovery_add_pattern <category> <strategy> [description]"
        return 1
    fi

    mkdir -p "$(dirname "$RECOVERY_PATTERNS_FILE")"

    if [[ ! -f "$RECOVERY_PATTERNS_FILE" ]]; then
        echo '{"patterns":{}}' > "$RECOVERY_PATTERNS_FILE"
    fi

    local updated
    updated=$(jq --arg cat "$category" --arg strat "$strategy" --arg desc "$description" \
        '.patterns[$cat] = {"strategy": $strat, "description": $desc, "added": (now | todate)}' \
        "$RECOVERY_PATTERNS_FILE" 2>/dev/null)

    if [[ -n "$updated" ]]; then
        echo "$updated" > "$RECOVERY_PATTERNS_FILE"
        success "Recovery pattern added: ${category} → ${strategy}"
    else
        error "Failed to add recovery pattern"
        return 1
    fi
}

# ─── Exported Variables ──────────────────────────────────────────────────────
# These are set by recovery_attempt and read by the loop iteration logic.

RECOVERY_HINT=""              # Injected into next iteration prompt
RECOVERY_ESCALATED_MODEL=""   # Model to switch to (if escalated)
