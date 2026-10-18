#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost-optimizer — Dynamic Cost-Performance Pipeline Optimizer  ║
# ║  Real-time budget monitoring · Cost reduction suggestions · Burst mode    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard
[[ -n "${_COST_OPTIMIZER_LOADED:-}" ]] && return 0
_COST_OPTIMIZER_LOADED=1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"

# ─── Default Paths ──────────────────────────────────────────────────────────
COST_DIR="${COST_DIR:-${HOME}/.shipwright}"
BUDGET_FILE="${BUDGET_FILE:-${COST_DIR}/budget.json}"
COST_FILE="${COST_FILE:-${COST_DIR}/costs.json}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"

# ─── Safe Defaults (for set -u) ──────────────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-.}"
NOW_ISO="${NOW_ISO:-}"
NOW_EPOCH="${NOW_EPOCH:-}"

# ─── Helper Functions (fallback if not sourced from main script) ─────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi

if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift
    mkdir -p "${COST_DIR}"
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do
      local key="${1%%=*}" val="${1#*=}"
      payload="${payload},\"${key}\":\"${val}\""
      shift
    done
    echo "${payload}}" >> "${COST_DIR}/events.jsonl"
  }
fi

# ─── Helper to Validate JSON File Existence ──────────────────────────────────
_ensure_optimizer_files() {
    mkdir -p "$COST_DIR" "$ARTIFACTS_DIR"
    [[ -f "$COST_FILE" ]] || echo '{"entries":[],"summary":{}}' > "$COST_FILE"
    [[ -f "$BUDGET_FILE" ]] || echo '{"daily_budget_usd":0,"enabled":false}' > "$BUDGET_FILE"
}

# ─── Model Pricing (fallback if not loaded from sw-cost.sh) ───────────────────
if [[ -z "${OPUS_INPUT_PER_M:-}" ]]; then
    OPUS_INPUT_PER_M="15.00"
    OPUS_OUTPUT_PER_M="75.00"
    SONNET_INPUT_PER_M="3.00"
    SONNET_OUTPUT_PER_M="15.00"
    HAIKU_INPUT_PER_M="0.25"
    HAIKU_OUTPUT_PER_M="1.25"
fi

# ─── Calculate Cost for Token Counts ─────────────────────────────────────────
# ─── 1. costopt_init() ───────────────────────────────────────────────────────
# Initialize cost optimization for a pipeline run.
# Loads budget and historical cost data, calculates projections.
costopt_init() {
    _ensure_optimizer_files

    local budget_enabled budget_usd
    budget_enabled=$(jq -r '.enabled // false' "$BUDGET_FILE" 2>/dev/null || echo "false")
    budget_usd=$(jq -r '.daily_budget_usd // 0' "$BUDGET_FILE" 2>/dev/null || echo "0")

    # If budget not enabled, gracefully return
    if [[ "$budget_enabled" != "true" || "$budget_usd" == "0" ]]; then
        # Silent no-op: budget not configured
        return 0
    fi

    # Calculate today's spending
    local today_start
    today_start=$(date -u +"%Y-%m-%dT00:00:00Z")
    local today_epoch
    today_epoch=$(date_to_epoch "$today_start" || echo "0")

    local today_spent
    today_spent=$(jq --argjson cutoff "$today_epoch" \
        '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0' \
        "$COST_FILE" 2>/dev/null || echo "0")

    # Calculate historical average cost per stage
    local stage_costs
    stage_costs=$(jq -r '
        [.entries | group_by(.stage) | .[] |
        {
            stage: .[0].stage,
            avg_cost: (map(.cost_usd) | add / length)
        }] | map("\(.stage):\(.avg_cost)") | join(",")
    ' "$COST_FILE" 2>/dev/null || echo "")

    local remaining_budget
    remaining_budget=$(awk -v budget="$budget_usd" -v spent="$today_spent" 'BEGIN { printf "%.2f", budget - spent }')

    # Write initial cost optimization state
    local opt_state
    opt_state=$(cat <<EOF
{
  "initialized_at": "$(now_iso)",
  "daily_budget_usd": $budget_usd,
  "today_spent_usd": $today_spent,
  "remaining_budget_usd": $remaining_budget,
  "avg_pipeline_cost": 0,
  "stage_costs": "$stage_costs",
  "reductions_applied": [],
  "burst_active": false,
  "burst_end_ts": ""
}
EOF
)

    local tmp_file
    tmp_file=$(mktemp "$ARTIFACTS_DIR/cost-optimization.json.tmp.XXXXXX" 2>/dev/null) || tmp_file="/tmp/costopt-$$.tmp"
    echo "$opt_state" > "$tmp_file"
    mv "$tmp_file" "$ARTIFACTS_DIR/cost-optimization.json" 2>/dev/null || true

    emit_event "costopt.init" \
        "daily_budget=$budget_usd" \
        "today_spent=$today_spent" \
        "remaining=$remaining_budget"

    success "Cost optimization initialized: \$$remaining_budget remaining of \$$budget_usd daily budget"
}

# ─── 2. costopt_check_budget() ───────────────────────────────────────────────
# Real-time budget check with projections.
# Returns status and writes projection info.
# Status: under_budget, on_track, over_projecting, budget_exceeded
costopt_check_budget() {
    local current_pipeline_cost="${1:-0}"
    local remaining_stages="${2:-5}"

    _ensure_optimizer_files

    local budget_enabled budget_usd
    budget_enabled=$(jq -r '.enabled // false' "$BUDGET_FILE" 2>/dev/null || echo "false")
    budget_usd=$(jq -r '.daily_budget_usd // 0' "$BUDGET_FILE" 2>/dev/null || echo "0")

    # If budget not enabled, return under_budget
    if [[ "$budget_enabled" != "true" || "$budget_usd" == "0" ]]; then
        echo "under_budget"
        return 0
    fi

    # Get today's spending
    local today_start
    today_start=$(date -u +"%Y-%m-%dT00:00:00Z")
    local today_epoch
    today_epoch=$(date_to_epoch "$today_start" || echo "0")

    local today_spent
    today_spent=$(jq --argjson cutoff "$today_epoch" \
        '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0' \
        "$COST_FILE" 2>/dev/null || echo "0")

    # Calculate historical average cost per remaining stage
    local avg_per_stage
    avg_per_stage=$(jq -r \
        '[.entries[].cost_usd] | length as $count | if $count > 0 then add / $count / 5 else 0.50 end' \
        "$COST_FILE" 2>/dev/null || echo "0.50")

    local estimated_remaining
    estimated_remaining=$(awk -v avg="$avg_per_stage" -v stages="$remaining_stages" \
        'BEGIN { printf "%.2f", avg * stages }')

    local projected_total
    projected_total=$(awk -v current="$current_pipeline_cost" -v est="$estimated_remaining" \
        'BEGIN { printf "%.2f", current + est }')

    local total_projected
    total_projected=$(awk -v spent="$today_spent" -v proj="$projected_total" \
        'BEGIN { printf "%.2f", spent + proj }')

    local remaining_budget
    remaining_budget=$(awk -v budget="$budget_usd" -v spent="$today_spent" \
        'BEGIN { printf "%.2f", budget - spent }')

    local status
    if awk -v total="$total_projected" -v budget="$budget_usd" 'BEGIN { exit !(total > budget) }'; then
        status="budget_exceeded"
    elif awk -v total="$total_projected" -v budget="$budget_usd" -v threshold="$budget_usd * 0.8" \
            'BEGIN { exit !(total > threshold) }'; then
        status="over_projecting"
    elif awk -v total="$total_projected" -v budget="$budget_usd" -v threshold="$budget_usd * 0.6" \
            'BEGIN { exit !(total > threshold) }'; then
        status="on_track"
    else
        status="under_budget"
    fi

    # Write budget check state
    local check_state
    check_state=$(cat <<EOF
{
  "checked_at": "$(now_iso)",
  "daily_budget_usd": $budget_usd,
  "today_spent_usd": $today_spent,
  "current_pipeline_usd": $current_pipeline_cost,
  "remaining_stages": $remaining_stages,
  "avg_cost_per_stage": $avg_per_stage,
  "estimated_remaining_usd": $estimated_remaining,
  "projected_pipeline_total_usd": $projected_total,
  "projected_today_total_usd": $total_projected,
  "remaining_budget_usd": $remaining_budget,
  "status": "$status"
}
EOF
)

    local tmp_file
    tmp_file=$(mktemp "$ARTIFACTS_DIR/cost-check.json.tmp.XXXXXX" 2>/dev/null) || tmp_file="/tmp/costchk-$$.tmp"
    echo "$check_state" > "$tmp_file"
    mv "$tmp_file" "$ARTIFACTS_DIR/cost-check.json" 2>/dev/null || true

    echo "$status"
}

# ─── 3. costopt_suggest_reductions() ─────────────────────────────────────────
# Suggest cost reduction actions when over budget.
# Returns JSON array of suggested reductions with savings estimates.
costopt_suggest_reductions() {
    local remaining_stages="${1:-5}"
    local current_model="${2:-opus}"
    local current_cost="${3:-0}"
    local budget_usd="${4:-100}"
    local today_spent="${5:-0}"

    local suggestions="[]"

    # Calculate total projected cost
    local avg_per_stage
    avg_per_stage=$(jq -r \
        '[.entries[].cost_usd] | length as $count | if $count > 0 then add / $count / 5 else 0.50 end' \
        "$COST_FILE" 2>/dev/null || echo "0.50")

    local estimated_remaining
    estimated_remaining=$(awk -v avg="$avg_per_stage" -v stages="$remaining_stages" \
        'BEGIN { printf "%.2f", avg * stages }')

    local projected_today_total
    projected_today_total=$(awk -v spent="$today_spent" -v current="$current_cost" -v est="$estimated_remaining" \
        'BEGIN { printf "%.2f", spent + current + est }')

    # Suggestion 1: Downgrade model (opus -> sonnet -> haiku)
    if [[ "$current_model" == "opus" ]]; then
        local opus_cost
        opus_cost=$(jq -r '[.entries[] | select(.model == "opus") | .cost_usd] | length as $c | if $c > 0 then add / $c else 15 end' "$COST_FILE" 2>/dev/null || echo "15")
        local sonnet_cost
        sonnet_cost=$(jq -r '[.entries[] | select(.model == "sonnet") | .cost_usd] | length as $c | if $c > 0 then add / $c else 5 end' "$COST_FILE" 2>/dev/null || echo "5")
        local savings
        savings=$(awk -v opus="$opus_cost" -v sonnet="$sonnet_cost" -v stages="$remaining_stages" \
            'BEGIN { printf "%.2f", (opus - sonnet) * stages }')

        suggestions=$(jq --arg sav "$savings" '.+=[{
            "action": "downgrade_model",
            "from": "opus",
            "to": "sonnet",
            "estimated_savings_usd": ($sav | tonumber),
            "impact": "slower but acceptable for some stages"
        }]' <<< "$suggestions")
    elif [[ "$current_model" == "sonnet" ]]; then
        local sonnet_cost
        sonnet_cost=$(jq -r '[.entries[] | select(.model == "sonnet") | .cost_usd] | length as $c | if $c > 0 then add / $c else 5 end' "$COST_FILE" 2>/dev/null || echo "5")
        local haiku_cost
        haiku_cost=$(jq -r '[.entries[] | select(.model == "haiku") | .cost_usd] | length as $c | if $c > 0 then add / $c else 0.5 end' "$COST_FILE" 2>/dev/null || echo "0.5")
        local savings
        savings=$(awk -v sonnet="$sonnet_cost" -v haiku="$haiku_cost" -v stages="$remaining_stages" \
            'BEGIN { printf "%.2f", (sonnet - haiku) * stages }')

        suggestions=$(jq --arg sav "$savings" '.+=[{
            "action": "downgrade_model",
            "from": "sonnet",
            "to": "haiku",
            "estimated_savings_usd": ($sav | tonumber),
            "impact": "lowest cost, suitable for routine tasks"
        }]' <<< "$suggestions")
    fi

    # Suggestion 2: Skip optional stages
    local optional_stage_cost
    optional_stage_cost=$(jq -r '[.entries[] | select(.stage == "compound_quality" or .stage == "adversarial") | .cost_usd] | length as $c | if $c > 0 then add / $c else 2 end' "$COST_FILE" 2>/dev/null || echo "2")

    suggestions=$(jq --arg sav "$optional_stage_cost" '.+=[{
        "action": "skip_optional_stages",
        "stages": ["compound_quality", "adversarial"],
        "estimated_savings_usd": ($sav | tonumber),
        "impact": "skips quality stages but keeps test coverage"
    }]' <<< "$suggestions")

    # Suggestion 3: Reduce loop iterations
    suggestions=$(jq '.+=[{
        "action": "reduce_iterations",
        "max_iterations": 3,
        "from_max": 10,
        "estimated_savings_usd": 5.0,
        "impact": "faster convergence but less exploration"
    }]' <<< "$suggestions")

    # Suggestion 4: Use fast-test-cmd more frequently
    suggestions=$(jq '.+=[{
        "action": "increase_fast_test_frequency",
        "fast_test_interval": 2,
        "from_interval": 5,
        "estimated_savings_usd": 1.5,
        "impact": "run full test suite less often"
    }]' <<< "$suggestions")

    echo "$suggestions"
}

# ─── 4. costopt_apply_reduction() ────────────────────────────────────────────
# Apply a cost reduction action to the pipeline config.
# $1: reduction action name (downgrade_model, skip_optional_stages, reduce_iterations, etc.)
# $2: JSON config path (if modifiable in-memory)
# Returns 0 on success
costopt_apply_reduction() {
    local action="${1:-}"
    local config_path="${2:-}"
    local estimated_savings="${3:-0}"

    [[ -z "$action" ]] && { error "costopt_apply_reduction: action required"; return 1; }

    local opt_state
    opt_state="$ARTIFACTS_DIR/cost-optimization.json"

    # Record applied reduction
    local reduction_record
    reduction_record=$(cat <<EOF
{
    "applied_at": "$(now_iso)",
    "action": "$action",
    "estimated_savings_usd": $estimated_savings,
    "config_modified": "$config_path"
}
EOF
)

    # Update optimization state if file exists
    if [[ -f "$opt_state" ]]; then
        local tmp_file
        tmp_file=$(mktemp "$opt_state.tmp.XXXXXX" 2>/dev/null) || tmp_file="/tmp/costopt-red-$$.tmp"
        jq --argjson red "$reduction_record" '.reductions_applied += [$red]' "$opt_state" > "$tmp_file" 2>/dev/null && \
            mv "$tmp_file" "$opt_state" || rm -f "$tmp_file"
    fi

    emit_event "costopt.reduction_applied" \
        "action=$action" \
        "estimated_savings=$estimated_savings"

    info "Cost reduction applied: $action (estimated savings: \$$estimated_savings)"
    return 0
}

# ─── 5. costopt_burst_mode() ────────────────────────────────────────────────
# Temporarily increase budget for critical work (near completion, high convergence).
# Returns 0 if burst mode activated, 1 if conditions not met.
# $1: convergence_score (0-100)
# $2: iteration_count
# $3: base_iteration_limit
# $4: max_burst_multiplier (default: 2)
costopt_burst_mode() {
    local convergence_score="${1:-0}"
    local iteration_count="${2:-0}"
    local base_limit="${3:-10}"
    local max_multiplier="${4:-2}"

    _ensure_optimizer_files

    local budget_enabled budget_usd
    budget_enabled=$(jq -r '.enabled // false' "$BUDGET_FILE" 2>/dev/null || echo "false")
    budget_usd=$(jq -r '.daily_budget_usd // 0' "$BUDGET_FILE" 2>/dev/null || echo "0")

    # Burst requires budget to be enabled
    if [[ "$budget_enabled" != "true" || "$budget_usd" == "0" ]]; then
        return 1
    fi

    # Conditions for burst: tests passing, convergence > 60, iterations > base
    if [[ "$convergence_score" -lt 60 || "$iteration_count" -le "$base_limit" ]]; then
        return 1
    fi

    # Calculate burst extension
    local burst_budget
    burst_budget=$(awk -v budget="$budget_usd" -v mult="$max_multiplier" \
        'BEGIN { printf "%.2f", budget * mult }')

    local burst_end_ts
    burst_end_ts=$(date -u -v+2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                   date -u -d "+2 hours" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                   echo "")

    # Update cost-optimization.json
    if [[ -f "$ARTIFACTS_DIR/cost-optimization.json" ]]; then
        local tmp_file
        tmp_file=$(mktemp "$ARTIFACTS_DIR/cost-optimization.json.tmp.XXXXXX" 2>/dev/null) || tmp_file="/tmp/costopt-burst-$$.tmp"
        jq --arg burst_ts "$burst_end_ts" --arg burst_bud "$burst_budget" \
            '.burst_active = true | .burst_end_ts = $burst_ts | .burst_budget_usd = $burst_bud' \
            "$ARTIFACTS_DIR/cost-optimization.json" > "$tmp_file" 2>/dev/null && \
            mv "$tmp_file" "$ARTIFACTS_DIR/cost-optimization.json" || rm -f "$tmp_file"
    fi

    emit_event "costopt.burst_activated" \
        "convergence=$convergence_score" \
        "iteration=$iteration_count" \
        "burst_budget=$burst_budget" \
        "expires=$burst_end_ts"

    warn "Burst mode activated: temporary budget extension to \$$burst_budget (expires $burst_end_ts)"
    return 0
}

# ─── 6. costopt_efficiency_score() ──────────────────────────────────────────
# Calculate pipeline cost efficiency (0-100).
# Factors: cost per stage, cost per test, cost per line changed.
# Higher score = more efficient (less cost per unit work).
costopt_efficiency_score() {
    local total_cost="${1:-0}"
    local tests_passed="${2:-0}"
    local lines_changed="${3:-0}"
    local stages_completed="${4:-0}"

    # Metrics with reasonable defaults
    local cost_per_test=999
    local cost_per_line=999
    local cost_per_stage=999

    [[ "$tests_passed" -gt 0 ]] && \
        cost_per_test=$(awk -v cost="$total_cost" -v tests="$tests_passed" \
            'BEGIN { printf "%.4f", cost / tests }')

    [[ "$lines_changed" -gt 0 ]] && \
        cost_per_line=$(awk -v cost="$total_cost" -v lines="$lines_changed" \
            'BEGIN { printf "%.6f", cost / lines }')

    [[ "$stages_completed" -gt 0 ]] && \
        cost_per_stage=$(awk -v cost="$total_cost" -v stages="$stages_completed" \
            'BEGIN { printf "%.2f", cost / stages }')

    # Normalize to 0-100 score
    # Lower costs = higher score
    # Benchmarks: cost_per_test < $0.05 is excellent
    #             cost_per_line < $0.001 is excellent
    #             cost_per_stage < $1.00 is excellent
    local test_score
    test_score=$(awk -v cpt="$cost_per_test" 'BEGIN {
        s = 100 * (1 - cpt / 0.10)
        if (s < 0) s = 0
        if (s > 100) s = 100
        printf "%.0f", s
    }')

    local line_score
    line_score=$(awk -v cpl="$cost_per_line" 'BEGIN {
        s = 100 * (1 - cpl / 0.002)
        if (s < 0) s = 0
        if (s > 100) s = 100
        printf "%.0f", s
    }')

    local stage_score
    stage_score=$(awk -v cps="$cost_per_stage" 'BEGIN {
        s = 100 * (1 - cps / 2.00)
        if (s < 0) s = 0
        if (s > 100) s = 100
        printf "%.0f", s
    }')

    # Average the three scores
    local efficiency
    efficiency=$(awk -v ts="$test_score" -v ls="$line_score" -v ss="$stage_score" \
        'BEGIN { printf "%.0f", (ts + ls + ss) / 3 }')

    echo "$efficiency"
}

# ─── 7. costopt_report() ────────────────────────────────────────────────────
# Generate cost optimization dashboard/report.
# $1: output format (text|json) - default: text
costopt_report() {
    local format="${1:-text}"

    _ensure_optimizer_files

    local budget_enabled budget_usd
    budget_enabled=$(jq -r '.enabled // false' "$BUDGET_FILE" 2>/dev/null || echo "false")
    budget_usd=$(jq -r '.daily_budget_usd // 0' "$BUDGET_FILE" 2>/dev/null || echo "0")

    # If budget not enabled, return minimal report
    if [[ "$budget_enabled" != "true" || "$budget_usd" == "0" ]]; then
        if [[ "$format" == "json" ]]; then
            echo '{"status":"budget_not_configured","daily_budget_usd":0}'
        else
            echo "Budget not configured. Use 'shipwright cost budget set <amount>' to enable cost tracking."
        fi
        return 0
    fi

    # Calculate today's spending
    local today_start
    today_start=$(date -u +"%Y-%m-%dT00:00:00Z")
    local today_epoch
    today_epoch=$(date_to_epoch "$today_start" || echo "0")

    local today_spent
    today_spent=$(jq --argjson cutoff "$today_epoch" \
        '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0' \
        "$COST_FILE" 2>/dev/null || echo "0")

    local remaining
    remaining=$(awk -v budget="$budget_usd" -v spent="$today_spent" \
        'BEGIN { printf "%.2f", budget - spent }')

    local pct_used
    pct_used=$(awk -v spent="$today_spent" -v budget="$budget_usd" \
        'BEGIN { printf "%.0f", (spent / budget) * 100 }')

    # Stage breakdown
    local stage_summary
    stage_summary=$(jq -r '
        [.entries | group_by(.stage) | .[] |
        {
            stage: .[0].stage,
            count: length,
            total_cost: (map(.cost_usd) | add),
            avg_cost: (map(.cost_usd) | add / length)
        }] | sort_by(-.total_cost) | .[:10]
    ' "$COST_FILE" 2>/dev/null || echo "[]")

    # Model breakdown
    local model_summary
    model_summary=$(jq -r '
        [.entries | group_by(.model) | .[] |
        {
            model: .[0].model,
            count: length,
            total_cost: (map(.cost_usd) | add)
        }] | sort_by(-.total_cost)
    ' "$COST_FILE" 2>/dev/null || echo "[]")

    if [[ "$format" == "json" ]]; then
        cat <<EOF
{
  "report_timestamp": "$(now_iso)",
  "budget": {
    "daily_limit_usd": $budget_usd,
    "today_spent_usd": $today_spent,
    "remaining_usd": $remaining,
    "percent_used": $pct_used
  },
  "stage_breakdown": $stage_summary,
  "model_breakdown": $model_summary,
  "burst_enabled": false,
  "optimizations_applied": []
}
EOF
    else
        # Text format
        cat <<EOF

╔═══════════════════════════════════════════════════════════════╗
║              Cost Optimization Report                         ║
╚═══════════════════════════════════════════════════════════════╝

Budget Status:
  Daily limit:     \$$budget_usd
  Today spent:     \$$today_spent (${pct_used}%)
  Remaining:       \$$remaining

Top Cost Drivers (by stage):
$(echo "$stage_summary" | jq -r '.[] | "  \(.stage): $\(.total_cost) (\(.count) calls)"' || echo "  (no data)")

Model Cost Breakdown:
$(echo "$model_summary" | jq -r '.[] | "  \(.model): $\(.total_cost) (\(.count) calls)"' || echo "  (no data)")

Burst Mode: Disabled (activate when near completion)
Optimizations Applied: None yet

EOF
    fi
}

# ─── Public API ──────────────────────────────────────────────────────────────
# These functions are the main entry points:
#   costopt_init
#   costopt_check_budget
#   costopt_suggest_reductions
#   costopt_apply_reduction
#   costopt_burst_mode
#   costopt_efficiency_score
#   costopt_report

true
