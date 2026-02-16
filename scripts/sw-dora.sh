#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-dora.sh — DORA Metrics Dashboard with Engineering Intelligence       ║
# ║                                                                          ║
# ║  Computes Lead Time, Deploy Frequency, Change Failure Rate, MTTR,        ║
# ║  DX metrics, AI intelligence metrics, trends, and comparative analysis   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
_COMPAT="$SCRIPT_DIR/lib/compat.sh"
[[ -f "$_COMPAT" ]] && source "$_COMPAT"

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

# ─── DORA Metrics Calculation ────────────────────────────────────────────────

# Classify performance band per DORA standards
classify_band() {
    local metric="$1"
    local value="$2"

    case "$metric" in
        lead_time)
            if (( $(echo "$value <= 1" | bc -l) )); then echo "Elite"
            elif (( $(echo "$value <= 7" | bc -l) )); then echo "High"
            elif (( $(echo "$value <= 30" | bc -l) )); then echo "Medium"
            else echo "Low"; fi
            ;;
        deploy_frequency)
            if (( $(echo "$value >= 7" | bc -l) )); then echo "Elite"
            elif (( $(echo "$value >= 1" | bc -l) )); then echo "High"
            elif (( $(echo "$value >= 0.3" | bc -l) )); then echo "Medium"
            else echo "Low"; fi
            ;;
        cfr)
            if (( $(echo "$value <= 15" | bc -l) )); then echo "Elite"
            elif (( $(echo "$value <= 30" | bc -l) )); then echo "High"
            elif (( $(echo "$value <= 45" | bc -l) )); then echo "Medium"
            else echo "Low"; fi
            ;;
        mttr)
            if (( $(echo "$value <= 1" | bc -l) )); then echo "Elite"
            elif (( $(echo "$value <= 24" | bc -l) )); then echo "High"
            elif (( $(echo "$value <= 168" | bc -l) )); then echo "Medium"
            else echo "Low"; fi
            ;;
        *)
            echo "Unknown"
            ;;
    esac
}

# Determine trend arrow
trend_arrow() {
    local current="$1"
    local previous="$2"
    local metric="$3"

    # Handle division by zero
    if (( $(echo "$previous == 0" | bc -l) )); then
        echo "→"
        return
    fi

    local threshold=0.05  # 5% change threshold
    local pct_change
    pct_change=$(echo "scale=4; ($current - $previous) / $previous" | bc)

    # For metrics where lower is better (lead_time, cfr, mttr)
    case "$metric" in
        lead_time|cfr|mttr)
            if (( $(echo "$pct_change < -$threshold" | bc -l) )); then echo "↓"
            elif (( $(echo "$pct_change > $threshold" | bc -l) )); then echo "↑"
            else echo "→"; fi
            ;;
        *)
            # For metrics where higher is better (deploy_frequency)
            if (( $(echo "$pct_change > $threshold" | bc -l) )); then echo "↑"
            elif (( $(echo "$pct_change < -$threshold" | bc -l) )); then echo "↓"
            else echo "→"; fi
            ;;
    esac
}

# Calculate DORA metrics for time window
calculate_dora() {
    local window_days="${1:-7}"
    local offset_days="${2:-0}"

    local events_file="${HOME}/.shipwright/events.jsonl"
    if [[ ! -f "$events_file" ]]; then
        echo '{"deploy_freq":0,"cycle_time":0,"cfr":0,"mttr":0,"total":0}'
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        echo '{"deploy_freq":0,"cycle_time":0,"cfr":0,"mttr":0,"total":0}'
        return 0
    fi

    local now_e
    now_e=$(now_epoch)
    local window_end=$((now_e - offset_days * 86400))
    local window_start=$((window_end - window_days * 86400))

    jq -s --argjson start "$window_start" --argjson end "$window_end" '
        [.[] | select(.ts_epoch >= $start and .ts_epoch < $end)] as $events |
        [$events[] | select(.type == "pipeline.completed")] as $completed |
        ($completed | length) as $total |
        [$completed[] | select(.result == "success")] as $successes |
        [$completed[] | select(.result == "failure")] as $failures |
        ($successes | length) as $success_count |
        ($failures | length) as $failure_count |
        (if $total > 0 then ($success_count * 7 / '"$window_days"') else 0 end) as $deploy_freq |
        ([$successes[] | .duration_s] | sort |
            if length > 0 then .[length/2 | floor] else 0 end) as $cycle_time |
        (if $total > 0 then ($failure_count / $total * 100) else 0 end) as $cfr |
        ($completed | sort_by(.ts_epoch // 0) |
            [range(length) as $i |
                if .[$i].result == "failure" then
                    [.[$i+1:][] | select(.result == "success")][0] as $next |
                    if $next and $next.ts_epoch and .[$i].ts_epoch then
                        ($next.ts_epoch - .[$i].ts_epoch)
                    else null end
                else null end
            ] | map(select(. != null)) |
            if length > 0 then (add / length | floor) else 0 end
        ) as $mttr |
        {
            deploy_freq: ($deploy_freq * 100 | floor / 100),
            cycle_time: ($cycle_time / 3600),
            cfr: ($cfr * 10 | floor / 10),
            mttr: ($mttr / 3600),
            total: $total
        }
    ' "$events_file" 2>/dev/null || echo '{"deploy_freq":0,"cycle_time":0,"cfr":0,"mttr":0,"total":0}'
}

# ─── Dashboard Display ────────────────────────────────────────────────────────

show_dora_dashboard() {
    info "Shipwright DORA Metrics Dashboard"
    echo ""

    local current previous
    current=$(calculate_dora 7 0)
    previous=$(calculate_dora 7 7)

    if ! command -v jq &>/dev/null; then
        error "jq is required for dashboard display"
        exit 1
    fi

    # Extract metrics
    local curr_deploy_freq curr_cycle_time curr_cfr curr_mttr curr_total
    local prev_deploy_freq prev_cycle_time prev_cfr prev_mttr

    curr_deploy_freq=$(echo "$current" | jq -r '.deploy_freq // 0')
    curr_cycle_time=$(echo "$current" | jq -r '.cycle_time // 0')
    curr_cfr=$(echo "$current" | jq -r '.cfr // 0')
    curr_mttr=$(echo "$current" | jq -r '.mttr // 0')
    curr_total=$(echo "$current" | jq -r '.total // 0')

    prev_deploy_freq=$(echo "$previous" | jq -r '.deploy_freq // 0')
    prev_cycle_time=$(echo "$previous" | jq -r '.cycle_time // 0')
    prev_cfr=$(echo "$previous" | jq -r '.cfr // 0')
    prev_mttr=$(echo "$previous" | jq -r '.mttr // 0')

    # Trends
    local trend_df trend_ct trend_cfr trend_mttr
    trend_df=$(trend_arrow "$curr_deploy_freq" "$prev_deploy_freq" "deploy_frequency")
    trend_ct=$(trend_arrow "$curr_cycle_time" "$prev_cycle_time" "lead_time")
    trend_cfr=$(trend_arrow "$curr_cfr" "$prev_cfr" "cfr")
    trend_mttr=$(trend_arrow "$curr_mttr" "$prev_mttr" "mttr")

    # Bands
    local band_df band_ct band_cfr band_mttr
    band_df=$(classify_band "deploy_frequency" "$curr_deploy_freq")
    band_ct=$(classify_band "lead_time" "$curr_cycle_time")
    band_cfr=$(classify_band "cfr" "$curr_cfr")
    band_mttr=$(classify_band "mttr" "$curr_mttr")

    # Color-code bands
    local color_df color_ct color_cfr color_mttr
    case "$band_df" in
        Elite)  color_df="$GREEN" ;;
        High)   color_df="$CYAN" ;;
        Medium) color_df="$YELLOW" ;;
        Low)    color_df="$RED" ;;
    esac
    case "$band_ct" in
        Elite)  color_ct="$GREEN" ;;
        High)   color_ct="$CYAN" ;;
        Medium) color_ct="$YELLOW" ;;
        Low)    color_ct="$RED" ;;
    esac
    case "$band_cfr" in
        Elite)  color_cfr="$GREEN" ;;
        High)   color_cfr="$CYAN" ;;
        Medium) color_cfr="$YELLOW" ;;
        Low)    color_cfr="$RED" ;;
    esac
    case "$band_mttr" in
        Elite)  color_mttr="$GREEN" ;;
        High)   color_mttr="$CYAN" ;;
        Medium) color_mttr="$YELLOW" ;;
        Low)    color_mttr="$RED" ;;
    esac

    # Display 4 core metrics
    echo -e "${BOLD}CORE DORA METRICS${RESET} ${DIM}(Last 7 days vs previous 7 days)${RESET}"
    echo ""

    printf "  ${BOLD}Deploy Frequency${RESET}     %6.2f /week  ${color_df}${BOLD}%s${RESET}%-8s ${CYAN}%s${RESET}  (Band: ${color_df}${band_df}${RESET})\n" \
        "$curr_deploy_freq" "$trend_df" "" "[$(echo "scale=1; ($curr_deploy_freq - $prev_deploy_freq)" | bc)%]"

    printf "  ${BOLD}Lead Time${RESET}            %6.2f hours ${color_ct}${BOLD}%s${RESET}%-8s ${CYAN}%s${RESET}  (Band: ${color_ct}${band_ct}${RESET})\n" \
        "$curr_cycle_time" "$trend_ct" "" "[$(echo "scale=1; ($curr_cycle_time - $prev_cycle_time)" | bc)h]"

    printf "  ${BOLD}Change Failure Rate${RESET}  %6.1f %%     ${color_cfr}${BOLD}%s${RESET}%-8s ${CYAN}%s${RESET}  (Band: ${color_cfr}${band_cfr}${RESET})\n" \
        "$curr_cfr" "$trend_cfr" "" "[$(echo "scale=1; ($curr_cfr - $prev_cfr)" | bc)pp]"

    local mttr_hours mttr_str
    mttr_hours=$(echo "scale=1; $curr_mttr" | bc)
    if (( $(echo "$curr_mttr >= 24" | bc -l) )); then
        mttr_str=$(echo "scale=1; $curr_mttr / 24" | bc)
        mttr_str="${mttr_str} days"
    else
        mttr_str="${mttr_hours} hours"
    fi

    printf "  ${BOLD}MTTR${RESET}                  %6s        ${color_mttr}${BOLD}%s${RESET}%-8s ${CYAN}%s${RESET}  (Band: ${color_mttr}${band_mttr}${RESET})\n" \
        "$mttr_str" "$trend_mttr" "" "[prev: $(echo "scale=1; $prev_mttr" | bc)h]"

    echo ""
    success "Computed from $(printf '%d' "$curr_total") pipeline runs in the last 7 days"
}

# ─── DX Metrics Display ────────────────────────────────────────────────────────

show_dx_metrics() {
    info "Developer Experience (DX) Metrics"
    echo ""

    local events_file="${HOME}/.shipwright/events.jsonl"
    if [[ ! -f "$events_file" ]]; then
        warn "No events found. Run pipelines to generate metrics."
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        error "jq is required"
        exit 1
    fi

    # Calculate DX metrics
    local dx_metrics
    dx_metrics=$(jq -s '
        [.[] | select(.type == "pipeline.completed")] as $completed |
        [.[] | select(.type == "build.iteration")] as $iterations |
        [$completed[] | select(.result == "success")] as $successes |
        ($successes | length) as $success_count |
        ($completed | length) as $total_runs |

        # First-time pass rate
        (if $total_runs > 0 then
            ($completed | group_by(.issue_id) |
            map(if length == 1 then 1 else 0 end) | add) / $total_runs * 100
        else 0 end) as $ftp_rate |

        # Avg iterations to pass per issue
        ($iterations | map(.iteration_num) |
        if length > 0 then (add / length) else 1 end) as $avg_iterations |

        # Cost per issue
        ([$completed[] | .cost_usd] | if length > 0 then add else 0 end) as $total_cost |
        (if $total_runs > 0 then ($total_cost / $total_runs) else 0 end) as $cost_per_issue |

        {
            ftp_rate: ($ftp_rate * 10 | floor / 10),
            avg_iterations: ($avg_iterations * 100 | floor / 100),
            total_runs: $total_runs,
            cost_per_issue: ($cost_per_issue * 100 | floor / 100)
        }
    ' "$events_file" 2>/dev/null || echo '{"ftp_rate":0,"avg_iterations":0,"total_runs":0,"cost_per_issue":0}')

    local ftp_rate avg_iterations total_runs cost_per_issue
    ftp_rate=$(echo "$dx_metrics" | jq -r '.ftp_rate // 0')
    avg_iterations=$(echo "$dx_metrics" | jq -r '.avg_iterations // 0')
    total_runs=$(echo "$dx_metrics" | jq -r '.total_runs // 0')
    cost_per_issue=$(echo "$dx_metrics" | jq -r '.cost_per_issue // 0')

    printf "  ${BOLD}First-Time Pass Rate${RESET}     %6.1f %%\n" "$ftp_rate"
    printf "  ${BOLD}Avg Iterations to Pass${RESET}   %6.2f\n" "$avg_iterations"
    printf "  ${BOLD}Cost per Issue${RESET}          ${GREEN}\$${RESET}%-6.2f\n" "$cost_per_issue"
    printf "  ${BOLD}Total Pipeline Runs${RESET}      %6d\n" "$total_runs"
    echo ""
}

# ─── AI Metrics Display ────────────────────────────────────────────────────────

show_ai_metrics() {
    info "AI Performance Metrics"
    echo ""

    local events_file="${HOME}/.shipwright/events.jsonl"
    if [[ ! -f "$events_file" ]]; then
        warn "No events found. Run pipelines to generate metrics."
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        error "jq is required"
        exit 1
    fi

    # Calculate AI metrics
    local ai_metrics
    ai_metrics=$(jq -s '
        [.[] | select(.type == "intelligence.cache_hit")] as $cache_hits |
        [.[] | select(.type == "intelligence.cache_miss")] as $cache_misses |
        [.[] | select(.type == "intelligence.prediction")] as $predictions |
        [.[] | select(.result == "accurate")] as $accurate |

        ($cache_hits | length) as $hits |
        ($cache_misses | length) as $misses |
        ($hits + $misses) as $total_cache |
        (if $total_cache > 0 then ($hits / $total_cache * 100) else 0 end) as $cache_rate |

        ($accurate | length) as $accurate_count |
        ($predictions | length) as $total_predictions |
        (if $total_predictions > 0 then ($accurate_count / $total_predictions * 100) else 0 end) as $pred_accuracy |

        # Model routing efficiency (cost savings from routing optimization)
        ([.[] | select(.type == "cost.savings")] | map(.amount_usd) | add) as $total_savings |
        (if $total_savings then $total_savings else 0 end) as $savings |

        {
            cache_hit_rate: ($cache_rate * 10 | floor / 10),
            cache_total: $total_cache,
            prediction_accuracy: ($pred_accuracy * 10 | floor / 10),
            total_predictions: $total_predictions,
            model_routing_savings: ($savings * 100 | floor / 100)
        }
    ' "$events_file" 2>/dev/null || echo '{"cache_hit_rate":0,"cache_total":0,"prediction_accuracy":0,"total_predictions":0,"model_routing_savings":0}')

    local cache_rate cache_total pred_accuracy total_pred savings
    cache_rate=$(echo "$ai_metrics" | jq -r '.cache_hit_rate // 0')
    cache_total=$(echo "$ai_metrics" | jq -r '.cache_total // 0')
    pred_accuracy=$(echo "$ai_metrics" | jq -r '.prediction_accuracy // 0')
    total_pred=$(echo "$ai_metrics" | jq -r '.total_predictions // 0')
    savings=$(echo "$ai_metrics" | jq -r '.model_routing_savings // 0')

    printf "  ${BOLD}Cache Hit Rate${RESET}           %6.1f %%  (${DIM}%d total${RESET})\n" "$cache_rate" "$cache_total"
    printf "  ${BOLD}Prediction Accuracy${RESET}      %6.1f %%  (${DIM}%d predictions${RESET})\n" "$pred_accuracy" "$total_pred"
    printf "  ${BOLD}Model Routing Savings${RESET}    ${GREEN}\$${RESET}%-6.2f\n" "$savings"
    echo ""
}

# ─── Trends Display ────────────────────────────────────────────────────────────

show_trends() {
    local period="${1:-7}"

    info "Shipwright Metrics Trends (Last ${period} Days)"
    echo ""

    local events_file="${HOME}/.shipwright/events.jsonl"
    if [[ ! -f "$events_file" ]]; then
        warn "No events found. Run pipelines to generate metrics."
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        error "jq is required"
        exit 1
    fi

    # Show day-by-day trends
    local day=0
    printf "  ${BOLD}Day${RESET}  ${BOLD}Deployments${RESET}  ${BOLD}Cycle Time${RESET}  ${BOLD}CFR${RESET}  ${BOLD}MTTR${RESET}\n"
    printf "  ${DIM}─────────────────────────────────────────────${RESET}\n"

    while [[ $day -lt $period ]]; do
        local metrics
        metrics=$(calculate_dora 1 "$day")

        local deploys ct cfr mttr
        deploys=$(echo "$metrics" | jq -r '.total // 0')
        ct=$(echo "$metrics" | jq -r '.cycle_time // 0')
        cfr=$(echo "$metrics" | jq -r '.cfr // 0')
        mttr=$(echo "$metrics" | jq -r '.mttr // 0')

        local date_str
        date_str=$(date -u -v-${day}d +"%a" 2>/dev/null || date -u -d "${day} days ago" +"%a" 2>/dev/null || echo "Day")

        printf "  %-3s   %d          %.1fh         %.1f%%  %.1fh\n" \
            "$date_str" "$deploys" "$ct" "$cfr" "$mttr"

        ((day++))
    done

    echo ""
}

# ─── Comparison Display ────────────────────────────────────────────────────────

show_comparison() {
    local current_period="${1:-7}"
    local previous_period="${2:-7}"

    info "Period Comparison Analysis"
    echo ""
    printf "  ${BOLD}Current (last %d days) vs Previous (%d days)${RESET}\n" "$current_period" "$previous_period"
    echo ""

    local curr prev
    curr=$(calculate_dora "$current_period" 0)
    prev=$(calculate_dora "$previous_period" "$current_period")

    if ! command -v jq &>/dev/null; then
        error "jq is required"
        exit 1
    fi

    local curr_df curr_ct curr_cfr curr_mttr
    local prev_df prev_ct prev_cfr prev_mttr

    curr_df=$(echo "$curr" | jq -r '.deploy_freq // 0')
    curr_ct=$(echo "$curr" | jq -r '.cycle_time // 0')
    curr_cfr=$(echo "$curr" | jq -r '.cfr // 0')
    curr_mttr=$(echo "$curr" | jq -r '.mttr // 0')

    prev_df=$(echo "$prev" | jq -r '.deploy_freq // 0')
    prev_ct=$(echo "$prev" | jq -r '.cycle_time // 0')
    prev_cfr=$(echo "$prev" | jq -r '.cfr // 0')
    prev_mttr=$(echo "$prev" | jq -r '.mttr // 0')

    # Calculate percent changes
    local pct_df pct_ct pct_cfr pct_mttr
    pct_df=$(echo "scale=1; (($curr_df - $prev_df) / $prev_df * 100)" | bc 2>/dev/null || echo "0")
    pct_ct=$(echo "scale=1; (($curr_ct - $prev_ct) / $prev_ct * 100)" | bc 2>/dev/null || echo "0")
    pct_cfr=$(echo "scale=1; (($curr_cfr - $prev_cfr) / $prev_cfr * 100)" | bc 2>/dev/null || echo "0")
    pct_mttr=$(echo "scale=1; (($curr_mttr - $prev_mttr) / $prev_mttr * 100)" | bc 2>/dev/null || echo "0")

    printf "  ${BOLD}Deploy Frequency${RESET}     %6.2f  →  %6.2f /week  ${CYAN}(%+.1f%%)${RESET}\n" \
        "$prev_df" "$curr_df" "$pct_df"

    printf "  ${BOLD}Lead Time${RESET}            %6.2f  →  %6.2f hours  ${CYAN}(%+.1f%%)${RESET}\n" \
        "$prev_ct" "$curr_ct" "$pct_ct"

    printf "  ${BOLD}Change Failure Rate${RESET}  %6.1f%%  →  %6.1f%%      ${CYAN}(%+.1f pp)${RESET}\n" \
        "$prev_cfr" "$curr_cfr" "$pct_cfr"

    printf "  ${BOLD}MTTR${RESET}                  %6.1f  →  %6.1f hours  ${CYAN}(%+.1f%%)${RESET}\n" \
        "$prev_mttr" "$curr_mttr" "$pct_mttr"

    echo ""
}

# ─── Export to JSON ────────────────────────────────────────────────────────────

export_metrics() {
    local current previous
    current=$(calculate_dora 7 0)
    previous=$(calculate_dora 7 7)

    if ! command -v jq &>/dev/null; then
        error "jq is required for JSON export"
        exit 1
    fi

    # Build comprehensive metrics object
    jq -n \
        --argjson current "$current" \
        --argjson previous "$previous" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            timestamp: $timestamp,
            current_period: ($current | {
                deploy_freq: .deploy_freq,
                cycle_time: .cycle_time,
                cfr: .cfr,
                mttr: .mttr,
                total_runs: .total
            }),
            previous_period: ($previous | {
                deploy_freq: .deploy_freq,
                cycle_time: .cycle_time,
                cfr: .cfr,
                mttr: .mttr,
                total_runs: .total
            })
        }'
}

# ─── Help Display ────────────────────────────────────────────────────────────

show_help() {
    cat << EOF
${BOLD}shipwright dora${RESET} — DORA Metrics Dashboard & Engineering Intelligence

${BOLD}USAGE${RESET}
  shipwright dora <subcommand> [options]

${BOLD}SUBCOMMANDS${RESET}
  show              Display DORA dashboard (4 core metrics)
  dx                Developer Experience metrics (FTP, iterations, cost)
  ai                AI performance metrics (cache, predictions, routing savings)
  trends [days]     Trend analysis over time (default: 7 days)
  compare [c] [p]   Compare current vs previous period (default: 7 vs 7 days)
  export            Export all metrics as JSON
  help              Show this help message

${BOLD}EXAMPLES${RESET}
  ${DIM}shipwright dora show${RESET}              # Display DORA dashboard
  ${DIM}shipwright dora trends 30${RESET}         # Show 30-day trends
  ${DIM}shipwright dora compare 7 14${RESET}      # Compare last 7 days vs previous 14
  ${DIM}shipwright dora export | jq .${RESET}    # Export metrics as JSON

${BOLD}DORA BANDS${RESET} (per DORA standards)
  ${GREEN}Elite${RESET}   — Highest performance tier
  ${CYAN}High${RESET}    — Above average
  ${YELLOW}Medium${RESET}  — Average performance
  ${RED}Low${RESET}     — Below average

${BOLD}METRICS REFERENCE${RESET}
  Deploy Frequency   — Deployments per week (higher is better)
  Lead Time          — Hours from commit to production (lower is better)
  Change Failure Rate — % of deployments requiring hotfix (lower is better)
  MTTR               — Hours to restore after failure (lower is better)

EOF
}

# ─── Main Entry Point ────────────────────────────────────────────────────────

main() {
    local cmd="${1:-show}"

    case "$cmd" in
        show)
            show_dora_dashboard
            ;;
        dx)
            show_dx_metrics
            ;;
        ai)
            show_ai_metrics
            ;;
        trends)
            local days="${2:-7}"
            show_trends "$days"
            ;;
        compare)
            local curr="${2:-7}"
            local prev="${3:-7}"
            show_comparison "$curr" "$prev"
            ;;
        export)
            export_metrics
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
