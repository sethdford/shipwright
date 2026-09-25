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
# ║    query_memory_signature_match "$failures_json" "$error"  # verdict   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard - prevent double-sourcing
[[ -n "${_CIRCUIT_BREAKER_LOADED:-}" ]] && return 0
_CIRCUIT_BREAKER_LOADED=1

# shellcheck disable=SC2034
VERSION="3.3.0"
set -euo pipefail

# Private dir var: this file is sourced by lib/loop-convergence.sh, so it must
# not clobber the caller's SCRIPT_DIR.
_CB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$_CB_SCRIPT_DIR/lib/helpers.sh" ]] && source "$_CB_SCRIPT_DIR/lib/helpers.sh"

# Fallbacks when helpers not loaded (e.g. test env)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# Config helper
[[ -f "$_CB_SCRIPT_DIR/lib/config.sh" ]] && source "$_CB_SCRIPT_DIR/lib/config.sh" 2>/dev/null || true

# _cb_config_bool <dotpath> <default>
# Reads a config flag via _config_get (env → daemon-config → policy → default)
# and normalizes it to 1/0. Accepts true/1/yes/on. Falls back to <default>
# when config.sh is unavailable (e.g. sourced in isolation by tests).
_cb_config_bool() {
    local val="${2:-0}"
    if type _config_get >/dev/null 2>&1; then
        val=$(_config_get "$1" "${2:-0}" 2>/dev/null || echo "${2:-0}")
    fi
    case "$val" in
        true|1|yes|on) echo 1 ;;
        *) echo 0 ;;
    esac
}

# ─── Configuration ───────────────────────────────────────────────────────────
# Enable adaptive circuit breaker (default: false during rollout).
# Parsed as a boolean: _config_get_int would strip "true" to "" and silently
# disable the feature.
ADAPTIVE_ENABLED=$(_cb_config_bool "loop.adaptive_circuit_breaker_enabled" 0)

# Similarity threshold: failures above this % are considered "same signature"
SIMILARITY_THRESHOLD=${SIMILARITY_THRESHOLD:-75}

# Threshold adjustments
THRESHOLD_BASE=${THRESHOLD_BASE:-3}  # Default threshold when disabled
THRESHOLD_SIMILAR_ADJUSTMENT=${THRESHOLD_SIMILAR_ADJUSTMENT:-2}  # +2 when similar
THRESHOLD_DIVERSE_ADJUSTMENT=${THRESHOLD_DIVERSE_ADJUSTMENT:-1}  # -1 when diverse
THRESHOLD_MIN=${THRESHOLD_MIN:-2}  # Absolute minimum
THRESHOLD_MAX=${THRESHOLD_MAX:-8}  # Absolute maximum

# Memory-informed adjustment: consult failures.json (sw-memory) for the latest
# error. A known-resolvable failure earns extra attempts; a failure whose past
# fixes kept failing trips sooner. Purely local file read — works offline.
THRESHOLD_MEMORY_RESOLVED_ADJUSTMENT=${THRESHOLD_MEMORY_RESOLVED_ADJUSTMENT:-2}       # base +2
THRESHOLD_MEMORY_UNRECOVERABLE_ADJUSTMENT=${THRESHOLD_MEMORY_UNRECOVERABLE_ADJUSTMENT:-1}  # base -1
MEMORY_RESOLVED_MIN_RATE=${MEMORY_RESOLVED_MIN_RATE:-50}           # fix_effectiveness_rate % to count as resolved
MEMORY_UNRECOVERABLE_MAX_RATE=${MEMORY_UNRECOVERABLE_MAX_RATE:-20} # rate % at/below which applied fixes "don't work"
MEMORY_UNRECOVERABLE_MIN_SEEN=${MEMORY_UNRECOVERABLE_MIN_SEEN:-3}  # sightings needed for high confidence
MEMORY_MIN_MATCH_LEN=${MEMORY_MIN_MATCH_LEN:-8}                     # ignore trivially short patterns

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

# ─── Memory Signature Lookup ─────────────────────────────────────────────────

# resolve_memory_failures_file
#
# Locates the sw-memory failures.json for the current repo.
#
# Resolution order:
#   1. $CIRCUIT_BREAKER_MEMORY_FILE (explicit path, used by tests/fleet)
#   2. Empty when loop.adaptive_circuit_breaker_memory_enabled is false
#   3. ${MEMORY_ROOT:-$HOME/.shipwright/memory}/<repo_hash>/failures.json,
#      using the same repo hash as sw-memory.sh (sha256 of origin URL, 12 chars)
#
# OUTPUT:
#   Path to failures.json (may not exist), or empty when memory is disabled
#
# SIDE EFFECTS:
#   None (runs read-only git config in ${PROJECT_ROOT:-.})
resolve_memory_failures_file() {
    if [[ -n "${CIRCUIT_BREAKER_MEMORY_FILE:-}" ]]; then
        echo "$CIRCUIT_BREAKER_MEMORY_FILE"
        return 0
    fi

    if [[ "$(_cb_config_bool "loop.adaptive_circuit_breaker_memory_enabled" 1)" != "1" ]]; then
        echo ""
        return 0
    fi

    local origin hash=""
    origin=$(git -C "${PROJECT_ROOT:-.}" config --get remote.origin.url 2>/dev/null || echo "local")
    if command -v shasum >/dev/null 2>&1; then
        hash=$(printf '%s' "$origin" | shasum -a 256 2>/dev/null | cut -c1-12)
    elif command -v sha256sum >/dev/null 2>&1; then
        hash=$(printf '%s' "$origin" | sha256sum 2>/dev/null | cut -c1-12)
    fi
    if [[ -z "$hash" ]]; then
        echo ""
        return 0
    fi
    echo "${MEMORY_ROOT:-$HOME/.shipwright/memory}/${hash}/failures.json"
}

# query_memory_signature_match <failures_json> <error_message>
#
# Looks up an error message in sw-memory's failures.json and classifies how
# past pipelines fared against it.
#
# Matching: case-insensitive literal containment in either direction between
# the stored pattern and the error (patterns shorter than MEMORY_MIN_MATCH_LEN
# are ignored so e.g. "error" doesn't match everything).
#
# Verdicts (a resolved match wins over an unrecoverable one):
#   resolved       — times_fix_resolved > 0 and
#                    fix_effectiveness_rate >= MEMORY_RESOLVED_MIN_RATE
#   unrecoverable  — seen_count >= MEMORY_UNRECOVERABLE_MIN_SEEN, fixes were
#                    applied, and fix_effectiveness_rate <= MEMORY_UNRECOVERABLE_MAX_RATE
#   none           — no match, low-confidence match, missing/malformed file
#
# INPUT:
#   $1: Path to failures.json
#   $2: Error message of the most recent failure
#
# OUTPUT:
#   One of: resolved | unrecoverable | none
#
# SIDE EFFECTS:
#   None (read-only)
query_memory_signature_match() {
    local failures_file="${1:-}"
    local error_msg="${2:-}"

    if [[ -z "$failures_file" || ! -f "$failures_file" || -z "$error_msg" ]]; then
        echo "none"
        return 0
    fi

    local verdict
    verdict=$(jq -r \
        --arg err "$error_msg" \
        --argjson min_len "$MEMORY_MIN_MATCH_LEN" \
        --argjson resolved_rate "$MEMORY_RESOLVED_MIN_RATE" \
        --argjson unrec_rate "$MEMORY_UNRECOVERABLE_MAX_RATE" \
        --argjson unrec_seen "$MEMORY_UNRECOVERABLE_MIN_SEEN" '
        ($err | ascii_downcase) as $e
        | [(.failures // [])[]
           | select(type == "object")
           | select((.pattern // "") | type == "string" and length >= $min_len)
           | (.pattern | ascii_downcase) as $p
           | select(($e | contains($p)) or ($p | contains($e)))
           | (.fix_effectiveness_rate // 0) as $rate
           | if (.times_fix_resolved // 0) > 0 and $rate >= $resolved_rate then "resolved"
             elif (.seen_count // 1) >= $unrec_seen
                  and (.times_fix_applied // 0) > 0
                  and $rate <= $unrec_rate then "unrecoverable"
             else "none" end]
        | if index("resolved") != null then "resolved"
          elif index("unrecoverable") != null then "unrecoverable"
          else "none" end
    ' "$failures_file" 2>/dev/null || echo "none")

    case "$verdict" in
        resolved|unrecoverable) echo "$verdict" ;;
        *) echo "none" ;;
    esac
}

# ─── Adaptive Threshold Computation ──────────────────────────────────────────

# compute_adaptive_threshold <error_log_file> <base_threshold>
#
# Adjusts the circuit breaker threshold from two signals:
#
#   1. Signature similarity of the last two failures (needs 2+ entries):
#      - SIMILAR (>= SIMILARITY_THRESHOLD%): same root cause → base + 2
#      - DIVERSE (< 50%): unrelated problems → base - 1
#      - MIXED (50-74%): unchanged
#
#   2. Memory verdict for the latest failure (needs 1+ entry). Memory is
#      cross-run evidence, so it takes precedence over within-run similarity:
#      - resolved: past runs fixed this → base + 2 (even if failures diverse)
#      - unrecoverable: past fixes kept failing → base - 1 (even if similar —
#        more retries of a known-dead-end won't help)
#      - none: similarity result stands (static fallback when both are neutral)
#
# Returns the base unchanged when the feature is disabled, when
# loop.circuit_breaker_threshold_pinned is true (explicit operator override),
# or when the log is missing/empty. All results clamp to
# [THRESHOLD_MIN, THRESHOLD_MAX].
#
# INPUT:
#   $1: Path to error-log.jsonl file
#   $2: Base threshold (default: THRESHOLD_BASE)
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

    # Operator pinned the threshold: never override an explicit setting
    if [[ "$(_cb_config_bool "loop.circuit_breaker_threshold_pinned" 0)" == "1" ]]; then
        echo "$base_threshold"
        return 0
    fi

    # No error log: return base
    if [[ -z "$error_log" || ! -f "$error_log" ]]; then
        echo "$base_threshold"
        return 0
    fi

    local failure_count
    failure_count=$(grep -c '.' "$error_log" 2>/dev/null || true)
    failure_count="${failure_count:-0}"
    if [[ "$failure_count" -lt 1 ]]; then
        echo "$base_threshold"
        return 0
    fi

    local sig_filter='{error: (.error // .message // ""), type: (.type // .error_type // "unknown"), stage: (.stage // "unknown"), timestamp: (.timestamp // "")}'
    local last_line last_sig last_error
    last_line=$(grep '.' "$error_log" 2>/dev/null | tail -1 || true)
    last_sig=$(printf '%s\n' "$last_line" | jq -c "$sig_filter" 2>/dev/null || echo "")
    last_error=$(printf '%s\n' "$last_sig" | jq -r '.error // ""' 2>/dev/null || echo "")

    local adjusted_threshold="$base_threshold"
    local adjustment_reason="no_change"
    local similarity_score="n/a"

    # Signal 1: within-run signature similarity
    if [[ "$failure_count" -ge 2 && -n "$last_sig" ]]; then
        local second_last_sig
        second_last_sig=$(grep '.' "$error_log" 2>/dev/null | tail -2 | head -1 | jq -c "$sig_filter" 2>/dev/null || echo "")
        if [[ -n "$second_last_sig" ]]; then
            similarity_score=$(score_signature_similarity "$second_last_sig" "$last_sig" 2>/dev/null || echo "0")
            if [[ "$similarity_score" -ge "$SIMILARITY_THRESHOLD" ]]; then
                adjusted_threshold=$((base_threshold + THRESHOLD_SIMILAR_ADJUSTMENT))
                adjustment_reason="similar_signatures (${similarity_score}%)"
            elif [[ "$similarity_score" -lt 50 ]]; then
                adjusted_threshold=$((base_threshold - THRESHOLD_DIVERSE_ADJUSTMENT))
                adjustment_reason="diverse_signatures (${similarity_score}%)"
            fi
        fi
    fi

    # Signal 2: cross-run memory verdict for the latest error
    local memory_verdict="none"
    if [[ -n "$last_error" ]]; then
        local failures_file
        failures_file=$(resolve_memory_failures_file 2>/dev/null || echo "")
        memory_verdict=$(query_memory_signature_match "$failures_file" "$last_error" 2>/dev/null || echo "none")
    fi
    case "$memory_verdict" in
        resolved)
            adjusted_threshold=$((base_threshold + THRESHOLD_MEMORY_RESOLVED_ADJUSTMENT))
            adjustment_reason="memory_resolved_match"
            ;;
        unrecoverable)
            adjusted_threshold=$((base_threshold - THRESHOLD_MEMORY_UNRECOVERABLE_ADJUSTMENT))
            adjustment_reason="memory_unrecoverable_match"
            ;;
    esac

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
            "similarity=$similarity_score" \
            "memory=$memory_verdict" >/dev/null 2>&1 || true
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
        memory)
            query_memory_signature_match "${2:-}" "${3:-}"
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
  memory <failures_json> <error>    Classify error against memory (resolved|unrecoverable|none)
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
