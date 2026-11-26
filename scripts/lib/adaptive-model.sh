#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  adaptive-model.sh — Real-Time Adaptive Model Selection During Build Loop ║
# ║                                                                           ║
# ║  Changes model choice mid-iteration based on real-time signals:          ║
# ║  - Tests passing + converging: downgrade to cheaper model (save cost)    ║
# ║  - Tests failing + same error 2x: escalate to stronger model             ║
# ║  - Convergence score dropping: escalate model                            ║
# ║  - Rate limit hit: fallback to next available model                      ║
# ║                                                                           ║
# ║  Usage: Source from sw-loop.sh, call adaptive_model_select()             ║
# ║  before each Claude invocation in the build loop                         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_ADAPTIVE_MODEL_LOADED:-}" ]] && return 0
_ADAPTIVE_MODEL_LOADED=1

# ─── Defaults ──────────────────────────────────────────────────────────────
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ─── Load helpers ──────────────────────────────────────────────────────────
if [[ "$(type -t info 2>/dev/null)" != "function" ]]; then
  info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
  success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
  warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
  error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
fi
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

# ─── Model Ranking & Escalation Chains ─────────────────────────────────────
MODEL_HIERARCHY=("haiku" "sonnet" "opus")

# ─── Thresholds for Adaptive Behavior ──────────────────────────────────────
ESCALATION_ERROR_THRESHOLD=2      # Escalate after this many same error repeats
DOWNGRADE_SUCCESS_THRESHOLD=3     # Downgrade after this many consecutive successes
CONVERGENCE_DROP_THRESHOLD=10     # Escalate if convergence score drops by this
ESCALATION_COOLDOWN=2             # Wait this many iterations before escalating again
RATE_LIMIT_BACKOFF_SECONDS=60     # Cooldown on rate limit (handled by Claude CLI)

# ─── Initialize adaptive tracking for a pipeline run ──────────────────────
adaptive_model_init() {
    local history_file="${ARTIFACTS_DIR}/adaptive-model-history.json"
    mkdir -p "$ARTIFACTS_DIR"

    # Start fresh history for this pipeline run
    echo "[]" > "${history_file}.tmp.$$"
    mv "${history_file}.tmp.$$" "$history_file"

    # Initialize preferences file if it doesn't exist
    local preferences_file="${HOME}/.shipwright/optimization/model-preferences.json"
    mkdir -p "$(dirname "$preferences_file")"

    if [[ ! -f "$preferences_file" ]]; then
        cat > "$preferences_file" <<'JSON'
{
  "version": "1.0",
  "stage_priors": {},
  "learned_escalations": {},
  "learned_downgrades": {},
  "last_updated": ""
}
JSON
    fi

    emit_event "adaptive_model.init" "artifacts_dir=$ARTIFACTS_DIR" 2>/dev/null || true
}

# ─── Select model based on real-time signals ───────────────────────────────
#
# Inputs:
#   stage: pipeline stage name (optional, default "build")
#   iteration_number: current iteration (0-based)
#   last_test_result: "pass" or "fail"
#   error_count: number of times same error appeared
#   convergence_score: 0-100 quality score
#   current_model: model currently in use
#
# Returns: Selected model (haiku|sonnet|opus) on stdout
#
adaptive_model_select() {
    local stage="${1:-build}"
    local iteration_number="${2:-0}"
    local last_test_result="${3:-unknown}"
    local error_count="${4:-0}"
    local convergence_score="${5:-50}"
    local current_model="${6:-opus}"

    # Defaults
    [[ ! "$iteration_number" =~ ^[0-9]+$ ]] && iteration_number=0
    [[ ! "$error_count" =~ ^[0-9]+$ ]] && error_count=0
    [[ ! "$convergence_score" =~ ^[0-9]+$ ]] && convergence_score=50

    local selected_model="$current_model"
    local reason="no_change"
    local escalated=false
    local downgraded=false

    # First iteration: use default (don't adapt)
    if [[ "$iteration_number" -le 0 ]]; then
        reason="first_iteration"
    # Tests passing + high convergence: consider downgrade for cost savings
    elif [[ "$last_test_result" == "pass" && "$convergence_score" -ge 75 ]]; then
        # Downgrade if we're above haiku
        case "$current_model" in
            opus)
                selected_model="sonnet"
                reason="tests_passing_high_convergence_downgrade_opus_to_sonnet"
                downgraded=true
                ;;
            sonnet)
                selected_model="haiku"
                reason="tests_passing_high_convergence_downgrade_sonnet_to_haiku"
                downgraded=true
                ;;
            *)
                reason="already_at_minimum_model"
                ;;
        esac
    # Tests failing + repeated error: escalate to stronger model
    elif [[ "$last_test_result" == "fail" && "$error_count" -ge "$ESCALATION_ERROR_THRESHOLD" ]]; then
        case "$current_model" in
            haiku)
                selected_model="sonnet"
                reason="test_failure_repeated_error_escalate_haiku_to_sonnet"
                escalated=true
                ;;
            sonnet)
                selected_model="opus"
                reason="test_failure_repeated_error_escalate_sonnet_to_opus"
                escalated=true
                ;;
            opus)
                reason="already_at_maximum_model"
                ;;
        esac
    # Convergence score dropping: escalate to get better analysis
    elif [[ "$iteration_number" -gt 0 && "$convergence_score" -lt 30 ]]; then
        case "$current_model" in
            haiku)
                selected_model="sonnet"
                reason="low_convergence_score_escalate_haiku_to_sonnet"
                escalated=true
                ;;
            sonnet)
                selected_model="opus"
                reason="low_convergence_score_escalate_sonnet_to_opus"
                escalated=true
                ;;
            opus)
                reason="already_at_maximum_model"
                ;;
        esac
    else
        reason="stable_conditions_keep_current"
    fi

    # Record selection
    adaptive_model_record "$iteration_number" "$selected_model" "$last_test_result" \
        "$error_count" "$convergence_score" "$reason" "$escalated" "$downgraded"

    echo "$selected_model"
}

# ─── Record model selection and outcome ────────────────────────────────────
adaptive_model_record() {
    local iteration="${1:-0}"
    local model_used="${2:-opus}"
    local test_result="${3:-unknown}"
    local error_count="${4:-0}"
    local convergence_score="${5:-50}"
    local reason="${6:-unknown}"
    local escalated="${7:-false}"
    local downgraded="${8:-false}"

    [[ ! "$iteration" =~ ^[0-9]+$ ]] && iteration=0
    [[ ! "$error_count" =~ ^[0-9]+$ ]] && error_count=0
    [[ ! "$convergence_score" =~ ^[0-9]+$ ]] && convergence_score=50

    local history_file="${ARTIFACTS_DIR}/adaptive-model-history.json"
    mkdir -p "$ARTIFACTS_DIR"

    # Build record
    local record
    record=$(cat <<JSON
{
  "ts": "$(now_iso)",
  "iteration": $iteration,
  "model": "$model_used",
  "test_result": "$test_result",
  "error_count": $error_count,
  "convergence_score": $convergence_score,
  "reason": "$reason",
  "escalated": $escalated,
  "downgraded": $downgraded
}
JSON
)

    # Append to history (use jq if available)
    local tmp_hist="${history_file}.tmp.$$"
    if command -v jq >/dev/null 2>&1; then
        if jq ". += [$(echo "$record" | jq '.')] " "$history_file" > "$tmp_hist" 2>/dev/null; then
            mv "$tmp_hist" "$history_file"
        else
            rm -f "$tmp_hist"
        fi
    else
        # Fallback: simple append (may not be valid JSON at end of file)
        echo "$record" >> "$history_file"
    fi

    emit_event "adaptive_model.recorded" \
        "iteration=$iteration" \
        "model=$model_used" \
        "test_result=$test_result" \
        "reason=$reason" \
        "escalated=$escalated" \
        "downgraded=$downgraded" 2>/dev/null || true
}

# ─── Learn from history after pipeline completes ───────────────────────────
#
# Analyzes adaptive history to answer: which model changes helped?
# Writes learned preferences to optimization/model-preferences.json
#
adaptive_model_learn() {
    local history_file="${ARTIFACTS_DIR}/adaptive-model-history.json"

    if [[ ! -f "$history_file" ]]; then
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        warn "jq required for adaptive model learning"
        return 1
    fi

    local preferences_file="${HOME}/.shipwright/optimization/model-preferences.json"
    mkdir -p "$(dirname "$preferences_file")"

    # Count model transitions and their outcomes
    local escalation_success=0
    local escalation_total=0
    local downgrade_success=0
    local downgrade_total=0

    # Parse history: look for escalations/downgrades followed by success
    if [[ -f "$history_file" ]]; then
        # Count escalations that were followed by pass
        escalation_total=$(jq '[.[] | select(.escalated == true)] | length' "$history_file" 2>/dev/null || echo "0")
        escalation_success=$(jq '[.[] | select(.escalated == true and .test_result == "pass")] | length' "$history_file" 2>/dev/null || echo "0")

        # Count downgrades that maintained pass
        downgrade_total=$(jq '[.[] | select(.downgraded == true)] | length' "$history_file" 2>/dev/null || echo "0")
        downgrade_success=$(jq '[.[] | select(.downgraded == true and .test_result == "pass")] | length' "$history_file" 2>/dev/null || echo "0")
    fi

    # Calculate effectiveness rates
    local escalation_rate=0
    local downgrade_rate=0

    if [[ "$escalation_total" -gt 0 ]]; then
        escalation_rate=$((escalation_success * 100 / escalation_total))
    fi

    if [[ "$downgrade_total" -gt 0 ]]; then
        downgrade_rate=$((downgrade_success * 100 / downgrade_total))
    fi

    # Update preferences file
    local tmp_prefs
    tmp_prefs=$(mktemp)
    trap "rm -f '$tmp_prefs'; trap - RETURN" RETURN

    jq \
        --argjson esc_success "$escalation_success" \
        --argjson esc_total "$escalation_total" \
        --argjson down_success "$downgrade_success" \
        --argjson down_total "$downgrade_total" \
        --argjson esc_rate "$escalation_rate" \
        --argjson down_rate "$downgrade_rate" \
        --arg timestamp "$(now_iso)" \
        '.learned_escalations = {
           "total_attempts": $esc_total,
           "successful": $esc_success,
           "success_rate": $esc_rate
         } |
         .learned_downgrades = {
           "total_attempts": $down_total,
           "successful": $down_success,
           "success_rate": $down_rate
         } |
         .last_updated = $timestamp' \
        "$preferences_file" > "$tmp_prefs" 2>/dev/null

    if [[ -f "$tmp_prefs" ]]; then
        mv "$tmp_prefs" "$preferences_file"
        success "Learned model preferences: escalation=${escalation_rate}% success, downgrade=${downgrade_rate}% success"
        emit_event "adaptive_model.learned" \
            "escalation_rate=$escalation_rate" \
            "downgrade_rate=$downgrade_rate" 2>/dev/null || true
    fi
}

# ─── Show adaptive selection stats ─────────────────────────────────────────
#
# Reports on model usage distribution, cost savings, and effectiveness
#
adaptive_model_report() {
    local history_file="${ARTIFACTS_DIR}/adaptive-model-history.json"

    if [[ ! -f "$history_file" ]]; then
        info "No adaptive model history yet"
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        error "jq required for reports"
        return 1
    fi

    echo ""
    info "Adaptive Model Selection Report"
    echo ""

    # Model usage distribution
    echo "▸ Model Usage Distribution:"
    jq -s 'group_by(.model) | map({
        model: .[0].model,
        count: length,
        percentage: ((length / (. | length)) * 100 | round)
    }) | sort_by(.count) | reverse | .[]' "$history_file" 2>/dev/null | \
    jq -r '"  \(.model): \(.count) iterations (\(.percentage)%)"' 2>/dev/null || true

    echo ""
    echo "▸ Adaptive Actions:"
    local escalations
    escalations=$(jq '[.[] | select(.escalated == true)] | length' "$history_file" 2>/dev/null || echo "0")
    local downgrades
    downgrades=$(jq '[.[] | select(.downgraded == true)] | length' "$history_file" 2>/dev/null || echo "0")

    echo "  Escalations: $escalations"
    echo "  Downgrades: $downgrades"

    # Effectiveness
    if [[ "$escalations" -gt 0 ]]; then
        local esc_success
        esc_success=$(jq '[.[] | select(.escalated == true and .test_result == "pass")] | length' "$history_file" 2>/dev/null || echo "0")
        local esc_rate=$((esc_success * 100 / escalations))
        echo "  Escalation Success Rate: ${esc_rate}% ($esc_success/$escalations)"
    fi

    if [[ "$downgrades" -gt 0 ]]; then
        local down_success
        down_success=$(jq '[.[] | select(.downgraded == true and .test_result == "pass")] | length' "$history_file" 2>/dev/null || echo "0")
        local down_rate=$((down_success * 100 / downgrades))
        echo "  Downgrade Success Rate: ${down_rate}% ($down_success/$downgrades)"
    fi

    # Test result summary
    echo ""
    echo "▸ Test Result Summary:"
    jq -s 'group_by(.test_result) | map({
        result: .[0].test_result,
        count: length
    }) | .[]' "$history_file" 2>/dev/null | \
    jq -r '"  \(.result): \(.count)"' 2>/dev/null || true

    # Top reasons
    echo ""
    echo "▸ Top Adaptation Reasons:"
    jq -s 'group_by(.reason) | map({
        reason: .[0].reason,
        count: length
    }) | sort_by(.count) | reverse | .[0:5] | .[]' "$history_file" 2>/dev/null | \
    jq -r '"  \(.reason): \(.count) times"' 2>/dev/null || true

    echo ""
}

# ─── Load learned preferences from previous runs ────────────────────────────
adaptive_model_apply_learned_preferences() {
    local preferences_file="${HOME}/.shipwright/optimization/model-preferences.json"

    if [[ ! -f "$preferences_file" ]]; then
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        return 0
    fi

    # Load learned escalation/downgrade rates (could affect future decisions)
    local learned_escalation_rate
    learned_escalation_rate=$(jq -r '.learned_escalations.success_rate // 0' "$preferences_file" 2>/dev/null || echo "0")

    local learned_downgrade_rate
    learned_downgrade_rate=$(jq -r '.learned_downgrades.success_rate // 0' "$preferences_file" 2>/dev/null || echo "0")

    # Could use these to adjust thresholds dynamically in future runs
    # For now, just log them
    if [[ -n "$learned_escalation_rate" && "$learned_escalation_rate" -gt 0 ]]; then
        emit_event "adaptive_model.using_learned_preferences" \
            "escalation_rate=$learned_escalation_rate" \
            "downgrade_rate=$learned_downgrade_rate" 2>/dev/null || true
    fi
}

# ─── Export functions for use by sw-loop.sh ───────────────────────────────
export -f adaptive_model_init
export -f adaptive_model_select
export -f adaptive_model_record
export -f adaptive_model_learn
export -f adaptive_model_report
export -f adaptive_model_apply_learned_preferences
