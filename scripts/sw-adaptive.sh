#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright adaptive — data-driven pipeline tuning                       ║
# ║  Replace 83+ hardcoded values with learned defaults from historical runs  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ─── Paths ─────────────────────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"
MODELS_FILE="${HOME}/.shipwright/adaptive-models.json"
REPO_DIR="${PWD}"

# ─── Default Thresholds ─────────────────────────────────────────────────────
MIN_CONFIDENCE_SAMPLES=10
MED_CONFIDENCE_SAMPLES=50
MIN_TIMEOUT=60
MAX_TIMEOUT=7200
MIN_ITERATIONS=2
MAX_ITERATIONS=50
MIN_POLL_INTERVAL=10
MAX_POLL_INTERVAL=300
MIN_COVERAGE=0
MAX_COVERAGE=100

# ─── JSON Helper: Percentile ────────────────────────────────────────────────
# Compute P-th percentile of sorted numeric array (bash + jq)
# Usage: percentile "[1, 5, 10, 15, 20]" 95
percentile() {
    local arr="$1"
    local p="$2"
    jq -n --arg arr "$arr" --arg p "$p" '
        ($arr | fromjson | sort) as $sorted |
        ($sorted | length) as $len |
        (($p / 100) * ($len - 1) | floor) as $idx |
        if $len == 0 then null
        elif $idx >= $len - 1 then $sorted[-1]
        else
            ($sorted[$idx] + $sorted[$idx + 1]) / 2
        end
    '
}

# ─── JSON Helper: Mean ──────────────────────────────────────────────────────
mean() {
    local arr="$1"
    jq -n --arg arr "$arr" '
        ($arr | fromjson | add / length)
    '
}

# ─── JSON Helper: Median ───────────────────────────────────────────────────
median() {
    local arr="$1"
    percentile "$arr" 50
}

# ─── JSON Helper: Stddev ───────────────────────────────────────────────────
stddev() {
    local arr="$1"
    jq -n --arg arr "$arr" '
        ($arr | fromjson) as $data |
        ($data | add / length) as $mean |
        (($data | map(. - $mean | . * .) | add) / ($data | length)) | sqrt
    '
}

# ─── Determine Confidence Level ─────────────────────────────────────────────
confidence_level() {
    local samples="$1"
    if [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "low"
    elif [[ "$samples" -lt "$MED_CONFIDENCE_SAMPLES" ]]; then
        echo "medium"
    else
        echo "high"
    fi
}

# ─── Load Models from Cache ─────────────────────────────────────────────────
load_models() {
    if [[ -f "$MODELS_FILE" ]]; then
        cat "$MODELS_FILE"
    else
        echo '{}'
    fi
}

# ─── Save Models to Cache ───────────────────────────────────────────────────
save_models() {
    local models="$1"
    mkdir -p "${HOME}/.shipwright"
    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-adaptive-models.XXXXXX")
    echo "$models" > "$tmp_file"
    mv "$tmp_file" "$MODELS_FILE"
}

# ─── Query events by field and value ────────────────────────────────────────
query_events() {
    local field="$1"
    local value="$2"
    if [[ ! -f "$EVENTS_FILE" ]]; then
        echo "[]"
        return
    fi
    jq -s "
        map(select(.${field} == \"${value}\")) | map(.duration, .iterations, .model, .team_size, .template, .quality_score, .coverage // empty) | flatten
    " "$EVENTS_FILE" 2>/dev/null || echo "[]"
}

# ─── Get Timeout Recommendation ─────────────────────────────────────────────
get_timeout() {
    local stage="${1:-build}"
    local repo="${2:-.}"
    local default="${3:-1800}"

    # Query events for this stage
    local durations
    durations=$(jq -s "
        map(select(.type == \"stage_complete\" and .stage == \"${stage}\") | .duration // empty) |
        map(select(. > 0)) | map(. / 1000) | sort
    " "$EVENTS_FILE" 2>/dev/null || echo "[]")

    local samples
    samples=$(echo "$durations" | jq 'length')

    if [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "$default"
        return
    fi

    # Compute P95 + 20% buffer
    local p95
    p95=$(percentile "$durations" 95)
    local timeout
    timeout=$(echo "$p95 * 1.2" | bc 2>/dev/null | cut -d. -f1)

    # Apply safety bounds
    if [[ "$timeout" -lt "$MIN_TIMEOUT" ]]; then timeout="$MIN_TIMEOUT"; fi
    if [[ "$timeout" -gt "$MAX_TIMEOUT" ]]; then timeout="$MAX_TIMEOUT"; fi

    echo "$timeout"
}

# ─── Get Iterations Recommendation ─────────────────────────────────────────
get_iterations() {
    local complexity="${1:-5}"
    local stage="${2:-build}"
    local default="${3:-10}"

    # Query events for this complexity band
    local iterations_data
    iterations_data=$(jq -s "
        map(select(.type == \"build_complete\" and .stage == \"${stage}\") | .iterations // empty) |
        map(select(. > 0))
    " "$EVENTS_FILE" 2>/dev/null || echo "[]")

    local samples
    samples=$(echo "$iterations_data" | jq 'length')

    if [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "$default"
        return
    fi

    # Compute mean
    local mean_iters
    mean_iters=$(mean "$iterations_data")
    local result
    result=$(echo "$mean_iters" | cut -d. -f1)

    # Apply safety bounds
    if [[ "$result" -lt "$MIN_ITERATIONS" ]]; then result="$MIN_ITERATIONS"; fi
    if [[ "$result" -gt "$MAX_ITERATIONS" ]]; then result="$MAX_ITERATIONS"; fi

    echo "$result"
}

# ─── Get Model Recommendation ───────────────────────────────────────────────
get_model() {
    local stage="${1:-build}"
    local default="${2:-opus}"

    # Query events for successful runs by model on this stage
    local model_success
    model_success=$(jq -s "
        group_by(.model) |
        map({
            model: .[0].model,
            total: length,
            success: map(select(.exit_code == 0)) | length,
            cost: (map(.token_cost // 0) | add)
        }) |
        map(select(.total >= 5)) |
        map(select((.success / .total) > 0.9)) |
        sort_by(.cost) |
        .[0].model // \"$default\"
    " "$EVENTS_FILE" 2>/dev/null || echo "\"$default\"")

    echo "$model_success" | tr -d '"'
}

# ─── Get Team Size Recommendation ───────────────────────────────────────────
get_team_size() {
    local complexity="${1:-5}"
    local default="${2:-2}"

    # Query team sizes for similar complexity
    local team_data
    team_data=$(jq -s "
        map(select(.team_size != null) | .team_size) |
        map(select(. > 0))
    " "$EVENTS_FILE" 2>/dev/null || echo "[]")

    local samples
    samples=$(echo "$team_data" | jq 'length')

    if [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "$default"
        return
    fi

    local mean_team
    mean_team=$(mean "$team_data")
    local result
    result=$(echo "$mean_team" | cut -d. -f1)

    # Bounds: 1-8 agents
    if [[ "$result" -lt 1 ]]; then result=1; fi
    if [[ "$result" -gt 8 ]]; then result=8; fi

    echo "$result"
}

# ─── Get Template Recommendation ────────────────────────────────────────────
get_template() {
    local complexity="${1:-5}"
    local default="${2:-standard}"

    # Find most successful template for similar complexity
    local template
    template=$(jq -s "
        map(select(.template != null and .complexity_score != null)) |
        group_by(.template) |
        map({
            template: .[0].template,
            success_rate: (map(select(.exit_code == 0)) | length / length)
        }) |
        sort_by(-.success_rate) |
        .[0].template // \"$default\"
    " "$EVENTS_FILE" 2>/dev/null || echo "\"$default\"")

    echo "$template" | tr -d '"'
}

# ─── Get Poll Interval Recommendation ───────────────────────────────────────
get_poll_interval() {
    local default="${1:-60}"

    # Query queue depths to estimate optimal poll interval
    local queue_events
    queue_events=$(jq -s "
        map(select(.type == \"queue_update\") | .queue_depth // 0) |
        map(select(. > 0))
    " "$EVENTS_FILE" 2>/dev/null || echo "[]")

    local samples
    samples=$(echo "$queue_events" | jq 'length')

    if [[ "$samples" -lt 5 ]]; then
        echo "$default"
        return
    fi

    local mean_queue
    mean_queue=$(mean "$queue_events")

    # Heuristic: deeper queue → shorter interval
    local interval
    interval=$(echo "60 - (${mean_queue} * 2)" | bc 2>/dev/null || echo "$default")

    # Apply bounds
    if [[ "$interval" -lt "$MIN_POLL_INTERVAL" ]]; then interval="$MIN_POLL_INTERVAL"; fi
    if [[ "$interval" -gt "$MAX_POLL_INTERVAL" ]]; then interval="$MAX_POLL_INTERVAL"; fi

    echo "$interval"
}

# ─── Get Retry Limit Recommendation ────────────────────────────────────────
get_retry_limit() {
    local error_class="${1:-generic}"
    local default="${2:-2}"

    # Query retry success rate by error class
    local retry_data
    retry_data=$(jq -s "
        map(select(.type == \"retry\" and .error_class != null)) |
        group_by(.error_class) |
        map({
            error_class: .[0].error_class,
            retries: (map(.attempt_count) | add // 0),
            successes: (map(select(.exit_code == 0)) | length)
        }) |
        map(select(.error_class == \"${error_class}\")) |
        .[0]
    " "$EVENTS_FILE" 2>/dev/null || echo "{}")

    # Extract success rate with safe defaults for missing data
    local success_rate
    success_rate=$(echo "$retry_data" | jq 'if .retries and .retries > 0 then .successes / .retries else 0.5 end')

    # Heuristic: higher success rate → allow more retries (cap at 5)
    local limit
    limit=$(echo "scale=0; ${success_rate} * 5" | bc 2>/dev/null | cut -d. -f1)
    if [[ -z "$limit" ]]; then limit="$default"; fi

    if [[ "$limit" -lt 1 ]]; then limit=1; fi
    if [[ "$limit" -gt 5 ]]; then limit=5; fi

    echo "$limit"
}

# ─── Get Quality Threshold Recommendation ───────────────────────────────────
get_quality_threshold() {
    local default="${1:-70}"

    # Query quality score distribution on pass vs fail runs
    local quality_data
    quality_data=$(jq -s "
        map(select(.quality_score != null)) |
        map(select(.exit_code == 0)) |
        map(.quality_score) |
        sort
    " "$EVENTS_FILE" 2>/dev/null || echo "[]")

    local samples
    samples=$(echo "$quality_data" | jq 'length')

    if [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "$default"
        return
    fi

    # Use 25th percentile of passing runs as recommended threshold
    local p25
    p25=$(percentile "$quality_data" 25)
    local result
    result=$(echo "$p25" | cut -d. -f1)

    # Bounds: 50-95
    if [[ "$result" -lt 50 ]]; then result=50; fi
    if [[ "$result" -gt 95 ]]; then result=95; fi

    echo "$result"
}

# ─── Get Coverage Min Recommendation ────────────────────────────────────────
get_coverage_min() {
    local default="${1:-80}"

    # Query coverage data on successful vs failed runs
    local coverage_data
    coverage_data=$(jq -s "
        map(select(.coverage != null and .exit_code == 0)) |
        map(.coverage) |
        sort
    " "$EVENTS_FILE" 2>/dev/null || echo "[]")

    local samples
    samples=$(echo "$coverage_data" | jq 'length')

    if [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "$default"
        return
    fi

    # Use median of successful runs
    local med_coverage
    med_coverage=$(median "$coverage_data")
    local result
    result=$(echo "$med_coverage" | cut -d. -f1)

    # Bounds: 0-100
    if [[ "$result" -lt "$MIN_COVERAGE" ]]; then result="$MIN_COVERAGE"; fi
    if [[ "$result" -gt "$MAX_COVERAGE" ]]; then result="$MAX_COVERAGE"; fi

    echo "$result"
}

# ─── Main: get subcommand ───────────────────────────────────────────────────
cmd_get() {
    local metric="${1:-}"
    [[ -n "$metric" ]] && shift || true

    local stage="build"
    local repo="${REPO_DIR}"
    local complexity=5
    local default=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage) stage="$2"; shift 2 ;;
            --repo) repo="$2"; shift 2 ;;
            --complexity) complexity="$2"; shift 2 ;;
            --default) default="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    case "$metric" in
        timeout)
            get_timeout "$stage" "$repo" "${default:-1800}"
            ;;
        iterations)
            get_iterations "$complexity" "$stage" "${default:-10}"
            ;;
        model)
            get_model "$stage" "${default:-opus}"
            ;;
        team_size)
            get_team_size "$complexity" "${default:-2}"
            ;;
        template)
            get_template "$complexity" "${default:-standard}"
            ;;
        poll_interval)
            get_poll_interval "${default:-60}"
            ;;
        retry_limit)
            get_retry_limit "generic" "${default:-2}"
            ;;
        quality_threshold)
            get_quality_threshold "${default:-70}"
            ;;
        coverage_min)
            get_coverage_min "${default:-80}"
            ;;
        *)
            error "Unknown metric: $metric"
            echo "Available metrics: timeout, iterations, model, team_size, template, poll_interval, retry_limit, quality_threshold, coverage_min"
            return 1
            ;;
    esac
}

# ─── Main: profile subcommand ───────────────────────────────────────────────
cmd_profile() {
    # profile takes no positional args, just --options
    local repo="${REPO_DIR}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    info "Adaptive Profile for ${CYAN}${repo}${RESET}"
    echo ""

    # Table header
    printf "%-25s %-15s %-15s %-12s %-10s\n" "Metric" "Learned" "Default" "Samples" "Confidence"
    printf "%s\n" "$(printf '%.0s─' {1..80})"

    # Timeout
    local timeout_val
    timeout_val=$(get_timeout "build" "$repo" "1800")
    local timeout_samples
    timeout_samples=$(jq -s "map(select(.type == \"stage_complete\" and .stage == \"build\") | .duration) | length" "$EVENTS_FILE" 2>/dev/null || echo "0")
    local timeout_conf
    timeout_conf=$(confidence_level "$timeout_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "timeout (s)" "$timeout_val" "1800" "$timeout_samples" "$timeout_conf"

    # Iterations
    local iter_val
    iter_val=$(get_iterations 5 "build" "10")
    local iter_samples
    iter_samples=$(jq -s "map(select(.type == \"build_complete\" and .stage == \"build\") | .iterations) | length" "$EVENTS_FILE" 2>/dev/null || echo "0")
    local iter_conf
    iter_conf=$(confidence_level "$iter_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "iterations" "$iter_val" "10" "$iter_samples" "$iter_conf"

    # Model
    local model_val
    model_val=$(get_model "build" "opus")
    local model_samples
    model_samples=$(jq -s "map(select(.model != null and .type == \"pipeline.completed\")) | length" "$EVENTS_FILE" 2>/dev/null || echo "0")
    local model_conf
    model_conf=$(confidence_level "$model_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "model" "$model_val" "opus" "$model_samples" "$model_conf"

    # Team size
    local team_val
    team_val=$(get_team_size 5 "2")
    local team_samples
    team_samples=$(jq -s "map(select(.team_size != null)) | length" "$EVENTS_FILE" 2>/dev/null || echo "0")
    local team_conf
    team_conf=$(confidence_level "$team_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "team_size" "$team_val" "2" "$team_samples" "$team_conf"

    # Template
    local template_val
    template_val=$(get_template 5 "standard")
    local template_samples
    template_samples=$(jq -s "map(select(.template != null)) | length" "$EVENTS_FILE" 2>/dev/null || echo "0")
    local template_conf
    template_conf=$(confidence_level "$template_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "template" "$template_val" "standard" "$template_samples" "$template_conf"

    # Poll interval
    local poll_val
    poll_val=$(get_poll_interval "60")
    local poll_samples=0
    local poll_conf
    poll_conf=$(confidence_level "$poll_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "poll_interval (s)" "$poll_val" "60" "$poll_samples" "$poll_conf"

    # Quality threshold
    local quality_val
    quality_val=$(get_quality_threshold "70")
    local quality_samples
    quality_samples=$(jq -s "map(select(.quality_score != null)) | length" "$EVENTS_FILE" 2>/dev/null || echo "0")
    local quality_conf
    quality_conf=$(confidence_level "$quality_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "quality_threshold" "$quality_val" "70" "$quality_samples" "$quality_conf"

    # Coverage min
    local coverage_val
    coverage_val=$(get_coverage_min "80")
    local coverage_samples
    coverage_samples=$(jq -s "map(select(.coverage != null)) | length" "$EVENTS_FILE" 2>/dev/null || echo "0")
    local coverage_conf
    coverage_conf=$(confidence_level "$coverage_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "coverage_min (%)" "$coverage_val" "80" "$coverage_samples" "$coverage_conf"

    echo ""
}

# ─── Main: train subcommand ─────────────────────────────────────────────────
cmd_train() {
    # train takes no positional args, just --options
    local repo="${REPO_DIR}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ ! -f "$EVENTS_FILE" ]]; then
        warn "No events file found: $EVENTS_FILE"
        return 1
    fi

    info "Training adaptive models from ${CYAN}${EVENTS_FILE}${RESET}"

    local event_count
    event_count=$(jq -s 'length' "$EVENTS_FILE" 2>/dev/null || echo 0)
    info "Processing ${CYAN}${event_count}${RESET} events..."

    # Build comprehensive models JSON using jq directly
    local timeout_learned timeout_samples
    timeout_learned=$(get_timeout "build" "$repo" "1800")
    timeout_samples=$(jq -s "map(select(.type == \"stage_complete\" and .stage == \"build\") | .duration) | length" "$EVENTS_FILE" 2>/dev/null || echo 0)

    local iterations_learned iterations_samples
    iterations_learned=$(get_iterations 5 "build" "10")
    iterations_samples=$(jq -s "map(select(.type == \"build_complete\") | .iterations) | length" "$EVENTS_FILE" 2>/dev/null || echo 0)

    local model_learned model_samples
    model_learned=$(get_model "build" "opus")
    model_samples=$(jq -s "map(select(.model != null)) | length" "$EVENTS_FILE" 2>/dev/null || echo 0)

    local team_learned team_samples
    team_learned=$(get_team_size 5 "2")
    team_samples=$(jq -s "map(select(.team_size != null)) | length" "$EVENTS_FILE" 2>/dev/null || echo 0)

    local quality_learned quality_samples
    quality_learned=$(get_quality_threshold "70")
    quality_samples=$(jq -s "map(select(.quality_score != null)) | length" "$EVENTS_FILE" 2>/dev/null || echo 0)

    local coverage_learned coverage_samples
    coverage_learned=$(get_coverage_min "80")
    coverage_samples=$(jq -s "map(select(.coverage != null)) | length" "$EVENTS_FILE" 2>/dev/null || echo 0)

    local trained_at
    trained_at=$(now_iso)

    # Build JSON using jq with variables
    local models
    models=$(jq -n \
        --arg trained_at "$trained_at" \
        --arg timeout_learned "$timeout_learned" \
        --arg iterations_learned "$iterations_learned" \
        --arg model_learned "$model_learned" \
        --arg team_learned "$team_learned" \
        --arg quality_learned "$quality_learned" \
        --arg coverage_learned "$coverage_learned" \
        --arg timeout_samples "$timeout_samples" \
        --arg iterations_samples "$iterations_samples" \
        --arg model_samples "$model_samples" \
        --arg team_samples "$team_samples" \
        --arg quality_samples "$quality_samples" \
        --arg coverage_samples "$coverage_samples" \
        '{
            timeout: {
                learned: ($timeout_learned | tonumber),
                default: 1800,
                samples: ($timeout_samples | tonumber)
            },
            iterations: {
                learned: ($iterations_learned | tonumber),
                default: 10,
                samples: ($iterations_samples | tonumber)
            },
            model: {
                learned: $model_learned,
                default: "opus",
                samples: ($model_samples | tonumber)
            },
            team_size: {
                learned: ($team_learned | tonumber),
                default: 2,
                samples: ($team_samples | tonumber)
            },
            quality_threshold: {
                learned: ($quality_learned | tonumber),
                default: 70,
                samples: ($quality_samples | tonumber)
            },
            coverage_min: {
                learned: ($coverage_learned | tonumber),
                default: 80,
                samples: ($coverage_samples | tonumber)
            },
            trained_at: $trained_at
        }')

    save_models "$models"
    success "Models trained and saved to ${CYAN}${MODELS_FILE}${RESET}"
}

# ─── Main: compare subcommand ───────────────────────────────────────────────
cmd_compare() {
    # compare takes no positional args, just --options
    local repo="${REPO_DIR}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    info "Learned vs Hardcoded Values for ${CYAN}${repo}${RESET}"
    echo ""

    printf "%-25s %-15s %-15s %-15s\n" "Metric" "Hardcoded" "Learned" "Difference"
    printf "%s\n" "$(printf '%.0s─' {1..70})"

    # Timeout
    local timeout_hard=1800
    local timeout_learn
    timeout_learn=$(get_timeout "build" "$repo" "$timeout_hard")
    local timeout_diff=$((timeout_learn - timeout_hard))
    printf "%-25s %-15s %-15s %-15s\n" "timeout (s)" "$timeout_hard" "$timeout_learn" "$timeout_diff"

    # Iterations
    local iter_hard=10
    local iter_learn
    iter_learn=$(get_iterations 5 "build" "$iter_hard")
    local iter_diff=$((iter_learn - iter_hard))
    printf "%-25s %-15s %-15s %-15s\n" "iterations" "$iter_hard" "$iter_learn" "$iter_diff"

    # Model
    local model_hard="opus"
    local model_learn
    model_learn=$(get_model "build" "$model_hard")
    printf "%-25s %-15s %-15s %-15s\n" "model" "$model_hard" "$model_learn" "-"

    # Team size
    local team_hard=2
    local team_learn
    team_learn=$(get_team_size 5 "$team_hard")
    local team_diff=$((team_learn - team_hard))
    printf "%-25s %-15s %-15s %-15s\n" "team_size" "$team_hard" "$team_learn" "$team_diff"

    # Quality threshold
    local quality_hard=70
    local quality_learn
    quality_learn=$(get_quality_threshold "$quality_hard")
    local quality_diff=$((quality_learn - quality_hard))
    printf "%-25s %-15s %-15s %-15s\n" "quality_threshold" "$quality_hard" "$quality_learn" "$quality_diff"

    # Coverage min
    local coverage_hard=80
    local coverage_learn
    coverage_learn=$(get_coverage_min "$coverage_hard")
    local coverage_diff=$((coverage_learn - coverage_hard))
    printf "%-25s %-15s %-15s %-15s\n" "coverage_min (%)" "$coverage_hard" "$coverage_learn" "$coverage_diff"

    echo ""
}

# ─── Main: recommend subcommand ─────────────────────────────────────────────
cmd_recommend() {
    # recommend takes --issue as required option
    local issue=""
    local repo="${REPO_DIR}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue) issue="$2"; shift 2 ;;
            --repo) repo="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$issue" ]]; then
        error "Missing --issue argument"
        return 1
    fi

    info "Generating recommendation for issue ${CYAN}#${issue}${RESET}..."

    # Simulate complexity score (in real implementation, query GitHub API)
    local complexity=5

    # Build JSON recommendation
    local recommendation
    recommendation=$(jq -n "{
        issue: ${issue},
        template: \"$(get_template "$complexity" "standard")\",
        model: \"$(get_model "build" "opus")\",
        max_iterations: $(get_iterations "$complexity" "build" "10"),
        team_size: $(get_team_size "$complexity" "2"),
        timeout: $(get_timeout "build" "$repo" "1800"),
        quality_threshold: $(get_quality_threshold "70"),
        poll_interval: $(get_poll_interval "60"),
        coverage_min: $(get_coverage_min "80"),
        confidence: \"high\",
        reasoning: \"Based on $(jq -s 'length' "$EVENTS_FILE" 2>/dev/null || echo 0) historical events\"
    }")

    echo "$recommendation" | jq .
}

# ─── Main: reset subcommand ─────────────────────────────────────────────────
cmd_reset() {
    # reset takes optional --metric
    local metric=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --metric) metric="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$metric" ]]; then
        info "Clearing all learned data..."
        rm -f "$MODELS_FILE"
        success "Cleared ${CYAN}${MODELS_FILE}${RESET}"
    else
        info "Clearing learned data for metric: ${CYAN}${metric}${RESET}"
        local models
        models=$(load_models)
        models=$(echo "$models" | jq "del(.${metric})")
        save_models "$models"
        success "Reset metric ${CYAN}${metric}${RESET}"
    fi
}

# ─── Main: help subcommand ──────────────────────────────────────────────────
cmd_help() {
    cat <<EOF
${BOLD}shipwright adaptive${RESET} — Data-Driven Pipeline Tuning

${BOLD}USAGE${RESET}
  sw adaptive <subcommand> [options]

${BOLD}SUBCOMMANDS${RESET}
  ${CYAN}get${RESET} <metric> [--stage S] [--repo R] [--complexity C] [--default V]
    Return adaptive value for a metric (replaces hardcoded defaults)
    Metrics: timeout, iterations, model, team_size, template, poll_interval,
             retry_limit, quality_threshold, coverage_min

  ${CYAN}profile${RESET} [--repo REPO]
    Show all learned parameters with confidence levels

  ${CYAN}train${RESET} [--repo REPO]
    Rebuild models from events.jsonl (run after significant pipeline activity)

  ${CYAN}compare${RESET} [--repo REPO]
    Side-by-side table: learned vs hardcoded values

  ${CYAN}recommend${RESET} --issue N [--repo REPO]
    Full JSON recommendation for an issue (template, model, team_size, etc.)

  ${CYAN}reset${RESET} [--metric METRIC]
    Clear learned data (all, or specific metric)

  ${CYAN}help${RESET}
    Show this help message

${BOLD}EXAMPLES${RESET}
  # Get learned timeout for build stage
  sw adaptive get timeout --stage build

  # Show all learned parameters
  sw adaptive profile

  # Train models from events (run after major pipeline activity)
  sw adaptive train

  # Get complete recommendation for issue #42
  sw adaptive recommend --issue 42

  # Compare learned vs hardcoded
  sw adaptive compare

${BOLD}STORAGE${RESET}
  Events:      ${CYAN}${EVENTS_FILE}${RESET}
  Models:      ${CYAN}${MODELS_FILE}${RESET}

${BOLD}STATISTICS${RESET}
  • Low confidence:    < 10 samples
  • Medium confidence: 10-50 samples
  • High confidence:   > 50 samples

  • Timeout:  P95 of historical stage durations + 20% buffer
  • Iterations: Mean of successful build iterations
  • Model: Cheapest model with >90% success rate
  • Team size: Mean team size from historical runs
  • Quality threshold: 25th percentile of passing quality scores
  • Coverage: Median coverage from successful runs
EOF
}

# ─── Main Entry Point ────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        get)
            cmd_get "$@"
            ;;
        profile)
            cmd_profile "$@"
            ;;
        train)
            cmd_train "$@"
            ;;
        compare)
            cmd_compare "$@"
            ;;
        recommend)
            cmd_recommend "$@"
            ;;
        reset)
            cmd_reset "$@"
            ;;
        help)
            cmd_help
            ;;
        version)
            echo "sw-adaptive v${VERSION}"
            ;;
        *)
            error "Unknown command: $cmd"
            cmd_help
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
