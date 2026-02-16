#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright instrument — Pipeline Instrumentation & Feedback Loops       ║
# ║  Records predicted vs actual metrics · Enables learning · Trend analysis ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.2"
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

format_tokens() {
    local tokens="$1"
    if [[ "$tokens" -ge 1000000 ]]; then
        printf "%.1fM" "$(echo "scale=1; $tokens / 1000000" | bc)"
    elif [[ "$tokens" -ge 1000 ]]; then
        printf "%.1fK" "$(echo "scale=1; $tokens / 1000" | bc)"
    else
        printf "%d" "$tokens"
    fi
}

format_cost() {
    printf '$%.2f' "$(echo "scale=2; $1" | bc)"
}

percent_delta() {
    local predicted="$1"
    local actual="$2"
    if [[ "$predicted" -eq 0 ]]; then
        echo "N/A"
        return
    fi
    local delta
    delta=$(echo "scale=0; ($actual - $predicted) * 100 / $predicted" | bc)
    if [[ "$delta" -ge 0 ]]; then
        printf "+%d%%" "$delta"
    else
        printf "%d%%" "$delta"
    fi
}

# ─── Instrumentation Storage ───────────────────────────────────────────────
INSTRUMENT_DIR="${HOME}/.shipwright/instrumentation"
INSTRUMENT_ACTIVE="${INSTRUMENT_DIR}/active"
INSTRUMENT_COMPLETED="${HOME}/.shipwright/instrumentation.jsonl"

ensure_instrument_dirs() {
    mkdir -p "$INSTRUMENT_ACTIVE" "${HOME}/.shipwright"
}

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright Instrumentation${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright instrument <command> [options]"
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo -e "    ${CYAN}start${RESET}        Begin instrumenting a pipeline run"
    echo -e "    ${CYAN}record${RESET}       Record a metric during execution"
    echo -e "    ${CYAN}stage-start${RESET}  Mark the start of a stage"
    echo -e "    ${CYAN}stage-end${RESET}    Mark the end of a stage with result"
    echo -e "    ${CYAN}finish${RESET}       Complete a pipeline run record"
    echo -e "    ${CYAN}summary${RESET}      Show run summary (predicted vs actual)"
    echo -e "    ${CYAN}trends${RESET}       Show prediction accuracy over time"
    echo -e "    ${CYAN}export${RESET}       Export instrumentation data"
    echo -e "    ${CYAN}help${RESET}         Show this help message"
    echo ""
    echo -e "  ${BOLD}START OPTIONS${RESET}"
    echo -e "    --run-id ID             Unique run identifier (required)"
    echo -e "    --issue N               GitHub issue number"
    echo -e "    --repo PATH             Repository path (default: current)"
    echo -e "    --predicted <json>      Initial predicted values (optional)"
    echo ""
    echo -e "  ${BOLD}RECORD OPTIONS${RESET}"
    echo -e "    --run-id ID             Run identifier (required)"
    echo -e "    --stage NAME            Stage name (required)"
    echo -e "    --metric NAME           Metric name (required)"
    echo -e "    --value VAL             Metric value (required)"
    echo ""
    echo -e "  ${BOLD}STAGE OPTIONS${RESET}"
    echo -e "    --run-id ID             Run identifier (required)"
    echo -e "    --stage NAME            Stage name (required)"
    echo -e "    --result success|fail   Result (stage-end only)"
    echo ""
    echo -e "  ${BOLD}FINISH OPTIONS${RESET}"
    echo -e "    --run-id ID             Run identifier (required)"
    echo -e "    --result success|fail   Final pipeline result"
    echo ""
    echo -e "  ${BOLD}SUMMARY OPTIONS${RESET}"
    echo -e "    --run-id ID             Run identifier (required)"
    echo ""
    echo -e "  ${BOLD}TRENDS OPTIONS${RESET}"
    echo -e "    --metric NAME           Filter by metric (optional)"
    echo -e "    --last N                Last N runs (default: 20)"
    echo ""
    echo -e "  ${BOLD}EXPORT OPTIONS${RESET}"
    echo -e "    --format json|csv       Output format (default: json)"
    echo -e "    --last N                Last N runs (default: all)"
    echo ""
    echo -e "  ${BOLD}EXAMPLES${RESET}"
    echo -e "    ${DIM}# Start instrumenting a run${RESET}"
    echo -e "    shipwright instrument start --run-id abc123 --issue 42"
    echo ""
    echo -e "    ${DIM}# Record stage execution${RESET}"
    echo -e "    shipwright instrument stage-start --run-id abc123 --stage plan"
    echo -e "    ${DIM}# ... do work ...${RESET}"
    echo -e "    shipwright instrument stage-end --run-id abc123 --stage plan --result success"
    echo ""
    echo -e "    ${DIM}# Record individual metric${RESET}"
    echo -e "    shipwright instrument record --run-id abc123 --stage build --metric iterations --value 7"
    echo ""
    echo -e "    ${DIM}# Finish the run${RESET}"
    echo -e "    shipwright instrument finish --run-id abc123 --result success"
    echo ""
    echo -e "    ${DIM}# Show what was predicted vs actual${RESET}"
    echo -e "    shipwright instrument summary --run-id abc123"
    echo ""
    echo -e "    ${DIM}# Analyze trends across runs${RESET}"
    echo -e "    shipwright instrument trends --metric duration --last 30"
    echo ""
    echo -e "    ${DIM}# Export data for analysis${RESET}"
    echo -e "    shipwright instrument export --format csv --last 50"
    echo ""
}

# ─── Start Instrumentation ──────────────────────────────────────────────────
cmd_start() {
    local run_id="" issue="" repo="." predicted=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-id)   run_id="${2:-}"; shift 2 ;;
            --issue)    issue="${2:-}"; shift 2 ;;
            --repo)     repo="${2:-}"; shift 2 ;;
            --predicted) predicted="${2:-}"; shift 2 ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    if [[ -z "$run_id" ]]; then
        error "Usage: shipwright instrument start --run-id ID [--issue N] [--repo PATH]"
        return 1
    fi

    ensure_instrument_dirs

    local run_file="${INSTRUMENT_ACTIVE}/${run_id}.json"
    local tmp_file
    tmp_file="$(mktemp "${INSTRUMENT_ACTIVE}/.tmp.XXXXXX")"

    # Get repo info if not provided
    if [[ "$repo" == "." ]]; then
        repo="$(cd "$repo" && pwd 2>/dev/null || echo "unknown")"
    fi

    # Build initial record with jq
    jq -n \
        --arg run_id "$run_id" \
        --argjson issue "$([ -n "$issue" ] && echo "$issue" || echo "null")" \
        --arg repo "$repo" \
        --arg started_at "$(now_iso)" \
        --argjson started_epoch "$(now_epoch)" \
        --arg predicted "$predicted" \
        '{
            run_id: $run_id,
            issue: $issue,
            repo: $repo,
            started_at: $started_at,
            started_epoch: $started_epoch,
            finished_at: null,
            finished_epoch: null,
            result: null,
            predicted: (if $predicted == "" then {} else ($predicted | fromjson) end),
            actual: {},
            stages: {},
            metrics: []
        }' > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

    mv "$tmp_file" "$run_file"
    success "Started instrumentation for run ${CYAN}${run_id}${RESET} (issue #${issue})"
    emit_event "instrument_start" "run_id=${run_id}" "issue=${issue}" "repo=${repo}"
}

# ─── Record Metric ───────────────────────────────────────────────────────────
cmd_record() {
    local run_id="" stage="" metric="" value=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-id) run_id="${2:-}"; shift 2 ;;
            --stage)  stage="${2:-}"; shift 2 ;;
            --metric) metric="${2:-}"; shift 2 ;;
            --value)  value="${2:-}"; shift 2 ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    if [[ -z "$run_id" || -z "$stage" || -z "$metric" || -z "$value" ]]; then
        error "Usage: shipwright instrument record --run-id ID --stage NAME --metric NAME --value VAL"
        return 1
    fi

    ensure_instrument_dirs
    local run_file="${INSTRUMENT_ACTIVE}/${run_id}.json"

    if [[ ! -f "$run_file" ]]; then
        error "Run not found: ${run_id}"
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp "${INSTRUMENT_ACTIVE}/.tmp.XXXXXX")"

    # Parse value as number if it's numeric
    local value_json
    if [[ "$value" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        value_json="$value"
    else
        value_json="\"$value\""
    fi

    # Append metric record with jq
    jq \
        --arg stage "$stage" \
        --arg metric "$metric" \
        --argjson value "$value_json" \
        --arg recorded_at "$(now_iso)" \
        '.metrics += [
            {
                stage: $stage,
                metric: $metric,
                value: $value,
                recorded_at: $recorded_at
            }
        ] |
        .actual[$stage] //= {} |
        .actual[$stage][$metric] = $value' \
        "$run_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

    mv "$tmp_file" "$run_file"
    success "Recorded ${CYAN}${metric}${RESET}=${CYAN}${value}${RESET} for stage ${CYAN}${stage}${RESET}"
    emit_event "instrument_record" "run_id=${run_id}" "stage=${stage}" "metric=${metric}" "value=${value}"
}

# ─── Stage Start ─────────────────────────────────────────────────────────────
cmd_stage_start() {
    local run_id="" stage=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-id) run_id="${2:-}"; shift 2 ;;
            --stage)  stage="${2:-}"; shift 2 ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    if [[ -z "$run_id" || -z "$stage" ]]; then
        error "Usage: shipwright instrument stage-start --run-id ID --stage NAME"
        return 1
    fi

    ensure_instrument_dirs
    local run_file="${INSTRUMENT_ACTIVE}/${run_id}.json"

    if [[ ! -f "$run_file" ]]; then
        error "Run not found: ${run_id}"
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp "${INSTRUMENT_ACTIVE}/.tmp.XXXXXX")"

    jq \
        --arg stage "$stage" \
        --arg started_at "$(now_iso)" \
        --argjson started_epoch "$(now_epoch)" \
        '.stages[$stage] //= {} |
        .stages[$stage].started_at = $started_at |
        .stages[$stage].started_epoch = $started_epoch' \
        "$run_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

    mv "$tmp_file" "$run_file"
    success "Started stage ${CYAN}${stage}${RESET}"
}

# ─── Stage End ───────────────────────────────────────────────────────────────
cmd_stage_end() {
    local run_id="" stage="" result=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-id) run_id="${2:-}"; shift 2 ;;
            --stage)  stage="${2:-}"; shift 2 ;;
            --result) result="${2:-}"; shift 2 ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    if [[ -z "$run_id" || -z "$stage" ]]; then
        error "Usage: shipwright instrument stage-end --run-id ID --stage NAME [--result success|failure|timeout]"
        return 1
    fi

    ensure_instrument_dirs
    local run_file="${INSTRUMENT_ACTIVE}/${run_id}.json"

    if [[ ! -f "$run_file" ]]; then
        error "Run not found: ${run_id}"
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp "${INSTRUMENT_ACTIVE}/.tmp.XXXXXX")"

    jq \
        --arg stage "$stage" \
        --arg finished_at "$(now_iso)" \
        --argjson finished_epoch "$(now_epoch)" \
        --arg result "$result" \
        '.stages[$stage] //= {} |
        .stages[$stage].finished_at = $finished_at |
        .stages[$stage].finished_epoch = $finished_epoch |
        (if .stages[$stage].started_epoch and .stages[$stage].finished_epoch then
            .stages[$stage].duration_s = (.stages[$stage].finished_epoch - .stages[$stage].started_epoch)
        else . end) |
        (if $result != "" then .stages[$stage].result = $result else . end)' \
        "$run_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

    mv "$tmp_file" "$run_file"
    success "Finished stage ${CYAN}${stage}${RESET} (${result})"
}

# ─── Finish Run ──────────────────────────────────────────────────────────────
cmd_finish() {
    local run_id="" result=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-id) run_id="${2:-}"; shift 2 ;;
            --result) result="${2:-}"; shift 2 ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    if [[ -z "$run_id" ]]; then
        error "Usage: shipwright instrument finish --run-id ID [--result success|failure|timeout]"
        return 1
    fi

    ensure_instrument_dirs
    local run_file="${INSTRUMENT_ACTIVE}/${run_id}.json"

    if [[ ! -f "$run_file" ]]; then
        error "Run not found: ${run_id}"
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp "${INSTRUMENT_ACTIVE}/.tmp.XXXXXX")"

    # Update run record with finish data
    jq \
        --arg finished_at "$(now_iso)" \
        --argjson finished_epoch "$(now_epoch)" \
        --arg result "$result" \
        '.finished_at = $finished_at |
        .finished_epoch = $finished_epoch |
        .result = $result |
        (.finished_epoch - .started_epoch) as $total_duration |
        .total_duration_s = $total_duration' \
        "$run_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

    # Compact and append to JSONL (single-line JSON)
    jq -c '.' "$tmp_file" >> "$INSTRUMENT_COMPLETED"
    rm -f "$tmp_file"

    # Remove active file
    rm -f "$run_file"

    success "Finished instrumentation for run ${CYAN}${run_id}${RESET} (${result})"
    emit_event "instrument_finish" "run_id=${run_id}" "result=${result}"
}

# ─── Show Summary ────────────────────────────────────────────────────────────
cmd_summary() {
    local run_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-id) run_id="${2:-}"; shift 2 ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    if [[ -z "$run_id" ]]; then
        error "Usage: shipwright instrument summary --run-id ID"
        return 1
    fi

    ensure_instrument_dirs

    # Check active first, then completed
    local run_file="${INSTRUMENT_ACTIVE}/${run_id}.json"
    if [[ ! -f "$run_file" ]]; then
        # Try to find in JSONL
        run_file=$(grep -l "\"run_id\":\"${run_id}\"" "$INSTRUMENT_COMPLETED" 2>/dev/null | head -1 || true)
        if [[ -z "$run_file" ]]; then
            error "Run not found: ${run_id}"
            return 1
        fi
        # Extract matching record from JSONL
        local tmp_file
        tmp_file="$(mktemp)"
        grep "\"run_id\":\"${run_id}\"" "$INSTRUMENT_COMPLETED" | head -1 > "$tmp_file"
        run_file="$tmp_file"
        trap "rm -f '$tmp_file'" RETURN
    fi

    # Extract data
    local issue result started_at finished_at total_dur
    local pred_dur pred_iter pred_tokens pred_cost
    local actual_dur actual_iter actual_tokens actual_cost

    issue=$(jq -r '.issue // "N/A"' "$run_file")
    result=$(jq -r '.result // "pending"' "$run_file")
    started_at=$(jq -r '.started_at' "$run_file")
    finished_at=$(jq -r '.finished_at // "in progress"' "$run_file")
    total_dur=$(jq -r '.total_duration_s // 0' "$run_file")

    # Predicted values
    pred_dur=$(jq -r '.predicted.timeout // 0' "$run_file")
    pred_iter=$(jq -r '.predicted.iterations // 0' "$run_file")
    pred_tokens=$(jq -r '.predicted.tokens // 0' "$run_file")
    pred_cost=$(jq -r '.predicted.cost // 0' "$run_file")

    # Aggregate actual values
    actual_iter=$(jq '[.metrics[] | select(.metric == "iterations") | .value] | max' "$run_file" 2>/dev/null || echo "0")
    actual_tokens=$(jq '[.metrics[] | select(.metric == "tokens_total") | .value] | max' "$run_file" 2>/dev/null || echo "0")
    actual_cost=$(jq '[.metrics[] | select(.metric == "cost_usd") | .value] | add // 0' "$run_file" 2>/dev/null || echo "0")
    actual_dur="$total_dur"

    # Print summary
    echo ""
    echo -e "${CYAN}${BOLD}  Pipeline Run ${run_id}${RESET}  ${DIM}Issue #${issue}${RESET}"
    echo -e "${DIM}  ═════════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}Result:${RESET} ${result}"
    echo -e "  ${DIM}Started: ${started_at}${RESET}"
    echo -e "  ${DIM}Finished: ${finished_at}${RESET}"
    echo ""
    echo -e "  ${BOLD}Predicted vs Actual${RESET}"
    echo ""

    # Print table header
    printf "  %-20s %-15s %-15s %-10s\n" "Metric" "Predicted" "Actual" "Delta"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────────${RESET}"

    # Duration
    local dur_fmt_pred dur_fmt_act dur_delta
    dur_fmt_pred=$(format_duration "$pred_dur")
    dur_fmt_act=$(format_duration "$actual_dur")
    dur_delta=$(percent_delta "$pred_dur" "$actual_dur")
    printf "  %-20s %-15s %-15s %-10s\n" "Duration" "$dur_fmt_pred" "$dur_fmt_act" "$dur_delta"

    # Iterations
    if [[ "$pred_iter" -gt 0 || "$actual_iter" -gt 0 ]]; then
        local iter_delta
        iter_delta=$(percent_delta "$pred_iter" "$actual_iter")
        printf "  %-20s %-15s %-15s %-10s\n" "Iterations" "$pred_iter" "$actual_iter" "$iter_delta"
    fi

    # Tokens
    if [[ "$pred_tokens" -gt 0 || "$actual_tokens" -gt 0 ]]; then
        local tok_fmt_pred tok_fmt_act tok_delta
        tok_fmt_pred=$(format_tokens "$pred_tokens")
        tok_fmt_act=$(format_tokens "$actual_tokens")
        tok_delta=$(percent_delta "$pred_tokens" "$actual_tokens")
        printf "  %-20s %-15s %-15s %-10s\n" "Tokens" "$tok_fmt_pred" "$tok_fmt_act" "$tok_delta"
    fi

    # Cost
    if [[ $(echo "$pred_cost > 0" | bc) -eq 1 || $(echo "$actual_cost > 0" | bc) -eq 1 ]]; then
        local cost_fmt_pred cost_fmt_act cost_delta
        cost_fmt_pred=$(format_cost "$pred_cost")
        cost_fmt_act=$(format_cost "$actual_cost")
        cost_delta=$(percent_delta "$(echo "$pred_cost * 100" | bc)" "$(echo "$actual_cost * 100" | bc)")
        printf "  %-20s %-15s %-15s %-10s\n" "Cost" "$cost_fmt_pred" "$cost_fmt_act" "$cost_delta"
    fi

    echo ""
    echo -e "  ${BOLD}Stages${RESET}"
    echo ""
    jq -r '.stages | to_entries[] | "  \(.key): \(.value.result // "pending") (\(.value.duration_s // "?")s)"' "$run_file"
    echo ""
}

# ─── Show Trends ─────────────────────────────────────────────────────────────
cmd_trends() {
    local metric="" last=20

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --metric) metric="${2:-}"; shift 2 ;;
            --last)   last="${2:-20}"; shift 2 ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    if [[ ! -f "$INSTRUMENT_COMPLETED" ]]; then
        warn "No completed runs found"
        return
    fi

    echo ""
    echo -e "${CYAN}${BOLD}  Instrumentation Trends${RESET}  ${DIM}(last ${last} runs)${RESET}"
    echo -e "${DIM}  ═══════════════════════════════════════════════════════════════════${RESET}"
    echo ""

    # Extract metrics and compute statistics
    if [[ -n "$metric" ]]; then
        echo -e "  ${BOLD}${metric}${RESET}"
        echo -e "  ${DIM}────────────────────────────────────────${RESET}"
    fi

    # Use jq to analyze trends from JSONL file (with compact output)
    if [[ -n "$metric" ]]; then
        jq -c -s '[.[] | .metrics[] | select(.metric == "'$metric'")] | group_by(.metric) | map({metric: .[0].metric, count: length, avg: (map(.value | tonumber) | add / length), min: (map(.value | tonumber) | min), max: (map(.value | tonumber) | max)}) | .[]' "$INSTRUMENT_COMPLETED" | while read -r line; do
            local m avg min max
            m=$(echo "$line" | jq -r '.metric')
            avg=$(echo "$line" | jq -r '.avg | round')
            min=$(echo "$line" | jq -r '.min | round')
            max=$(echo "$line" | jq -r '.max | round')
            printf "  %-25s avg: %-8s min: %-8s max: %-8s\n" "$m" "$avg" "$min" "$max"
        done
    else
        jq -c -s '[.[] | .metrics[]] | group_by(.metric) | map({metric: .[0].metric, count: length, avg: (map(.value | tonumber) | add / length), min: (map(.value | tonumber) | min), max: (map(.value | tonumber) | max)}) | .[]' "$INSTRUMENT_COMPLETED" | while read -r line; do
            local m avg min max
            m=$(echo "$line" | jq -r '.metric')
            avg=$(echo "$line" | jq -r '.avg | round')
            min=$(echo "$line" | jq -r '.min | round')
            max=$(echo "$line" | jq -r '.max | round')
            printf "  %-25s avg: %-8s min: %-8s max: %-8s\n" "$m" "$avg" "$min" "$max"
        done
    fi

    echo ""
}

# ─── Export Data ─────────────────────────────────────────────────────────────
cmd_export() {
    local format="json" last=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) format="${2:-}"; shift 2 ;;
            --last)   last="${2:-}"; shift 2 ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    if [[ ! -f "$INSTRUMENT_COMPLETED" ]]; then
        warn "No completed runs found"
        return
    fi

    case "$format" in
        json)
            if [[ -n "$last" ]]; then
                tail -n "$last" "$INSTRUMENT_COMPLETED" | jq -s '.'
            else
                jq -s '.' "$INSTRUMENT_COMPLETED"
            fi
            ;;
        csv)
            echo "run_id,issue,repo,started_at,result,duration_s,iterations,tokens,cost"
            if [[ -n "$last" ]]; then
                tail -n "$last" "$INSTRUMENT_COMPLETED"
            else
                cat "$INSTRUMENT_COMPLETED"
            fi | jq -r '[.run_id, .issue // "", .repo, .started_at, .result // "", .total_duration_s // 0, (.metrics[] | select(.metric == "iterations") | .value) // 0, (.metrics[] | select(.metric == "tokens_total") | .value) // 0, (.metrics[] | select(.metric == "cost_usd") | .value) // 0] | @csv'
            ;;
        *)
            error "Unknown format: ${format}. Use 'json' or 'csv'."
            return 1
            ;;
    esac
}

# ─── Main Command Router ────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        start)       cmd_start "$@" ;;
        record)      cmd_record "$@" ;;
        stage-start) cmd_stage_start "$@" ;;
        stage-end)   cmd_stage_end "$@" ;;
        finish)      cmd_finish "$@" ;;
        summary)     cmd_summary "$@" ;;
        trends)      cmd_trends "$@" ;;
        export)      cmd_export "$@" ;;
        help|--help|-h) show_help ;;
        *)
            error "Unknown command: ${cmd}"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
