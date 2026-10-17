# pipeline-stages-review.sh — review, compound_quality, audit stages

# Agents run without GitHub credentials (#8614): claude is launched through agent-exec.sh.
SW_AGENT_EXEC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-exec.sh"
# Source from pipeline-stages.sh. Requires all pipeline globals and dependencies.
# Test commands run without credentials (#8608).
# shellcheck source=lib/test-gate-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-gate-env.sh"
[[ -n "${_PIPELINE_STAGES_REVIEW_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_REVIEW_LOADED=1

stage_review() {
    CURRENT_STAGE_ID="review"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-review.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _review_retry_hints
        _review_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi
    local diff_file="$ARTIFACTS_DIR/review-diff.patch"
    local review_file="$ARTIFACTS_DIR/review.md"

    _safe_base_diff > "$diff_file" 2>/dev/null || true

    if [[ ! -s "$diff_file" ]]; then
        warn "No diff found — skipping review"
        return 0
    fi

    if ! command -v claude >/dev/null 2>&1; then
        warn "Claude CLI not found — skipping AI review"
        return 0
    fi

    local diff_stats
    diff_stats=$(_safe_base_diff --stat | tail -1 || echo "")
    info "Running AI code review... ${DIM}($diff_stats)${RESET}"

    # Semantic risk scoring when intelligence is enabled
    if type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
        local diff_files
        diff_files=$(_safe_base_diff --name-only || true)
        local risk_score="low"
        # Fast heuristic: flag high-risk file patterns
        if echo "$diff_files" | grep >/dev/null -iE 'migration|schema|auth|crypto|security|password|token|secret|\.env'; then
            risk_score="high"
        elif echo "$diff_files" | grep >/dev/null -iE 'api|route|controller|middleware|hook'; then
            risk_score="medium"
        fi
        emit_event "review.risk_assessed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "risk=$risk_score" \
            "files_changed=$(echo "$diff_files" | wc -l | xargs)"
        if [[ "$risk_score" == "high" ]]; then
            warn "High-risk changes detected (DB schema, auth, crypto, or secrets)"
        fi
    fi

    local review_model="${MODEL:-opus}"
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        review_model="$CLAUDE_MODEL"
    fi

    # Build adversarial review prompt with project context
    local review_prompt="You are a SKEPTICAL senior engineer reviewing code for production.
Your job is to FIND PROBLEMS, not confirm quality.

For each issue found, use this format:
- **[SEVERITY]** file:line — description

Severity levels: Critical, Bug, Security, Warning, Suggestion

Mandatory requirements:
1. Find at least 3 issues (or explain why code is exceptional)
2. Check EVERY acceptance criterion — mark PASS/FAIL with evidence
3. Flag every scope creep (unplanned files)
4. Verify all never-ship rules are not violated
5. Assess all always-require rules are met

Focus areas:
1. Logic bugs and edge cases
2. Security vulnerabilities (injection, XSS, auth bypass, etc.)
3. Error handling gaps
4. Performance issues
5. Missing validation
6. Project convention violations (see standards below)
7. Architectural constraint violations
8. Data validation and sanitization gaps

Be thorough and adversarial. Only accept exceptional code without issues.
"

    # Dark factory: inject spec compliance check into review
    local spec_file="${ARTIFACTS_DIR}/spec.json"
    if [[ -f "$spec_file" ]] && type spec_diff >/dev/null 2>&1; then
        SPEC_DIR="${ARTIFACTS_DIR}/specs"
        local compliance_report
        compliance_report=$(spec_diff "$spec_file" "${PROJECT_ROOT:-.}" 2>/dev/null || true)
        if [[ -n "$compliance_report" && -f "$compliance_report" ]]; then
            local verdict
            verdict=$(jq -r '.verdict // "unknown"' "$compliance_report" 2>/dev/null || echo "unknown")
            if [[ "$verdict" == "review_needed" ]]; then
                local unmod_files
                unmod_files=$(jq -r '.file_coverage.unmodified_files[]?' "$compliance_report" 2>/dev/null | head -5 || true)
                review_prompt+="
## Spec Compliance Warning
The specification expected changes to files that were NOT modified:
${unmod_files}
Check if these files should have been changed to meet the spec goals.
"
            fi
        fi
    fi

    # Inject quality profile standards (never-ship, always-require, focus areas)
    local quality_profile="${PROJECT_ROOT}/.claude/quality-profile.json"
    if [[ -f "$quality_profile" ]]; then
        local never_ship_rules always_require_rules focus_areas learned_rules

        never_ship_rules=$(jq -r '.quality.never_ship[]? // empty' "$quality_profile" 2>/dev/null | sed 's/^/  - /')
        if [[ -n "$never_ship_rules" ]]; then
            review_prompt+="
## Project Standards — NEVER SHIP Rules
These are absolute violations that must be caught:
${never_ship_rules}
"
        fi

        always_require_rules=$(jq -r '.quality.always_require[]? // empty' "$quality_profile" 2>/dev/null | sed 's/^/  - /')
        if [[ -n "$always_require_rules" ]]; then
            review_prompt+="
## Project Standards — ALWAYS REQUIRE
These must be present in this PR:
${always_require_rules}
"
        fi

        focus_areas=$(jq -r '.review.focus_areas[]? // empty' "$quality_profile" 2>/dev/null | sed 's/^/  - /')
        if [[ -n "$focus_areas" ]]; then
            review_prompt+="
## Review Focus Areas
Pay extra attention to these areas for this project:
${focus_areas}
"
        fi

        learned_rules=$(jq -r '.quality.learned_rules[]? | "\(.rule) (source: \(.source), confidence: \(.confidence))" | @base64' "$quality_profile" 2>/dev/null | while read -r encoded; do
            [[ -z "$encoded" ]] && continue
            echo "$encoded" | base64 -d 2>/dev/null || true
        done | sed 's/^/  - /')
        if [[ -n "$learned_rules" ]]; then
            review_prompt+="
## Learned Rules from Previous Reviews
These patterns were discovered from past code review findings:
${learned_rules}
"
        fi
    fi

    # Inject acceptance criteria from intake stage
    local acceptance_file="$ARTIFACTS_DIR/acceptance-criteria.json"
    if [[ -f "$acceptance_file" ]]; then
        local ac_list
        ac_list=$(jq -r '.acceptance_criteria[]? // empty' "$acceptance_file" 2>/dev/null | sed 's/^/  - /')
        if [[ -n "$ac_list" ]]; then
            review_prompt+="
## Definition of Done (Acceptance Criteria)
Verify EVERY criterion below is met:
${ac_list}
"
        fi
    fi

    # Inject scope report (planned vs actual files)
    local scope_file="$ARTIFACTS_DIR/scope-report.json"
    if [[ -f "$scope_file" ]]; then
        local planned_files unplanned_files
        planned_files=$(jq -r '.planned_files[]? // empty' "$scope_file" 2>/dev/null | sed 's/^/  - /')
        unplanned_files=$(jq -r '.unplanned_files[]? // empty' "$scope_file" 2>/dev/null | sed 's/^/  - UNPLANNED: /')

        if [[ -n "$planned_files" ]]; then
            review_prompt+="
## Scope Report
Planned files to modify:
${planned_files}
"
        fi
        if [[ -n "$unplanned_files" ]]; then
            review_prompt+="
Unplanned files changed (scope creep?):
${unplanned_files}
"
        fi
    fi

    # Inject previous review findings and anti-patterns from memory
    if type intelligence_search_memory >/dev/null 2>&1; then
        local review_memory
        review_memory=$(intelligence_search_memory "code review findings anti-patterns for: ${GOAL:-}" "${HOME}/.shipwright/memory" 5 2>/dev/null) || true
        review_memory=$(prune_context_section "memory" "$review_memory" 10000)
        if [[ -n "$review_memory" ]]; then
            review_prompt+="
## Known Issues from Previous Reviews
These anti-patterns and issues have been found in past reviews of this codebase. Flag them if they recur:
${review_memory}
"
        fi
    fi

    # Inject project conventions if a conventions file exists
    local claudemd="" _conv_file
    # Repo conventions: .claude/CLAUDE.md, then CLAUDE.md, then AGENTS.md (skip @-import-only stubs)
    for _conv_file in "$PROJECT_ROOT/.claude/CLAUDE.md" "$PROJECT_ROOT/CLAUDE.md" "$PROJECT_ROOT/AGENTS.md"; do
        if [[ -f "$_conv_file" ]] && grep -qvE '^[[:space:]]*(@[^[:space:]]+)?[[:space:]]*$' "$_conv_file" 2>/dev/null; then
            claudemd="$_conv_file"
            break
        fi
    done
    if [[ -n "$claudemd" ]]; then
        local conventions
        conventions=$(grep -A2 'Common Pitfalls\|Shell Standards\|Bash 3.2' "$claudemd" 2>/dev/null | head -20 || true)
        if [[ -n "$conventions" ]]; then
            review_prompt+="
## Project Conventions
${conventions}
"
        fi
    fi

    # ── Constitutional AI: deterministic principle-based checks ──
    if type constitutional_load >/dev/null 2>&1; then
        if constitutional_load 2>/dev/null; then
            local constitution_violations
            constitution_violations=$(constitutional_self_critique "$BASE_BRANCH" 2>/dev/null) || true
            constitution_violations="${constitution_violations:-0}"
            if [[ "$constitution_violations" -gt 0 ]]; then
                local constitution_prompt
                constitution_prompt=$(constitutional_inject_prompt "" "high" 2>/dev/null || true)
                if [[ -n "$constitution_prompt" ]]; then
                    review_prompt+="
${constitution_prompt}
"
                fi
            fi
        fi
    fi

    # Inject CODEOWNERS focus areas for review
    if [[ "${NO_GITHUB:-}" != "true" ]] && type gh_codeowners >/dev/null 2>&1; then
        local review_owners
        review_owners=$(gh_codeowners 2>/dev/null | head -10 || true)
        if [[ -n "$review_owners" ]]; then
            review_prompt+="
## Code Owners (focus areas)
${review_owners}
"
        fi
    fi

    # Inject Definition of Done if present
    local dod_file="$PROJECT_ROOT/.claude/DEFINITION-OF-DONE.md"
    if [[ -f "$dod_file" ]]; then
        review_prompt+="
## Definition of Done (verify these)
$(cat "$dod_file")
"
    fi

    # Inject skill prompts for review stage
    # Prefer adaptive selection when available
    if type skill_select_adaptive >/dev/null 2>&1; then
        local _review_skill_files _review_skills
        _review_skill_files=$(skill_select_adaptive "${INTELLIGENCE_ISSUE_TYPE:-backend}" "review" "${ISSUE_BODY:-}" "${INTELLIGENCE_COMPLEXITY:-5}" 2>/dev/null || true)
        if [[ -n "$_review_skill_files" ]]; then
            _review_skills=$(while IFS= read -r _path; do
                [[ -z "$_path" ]] && continue
                [[ -f "$_path" ]] && cat "$_path" 2>/dev/null
            done <<< "$_review_skill_files")
            if [[ -n "$_review_skills" ]]; then
                _review_skills=$(prune_context_section "review-skills" "$_review_skills" 5000)
                review_prompt+="
## Review Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue)
${_review_skills}
"
            fi
        fi
    elif type skill_load_prompts >/dev/null 2>&1; then
        # Fallback to static selection
        local _review_skills
        _review_skills=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "review" 2>/dev/null || true)
        if [[ -n "$_review_skills" ]]; then
            _review_skills=$(prune_context_section "review-skills" "$_review_skills" 5000)
            review_prompt+="
## Review Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue)
${_review_skills}
"
        fi
    fi

    review_prompt+="
## Diff to Review
$(cat "$diff_file")"

    # Inject skill prompts for review stage
    _skill_prompts=""
    if type skill_load_from_plan >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_from_plan "review" 2>/dev/null || true)
    elif type skill_select_adaptive >/dev/null 2>&1; then
        local _skill_files
        _skill_files=$(skill_select_adaptive "${INTELLIGENCE_ISSUE_TYPE:-backend}" "review" "${ISSUE_BODY:-}" "${INTELLIGENCE_COMPLEXITY:-5}" 2>/dev/null || true)
        if [[ -n "$_skill_files" ]]; then
            _skill_prompts=$(while IFS= read -r _path; do
                [[ -z "$_path" || ! -f "$_path" ]] && continue
                cat "$_path" 2>/dev/null
            done <<< "$_skill_files")
        fi
    elif type skill_load_prompts >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "review" 2>/dev/null || true)
    fi
    if [[ -n "$_skill_prompts" ]]; then
        _skill_prompts=$(prune_context_section "skills" "$_skill_prompts" 8000)
        review_prompt="${review_prompt}
## Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue, AI-selected)
${_skill_prompts}
"
    fi

    # Guard total prompt size
    review_prompt=$(guard_prompt_size "review" "$review_prompt")

    # Skip permissions — pipeline runs headlessly (claude -p) and has no terminal
    # for interactive permission prompts. Same rationale as build stage (line ~1083).
    local review_args=(--print)
    local _review_flags
    _review_flags="$(_pipeline_claude_flags "review" "$review_model")"
    # shellcheck disable=SC2206
    review_args+=($_review_flags --max-turns "$(_smart_int "max_turns.pipeline_stage" 25)" --dangerously-skip-permissions)

    # ── Two-Stage Review: Pass 1 (Spec Compliance) ──
    local _two_stage=false
    if type skill_has_two_stage_review >/dev/null 2>&1 && skill_has_two_stage_review "${INTELLIGENCE_ISSUE_TYPE:-backend}"; then
        _two_stage=true
        local spec_review_file="$ARTIFACTS_DIR/review-spec.md"
        local plan_file="$ARTIFACTS_DIR/plan.md"

        if [[ -s "$plan_file" ]]; then
            info "Two-stage review: Pass 1 — Spec compliance"
            local spec_prompt="You are a spec compliance reviewer. Compare the implementation against the plan.

## Plan
$(cat "$plan_file" 2>/dev/null | head -200)

## Implementation Diff
$(cat "$diff_file" 2>/dev/null)

## Task
Compare the diff against the plan:
1. Does the code implement every task from the plan's checklist?
2. Were all planned files actually modified?
3. Is anything from the plan NOT implemented?
4. Was anything added that WASN'T in the plan?

For each gap found:
- **[SPEC-GAP]** description — what was planned vs what was implemented

If all requirements are met, write: \"Spec compliance: PASS — all planned tasks implemented.\"
"
            spec_prompt=$(guard_prompt_size "spec-review" "$spec_prompt")
            "$SW_AGENT_EXEC" claude "${review_args[@]}" "$spec_prompt" < /dev/null > "$spec_review_file" 2>"${ARTIFACTS_DIR}/.claude-tokens-spec-review.log" || true
            parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-spec-review.log"

            if [[ -s "$spec_review_file" ]]; then
                local spec_gaps
                spec_gaps=$(grep -c 'SPEC-GAP' "$spec_review_file" 2>/dev/null || true)
                spec_gaps="${spec_gaps:-0}"
                if [[ "$spec_gaps" -gt 0 ]]; then
                    warn "Spec review found $spec_gaps gap(s) — see $spec_review_file"
                else
                    success "Spec compliance: PASS"
                fi
                emit_event "review.spec_complete" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "gaps=$spec_gaps"
            fi
            info "Two-stage review: Pass 2 — Code quality"
        fi
    fi

    "$SW_AGENT_EXEC" claude "${review_args[@]}" "$review_prompt" < /dev/null > "$review_file" 2>"${ARTIFACTS_DIR}/.claude-tokens-review.log" || true
    parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-review.log"

    if [[ ! -s "$review_file" ]]; then
        warn "Review produced no output — check ${ARTIFACTS_DIR}/.claude-tokens-review.log for errors"
        return 0
    fi

    # Extract severity counts — try JSON structure first, then grep fallback
    local critical_count=0 bug_count=0 warning_count=0

    # Check if review output is structured JSON (e.g. from structured review tools)
    local json_parsed=false
    if head -1 "$review_file" 2>/dev/null | grep >/dev/null '^{' 2>/dev/null; then
        local j_critical j_bug j_warning
        j_critical=$(jq -r '.issues | map(select(.severity == "Critical")) | length' "$review_file" 2>/dev/null || echo "")
        if [[ -n "$j_critical" && "$j_critical" != "null" ]]; then
            critical_count="$j_critical"
            bug_count=$(jq -r '.issues | map(select(.severity == "Bug" or .severity == "Security")) | length' "$review_file" 2>/dev/null || echo "0")
            warning_count=$(jq -r '.issues | map(select(.severity == "Warning" or .severity == "Suggestion")) | length' "$review_file" 2>/dev/null || echo "0")
            json_parsed=true
        fi
    fi

    # Grep fallback for markdown-formatted review output
    if [[ "$json_parsed" != "true" ]]; then
        critical_count=$(grep -ciE '\*\*\[?Critical\]?\*\*' "$review_file" 2>/dev/null || true)
        critical_count="${critical_count:-0}"
        bug_count=$(grep -ciE '\*\*\[?(Bug|Security)\]?\*\*' "$review_file" 2>/dev/null || true)
        bug_count="${bug_count:-0}"
        warning_count=$(grep -ciE '\*\*\[?(Warning|Suggestion)\]?\*\*' "$review_file" 2>/dev/null || true)
        warning_count="${warning_count:-0}"
    fi
    local total_issues=$((critical_count + bug_count + warning_count))

    if [[ "$critical_count" -gt 0 ]]; then
        error "Review found ${BOLD}$critical_count critical${RESET} issue(s) — see $review_file"
    elif [[ "$bug_count" -gt 0 ]]; then
        warn "Review found $bug_count bug/security issue(s) — see ${DIM}$review_file${RESET}"
    elif [[ "$total_issues" -gt 0 ]]; then
        info "Review found $total_issues suggestion(s)"
    else
        success "Review clean"
    fi

    # ── Dark factory: formal spec verification ──
    if type formal_spec_extract >/dev/null 2>&1; then
        local _spec_file="${ARTIFACTS_DIR}/formal-specs.json"
        local _spec_report="${ARTIFACTS_DIR}/formal-spec-report.json"
        local diff_files_for_spec
        diff_files_for_spec=$(_safe_base_diff --name-only 2>/dev/null || true)
        if [[ -n "$diff_files_for_spec" ]]; then
            formal_spec_extract "${PROJECT_ROOT:-.}" "$_spec_file" >/dev/null 2>&1 || true
            if [[ -f "$_spec_file" ]]; then
                local _spec_count
                _spec_count=$(jq -r '.count // 0' "$_spec_file" 2>/dev/null || echo "0")
                if [[ "$_spec_count" -gt 0 ]]; then
                    formal_spec_verify "$_spec_file" "${PROJECT_ROOT:-.}" "$_spec_report" >/dev/null 2>&1 || true
                    if [[ -f "$_spec_report" ]]; then
                        local _spec_violations _spec_pct
                        _spec_violations=$(jq -r '.violations // 0' "$_spec_report" 2>/dev/null || echo "0")
                        _spec_pct=$(jq -r '.compliance_pct // 100' "$_spec_report" 2>/dev/null || echo "100")
                        if [[ "$_spec_violations" -gt 0 ]]; then
                            warn "Formal spec verification: ${_spec_violations} violation(s), ${_spec_pct}% compliance"
                        else
                            success "Formal spec verification: ${_spec_pct}% compliance"
                        fi
                        emit_event "review.formal_spec" \
                            "issue=${ISSUE_NUMBER:-0}" \
                            "violations=$_spec_violations" \
                            "compliance_pct=$_spec_pct" 2>/dev/null || true
                    fi
                fi
            fi
        fi
    fi

    # ── Oversight gate: pipeline review/quality stages block on verdict ──
    if [[ -x "$SCRIPT_DIR/sw-oversight.sh" ]] && [[ "${SKIP_GATES:-false}" != "true" ]]; then
        local reject_reason=""
        local _sec_count
        _sec_count=$(grep -ciE '\*\*\[?Security\]?\*\*' "$review_file" 2>/dev/null || true)
        _sec_count="${_sec_count:-0}"
        local _blocking=$((critical_count + _sec_count))
        [[ "$_blocking" -gt 0 ]] && reject_reason="Review found ${_blocking} critical/security issue(s)"
        if ! bash "$SCRIPT_DIR/sw-oversight.sh" gate --diff "$diff_file" --description "${GOAL:-Pipeline review}" --reject-if "$reject_reason" >/dev/null 2>&1; then
            error "Oversight gate rejected — blocking pipeline"
            emit_event "review.oversight_blocked" "issue=${ISSUE_NUMBER:-0}"
            log_stage "review" "BLOCKED: oversight gate rejected"
            return 1
        fi
    fi

    # ── Review Blocking Gate ──
    # Block pipeline on critical/bug/security issues (bugs now block as per spec)
    local security_count
    security_count=$(grep -ciE '\*\*\[?Security\]?\*\*' "$review_file" 2>/dev/null || true)
    security_count="${security_count:-0}"

    local blocking_issues=$((critical_count + bug_count + security_count))

    if [[ "$blocking_issues" -gt 0 ]]; then
        # Check if compound_quality stage is enabled — if so, let it handle issues
        local compound_enabled="false"
        if [[ -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-/dev/null}" ]]; then
            compound_enabled=$(jq -r '.stages[] | select(.id == "compound_quality") | .enabled' "$PIPELINE_CONFIG" 2>/dev/null) || true
            [[ -z "$compound_enabled" || "$compound_enabled" == "null" ]] && compound_enabled="false"
        fi

        # Check if this is a fast template (don't block fast pipelines)
        local is_fast="false"
        if [[ "${PIPELINE_NAME:-}" == "fast" || "${PIPELINE_NAME:-}" == "hotfix" ]]; then
            is_fast="true"
        fi

        if [[ "$compound_enabled" == "true" ]]; then
            info "Review found ${blocking_issues} critical/security issue(s) — compound_quality stage will handle"
        elif [[ "$is_fast" == "true" ]]; then
            warn "Review found ${blocking_issues} critical/security issue(s) — fast template, not blocking"
        elif [[ "${SKIP_GATES:-false}" == "true" ]]; then
            warn "Review found ${blocking_issues} critical/security issue(s) — skip-gates mode, not blocking"
        else
            error "Review found ${BOLD}${blocking_issues} critical/security issue(s)${RESET} — blocking pipeline"
            emit_event "review.blocked" \
                "issue=${ISSUE_NUMBER:-0}" \
                "critical=${critical_count}" \
                "security=${security_count}"

            # Save blocking issues for self-healing context
            grep -iE '\*\*\[?(Critical|Security)\]?\*\*' "$review_file" > "$ARTIFACTS_DIR/review-blockers.md" 2>/dev/null || true

            # Post review to GitHub before failing
            if [[ -n "$ISSUE_NUMBER" ]]; then
                local review_summary
                review_summary=$(head -40 "$review_file")
                gh_comment_issue "$ISSUE_NUMBER" "## 🔍 Code Review — ❌ Blocked

**Stats:** $diff_stats
**Blocking issues:** ${blocking_issues} (${critical_count} critical, ${security_count} security)

<details>
<summary>Review details</summary>

${review_summary}

</details>

_Pipeline will attempt self-healing rebuild._"
            fi

            log_stage "review" "BLOCKED: $blocking_issues critical/security issues found"
            return 1
        fi
    fi

    # Post review to GitHub issue
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local review_summary
        review_summary=$(head -40 "$review_file")
        gh_comment_issue "$ISSUE_NUMBER" "## 🔍 Code Review

**Stats:** $diff_stats
**Issues found:** $total_issues (${critical_count} critical, ${bug_count} bugs, ${warning_count} suggestions)

<details>
<summary>Review details</summary>

${review_summary}

</details>"
    fi

    # ── Constitutional diff check (advisory) ──
    if type constitutional_check_diff >/dev/null 2>&1; then
        local const_diff_violations
        const_diff_violations=$(constitutional_check_diff "${BASE_BRANCH:-main}" "HEAD" 2>/dev/null) || true
        local const_diff_count
        const_diff_count=$(echo "${const_diff_violations:-[]}" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$const_diff_count" -gt 0 ]]; then
            warn "Constitutional diff check: $const_diff_count violation(s) in changed code"
            emit_event "review.constitutional_diff" "violations=$const_diff_count" "stage=review"
        fi
    fi

    log_stage "review" "AI review complete ($total_issues issues: $critical_count critical, $bug_count bugs, $warning_count suggestions)"
}

# ─── Spec Verification Stage (dark factory: spec-driven development) ────────
# Runs between review and compound_quality. Verifies implementation against
# the spec by checking each acceptance criterion.
stage_spec_verification() {
    CURRENT_STAGE_ID="spec_verification"

    # Check if spec-driven is disabled
    if [[ "${SPEC_DRIVEN_ENABLED:-true}" == "false" ]]; then
        info "Spec-driven development disabled — skipping spec verification"
        return 0
    fi

    local spec_file="${ARTIFACTS_DIR}/spec.json"

    if [[ ! -f "$spec_file" ]]; then
        info "No spec found — skipping spec verification"
        log_stage "spec_verification" "Skipped: no spec available"
        return 0
    fi

    info "Verifying implementation against specification..."

    local criteria_count
    criteria_count=$(jq '.acceptance_criteria | length' "$spec_file" 2>/dev/null || echo "0")

    if [[ "$criteria_count" -eq 0 ]]; then
        warn "Spec has no acceptance criteria — skipping verification"
        log_stage "spec_verification" "Skipped: no acceptance criteria in spec"
        return 0
    fi

    # Build verification results
    local verified=0
    local unverified=0
    local manual_review=0
    local results_json="["
    local first=true
    local idx=0

    while [[ "$idx" -lt "$criteria_count" ]]; do
        local criterion verification_method testable
        criterion=$(jq -r --argjson i "$idx" '.acceptance_criteria[$i].criterion // ""' "$spec_file" 2>/dev/null)
        verification_method=$(jq -r --argjson i "$idx" '.acceptance_criteria[$i].verification_method // "manual"' "$spec_file" 2>/dev/null)
        testable=$(jq -r --argjson i "$idx" '.acceptance_criteria[$i].testable // false' "$spec_file" 2>/dev/null)

        local status="unverified"
        local evidence=""

        case "$verification_method" in
            unit_test|integration_test)
                # Check if tests exist and pass by looking at test results
                local test_results="${ARTIFACTS_DIR}/test-results.log"
                if [[ -f "$test_results" ]]; then
                    # If test results exist and contain no failures, mark as verified
                    local test_failures
                    test_failures=$(grep -ciE 'fail|error|FAIL' "$test_results" 2>/dev/null || true)
                    test_failures="${test_failures:-0}"
                    if [[ "$test_failures" -eq 0 ]]; then
                        status="verified"
                        evidence="Tests passed (no failures in test-results.log)"
                        verified=$((verified + 1))
                    else
                        status="unverified"
                        evidence="Test failures detected in test-results.log"
                        unverified=$((unverified + 1))
                    fi
                else
                    status="unverified"
                    evidence="No test results found"
                    unverified=$((unverified + 1))
                fi
                ;;
            static_analysis)
                # Check if constitutional checker ran and passed
                local const_report="${ARTIFACTS_DIR}/constitutional-audit.json"
                if [[ -f "$const_report" ]]; then
                    local violations
                    violations=$(jq '.total_violations // 0' "$const_report" 2>/dev/null || echo "0")
                    if [[ "$violations" -eq 0 ]]; then
                        status="verified"
                        evidence="Constitutional audit passed (0 violations)"
                        verified=$((verified + 1))
                    else
                        status="unverified"
                        evidence="Constitutional audit found $violations violations"
                        unverified=$((unverified + 1))
                    fi
                else
                    status="unverified"
                    evidence="No static analysis results found"
                    unverified=$((unverified + 1))
                fi
                ;;
            manual)
                status="manual_review"
                evidence="Requires human review"
                manual_review=$((manual_review + 1))
                ;;
            *)
                status="unverified"
                evidence="Unknown verification method: $verification_method"
                unverified=$((unverified + 1))
                ;;
        esac

        # Build JSON result entry
        local escaped_criterion escaped_evidence
        escaped_criterion=$(printf '%s' "$criterion" | jq -Rs . 2>/dev/null || echo "\"$criterion\"")
        escaped_evidence=$(printf '%s' "$evidence" | jq -Rs . 2>/dev/null || echo "\"$evidence\"")

        if $first; then
            first=false
        else
            results_json="${results_json},"
        fi
        results_json="${results_json}{\"criterion\":${escaped_criterion},\"verification_method\":\"${verification_method}\",\"status\":\"${status}\",\"evidence\":${escaped_evidence}}"

        idx=$((idx + 1))
    done
    results_json="${results_json}]"

    # Compute compliance score
    local total_checkable=$((verified + unverified))
    local compliance_score=0
    if [[ "$total_checkable" -gt 0 ]]; then
        compliance_score=$((verified * 100 / total_checkable))
    elif [[ "$manual_review" -gt 0 && "$unverified" -eq 0 ]]; then
        # All criteria are manual — treat as 100% machine compliance
        compliance_score=100
    fi

    # Generate verification report
    local report_file="${ARTIFACTS_DIR}/spec-verification-report.json"
    cat > "$report_file" <<REPORTEOF
{
  "spec_file": "${spec_file}",
  "verified_at": "$(now_iso)",
  "summary": {
    "total_criteria": ${criteria_count},
    "verified": ${verified},
    "unverified": ${unverified},
    "manual_review": ${manual_review},
    "compliance_score": ${compliance_score}
  },
  "results": ${results_json}
}
REPORTEOF

    # Pretty-print if jq available
    if command -v jq >/dev/null 2>&1; then
        local pp
        pp=$(jq '.' "$report_file" 2>/dev/null) || true
        if [[ -n "$pp" ]]; then
            echo "$pp" > "$report_file"
        fi
    fi

    save_artifact "spec-verification-report.json" "$(cat "$report_file")" || true

    # Report results
    if [[ "$compliance_score" -lt 80 ]]; then
        warn "Spec compliance: ${compliance_score}% (${verified}/${total_checkable} verified) — below 80% threshold"
    else
        success "Spec compliance: ${compliance_score}% (${verified}/${total_checkable} verified)"
    fi

    if [[ "$manual_review" -gt 0 ]]; then
        info "${manual_review} criteria flagged for manual review"
    fi

    emit_event "spec_verification.completed" \
        "issue=${ISSUE_NUMBER:-0}" \
        "compliance=${compliance_score}" \
        "verified=${verified}" \
        "unverified=${unverified}" \
        "manual=${manual_review}"

    log_stage "spec_verification" "Compliance: ${compliance_score}% — ${verified} verified, ${unverified} unverified, ${manual_review} manual"
}

# ─── Compound Quality (fallback) ────────────────────────────────────────────
# Machine-verifiable DoD scorecard, then adversarial review, negative testing, e2e checks.
# If pipeline-intelligence.sh was sourced first, its enhanced version takes priority.
if ! type stage_compound_quality >/dev/null 2>&1; then
stage_compound_quality() {
    CURRENT_STAGE_ID="compound_quality"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-compound_quality.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _cq_retry_hints
        _cq_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi

    # Source DoD scorecard library
    if [[ -f "$SCRIPT_DIR/lib/dod-scorecard.sh" ]]; then
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/dod-scorecard.sh"
    fi

    # ── Machine-Verifiable DoD Scorecard (runs first) ──
    info "Computing machine-verifiable Definition of Done scorecard..."
    local quality_profile="${PROJECT_ROOT}/.claude/quality-profile.json"
    local dod_scorecard_json
    dod_scorecard_json=$(compute_dod_scorecard "${BASE_BRANCH:-main}" "$ARTIFACTS_DIR" "$quality_profile" 2>/dev/null) || true

    if [[ -n "$dod_scorecard_json" ]]; then
        # Display scorecard
        local scorecard_display
        scorecard_display=$(format_scorecard "$dod_scorecard_json")
        echo "$scorecard_display"

        # Log scorecard
        log_stage "compound_quality" "DoD Scorecard computed"

        # If scorecard fails, skip LLM checks and return failure
        if ! scorecard_passed "$dod_scorecard_json"; then
            local blocking_failures
            blocking_failures=$(get_blocking_failures "$dod_scorecard_json")
            error "DoD Scorecard gate failed on: $blocking_failures"
            emit_event "compound_quality.dod_failed" \
                "issue=${ISSUE_NUMBER:-0}" \
                "failures=$blocking_failures"
            return 1
        else
            success "DoD Scorecard gate passed"
            emit_event "compound_quality.dod_passed" "issue=${ISSUE_NUMBER:-0}"
        fi
    fi

    # Load skill prompts for compound quality (used by adversarial review)
    local _cq_skills=""
    if type skill_load_prompts >/dev/null 2>&1; then
        _cq_skills=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "compound_quality" 2>/dev/null || true)
    fi
    # Write skill guidance to artifact for sw-adversarial.sh to consume
    if [[ -n "$_cq_skills" ]]; then
        echo "$_cq_skills" > "${ARTIFACTS_DIR}/.compound-quality-skills.md" 2>/dev/null || true
    fi
    if [[ -n "${_cq_retry_hints:-}" ]]; then
        echo "$_cq_retry_hints" >> "${ARTIFACTS_DIR}/.compound-quality-skills.md" 2>/dev/null || true
    fi

    # Read stage config from pipeline template
    local cfg
    cfg=$(jq -r '.stages[] | select(.id == "compound_quality") | .config // {}' "$PIPELINE_CONFIG" 2>/dev/null) || cfg="{}"

    local do_adversarial do_negative do_e2e do_dod max_cycles blocking
    do_adversarial=$(echo "$cfg" | jq -r '.adversarial // false')
    do_negative=$(echo "$cfg" | jq -r '.negative // false')
    do_e2e=$(echo "$cfg" | jq -r '.e2e // false')
    do_dod=$(echo "$cfg" | jq -r '.dod_audit // false')
    max_cycles=$(echo "$cfg" | jq -r '.max_cycles // 1')
    blocking=$(echo "$cfg" | jq -r '.compound_quality_blocking // false')

    local pass_count=0 fail_count=0 total=0
    local compound_log="$ARTIFACTS_DIR/compound-quality.log"
    : > "$compound_log"

    # ── Adversarial review ──
    if [[ "$do_adversarial" == "true" ]]; then
        total=$((total + 1))
        info "Running adversarial review..."
        if [[ -x "$SCRIPT_DIR/sw-adversarial.sh" ]]; then
            if bash "$SCRIPT_DIR/sw-adversarial.sh" --repo "${REPO_DIR:-.}" >> "$compound_log" 2>&1; then
                pass_count=$((pass_count + 1))
                success "Adversarial review passed"
            else
                fail_count=$((fail_count + 1))
                warn "Adversarial review found issues"
            fi
        else
            warn "sw-adversarial.sh not found, skipping"
        fi
    fi

    # ── Negative / edge-case testing ──
    if [[ "$do_negative" == "true" ]]; then
        total=$((total + 1))
        info "Running negative test pass..."
        if [[ -n "${TEST_CMD:-}" ]]; then
            if ( sw_test_gate_scrub && eval "$TEST_CMD" ) >> "$compound_log" 2>&1; then
                pass_count=$((pass_count + 1))
                success "Negative test pass passed"
            else
                fail_count=$((fail_count + 1))
                warn "Negative test pass found failures"
            fi
        else
            pass_count=$((pass_count + 1))
            info "No test command configured, skipping negative tests"
        fi
    fi

    # ── E2E checks ──
    if [[ "$do_e2e" == "true" ]]; then
        total=$((total + 1))
        info "Running e2e checks..."
        if [[ -x "$SCRIPT_DIR/sw-e2e-orchestrator.sh" ]]; then
            if bash "$SCRIPT_DIR/sw-e2e-orchestrator.sh" run >> "$compound_log" 2>&1; then
                pass_count=$((pass_count + 1))
                success "E2E checks passed"
            else
                fail_count=$((fail_count + 1))
                warn "E2E checks found issues"
            fi
        else
            pass_count=$((pass_count + 1))
            info "sw-e2e-orchestrator.sh not found, skipping e2e"
        fi
    fi

    # ── Definition of Done audit ──
    if [[ "$do_dod" == "true" ]]; then
        total=$((total + 1))
        info "Running definition-of-done audit..."
        if [[ -x "$SCRIPT_DIR/sw-quality.sh" ]]; then
            if bash "$SCRIPT_DIR/sw-quality.sh" validate >> "$compound_log" 2>&1; then
                pass_count=$((pass_count + 1))
                success "DoD audit passed"
            else
                fail_count=$((fail_count + 1))
                warn "DoD audit found gaps"
            fi
        else
            pass_count=$((pass_count + 1))
            info "sw-quality.sh not found, skipping DoD audit"
        fi
    fi

    # ── Summary ──
    log_stage "compound_quality" "Compound quality: $pass_count/$total checks passed, $fail_count failed"

    if [[ "$fail_count" -gt 0 && "$blocking" == "true" ]]; then
        error "Compound quality gate failed: $fail_count of $total checks failed"
        return 1
    fi

    return 0
}
fi  # end fallback stage_compound_quality

# ─── Audit Stage ───────────────────────────────────────────────────────────
# Security and quality audits: secrets scan, file permissions, || true usage,
# test coverage delta, atomic write checks.
stage_audit() {
    CURRENT_STAGE_ID="audit"

    # Read stage config from pipeline template
    local cfg
    cfg=$(jq -r '.stages[] | select(.id == "audit") | .config // {}' "$PIPELINE_CONFIG" 2>/dev/null) || cfg="{}"

    local do_secret_scan do_perms do_atomic_writes do_coverage blocking
    do_secret_scan=$(echo "$cfg" | jq -r '.secret_scan // true')
    do_perms=$(echo "$cfg" | jq -r '.file_permissions // true')
    do_atomic_writes=$(echo "$cfg" | jq -r '.atomic_writes // true')
    do_coverage=$(echo "$cfg" | jq -r '.coverage_delta // true')
    blocking=$(echo "$cfg" | jq -r '.blocking // false')

    local audit_log="$ARTIFACTS_DIR/audit.log"
    : > "$audit_log"

    local issues=0

    # ── Secret Scanning ──
    if [[ "$do_secret_scan" == "true" ]]; then
        info "Scanning for secrets in changed files..."
        local secret_patterns=(
            "sk-ant-" "ANTHROPIC_API_KEY=" "GITHUB_TOKEN=" "OPENAI_API_KEY="
            "AWS_SECRET_ACCESS_KEY=" "DATABASE_URL=" "PRIVATE_KEY="
            "api_key=" "secret=" "password=" "token="
        )

        local changed_files
        changed_files=$(git diff --name-only "${BASE_BRANCH:-main}..HEAD" 2>/dev/null || git diff --name-only HEAD~5 2>/dev/null || echo "")

        for pattern in "${secret_patterns[@]}"; do
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                if grep -l "$pattern" "$file" 2>/dev/null | grep >/dev/null -v node_modules; then
                    echo "WARN: Potential secret found in $file: $pattern" >> "$audit_log"
                    warn "Found potential secret: $pattern in $file"
                    issues=$((issues + 1))
                fi
            done <<< "$changed_files"
        done
    fi

    # ── File Permission Check ──
    if [[ "$do_perms" == "true" ]]; then
        info "Checking file permissions on sensitive files..."
        local sensitive_patterns=(".env" "secret" "credential" "key" "token" "config")

        for pattern in "${sensitive_patterns[@]}"; do
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                # Check for world-readable files
                local perms
                perms=$(stat -f "%OLp" "$file" 2>/dev/null || stat -c "%a" "$file" 2>/dev/null)
                if [[ "$perms" =~ [4567]$ ]]; then  # world-readable
                    echo "WARN: World-readable sensitive file: $file ($perms)" >> "$audit_log"
                    warn "World-readable file: $file ($perms)"
                    issues=$((issues + 1))
                fi
            done < <(find . -name "*${pattern}*" -type f 2>/dev/null | head -20)
        done
    fi

    # ── || true Count (atomic write pattern) ──
    if [[ "$do_atomic_writes" == "true" ]]; then
        info "Checking for unprotected direct writes (|| true usage)..."
        local baseline_true_count=0
        local current_true_count=0

        # Baseline (before changes)
        if git rev-parse "${BASE_BRANCH:-main}" >/dev/null 2>&1; then
            baseline_true_count=$(git show "${BASE_BRANCH:-main}:." 2>/dev/null | grep -r "|| true" 2>/dev/null | wc -l)
        fi

        # Current
        current_true_count=$(grep -r "|| true" --include="*.sh" . 2>/dev/null | wc -l)

        local true_delta=$((current_true_count - baseline_true_count))
        if [[ $true_delta -gt 0 ]]; then
            echo "WARN: Added $true_delta new '|| true' clauses (may mask errors)" >> "$audit_log"
            warn "Added $true_delta new || true patterns"
            issues=$((issues + 1))
        fi
    fi

    # ── Test Coverage Delta ──
    if [[ "$do_coverage" == "true" && -n "${COVERAGE_FILE:-}" ]]; then
        info "Comparing test coverage..."
        if [[ -f "$COVERAGE_FILE" ]]; then
            local current_coverage
            current_coverage=$(grep -oP 'Coverage: \K[0-9.]+' "$COVERAGE_FILE" | head -1)
            if [[ -n "$current_coverage" ]]; then
                # Try to get baseline coverage
                local baseline_coverage=0
                if git show "${BASE_BRANCH:-main}:.claude/coverage.txt" >/dev/null 2>&1; then
                    baseline_coverage=$(git show "${BASE_BRANCH:-main}:.claude/coverage.txt" 2>/dev/null | \
                        grep -oP 'Coverage: \K[0-9.]+' | head -1 || echo "0")
                fi

                local coverage_delta
                coverage_delta=$(echo "$current_coverage - $baseline_coverage" | bc 2>/dev/null || echo "0")
                if (( $(echo "$coverage_delta < -2" | bc -l 2>/dev/null || echo 0) )); then
                    echo "WARN: Coverage decreased by ${coverage_delta}pp (from ${baseline_coverage}% to ${current_coverage}%)" >> "$audit_log"
                    warn "Coverage delta: ${coverage_delta}pp"
                    issues=$((issues + 1))
                fi
            fi
        fi
    fi

    log_stage "audit" "Audit complete: $issues issue(s) found"

    if [[ "$issues" -gt 0 && "$blocking" == "true" ]]; then
        error "Audit gate failed: $issues issue(s) detected"
        emit_event "pipeline.audit_failed" "issues=$issues"
        return 1
    fi

    if [[ "$issues" -gt 0 ]]; then
        emit_event "pipeline.audit_warnings" "issues=$issues"
    fi

    return 0
}

