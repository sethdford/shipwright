#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-circuit-breaker — Adaptive circuit breaker threshold based on        ║
# ║                        failure signature similarity                       ║
# ║                                                                         ║
# ║  Analyzes recent failure signatures and adjusts the circuit breaker     ║
# ║  threshold dynamically: higher if failures share the same root cause,   ║
# ║  lower if failures are diverse and unrelated.                           ║
# ║                                                                         ║
# ║  USAGE (as a library):                                                  ║
# ║    source sw-circuit-breaker.sh                                         ║
# ║    extract_error_signatures "$error_log"  # Returns JSON array         ║
# ║    score_signature_similarity "$sig1" "$sig2"  # Returns 0-100         ║
# ║    compute_adaptive_threshold "$error_log" 3  # Returns adjusted int   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard - prevent double-sourcing
[[ -n "${_CIRCUIT_BREAKER_LOADED:-}" ]] && return 0
_CIRCUIT_BREAKER_LOADED=1

# shellcheck disable=SC2034
VERSION="3.3.0"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"

# Fallbacks when helpers not loaded (e.g. test env)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# Config helper
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh" 2>/dev/null || true

# ─── Configuration ───────────────────────────────────────────────────────────
# Enable adaptive circuit breaker (default: false during rollout)
ADAPTIVE_ENABLED=$(_config_get_int "loop.adaptive_circuit_breaker_enabled" 0 2>/dev/null || echo 0)
[[ "$ADAPTIVE_ENABLED" == "true" ]] && ADAPTIVE_ENABLED=1

# Similarity threshold: failures above this % are considered "same signature"
SIMILARITY_THRESHOLD=${SIMILARITY_THRESHOLD:-75}

# Threshold adjustments
THRESHOLD_BASE=${THRESHOLD_BASE:-3}  # Default threshold when disabled
THRESHOLD_SIMILAR_ADJUSTMENT=${THRESHOLD_SIMILAR_ADJUSTMENT:-2}  # +2 when similar
THRESHOLD_DIVERSE_ADJUSTMENT=${THRESHOLD_DIVERSE_ADJUSTMENT:-1}  # -1 when diverse
THRESHOLD_MIN=${THRESHOLD_MIN:-2}  # Absolute minimum
THRESHOLD_MAX=${THRESHOLD_MAX:-8}  # Absolute maximum

# ─── Error Signature Extraction ──────────────────────────────────────────────

# extract_error_signatures <error_log_file>
#
# Reads error-log.jsonl and extracts signatures from recent failures.
# Returns a JSON array of objects: [{"error":"...", "type":"...", "stage":"..."}]
#
# Each signature is computed from:
#   - error message (first 100 chars for compactness)
#   - error type (if available)
#   - stage (if available)
#
# INPUT:
#   $1: Path to error-log.jsonl file
#
# OUTPUT:
#   JSON array of signature objects, one per line (last N failures)
#   Returns empty array if file doesn't exist or is empty
#
# SIDE EFFECTS:
#   None (read-only operation)
extract_error_signatures() {
    local error_log="${1:-}"

    if [[ -z "$error_log" ]]; then
        echo "[]"
        return 0
    fi

    if [[ ! -f "$error_log" ]]; then
        echo "[]"
        return 0
    fi

    # Extract last 10 failures, normalize to signature format
    jq -Rs '
        split("\n") |
        map(
            select(length > 0) |
            fromjson? |
            select(.error != null or .message != null) |
            {
                error: (.error // .message // ""),
                type: (.type // .error_type // "unknown"),
                stage: (.stage // "unknown"),
                timestamp: (.timestamp // "")
            }
        )
    ' "$error_log" 2>/dev/null || echo "[]"
}

# ─── Signature Similarity Scoring ────────────────────────────────────────────

# score_signature_similarity <sig1_json> <sig2_json>
#
# Compares two signature objects and returns a similarity score (0-100).
#
# Scoring heuristic:
#   - Type match: +30 points (same error type)
#   - Error prefix match (first 50 chars): +40 points
#   - Stage match: +10 points
#   - Timestamp proximity (within 2 mins): +20 points
#
# INPUT:
#   $1: First signature as JSON object
#   $2: Second signature as JSON object
#
# OUTPUT:
#   Integer 0-100 representing similarity percentage
#
# SIDE EFFECTS:
#   None
score_signature_similarity() {
    local sig1="${1:-}"
    local sig2="${2:-}"

    if [[ -z "$sig1" || -z "$sig2" ]]; then
        echo "0"
        return 0
    fi

    # Extract fields from JSON objects
    local type1 error1 stage1 ts1
    local type2 error2 stage2 ts2

    type1=$(echo "$sig1" | jq -r '.type // ""' 2>/dev/null || echo "")
    error1=$(echo "$sig1" | jq -r '.error // "" | .[0:50]' 2>/dev/null || echo "")
    stage1=$(echo "$sig1" | jq -r '.stage // ""' 2>/dev/null || echo "")
    ts1=$(echo "$sig1" | jq -r '.timestamp // ""' 2>/dev/null || echo "")

    type2=$(echo "$sig2" | jq -r '.type // ""' 2>/dev/null || echo "")
    error2=$(echo "$sig2" | jq -r '.error // "" | .[0:50]' 2>/dev/null || echo "")
    stage2=$(echo "$sig2" | jq -r '.stage // ""' 2>/dev/null || echo "")
    ts2=$(echo "$sig2" | jq -r '.timestamp // ""' 2>/dev/null || echo "")

    local score=0

    # Type match: same error class = likely same root cause
    if [[ "$type1" == "$type2" ]] && [[ -n "$type1" ]]; then
        score=$((score + 30))
    fi

    # Error message prefix match: identical first 50 chars = very similar
    if [[ "$error1" == "$error2" ]] && [[ -n "$error1" ]]; then
        score=$((score + 40))
    fi

    # Stage match: failed in same pipeline stage
    if [[ "$stage1" == "$stage2" ]] && [[ -n "$stage1" ]]; then
        score=$((score + 10))
    fi

    # Timestamp proximity: within 2 minutes (120 seconds)
    if [[ -n "$ts1" && -n "$ts2" ]]; then
        local t1_epoch t2_epoch time_diff
        t1_epoch=$(date -d "$ts1" +%s 2>/dev/null || echo "0")
        t2_epoch=$(date -d "$ts2" +%s 2>/dev/null || echo "0")
        if [[ "$t1_epoch" -gt 0 && "$t2_epoch" -gt 0 ]]; then
            time_diff=$((t1_epoch > t2_epoch ? t1_epoch - t2_epoch : t2_epoch - t1_epoch))
            if [[ "$time_diff" -le 120 ]]; then
                score=$((score + 20))
            fi
        fi
    fi

    # Clamp to 0-100
    [[ "$score" -gt 100 ]] && score=100
    echo "$score"
}

# ─── Adaptive Threshold Computation ──────────────────────────────────────────

# compute_adaptive_threshold <error_log_file> <base_threshold>
#
# Analyzes the last N failures and adjusts the circuit breaker threshold
# based on signature similarity:
#
#   - If last 2+ failures are SIMILAR (>75% match):
#     Same root cause → grant more attempts → threshold += 2
#
#   - If last 2+ failures are DIVERSE (<75% match):
#     Different problems → trip faster → threshold -= 1
#
#   - Otherwise: return base threshold unchanged
#
# All results are clamped to [THRESHOLD_MIN, THRESHOLD_MAX].
#
# INPUT:
#   $1: Path to error-log.jsonl file
#   $2: Base threshold (default: 3)
#
# OUTPUT:
#   Adjusted threshold as integer
#
# SIDE EFFECTS:
#   May emit_event "loop.adaptive_circuit_breaker" with computed metrics
compute_adaptive_threshold() {
    local error_log="${1:-}"
    local base_threshold="${2:-$THRESHOLD_BASE}"

    # Disabled: return base threshold unchanged
    if [[ "$ADAPTIVE_ENABLED" != "1" ]]; then
        echo "$base_threshold"
        return 0
    fi

    # No error log: return base
    if [[ -z "$error_log" || ! -f "$error_log" ]]; then
        echo "$base_threshold"
        return 0
    fi

    # Not enough failures to analyze: return base
    local failure_count
    failure_count=$(grep -c '.' "$error_log" 2>/dev/null || echo "0")
    if [[ "$failure_count" -lt 2 ]]; then
        echo "$base_threshold"
        return 0
    fi

    # Extract last two signatures
    local last_sig second_last_sig
    last_sig=$(tail -1 "$error_log" 2>/dev/null | jq '{error: (.error // .message // ""), type: (.type // .error_type // "unknown"), stage: (.stage // "unknown"), timestamp: (.timestamp // "")}' 2>/dev/null || echo "")
    second_last_sig=$(tail -2 "$error_log" 2>/dev/null | head -1 | jq '{error: (.error // .message // ""), type: (.type // .error_type // "unknown"), stage: (.stage // "unknown"), timestamp: (.timestamp // "")}' 2>/dev/null || echo "")

    if [[ -z "$last_sig" || -z "$second_last_sig" ]]; then
        echo "$base_threshold"
        return 0
    fi

    # Compute similarity score
    local similarity_score
    similarity_score=$(score_signature_similarity "$second_last_sig" "$last_sig" 2>/dev/null || echo "0")

    local adjusted_threshold="$base_threshold"
    local adjustment_reason="no_change"

    # Decision logic
    if [[ "$similarity_score" -ge "$SIMILARITY_THRESHOLD" ]]; then
        # Failures are SIMILAR: likely same root cause → allow more attempts
        adjusted_threshold=$((base_threshold + THRESHOLD_SIMILAR_ADJUSTMENT))
        adjustment_reason="similar_signatures (${similarity_score}%)"
    elif [[ "$similarity_score" -lt 50 ]]; then
        # Failures are DIVERSE: unrelated issues → trip faster
        adjusted_threshold=$((base_threshold - THRESHOLD_DIVERSE_ADJUSTMENT))
        adjustment_reason="diverse_signatures (${similarity_score}%)"
    fi

    # Clamp to bounds
    if [[ "$adjusted_threshold" -lt "$THRESHOLD_MIN" ]]; then
        adjusted_threshold="$THRESHOLD_MIN"
    fi
    if [[ "$adjusted_threshold" -gt "$THRESHOLD_MAX" ]]; then
        adjusted_threshold="$THRESHOLD_MAX"
    fi

    # Emit event for observability
    if type emit_event >/dev/null 2>&1; then
        emit_event "loop.adaptive_circuit_breaker" \
            "base=$base_threshold" \
            "adjusted=$adjusted_threshold" \
            "reason=$adjustment_reason" \
            "similarity=$similarity_score"
    fi

    echo "$adjusted_threshold"
}

# ─── Diagnostic Functions ───────────────────────────────────────────────────

# diagnose_failure_signatures <error_log_file>
#
# Print a human-readable report of recent failure signatures.
# Useful for debugging and understanding failure patterns.
#
# INPUT:
#   $1: Path to error-log.jsonl file
#
# OUTPUT:
#   Formatted report to stdout
diagnose_failure_signatures() {
    local error_log="${1:-}"

    if [[ -z "$error_log" || ! -f "$error_log" ]]; then
        echo "No error log found"
        return 0
    fi

    local failure_count
    failure_count=$(wc -l < "$error_log" 2>/dev/null || echo "0")

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Failure Signature Analysis                                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo "Total failures: $failure_count"
    echo ""

    if [[ "$failure_count" -lt 2 ]]; then
        echo "Not enough failures to analyze"
        return 0
    fi

    local last_sig second_last_sig similarity
    last_sig=$(tail -1 "$error_log" 2>/dev/null | jq '{error: (.error // .message // ""), type: (.type // .error_type // "unknown"), stage: (.stage // "unknown")}' 2>/dev/null || echo "")
    second_last_sig=$(tail -2 "$error_log" 2>/dev/null | head -1 | jq '{error: (.error // .message // ""), type: (.type // .error_type // "unknown"), stage: (.stage // "unknown")}' 2>/dev/null || echo "")
    similarity=$(score_signature_similarity "$second_last_sig" "$last_sig" 2>/dev/null || echo "0")

    echo "Last two failures:"
    echo ""
    echo "  Signature 1 (N-1):"
    echo "$second_last_sig" | jq '.' 2>/dev/null || echo "    (parse error)"
    echo ""
    echo "  Signature 2 (N):"
    echo "$last_sig" | jq '.' 2>/dev/null || echo "    (parse error)"
    echo ""
    echo "  Similarity: ${similarity}%"

    if [[ "$similarity" -ge 75 ]]; then
        echo "  Assessment: SIMILAR - Likely same root cause"
    elif [[ "$similarity" -lt 50 ]]; then
        echo "  Assessment: DIVERSE - Likely different problems"
    else
        echo "  Assessment: MIXED - Partially related"
    fi
}

# Return non-zero exit code if called directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Standalone execution for testing
    case "${1:-}" in
        extract)
            extract_error_signatures "${2:-}"
            ;;
        score)
            score_signature_similarity "${2:-}" "${3:-}"
            ;;
        compute)
            compute_adaptive_threshold "${2:-}" "${3:-3}"
            ;;
        diagnose)
            diagnose_failure_signatures "${2:-}"
            ;;
        *)
            cat <<EOF
USAGE
  sw-circuit-breaker.sh <command> [args]

COMMANDS
  extract <error_log>               Extract signatures from error log
  score <sig1_json> <sig2_json>    Score similarity between two signatures
  compute <error_log> [threshold]  Compute adaptive threshold
  diagnose <error_log>              Print failure signature report

EXAMPLES
  sw-circuit-breaker.sh extract /path/to/error-log.jsonl
  sw-circuit-breaker.sh compute /path/to/error-log.jsonl 3
  sw-circuit-breaker.sh diagnose /path/to/error-log.jsonl

EOF
            exit 1
            ;;
    esac
fi
