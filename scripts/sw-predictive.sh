#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright predictive — Predictive & Proactive Intelligence            ║
# ║  Risk assessment · Anomaly detection · AI patrol · Failure prevention   ║
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

info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

emit_event() {
    local event_type="$1"; shift
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"; local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            val="${val//\"/\\\"}"; json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Intelligence Engine (optional) ────────────────────────────────────────
INTELLIGENCE_AVAILABLE=false
if [[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]]; then
    source "$SCRIPT_DIR/sw-intelligence.sh"
    INTELLIGENCE_AVAILABLE=true
fi

# ─── Storage ───────────────────────────────────────────────────────────────
BASELINES_DIR="${HOME}/.shipwright/baselines"
ANOMALY_THRESHOLD="${ANOMALY_THRESHOLD:-3.0}"

# ═══════════════════════════════════════════════════════════════════════════════
# RISK ASSESSMENT
# ═══════════════════════════════════════════════════════════════════════════════

# predict_pipeline_risk <issue_json> [repo_context]
# Pre-pipeline risk assessment. Returns JSON with overall_risk, failure_stages, preventative_actions.
predict_pipeline_risk() {
    local issue_json="${1:-"{}"}"
    local repo_context="${2:-}"

    if [[ "$INTELLIGENCE_AVAILABLE" == "true" ]] && command -v _intelligence_call_claude &>/dev/null; then
        local prompt
        prompt="Analyze this issue for pipeline risk. Return ONLY valid JSON.

Issue: ${issue_json}
Repo context: ${repo_context:-none}

Return JSON format:
{\"overall_risk\": <0-100>, \"failure_stages\": [{\"stage\": \"<name>\", \"risk\": <0-100>, \"reason\": \"<why>\"}], \"preventative_actions\": [\"<action>\"]}"

        local result
        result=$(_intelligence_call_claude "$prompt" 2>/dev/null || echo "")

        if [[ -n "$result" ]] && echo "$result" | jq -e '.overall_risk' &>/dev/null; then
            # Validate range
            local risk
            risk=$(echo "$result" | jq '.overall_risk')
            if [[ "$risk" -ge 0 && "$risk" -le 100 ]]; then
                emit_event "prediction.risk_assessed" "risk=${risk}" "source=ai"
                echo "$result"
                return 0
            fi
        fi
    fi

    # Fallback: heuristic risk assessment
    local risk=50
    local reason="Default medium risk — no AI analysis available"

    # Bump risk if issue mentions complex keywords
    if echo "$issue_json" | grep -qiE "refactor|migration|breaking|security|deploy"; then
        risk=70
        reason="Keywords suggest elevated complexity"
    fi

    local result_json
    result_json=$(jq -n \
        --argjson risk "$risk" \
        --arg reason "$reason" \
        '{
            overall_risk: $risk,
            failure_stages: [{stage: "build", risk: $risk, reason: $reason}],
            preventative_actions: ["Review scope before starting", "Ensure test coverage"]
        }')

    emit_event "prediction.risk_assessed" "risk=${risk}" "source=heuristic"
    echo "$result_json"
}

# ═══════════════════════════════════════════════════════════════════════════════
# AI PATROL ANALYSIS
# ═══════════════════════════════════════════════════════════════════════════════

# patrol_ai_analyze <sample_files_list> [recent_git_log]
# Reads sampled source files and asks Claude to analyze for issues.
# Returns structured findings array.
patrol_ai_analyze() {
    local sample_files="${1:-}"
    local git_log="${2:-}"

    if [[ -z "$sample_files" ]]; then
        echo '[]'
        return 0
    fi

    # Collect file contents (max 5 files, first 100 lines each)
    local file_contents=""
    local file_count=0
    local IFS_ORIG="$IFS"
    IFS=$'\n'
    for file_path in $sample_files; do
        IFS="$IFS_ORIG"
        if [[ "$file_count" -ge 5 ]]; then
            break
        fi
        if [[ -f "$file_path" ]]; then
            file_contents="${file_contents}
--- ${file_path} ---
$(head -100 "$file_path" 2>/dev/null || true)
"
            file_count=$((file_count + 1))
        fi
    done
    IFS="$IFS_ORIG"

    if [[ -z "$file_contents" ]]; then
        echo '[]'
        return 0
    fi

    if [[ "$INTELLIGENCE_AVAILABLE" != "true" ]] || ! command -v _intelligence_call_claude &>/dev/null; then
        echo '[]'
        return 0
    fi

    local prompt
    prompt="Analyze these source files for issues. Return ONLY a JSON array.
Focus on high/critical severity only. Categories: security, performance, architecture, testing.

Files:
${file_contents}

Recent git log:
${git_log:-none}

Return format: [{\"severity\": \"high\", \"category\": \"security\", \"finding\": \"...\", \"recommendation\": \"...\"}]
Only return findings with severity 'high' or 'critical'. Return [] if nothing significant found."

    local result
    result=$(_intelligence_call_claude "$prompt" 2>/dev/null || echo "")

    if [[ -n "$result" ]] && echo "$result" | jq -e 'type == "array"' &>/dev/null; then
        # Filter to only high/critical findings
        local filtered
        filtered=$(echo "$result" | jq '[.[] | select(.severity == "high" or .severity == "critical")]')

        local count
        count=$(echo "$filtered" | jq 'length')

        local i=0
        while [[ "$i" -lt "$count" ]]; do
            local sev cat finding
            sev=$(echo "$filtered" | jq -r ".[$i].severity")
            cat=$(echo "$filtered" | jq -r ".[$i].category")
            finding=$(echo "$filtered" | jq -r ".[$i].finding" | cut -c1-80)
            emit_event "patrol.ai_finding" "severity=${sev}" "category=${cat}" "finding=${finding}"
            i=$((i + 1))
        done

        echo "$filtered"
        return 0
    fi

    # Dismissed — no valid result
    emit_event "patrol.ai_dismissed" "reason=invalid_response"
    echo '[]'
}

# ═══════════════════════════════════════════════════════════════════════════════
# ANOMALY DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

# predict_detect_anomaly <stage> <metric_name> <current_value> [baseline_file]
# Compare current metric against baseline. Returns "critical", "warning", or "normal".
predict_detect_anomaly() {
    local stage="${1:-}"
    local metric_name="${2:-}"
    local current_value="${3:-0}"
    local baseline_file="${4:-}"

    if [[ -z "$stage" || -z "$metric_name" ]]; then
        error "Usage: predict_detect_anomaly <stage> <metric_name> <current_value> [baseline_file]"
        return 1
    fi

    # Default baseline file
    if [[ -z "$baseline_file" ]]; then
        mkdir -p "$BASELINES_DIR"
        baseline_file="${BASELINES_DIR}/default.json"
    fi

    # Read baseline for this stage+metric
    local key="${stage}.${metric_name}"
    local baseline_value=0

    if [[ -f "$baseline_file" ]]; then
        baseline_value=$(jq -r --arg key "$key" '.[$key].value // 0' "$baseline_file" 2>/dev/null || echo "0")
    fi

    # No baseline yet — treat as normal
    if [[ "$baseline_value" == "0" || "$baseline_value" == "null" ]]; then
        echo "normal"
        return 0
    fi

    # Calculate thresholds using awk for floating-point
    local critical_threshold warning_threshold
    critical_threshold=$(awk "BEGIN{printf \"%.2f\", ${baseline_value} * ${ANOMALY_THRESHOLD}}")
    warning_threshold=$(awk "BEGIN{printf \"%.2f\", ${baseline_value} * 2.0}")

    local severity="normal"

    if awk "BEGIN{exit !(${current_value} > ${critical_threshold})}" 2>/dev/null; then
        severity="critical"
    elif awk "BEGIN{exit !(${current_value} > ${warning_threshold})}" 2>/dev/null; then
        severity="warning"
    fi

    if [[ "$severity" != "normal" ]]; then
        emit_event "prediction.anomaly" \
            "stage=${stage}" \
            "metric=${metric_name}" \
            "value=${current_value}" \
            "baseline=${baseline_value}" \
            "severity=${severity}"
    fi

    echo "$severity"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PREVENTATIVE INJECTION
# ═══════════════════════════════════════════════════════════════════════════════

# predict_inject_prevention <stage> <issue_json> [memory_context]
# Returns prevention text based on memory patterns relevant to this stage.
predict_inject_prevention() {
    local stage="${1:-}"
    local issue_json="${2:-"{}"}"
    local memory_context="${3:-}"

    if [[ -z "$stage" ]]; then
        return 0
    fi

    # If memory context was passed directly, search it
    if [[ -n "$memory_context" ]]; then
        local prevention_text=""

        # Look for failure patterns mentioning this stage
        local failures
        failures=$(echo "$memory_context" | grep -i "\\[$stage\\]" 2>/dev/null || true)

        if [[ -n "$failures" ]]; then
            prevention_text="WARNING: Previous similar issues failed at ${stage} stage."
            prevention_text="${prevention_text}
Known patterns:"

            local line_count=0
            while IFS= read -r line; do
                if [[ "$line_count" -ge 5 ]]; then
                    break
                fi
                prevention_text="${prevention_text}
  - ${line}"
                line_count=$((line_count + 1))
            done <<EOF
${failures}
EOF
            prevention_text="${prevention_text}
Recommended: Review these patterns before proceeding."

            emit_event "prediction.prevented" "stage=${stage}" "patterns=${line_count}"
            echo "$prevention_text"
            return 0
        fi
    fi

    # Try sourcing memory for context if available
    if [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
        local mem_context
        mem_context=$(bash "$SCRIPT_DIR/sw-memory.sh" inject "$stage" 2>/dev/null || true)

        if [[ -n "$mem_context" ]] && echo "$mem_context" | grep -qi "failure\|pattern\|avoid"; then
            local pattern_lines
            pattern_lines=$(echo "$mem_context" | grep -iE "^\s*-\s*\[" | head -3 || true)

            if [[ -n "$pattern_lines" ]]; then
                local prevention_text="WARNING: Memory system flagged relevant patterns for ${stage}:
${pattern_lines}
Recommended: Apply known fixes proactively."

                emit_event "prediction.prevented" "stage=${stage}" "source=memory"
                echo "$prevention_text"
                return 0
            fi
        fi
    fi

    # No relevant patterns found
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# BASELINE MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

# predict_update_baseline <stage> <metric_name> <value> [baseline_file]
# Exponential moving average: new = 0.9 * old + 0.1 * current
predict_update_baseline() {
    local stage="${1:-}"
    local metric_name="${2:-}"
    local value="${3:-0}"
    local baseline_file="${4:-}"

    if [[ -z "$stage" || -z "$metric_name" ]]; then
        error "Usage: predict_update_baseline <stage> <metric_name> <value> [baseline_file]"
        return 1
    fi

    # Default baseline file
    if [[ -z "$baseline_file" ]]; then
        mkdir -p "$BASELINES_DIR"
        baseline_file="${BASELINES_DIR}/default.json"
    fi

    local key="${stage}.${metric_name}"

    # Initialize file if missing
    if [[ ! -f "$baseline_file" ]]; then
        mkdir -p "$(dirname "$baseline_file")"
        echo '{}' > "$baseline_file"
    fi

    # Read current baseline
    local old_value old_count
    old_value=$(jq -r --arg key "$key" '.[$key].value // 0' "$baseline_file" 2>/dev/null || echo "0")
    old_count=$(jq -r --arg key "$key" '.[$key].count // 0' "$baseline_file" 2>/dev/null || echo "0")

    # Calculate new baseline using EMA
    local new_value new_count
    new_count=$((old_count + 1))

    if [[ "$old_value" == "0" || "$old_value" == "null" ]]; then
        # First data point — use raw value
        new_value="$value"
    else
        # Exponential moving average: 0.9 * old + 0.1 * new
        new_value=$(awk "BEGIN{printf \"%.2f\", 0.9 * ${old_value} + 0.1 * ${value}}")
    fi

    local updated_at
    updated_at="$(now_iso)"

    # Atomic write
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg key "$key" \
       --argjson val "$new_value" \
       --argjson cnt "$new_count" \
       --arg ts "$updated_at" \
       '.[$key] = {value: $val, count: $cnt, updated: $ts}' \
       "$baseline_file" > "$tmp_file" && mv "$tmp_file" "$baseline_file"
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELP
# ═══════════════════════════════════════════════════════════════════════════════

show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}━━━ shipwright predictive ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "  ${BOLD}Risk Assessment${RESET}"
    echo -e "    ${CYAN}shipwright predictive risk${RESET} <issue_json> [repo_context]"
    echo -e "    Pre-pipeline risk scoring with AI analysis"
    echo ""
    echo -e "  ${BOLD}Anomaly Detection${RESET}"
    echo -e "    ${CYAN}shipwright predictive anomaly${RESET} <stage> <metric> <value> [baseline_file]"
    echo -e "    Compare metrics against running baselines"
    echo ""
    echo -e "  ${BOLD}AI Patrol${RESET}"
    echo -e "    ${CYAN}shipwright predictive patrol${RESET} <files_list> [git_log]"
    echo -e "    AI-driven code analysis for high-severity issues"
    echo ""
    echo -e "  ${BOLD}Baseline Management${RESET}"
    echo -e "    ${CYAN}shipwright predictive baseline${RESET} <stage> <metric> <value> [baseline_file]"
    echo -e "    Update running metric baselines (EMA)"
    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true
    case "$cmd" in
        risk)        predict_pipeline_risk "$@" ;;
        anomaly)     predict_detect_anomaly "$@" ;;
        patrol)      patrol_ai_analyze "$@" ;;
        baseline)    predict_update_baseline "$@" ;;
        help|--help|-h) show_help ;;
        *) error "Unknown command: $cmd"; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
