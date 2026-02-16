#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright self-optimize — Learning & Self-Tuning System               ║
# ║  Outcome analysis · Template tuning · Model routing · Memory evolution  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.2"
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

# ─── Structured Event Log ────────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

# ─── Storage Paths ───────────────────────────────────────────────────────────
OPTIMIZATION_DIR="${HOME}/.shipwright/optimization"
OUTCOMES_FILE="${OPTIMIZATION_DIR}/outcomes.jsonl"
TEMPLATE_WEIGHTS_FILE="${OPTIMIZATION_DIR}/template-weights.json"
MODEL_ROUTING_FILE="${OPTIMIZATION_DIR}/model-routing.json"
ITERATION_MODEL_FILE="${OPTIMIZATION_DIR}/iteration-model.json"

ensure_optimization_dir() {
    mkdir -p "$OPTIMIZATION_DIR"
    [[ -f "$TEMPLATE_WEIGHTS_FILE" ]] || echo '{}' > "$TEMPLATE_WEIGHTS_FILE"
    [[ -f "$MODEL_ROUTING_FILE" ]]    || echo '{}' > "$MODEL_ROUTING_FILE"
    [[ -f "$ITERATION_MODEL_FILE" ]]  || echo '{}' > "$ITERATION_MODEL_FILE"
}

# ─── GitHub Metrics ──────────────────────────────────────────────────────

_optimize_github_metrics() {
    type _gh_detect_repo &>/dev/null 2>&1 || { echo "{}"; return 0; }
    _gh_detect_repo 2>/dev/null || { echo "{}"; return 0; }

    local owner="${GH_OWNER:-}" repo="${GH_REPO:-}"
    [[ -z "$owner" || -z "$repo" ]] && { echo "{}"; return 0; }

    if type gh_actions_runs &>/dev/null 2>&1; then
        local runs
        runs=$(gh_actions_runs "$owner" "$repo" "" 50 2>/dev/null || echo "[]")
        local success_rate avg_duration
        success_rate=$(echo "$runs" | jq '[.[] | select(.conclusion == "success")] | length as $s | ([length, 1] | max) as $t | ($s / $t * 100) | floor' 2>/dev/null || echo "0")
        avg_duration=$(echo "$runs" | jq '[.[] | .duration_seconds // 0] | if length > 0 then add / length | floor else 0 end' 2>/dev/null || echo "0")
        jq -n --argjson rate "${success_rate:-0}" --argjson dur "${avg_duration:-0}" \
            '{ci_success_rate: $rate, ci_avg_duration_s: $dur}'
    else
        echo "{}"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# OUTCOME ANALYSIS
# ═════════════════════════════════════════════════════════════════════════════

# optimize_analyze_outcome <pipeline_state_file>
# Extract metrics from a completed pipeline and append to outcomes.jsonl
optimize_analyze_outcome() {
    local state_file="${1:-}"

    if [[ -z "$state_file" || ! -f "$state_file" ]]; then
        error "Pipeline state file not found: ${state_file:-<empty>}"
        return 1
    fi

    ensure_optimization_dir

    # Extract fields from the state file (markdown-style key: value)
    local issue_number template_used result total_iterations total_cost labels model
    issue_number=$(sed -n 's/^issue: *#*//p' "$state_file" | head -1 | tr -d ' ')
    template_used=$(sed -n 's/^template: *//p' "$state_file" | head -1 | tr -d ' ')
    result=$(sed -n 's/^status: *//p' "$state_file" | head -1 | tr -d ' ')
    total_iterations=$(sed -n 's/^iterations: *//p' "$state_file" | head -1 | tr -d ' ')
    total_cost=$(sed -n 's/^cost: *\$*//p' "$state_file" | head -1 | tr -d ' ')
    labels=$(sed -n 's/^labels: *//p' "$state_file" | head -1)
    model=$(sed -n 's/^model: *//p' "$state_file" | head -1 | tr -d ' ')

    # Extract complexity score if present
    local complexity
    complexity=$(sed -n 's/^complexity: *//p' "$state_file" | head -1 | tr -d ' ')

    # Extract stage durations from stages section
    local stages_json="[]"
    local stages_section=""
    stages_section=$(sed -n '/^stages:/,/^---/p' "$state_file" 2>/dev/null || true)
    if [[ -n "$stages_section" ]]; then
        # Build JSON array of stage results
        local stage_entries=""
        while IFS= read -r line; do
            local stage_name stage_status
            stage_name=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
            stage_status=$(echo "$line" | sed 's/.*: *//' | tr -d ' ')
            if [[ -n "$stage_name" && "$stage_name" != "stages" && "$stage_name" != "---" ]]; then
                if [[ -n "$stage_entries" ]]; then
                    stage_entries="${stage_entries},"
                fi
                stage_entries="${stage_entries}{\"name\":\"${stage_name}\",\"status\":\"${stage_status}\"}"
            fi
        done <<< "$stages_section"
        if [[ -n "$stage_entries" ]]; then
            stages_json="[${stage_entries}]"
        fi
    fi

    # Build outcome record using jq for proper escaping
    local tmp_outcome
    tmp_outcome=$(mktemp)
    trap "rm -f '$tmp_outcome'" RETURN
    jq -c -n \
        --arg ts "$(now_iso)" \
        --arg issue "${issue_number:-unknown}" \
        --arg template "${template_used:-unknown}" \
        --arg result "${result:-unknown}" \
        --arg model "${model:-opus}" \
        --arg labels "${labels:-}" \
        --argjson iterations "${total_iterations:-0}" \
        --argjson cost "${total_cost:-0}" \
        --argjson complexity "${complexity:-0}" \
        --argjson stages "$stages_json" \
        '{
            ts: $ts,
            issue: $issue,
            template: $template,
            result: $result,
            model: $model,
            labels: $labels,
            iterations: $iterations,
            cost: $cost,
            complexity: $complexity,
            stages: $stages
        }' > "$tmp_outcome"

    # Append to outcomes file (atomic: write to tmp, then cat + mv)
    local outcome_line
    outcome_line=$(cat "$tmp_outcome")
    rm -f "$tmp_outcome"
    echo "$outcome_line" >> "$OUTCOMES_FILE"

    # Rotate outcomes file to prevent unbounded growth
    type rotate_jsonl &>/dev/null 2>&1 && rotate_jsonl "$OUTCOMES_FILE" 10000

    # Record GitHub CI metrics alongside outcome
    local gh_ci_metrics
    gh_ci_metrics=$(_optimize_github_metrics 2>/dev/null || echo "{}")
    local ci_success_rate ci_avg_dur
    ci_success_rate=$(echo "$gh_ci_metrics" | jq -r '.ci_success_rate // 0' 2>/dev/null || echo "0")
    ci_avg_dur=$(echo "$gh_ci_metrics" | jq -r '.ci_avg_duration_s // 0' 2>/dev/null || echo "0")
    if [[ "${ci_success_rate:-0}" -gt 0 || "${ci_avg_dur:-0}" -gt 0 ]]; then
        # Append CI metrics to the outcome line
        local ci_record
        ci_record=$(jq -c -n \
            --arg ts "$(now_iso)" \
            --arg issue "${issue_number:-unknown}" \
            --argjson ci_rate "${ci_success_rate:-0}" \
            --argjson ci_dur "${ci_avg_dur:-0}" \
            '{ts: $ts, type: "ci_metrics", issue: $issue, ci_success_rate: $ci_rate, ci_avg_duration_s: $ci_dur}')
        echo "$ci_record" >> "$OUTCOMES_FILE"

        # Warn if CI success rate is dropping
        if [[ "${ci_success_rate:-0}" -lt 70 && "${ci_success_rate:-0}" -gt 0 ]]; then
            warn "CI success rate is ${ci_success_rate}% — consider template escalation"
        fi
    fi

    emit_event "optimize.outcome_analyzed" \
        "issue=${issue_number:-unknown}" \
        "template=${template_used:-unknown}" \
        "result=${result:-unknown}" \
        "iterations=${total_iterations:-0}" \
        "cost=${total_cost:-0}"

    success "Outcome recorded for issue #${issue_number:-unknown} (${result:-unknown})"
}

# ═════════════════════════════════════════════════════════════════════════════
# TEMPLATE TUNING
# ═════════════════════════════════════════════════════════════════════════════

# optimize_tune_templates [outcomes_file]
# Adjust template selection weights based on success/failure rates per label
optimize_tune_templates() {
    local outcomes_file="${1:-$OUTCOMES_FILE}"

    if [[ ! -f "$outcomes_file" ]]; then
        warn "No outcomes data found at: $outcomes_file"
        return 0
    fi

    ensure_optimization_dir

    info "Tuning template weights..."

    # Process outcomes: group by template+label, calculate success rates
    # Uses a temp file approach compatible with Bash 3.2 (no associative arrays)
    local tmp_stats tmp_weights
    tmp_stats=$(mktemp)
    tmp_weights=$(mktemp)
    trap "rm -f '$tmp_stats' '$tmp_weights'" RETURN

    # Extract template, labels, result from each outcome line
    while IFS= read -r line; do
        local template result labels_str
        template=$(echo "$line" | jq -r '.template // "unknown"' 2>/dev/null) || continue
        result=$(echo "$line" | jq -r '.result // "unknown"' 2>/dev/null) || continue
        labels_str=$(echo "$line" | jq -r '.labels // ""' 2>/dev/null) || continue

        # Default label if none
        if [[ -z "$labels_str" ]]; then
            labels_str="unlabeled"
        fi

        # Record template+label combination with result
        local label
        # Split labels by comma
        echo "$labels_str" | tr ',' '\n' | while IFS= read -r label; do
            label=$(echo "$label" | tr -d ' ')
            [[ -z "$label" ]] && continue
            local is_success=0
            if [[ "$result" == "success" || "$result" == "completed" ]]; then
                is_success=1
            fi
            echo "${template}|${label}|${is_success}" >> "$tmp_stats"
        done
    done < "$outcomes_file"

    # Calculate weights per template+label
    local current_weights='{}'
    if [[ -f "$TEMPLATE_WEIGHTS_FILE" ]]; then
        current_weights=$(cat "$TEMPLATE_WEIGHTS_FILE")
    fi

    # Get unique template|label combos
    if [[ -f "$tmp_stats" ]]; then
        local combos
        combos=$(cut -d'|' -f1,2 "$tmp_stats" | sort -u || true)

        local new_weights="$current_weights"
        while IFS= read -r combo; do
            [[ -z "$combo" ]] && continue
            local tmpl lbl
            tmpl=$(echo "$combo" | cut -d'|' -f1)
            lbl=$(echo "$combo" | cut -d'|' -f2)

            local total successes rate
            total=$(grep -c "^${tmpl}|${lbl}|" "$tmp_stats" || true)
            total="${total:-0}"
            successes=$(grep -c "^${tmpl}|${lbl}|1$" "$tmp_stats" || true)
            successes="${successes:-0}"

            if [[ "$total" -gt 0 ]]; then
                rate=$(awk "BEGIN{printf \"%.2f\", ($successes/$total)*100}")
            else
                rate="0"
            fi

            # Get current weight (default 1.0)
            local current_weight
            current_weight=$(echo "$new_weights" | jq -r --arg t "$tmpl" --arg l "$lbl" '.[$t + "|" + $l] // 1.0' 2>/dev/null)
            current_weight="${current_weight:-1.0}"

            # Adjust weight: proportional update if enough samples, else skip
            local new_weight="$current_weight"
            if [[ "$total" -ge 5 ]]; then
                # Calculate average success rate across all combos for dynamic thresholds
                local all_total all_successes avg_rate
                all_total=$(wc -l < "$tmp_stats" | tr -d ' ')
                all_total="${all_total:-1}"
                all_successes=$(grep -c "|1$" "$tmp_stats" || true)
                all_successes="${all_successes:-0}"
                avg_rate=$(awk -v s="$all_successes" -v t="$all_total" 'BEGIN { if (t > 0) printf "%.2f", (s/t)*100; else print "50" }')

                # Proportional update: new_weight = old_weight * (rate / avg_rate), clamp [0.1, 2.0]
                if awk -v ar="$avg_rate" 'BEGIN { exit !(ar > 0) }' 2>/dev/null; then
                    new_weight=$(awk -v cw="$current_weight" -v r="$rate" -v ar="$avg_rate" \
                        'BEGIN { w = cw * (r / ar); if (w < 0.1) w = 0.1; if (w > 2.0) w = 2.0; printf "%.3f", w }')
                fi
            fi

            # Update weights JSON
            new_weights=$(echo "$new_weights" | jq --arg key "${tmpl}|${lbl}" --argjson w "$new_weight" '.[$key] = $w')
        done <<< "$combos"

        # Build consumer-friendly format with per-template aggregates
        local consumer_weights
        consumer_weights=$(echo "$new_weights" | jq '
            . as $raw |
            # Extract unique template names
            [keys[] | split("|")[0]] | unique | map(. as $tmpl |
                {
                    key: $tmpl,
                    value: {
                        success_rate: ([$raw | to_entries[] | select(.key | startswith($tmpl + "|")) | .value] | if length > 0 then (add / length) else 0 end),
                        avg_duration_min: 0,
                        sample_size: ([$raw | to_entries[] | select(.key | startswith($tmpl + "|"))] | length),
                        raw_weights: ([$raw | to_entries[] | select(.key | startswith($tmpl + "|"))] | from_entries)
                    }
                }
            ) | from_entries |
            {weights: ., updated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}
        ' 2>/dev/null || echo "$new_weights")

        # Atomic write
        local tmp_cw
        tmp_cw=$(mktemp "${TEMPLATE_WEIGHTS_FILE}.tmp.XXXXXX")
        trap "rm -f '$tmp_cw'" RETURN
        echo "$consumer_weights" > "$tmp_cw" && mv "$tmp_cw" "$TEMPLATE_WEIGHTS_FILE" || rm -f "$tmp_cw"
    fi

    rm -f "$tmp_stats" "$tmp_weights" 2>/dev/null || true

    emit_event "optimize.template_tuned"
    success "Template weights updated"
}

# ═════════════════════════════════════════════════════════════════════════════
# ITERATION LEARNING
# ═════════════════════════════════════════════════════════════════════════════

# optimize_learn_iterations [outcomes_file]
# Build a prediction model for iterations by complexity bucket
optimize_learn_iterations() {
    local outcomes_file="${1:-$OUTCOMES_FILE}"

    if [[ ! -f "$outcomes_file" ]]; then
        warn "No outcomes data found at: $outcomes_file"
        return 0
    fi

    ensure_optimization_dir

    info "Learning iteration patterns..."

    # Read complexity bucket boundaries from config or use defaults (3, 6)
    local clusters_file="${OPTIMIZATION_DIR}/complexity-clusters.json"
    local low_max=3
    local med_max=6

    if [[ -f "$clusters_file" ]]; then
        local cfg_low cfg_med
        cfg_low=$(jq -r '.low_max // empty' "$clusters_file" 2>/dev/null || true)
        cfg_med=$(jq -r '.med_max // empty' "$clusters_file" 2>/dev/null || true)
        [[ -n "$cfg_low" && "$cfg_low" != "null" ]] && low_max="$cfg_low"
        [[ -n "$cfg_med" && "$cfg_med" != "null" ]] && med_max="$cfg_med"
    fi

    # Group by complexity bucket
    local tmp_low tmp_med tmp_high tmp_all_pairs
    tmp_low=$(mktemp)
    tmp_med=$(mktemp)
    tmp_high=$(mktemp)
    tmp_all_pairs=$(mktemp)
    trap "rm -f '$tmp_low' '$tmp_med' '$tmp_high' '$tmp_all_pairs'" RETURN

    while IFS= read -r line; do
        local complexity iterations
        complexity=$(echo "$line" | jq -r '.complexity // 0' 2>/dev/null) || continue
        iterations=$(echo "$line" | jq -r '.iterations // 0' 2>/dev/null) || continue

        # Skip entries without iteration data
        [[ "$iterations" == "0" || "$iterations" == "null" ]] && continue

        # Store (complexity, iterations) pairs for potential k-means
        echo "${complexity} ${iterations}" >> "$tmp_all_pairs"

        if [[ "$complexity" -le "$low_max" ]]; then
            echo "$iterations" >> "$tmp_low"
        elif [[ "$complexity" -le "$med_max" ]]; then
            echo "$iterations" >> "$tmp_med"
        else
            echo "$iterations" >> "$tmp_high"
        fi
    done < "$outcomes_file"

    # If 50+ data points, compute k-means (3 clusters) to find natural boundaries
    local pair_count=0
    [[ -s "$tmp_all_pairs" ]] && pair_count=$(wc -l < "$tmp_all_pairs" | tr -d ' ')
    if [[ "$pair_count" -ge 50 ]]; then
        # Simple k-means in awk: cluster by complexity value into 3 groups
        local new_boundaries
        new_boundaries=$(awk '
        BEGIN { n=0 }
        { c[n]=$1; it[n]=$2; n++ }
        END {
            if (n < 50) exit
            # Sort by complexity (simple bubble sort — small n)
            for (i=0; i<n-1; i++)
                for (j=i+1; j<n; j++)
                    if (c[i] > c[j]) {
                        tmp=c[i]; c[i]=c[j]; c[j]=tmp
                        tmp=it[i]; it[i]=it[j]; it[j]=tmp
                    }
            # Split into 3 equal groups and find boundaries
            third = int(n / 3)
            low_boundary = c[third - 1]
            med_boundary = c[2 * third - 1]
            # Ensure boundaries are sane (1-9 range)
            if (low_boundary < 1) low_boundary = 1
            if (low_boundary > 5) low_boundary = 5
            if (med_boundary < low_boundary + 1) med_boundary = low_boundary + 1
            if (med_boundary > 8) med_boundary = 8
            printf "%d %d", low_boundary, med_boundary
        }' "$tmp_all_pairs")

        if [[ -n "$new_boundaries" ]]; then
            local new_low new_med
            new_low=$(echo "$new_boundaries" | cut -d' ' -f1)
            new_med=$(echo "$new_boundaries" | cut -d' ' -f2)

            if [[ -n "$new_low" && -n "$new_med" ]]; then
                # Write boundaries back to config (atomic)
                local tmp_clusters
                tmp_clusters=$(mktemp "${TMPDIR:-/tmp}/sw-clusters.XXXXXX")
                trap "rm -f '$tmp_clusters'" RETURN
                jq -n \
                    --argjson low_max "$new_low" \
                    --argjson med_max "$new_med" \
                    --argjson samples "$pair_count" \
                    --arg updated "$(now_iso)" \
                    '{low_max: $low_max, med_max: $med_max, samples: $samples, updated: $updated}' \
                    > "$tmp_clusters" && mv "$tmp_clusters" "$clusters_file" || rm -f "$tmp_clusters"

                emit_event "optimize.clusters_updated" \
                    "low_max=$new_low" \
                    "med_max=$new_med" \
                    "samples=$pair_count"
            fi
        fi
    fi
    rm -f "$tmp_all_pairs" 2>/dev/null || true

    # Calculate mean and stddev for each bucket using awk
    calc_stats() {
        local file="$1"
        if [[ ! -s "$file" ]]; then
            echo '{"mean":0,"stddev":0,"samples":0}'
            return
        fi
        awk '{
            sum += $1; sumsq += ($1 * $1); n++
        } END {
            if (n == 0) { print "{\"mean\":0,\"stddev\":0,\"samples\":0}"; exit }
            mean = sum / n
            if (n > 1) {
                variance = (sumsq / n) - (mean * mean)
                if (variance < 0) variance = 0
                stddev = sqrt(variance)
            } else {
                stddev = 0
            }
            printf "{\"mean\":%.1f,\"stddev\":%.1f,\"samples\":%d}\n", mean, stddev, n
        }' "$file"
    }

    local low_stats med_stats high_stats
    low_stats=$(calc_stats "$tmp_low")
    med_stats=$(calc_stats "$tmp_med")
    high_stats=$(calc_stats "$tmp_high")

    # Build iteration model (flat format for readers: .low, .medium, .high)
    local tmp_model
    tmp_model=$(mktemp "${ITERATION_MODEL_FILE}.tmp.XXXXXX")
    trap "rm -f '$tmp_model'" RETURN
    jq -n \
        --argjson low "$low_stats" \
        --argjson medium "$med_stats" \
        --argjson high "$high_stats" \
        --arg updated "$(now_iso)" \
        '{
            low: {max_iterations: (if $low.mean > 0 then (($low.mean + $low.stddev) | floor | if . < 5 then 5 else . end) else 10 end), confidence: (if $low.samples >= 10 then 0.8 elif $low.samples >= 5 then 0.6 else 0.4 end), mean: $low.mean, stddev: $low.stddev, samples: $low.samples},
            medium: {max_iterations: (if $medium.mean > 0 then (($medium.mean + $medium.stddev) | floor | if . < 10 then 10 else . end) else 20 end), confidence: (if $medium.samples >= 10 then 0.8 elif $medium.samples >= 5 then 0.6 else 0.4 end), mean: $medium.mean, stddev: $medium.stddev, samples: $medium.samples},
            high: {max_iterations: (if $high.mean > 0 then (($high.mean + $high.stddev) | floor | if . < 15 then 15 else . end) else 30 end), confidence: (if $high.samples >= 10 then 0.8 elif $high.samples >= 5 then 0.6 else 0.4 end), mean: $high.mean, stddev: $high.stddev, samples: $high.samples},
            updated_at: $updated
        }' \
        > "$tmp_model" && mv "$tmp_model" "$ITERATION_MODEL_FILE" || rm -f "$tmp_model"

    rm -f "$tmp_low" "$tmp_med" "$tmp_high" 2>/dev/null || true

    success "Iteration model updated"

    # Apply prediction error bias correction from validation data
    _optimize_apply_prediction_bias
}

# _optimize_apply_prediction_bias
# Reads prediction-validation.jsonl and applies bias correction to iteration model.
# If predictions consistently over/under-estimate, shift the model's means.
_optimize_apply_prediction_bias() {
    local validation_file="${HOME}/.shipwright/optimization/prediction-validation.jsonl"
    [[ ! -f "$validation_file" ]] && return 0

    local model_file="$ITERATION_MODEL_FILE"
    [[ ! -f "$model_file" ]] && return 0

    # Compute mean delta (predicted - actual) from recent validations
    local recent_count=50
    local bias_data
    bias_data=$(tail -n "$recent_count" "$validation_file" | jq -s '
        if length == 0 then empty
        else
            group_by(
                if .predicted_complexity <= 3 then "low"
                elif .predicted_complexity <= 6 then "medium"
                else "high" end
            ) | map({
                bucket: (.[0] | if .predicted_complexity <= 3 then "low" elif .predicted_complexity <= 6 then "medium" else "high" end),
                mean_delta: ([.[].delta] | add / length),
                count: length
            })
        end' 2>/dev/null || true)

    [[ -z "$bias_data" || "$bias_data" == "null" ]] && return 0

    # Apply bias correction: if mean_delta > 0, predictions are too high → increase model mean
    # (model mean drives estimates, and positive delta = predicted > actual = model underestimates actual iterations needed)
    local updated_model
    updated_model=$(cat "$model_file")
    local changed=false

    for bucket in low medium high; do
        local bucket_bias count
        bucket_bias=$(echo "$bias_data" | jq -r --arg b "$bucket" '.[] | select(.bucket == $b) | .mean_delta // 0' 2>/dev/null || echo "0")
        count=$(echo "$bias_data" | jq -r --arg b "$bucket" '.[] | select(.bucket == $b) | .count // 0' 2>/dev/null || echo "0")

        # Only correct if enough samples and significant bias (|delta| > 1)
        if [[ "${count:-0}" -ge 5 ]]; then
            local abs_bias
            abs_bias=$(awk -v b="$bucket_bias" 'BEGIN { v = b < 0 ? -b : b; printf "%.1f", v }')
            if awk -v ab="$abs_bias" 'BEGIN { exit !(ab > 1.0) }' 2>/dev/null; then
                # Correction = -delta * 0.3 (partial correction to avoid overshooting)
                local correction
                correction=$(awk -v d="$bucket_bias" 'BEGIN { printf "%.2f", -d * 0.3 }')
                updated_model=$(echo "$updated_model" | jq --arg b "$bucket" --argjson c "$correction" \
                    '.[$b].mean = ((.[$b].mean // 0) + $c) | .[$b].bias_correction = $c' 2>/dev/null || echo "$updated_model")
                changed=true
                info "Prediction bias correction for $bucket: delta=${bucket_bias}, correction=${correction} (${count} samples)"
            fi
        fi
    done

    if [[ "$changed" == true ]]; then
        local tmp_model
        tmp_model=$(mktemp)
        trap "rm -f '$tmp_model'" RETURN
        if echo "$updated_model" | jq '.' > "$tmp_model" 2>/dev/null && [[ -s "$tmp_model" ]]; then
            mv "$tmp_model" "$model_file"
            emit_event "optimize.prediction_bias_corrected"
        else
            rm -f "$tmp_model"
        fi
    fi

    # Rotate validation file
    type rotate_jsonl &>/dev/null 2>&1 && rotate_jsonl "$validation_file" 5000
}

# ═════════════════════════════════════════════════════════════════════════════
# MODEL ROUTING
# ═════════════════════════════════════════════════════════════════════════════

# optimize_should_ab_test <stage>
# Returns 0 (true) ~20% of the time for A/B testing
optimize_should_ab_test() {
    local threshold=20
    local roll=$((RANDOM % 100))
    [[ "$roll" -lt "$threshold" ]]
}

# optimize_route_models [outcomes_file]
# Track per-stage model success rates and recommend cheaper models when viable
optimize_route_models() {
    local outcomes_file="${1:-$OUTCOMES_FILE}"

    if [[ ! -f "$outcomes_file" ]]; then
        warn "No outcomes data found at: $outcomes_file"
        return 0
    fi

    ensure_optimization_dir

    info "Analyzing model routing..."

    # Collect per-stage, per-model stats
    local tmp_stage_stats
    tmp_stage_stats=$(mktemp)
    trap "rm -f '$tmp_stage_stats'" RETURN

    while IFS= read -r line; do
        local model result stages_arr
        model=$(echo "$line" | jq -r '.model // "opus"' 2>/dev/null) || continue
        result=$(echo "$line" | jq -r '.result // "unknown"' 2>/dev/null) || continue
        local cost
        cost=$(echo "$line" | jq -r '.cost // 0' 2>/dev/null) || continue

        # Extract stage names from the stages array
        local stage_count
        stage_count=$(echo "$line" | jq '.stages | length' 2>/dev/null || echo "0")

        local i=0
        while [[ "$i" -lt "$stage_count" ]]; do
            local stage_name stage_status
            stage_name=$(echo "$line" | jq -r ".stages[$i].name" 2>/dev/null)
            stage_status=$(echo "$line" | jq -r ".stages[$i].status" 2>/dev/null)
            local is_success=0
            if [[ "$stage_status" == "complete" || "$stage_status" == "success" ]]; then
                is_success=1
            fi
            echo "${stage_name}|${model}|${is_success}|${cost}" >> "$tmp_stage_stats"
            i=$((i + 1))
        done
    done < "$outcomes_file"

    # Build routing recommendations
    local routing='{}'
    if [[ -f "$MODEL_ROUTING_FILE" ]]; then
        routing=$(cat "$MODEL_ROUTING_FILE")
    fi

    if [[ -f "$tmp_stage_stats" && -s "$tmp_stage_stats" ]]; then
        local stages
        stages=$(cut -d'|' -f1 "$tmp_stage_stats" | sort -u || true)

        while IFS= read -r stage; do
            [[ -z "$stage" ]] && continue

            # Sonnet stats for this stage
            local sonnet_total sonnet_success sonnet_rate
            sonnet_total=$(grep -c "^${stage}|sonnet|" "$tmp_stage_stats" || true)
            sonnet_total="${sonnet_total:-0}"
            sonnet_success=$(grep -c "^${stage}|sonnet|1|" "$tmp_stage_stats" || true)
            sonnet_success="${sonnet_success:-0}"

            if [[ "$sonnet_total" -gt 0 ]]; then
                sonnet_rate=$(awk "BEGIN{printf \"%.1f\", ($sonnet_success/$sonnet_total)*100}")
            else
                sonnet_rate="0"
            fi

            # Opus stats for this stage
            local opus_total opus_success opus_rate
            opus_total=$(grep -c "^${stage}|opus|" "$tmp_stage_stats" || true)
            opus_total="${opus_total:-0}"
            opus_success=$(grep -c "^${stage}|opus|1|" "$tmp_stage_stats" || true)
            opus_success="${opus_success:-0}"

            if [[ "$opus_total" -gt 0 ]]; then
                opus_rate=$(awk "BEGIN{printf \"%.1f\", ($opus_success/$opus_total)*100}")
            else
                opus_rate="0"
            fi

            # Recommend sonnet if it succeeds 90%+ with enough samples
            local recommendation="opus"
            if [[ "$sonnet_total" -ge 3 ]] && awk "BEGIN{exit !($sonnet_rate >= 90)}" 2>/dev/null; then
                recommendation="sonnet"
                emit_event "optimize.model_switched" \
                    "stage=$stage" \
                    "from=opus" \
                    "to=sonnet" \
                    "sonnet_rate=$sonnet_rate"
            fi

            routing=$(echo "$routing" | jq \
                --arg stage "$stage" \
                --arg rec "$recommendation" \
                --argjson sonnet_rate "$sonnet_rate" \
                --argjson opus_rate "$opus_rate" \
                --argjson sonnet_n "$sonnet_total" \
                --argjson opus_n "$opus_total" \
                '.[$stage] = {
                    recommended: $rec,
                    sonnet_rate: $sonnet_rate,
                    opus_rate: $opus_rate,
                    sonnet_samples: $sonnet_n,
                    opus_samples: $opus_n
                }')
        done <<< "$stages"
    fi

    # Wrap in consumer-friendly format
    local consumer_routing
    consumer_routing=$(echo "$routing" | jq '{
        routes: (. | to_entries | map({
            key: .key,
            value: {
                model: .value.recommended,
                confidence: (if .value.sonnet_samples + .value.opus_samples >= 10 then 0.9
                    elif .value.sonnet_samples + .value.opus_samples >= 5 then 0.7
                    else 0.5 end),
                sonnet_rate: .value.sonnet_rate,
                opus_rate: .value.opus_rate,
                sonnet_samples: .value.sonnet_samples,
                opus_samples: .value.opus_samples
            }
        }) | from_entries),
        updated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }' 2>/dev/null || echo "$routing")

    # Atomic write
    local tmp_routing
    tmp_routing=$(mktemp "${MODEL_ROUTING_FILE}.tmp.XXXXXX")
    trap "rm -f '$tmp_routing'" RETURN
    echo "$consumer_routing" > "$tmp_routing" && mv "$tmp_routing" "$MODEL_ROUTING_FILE" || rm -f "$tmp_routing"

    rm -f "$tmp_stage_stats" 2>/dev/null || true

    success "Model routing updated"
}

# ═════════════════════════════════════════════════════════════════════════════
# RISK KEYWORD LEARNING
# ═════════════════════════════════════════════════════════════════════════════

# optimize_learn_risk_keywords [outcomes_file]
# Learns keyword→risk-weight mapping from pipeline outcomes for predictive risk scoring.
# Failed pipelines with labels/keywords get positive weights; successful ones get negative.
optimize_learn_risk_keywords() {
    local outcomes_file="${1:-$OUTCOMES_FILE}"

    if [[ ! -f "$outcomes_file" ]]; then
        return 0
    fi

    ensure_optimization_dir

    info "Learning risk keywords from outcomes..."

    local risk_file="${OPTIMIZATION_DIR}/risk-keywords.json"
    local keywords='{}'
    if [[ -f "$risk_file" ]]; then
        keywords=$(jq '.' "$risk_file" 2>/dev/null || echo '{}')
    fi

    local decay=0.95
    local learn_rate=5

    # Read outcomes and extract keywords from labels
    local updated=false
    while IFS= read -r line; do
        local result labels
        result=$(echo "$line" | jq -r '.result // "unknown"' 2>/dev/null) || continue
        labels=$(echo "$line" | jq -r '.labels // ""' 2>/dev/null) || continue
        [[ -z "$labels" || "$labels" == "null" ]] && continue

        # Split labels on comma/space and learn from each keyword
        local IFS=', '
        for kw in $labels; do
            kw=$(echo "$kw" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
            [[ -z "$kw" || ${#kw} -lt 3 ]] && continue

            local current_weight
            current_weight=$(echo "$keywords" | jq -r --arg k "$kw" '.[$k] // 0' 2>/dev/null || echo "0")

            local delta=0
            if [[ "$result" == "failed" || "$result" == "error" ]]; then
                delta=$learn_rate
            elif [[ "$result" == "success" || "$result" == "complete" ]]; then
                delta=$((-learn_rate / 2))
            fi

            if [[ "$delta" -ne 0 ]]; then
                local new_weight
                new_weight=$(awk -v cw="$current_weight" -v d="$decay" -v dw="$delta" 'BEGIN { printf "%.0f", (cw * d) + dw }')
                # Clamp to -50..50
                new_weight=$(awk -v w="$new_weight" 'BEGIN { if(w>50) w=50; if(w<-50) w=-50; printf "%.0f", w }')
                keywords=$(echo "$keywords" | jq --arg k "$kw" --argjson w "$new_weight" '.[$k] = $w' 2>/dev/null || echo "$keywords")
                updated=true
            fi
        done
    done < "$outcomes_file"

    if [[ "$updated" == true ]]; then
        # Prune zero-weight keywords
        keywords=$(echo "$keywords" | jq 'to_entries | map(select(.value != 0)) | from_entries' 2>/dev/null || echo "$keywords")
        local tmp_risk
        tmp_risk=$(mktemp)
        trap "rm -f '$tmp_risk'" RETURN
        if echo "$keywords" | jq '.' > "$tmp_risk" 2>/dev/null && [[ -s "$tmp_risk" ]]; then
            mv "$tmp_risk" "$risk_file"
            success "Risk keywords updated ($(echo "$keywords" | jq 'length' 2>/dev/null || echo '?') keywords)"
        else
            rm -f "$tmp_risk"
        fi
    else
        info "No label data in outcomes — risk keywords unchanged"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# MEMORY EVOLUTION
# ═════════════════════════════════════════════════════════════════════════════

# optimize_evolve_memory
# Prune stale patterns, strengthen confirmed ones, promote cross-repo patterns
optimize_evolve_memory() {
    local memory_root="${HOME}/.shipwright/memory"

    if [[ ! -d "$memory_root" ]]; then
        warn "No memory directory found"
        return 0
    fi

    info "Evolving memory patterns..."

    local pruned=0
    local strengthened=0
    local promoted=0
    local now_e
    now_e=$(now_epoch)

    # Read adaptive timescales from config or use defaults
    local timescales_file="${OPTIMIZATION_DIR}/memory-timescales.json"
    local prune_days=30
    local boost_days=7
    local strength_threshold=3
    local promotion_threshold=3

    if [[ -f "$timescales_file" ]]; then
        local cfg_prune cfg_boost
        cfg_prune=$(jq -r '.prune_days // empty' "$timescales_file" 2>/dev/null || true)
        cfg_boost=$(jq -r '.boost_days // empty' "$timescales_file" 2>/dev/null || true)
        [[ -n "$cfg_prune" && "$cfg_prune" != "null" ]] && prune_days="$cfg_prune"
        [[ -n "$cfg_boost" && "$cfg_boost" != "null" ]] && boost_days="$cfg_boost"
    fi

    # Read strength and cross-repo thresholds from config
    local thresholds_file="${OPTIMIZATION_DIR}/memory-thresholds.json"
    if [[ -f "$thresholds_file" ]]; then
        local cfg_strength cfg_promotion
        cfg_strength=$(jq -r '.strength_threshold // empty' "$thresholds_file" 2>/dev/null || true)
        cfg_promotion=$(jq -r '.promotion_threshold // empty' "$thresholds_file" 2>/dev/null || true)
        [[ -n "$cfg_strength" && "$cfg_strength" != "null" ]] && strength_threshold="$cfg_strength"
        [[ -n "$cfg_promotion" && "$cfg_promotion" != "null" ]] && promotion_threshold="$cfg_promotion"
    fi

    local prune_seconds=$((prune_days * 86400))
    local boost_seconds=$((boost_days * 86400))
    local prune_cutoff=$((now_e - prune_seconds))
    local boost_cutoff=$((now_e - boost_seconds))

    # Process each repo's failures.json
    local repo_dir
    for repo_dir in "$memory_root"/*/; do
        [[ -d "$repo_dir" ]] || continue
        local failures_file="${repo_dir}failures.json"
        [[ -f "$failures_file" ]] || continue

        local entry_count
        entry_count=$(jq '.failures | length' "$failures_file" 2>/dev/null || echo "0")
        [[ "$entry_count" -eq 0 ]] && continue

        local tmp_file
        tmp_file=$(mktemp)
        trap "rm -f '$tmp_file'" RETURN

        # Prune entries not seen within prune window
        local pruned_json
        pruned_json=$(jq --arg cutoff "$(date -u -r "$prune_cutoff" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '[.failures[] | select(.last_seen >= $cutoff or .last_seen == null)]' \
            "$failures_file" 2>/dev/null || echo "[]")

        local after_count
        after_count=$(echo "$pruned_json" | jq 'length' 2>/dev/null || echo "0")
        local delta=$((entry_count - after_count))
        pruned=$((pruned + delta))

        # Strengthen entries seen N+ times within boost window (adaptive thresholds)
        pruned_json=$(echo "$pruned_json" | jq \
            --arg cutoff_b "$(date -u -r "$boost_cutoff" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            --argjson st "$strength_threshold" '
            [.[] | if (.seen_count >= $st and .last_seen >= $cutoff_b) then
                .weight = ((.weight // 1.0) * 1.5)
            else . end]')

        local strong_count
        strong_count=$(echo "$pruned_json" | jq '[.[] | select(.weight != null and .weight > 1.0)] | length' 2>/dev/null || echo "0")
        strengthened=$((strengthened + strong_count))

        # Write back
        jq -n --argjson f "$pruned_json" '{failures: $f}' > "$tmp_file" && mv "$tmp_file" "$failures_file"
    done

    # Promote patterns that appear in 3+ repos to global.json
    local global_file="${memory_root}/global.json"
    if [[ ! -f "$global_file" ]]; then
        echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$global_file"
    fi

    # Collect all patterns across repos
    local tmp_all_patterns
    tmp_all_patterns=$(mktemp)
    trap "rm -f '$tmp_all_patterns'" RETURN
    for repo_dir in "$memory_root"/*/; do
        [[ -d "$repo_dir" ]] || continue
        local failures_file="${repo_dir}failures.json"
        [[ -f "$failures_file" ]] || continue
        jq -r '.failures[]?.pattern // empty' "$failures_file" 2>/dev/null >> "$tmp_all_patterns" || true
    done

    if [[ -s "$tmp_all_patterns" ]]; then
        # Find patterns appearing in N+ repos (adaptive threshold)
        local promoted_patterns
        promoted_patterns=$(sort "$tmp_all_patterns" | uniq -c | sort -rn | awk -v pt="$promotion_threshold" '$1 >= pt {$1=""; print substr($0,2)}' || true)

        if [[ -n "$promoted_patterns" ]]; then
            local tmp_global
            tmp_global=$(mktemp)
            trap "rm -f '$tmp_global'" RETURN
            local pcount=0
            while IFS= read -r pattern; do
                [[ -z "$pattern" ]] && continue
                # Check if already in global
                local exists
                exists=$(jq --arg p "$pattern" '[.common_patterns[] | select(.pattern == $p)] | length' "$global_file" 2>/dev/null || echo "0")
                if [[ "$exists" == "0" ]]; then
                    jq --arg p "$pattern" --arg ts "$(now_iso)" \
                        '.common_patterns += [{pattern: $p, promoted_at: $ts, source: "cross-repo"}]' \
                        "$global_file" > "$tmp_global" && mv "$tmp_global" "$global_file"
                    pcount=$((pcount + 1))
                fi
            done <<< "$promoted_patterns"
            promoted=$((promoted + pcount))
        fi
    fi

    rm -f "$tmp_all_patterns" 2>/dev/null || true

    emit_event "optimize.memory_pruned" \
        "pruned=$pruned" \
        "strengthened=$strengthened" \
        "promoted=$promoted"

    success "Memory evolved: pruned=$pruned, strengthened=$strengthened, promoted=$promoted"
}

# ═════════════════════════════════════════════════════════════════════════════
# FULL ANALYSIS (DAILY)
# ═════════════════════════════════════════════════════════════════════════════

# optimize_full_analysis
# Run all optimization steps — designed for daily execution
optimize_full_analysis() {
    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  Self-Optimization — Full Analysis                           ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    ensure_optimization_dir

    optimize_tune_templates
    optimize_learn_iterations
    optimize_route_models
    optimize_learn_risk_keywords
    optimize_evolve_memory
    optimize_report >> "${OPTIMIZATION_DIR}/last-report.txt" 2>/dev/null || true
    optimize_adjust_audit_intensity 2>/dev/null || true

    echo ""
    success "Full optimization analysis complete"
}

# ═════════════════════════════════════════════════════════════════════════════
# REPORT
# ═════════════════════════════════════════════════════════════════════════════

# optimize_report
# Generate a summary report of optimization trends over last 7 days
optimize_report() {
    ensure_optimization_dir

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  Self-Optimization Report                                    ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    if [[ ! -f "$OUTCOMES_FILE" ]]; then
        warn "No outcomes data available yet"
        return 0
    fi

    local now_e seven_days_ago
    now_e=$(now_epoch)
    seven_days_ago=$((now_e - 604800))
    local cutoff_iso
    cutoff_iso=$(date -u -r "$seven_days_ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Count outcomes in last 7 days
    local total_recent=0
    local success_recent=0
    local total_cost_recent=0
    local total_iterations_recent=0

    while IFS= read -r line; do
        local ts result cost iterations
        ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null) || continue
        [[ "$ts" < "$cutoff_iso" ]] && continue

        result=$(echo "$line" | jq -r '.result // "unknown"' 2>/dev/null) || continue
        cost=$(echo "$line" | jq -r '.cost // 0' 2>/dev/null) || continue
        iterations=$(echo "$line" | jq -r '.iterations // 0' 2>/dev/null) || continue

        total_recent=$((total_recent + 1))
        if [[ "$result" == "success" || "$result" == "completed" ]]; then
            success_recent=$((success_recent + 1))
        fi
        total_cost_recent=$(awk "BEGIN{printf \"%.2f\", $total_cost_recent + $cost}")
        total_iterations_recent=$((total_iterations_recent + iterations))
    done < "$OUTCOMES_FILE"

    # Calculate rates
    local success_rate="0"
    local avg_iterations="0"
    local avg_cost="0"
    if [[ "$total_recent" -gt 0 ]]; then
        success_rate=$(awk "BEGIN{printf \"%.1f\", ($success_recent/$total_recent)*100}")
        avg_iterations=$(awk "BEGIN{printf \"%.1f\", $total_iterations_recent/$total_recent}")
        avg_cost=$(awk "BEGIN{printf \"%.2f\", $total_cost_recent/$total_recent}")
    fi

    echo -e "${CYAN}${BOLD}  Last 7 Days${RESET}"
    echo -e "  ${DIM}─────────────────────────────────${RESET}"
    echo -e "  Pipelines:       ${BOLD}$total_recent${RESET}"
    echo -e "  Success rate:    ${BOLD}${success_rate}%${RESET}"
    echo -e "  Avg iterations:  ${BOLD}${avg_iterations}${RESET}"
    echo -e "  Avg cost:        ${BOLD}\$${avg_cost}${RESET}"
    echo -e "  Total cost:      ${BOLD}\$${total_cost_recent}${RESET}"
    echo ""

    # Template weights summary
    if [[ -f "$TEMPLATE_WEIGHTS_FILE" ]]; then
        local weight_count
        weight_count=$(jq 'keys | length' "$TEMPLATE_WEIGHTS_FILE" 2>/dev/null || echo "0")
        if [[ "$weight_count" -gt 0 ]]; then
            echo -e "${CYAN}${BOLD}  Template Weights${RESET}"
            echo -e "  ${DIM}─────────────────────────────────${RESET}"
            jq -r 'to_entries[] | "  \(.key): \(.value)"' "$TEMPLATE_WEIGHTS_FILE" 2>/dev/null || true
            echo ""
        fi
    fi

    # Model routing summary
    if [[ -f "$MODEL_ROUTING_FILE" ]]; then
        local route_count
        route_count=$(jq 'keys | length' "$MODEL_ROUTING_FILE" 2>/dev/null || echo "0")
        if [[ "$route_count" -gt 0 ]]; then
            echo -e "${CYAN}${BOLD}  Model Routing${RESET}"
            echo -e "  ${DIM}─────────────────────────────────${RESET}"
            jq -r 'to_entries[] | "  \(.key): \(.value.recommended) (sonnet: \(.value.sonnet_rate)%, opus: \(.value.opus_rate)%)"' \
                "$MODEL_ROUTING_FILE" 2>/dev/null || true
            echo ""
        fi
    fi

    # Iteration model summary
    if [[ -f "$ITERATION_MODEL_FILE" ]]; then
        local has_data
        has_data=$(jq '.low.samples // 0' "$ITERATION_MODEL_FILE" 2>/dev/null || echo "0")
        if [[ "$has_data" -gt 0 ]]; then
            echo -e "${CYAN}${BOLD}  Iteration Model${RESET}"
            echo -e "  ${DIM}─────────────────────────────────${RESET}"
            echo -e "  Low complexity:  $(jq -r '.low | "\(.mean) ± \(.stddev) (\(.samples) samples)"' "$ITERATION_MODEL_FILE" 2>/dev/null)"
            echo -e "  Med complexity:  $(jq -r '.medium | "\(.mean) ± \(.stddev) (\(.samples) samples)"' "$ITERATION_MODEL_FILE" 2>/dev/null)"
            echo -e "  High complexity: $(jq -r '.high | "\(.mean) ± \(.stddev) (\(.samples) samples)"' "$ITERATION_MODEL_FILE" 2>/dev/null)"
            echo ""
        fi
    fi

    emit_event "optimize.report" \
        "pipelines=$total_recent" \
        "success_rate=$success_rate" \
        "avg_cost=$avg_cost"

    success "Report complete"
}

# optimize_adjust_audit_intensity
# Reads quality-scores.jsonl trends and adjusts intelligence feature flags
# to increase audit intensity when quality is declining.
optimize_adjust_audit_intensity() {
    local quality_file="${HOME}/.shipwright/optimization/quality-scores.jsonl"
    local daemon_config="${REPO_DIR:-.}/.claude/daemon-config.json"

    [[ ! -f "$quality_file" ]] && return 0
    [[ ! -f "$daemon_config" ]] && return 0

    # Get last 10 quality scores
    local recent_scores avg_quality trend
    recent_scores=$(tail -10 "$quality_file" 2>/dev/null || true)
    [[ -z "$recent_scores" ]] && return 0

    avg_quality=$(echo "$recent_scores" | jq -r '.quality_score // 70' 2>/dev/null \
        | awk '{ sum += $1; count++ } END { if (count > 0) printf "%.0f", sum/count; else print 70 }')
    avg_quality="${avg_quality:-70}"

    # Detect trend: compare first half vs second half
    local first_half_avg second_half_avg
    first_half_avg=$(echo "$recent_scores" | head -5 | jq -r '.quality_score // 70' 2>/dev/null \
        | awk '{ sum += $1; count++ } END { if (count > 0) printf "%.0f", sum/count; else print 70 }')
    second_half_avg=$(echo "$recent_scores" | tail -5 | jq -r '.quality_score // 70' 2>/dev/null \
        | awk '{ sum += $1; count++ } END { if (count > 0) printf "%.0f", sum/count; else print 70 }')

    if [[ "${second_half_avg:-70}" -lt "${first_half_avg:-70}" ]]; then
        trend="declining"
    else
        trend="stable_or_improving"
    fi

    # Declining quality → enable more audits
    if [[ "$trend" == "declining" || "${avg_quality:-70}" -lt 60 ]]; then
        info "Quality trend: ${trend} (avg: ${avg_quality}) — increasing audit intensity"
        local tmp_dc
        tmp_dc=$(mktemp "${daemon_config}.tmp.XXXXXX")
        trap "rm -f '$tmp_dc'" RETURN
        jq '.intelligence.adversarial_enabled = true | .intelligence.architecture_enabled = true' \
            "$daemon_config" > "$tmp_dc" 2>/dev/null && mv "$tmp_dc" "$daemon_config" || rm -f "$tmp_dc"
        emit_event "optimize.audit_intensity" \
            "avg_quality=$avg_quality" \
            "trend=$trend" \
            "action=increase"
    elif [[ "${avg_quality:-70}" -gt 85 ]]; then
        info "Quality trend: excellent (avg: ${avg_quality}) — maintaining standard audits"
        emit_event "optimize.audit_intensity" \
            "avg_quality=$avg_quality" \
            "trend=$trend" \
            "action=maintain"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# HELP
# ═════════════════════════════════════════════════════════════════════════════

show_help() {
    echo ""
    echo -e "${PURPLE}${BOLD}shipwright self-optimize${RESET} — Learning & Self-Tuning System"
    echo ""
    echo -e "${CYAN}USAGE${RESET}"
    echo "  shipwright self-optimize <command>"
    echo ""
    echo -e "${CYAN}COMMANDS${RESET}"
    echo "  analyze-outcome <state-file>   Analyze a completed pipeline outcome"
    echo "  tune                           Run full optimization analysis"
    echo "  report                         Show optimization report (last 7 days)"
    echo "  evolve-memory                  Prune/strengthen/promote memory patterns"
    echo "  help                           Show this help"
    echo ""
    echo -e "${CYAN}STORAGE${RESET}"
    echo "  ~/.shipwright/optimization/outcomes.jsonl        Outcome history"
    echo "  ~/.shipwright/optimization/template-weights.json Template selection weights"
    echo "  ~/.shipwright/optimization/model-routing.json    Per-stage model routing"
    echo "  ~/.shipwright/optimization/iteration-model.json  Iteration predictions"
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true
    case "$cmd" in
        analyze-outcome) optimize_analyze_outcome "$@" ;;
        tune)            optimize_full_analysis ;;
        report)          optimize_report ;;
        evolve-memory)   optimize_evolve_memory ;;
        help|--help|-h)  show_help ;;
        *)               error "Unknown command: $cmd"; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
