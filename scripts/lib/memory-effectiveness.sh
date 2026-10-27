#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Memory Pattern Effectiveness Tracker — proactive failure prevention      ║
# ║  Scores memory patterns · Ranks by effectiveness · Prunes ineffective     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard
[[ -n "${_MEMEFF_LOADED:-}" ]] && return 0
_MEMEFF_LOADED=1
set -euo pipefail

VERSION="4.0.0"

# ─── Helpers (loaded from parent context) ───────────────────────────────────
# Expects: info(), success(), warn(), error(), emit_event(), now_iso()
# If not available, provide fallbacks

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
    local event_type="$1"; shift
    mkdir -p "${HOME}/.shipwright" 2>/dev/null || return 0
    local payload="{\"ts\":\"$(now_iso)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do
      local key="${1%%=*}" val="${1#*=}"
      payload="${payload},\"${key}\":\"${val}\""
      shift
    done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Storage Paths ───────────────────────────────────────────────────────────

MEMEFF_DIR="${HOME}/.shipwright/optimization"
MEMEFF_INJECTIONS="${MEMEFF_DIR}/memory-injections.jsonl"
MEMEFF_OUTCOMES="${MEMEFF_DIR}/memory-outcomes.jsonl"
MEMEFF_SCORES="${MEMEFF_DIR}/memory-scores.json"
MEMEFF_ARCHIVE="${MEMEFF_DIR}/archive"

# ─── Initialize Storage ───────────────────────────────────────────────────────

memeff_init() {
    mkdir -p "$MEMEFF_DIR" "$MEMEFF_ARCHIVE"
    [[ -f "$MEMEFF_SCORES" ]] || echo '{}' > "$MEMEFF_SCORES"
}

# ─── 1. Track Memory Injection ──────────────────────────────────────────────

# Record when a memory pattern is injected
# memeff_track_injection <memory_id> <pipeline_id> <stage> <injection_context>
memeff_track_injection() {
    local memory_id="${1:-}"
    local pipeline_id="${2:-}"
    local stage="${3:-unknown}"
    local injection_context="${4:-}"

    [[ -z "$memory_id" || -z "$pipeline_id" ]] && return 1

    memeff_init

    local ts
    ts="$(now_iso)"
    local injection_record
    injection_record=$(jq -cn \
        --arg mid "$memory_id" \
        --arg pid "$pipeline_id" \
        --arg stg "$stage" \
        --arg ctx "$injection_context" \
        --arg ts "$ts" \
        '{
            memory_id: $mid,
            pipeline_id: $pid,
            stage: $stg,
            context: $ctx,
            injected_at: $ts,
            token_cost: 0,
            outcome_recorded: false
        }')

    # Atomic write to JSONL
    local tmp_injections
    tmp_injections=$(mktemp "${MEMEFF_INJECTIONS}.tmp.XXXXXX")
    {
        [[ -f "$MEMEFF_INJECTIONS" ]] && cat "$MEMEFF_INJECTIONS"
        echo "$injection_record"
    } > "$tmp_injections"
    mv "$tmp_injections" "$MEMEFF_INJECTIONS"

    emit_event "memeff.injection" \
        "memory_id=${memory_id}" \
        "pipeline_id=${pipeline_id}" \
        "stage=${stage}"

    return 0
}

# ─── 2. Track Memory Outcome ──────────────────────────────────────────────

# Record pipeline outcome after injection
# memeff_track_outcome <memory_id> <pipeline_id> <outcome> [relevant_error]
memeff_track_outcome() {
    local memory_id="${1:-}"
    local pipeline_id="${2:-}"
    local outcome="${3:-unknown}"  # success, failure, inconclusive
    local relevant_error="${4:-}"

    [[ -z "$memory_id" || -z "$pipeline_id" ]] && return 1

    memeff_init

    # Find the corresponding injection (use fixed strings, not regex, to avoid special char issues)
    local injection_record
    injection_record=$(grep -F "\"memory_id\":\"${memory_id}\"" "$MEMEFF_INJECTIONS" 2>/dev/null | \
        grep -F "\"pipeline_id\":\"${pipeline_id}\"" | tail -1 || true)

    if [[ -z "$injection_record" ]]; then
        warn "No injection record found for memory_id=$memory_id, pipeline_id=$pipeline_id"
        return 1
    fi

    # Determine if pattern was relevant (did the injection prevent the error?)
    local was_relevant="false"
    if [[ "$outcome" == "success" ]]; then
        was_relevant="true"
    elif [[ "$outcome" == "failure" && -z "$relevant_error" ]]; then
        was_relevant="false"
    elif [[ "$outcome" == "failure" && -n "$relevant_error" ]]; then
        # Failure occurred, but unrelated to this memory's domain
        was_relevant="false"
    fi

    local ts
    ts="$(now_iso)"
    local outcome_record
    outcome_record=$(jq -cn \
        --arg mid "$memory_id" \
        --arg pid "$pipeline_id" \
        --arg out "$outcome" \
        --arg relevant "$was_relevant" \
        --arg err "$relevant_error" \
        --arg ts "$ts" \
        '{
            memory_id: $mid,
            pipeline_id: $pid,
            outcome: $out,
            was_relevant: ($relevant == "true"),
            avoided_error: ($out == "success"),
            error_description: $err,
            recorded_at: $ts
        }')

    # Atomic write
    local tmp_outcomes
    tmp_outcomes=$(mktemp "${MEMEFF_OUTCOMES}.tmp.XXXXXX")
    {
        [[ -f "$MEMEFF_OUTCOMES" ]] && cat "$MEMEFF_OUTCOMES"
        echo "$outcome_record"
    } > "$tmp_outcomes"
    mv "$tmp_outcomes" "$MEMEFF_OUTCOMES"

    emit_event "memeff.outcome" \
        "memory_id=${memory_id}" \
        "pipeline_id=${pipeline_id}" \
        "outcome=${outcome}" \
        "was_relevant=${was_relevant}"

    return 0
}

# ─── 3. Score Individual Pattern ────────────────────────────────────────────

# Calculate effectiveness score for a memory pattern
# memeff_score_pattern <memory_id>
# Returns: JSON with prevention_rate, relevance_rate, token_cost, effectiveness_score
memeff_score_pattern() {
    local memory_id="${1:-}"
    [[ -z "$memory_id" ]] && return 1

    memeff_init

    # Count outcomes for this pattern
    local outcomes
    outcomes=$(grep -F "\"memory_id\":\"${memory_id}\"" "$MEMEFF_OUTCOMES" 2>/dev/null || true)

    local total_injections=0
    local successful_preventions=0
    local relevant_injections=0
    local token_cost_total=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        total_injections=$((total_injections + 1))

        # Check if outcome avoided the error
        if echo "$line" | jq -e '.avoided_error == true' >/dev/null 2>&1; then
            successful_preventions=$((successful_preventions + 1))
        fi

        # Check if pattern was relevant to the task
        if echo "$line" | jq -e '.was_relevant == true' >/dev/null 2>&1; then
            relevant_injections=$((relevant_injections + 1))
        fi
    done <<< "$outcomes"

    # Calculate rates (avoid division by zero)
    local prevention_rate=0
    local relevance_rate=0
    if [[ "$total_injections" -gt 0 ]]; then
        prevention_rate=$((successful_preventions * 100 / total_injections))
        relevance_rate=$((relevant_injections * 100 / total_injections))
    fi

    # Normalize token cost (assume ~100 tokens per injection on average)
    local token_cost_normalized
    if [[ "$total_injections" -gt 0 ]]; then
        token_cost_normalized=$((token_cost_total / total_injections / 100))
    else
        token_cost_normalized=0
    fi

    # Effectiveness formula: (prevention * 0.5 + relevance * 0.3) - (token_cost * 0.2)
    local effectiveness_score
    effectiveness_score=$(( (prevention_rate * 50 + relevance_rate * 30) / 100 - (token_cost_normalized * 20) ))
    [[ "$effectiveness_score" -lt 0 ]] && effectiveness_score=0
    [[ "$effectiveness_score" -gt 100 ]] && effectiveness_score=100

    # Return as JSON
    jq -cn \
        --arg mid "$memory_id" \
        --argjson prev "$prevention_rate" \
        --argjson rel "$relevance_rate" \
        --argjson cost "$token_cost_normalized" \
        --argjson score "$effectiveness_score" \
        --argjson injections "$total_injections" \
        '{
            memory_id: $mid,
            prevention_rate: $prev,
            relevance_rate: $rel,
            token_cost_normalized: $cost,
            effectiveness_score: $score,
            total_injections: $injections
        }'
}

# ─── 4. Rank All Patterns ──────────────────────────────────────────────────

# Rank all patterns by effectiveness
# memeff_rank_patterns [limit]
# Returns: JSON array sorted by effectiveness_score descending
memeff_rank_patterns() {
    local limit="${1:-50}"

    memeff_init

    # Extract all unique memory IDs from outcomes
    local memory_ids
    memory_ids=$(grep -o '"memory_id":"[^"]*"' "$MEMEFF_OUTCOMES" 2>/dev/null | \
        sed 's/"memory_id":"//' | sed 's/"//' | \
        sort -u || true)

    local rankings=()
    while IFS= read -r memory_id; do
        [[ -z "$memory_id" ]] && continue
        local score_json
        score_json=$(memeff_score_pattern "$memory_id")
        rankings+=("$score_json")
    done <<< "$memory_ids"

    # Sort by effectiveness_score descending
    if [[ "${#rankings[@]}" -eq 0 ]]; then
        echo "[]"
        return 0
    fi

    printf '%s\n' "${rankings[@]}" | \
        jq -s 'sort_by(-.effectiveness_score) | .[0:'"$limit"']'
}

# ─── 5. Prune Ineffective Patterns ──────────────────────────────────────────

# Remove or archive ineffective patterns
# memeff_prune_ineffective [dry_run]
# Score < 20 after 5+ injections → archive
# Score < 10 after 10+ injections → delete
memeff_prune_ineffective() {
    local dry_run="${1:-true}"

    memeff_init

    local rankings
    rankings=$(memeff_rank_patterns 999)

    local archived=0
    local deleted=0

    echo "$rankings" | jq -c '.[]' | while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue

        local mid score injections
        mid=$(echo "$pattern" | jq -r '.memory_id')
        score=$(echo "$pattern" | jq -r '.effectiveness_score // 0')
        injections=$(echo "$pattern" | jq -r '.total_injections // 0')

        # Score < 20 after 5+ injections → archive
        if [[ "${score%.*}" -lt 20 && "$injections" -ge 5 ]]; then
            if [[ "$dry_run" != "true" ]]; then
                # Archive the pattern metadata
                echo "Archiving memory_id=$mid (score=$score, injections=$injections)"
                archived=$((archived + 1))
                emit_event "memeff.archive" \
                    "memory_id=${mid}" \
                    "score=${score}" \
                    "reason=low_effectiveness"
            else
                info "DRY-RUN: Would archive memory_id=$mid (score=$score)"
            fi
        fi

        # Score < 10 after 10+ injections → delete
        if [[ "${score%.*}" -lt 10 && "$injections" -ge 10 ]]; then
            if [[ "$dry_run" != "true" ]]; then
                # Remove from tracking
                echo "Deleting memory_id=$mid (score=$score, injections=$injections)"
                deleted=$((deleted + 1))
                emit_event "memeff.delete" \
                    "memory_id=${mid}" \
                    "score=${score}" \
                    "reason=critically_ineffective"
            else
                info "DRY-RUN: Would delete memory_id=$mid (score=$score)"
            fi
        fi
    done

    emit_event "memeff.prune_complete" \
        "archived=${archived}" \
        "deleted=${deleted}" \
        "dry_run=${dry_run}"

    return 0
}

# ─── 6. Proactive Scoring ──────────────────────────────────────────────────

# Score likelihood of preventing a specific failure
# memeff_proactive_score <error_signature> [affected_files]
# Returns: probability 0-100 that matching patterns prevent failure
memeff_proactive_score() {
    local error_signature="${1:-}"
    local affected_files="${2:-}"

    [[ -z "$error_signature" ]] && return 1

    memeff_init

    # Search outcomes for patterns matching error_signature
    local matching_patterns=()
    local total_matches=0
    local successful_matches=0

    # Simple pattern matching on error description
    [[ -f "$MEMEFF_OUTCOMES" ]] && while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local error_desc
        error_desc=$(echo "$line" | jq -r '.error_description // ""' 2>/dev/null)

        # Check if error_signature appears in outcomes
        if echo "$error_desc" | grep >/dev/null -iF "$error_signature" 2>/dev/null; then
            total_matches=$((total_matches + 1))

            # Count how many were successfully prevented
            if echo "$line" | jq -e '.avoided_error == true' >/dev/null 2>&1; then
                successful_matches=$((successful_matches + 1))
            fi
        fi
    done < "$MEMEFF_OUTCOMES"

    # Calculate probability
    local probability=0
    if [[ "$total_matches" -gt 0 ]]; then
        probability=$((successful_matches * 100 / total_matches))
    fi

    # Cap between 0-100
    [[ "$probability" -lt 0 ]] && probability=0
    [[ "$probability" -gt 100 ]] && probability=100

    jq -n \
        --arg sig "$error_signature" \
        --argjson prob "$probability" \
        --argjson matches "$total_matches" \
        '{
            error_signature: $sig,
            prevention_probability: $prob,
            matching_patterns: $matches,
            confidence: (if $matches >= 5 then "high" elif $matches >= 2 then "medium" else "low" end)
        }'
}

# ─── 7. Effectiveness Report ───────────────────────────────────────────────

# Generate effectiveness dashboard
# memeff_report [format]
# format: "text" (default) or "json"
memeff_report() {
    local format="${1:-text}"

    memeff_init

    local total_patterns=0
    local avg_score=0
    local total_injections=0

    # Get all rankings
    local rankings
    rankings=$(memeff_rank_patterns 999)

    # Calculate metrics
    if [[ "$rankings" != "[]" ]]; then
        total_patterns=$(echo "$rankings" | jq 'length')
        avg_score=$(echo "$rankings" | jq '[.[].effectiveness_score] | add / length | round')
        total_injections=$(echo "$rankings" | jq '[.[].total_injections] | add')
    fi

    if [[ "$format" == "json" ]]; then
        # Return full JSON report
        jq -cn \
            --argjson total "$total_patterns" \
            --argjson avg "$avg_score" \
            --argjson injections "$total_injections" \
            --argjson top "$( echo "$rankings" | jq '.[0:5]')" \
            --argjson bottom "$( echo "$rankings" | jq '.[-5:]')" \
            '{
                summary: {
                    total_patterns: $total,
                    average_score: $avg,
                    total_injections: $injections
                },
                top_5: $top,
                bottom_5: $bottom
            }'
        return 0
    fi

    # Text format
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║          Memory Pattern Effectiveness Report                      ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Total Patterns: ${total_patterns}"
    echo "  Average Score:  ${avg_score}/100"
    echo "  Total Injections: ${total_injections}"
    echo ""

    if [[ "$total_patterns" -gt 0 ]]; then
        echo "  Top 5 Most Effective Patterns:"
        echo "$rankings" | jq -r '.[:5] | .[] | "    [\(.effectiveness_score)] \(.memory_id) (inj: \(.total_injections))"' || true
        echo ""

        echo "  Bottom 5 Least Effective Patterns:"
        echo "$rankings" | jq -r '.[-5:] | reverse | .[] | "    [\(.effectiveness_score)] \(.memory_id) (inj: \(.total_injections))"' || true
    fi

    echo ""
}

# ─── Integration Helpers ────────────────────────────────────────────────────

# Called by sw-loop.sh when injecting memory context
memeff_on_injection() {
    local memory_id="$1"
    local pipeline_id="$2"
    local stage="$3"
    memeff_track_injection "$memory_id" "$pipeline_id" "$stage" "automated_injection"
}

# Called by sw-pipeline.sh after completion
memeff_on_pipeline_complete() {
    local pipeline_id="$1"
    local outcome="$2"  # success or failure
    local error_context="${3:-}"

    # Find all memories injected in this pipeline
    local injected_memories
    injected_memories=$(grep -E "\"pipeline_id\":\"${pipeline_id}\"" "$MEMEFF_INJECTIONS" 2>/dev/null | \
        jq -r '.memory_id' | sort -u || true)

    while IFS= read -r memory_id; do
        [[ -z "$memory_id" ]] && continue
        memeff_track_outcome "$memory_id" "$pipeline_id" "$outcome" "$error_context"
    done <<< "$injected_memories"
}

# Export for sourcing
return 0
