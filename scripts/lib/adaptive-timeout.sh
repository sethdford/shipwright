#!/usr/bin/env bash
# adaptive-timeout.sh — Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning
# Source from sw-pipeline.sh. Requires SCRIPT_DIR and helpers (info, warn, error, emit_event).
# Tracks historical stage durations and auto-adjusts timeouts based on P95 percentile.

[[ -n "${_ADAPTIVE_TIMEOUT_LOADED:-}" ]] && return 0
_ADAPTIVE_TIMEOUT_LOADED=1

# Module version for debugging
VERSION="3.3.0"

# ─── Configuration ──────────────────────────────────────────────────────────

# Default timeouts per stage (in seconds)
# Using case statement instead of associative arrays for bash 3.2 compatibility
_timeout_default() {
    local stage="${1:-unknown}"
    case "$stage" in
        intake)         echo 60 ;;
        plan)           echo 300 ;;
        design)         echo 300 ;;
        build)          echo 1800 ;;
        test)           echo 600 ;;
        review)         echo 600 ;;
        compound_quality) echo 900 ;;
        pr)             echo 120 ;;
        merge)          echo 120 ;;
        deploy)         echo 300 ;;
        validate)       echo 300 ;;
        monitor)        echo 300 ;;
        *)              echo 300 ;;  # Default fallback
    esac
}

# Adaptive timeout constraints (in seconds)
TIMEOUT_MIN=30
TIMEOUT_MAX=7200
TIMEOUT_BUFFER_PCT=20  # Add 20% buffer to P95

# Historical data thresholds
TIMEOUT_MIN_SAMPLES=10  # Require N samples before using adaptive timeout
TIMEOUT_HISTORY_LOOKBACK=100  # Use last N samples for P95 calculation
TIMEOUT_ROTATION_ENTRIES=10000  # Rotate history file at N entries

# Paths
TIMEOUT_HISTORY_FILE="${HOME}/.shipwright/optimization/stage-durations.jsonl"

# ─── Initialize ────────────────────────────────────────────────────────────

# timeout_init() — Initialize adaptive timeout system.
# Creates history directory if needed.
# Returns: 0 on success
timeout_init() {
    local history_dir
    history_dir=$(dirname "$TIMEOUT_HISTORY_FILE")

    if [[ ! -d "$history_dir" ]]; then
        mkdir -p "$history_dir" 2>/dev/null || true
    fi

    # Verify file exists (create if not)
    if [[ ! -f "$TIMEOUT_HISTORY_FILE" ]]; then
        touch "$TIMEOUT_HISTORY_FILE" 2>/dev/null || true
    fi

    return 0
}

# ─── Timeout Retrieval ──────────────────────────────────────────────────────

# timeout_get(stage) — Get adaptive timeout for a stage.
# Returns the appropriate timeout in seconds (default or adaptive based on history).
# $1: stage name (e.g., "build", "test")
# Returns: timeout in seconds
timeout_get() {
    local stage="${1:-unknown}"

    # Ensure initialization
    timeout_init

    # Get default for this stage
    local default_timeout
    default_timeout=$(_timeout_default "$stage")

    # Check if we have enough historical data
    local sample_count
    sample_count=$(timeout_sample_count "$stage")

    if [[ "$sample_count" -lt "$TIMEOUT_MIN_SAMPLES" ]]; then
        # Not enough data — use default
        echo "$default_timeout"
        return 0
    fi

    # Calculate P95 and apply buffer
    local p95_duration
    p95_duration=$(timeout_calculate_p95 "$stage") || p95_duration=""

    if [[ -z "$p95_duration" || "$p95_duration" -le 0 ]]; then
        # P95 calculation failed — use default
        echo "$default_timeout"
        return 0
    fi

    # Add 20% buffer to P95
    local adaptive_timeout
    adaptive_timeout=$(( p95_duration + (p95_duration * TIMEOUT_BUFFER_PCT / 100) ))

    # Enforce min/max bounds
    if [[ "$adaptive_timeout" -lt "$TIMEOUT_MIN" ]]; then
        adaptive_timeout=$TIMEOUT_MIN
    elif [[ "$adaptive_timeout" -gt "$TIMEOUT_MAX" ]]; then
        adaptive_timeout=$TIMEOUT_MAX
    fi

    echo "$adaptive_timeout"
    return 0
}

# ─── Duration Recording ────────────────────────────────────────────────────

# timeout_record(stage, duration_seconds, [pipeline_template], [complexity], [result]) — Record a stage duration.
# Appends JSONL entry to history. Rotates file when it reaches TIMEOUT_ROTATION_ENTRIES.
# $1: stage name
# $2: duration in seconds
# $3: (optional) pipeline_template (fast/standard/full/hotfix/autonomous/enterprise/cost-aware/deployed)
# $4: (optional) complexity (simple/medium/complex/critical)
# $5: (optional) result (success/timeout/failure) — default: success
# Returns: 0 on success
timeout_record() {
    local stage="${1:-unknown}"
    local duration_seconds="${2:-0}"
    local pipeline_template="${3:-standard}"
    local complexity="${4:-medium}"
    local result="${5:-success}"

    # Validate inputs
    if ! [[ "$duration_seconds" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if [[ "$stage" == "unknown" ]]; then
        return 1
    fi

    # Ensure initialization
    timeout_init

    # Create JSON entry (include result field for exclusion filtering)
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local entry
    entry=$(printf '{"stage":"%s","duration_s":%d,"timestamp":"%s","pipeline_template":"%s","complexity":"%s","result":"%s"}\n' \
        "$stage" "$duration_seconds" "$timestamp" "$pipeline_template" "$complexity" "$result")

    # Atomic write (mktemp + mv pattern for safety under pipefail)
    local tmpfile
    tmpfile=$(mktemp) || return 1
    trap "rm -f '$tmpfile'" RETURN

    # Append new entry and existing data
    {
        printf '%s\n' "$entry"
        cat "$TIMEOUT_HISTORY_FILE" 2>/dev/null || true
    } > "$tmpfile"

    # Rotate if needed
    local line_count
    line_count=$(wc -l < "$tmpfile" 2>/dev/null | xargs)
    if [[ "$line_count" -gt "$TIMEOUT_ROTATION_ENTRIES" ]]; then
        # Keep only last N entries
        tail -n "$TIMEOUT_ROTATION_ENTRIES" "$tmpfile" > "${tmpfile}.rotated"
        mv "${tmpfile}.rotated" "$tmpfile"
    fi

    # Move to final location
    mv "$tmpfile" "$TIMEOUT_HISTORY_FILE"

    return 0
}

# ─── P95 Calculation ────────────────────────────────────────────────────────

# timeout_sample_count(stage) — Count historical samples for a stage.
# $1: stage name
# Returns: number of samples
timeout_sample_count() {
    local stage="${1:-unknown}"

    [[ ! -f "$TIMEOUT_HISTORY_FILE" ]] && echo "0" && return 0

    # Count lines where .stage == arg1
    grep -c "\"stage\":\"$stage\"" "$TIMEOUT_HISTORY_FILE" 2>/dev/null | xargs || echo "0"
}

# timeout_calculate_p95(stage) — Calculate P95 duration from historical data.
# Uses jq to extract durations, sort, and compute the 95th percentile.
# Applies TIMEOUT_HISTORY_LOOKBACK to use only the N most recent samples.
# $1: stage name
# Returns: P95 duration in seconds (or empty string on error)
timeout_calculate_p95() {
    local stage="${1:-unknown}"

    [[ ! -f "$TIMEOUT_HISTORY_FILE" ]] && return 1

    # Extract durations for this stage, sort, and get P95
    # P95 is the value at index (count * 0.95) rounded down
    # Entries are prepended newest-first, so head -n gets the most recent samples
    local p95

    # Method 1: Pure jq with proper slurping of each JSON object's duration_s field
    # Apply lookback window with head (newest-first ordering)
    # Exclude timeout-killed runs (result != "timeout") from p95 calculation
    p95=$(grep "\"stage\":\"$stage\"" "$TIMEOUT_HISTORY_FILE" 2>/dev/null | \
        head -n "$TIMEOUT_HISTORY_LOOKBACK" | \
        jq -s 'map(select(.result != "timeout" or .result == null) | .duration_s) | sort |
                (length * 0.95 | floor) as $idx |
                if .[$idx] then .[$idx] else empty end' 2>/dev/null) || p95=""

    # Fallback: if jq pipeline fails, try awk approach
    if [[ -z "$p95" ]]; then
        p95=$(grep "\"stage\":\"$stage\"" "$TIMEOUT_HISTORY_FILE" 2>/dev/null | \
            head -n "$TIMEOUT_HISTORY_LOOKBACK" | \
            jq -r 'select(.result != "timeout" or .result == null) | .duration_s' 2>/dev/null | \
            awk '{arr[NR]=$1} END {
                count=length(arr);
                if (count==0) exit 1;
                for (i=1; i<=count; i++) for (j=i; j<=count; j++)
                    if (arr[i]>arr[j]) {t=arr[i]; arr[i]=arr[j]; arr[j]=t}
                idx=int(count*0.95); if (idx==0) idx=1;
                print arr[idx]
            }' 2>/dev/null) || p95=""
    fi

    # Output result (empty string on complete failure)
    [[ -n "$p95" ]] && echo "$p95" || return 1
}

# ─── Reporting ──────────────────────────────────────────────────────────────

# timeout_report() — Show timeout tuning statistics.
# Displays per-stage defaults, current adaptive values, P50/P95, and sample counts.
# Returns: 0
timeout_report() {
    local stage

    echo ""
    printf "├─ %s\n" "Adaptive Stage Timeout Report"
    printf "│\n"
    printf "│  %-20s %8s %8s %8s %8s %6s\n" "Stage" "Default" "Adaptive" "P50" "P95" "Samples"
    printf "│  %s\n" "$(printf '%.0s─' {1..80})"

    # List of all known stages
    local stages=(intake plan design build test review compound_quality pr merge deploy validate monitor)

    for stage in "${stages[@]}"; do
        local default_timeout
        default_timeout=$(_timeout_default "$stage")
        local sample_count
        sample_count=$(timeout_sample_count "$stage")

        if [[ "$sample_count" -lt "$TIMEOUT_MIN_SAMPLES" ]]; then
            # Not enough data
            printf "│  %-20s %8ds %8s %8s %8s %6d\n" \
                "$stage" "$default_timeout" "—" "—" "—" "$sample_count"
        else
            # Calculate P50 and P95
            local p50 p95 adaptive_timeout

            # P50 (median), excluding timeout-killed runs
            p50=$(grep "\"stage\":\"$stage\"" "$TIMEOUT_HISTORY_FILE" 2>/dev/null | \
                head -n "$TIMEOUT_HISTORY_LOOKBACK" | \
                jq -s 'map(select(.result != "timeout" or .result == null) | .duration_s) | sort |
                           (length * 0.5 | floor) as $idx |
                           if .[$idx] then .[$idx] else empty end' 2>/dev/null)
            p50="${p50:-—}"

            # P95
            p95=$(timeout_calculate_p95 "$stage") || p95="—"

            # Current adaptive timeout
            adaptive_timeout=$(timeout_get "$stage")

            # Format output
            local p50_str p95_str adaptive_str
            p50_str=$([[ "$p50" == "—" ]] && echo "—" || printf "%ds" "$p50")
            p95_str=$([[ "$p95" == "—" ]] && echo "—" || printf "%ds" "$p95")
            adaptive_str=$(printf "%ds" "$adaptive_timeout")

            printf "│  %-20s %8ds %8s %8s %8s %6d\n" \
                "$stage" "$default_timeout" "$adaptive_str" "$p50_str" "$p95_str" "$sample_count"
        fi
    done

    printf "│\n"
    printf "├─ Summary\n"
    printf "│  Min timeout: %ds | Max timeout: %ds | Buffer: %d%%\n" \
        "$TIMEOUT_MIN" "$TIMEOUT_MAX" "$TIMEOUT_BUFFER_PCT"
    printf "│  Min samples for adaptive: %d | History lookback: %d | Rotation: %d entries\n" \
        "$TIMEOUT_MIN_SAMPLES" "$TIMEOUT_HISTORY_LOOKBACK" "$TIMEOUT_ROTATION_ENTRIES"
    printf "│  History file: %s (%d lines)\n" \
        "$TIMEOUT_HISTORY_FILE" "$(wc -l < "$TIMEOUT_HISTORY_FILE" 2>/dev/null | xargs || echo 0)"
    printf "└─\n"

    return 0
}

# ─── Utility: Reset history (for testing/cleanup) ────────────────────────────

# timeout_reset() — Clear all historical data (for testing).
# Usage: timeout_reset
# Returns: 0
timeout_reset() {
    if [[ -f "$TIMEOUT_HISTORY_FILE" ]]; then
        rm -f "$TIMEOUT_HISTORY_FILE" || return 1
    fi
    return 0
}

# ─── Initialization on load ──────────────────────────────────────────────────

timeout_init
