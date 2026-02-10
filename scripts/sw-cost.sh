#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost — Token Usage & Cost Intelligence                            ║
# ║  Tracks spending · Enforces budgets · Stage breakdowns · Trend analysis ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.7.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 3600 ]]; then
        printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%ds" "$secs"
    fi
}

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

emit_event() {
    local event_type="$1"
    shift
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            val="${val//\"/\\\"}"
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Cost Storage ──────────────────────────────────────────────────────────
COST_DIR="${HOME}/.shipwright"
COST_FILE="${COST_DIR}/costs.json"
BUDGET_FILE="${COST_DIR}/budget.json"

ensure_cost_dir() {
    mkdir -p "$COST_DIR"
    [[ -f "$COST_FILE" ]] || echo '{"entries":[],"summary":{}}' > "$COST_FILE"
    [[ -f "$BUDGET_FILE" ]] || echo '{"daily_budget_usd":0,"enabled":false}' > "$BUDGET_FILE"
}

# ─── Model Pricing (USD per million tokens) ────────────────────────────────
# Pricing as of 2025
OPUS_INPUT_PER_M=15.00
OPUS_OUTPUT_PER_M=75.00
SONNET_INPUT_PER_M=3.00
SONNET_OUTPUT_PER_M=15.00
HAIKU_INPUT_PER_M=0.25
HAIKU_OUTPUT_PER_M=1.25

# cost_calculate <input_tokens> <output_tokens> <model>
# Returns the cost in USD (floating point)
cost_calculate() {
    local input_tokens="${1:-0}"
    local output_tokens="${2:-0}"
    local model="${3:-sonnet}"

    local input_rate output_rate
    case "$model" in
        opus|claude-opus-4*)
            input_rate="$OPUS_INPUT_PER_M"
            output_rate="$OPUS_OUTPUT_PER_M"
            ;;
        sonnet|claude-sonnet-4*)
            input_rate="$SONNET_INPUT_PER_M"
            output_rate="$SONNET_OUTPUT_PER_M"
            ;;
        haiku|claude-haiku-4*)
            input_rate="$HAIKU_INPUT_PER_M"
            output_rate="$HAIKU_OUTPUT_PER_M"
            ;;
        *)
            # Default to sonnet pricing for unknown models
            input_rate="$SONNET_INPUT_PER_M"
            output_rate="$SONNET_OUTPUT_PER_M"
            ;;
    esac

    awk -v it="$input_tokens" -v ot="$output_tokens" \
        -v ir="$input_rate" -v or_="$output_rate" \
        'BEGIN { printf "%.4f", (it / 1000000.0 * ir) + (ot / 1000000.0 * or_) }'
}

# cost_record <input_tokens> <output_tokens> <model> <stage> [issue]
# Records a cost entry to the cost file and events log.
cost_record() {
    local input_tokens="${1:-0}"
    local output_tokens="${2:-0}"
    local model="${3:-sonnet}"
    local stage="${4:-unknown}"
    local issue="${5:-}"

    ensure_cost_dir

    local cost_usd
    cost_usd=$(cost_calculate "$input_tokens" "$output_tokens" "$model")

    local tmp_file
    tmp_file=$(mktemp)
    jq --argjson input "$input_tokens" \
       --argjson output "$output_tokens" \
       --arg model "$model" \
       --arg stage "$stage" \
       --arg issue "$issue" \
       --arg cost "$cost_usd" \
       --arg ts "$(now_iso)" \
       --argjson epoch "$(now_epoch)" \
       '.entries += [{
           input_tokens: $input,
           output_tokens: $output,
           model: $model,
           stage: $stage,
           issue: $issue,
           cost_usd: ($cost | tonumber),
           ts: $ts,
           ts_epoch: $epoch
       }] | .entries = (.entries | .[-1000:])' \
       "$COST_FILE" > "$tmp_file" && mv "$tmp_file" "$COST_FILE"

    emit_event "cost.record" \
        "input_tokens=${input_tokens}" \
        "output_tokens=${output_tokens}" \
        "model=${model}" \
        "stage=${stage}" \
        "cost_usd=${cost_usd}"
}

# cost_check_budget [estimated_cost_usd]
# Checks if daily budget would be exceeded. Returns 0=ok, 1=warning, 2=blocked.
cost_check_budget() {
    local estimated="${1:-0}"

    ensure_cost_dir

    local budget_enabled budget_usd
    budget_enabled=$(jq -r '.enabled' "$BUDGET_FILE" 2>/dev/null || echo "false")
    budget_usd=$(jq -r '.daily_budget_usd' "$BUDGET_FILE" 2>/dev/null || echo "0")

    if [[ "$budget_enabled" != "true" || "$budget_usd" == "0" ]]; then
        return 0
    fi

    # Calculate today's spending
    local today_start
    today_start=$(date -u +"%Y-%m-%dT00:00:00Z")
    local today_epoch
    today_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$today_start" +%s 2>/dev/null || date -u -d "$today_start" +%s 2>/dev/null || echo "0")

    local today_spent
    today_spent=$(jq --argjson cutoff "$today_epoch" \
        '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0' \
        "$COST_FILE" 2>/dev/null || echo "0")

    local projected
    projected=$(awk -v spent="$today_spent" -v est="$estimated" 'BEGIN { printf "%.4f", spent + est }')

    local pct_used
    pct_used=$(awk -v spent="$today_spent" -v budget="$budget_usd" 'BEGIN { printf "%.0f", (spent / budget) * 100 }')

    if awk -v proj="$projected" -v budget="$budget_usd" 'BEGIN { exit !(proj > budget) }'; then
        error "Budget exceeded! Today: \$${today_spent} + estimated \$${estimated} > \$${budget_usd} daily limit"
        emit_event "cost.budget_exceeded" "today_spent=${today_spent}" "estimated=${estimated}" "budget=${budget_usd}"
        return 2
    fi

    if [[ "${pct_used}" -ge 80 ]]; then
        warn "Budget warning: ${pct_used}% used (\$${today_spent} / \$${budget_usd})"
        emit_event "cost.budget_warning" "pct_used=${pct_used}" "today_spent=${today_spent}" "budget=${budget_usd}"
        return 1
    fi

    return 0
}

# cost_remaining_budget
# Returns remaining daily budget as a plain number (for daemon auto-scale consumption)
# Outputs "unlimited" if budget is not enabled

cost_remaining_budget() {
    ensure_cost_dir

    local budget_enabled budget_usd
    budget_enabled=$(jq -r '.enabled' "$BUDGET_FILE" 2>/dev/null || echo "false")
    budget_usd=$(jq -r '.daily_budget_usd' "$BUDGET_FILE" 2>/dev/null || echo "0")

    if [[ "$budget_enabled" != "true" || "$budget_usd" == "0" ]]; then
        echo "unlimited"
        return 0
    fi

    # Calculate today's spending (same pattern as cost_check_budget)
    local today_start
    today_start=$(date -u +"%Y-%m-%dT00:00:00Z")
    local today_epoch
    today_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$today_start" +%s 2>/dev/null || date -u -d "$today_start" +%s 2>/dev/null || echo "0")

    local today_spent
    today_spent=$(jq --argjson cutoff "$today_epoch" \
        '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0' \
        "$COST_FILE" 2>/dev/null || echo "0")

    # Validate numeric values
    if [[ ! "$today_spent" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        today_spent="0"
    fi
    if [[ ! "$budget_usd" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "unlimited"
        return 0
    fi

    # Calculate remaining
    local remaining
    remaining=$(awk -v budget="$budget_usd" -v spent="$today_spent" 'BEGIN { printf "%.2f", budget - spent }')

    echo "$remaining"
}

# ─── Dashboard ─────────────────────────────────────────────────────────────

cost_dashboard() {
    local period_days=7
    local json_output=false
    local by_stage=false
    local by_issue=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --period)  period_days="${2:-7}"; shift 2 ;;
            --period=*) period_days="${1#--period=}"; shift ;;
            --json)    json_output=true; shift ;;
            --by-stage) by_stage=true; shift ;;
            --by-issue) by_issue=true; shift ;;
            *)         shift ;;
        esac
    done

    ensure_cost_dir

    if [[ ! -f "$COST_FILE" ]]; then
        warn "No cost data found."
        return 0
    fi

    local cutoff_epoch
    cutoff_epoch=$(( $(now_epoch) - (period_days * 86400) ))

    # Filter entries within period
    local period_entries
    period_entries=$(jq --argjson cutoff "$cutoff_epoch" \
        '[.entries[] | select(.ts_epoch >= $cutoff)]' \
        "$COST_FILE" 2>/dev/null || echo "[]")

    local entry_count
    entry_count=$(echo "$period_entries" | jq 'length')

    if [[ "$entry_count" -eq 0 ]]; then
        warn "No cost entries in the last ${period_days} day(s)."
        return 0
    fi

    # Aggregate stats
    local total_cost avg_cost max_cost total_input total_output
    total_cost=$(echo "$period_entries" | jq '[.[].cost_usd] | add // 0 | . * 100 | round / 100')
    avg_cost=$(echo "$period_entries" | jq '[.[].cost_usd] | if length > 0 then add / length else 0 end | . * 100 | round / 100')
    max_cost=$(echo "$period_entries" | jq '[.[].cost_usd] | max // 0 | . * 100 | round / 100')
    total_input=$(echo "$period_entries" | jq '[.[].input_tokens] | add // 0')
    total_output=$(echo "$period_entries" | jq '[.[].output_tokens] | add // 0')

    # Stage breakdown
    local stage_breakdown
    stage_breakdown=$(echo "$period_entries" | jq '
        group_by(.stage) | map({
            stage: .[0].stage,
            cost: ([.[].cost_usd] | add // 0 | . * 100 | round / 100),
            count: length
        }) | sort_by(-.cost)')

    # Issue breakdown
    local issue_breakdown
    issue_breakdown=$(echo "$period_entries" | jq '
        [.[] | select(.issue != "")] | group_by(.issue) | map({
            issue: .[0].issue,
            cost: ([.[].cost_usd] | add // 0 | . * 100 | round / 100),
            count: length
        }) | sort_by(-.cost) | .[:10]')

    # Cost trend (compare first half vs second half of period)
    local half_epoch
    half_epoch=$(( cutoff_epoch + (period_days * 86400 / 2) ))
    local first_half_cost second_half_cost trend
    first_half_cost=$(echo "$period_entries" | jq --argjson mid "$half_epoch" \
        '[.[] | select(.ts_epoch < $mid) | .cost_usd] | add // 0')
    second_half_cost=$(echo "$period_entries" | jq --argjson mid "$half_epoch" \
        '[.[] | select(.ts_epoch >= $mid) | .cost_usd] | add // 0')

    if awk -v f="$first_half_cost" -v s="$second_half_cost" 'BEGIN { exit !(f > 0) }' 2>/dev/null; then
        local change_pct
        change_pct=$(awk -v f="$first_half_cost" -v s="$second_half_cost" \
            'BEGIN { printf "%.0f", ((s - f) / f) * 100 }')
        if [[ "$change_pct" -gt 10 ]]; then
            trend="↑ ${change_pct}% (increasing)"
        elif [[ "$change_pct" -lt -10 ]]; then
            trend="↓ ${change_pct#-}% (decreasing)"
        else
            trend="→ stable"
        fi
    else
        trend="→ insufficient data"
    fi

    # Budget info
    local budget_enabled budget_usd today_spent
    budget_enabled=$(jq -r '.enabled' "$BUDGET_FILE" 2>/dev/null || echo "false")
    budget_usd=$(jq -r '.daily_budget_usd' "$BUDGET_FILE" 2>/dev/null || echo "0")

    local today_start_epoch
    today_start_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$(date -u +%Y-%m-%dT00:00:00Z)" +%s 2>/dev/null || date -u -d "$(date -u +%Y-%m-%dT00:00:00Z)" +%s 2>/dev/null || echo "0")
    today_spent=$(jq --argjson cutoff "$today_start_epoch" \
        '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0 | . * 100 | round / 100' \
        "$COST_FILE" 2>/dev/null || echo "0")

    # ── JSON Output ──
    if [[ "$json_output" == "true" ]]; then
        jq -n \
            --arg period "${period_days}d" \
            --argjson total_cost "$total_cost" \
            --argjson avg_cost "$avg_cost" \
            --argjson max_cost "$max_cost" \
            --argjson total_input "$total_input" \
            --argjson total_output "$total_output" \
            --argjson entry_count "$entry_count" \
            --argjson stage_breakdown "$stage_breakdown" \
            --argjson issue_breakdown "$issue_breakdown" \
            --arg trend "$trend" \
            --arg budget_enabled "$budget_enabled" \
            --argjson budget_usd "${budget_usd:-0}" \
            --argjson today_spent "$today_spent" \
            '{
                period: $period,
                total_cost_usd: $total_cost,
                avg_cost_usd: $avg_cost,
                max_cost_usd: $max_cost,
                total_input_tokens: $total_input,
                total_output_tokens: $total_output,
                entries: $entry_count,
                by_stage: $stage_breakdown,
                by_issue: $issue_breakdown,
                trend: $trend,
                budget: {
                    enabled: ($budget_enabled == "true"),
                    daily_usd: $budget_usd,
                    today_spent_usd: $today_spent
                }
            }'
        return 0
    fi

    # ── Dashboard Output ──
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Cost Intelligence ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Period: last ${period_days} day(s)    ${DIM}$(now_iso)${RESET}"
    echo ""

    echo -e "${BOLD}  SPENDING SUMMARY${RESET}"
    echo -e "    Total cost          ${CYAN}\$${total_cost}${RESET}"
    echo -e "    Avg per pipeline    \$${avg_cost}"
    echo -e "    Max single pipeline \$${max_cost}"
    echo -e "    Entries             ${entry_count}"
    echo ""

    echo -e "${BOLD}  TOKENS${RESET}"
    echo -e "    Input tokens        $(printf "%'d" "$total_input")"
    echo -e "    Output tokens       $(printf "%'d" "$total_output")"
    echo ""

    echo -e "${BOLD}  TREND${RESET}"
    echo -e "    ${trend}"
    echo ""

    # Stage breakdown
    if [[ "$by_stage" == "true" ]]; then
        echo -e "${BOLD}  BY STAGE${RESET}"
        echo "$stage_breakdown" | jq -r '.[] | "    \(.stage)\t$\(.cost)\t(\(.count) entries)"' 2>/dev/null | \
            while IFS=$'\t' read -r stage cost count; do
                printf "    %-20s %-12s %s\n" "$stage" "$cost" "$count"
            done
        echo ""
    fi

    # Issue breakdown
    if [[ "$by_issue" == "true" ]]; then
        echo -e "${BOLD}  BY ISSUE${RESET}"
        echo "$issue_breakdown" | jq -r '.[] | "    #\(.issue)\t$\(.cost)\t(\(.count) entries)"' 2>/dev/null | \
            while IFS=$'\t' read -r issue cost count; do
                printf "    %-20s %-12s %s\n" "$issue" "$cost" "$count"
            done
        echo ""
    fi

    # Budget
    if [[ "$budget_enabled" == "true" ]]; then
        local pct_used
        pct_used=$(awk -v spent="$today_spent" -v budget="$budget_usd" \
            'BEGIN { if (budget > 0) printf "%.0f", (spent / budget) * 100; else print "0" }')
        local bar=""
        local filled=$(( pct_used / 5 ))
        [[ "$filled" -gt 20 ]] && filled=20
        local empty=$(( 20 - filled ))
        bar=$(printf '%0.s█' $(seq 1 "$filled") 2>/dev/null || true)
        bar+=$(printf '%0.s░' $(seq 1 "$empty") 2>/dev/null || true)

        local color="$GREEN"
        [[ "$pct_used" -ge 80 ]] && color="$YELLOW"
        [[ "$pct_used" -ge 100 ]] && color="$RED"

        echo -e "${BOLD}  DAILY BUDGET${RESET}"
        echo -e "    ${color}${bar}${RESET} ${pct_used}%"
        echo -e "    \$${today_spent} / \$${budget_usd}"
        echo ""
    fi

    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ─── Budget Management ─────────────────────────────────────────────────────

budget_set() {
    local amount="${1:-}"

    if [[ -z "$amount" ]]; then
        error "Usage: shipwright cost budget set <amount_usd>"
        return 1
    fi

    # Validate it's a number
    if ! echo "$amount" | grep -qE '^[0-9]+\.?[0-9]*$'; then
        error "Invalid amount: ${amount} (must be a positive number)"
        return 1
    fi

    ensure_cost_dir

    local tmp_file
    tmp_file=$(mktemp)
    jq --arg amt "$amount" \
       '{daily_budget_usd: ($amt | tonumber), enabled: true}' \
       "$BUDGET_FILE" > "$tmp_file" && mv "$tmp_file" "$BUDGET_FILE"

    success "Daily budget set to \$${amount}"
    emit_event "cost.budget_set" "daily_budget_usd=${amount}"
}

budget_show() {
    ensure_cost_dir

    local budget_enabled budget_usd
    budget_enabled=$(jq -r '.enabled' "$BUDGET_FILE" 2>/dev/null || echo "false")
    budget_usd=$(jq -r '.daily_budget_usd' "$BUDGET_FILE" 2>/dev/null || echo "0")

    echo ""
    echo -e "${BOLD}  Daily Budget${RESET}"
    if [[ "$budget_enabled" == "true" ]]; then
        echo -e "    Limit:    ${CYAN}\$${budget_usd}${RESET} per day"
        echo -e "    Status:   ${GREEN}enabled${RESET}"

        # Show today's usage
        local today_start_epoch
        today_start_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$(date -u +%Y-%m-%dT00:00:00Z)" +%s 2>/dev/null || date -u -d "$(date -u +%Y-%m-%dT00:00:00Z)" +%s 2>/dev/null || echo "0")
        local today_spent
        today_spent=$(jq --argjson cutoff "$today_start_epoch" \
            '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0 | . * 100 | round / 100' \
            "$COST_FILE" 2>/dev/null || echo "0")
        echo -e "    Today:    \$${today_spent} / \$${budget_usd}"
    else
        echo -e "    Status:   ${DIM}not configured${RESET}"
        echo -e "    ${DIM}Set with: shipwright cost budget set <amount>${RESET}"
    fi
    echo ""
}

# ─── Help ──────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright cost${RESET} ${DIM}v${VERSION}${RESET} — Token Usage & Cost Intelligence"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright cost${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}show${RESET}                          Show cost summary for current period"
    echo -e "  ${CYAN}show${RESET} --period 30              Last 30 days"
    echo -e "  ${CYAN}show${RESET} --json                   JSON output"
    echo -e "  ${CYAN}show${RESET} --by-stage               Breakdown by pipeline stage"
    echo -e "  ${CYAN}show${RESET} --by-issue               Breakdown by issue"
    echo -e "  ${CYAN}budget set${RESET} <amount>            Set daily budget (USD)"
    echo -e "  ${CYAN}budget show${RESET}                    Show current budget/usage"
    echo ""
    echo -e "${BOLD}PIPELINE INTEGRATION${RESET}"
    echo -e "  ${CYAN}record${RESET} <in> <out> <model> <stage> [issue]   Record token usage"
    echo -e "  ${CYAN}calculate${RESET} <in> <out> <model>                Calculate cost (no record)"
    echo -e "  ${CYAN}check-budget${RESET} [estimated_usd]                Check budget before starting"
    echo ""
    echo -e "${BOLD}MODEL PRICING${RESET}"
    echo -e "  opus     \$15.00 / \$75.00 per 1M tokens (in/out)"
    echo -e "  sonnet   \$3.00 / \$15.00 per 1M tokens (in/out)"
    echo -e "  haiku    \$0.25 / \$1.25 per 1M tokens (in/out)"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright cost show${RESET}                              # 7-day cost summary"
    echo -e "  ${DIM}shipwright cost show --period 30 --by-stage${RESET}       # 30-day breakdown by stage"
    echo -e "  ${DIM}shipwright cost budget set 50.00${RESET}                  # Set \$50/day limit"
    echo -e "  ${DIM}shipwright cost budget show${RESET}                       # Check current budget"
    echo -e "  ${DIM}shipwright cost calculate 50000 10000 opus${RESET}        # Estimate cost"
}

# ─── Command Router ─────────────────────────────────────────────────────────

SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

case "$SUBCOMMAND" in
    show)
        cost_dashboard "$@"
        ;;
    budget)
        BUDGET_CMD="${1:-show}"
        shift 2>/dev/null || true
        case "$BUDGET_CMD" in
            set)  budget_set "$@" ;;
            show) budget_show ;;
            *)    error "Unknown budget command: ${BUDGET_CMD}"; show_help; exit 1 ;;
        esac
        ;;
    record)
        cost_record "$@"
        ;;
    calculate)
        cost_calculate "$@"
        echo ""
        ;;
    remaining-budget)
        cost_remaining_budget
        ;;
    check-budget)
        cost_check_budget "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        error "Unknown command: ${SUBCOMMAND}"
        echo ""
        show_help
        exit 1
        ;;
esac
