#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright model-router — Intelligent Model Routing & Cost Optimization  ║
# ║  Route tasks to optimal Claude models based on complexity and stage        ║
# ║  Escalate on failure · Track costs · A/B test configurations              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
CYAN="${CYAN:-\033[38;2;0;212;255m}"
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"
BLUE="${BLUE:-\033[38;2;0;102;255m}"
GREEN="${GREEN:-\033[38;2;74;222;128m}"
YELLOW="${YELLOW:-\033[38;2;250;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
RESET="${RESET:-\033[0m}"

# ─── File Paths ────────────────────────────────────────────────────────────
MODEL_ROUTING_CONFIG="${HOME}/.shipwright/model-routing.json"
MODEL_USAGE_LOG="${HOME}/.shipwright/model-usage.jsonl"
AB_RESULTS_FILE="${HOME}/.shipwright/ab-results.jsonl"

# ─── Model Costs (per million tokens) ───────────────────────────────────────
HAIKU_INPUT_COST="0.80"
HAIKU_OUTPUT_COST="4.00"
SONNET_INPUT_COST="3.00"
SONNET_OUTPUT_COST="15.00"
OPUS_INPUT_COST="15.00"
OPUS_OUTPUT_COST="75.00"

# ─── Default Routing Rules ──────────────────────────────────────────────────
# Stages that default to haiku (low complexity, fast)
HAIKU_STAGES="intake|monitor"
# Stages that default to sonnet (medium complexity)
SONNET_STAGES="test|review"
# Stages that default to opus (high complexity, needs deep thinking)
OPUS_STAGES="plan|design|build|compound_quality"

# ─── Complexity Thresholds ──────────────────────────────────────────────────
COMPLEXITY_LOW=30          # Below this: use sonnet
COMPLEXITY_HIGH=80         # Above this: use opus

# ─── Ensure Config File Exists ──────────────────────────────────────────────
ensure_config() {
    mkdir -p "${HOME}/.shipwright"

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

    # Complexity-based override (applies to all stages)
    if [[ "$complexity" -lt "$COMPLEXITY_LOW" ]]; then
        model="sonnet"
    elif [[ "$complexity" -gt "$COMPLEXITY_HIGH" ]]; then
        model="opus"
    else
        # Stage-based routing for medium complexity
        if [[ "$stage" =~ $HAIKU_STAGES ]]; then
            model="haiku"
        elif [[ "$stage" =~ $SONNET_STAGES ]]; then
            model="sonnet"
        elif [[ "$stage" =~ $OPUS_STAGES ]]; then
            model="opus"
        else
            # Default to sonnet for unknown stages
            model="sonnet"
        fi
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

    if command -v jq &>/dev/null; then
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

    if ! command -v jq &>/dev/null; then
        error "jq is required for config updates"
        return 1
    fi

    # Use jq to safely update the config
    local tmp_config
    tmp_config=$(mktemp)
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

    mkdir -p "${HOME}/.shipwright"

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

    local record="{\"ts\":\"$(now_iso)\",\"stage\":\"$stage\",\"model\":\"$model\",\"input_tokens\":$input_tokens,\"output_tokens\":$output_tokens,\"cost\":$cost}"
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

    if ! command -v jq &>/dev/null; then
        error "jq is required for A/B test configuration"
        return 1
    fi

    local tmp_config
    tmp_config=$(mktemp)
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

    local record="{\"ts\":\"$(now_iso)\",\"run_id\":\"$run_id\",\"variant\":\"$variant\",\"success\":$success_status,\"cost\":$cost,\"duration_seconds\":$duration}"
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

    if ! command -v jq &>/dev/null; then
        error "jq is required to view reports"
        return 1
    fi

    # Summary stats
    local total_runs
    total_runs=$(wc -l < "$MODEL_USAGE_LOG" || echo "0")

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

    if ! command -v jq &>/dev/null; then
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

# ─── Help Text ──────────────────────────────────────────────────────────────
show_help() {
    echo -e "${BOLD}shipwright model${RESET} — Intelligent Model Routing & Optimization"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo "  ${CYAN}shipwright model${RESET} <subcommand> [options]"
    echo ""
    echo -e "${BOLD}SUBCOMMANDS${RESET}"
    echo "  ${CYAN}route${RESET} <stage> [complexity]    Route task to optimal model (returns: haiku|sonnet|opus)"
    echo "  ${CYAN}escalate${RESET} <model>              Get next tier model (haiku→sonnet→opus)"
    echo "  ${CYAN}config${RESET} [show|set <key> <val>] Show/set routing configuration"
    echo "  ${CYAN}estimate${RESET} [template] [complexity]  Estimate pipeline cost"
    echo "  ${CYAN}ab-test${RESET} [enable|disable] [pct] [variant]  Configure A/B testing"
    echo "  ${CYAN}report${RESET}                        Show model usage and cost report"
    echo "  ${CYAN}ab-results${RESET}                     Show A/B test results"
    echo "  ${CYAN}help${RESET}                          Show this help message"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo "  ${DIM}shipwright model route plan 65${RESET}        # Route 'plan' stage with 65% complexity"
    echo "  ${DIM}shipwright model escalate haiku${RESET}      # Upgrade from haiku"
    echo "  ${DIM}shipwright model config show${RESET}         # View routing rules"
    echo "  ${DIM}shipwright model estimate standard 50${RESET}  # Estimate standard pipeline cost"
    echo "  ${DIM}shipwright model ab-test enable 15 cost-optimized${RESET}  # 15% A/B test"
    echo "  ${DIM}shipwright model report${RESET}              # Show usage stats"
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
                if command -v jq &>/dev/null; then
                    local tmp_config
                    tmp_config=$(mktemp)
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
