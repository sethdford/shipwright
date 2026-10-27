#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_REWARD_AGGREGATOR_LOADED:-}" ]] && return 0
_REWARD_AGGREGATOR_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright reward-aggregator — Composite Reward from All Data Signals   ║
# ║  Reads process-rewards, costs, stage-effectiveness, recovery-log,        ║
# ║  quality-scores, memory-outcomes → weighted composite (0.0-1.0)          ║
# ║  Stores history in ~/.shipwright/rewards.jsonl for RL feedback           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# shellcheck disable=SC2034
VERSION="4.0.0"

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

REWARDS_FILE="${REWARDS_FILE:-${HOME}/.shipwright/rewards.jsonl}"
PROCESS_REWARDS_FILE="${PROCESS_REWARDS_FILE:-.claude/pipeline-artifacts/process-rewards.jsonl}"
COSTS_FILE="${COSTS_FILE:-${HOME}/.shipwright/costs.json}"
STAGE_EFFECTIVENESS_FILE="${STAGE_EFFECTIVENESS_FILE:-.claude/pipeline-artifacts/stage-effectiveness.jsonl}"
RECOVERY_LOG_FILE="${RECOVERY_LOG_FILE:-.claude/pipeline-artifacts/recovery-log.jsonl}"
QUALITY_SCORES_FILE="${QUALITY_SCORES_FILE:-.claude/pipeline-artifacts/quality-scores.jsonl}"
MEMORY_OUTCOMES_FILE="${MEMORY_OUTCOMES_FILE:-.claude/pipeline-artifacts/memory-outcomes.jsonl}"

# Weights for composite reward (must sum to 1.0)
REWARD_WEIGHT_TEST="${REWARD_WEIGHT_TEST:-0.30}"
REWARD_WEIGHT_ITERATIONS="${REWARD_WEIGHT_ITERATIONS:-0.20}"
REWARD_WEIGHT_COST="${REWARD_WEIGHT_COST:-0.15}"
REWARD_WEIGHT_QUALITY="${REWARD_WEIGHT_QUALITY:-0.15}"
REWARD_WEIGHT_CONVERGENCE="${REWARD_WEIGHT_CONVERGENCE:-0.10}"
REWARD_WEIGHT_MEMORY="${REWARD_WEIGHT_MEMORY:-0.10}"

REWARD_BASELINE_DAYS="${REWARD_BASELINE_DAYS:-30}"
REWARD_RECENT_COUNT="${REWARD_RECENT_COUNT:-5}"

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Clamp a float to [0.0, 1.0]
_reward_clamp() {
    local val="${1:-0}"
    awk -v v="$val" 'BEGIN { if (v < 0) v = 0; if (v > 1) v = 1; printf "%.4f", v }'
}

# Safe float division with zero guard
_reward_div() {
    local num="${1:-0}" den="${2:-1}"
    awk -v n="$num" -v d="$den" 'BEGIN { if (d == 0) d = 1; printf "%.4f", n / d }'
}

# Ensure rewards directory exists
_reward_ensure_dir() {
    local dir
    dir=$(dirname "$REWARDS_FILE")
    [[ -d "$dir" ]] || mkdir -p "$dir"
}

# ─── Signal Extractors ──────────────────────────────────────────────────────

# Extract test outcome score from process-rewards.jsonl
# Returns 1.0 if tests passed, 0.0 if failed, 0.5 as default
_reward_extract_test_outcome() {
    local pipeline_id="${1:-}"

    if [[ ! -f "$PROCESS_REWARDS_FILE" ]]; then
        echo "0.5"
        return 0
    fi

    # Get the last entry for this pipeline (or last overall)
    local result
    if [[ -n "$pipeline_id" ]]; then
        result=$(jq -r --arg pid "$pipeline_id" \
            'select(.pipeline_id == $pid) | .scores.test_outcome // .test_passed // empty' \
            "$PROCESS_REWARDS_FILE" 2>/dev/null | tail -1)
    fi
    if [[ -z "${result:-}" ]]; then
        result=$(jq -r '.scores.test_outcome // .test_passed // empty' \
            "$PROCESS_REWARDS_FILE" 2>/dev/null | tail -1)
    fi

    if [[ -z "${result:-}" ]]; then
        echo "0.5"
    else
        _reward_clamp "$result"
    fi
}

# Extract iteration efficiency from process-rewards.jsonl
# Score = 1.0 - (iterations_used / max_iterations), clamped
_reward_extract_iteration_efficiency() {
    local pipeline_id="${1:-}"

    if [[ ! -f "$PROCESS_REWARDS_FILE" ]]; then
        echo "0.5"
        return 0
    fi

    local iterations max_iterations
    if [[ -n "$pipeline_id" ]]; then
        iterations=$(jq -r --arg pid "$pipeline_id" \
            'select(.pipeline_id == $pid) | .iteration // empty' \
            "$PROCESS_REWARDS_FILE" 2>/dev/null | tail -1)
        max_iterations=$(jq -r --arg pid "$pipeline_id" \
            'select(.pipeline_id == $pid) | .max_iterations // empty' \
            "$PROCESS_REWARDS_FILE" 2>/dev/null | tail -1)
    fi
    if [[ -z "${iterations:-}" ]]; then
        iterations=$(jq -r '.iteration // empty' \
            "$PROCESS_REWARDS_FILE" 2>/dev/null | tail -1)
    fi
    if [[ -z "${max_iterations:-}" ]]; then
        max_iterations=$(jq -r '.max_iterations // empty' \
            "$PROCESS_REWARDS_FILE" 2>/dev/null | tail -1)
    fi

    iterations="${iterations:-5}"
    max_iterations="${max_iterations:-10}"

    local score
    score=$(_reward_div "$iterations" "$max_iterations")
    score=$(awk -v s="$score" 'BEGIN { printf "%.4f", 1.0 - s }')
    _reward_clamp "$score"
}

# Extract cost efficiency from costs.json
# Score = budget_remaining / budget_total (higher = more efficient)
_reward_extract_cost_efficiency() {
    if [[ ! -f "$COSTS_FILE" ]]; then
        echo "0.5"
        return 0
    fi

    local total_cost budget
    total_cost=$(jq -r '.total_cost // .cost // 0' "$COSTS_FILE" 2>/dev/null || echo "0")
    budget=$(jq -r '.budget // .daily_budget // 0' "$COSTS_FILE" 2>/dev/null || echo "0")

    if [[ "$budget" == "0" ]] || [[ -z "$budget" ]] || [[ "$budget" == "null" ]]; then
        # No budget set — if cost is low, that's good
        if awk -v c="$total_cost" 'BEGIN { exit (c < 5) ? 0 : 1 }'; then
            echo "0.8"
        else
            echo "0.5"
        fi
        return 0
    fi

    local ratio
    ratio=$(_reward_div "$total_cost" "$budget")
    # Efficiency = 1.0 - cost_ratio (spending less of budget = better)
    local score
    score=$(awk -v r="$ratio" 'BEGIN { printf "%.4f", 1.0 - r }')
    _reward_clamp "$score"
}

# Extract quality score from quality-scores.jsonl
_reward_extract_quality_score() {
    local pipeline_id="${1:-}"

    if [[ ! -f "$QUALITY_SCORES_FILE" ]]; then
        echo "0.5"
        return 0
    fi

    local score
    if [[ -n "$pipeline_id" ]]; then
        score=$(jq -r --arg pid "$pipeline_id" \
            'select(.pipeline_id == $pid) | .score // .quality // empty' \
            "$QUALITY_SCORES_FILE" 2>/dev/null | tail -1)
    fi
    if [[ -z "${score:-}" ]]; then
        score=$(jq -r '.score // .quality // empty' \
            "$QUALITY_SCORES_FILE" 2>/dev/null | tail -1)
    fi

    if [[ -z "${score:-}" ]]; then
        echo "0.5"
    else
        _reward_clamp "$score"
    fi
}

# Extract convergence speed from stage-effectiveness.jsonl
# Ratio of passed stages to total stages
_reward_extract_convergence_speed() {
    if [[ ! -f "$STAGE_EFFECTIVENESS_FILE" ]]; then
        echo "0.5"
        return 0
    fi

    local total passed
    total=$(wc -l < "$STAGE_EFFECTIVENESS_FILE" 2>/dev/null || echo "0")
    total=$(echo "$total" | tr -d ' ')
    if [[ "$total" -eq 0 ]]; then
        echo "0.5"
        return 0
    fi

    passed=$(grep -c '"passed"' "$STAGE_EFFECTIVENESS_FILE" 2>/dev/null || true)
    passed="${passed:-0}"

    _reward_clamp "$(_reward_div "$passed" "$total")"
}

# Extract memory hit rate from memory-outcomes.jsonl
_reward_extract_memory_hit_rate() {
    if [[ ! -f "$MEMORY_OUTCOMES_FILE" ]]; then
        echo "0.5"
        return 0
    fi

    local total hits
    total=$(wc -l < "$MEMORY_OUTCOMES_FILE" 2>/dev/null || echo "0")
    total=$(echo "$total" | tr -d ' ')
    if [[ "$total" -eq 0 ]]; then
        echo "0.5"
        return 0
    fi

    hits=$(jq -r 'select(.hit == true or .useful == true) | "1"' \
        "$MEMORY_OUTCOMES_FILE" 2>/dev/null | wc -l || true)
    hits=$(echo "$hits" | tr -d ' ')
    hits="${hits:-0}"

    _reward_clamp "$(_reward_div "$hits" "$total")"
}

# ─── Core Functions ──────────────────────────────────────────────────────────

# Aggregate all signals into a composite reward for a pipeline run
# Args: [pipeline_id] [language] [complexity]
# Output: JSON reward record to stdout, appends to rewards.jsonl
reward_aggregate_pipeline() {
    local pipeline_id="${1:-$(date +%s)}"
    local language="${2:-unknown}"
    local complexity="${3:-medium}"

    _reward_ensure_dir

    # Extract all component scores
    local test_score iteration_score cost_score quality_score convergence_score memory_score
    test_score=$(_reward_extract_test_outcome "$pipeline_id")
    iteration_score=$(_reward_extract_iteration_efficiency "$pipeline_id")
    cost_score=$(_reward_extract_cost_efficiency)
    quality_score=$(_reward_extract_quality_score "$pipeline_id")
    convergence_score=$(_reward_extract_convergence_speed)
    memory_score=$(_reward_extract_memory_hit_rate)

    # Compute weighted composite
    local composite
    composite=$(awk \
        -v t="$test_score" -v wt="$REWARD_WEIGHT_TEST" \
        -v i="$iteration_score" -v wi="$REWARD_WEIGHT_ITERATIONS" \
        -v c="$cost_score" -v wc="$REWARD_WEIGHT_COST" \
        -v q="$quality_score" -v wq="$REWARD_WEIGHT_QUALITY" \
        -v s="$convergence_score" -v ws="$REWARD_WEIGHT_CONVERGENCE" \
        -v m="$memory_score" -v wm="$REWARD_WEIGHT_MEMORY" \
        'BEGIN { printf "%.4f", t*wt + i*wi + c*wc + q*wq + s*ws + m*wm }')
    composite=$(_reward_clamp "$composite")

    # Build JSON record
    local timestamp
    timestamp=$(now_iso)
    local record
    record=$(jq -c -n \
        --arg ts "$timestamp" \
        --arg pid "$pipeline_id" \
        --argjson reward "$composite" \
        --argjson test "$test_score" \
        --argjson iter "$iteration_score" \
        --argjson cost "$cost_score" \
        --argjson qual "$quality_score" \
        --argjson conv "$convergence_score" \
        --argjson mem "$memory_score" \
        --arg lang "$language" \
        --arg comp "$complexity" \
        '{
            timestamp: $ts,
            epoch: (now | floor),
            pipeline_id: $pid,
            reward: $reward,
            components: {
                test_outcome: $test,
                iteration_efficiency: $iter,
                cost_efficiency: $cost,
                quality_score: $qual,
                convergence_speed: $conv,
                memory_hit_rate: $mem
            },
            context: {
                language: $lang,
                complexity: $comp
            }
        }')

    # Append to rewards file (non-atomic append — acceptable for single-worker pipelines)
    local tmp_append
    tmp_append=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/reward-append-$$")
    echo "$record" > "$tmp_append"
    cat "$tmp_append" >> "$REWARDS_FILE"
    rm -f "$tmp_append"

    # Emit event
    if type emit_event >/dev/null 2>&1; then
        emit_event "reward_aggregated" \
            "pipeline_id=$pipeline_id" \
            "reward=$composite" \
            "test=$test_score" \
            "cost=$cost_score"
    fi

    echo "$record"
}

# Return last N rewards with context
# Args: [count]
# Output: JSON array
reward_get_history() {
    local count="${1:-10}"

    if [[ ! -f "$REWARDS_FILE" ]]; then
        echo "[]"
        return 0
    fi

    local total
    total=$(wc -l < "$REWARDS_FILE" 2>/dev/null || echo "0")
    total=$(echo "$total" | tr -d ' ')

    if [[ "$total" -eq 0 ]]; then
        echo "[]"
        return 0
    fi

    tail -n "$count" "$REWARDS_FILE" | jq -s '.' 2>/dev/null || echo "[]"
}

# Compute rolling baseline reward (average over N days)
# Args: [days]
# Output: float (0.0-1.0)
reward_compute_baseline() {
    local days="${1:-$REWARD_BASELINE_DAYS}"

    if [[ ! -f "$REWARDS_FILE" ]]; then
        echo "0.5000"
        return 0
    fi

    local cutoff_epoch now_epoch_val
    now_epoch_val=$(date +%s)
    cutoff_epoch=$(awk -v now="$now_epoch_val" -v d="$days" 'BEGIN { printf "%d", now - (d * 86400) }')

    # Filter records within the baseline window and compute average
    # Extract both epoch and reward so awk can filter by time
    local avg
    avg=$(jq -r '"\(.epoch // 9999999999) \(.reward // 0)"' "$REWARDS_FILE" 2>/dev/null | \
        awk -v cutoff="$cutoff_epoch" '
        BEGIN { sum = 0; count = 0 }
        { if ($1 >= cutoff) { sum += $2; count++ } }
        END {
            if (count == 0) { printf "0.5000"; exit }
            printf "%.4f", sum / count
        }')

    if [[ -z "${avg:-}" ]] || [[ "$avg" == "0.5000" ]]; then
        echo "0.5000"
        return 0
    fi
    _reward_clamp "$avg"
}

# Compare recent reward average vs baseline
# Args: [recent_count] [baseline_days]
# Output: JSON with improving (bool), delta, recent_avg, baseline
reward_is_improving() {
    local recent_count="${1:-$REWARD_RECENT_COUNT}"
    local baseline_days="${2:-$REWARD_BASELINE_DAYS}"

    local baseline
    baseline=$(reward_compute_baseline "$baseline_days")

    if [[ ! -f "$REWARDS_FILE" ]]; then
        jq -n \
            --argjson improving false \
            --argjson delta 0 \
            --argjson recent_avg 0.5 \
            --argjson baseline "$baseline" \
            '{ improving: $improving, delta: $delta, recent_avg: $recent_avg, baseline: $baseline }'
        return 0
    fi

    local recent_avg
    recent_avg=$(tail -n "$recent_count" "$REWARDS_FILE" 2>/dev/null | \
        jq -r '.reward' 2>/dev/null | \
        awk '
        BEGIN { sum = 0; count = 0 }
        { sum += $1; count++ }
        END {
            if (count == 0) { printf "0.5000"; exit }
            printf "%.4f", sum / count
        }')
    recent_avg="${recent_avg:-0.5}"

    local delta improving
    delta=$(awk -v r="$recent_avg" -v b="$baseline" 'BEGIN { printf "%.4f", r - b }')
    improving=$(awk -v d="$delta" 'BEGIN { print (d > 0) ? "true" : "false" }')

    jq -n \
        --argjson improving "$improving" \
        --argjson delta "$delta" \
        --argjson recent_avg "$recent_avg" \
        --argjson baseline "$baseline" \
        '{ improving: $improving, delta: $delta, recent_avg: $recent_avg, baseline: $baseline }'
}

# Format reward trend as markdown for agent prompt injection
# Output: markdown string
reward_inject_feedback() {
    local result
    result=$(reward_is_improving)

    local recent_avg baseline delta improving
    recent_avg=$(echo "$result" | jq -r '.recent_avg')
    baseline=$(echo "$result" | jq -r '.baseline')
    delta=$(echo "$result" | jq -r '.delta')
    improving=$(echo "$result" | jq -r '.improving')

    local pct_change arrow
    if awk -v b="$baseline" 'BEGIN { exit (b == 0) ? 0 : 1 }'; then
        pct_change="N/A"
    else
        pct_change=$(awk -v d="$delta" -v b="$baseline" 'BEGIN { printf "%.0f", (d / b) * 100 }')
    fi

    if [[ "$improving" == "true" ]]; then
        arrow="↑"
    else
        arrow="↓"
        # Make pct_change absolute for display
        pct_change=$(echo "$pct_change" | tr -d '-')
    fi

    if [[ "$pct_change" == "N/A" ]]; then
        echo "Your pipeline performance: ${recent_avg} (no baseline yet)"
    else
        echo "Your pipeline performance: ${recent_avg} (${arrow}${pct_change}% vs 30-day baseline of ${baseline})"
    fi
}
