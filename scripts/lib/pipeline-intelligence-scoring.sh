# pipeline-intelligence-scoring.sh — Complexity scoring and adaptation for pipeline-intelligence.sh
# Source from pipeline-intelligence.sh. Requires state, ARTIFACTS_DIR.
[[ -n "${_PIPELINE_INTELLIGENCE_SCORING_LOADED:-}" ]] && return 0
_PIPELINE_INTELLIGENCE_SCORING_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NO_GITHUB="${NO_GITHUB:-false}"

pipeline_adaptive_cycles() {
    local base_limit="$1"
    local context="${2:-compound_quality}"  # compound_quality or build_test
    local current_issue_count="${3:-0}"
    local prev_issue_count="${4:--1}"

    local adjusted="$base_limit"
    local hard_ceiling=$((base_limit * 2))

    # ── Learned iteration model ──
    local model_file="${HOME}/.shipwright/optimization/iteration-model.json"
    if [[ -f "$model_file" ]]; then
        local learned
        learned=$(jq -r --arg ctx "$context" '.[$ctx].recommended_cycles // 0' "$model_file" 2>/dev/null || echo "0")
        if [[ "$learned" -gt 0 && "$learned" -le "$hard_ceiling" ]]; then
            adjusted="$learned"
        fi
    fi

    # ── Convergence acceleration ──
    # If issue count drops >50% per cycle, extend limit by 1 (we're making progress)
    if [[ "$prev_issue_count" -gt 0 && "$current_issue_count" -ge 0 ]]; then
        local half_prev=$((prev_issue_count / 2))
        if [[ "$current_issue_count" -le "$half_prev" && "$current_issue_count" -gt 0 ]]; then
            # Rapid convergence — extend by 1
            local new_limit=$((adjusted + 1))
            if [[ "$new_limit" -le "$hard_ceiling" ]]; then
                adjusted="$new_limit"
                emit_event "intelligence.convergence_acceleration" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "context=$context" \
                    "prev_issues=$prev_issue_count" \
                    "current_issues=$current_issue_count" \
                    "new_limit=$adjusted"
            fi
        fi

        # ── Divergence detection ──
        # If issue count increases, reduce remaining cycles
        if [[ "$current_issue_count" -gt "$prev_issue_count" ]]; then
            local reduced=$((adjusted - 1))
            if [[ "$reduced" -ge 1 ]]; then
                adjusted="$reduced"
                emit_event "intelligence.divergence_detected" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "context=$context" \
                    "prev_issues=$prev_issue_count" \
                    "current_issues=$current_issue_count" \
                    "new_limit=$adjusted"
            fi
        fi
    fi

    # ── Budget gate ──
    if [[ "$IGNORE_BUDGET" != "true" ]] && [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
        local budget_rc=0
        bash "$SCRIPT_DIR/sw-cost.sh" check-budget 2>/dev/null || budget_rc=$?
        if [[ "$budget_rc" -eq 2 ]]; then
            # Budget exhausted — cap at current cycle
            adjusted=0
            emit_event "intelligence.budget_cap" \
                "issue=${ISSUE_NUMBER:-0}" \
                "context=$context"
        fi
    fi

    # ── Enforce hard ceiling ──
    if [[ "$adjusted" -gt "$hard_ceiling" ]]; then
        adjusted="$hard_ceiling"
    fi

    echo "$adjusted"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Intelligent Audit Selection
# AI-driven audit selection — all audits enabled, intensity varies.

pipeline_select_audits() {
    local audit_intensity
    audit_intensity=$(jq -r --arg id "compound_quality" \
        '(.stages[] | select(.id == $id) | .config.audit_intensity) // "auto"' \
        "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$audit_intensity" || "$audit_intensity" == "null" ]] && audit_intensity="auto"

    # Short-circuit for explicit overrides
    case "$audit_intensity" in
        off)
            echo '{"adversarial":"off","architecture":"off","simulation":"off","security":"off","dod":"off"}'
            return 0
            ;;
        full|lightweight)
            jq -n --arg i "$audit_intensity" \
                '{adversarial:$i,architecture:$i,simulation:$i,security:$i,dod:$i}'
            return 0
            ;;
    esac

    # ── Auto mode: data-driven intensity ──
    local default_intensity="targeted"
    local security_intensity="targeted"

    # Read last 5 quality scores for this repo
    local quality_scores_file="${HOME}/.shipwright/optimization/quality-scores.jsonl"
    local repo_name
    repo_name=$(basename "${PROJECT_ROOT:-.}") || true
    if [[ -f "$quality_scores_file" ]]; then
        local recent_scores
        recent_scores=$(grep "\"repo\":\"${repo_name}\"" "$quality_scores_file" 2>/dev/null | tail -5) || true
        if [[ -n "$recent_scores" ]]; then
            # Check for critical findings in recent history
            local has_critical
            has_critical=$(echo "$recent_scores" | jq -s '[.[].findings.critical // 0] | add' 2>/dev/null || echo "0")
            has_critical="${has_critical:-0}"
            if [[ "$has_critical" -gt 0 ]]; then
                security_intensity="full"
            fi

            # Compute average quality score
            local avg_score
            avg_score=$(echo "$recent_scores" | jq -s 'if length > 0 then ([.[].quality_score] | add / length | floor) else 70 end' 2>/dev/null || echo "70")
            avg_score="${avg_score:-70}"

            if [[ "$avg_score" -lt 60 ]]; then
                default_intensity="full"
                security_intensity="full"
            elif [[ "$avg_score" -gt 80 ]]; then
                default_intensity="lightweight"
                [[ "$security_intensity" != "full" ]] && security_intensity="lightweight"
            fi
        fi
    fi

    # Intelligence cache: upgrade targeted→full for complex changes
    local intel_cache="${SHIPWRIGHT_INTELLIGENCE_CACHE:-${PROJECT_ROOT}/.claude/intelligence-cache.json}"
    if [[ -f "$intel_cache" && "$default_intensity" == "targeted" ]]; then
        local complexity
        complexity=$(jq -r '.complexity // "medium"' "$intel_cache" 2>/dev/null || echo "medium")
        if [[ "$complexity" == "high" || "$complexity" == "very_high" ]]; then
            default_intensity="full"
            security_intensity="full"
        fi
    fi

    emit_event "pipeline.audit_selection" \
        "issue=${ISSUE_NUMBER:-0}" \
        "default_intensity=$default_intensity" \
        "security_intensity=$security_intensity" \
        "repo=$repo_name"

    jq -n \
        --arg adv "$default_intensity" \
        --arg arch "$default_intensity" \
        --arg sim "$default_intensity" \
        --arg sec "$security_intensity" \
        --arg dod "$default_intensity" \
        '{adversarial:$adv,architecture:$arch,simulation:$sim,security:$sec,dod:$dod}'
}

pipeline_record_quality_score() {
    local quality_score="${1:-0}"
    local critical="${2:-0}"
    local major="${3:-0}"
    local minor="${4:-0}"
    local dod_pass_rate="${5:-0}"
    local audits_run="${6:-}"

    local scores_dir="${HOME}/.shipwright/optimization"
    local scores_file="${scores_dir}/quality-scores.jsonl"
    mkdir -p "$scores_dir"

    local repo_name
    repo_name=$(basename "${PROJECT_ROOT:-.}") || true

    local tmp_score
    tmp_score=$(mktemp)
    jq -n \
        --arg repo "$repo_name" \
        --arg issue "${ISSUE_NUMBER:-0}" \
        --arg ts "$(now_iso)" \
        --argjson score "$quality_score" \
        --argjson critical "$critical" \
        --argjson major "$major" \
        --argjson minor "$minor" \
        --argjson dod "$dod_pass_rate" \
        --arg template "${PIPELINE_NAME:-standard}" \
        --arg audits "$audits_run" \
        '{
            repo: $repo,
            issue: ($issue | tonumber),
            timestamp: $ts,
            quality_score: $score,
            findings: {critical: $critical, major: $major, minor: $minor},
            dod_pass_rate: $dod,
            template: $template,
            audits_run: ($audits | split(",") | map(select(. != "")))
        }' > "$tmp_score" 2>/dev/null

    cat "$tmp_score" >> "$scores_file"
    rm -f "$tmp_score"

    # Rotate quality scores file to prevent unbounded growth
    type rotate_jsonl >/dev/null 2>&1 && rotate_jsonl "$scores_file" 5000

    emit_event "pipeline.quality_score_recorded" \
        "issue=${ISSUE_NUMBER:-0}" \
        "quality_score=$quality_score" \
        "critical=$critical" \
        "major=$major" \
        "minor=$minor"
}


pipeline_reassess_complexity() {
    local initial_complexity="${INTELLIGENCE_COMPLEXITY:-5}"
    local reassessment_file="$ARTIFACTS_DIR/reassessment.json"

    # ── Gather actual metrics ──
    local files_changed=0 lines_changed=0 first_try_pass=false self_heal_cycles=0

    files_changed=$(git diff "${BASE_BRANCH:-main}...HEAD" --name-only 2>/dev/null | wc -l | tr -d ' ') || files_changed=0
    files_changed="${files_changed:-0}"

    # Count lines changed (insertions + deletions) without pipefail issues
    lines_changed=0
    local _diff_stat
    _diff_stat=$(git diff "${BASE_BRANCH:-main}...HEAD" --stat 2>/dev/null | tail -1) || true
    if [[ -n "${_diff_stat:-}" ]]; then
        local _ins _del
        _ins=$(echo "$_diff_stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+') || true
        _del=$(echo "$_diff_stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+') || true
        lines_changed=$(( ${_ins:-0} + ${_del:-0} ))
    fi

    self_heal_cycles="${SELF_HEAL_COUNT:-0}"
    if [[ "$self_heal_cycles" -eq 0 ]]; then
        first_try_pass=true
    fi

    # ── Compare to expectations ──
    local actual_complexity="$initial_complexity"
    local assessment="as_expected"
    local skip_stages="[]"

    # Simpler than expected: small diff, tests passed first try
    if [[ "$lines_changed" -lt 50 && "$first_try_pass" == "true" && "$files_changed" -lt 5 ]]; then
        actual_complexity=$((initial_complexity > 2 ? initial_complexity - 2 : 1))
        assessment="simpler_than_expected"
        # Mark compound_quality as skippable, simplify review
        skip_stages='["compound_quality"]'
    # Much simpler
    elif [[ "$lines_changed" -lt 20 && "$first_try_pass" == "true" && "$files_changed" -lt 3 ]]; then
        actual_complexity=1
        assessment="much_simpler"
        skip_stages='["compound_quality","review"]'
    # Harder than expected: large diff, multiple self-heal cycles
    elif [[ "$lines_changed" -gt 500 || "$self_heal_cycles" -gt 2 ]]; then
        actual_complexity=$((initial_complexity < 9 ? initial_complexity + 2 : 10))
        assessment="harder_than_expected"
        # Ensure compound_quality runs, possibly upgrade model
        skip_stages='[]'
    # Much harder
    elif [[ "$lines_changed" -gt 1000 || "$self_heal_cycles" -gt 4 ]]; then
        actual_complexity=10
        assessment="much_harder"
        skip_stages='[]'
    fi

    # ── Write reassessment ──
    local tmp_reassess
    tmp_reassess="$(mktemp)"
    jq -n \
        --argjson initial "$initial_complexity" \
        --argjson actual "$actual_complexity" \
        --arg assessment "$assessment" \
        --argjson files_changed "$files_changed" \
        --argjson lines_changed "$lines_changed" \
        --argjson self_heal_cycles "$self_heal_cycles" \
        --argjson first_try "$first_try_pass" \
        --argjson skip_stages "$skip_stages" \
        '{
            initial_complexity: $initial,
            actual_complexity: $actual,
            assessment: $assessment,
            files_changed: $files_changed,
            lines_changed: $lines_changed,
            self_heal_cycles: $self_heal_cycles,
            first_try_pass: $first_try,
            skip_stages: $skip_stages
        }' > "$tmp_reassess" 2>/dev/null && mv "$tmp_reassess" "$reassessment_file" || rm -f "$tmp_reassess"

    # Update global complexity for downstream stages
    PIPELINE_ADAPTIVE_COMPLEXITY="$actual_complexity"

    emit_event "intelligence.reassessment" \
        "issue=${ISSUE_NUMBER:-0}" \
        "initial=$initial_complexity" \
        "actual=$actual_complexity" \
        "assessment=$assessment" \
        "files=$files_changed" \
        "lines=$lines_changed" \
        "self_heals=$self_heal_cycles"

    # ── Store for learning ──
    local learning_file="${HOME}/.shipwright/optimization/complexity-actuals.jsonl"
    mkdir -p "${HOME}/.shipwright/optimization" 2>/dev/null || true
    echo "{\"issue\":\"${ISSUE_NUMBER:-0}\",\"initial\":$initial_complexity,\"actual\":$actual_complexity,\"files\":$files_changed,\"lines\":$lines_changed,\"ts\":\"$(now_iso)\"}" \
        >> "$learning_file" 2>/dev/null || true

    echo "$assessment"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Backtracking Support
# When compound_quality detects architecture-level problems, backtracks to
# the design stage instead of just feeding findings to the build loop.

pipeline_backtrack_to_stage() {
    local target_stage="$1"
    local reason="${2:-architecture_violation}"

    # Prevent infinite backtracking
    if [[ "$PIPELINE_BACKTRACK_COUNT" -ge "$PIPELINE_MAX_BACKTRACKS" ]]; then
        warn "Max backtracks ($PIPELINE_MAX_BACKTRACKS) reached — cannot backtrack to $target_stage"
        emit_event "intelligence.backtrack_blocked" \
            "issue=${ISSUE_NUMBER:-0}" \
            "target=$target_stage" \
            "reason=max_backtracks_reached" \
            "count=$PIPELINE_BACKTRACK_COUNT"
        return 1
    fi

    PIPELINE_BACKTRACK_COUNT=$((PIPELINE_BACKTRACK_COUNT + 1))

    info "Backtracking to ${BOLD}${target_stage}${RESET} stage (reason: ${reason})"

    emit_event "intelligence.backtrack" \
        "issue=${ISSUE_NUMBER:-0}" \
        "target=$target_stage" \
        "reason=$reason"

    # Gather architecture context from findings
    local arch_context=""
    if [[ -f "$ARTIFACTS_DIR/compound-architecture-validation.json" ]]; then
        arch_context=$(jq -r '[.[] | select(.severity == "critical" or .severity == "high") | .message // .description // ""] | join("\n")' \
            "$ARTIFACTS_DIR/compound-architecture-validation.json" 2>/dev/null || true)
    fi
    if [[ -f "$ARTIFACTS_DIR/adversarial-review.md" ]]; then
        local arch_lines
        arch_lines=$(grep -iE 'architect|layer.*violation|circular.*depend|coupling|design.*flaw' \
            "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
        if [[ -n "$arch_lines" ]]; then
            arch_context="${arch_context}
${arch_lines}"
        fi
    fi

    # Reset stages from target onward
    set_stage_status "$target_stage" "pending"
    set_stage_status "build" "pending"
    set_stage_status "test" "pending"

    # Augment goal with architecture context for re-run
    local original_goal="$GOAL"
    if [[ -n "$arch_context" ]]; then
        GOAL="$GOAL

IMPORTANT — Architecture violations were detected during quality review. Redesign to fix:
$arch_context

Update the design to address these violations, then rebuild."
    fi

    # Re-run design stage
    info "Re-running ${BOLD}${target_stage}${RESET} with architecture context..."
    if "stage_${target_stage}" 2>/dev/null; then
        mark_stage_complete "$target_stage"
        success "Backtrack: ${target_stage} re-run complete"
    else
        GOAL="$original_goal"
        error "Backtrack: ${target_stage} re-run failed"
        return 1
    fi

    # Re-run build+test
    info "Re-running build→test after backtracked ${target_stage}..."
    if self_healing_build_test; then
        success "Backtrack: build→test passed after ${target_stage} redesign"
        GOAL="$original_goal"
        return 0
    else
        GOAL="$original_goal"
        error "Backtrack: build→test failed after ${target_stage} redesign"
        return 1
    fi
}

