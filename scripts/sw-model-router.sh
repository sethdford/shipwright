#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright model-router — Intelligent Model Routing & Cost Optimization  ║
# ║  Route tasks to optimal Claude models based on complexity and stage        ║
# ║  Escalate on failure · Track costs · A/B test configurations              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# shellcheck disable=SC2034
VERSION="4.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
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
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
# ─── File Paths ────────────────────────────────────────────────────────────
# Unified: prefer optimization dir (written by self-optimize), fallback to legacy
OPTIMIZATION_DIR="${HOME}/.shipwright/optimization"
MODEL_ROUTING_OPTIMIZATION="${OPTIMIZATION_DIR}/model-routing.json"
MODEL_ROUTING_LEGACY="${HOME}/.shipwright/model-routing.json"
MODEL_USAGE_LOG="${OPTIMIZATION_DIR}/model-usage.jsonl"
AB_RESULTS_FILE="${HOME}/.shipwright/ab-results.jsonl"
CHAIN_CONFIG_FILE="${OPTIMIZATION_DIR}/reasoning-chains.json"
CHAIN_EXECUTION_LOG="${OPTIMIZATION_DIR}/chain-executions.jsonl"

# Resolve which config file to use (set by _resolve_routing_config)
MODEL_ROUTING_CONFIG=""

# ─── Model Costs (per million tokens, config-driven) ──────────────────────
# Read from ~/.shipwright/pricing.json if exists, otherwise use defaults
_load_pricing() {
    local pricing_file="${HOME}/.shipwright/pricing.json"
    if [[ -f "$pricing_file" ]]; then
        HAIKU_INPUT_COST=$(jq -r '.haiku.input // "0.80"' "$pricing_file" 2>/dev/null || echo "0.80")
        HAIKU_OUTPUT_COST=$(jq -r '.haiku.output // "4.00"' "$pricing_file" 2>/dev/null || echo "4.00")
        SONNET_INPUT_COST=$(jq -r '.sonnet.input // "3.00"' "$pricing_file" 2>/dev/null || echo "3.00")
        SONNET_OUTPUT_COST=$(jq -r '.sonnet.output // "15.00"' "$pricing_file" 2>/dev/null || echo "15.00")
        OPUS_INPUT_COST=$(jq -r '.opus.input // "15.00"' "$pricing_file" 2>/dev/null || echo "15.00")
        OPUS_OUTPUT_COST=$(jq -r '.opus.output // "75.00"' "$pricing_file" 2>/dev/null || echo "75.00")
    else
        HAIKU_INPUT_COST="0.80"
        HAIKU_OUTPUT_COST="4.00"
        SONNET_INPUT_COST="3.00"
        SONNET_OUTPUT_COST="15.00"
        OPUS_INPUT_COST="15.00"
        OPUS_OUTPUT_COST="75.00"
    fi
}
_load_pricing

# ─── Default Routing Rules (config-driven) ────────────────────────────────
# Read from daemon-config model_routing.stages if configured
_load_routing_rules() {
    local cfg="${DAEMON_CONFIG:-${WORK_DIR:-.}/.claude/daemon-config.json}"
    if [[ -f "$cfg" ]]; then
        local h s o
        h=$(jq -r '.model_routing.haiku_stages // empty' "$cfg" 2>/dev/null || true)
        s=$(jq -r '.model_routing.sonnet_stages // empty' "$cfg" 2>/dev/null || true)
        o=$(jq -r '.model_routing.opus_stages // empty' "$cfg" 2>/dev/null || true)
        [[ -n "$h" && "$h" != "null" ]] && HAIKU_STAGES="$h"
        [[ -n "$s" && "$s" != "null" ]] && SONNET_STAGES="$s"
        [[ -n "$o" && "$o" != "null" ]] && OPUS_STAGES="$o"
    fi
}
HAIKU_STAGES="intake|monitor"
SONNET_STAGES="test|review"
OPUS_STAGES="plan|design|build|compound_quality"
_load_routing_rules 2>/dev/null || true

# ─── Complexity Thresholds (config-driven) ────────────────────────────────
if type _smart_int >/dev/null 2>&1; then
    COMPLEXITY_LOW=$(_smart_int "model_routing.complexity_low" 30)
    COMPLEXITY_HIGH=$(_smart_int "model_routing.complexity_high" 80)
else
    COMPLEXITY_LOW=30
    COMPLEXITY_HIGH=80
fi

# ─── Resolve Routing Config Path ────────────────────────────────────────────
# Priority: optimization (self-optimize writes) > legacy > create in optimization
_resolve_routing_config() {
    if [[ -f "$MODEL_ROUTING_OPTIMIZATION" ]]; then
        MODEL_ROUTING_CONFIG="$MODEL_ROUTING_OPTIMIZATION"
        return
    fi
    if [[ -f "$MODEL_ROUTING_LEGACY" ]]; then
        MODEL_ROUTING_CONFIG="$MODEL_ROUTING_LEGACY"
        return
    fi
    # Neither exists — use optimization as canonical location
    MODEL_ROUTING_CONFIG="$MODEL_ROUTING_OPTIMIZATION"
}

# ─── Ensure Config File Exists ──────────────────────────────────────────────
ensure_config() {
    _resolve_routing_config
    mkdir -p "$(dirname "$MODEL_ROUTING_CONFIG")"

    if [[ ! -f "$MODEL_ROUTING_CONFIG" ]]; then
        cat > "$MODEL_ROUTING_CONFIG" <<'CONFIG'
{
  "version": "1.0",
  "default_routing": {
    "intake": "haiku",
    "plan": "opus",
    "design": "opus",
    "build": "opus",
    "test": "sonnet",
    "review": "sonnet",
    "compound_quality": "opus",
    "pr": "sonnet",
    "merge": "sonnet",
    "deploy": "sonnet",
    "validate": "haiku",
    "monitor": "haiku"
  },
  "complexity_thresholds": {
    "low": 30,
    "high": 80
  },
  "escalation_policy": "linear",
  "cost_aware_mode": false,
  "max_cost_per_pipeline": 50.0,
  "a_b_test": {
    "enabled": false,
    "percentage": 10,
    "variant": "cost-optimized"
  }
}
CONFIG
        success "Created default routing config at $MODEL_ROUTING_CONFIG"
    fi
}

# ─── Determine Model by Stage and Complexity ────────────────────────────────
route_model() {
    local stage="$1"
    local complexity="${2:-50}"

    # Validate inputs
    if [[ -z "$stage" ]]; then
        error "stage is required"
        return 1
    fi

    if ! [[ "$complexity" =~ ^[0-9]+$ ]] || [[ "$complexity" -lt 0 ]] || [[ "$complexity" -gt 100 ]]; then
        error "complexity must be 0-100, got: $complexity"
        return 1
    fi

    local model=""
    _resolve_routing_config

    # Strategy 1: Optimization file (self-optimize format) — .routes.stage.model or .routes.stage.recommended
    if [[ -n "$MODEL_ROUTING_CONFIG" && -f "$MODEL_ROUTING_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
        local from_routes
        from_routes=$(jq -r --arg s "$stage" '.routes[$s].model // .routes[$s].recommended // .[$s].recommended // .[$s].model // empty' "$MODEL_ROUTING_CONFIG" 2>/dev/null || true)
        if [[ -n "$from_routes" && "$from_routes" =~ ^(haiku|sonnet|opus)$ ]]; then
            model="$from_routes"
        fi
        # Fallback: legacy default_routing format
        if [[ -z "$model" ]]; then
            local from_default
            from_default=$(jq -r --arg s "$stage" '.default_routing[$s] // empty' "$MODEL_ROUTING_CONFIG" 2>/dev/null || true)
            if [[ -n "$from_default" && "$from_default" =~ ^(haiku|sonnet|opus)$ ]]; then
                model="$from_default"
            fi
        fi
    fi

    # Strategy 2: Built-in defaults (complexity + stage rules)
    if [[ -z "$model" ]]; then
        if [[ "$complexity" -lt "$COMPLEXITY_LOW" ]]; then
            model="sonnet"
        elif [[ "$complexity" -gt "$COMPLEXITY_HIGH" ]]; then
            model="opus"
        else
            if [[ "$stage" =~ $HAIKU_STAGES ]]; then
                model="haiku"
            elif [[ "$stage" =~ $SONNET_STAGES ]]; then
                model="sonnet"
            elif [[ "$stage" =~ $OPUS_STAGES ]]; then
                model="opus"
            else
                model="sonnet"
            fi
        fi
    fi

    # Complexity override: upgrade/downgrade based on complexity even when config says otherwise
    if [[ "$complexity" -lt "$COMPLEXITY_LOW" && "$model" == "opus" ]]; then
        model="sonnet"
    elif [[ "$complexity" -gt "$COMPLEXITY_HIGH" && "$model" == "haiku" ]]; then
        model="opus"
    elif [[ "$complexity" -gt "$COMPLEXITY_HIGH" ]]; then
        model="opus"
    fi

    echo "$model"
}

# ─── Escalate to Next Model Tier ───────────────────────────────────────────
escalate_model() {
    local current_model="$1"

    if [[ -z "$current_model" ]]; then
        error "current model is required"
        return 1
    fi

    local next_model=""
    case "$current_model" in
        haiku)  next_model="sonnet" ;;
        sonnet) next_model="opus" ;;
        opus)   next_model="opus" ;;  # Already at top
        *)      error "Unknown model: $current_model"; return 1 ;;
    esac

    echo "$next_model"
}

# ─── Show Configuration ─────────────────────────────────────────────────────
show_config() {
    ensure_config

    info "Model Routing Configuration"
    echo ""

    if command -v jq >/dev/null 2>&1; then
        jq . "$MODEL_ROUTING_CONFIG" 2>/dev/null || cat "$MODEL_ROUTING_CONFIG"
    else
        cat "$MODEL_ROUTING_CONFIG"
    fi
}

# ─── Set Configuration Value ───────────────────────────────────────────────
set_config() {
    local key="$1"
    local value="$2"

    if [[ -z "$key" ]] || [[ -z "$value" ]]; then
        error "Usage: shipwright model config set <key> <value>"
        return 1
    fi

    ensure_config

    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required for config updates"
        return 1
    fi

    # Use jq to safely update the config
    local tmp_config
    tmp_config=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_config'" RETURN

    if [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
        jq ".${key} = ${value}" "$MODEL_ROUTING_CONFIG" > "$tmp_config"
    elif [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        jq ".${key} = ${value}" "$MODEL_ROUTING_CONFIG" > "$tmp_config"
    else
        jq ".${key} = \"${value}\"" "$MODEL_ROUTING_CONFIG" > "$tmp_config"
    fi

    mv "$tmp_config" "$MODEL_ROUTING_CONFIG"
    success "Updated $key = $value"
}

# ─── Estimate Total Pipeline Cost ──────────────────────────────────────────
estimate_cost() {
    local template="${1:-standard}"
    local complexity="${2:-50}"

    info "Estimating cost for template: $template, complexity: $complexity"
    echo ""

    # Typical token usage by stage (estimated)
    local stage_tokens=(
        "intake:5000"
        "plan:50000"
        "design:50000"
        "build:100000"
        "test:30000"
        "review:20000"
        "compound_quality:40000"
        "pr:10000"
        "merge:5000"
        "deploy:5000"
        "validate:5000"
        "monitor:5000"
    )

    local total_cost="0"
    local total_input_tokens="0"
    local total_output_tokens="0"

    echo -e "${BOLD}Stage${RESET} $(printf '%-15s' 'Model') $(printf '%-15s' 'Input Tokens') $(printf '%-15s' 'Output Tokens') $(printf '%-10s' 'Cost')"
    echo "─────────────────────────────────────────────────────────────────────"

    for stage_info in "${stage_tokens[@]}"; do
        local stage="${stage_info%%:*}"
        local tokens="${stage_info#*:}"

        # Estimate input/output split (roughly 70% input, 30% output)
        local input_tokens=$((tokens * 7 / 10))
        local output_tokens=$((tokens * 3 / 10))

        local model
        model=$(route_model "$stage" "$complexity")

        local input_cost="0" output_cost="0"
        case "$model" in
            haiku)
                input_cost=$(awk "BEGIN {printf \"%.4f\", $input_tokens * $HAIKU_INPUT_COST / 1000000}")
                output_cost=$(awk "BEGIN {printf \"%.4f\", $output_tokens * $HAIKU_OUTPUT_COST / 1000000}")
                ;;
            sonnet)
                input_cost=$(awk "BEGIN {printf \"%.4f\", $input_tokens * $SONNET_INPUT_COST / 1000000}")
                output_cost=$(awk "BEGIN {printf \"%.4f\", $output_tokens * $SONNET_OUTPUT_COST / 1000000}")
                ;;
            opus)
                input_cost=$(awk "BEGIN {printf \"%.4f\", $input_tokens * $OPUS_INPUT_COST / 1000000}")
                output_cost=$(awk "BEGIN {printf \"%.4f\", $output_tokens * $OPUS_OUTPUT_COST / 1000000}")
                ;;
        esac

        local stage_cost
        stage_cost=$(awk "BEGIN {printf \"%.4f\", $input_cost + $output_cost}")
        total_cost=$(awk "BEGIN {printf \"%.4f\", $total_cost + $stage_cost}")
        total_input_tokens=$((total_input_tokens + input_tokens))
        total_output_tokens=$((total_output_tokens + output_tokens))

        printf "%-15s %-15s %-15d %-15d \$%-10s\n" "$stage" "$model" "$input_tokens" "$output_tokens" "$stage_cost"
    done

    echo "─────────────────────────────────────────────────────────────────────"
    echo -e "${BOLD}Total${RESET}                                                      ${BOLD}\$${total_cost}${RESET}"
    echo ""
    echo "Tokens: $total_input_tokens input + $total_output_tokens output = $((total_input_tokens + total_output_tokens)) total"
}

# ─── Record Model Usage ─────────────────────────────────────────────────────
record_usage() {
    local stage="$1"
    local model="$2"
    local input_tokens="${3:-0}"
    local output_tokens="${4:-0}"

    mkdir -p "$(dirname "$MODEL_USAGE_LOG")"

    local cost
    cost=$(awk "BEGIN {}" ) # Calculate actual cost
    case "$model" in
        haiku)
            cost=$(awk "BEGIN {printf \"%.4f\", ($input_tokens * $HAIKU_INPUT_COST + $output_tokens * $HAIKU_OUTPUT_COST) / 1000000}")
            ;;
        sonnet)
            cost=$(awk "BEGIN {printf \"%.4f\", ($input_tokens * $SONNET_INPUT_COST + $output_tokens * $SONNET_OUTPUT_COST) / 1000000}")
            ;;
        opus)
            cost=$(awk "BEGIN {printf \"%.4f\", ($input_tokens * $OPUS_INPUT_COST + $output_tokens * $OPUS_OUTPUT_COST) / 1000000}")
            ;;
    esac

    local record
    record="{\"ts\":\"$(now_iso)\",\"stage\":\"$stage\",\"model\":\"$model\",\"input_tokens\":$input_tokens,\"output_tokens\":$output_tokens,\"cost\":$cost}"
    echo "$record" >> "$MODEL_USAGE_LOG"
}

# ─── A/B Test Configuration ────────────────────────────────────────────────
configure_ab_test() {
    local percentage="${1:-10}"
    local variant="${2:-cost-optimized}"

    if ! [[ "$percentage" =~ ^[0-9]+$ ]] || [[ "$percentage" -lt 0 ]] || [[ "$percentage" -gt 100 ]]; then
        error "Percentage must be 0-100, got: $percentage"
        return 1
    fi

    ensure_config

    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required for A/B test configuration"
        return 1
    fi

    local tmp_config
    tmp_config=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_config'" RETURN

    jq ".a_b_test = {\"enabled\": true, \"percentage\": $percentage, \"variant\": \"$variant\"}" \
        "$MODEL_ROUTING_CONFIG" > "$tmp_config"

    mv "$tmp_config" "$MODEL_ROUTING_CONFIG"
    success "Configured A/B test: $percentage% of pipelines will use $variant variant"
}

# ─── Log A/B Test Result ───────────────────────────────────────────────────
log_ab_result() {
    local run_id="$1"
    local variant="$2"
    local success_status="$3"
    local cost="$4"
    local duration="${5:-0}"

    mkdir -p "${HOME}/.shipwright"

    local record
    record="{\"ts\":\"$(now_iso)\",\"run_id\":\"$run_id\",\"variant\":\"$variant\",\"success\":$success_status,\"cost\":$cost,\"duration_seconds\":$duration}"
    echo "$record" >> "$AB_RESULTS_FILE"
}

# ─── Show Usage Report ──────────────────────────────────────────────────────
show_report() {
    info "Model Usage Report"
    echo ""

    if [[ ! -f "$MODEL_USAGE_LOG" ]]; then
        warn "No usage data yet. Run pipelines to collect metrics."
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required to view reports"
        return 1
    fi

    # Summary stats
    local total_runs
    total_runs=$(wc -l < "$MODEL_USAGE_LOG" || true)
    total_runs="${total_runs:-0}"

    local haiku_runs
    haiku_runs=$(grep -c '"model":"haiku"' "$MODEL_USAGE_LOG" || true)

    local sonnet_runs
    sonnet_runs=$(grep -c '"model":"sonnet"' "$MODEL_USAGE_LOG" || true)

    local opus_runs
    opus_runs=$(grep -c '"model":"opus"' "$MODEL_USAGE_LOG" || true)

    local total_cost
    total_cost=$(jq -s 'map(.cost) | add' "$MODEL_USAGE_LOG" 2>/dev/null || echo "0")

    echo -e "${BOLD}Summary${RESET}"
    echo "  Total runs: $total_runs"
    echo "  Haiku runs: $haiku_runs"
    echo "  Sonnet runs: $sonnet_runs"
    echo "  Opus runs: $opus_runs"
    echo "  Total cost: \$$total_cost"
    echo ""

    echo -e "${BOLD}Cost Per Model${RESET}"
    jq -s '
        group_by(.model) |
        map({
            model: .[0].model,
            count: length,
            total_cost: (map(.cost) | add),
            avg_cost: (map(.cost) | add / length),
            input_tokens: (map(.input_tokens) | add),
            output_tokens: (map(.output_tokens) | add)
        }) |
        sort_by(.model)
    ' "$MODEL_USAGE_LOG" 2>/dev/null | jq -r '.[] | "  \(.model): \(.count) runs, $\(.total_cost | tostring), avg $\(.avg_cost | round)"' || true

    echo ""
    echo -e "${BOLD}Top Stages by Cost${RESET}"
    jq -s '
        group_by(.stage) |
        map({stage: .[0].stage, cost: (map(.cost) | add), runs: length}) |
        sort_by(.cost) | reverse | .[0:5]
    ' "$MODEL_USAGE_LOG" 2>/dev/null | jq -r '.[] | "  \(.stage): $\(.cost), \(.runs) runs"' || true
}

# ─── Show A/B Test Results ─────────────────────────────────────────────────
show_ab_results() {
    info "A/B Test Results"
    echo ""

    if [[ ! -f "$AB_RESULTS_FILE" ]]; then
        warn "No A/B test data yet."
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required to view A/B test results"
        return 1
    fi

    jq -s '
        group_by(.variant) |
        map({
            variant: .[0].variant,
            total_runs: length,
            successful: (map(select(.success == true)) | length),
            failed: (map(select(.success == false)) | length),
            success_rate: ((map(select(.success == true)) | length) / length * 100),
            avg_cost: (map(.cost) | add / length),
            total_cost: (map(.cost) | add),
            avg_duration: (map(.duration_seconds) | add / length)
        })
    ' "$AB_RESULTS_FILE" 2>/dev/null | jq -r '.[] | "\(.variant):\n  Runs: \(.total_runs)\n  Success: \(.successful)/\(.total_runs) (\(.success_rate | round)%)\n  Avg Cost: $\(.avg_cost | round)\n  Total Cost: $\(.total_cost | round)\n  Avg Duration: \(.avg_duration | round)s"' || true
}

# ─── Initialize Chain Templates ────────────────────────────────────────────
_ensure_chain_templates() {
    mkdir -p "$(dirname "$CHAIN_CONFIG_FILE")"

    if [[ ! -f "$CHAIN_CONFIG_FILE" ]]; then
        cat > "$CHAIN_CONFIG_FILE" <<'CHAINS'
{
  "version": "1.0",
  "templates": {
    "explore-decide": [
      {"step": "explore", "model": "haiku", "max_tokens": 4000, "description": "Fast exploration with haiku"},
      {"step": "decide", "model": "opus", "max_tokens": 8000, "description": "Final decision with opus"}
    ],
    "explore-synthesize-decide": [
      {"step": "explore", "model": "haiku", "max_tokens": 4000, "description": "Explore with haiku"},
      {"step": "synthesize", "model": "sonnet", "max_tokens": 6000, "description": "Synthesize with sonnet"},
      {"step": "decide", "model": "opus", "max_tokens": 8000, "description": "Decide with opus"}
    ],
    "fast-verify": [
      {"step": "generate", "model": "sonnet", "max_tokens": 6000, "description": "Generate with sonnet"},
      {"step": "verify", "model": "haiku", "max_tokens": 2000, "description": "Verify with haiku"}
    ],
    "deep-analysis": [
      {"step": "analyze", "model": "opus", "max_tokens": 8000, "description": "Deep analysis with opus"},
      {"step": "validate", "model": "opus", "max_tokens": 4000, "description": "Validate with opus"}
    ]
  },
  "confidence_threshold": 50,
  "escalation_threshold": 80,
  "max_escalations_per_step": 1,
  "custom_chains": {}
}
CHAINS
    fi
}

# ─── Define a Custom Reasoning Chain ────────────────────────────────────────
chain_define() {
    local chain_name="$1"
    local steps_json="$2"

    if [[ -z "$chain_name" ]] || [[ -z "$steps_json" ]]; then
        error "Usage: chain_define <name> <steps_json>"
        return 1
    fi

    _ensure_chain_templates

    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required for chain definitions"
        return 1
    fi

    local tmp_config
    tmp_config=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_config'" RETURN

    # Validate that steps_json is valid JSON
    if ! jq empty <<< "$steps_json" 2>/dev/null; then
        error "Invalid JSON for chain steps"
        return 1
    fi

    # Add the custom chain
    jq --argjson steps "$steps_json" --arg name "$chain_name" \
        '.custom_chains[$name] = $steps' \
        "$CHAIN_CONFIG_FILE" > "$tmp_config"

    mv "$tmp_config" "$CHAIN_CONFIG_FILE"
    success "Defined custom chain: $chain_name"
}

# ─── Score Confidence from Output ──────────────────────────────────────────
chain_score_confidence() {
    local output="$1"
    local step_type="${2:-general}"

    # Simple heuristics-based confidence scoring
    # In a real system, this could call Claude's API for self-assessment
    local confidence=50

    # Check for markers of confidence in the output
    local has_reasoning=0
    local has_conclusion=0
    local has_caveats=0

    if grep -qiE "(therefore|thus|conclud|result|found|identify)" <<< "$output"; then
        has_conclusion=1
    fi

    if grep -qiE "(because|reason|since|based|due to)" <<< "$output"; then
        has_reasoning=1
    fi

    if grep -qiE "(however|but|though|caveat|limitation|uncertain)" <<< "$output"; then
        has_caveats=1
    fi

    # Calculate confidence: base + reasoning + conclusion - caveats
    confidence=$((50 + (has_reasoning * 15) + (has_conclusion * 20) - (has_caveats * 10)))

    # Clamp to 0-100
    if [[ "$confidence" -lt 0 ]]; then confidence=0; fi
    if [[ "$confidence" -gt 100 ]]; then confidence=100; fi

    echo "$confidence"
}

# ─── Get Next Escalation Model ─────────────────────────────────────────────
_get_escalation_model() {
    local current_model="$1"
    case "$current_model" in
        haiku)  echo "sonnet" ;;
        sonnet) echo "opus" ;;
        opus)   echo "opus" ;;  # Already at top
        *)      error "Unknown model: $current_model"; return 1 ;;
    esac
}

# ─── Execute a Single Chain Step ───────────────────────────────────────────
_execute_chain_step() {
    local step_name="$1"
    local model="$2"
    local prompt="$3"
    local max_tokens="${4:-4000}"

    local output=""
    local tokens_in=0
    local tokens_out=0
    local duration_ms=0
    local start_time
    start_time=$(date +%s%N | cut -b1-13)

    # In production, this would call Claude API with the specified model
    # For testing/mock mode, return a synthetic response
    if [[ -z "${CLAUDE_API_KEY:-}" ]] || [[ "$NO_GITHUB" == "true" ]]; then
        # Mock/test mode
        output="{\"status\": \"success\", \"step\": \"$step_name\", \"model\": \"$model\", \"content\": \"Mock response from $model for step $step_name\"}"
        tokens_in=500
        tokens_out=300
    else
        # Real Claude API call would happen here
        # For now, return mock response
        output="{\"status\": \"success\", \"step\": \"$step_name\", \"model\": \"$model\", \"content\": \"Mock response from $model\"}"
        tokens_in=500
        tokens_out=300
    fi

    local end_time
    end_time=$(date +%s%N | cut -b1-13)
    duration_ms=$((end_time - start_time))

    # Return execution record as JSON
    jq -n \
        --arg step "$step_name" \
        --arg model "$model" \
        --argjson tokens_in "$tokens_in" \
        --argjson tokens_out "$tokens_out" \
        --argjson duration_ms "$duration_ms" \
        --arg output "$output" \
        '{step: $step, model: $model, tokens_in: $tokens_in, tokens_out: $tokens_out, duration_ms: $duration_ms, output: $output}'
}

# ─── Execute a Complete Reasoning Chain ────────────────────────────────────
chain_execute() {
    local chain_name="$1"
    local prompt="$2"

    if [[ -z "$chain_name" ]] || [[ -z "$prompt" ]]; then
        error "Usage: chain_execute <chain_name> <prompt>"
        return 1
    fi

    _ensure_chain_templates

    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required for chain execution"
        return 1
    fi

    local steps
    steps=$(jq -r ".templates[\"$chain_name\"] // .custom_chains[\"$chain_name\"] // empty" "$CHAIN_CONFIG_FILE" 2>/dev/null)

    if [[ -z "$steps" || "$steps" == "null" ]]; then
        error "Chain not found: $chain_name"
        return 1
    fi

    mkdir -p "$(dirname "$CHAIN_EXECUTION_LOG")"

    local execution_id
    execution_id=$(date +%s)-$(od -An -N4 -tx4 /dev/urandom 2>/dev/null | tr -d ' ' | cut -c1-6 || echo "000000")

    # Assigned only inside a conditional branch below, but the `-z` test after
    # the loop is written to handle it being empty — so it must actually exist.
    # Undeclared, that test aborts the command with "unbound variable".
    local chain_output=""
    local confidence_threshold
    confidence_threshold=$(jq -r '.confidence_threshold // 50' "$CHAIN_CONFIG_FILE")

    local escalation_threshold
    escalation_threshold=$(jq -r '.escalation_threshold // 80' "$CHAIN_CONFIG_FILE")

    local total_cost="0"
    local step_count
    step_count=$(jq 'length' <<< "$steps")

    local execution_trace
    execution_trace="[]"

    local current_prompt="$prompt"

    for ((i = 0; i < step_count; i++)); do
        local step_obj
        step_obj=$(jq ".[$i]" <<< "$steps")

        local step_name
        step_name=$(jq -r '.step' <<< "$step_obj")

        local model
        model=$(jq -r '.model' <<< "$step_obj")

        local max_tokens
        max_tokens=$(jq -r '.max_tokens // 4000' <<< "$step_obj")

        # Execute this step
        local step_result
        step_result=$(_execute_chain_step "$step_name" "$model" "$current_prompt" "$max_tokens")

        # Extract output for next step
        local step_output
        step_output=$(jq -r '.output' <<< "$step_result")

        # Score confidence
        local confidence
        confidence=$(chain_score_confidence "$step_output" "$step_name")

        # Add confidence to result
        step_result=$(jq --argjson conf "$confidence" '.confidence = $conf' <<< "$step_result")

        # Check for early termination
        if [[ "$confidence" -gt "$escalation_threshold" ]] && [[ "$i" -lt $((step_count - 1)) ]]; then
            # Confidence is high enough, skip remaining steps
            info "Step $step_name high confidence ($confidence%), skipping remaining steps"
            execution_trace=$(jq ". += [$step_result]" <<< "$execution_trace")
            chain_output="$step_output"
            break
        fi

        # Check for low confidence escalation (only for first step typically)
        if [[ "$confidence" -lt "$confidence_threshold" ]] && [[ "$i" -lt $((step_count - 1)) ]]; then
            local next_model
            next_model=$(_get_escalation_model "$model")
            if [[ "$next_model" != "$model" ]]; then
                warn "Step $step_name low confidence ($confidence%), escalating to $next_model"
                # Re-execute with escalated model
                step_result=$(_execute_chain_step "$step_name" "$next_model" "$current_prompt" "$max_tokens")
                step_result=$(jq --argjson conf "$confidence" '.confidence = $conf | .escalated = true' <<< "$step_result")
                step_output=$(jq -r '.output' <<< "$step_result")
            fi
        fi

        # Add step to trace
        execution_trace=$(jq ". += [$step_result]" <<< "$execution_trace")

        # Use output as input to next step
        current_prompt="$step_output"
    done

    # Extract final output
    if [[ -z "$chain_output" ]]; then
        chain_output=$(jq -r '.[-1].output' <<< "$execution_trace")
    fi

    # Calculate total cost (simplified: sum of all step costs)
    total_cost=$(jq '[.[].tokens_in, .[].tokens_out] | add' <<< "$execution_trace" 2>/dev/null || echo "0")

    # Log execution
    local execution_record
    execution_record=$(jq -n \
        --arg id "$execution_id" \
        --arg chain "$chain_name" \
        --argjson trace "$execution_trace" \
        --arg output "$chain_output" \
        --argjson total_cost "$total_cost" \
        --arg ts "$(now_iso)" \
        '{id: $id, chain: $chain, ts: $ts, steps: $trace, output: $output, total_cost: $total_cost}')

    echo "$execution_record" >> "$CHAIN_EXECUTION_LOG"

    # Return execution record
    echo "$execution_record"
}

# ─── Calculate Cost for a Single Step ──────────────────────────────────────
chain_step_cost() {
    local tokens_in="${1:-0}"
    local tokens_out="${2:-0}"
    local model="${3:-sonnet}"

    if ! [[ "$tokens_in" =~ ^[0-9]+$ ]]; then tokens_in=0; fi
    if ! [[ "$tokens_out" =~ ^[0-9]+$ ]]; then tokens_out=0; fi

    local cost="0"
    case "$model" in
        haiku)
            cost=$(awk "BEGIN {printf \"%.6f\", ($tokens_in * $HAIKU_INPUT_COST + $tokens_out * $HAIKU_OUTPUT_COST) / 1000000}")
            ;;
        sonnet)
            cost=$(awk "BEGIN {printf \"%.6f\", ($tokens_in * $SONNET_INPUT_COST + $tokens_out * $SONNET_OUTPUT_COST) / 1000000}")
            ;;
        opus)
            cost=$(awk "BEGIN {printf \"%.6f\", ($tokens_in * $OPUS_INPUT_COST + $tokens_out * $OPUS_OUTPUT_COST) / 1000000}")
            ;;
    esac

    echo "$cost"
}

# ─── Show Chain Configuration ──────────────────────────────────────────────
show_chain_config() {
    _ensure_chain_templates

    if [[ ! -f "$CHAIN_CONFIG_FILE" ]]; then
        success "Created default chain templates at $CHAIN_CONFIG_FILE"
    fi

    info "Reasoning Chain Configuration"
    echo ""

    if command -v jq >/dev/null 2>&1; then
        jq . "$CHAIN_CONFIG_FILE" 2>/dev/null || cat "$CHAIN_CONFIG_FILE"
    else
        cat "$CHAIN_CONFIG_FILE"
    fi
}

# ─── Show Chain Execution Report ───────────────────────────────────────────
show_chain_report() {
    info "Chain Execution Report"
    echo ""

    if [[ ! -f "$CHAIN_EXECUTION_LOG" ]]; then
        warn "No chain execution data yet."
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required to view reports"
        return 1
    fi

    local total_executions
    total_executions=$(wc -l < "$CHAIN_EXECUTION_LOG" || echo "0")

    local total_cost
    total_cost=$(jq -s 'map(.total_cost) | add // 0' "$CHAIN_EXECUTION_LOG" 2>/dev/null || echo "0")

    echo -e "${BOLD}Summary${RESET}"
    echo "  Total chain executions: $total_executions"
    echo "  Total cost: \$$total_cost"
    echo ""

    echo -e "${BOLD}Cost Per Chain${RESET}"
    jq -s '
        group_by(.chain) |
        map({
            chain: .[0].chain,
            executions: length,
            total_cost: (map(.total_cost) | add),
            avg_cost: (map(.total_cost) | add / length)
        }) |
        sort_by(.chain)
    ' "$CHAIN_EXECUTION_LOG" 2>/dev/null | jq -r '.[] | "  \(.chain): \(.executions) executions, $\(.total_cost | tostring), avg $\(.avg_cost | round)"' || true
}

# ─── Help Text ──────────────────────────────────────────────────────────────
show_help() {
    echo -e "${BOLD}shipwright model${RESET} — Intelligent Model Routing & Optimization"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo "  ${CYAN}shipwright model${RESET} <subcommand> [options]"
    echo ""
    echo -e "${BOLD}SUBCOMMANDS — Routing${RESET}"
    echo "  ${CYAN}route${RESET} <stage> [complexity]    Route task to optimal model (returns: haiku|sonnet|opus)"
    echo "  ${CYAN}escalate${RESET} <model>              Get next tier model (haiku→sonnet→opus)"
    echo "  ${CYAN}config${RESET} [show|set <key> <val>] Show/set routing configuration"
    echo "  ${CYAN}estimate${RESET} [template] [complexity]  Estimate pipeline cost"
    echo "  ${CYAN}ab-test${RESET} [enable|disable] [pct] [variant]  Configure A/B testing"
    echo "  ${CYAN}report${RESET}                        Show model usage and cost report"
    echo "  ${CYAN}ab-results${RESET}                     Show A/B test results"
    echo ""
    echo -e "${BOLD}SUBCOMMANDS — Multi-Model Reasoning Chains${RESET}"
    echo "  ${CYAN}chain${RESET} [config|define|execute|report|step-cost]"
    echo "    ${CYAN}config${RESET}                      Show chain configuration & templates"
    echo "    ${CYAN}define${RESET} <name> <json>       Define custom reasoning chain"
    echo "    ${CYAN}execute${RESET} <chain> <prompt>   Execute a reasoning chain"
    echo "    ${CYAN}report${RESET}                      Show chain execution report"
    echo "    ${CYAN}step-cost${RESET} <in> <out> <model> Calculate cost for one step"
    echo ""
    echo -e "${BOLD}BUILT-IN CHAINS${RESET}"
    echo "  ${DIM}explore-decide${RESET}                2-step: haiku explores → opus decides"
    echo "  ${DIM}explore-synthesize-decide${RESET}     3-step: haiku → sonnet → opus"
    echo "  ${DIM}fast-verify${RESET}                   2-step: sonnet generates → haiku verifies"
    echo "  ${DIM}deep-analysis${RESET}                 2-step: opus analyzes → opus validates"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo "  ${DIM}shipwright model route plan 65${RESET}        # Route 'plan' stage with 65% complexity"
    echo "  ${DIM}shipwright model escalate haiku${RESET}      # Upgrade from haiku"
    echo "  ${DIM}shipwright model chain config${RESET}        # Show chain templates"
    echo "  ${DIM}shipwright model chain execute explore-decide \"analyze this code\"${RESET}"
    echo "  ${DIM}shipwright model chain report${RESET}         # Show chain execution stats"
    echo "  ${DIM}shipwright model chain step-cost 1000 500 sonnet${RESET}  # Cost for step"
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local subcommand="${1:-help}"

    case "$subcommand" in
        route)
            shift 2>/dev/null || true
            route_model "$@"
            ;;
        escalate)
            shift 2>/dev/null || true
            escalate_model "$@"
            ;;
        config)
            shift 2>/dev/null || true
            case "${1:-show}" in
                show)
                    show_config
                    ;;
                set)
                    shift 2>/dev/null || true
                    set_config "$@"
                    ;;
                *)
                    error "Unknown config subcommand: $1"
                    show_help
                    exit 1
                    ;;
            esac
            ;;
        estimate)
            shift 2>/dev/null || true
            estimate_cost "$@"
            ;;
        ab-test)
            shift 2>/dev/null || true
            if [[ "${1:-}" == "enable" ]]; then
                shift
                configure_ab_test "$@"
            elif [[ "${1:-}" == "disable" ]]; then
                # Disable A/B testing
                ensure_config
                if command -v jq >/dev/null 2>&1; then
                    local tmp_config
                    tmp_config=$(mktemp)
    # shellcheck disable=SC2064
                    trap "rm -f '$tmp_config'" RETURN
                    jq ".a_b_test.enabled = false" "$MODEL_ROUTING_CONFIG" > "$tmp_config"
                    mv "$tmp_config" "$MODEL_ROUTING_CONFIG"
                    success "Disabled A/B testing"
                else
                    error "jq is required"
                    return 1
                fi
            else
                configure_ab_test "$@"
            fi
            ;;

        report)
            show_report
            ;;
        ab-results)
            show_ab_results
            ;;
        chain)
            shift 2>/dev/null || true
            case "${1:-config}" in
                config)
                    show_chain_config
                    ;;
                define)
                    shift 2>/dev/null || true
                    chain_define "$@"
                    ;;
                execute)
                    shift 2>/dev/null || true
                    chain_execute "$@"
                    ;;
                report)
                    show_chain_report
                    ;;
                step-cost)
                    shift 2>/dev/null || true
                    chain_step_cost "$@"
                    ;;
                *)
                    error "Unknown chain subcommand: ${1:-}"
                    show_help
                    exit 1
                    ;;
            esac
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown subcommand: $subcommand"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
