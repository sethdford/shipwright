#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright predictive — Predictive & Proactive Intelligence            ║
# ║  Risk assessment · Anomaly detection · AI patrol · Failure prevention   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.0"
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
OPTIMIZATION_DIR="${HOME}/.shipwright/optimization"
DEFAULT_ANOMALY_THRESHOLD=3.0
DEFAULT_WARNING_MULTIPLIER=2.0
DEFAULT_EMA_ALPHA=0.1
ANOMALY_THRESHOLD="${ANOMALY_THRESHOLD:-$DEFAULT_ANOMALY_THRESHOLD}"

# ─── Adaptive Threshold Helpers ───────────────────────────────────────────

# _predictive_get_repo_hash
# Returns a short hash for the current repo (for per-repo config isolation)
_predictive_get_repo_hash() {
    local repo_root
    repo_root=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$REPO_DIR")
    compute_md5 --string "$repo_root"
}

# _predictive_get_anomaly_threshold <metric_name>
# Returns per-metric anomaly threshold from config, or default
_predictive_get_anomaly_threshold() {
    local metric_name="${1:-}"
    local repo_hash
    repo_hash=$(_predictive_get_repo_hash)
    local thresholds_file="${BASELINES_DIR}/${repo_hash}/anomaly-thresholds.json"

    if [[ -n "$metric_name" && -f "$thresholds_file" ]]; then
        local threshold
        threshold=$(jq -r --arg m "$metric_name" '.[$m].critical_multiplier // empty' "$thresholds_file" 2>/dev/null || true)
        if [[ -n "$threshold" && "$threshold" != "null" ]]; then
            echo "$threshold"
            return 0
        fi
    fi
    echo "$DEFAULT_ANOMALY_THRESHOLD"
}

# _predictive_get_warning_multiplier <metric_name>
# Returns per-metric warning multiplier from config, or default
_predictive_get_warning_multiplier() {
    local metric_name="${1:-}"
    local repo_hash
    repo_hash=$(_predictive_get_repo_hash)
    local thresholds_file="${BASELINES_DIR}/${repo_hash}/anomaly-thresholds.json"

    if [[ -n "$metric_name" && -f "$thresholds_file" ]]; then
        local multiplier
        multiplier=$(jq -r --arg m "$metric_name" '.[$m].warning_multiplier // empty' "$thresholds_file" 2>/dev/null || true)
        if [[ -n "$multiplier" && "$multiplier" != "null" ]]; then
            echo "$multiplier"
            return 0
        fi
    fi
    echo "$DEFAULT_WARNING_MULTIPLIER"
}

# _predictive_get_ema_alpha
# Returns EMA alpha from per-repo config, or default
_predictive_get_ema_alpha() {
    local repo_hash
    repo_hash=$(_predictive_get_repo_hash)
    local ema_config="${BASELINES_DIR}/${repo_hash}/ema-config.json"

    if [[ -f "$ema_config" ]]; then
        local alpha
        alpha=$(jq -r '.alpha // empty' "$ema_config" 2>/dev/null || true)
        if [[ -n "$alpha" && "$alpha" != "null" ]]; then
            echo "$alpha"
            return 0
        fi
    fi
    echo "$DEFAULT_EMA_ALPHA"
}

# _predictive_get_risk_keywords
# Returns JSON object of keyword→weight mapping from config, or empty
_predictive_get_risk_keywords() {
    local keywords_file="${OPTIMIZATION_DIR}/risk-keywords.json"
    if [[ -f "$keywords_file" ]]; then
        local content
        content=$(jq '.' "$keywords_file" 2>/dev/null || true)
        if [[ -n "$content" && "$content" != "null" ]]; then
            echo "$content"
            return 0
        fi
    fi
    echo ""
}

# _predictive_record_anomaly <stage> <metric_name> <severity> <value> <baseline>
# Records an anomaly detection event for false-alarm tracking
_predictive_record_anomaly() {
    local stage="${1:-}"
    local metric_name="${2:-}"
    local severity="${3:-}"
    local value="${4:-0}"
    local baseline="${5:-0}"

    local repo_hash
    repo_hash=$(_predictive_get_repo_hash)
    local tracking_file="${BASELINES_DIR}/${repo_hash}/anomaly-tracking.jsonl"
    mkdir -p "${BASELINES_DIR}/${repo_hash}"

    local record
    record=$(jq -c -n \
        --arg ts "$(now_iso)" \
        --argjson epoch "$(now_epoch)" \
        --arg stage "$stage" \
        --arg metric "$metric_name" \
        --arg severity "$severity" \
        --argjson value "$value" \
        --argjson baseline "$baseline" \
        '{ts: $ts, ts_epoch: $epoch, stage: $stage, metric: $metric, severity: $severity, value: $value, baseline: $baseline, confirmed: null}')
    echo "$record" >> "$tracking_file"
}

# predictive_confirm_anomaly <stage> <metric_name> <was_real_failure>
# After pipeline completes, confirm whether anomaly predicted a real failure
predictive_confirm_anomaly() {
    local stage="${1:-}"
    local metric_name="${2:-}"
    local was_real="${3:-false}"

    local repo_hash
    repo_hash=$(_predictive_get_repo_hash)
    local tracking_file="${BASELINES_DIR}/${repo_hash}/anomaly-tracking.jsonl"

    [[ -f "$tracking_file" ]] || return 0

    # Find the most recent unconfirmed anomaly for this stage+metric
    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-anomaly-confirm.XXXXXX")
    local found=false

    # Process file in reverse to find most recent unconfirmed
    while IFS= read -r line; do
        local line_stage line_metric line_confirmed
        line_stage=$(echo "$line" | jq -r '.stage // ""' 2>/dev/null || true)
        line_metric=$(echo "$line" | jq -r '.metric // ""' 2>/dev/null || true)
        line_confirmed=$(echo "$line" | jq -r '.confirmed // "null"' 2>/dev/null || true)

        if [[ "$line_stage" == "$stage" && "$line_metric" == "$metric_name" && "$line_confirmed" == "null" && "$found" == "false" ]]; then
            # Update this entry
            echo "$line" | jq -c --arg c "$was_real" '.confirmed = ($c == "true")' >> "$tmp_file"
            found=true
        else
            echo "$line" >> "$tmp_file"
        fi
    done < "$tracking_file"

    if [[ "$found" == "true" ]]; then
        mv "$tmp_file" "$tracking_file"
    else
        rm -f "$tmp_file"
    fi

    # Update false-alarm rate and adjust thresholds
    _predictive_update_alarm_rates "$metric_name"
}

# _predictive_update_alarm_rates <metric_name>
# Recalculates false-alarm rate for a metric and adjusts thresholds
_predictive_update_alarm_rates() {
    local metric_name="${1:-}"
    [[ -z "$metric_name" ]] && return 0

    local repo_hash
    repo_hash=$(_predictive_get_repo_hash)
    local tracking_file="${BASELINES_DIR}/${repo_hash}/anomaly-tracking.jsonl"
    local thresholds_file="${BASELINES_DIR}/${repo_hash}/anomaly-thresholds.json"

    [[ -f "$tracking_file" ]] || return 0

    # Count confirmed entries for this metric
    local total_confirmed=0
    local true_positives=0
    local false_positives=0

    while IFS= read -r line; do
        local line_metric line_confirmed
        line_metric=$(echo "$line" | jq -r '.metric // ""' 2>/dev/null || true)
        line_confirmed=$(echo "$line" | jq -r '.confirmed // "null"' 2>/dev/null || true)

        [[ "$line_metric" != "$metric_name" ]] && continue
        [[ "$line_confirmed" == "null" ]] && continue

        total_confirmed=$((total_confirmed + 1))
        if [[ "$line_confirmed" == "true" ]]; then
            true_positives=$((true_positives + 1))
        else
            false_positives=$((false_positives + 1))
        fi
    done < "$tracking_file"

    # Need at least 5 confirmed anomalies to adjust
    [[ "$total_confirmed" -lt 5 ]] && return 0

    local precision
    precision=$(awk -v tp="$true_positives" -v total="$total_confirmed" 'BEGIN { printf "%.2f", (tp / total) * 100 }')

    # Initialize thresholds file if missing
    mkdir -p "${BASELINES_DIR}/${repo_hash}"
    if [[ ! -f "$thresholds_file" ]]; then
        echo '{}' > "$thresholds_file"
    fi

    # Adjust thresholds to maintain 90%+ precision
    local current_critical current_warning
    current_critical=$(jq -r --arg m "$metric_name" '.[$m].critical_multiplier // 3.0' "$thresholds_file" 2>/dev/null || echo "3.0")
    current_warning=$(jq -r --arg m "$metric_name" '.[$m].warning_multiplier // 2.0' "$thresholds_file" 2>/dev/null || echo "2.0")

    local new_critical="$current_critical"
    local new_warning="$current_warning"

    if awk -v p="$precision" 'BEGIN { exit !(p < 90) }' 2>/dev/null; then
        # Too many false alarms — loosen thresholds (increase multipliers)
        new_critical=$(awk -v c="$current_critical" 'BEGIN { v = c * 1.1; if (v > 10.0) v = 10.0; printf "%.2f", v }')
        new_warning=$(awk -v w="$current_warning" 'BEGIN { v = w * 1.1; if (v > 8.0) v = 8.0; printf "%.2f", v }')
    elif awk -v p="$precision" 'BEGIN { exit !(p > 95) }' 2>/dev/null; then
        # Very high precision — can tighten slightly (decrease multipliers)
        new_critical=$(awk -v c="$current_critical" 'BEGIN { v = c * 0.95; if (v < 1.5) v = 1.5; printf "%.2f", v }')
        new_warning=$(awk -v w="$current_warning" 'BEGIN { v = w * 0.95; if (v < 1.2) v = 1.2; printf "%.2f", v }')
    fi

    # Atomic write
    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-anomaly-thresh.XXXXXX")
    jq --arg m "$metric_name" \
       --argjson crit "$new_critical" \
       --argjson warn "$new_warning" \
       --argjson precision "$precision" \
       --argjson tp "$true_positives" \
       --argjson fp "$false_positives" \
       --arg ts "$(now_iso)" \
       '.[$m] = {critical_multiplier: $crit, warning_multiplier: $warn, precision: $precision, true_positives: $tp, false_positives: $fp, updated: $ts}' \
       "$thresholds_file" > "$tmp_file" && mv "$tmp_file" "$thresholds_file" || rm -f "$tmp_file"

    emit_event "predictive.threshold_adjusted" \
        "metric=$metric_name" \
        "precision=$precision" \
        "critical=$new_critical" \
        "warning=$new_warning"
}

# ─── GitHub Risk Factors ──────────────────────────────────────────────────

_predictive_github_risk_factors() {
    local issue_json="$1"
    local risk_factors='{"security_risk": 0, "churn_risk": 0, "contributor_risk": 0, "recurrence_risk": 0}'

    type _gh_detect_repo &>/dev/null 2>&1 || { echo "$risk_factors"; return 0; }
    _gh_detect_repo 2>/dev/null || { echo "$risk_factors"; return 0; }

    local owner="${GH_OWNER:-}" repo="${GH_REPO:-}"
    [[ -z "$owner" || -z "$repo" ]] && { echo "$risk_factors"; return 0; }

    # Security risk: active alerts
    local sec_risk=0
    if type gh_security_alerts &>/dev/null 2>&1; then
        local alert_count
        alert_count=$(gh_security_alerts "$owner" "$repo" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        if [[ "${alert_count:-0}" -gt 10 ]]; then
            sec_risk=30
        elif [[ "${alert_count:-0}" -gt 5 ]]; then
            sec_risk=20
        elif [[ "${alert_count:-0}" -gt 0 ]]; then
            sec_risk=10
        fi
    fi

    # Recurrence risk: similar past issues
    local rec_risk=0
    if type gh_similar_issues &>/dev/null 2>&1; then
        local title
        title=$(echo "$issue_json" | jq -r '.title // ""' 2>/dev/null | head -c 100)
        if [[ -n "$title" ]]; then
            local similar_count
            similar_count=$(gh_similar_issues "$owner" "$repo" "$title" 5 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
            if [[ "${similar_count:-0}" -gt 3 ]]; then
                rec_risk=25
            elif [[ "${similar_count:-0}" -gt 0 ]]; then
                rec_risk=10
            fi
        fi
    fi

    # Contributor risk: low contributor count = bus factor risk
    local cont_risk=0
    if type gh_contributors &>/dev/null 2>&1; then
        local contributor_count
        contributor_count=$(gh_contributors "$owner" "$repo" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        if [[ "${contributor_count:-0}" -lt 2 ]]; then
            cont_risk=15
        fi
    fi

    jq -n --argjson sec "$sec_risk" --argjson rec "$rec_risk" --argjson cont "$cont_risk" \
        '{security_risk: $sec, churn_risk: 0, contributor_risk: $cont, recurrence_risk: $rec}'
}

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

    # Check for learned keyword weights first, fall back to hardcoded
    local keywords_json
    keywords_json=$(_predictive_get_risk_keywords)

    if [[ -n "$keywords_json" ]]; then
        # Use learned keyword→weight mapping
        local total_weight=0
        local matched_keywords=""
        local issue_lower
        issue_lower=$(echo "$issue_json" | tr '[:upper:]' '[:lower:]')

        while IFS= read -r keyword; do
            [[ -z "$keyword" ]] && continue
            local kw_lower
            kw_lower=$(echo "$keyword" | tr '[:upper:]' '[:lower:]')
            if echo "$issue_lower" | grep -q "$kw_lower" 2>/dev/null; then
                local weight
                weight=$(echo "$keywords_json" | jq -r --arg k "$keyword" '.[$k] // 0' 2>/dev/null || echo "0")
                total_weight=$(awk -v tw="$total_weight" -v w="$weight" 'BEGIN { printf "%.0f", tw + w }')
                matched_keywords="${matched_keywords}${keyword}, "
            fi
        done < <(echo "$keywords_json" | jq -r 'keys[]' 2>/dev/null || true)

        if [[ "$total_weight" -gt 0 ]]; then
            # Clamp risk to 0-100
            risk=$(awk -v base=50 -v tw="$total_weight" 'BEGIN { v = base + tw; if (v > 100) v = 100; if (v < 0) v = 0; printf "%.0f", v }')
            reason="Learned keyword weights: ${matched_keywords%%, }"
        fi
    else
        # Default hardcoded keyword check
        if echo "$issue_json" | grep -qiE "refactor|migration|breaking|security|deploy"; then
            risk=70
            reason="Keywords suggest elevated complexity"
        fi
    fi

    # Add GitHub risk factors if available
    local gh_factors
    gh_factors=$(_predictive_github_risk_factors "$issue_json" 2>/dev/null || echo '{"security_risk": 0, "churn_risk": 0, "contributor_risk": 0, "recurrence_risk": 0}')
    local gh_sec gh_rec gh_cont
    gh_sec=$(echo "$gh_factors" | jq -r '.security_risk // 0' 2>/dev/null || echo "0")
    gh_rec=$(echo "$gh_factors" | jq -r '.recurrence_risk // 0' 2>/dev/null || echo "0")
    gh_cont=$(echo "$gh_factors" | jq -r '.contributor_risk // 0' 2>/dev/null || echo "0")
    local gh_total=$((gh_sec + gh_rec + gh_cont))
    if [[ "$gh_total" -gt 0 ]]; then
        risk=$(awk -v r="$risk" -v g="$gh_total" 'BEGIN { v = r + g; if (v > 100) v = 100; printf "%.0f", v }')
        info "Risk scoring: GitHub factors — security=$gh_sec, recurrence=$gh_rec, contributor=$gh_cont"
    fi

    local result_json
    result_json=$(jq -n \
        --argjson risk "$risk" \
        --arg reason "$reason" \
        --argjson gh_factors "$gh_factors" \
        '{
            overall_risk: $risk,
            failure_stages: [{stage: "build", risk: $risk, reason: $reason}],
            preventative_actions: ["Review scope before starting", "Ensure test coverage"],
            github_risk_factors: $gh_factors
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

    # Get per-metric thresholds (adaptive or default)
    local metric_critical_mult metric_warning_mult
    metric_critical_mult=$(_predictive_get_anomaly_threshold "$metric_name")
    metric_warning_mult=$(_predictive_get_warning_multiplier "$metric_name")

    # Calculate thresholds using awk for floating-point
    local critical_threshold warning_threshold
    critical_threshold=$(awk -v bv="$baseline_value" -v m="$metric_critical_mult" 'BEGIN{printf "%.2f", bv * m}')
    warning_threshold=$(awk -v bv="$baseline_value" -v m="$metric_warning_mult" 'BEGIN{printf "%.2f", bv * m}')

    local severity="normal"

    if awk -v cv="$current_value" -v ct="$critical_threshold" 'BEGIN{exit !(cv > ct)}' 2>/dev/null; then
        severity="critical"
    elif awk -v cv="$current_value" -v wt="$warning_threshold" 'BEGIN{exit !(cv > wt)}' 2>/dev/null; then
        severity="warning"
    fi

    if [[ "$severity" != "normal" ]]; then
        emit_event "prediction.anomaly" \
            "stage=${stage}" \
            "metric=${metric_name}" \
            "value=${current_value}" \
            "baseline=${baseline_value}" \
            "severity=${severity}" \
            "critical_mult=${metric_critical_mult}" \
            "warning_mult=${metric_warning_mult}"

        # Record anomaly for false-alarm tracking
        _predictive_record_anomaly "$stage" "$metric_name" "$severity" "$current_value" "$baseline_value"
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
        # Get adaptive EMA alpha (learned or default)
        local alpha
        alpha=$(_predictive_get_ema_alpha)
        local one_minus_alpha
        one_minus_alpha=$(awk -v a="$alpha" 'BEGIN{printf "%.4f", 1.0 - a}')

        # Exponential moving average: (1-alpha) * old + alpha * new
        new_value=$(awk -v oma="$one_minus_alpha" -v ov="$old_value" -v a="$alpha" -v nv="$value" \
            'BEGIN{printf "%.2f", oma * ov + a * nv}')
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
    echo -e "    Update running metric baselines (adaptive EMA)"
    echo ""
    echo -e "  ${BOLD}False-Alarm Tracking${RESET}"
    echo -e "    ${CYAN}shipwright predictive confirm-anomaly${RESET} <stage> <metric> <was_real>"
    echo -e "    Confirm whether detected anomaly predicted a real failure"
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
        confirm-anomaly) predictive_confirm_anomaly "$@" ;;
        patrol)      patrol_ai_analyze "$@" ;;
        baseline)    predict_update_baseline "$@" ;;
        inject-prevention)
            local stage="${1:-build}"
            local issue_json="${2:-{}}"
            local mem_ctx="${3:-}"
            [[ -n "$mem_ctx" && -f "$mem_ctx" ]] && mem_ctx=$(cat "$mem_ctx" 2>/dev/null || true)
            predict_inject_prevention "$stage" "$issue_json" "$mem_ctx" || true
            ;;
        help|--help|-h) show_help ;;
        *) error "Unknown command: $cmd"; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
