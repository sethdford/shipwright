# pipeline-stages-intake.sh — intake, plan, design stages
# Source from pipeline-stages.sh. Requires all pipeline globals and dependencies.
[[ -n "${_PIPELINE_STAGES_INTAKE_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_INTAKE_LOADED=1

# Load intent analysis module for acceptance criteria generation
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
source "${SCRIPT_DIR}/lib/intent-analysis.sh" 2>/dev/null || true

stage_intake() {
    CURRENT_STAGE_ID="intake"
    local project_lang
    project_lang=$(detect_project_lang)
    info "Project: ${BOLD}$project_lang${RESET}"

    # 0. Pre-build toolchain check — before any GitHub/git side effects, so an
    # unbuildable environment fails here instead of after a paid build loop.
    local prebuild_status="skipped"
    if type prebuild_check >/dev/null 2>&1; then
        if ! prebuild_check "$project_lang" "${PROJECT_ROOT:-.}"; then
            error "PREBUILD_ENV_ERROR: ${PREBUILD_CRITICAL_IDS:-unknown} — fix the environment, then: shipwright pipeline resume"
            return 1
        fi
        prebuild_status="${PREBUILD_STATUS:-skipped}"
    fi

    # 1. Fetch issue metadata if --issue provided
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local meta
        meta=$(gh_get_issue_meta "$ISSUE_NUMBER")

        # Validate JSON before processing
        if [[ -n "$meta" ]] && jq empty <<< "$meta" 2>/dev/null; then
            GOAL=$(echo "$meta" | jq -r '.title // ""' 2>/dev/null) || GOAL=""
            ISSUE_BODY=$(echo "$meta" | jq -r '.body // ""' 2>/dev/null) || ISSUE_BODY=""
            ISSUE_LABELS=$(echo "$meta" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || ISSUE_LABELS=""
            ISSUE_MILESTONE=$(echo "$meta" | jq -r '.milestone.title // ""' 2>/dev/null || true)
            ISSUE_ASSIGNEES=$(echo "$meta" | jq -r '[.assignees[].login] | join(",")' 2>/dev/null || true)
            [[ "$ISSUE_MILESTONE" == "null" ]] && ISSUE_MILESTONE=""
            [[ "$ISSUE_LABELS" == "null" ]] && ISSUE_LABELS=""
            # Export for use by intelligence skip functions
            export ISSUE_LABELS
        else
            # Fallback: just get title
            GOAL=$(gh issue view "$ISSUE_NUMBER" --json title --jq '.title' 2>/dev/null) || {
                error "Failed to fetch issue #$ISSUE_NUMBER"
                return 1
            }
        fi

        GITHUB_ISSUE="#$ISSUE_NUMBER"
        info "Issue #$ISSUE_NUMBER: ${BOLD}$GOAL${RESET}"

        if [[ -n "$ISSUE_LABELS" ]]; then
            info "Labels: ${DIM}$ISSUE_LABELS${RESET}"
        fi
        if [[ -n "$ISSUE_MILESTONE" ]]; then
            info "Milestone: ${DIM}$ISSUE_MILESTONE${RESET}"
        fi

        # Self-assign
        gh_assign_self "$ISSUE_NUMBER"

        # Add in-progress label
        gh_add_labels "$ISSUE_NUMBER" "pipeline/in-progress"

        # 1a. Generate acceptance criteria from issue intent analysis
        if type analyze_intent >/dev/null 2>&1; then
            info "Analyzing issue intent and generating acceptance criteria..."
            if analyze_intent "$GOAL" "$ISSUE_BODY" "$ISSUE_LABELS" "$ARTIFACTS_DIR" 2>/dev/null; then
                local criteria_preview
                criteria_preview=$(format_acceptance_criteria_for_prompt "$ARTIFACTS_DIR" 2>/dev/null | head -10 || true)
                if [[ -n "$criteria_preview" ]]; then
                    info "Acceptance criteria generated: ${DIM}acceptance-criteria.json${RESET}"
                fi
            fi
        fi
    fi

    # 2. Detect task type
    TASK_TYPE=$(detect_task_type "$GOAL")
    local suggested_template
    suggested_template=$(template_for_type "$TASK_TYPE")
    info "Detected: ${BOLD}$TASK_TYPE${RESET} → team template: ${CYAN}$suggested_template${RESET}"

    # 3. Auto-detect test command if not provided
    if [[ -z "$TEST_CMD" ]]; then
        TEST_CMD=$(detect_test_cmd)
        if [[ -n "$TEST_CMD" ]]; then
            info "Auto-detected test: ${DIM}$TEST_CMD${RESET}"
        fi
    fi

    # 4. Create branch with smart prefix
    local prefix
    prefix=$(branch_prefix_for_type "$TASK_TYPE")
    local slug
    slug=$(echo "$GOAL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40)
    slug="${slug%-}"
    [[ -n "$ISSUE_NUMBER" ]] && slug="${slug}-${ISSUE_NUMBER}"
    GIT_BRANCH="${prefix}/${slug}"

    git checkout -b "$GIT_BRANCH" 2>/dev/null || {
        info "Branch $GIT_BRANCH exists, checking out"
        git checkout "$GIT_BRANCH" 2>/dev/null || true
    }
    success "Branch: ${BOLD}$GIT_BRANCH${RESET}"

    # 5. Post initial progress comment on GitHub issue
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_post_progress "$ISSUE_NUMBER" "$body"
    fi

    # 6. Save artifacts
    save_artifact "intake.json" "$(jq -n \
        --arg goal "$GOAL" --arg type "$TASK_TYPE" \
        --arg template "$suggested_template" --arg branch "$GIT_BRANCH" \
        --arg issue "${GITHUB_ISSUE:-}" --arg lang "$project_lang" \
        --arg test_cmd "${TEST_CMD:-}" --arg labels "${ISSUE_LABELS:-}" \
        --arg milestone "${ISSUE_MILESTONE:-}" --arg body "${ISSUE_BODY:-}" \
        --arg prebuild "$prebuild_status" \
        '{goal:$goal, type:$type, template:$template, branch:$branch,
          issue:$issue, language:$lang, test_cmd:$test_cmd,
          labels:$labels, milestone:$milestone, body:$body,
          prebuild_status:$prebuild}' 2>/dev/null)" || true

    # 7. AI-powered skill analysis (replaces static classification when available)
    if type skill_analyze_issue >/dev/null 2>&1; then
        local _intel_json=""
        [[ -f "$ARTIFACTS_DIR/intelligence-analysis.json" ]] && _intel_json=$(cat "$ARTIFACTS_DIR/intelligence-analysis.json" 2>/dev/null || true)

        if skill_analyze_issue "$GOAL" "${ISSUE_BODY:-}" "${ISSUE_LABELS:-}" "$ARTIFACTS_DIR" "$_intel_json" 2>/dev/null; then
            info "Skill analysis: AI-powered skill plan written to skill-plan.json"
            # INTELLIGENCE_ISSUE_TYPE and INTELLIGENCE_COMPLEXITY are updated by skill_analyze_issue
        else
            info "Skill analysis: LLM unavailable — using label-based classification"
        fi
    fi

    # 8. Generate structured specification (dark factory: spec-driven development)
    if type spec_generate >/dev/null 2>&1; then
        SPEC_DIR="${ARTIFACTS_DIR}/specs"
        local spec_file
        spec_file=$(spec_generate "$GOAL" "${ISSUE_BODY:-}" "${ISSUE_NUMBER:-}" "" "$project_lang" 2>/dev/null) || true
        if [[ -n "$spec_file" && -f "$spec_file" ]]; then
            info "Spec generated: ${DIM}$(basename "$spec_file")${RESET}"
            save_artifact "spec.json" "$(cat "$spec_file")" || true
        fi
    fi

    # 9. Partition tests for holdout validation (dark factory: test-as-holdout)
    if type holdout_partition >/dev/null 2>&1; then
        HOLDOUT_DIR="${ARTIFACTS_DIR}/test-holdout"
        if holdout_partition "." "$project_lang" 2>/dev/null; then
            holdout_seal "." 2>/dev/null || true
            info "Test holdout: ${HOLDOUT_VISIBLE_COUNT:-0} visible, ${HOLDOUT_SEALED_COUNT:-0} sealed"
        fi
    fi

    log_stage "intake" "Goal: $GOAL
Type: $TASK_TYPE → template: $suggested_template
Branch: $GIT_BRANCH
Language: $project_lang
Test cmd: ${TEST_CMD:-none detected}
Issue type: ${INTELLIGENCE_ISSUE_TYPE:-backend}"
}

# ─── Spec Generation Stage (dark factory: spec-driven development) ──────────
# Runs between intake and plan. Enhances auto-generated spec with Claude,
# adding missing acceptance criteria, edge cases, security requirements,
# and affected files estimation.
stage_spec_generation() {
    CURRENT_STAGE_ID="spec_generation"

    # Check if spec-driven is disabled via env or daemon config
    if [[ "${SPEC_DRIVEN_ENABLED:-true}" == "false" ]]; then
        info "Spec-driven development disabled — skipping spec generation"
        return 0
    fi

    local spec_file="${ARTIFACTS_DIR}/spec.json"

    # If no spec was generated at intake, generate a basic one now
    if [[ ! -f "$spec_file" ]]; then
        if type spec_generate >/dev/null 2>&1 && [[ -n "${GOAL:-}" ]]; then
            local project_lang
            project_lang=$(detect_project_lang 2>/dev/null || echo "unknown")
            SPEC_DIR="${ARTIFACTS_DIR}/specs"
            local generated
            generated=$(spec_generate "$GOAL" "${ISSUE_BODY:-}" "${ISSUE_NUMBER:-}" "" "$project_lang" 2>/dev/null) || true
            if [[ -n "$generated" && -f "$generated" ]]; then
                save_artifact "spec.json" "$(cat "$generated")" || true
                spec_file="${ARTIFACTS_DIR}/spec.json"
            fi
        fi
    fi

    if [[ ! -f "$spec_file" ]]; then
        warn "No spec available — skipping spec generation enhancement"
        log_stage "spec_generation" "Skipped: no spec available"
        return 0
    fi

    # Enhance spec with Claude if available
    if command -v claude >/dev/null 2>&1; then
        info "Enhancing specification with AI analysis..."

        local current_spec
        current_spec=$(cat "$spec_file")

        local enhance_prompt="You are a specification analyst. Given the following auto-generated specification and issue context, enhance it by:

1. Adding missing acceptance criteria (each must have 'criterion', 'testable' (bool), and 'verification_method' fields)
2. Adding edge cases (each must have 'scenario' and 'expected_behavior' fields)
3. Adding security requirements (list of strings)
4. Estimating affected files (list of file path strings)

Return ONLY valid JSON matching the same schema as the input spec. Do not add commentary.

## Current Spec
${current_spec}

## Issue Context
Goal: ${GOAL:-}
Body: ${ISSUE_BODY:-}
Labels: ${ISSUE_LABELS:-}
"

        local enhanced_spec=""
        local spec_model="${MODEL:-sonnet}"
        enhanced_spec=$(claude -p "$enhance_prompt" --model "$spec_model" --output-format json 2>/dev/null) || true

        if [[ -n "$enhanced_spec" ]]; then
            # Validate the enhanced spec is valid JSON with required fields
            if echo "$enhanced_spec" | jq -e '.version and .title and .goals' >/dev/null 2>&1; then
                # Preserve metadata from original, update timestamp
                enhanced_spec=$(echo "$enhanced_spec" | jq --arg ts "$(now_iso)" '
                    .metadata.enhanced_at = $ts |
                    .metadata.enhanced = true
                ' 2>/dev/null) || enhanced_spec=""

                if [[ -n "$enhanced_spec" ]]; then
                    save_artifact "spec.json" "$enhanced_spec" || true
                    success "Spec enhanced with AI analysis"
                fi
            else
                warn "AI-enhanced spec failed validation — keeping original"
            fi
        else
            info "Claude unavailable or returned empty — keeping original spec"
        fi
    else
        info "Claude CLI not available — keeping original spec"
    fi

    # Validate final spec
    if type spec_validate >/dev/null 2>&1; then
        if ! spec_validate "$spec_file" 2>/dev/null; then
            warn "Spec validation failed after enhancement"
            # Retry: regenerate from scratch if validation failed
            if type spec_generate >/dev/null 2>&1 && [[ -n "${GOAL:-}" ]]; then
                info "Retrying spec generation from scratch..."
                local project_lang
                project_lang=$(detect_project_lang 2>/dev/null || echo "unknown")
                SPEC_DIR="${ARTIFACTS_DIR}/specs"
                local regen
                regen=$(spec_generate "$GOAL" "${ISSUE_BODY:-}" "${ISSUE_NUMBER:-}" "" "$project_lang" 2>/dev/null) || true
                if [[ -n "$regen" && -f "$regen" ]]; then
                    save_artifact "spec.json" "$(cat "$regen")" || true
                    success "Spec regenerated successfully"
                fi
            fi
        fi
    fi

    # Count spec richness for logging
    local criteria_count edge_count security_count affected_count
    criteria_count=$(jq '.acceptance_criteria | length' "$spec_file" 2>/dev/null || echo "0")
    edge_count=$(jq '.edge_cases | length' "$spec_file" 2>/dev/null || echo "0")
    security_count=$(jq '.security_requirements | length' "$spec_file" 2>/dev/null || echo "0")
    affected_count=$(jq '.affected_files | length' "$spec_file" 2>/dev/null || echo "0")

    emit_event "spec_generation.completed" \
        "issue=${ISSUE_NUMBER:-0}" \
        "criteria=$criteria_count" \
        "edge_cases=$edge_count" \
        "security=$security_count" \
        "affected_files=$affected_count"

    log_stage "spec_generation" "Spec: ${criteria_count} criteria, ${edge_count} edge cases, ${security_count} security reqs, ${affected_count} affected files"
}

stage_plan() {
    CURRENT_STAGE_ID="plan"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-plan.md"
    local _retry_hints=""
    if [[ -s "$_retry_ctx" ]]; then
        _retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"  # consumed
    fi
    local plan_file="$ARTIFACTS_DIR/plan.md"

    if ! command -v claude >/dev/null 2>&1; then
        error "Claude CLI not found — cannot generate plan"
        return 1
    fi

    info "Generating implementation plan..."

    # Dark factory: inject RL approach suggestions based on past episodes
    if type rl_suggest_approach >/dev/null 2>&1; then
        local _rl_lang="${INTELLIGENCE_LANGUAGE:-unknown}"
        local _rl_complexity="${INTELLIGENCE_COMPLEXITY:-medium}"
        local _rl_type="${INTELLIGENCE_ISSUE_TYPE:-feature}"
        local _rl_suggestions
        _rl_suggestions=$(rl_suggest_approach "$_rl_lang" "$_rl_type" "$_rl_complexity" 2>/dev/null || true)
        if [[ -n "$_rl_suggestions" ]]; then
            info "RL suggests: $(echo "$_rl_suggestions" | head -1)"
        fi
    fi

    # ── Gather context bundle (if context engine available) ──
    local context_script="${SCRIPT_DIR}/sw-context.sh"
    if [[ -x "$context_script" ]]; then
        "$context_script" gather --goal "$GOAL" --stage plan 2>/dev/null || true
    fi

    # Gather rich architecture context (call-graph, dependencies)
    local arch_context=""
    if type gather_architecture_context &>/dev/null; then
        arch_context=$(gather_architecture_context "${PROJECT_ROOT:-.}" 2>/dev/null || true)
    fi

    # Build rich prompt with all available context
    local plan_prompt="You are an autonomous development agent. Analyze this codebase and create a detailed implementation plan.

## Goal
${GOAL}
"

    # Add issue context
    if [[ -n "$ISSUE_BODY" ]]; then
        plan_prompt="${plan_prompt}
## Issue Description
${ISSUE_BODY}
"
    fi

    # Inject architecture context (import graph, modules, test map)
    if [[ -n "$arch_context" ]]; then
        arch_context=$(prune_context_section "architecture" "$arch_context" 5000)
        plan_prompt="${plan_prompt}
## Architecture Context
${arch_context}
"
    fi

    # Inject context bundle from context engine (if available)
    local _context_bundle="${ARTIFACTS_DIR}/context-bundle.md"
    if [[ -f "$_context_bundle" ]]; then
        local _cb_content
        _cb_content=$(cat "$_context_bundle" 2>/dev/null | head -100 || true)
        _cb_content=$(prune_context_section "context-bundle" "$_cb_content" 8000)
        if [[ -n "$_cb_content" ]]; then
            plan_prompt="${plan_prompt}
## Pipeline Context
${_cb_content}
"
        fi
    fi

    # Inject intelligence memory context for similar past plans
    if type intelligence_search_memory >/dev/null 2>&1; then
        local plan_memory
        plan_memory=$(intelligence_search_memory "plan stage for ${TASK_TYPE:-feature}: ${GOAL:-}" "${HOME}/.shipwright/memory" 5 2>/dev/null) || true
        if [[ -n "$plan_memory" && "$plan_memory" != *'"results":[]'* && "$plan_memory" != *'"error"'* ]]; then
            local memory_summary
            memory_summary=$(echo "$plan_memory" | jq -r '.results[]? | "- \(.)"' 2>/dev/null | head -10 || true)
            memory_summary=$(prune_context_section "memory" "$memory_summary" 10000)
            if [[ -n "$memory_summary" ]]; then
                plan_prompt="${plan_prompt}
## Historical Context (from previous pipelines)
Previous similar issues were planned as:
${memory_summary}
"
            fi
        fi
    fi

    # Self-aware pipeline: inject hint when plan stage has been failing recently
    local plan_hint
    plan_hint=$(get_stage_self_awareness_hint "plan" 2>/dev/null || true)
    if [[ -n "$plan_hint" ]]; then
        plan_prompt="${plan_prompt}
## Self-Assessment (recent plan stage performance)
${plan_hint}
"
    fi

    # Inject retry context from previous failed attempt
    if [[ -n "$_retry_hints" ]]; then
        plan_prompt="${plan_prompt}
## Previous Attempt Analysis (RETRY)
This stage previously failed. Analysis of the failure:
${_retry_hints}

Use this analysis to avoid repeating the same mistake. Address the root cause in your approach.
"
    fi

    # Inject cross-pipeline discoveries (from other concurrent/similar pipelines)
    if [[ -x "$SCRIPT_DIR/sw-discovery.sh" ]]; then
        local plan_discoveries
        plan_discoveries=$("$SCRIPT_DIR/sw-discovery.sh" inject "*.md,*.json" 2>/dev/null | head -20 || true)
        plan_discoveries=$(prune_context_section "discoveries" "$plan_discoveries" 3000)
        if [[ -n "$plan_discoveries" ]]; then
            plan_prompt="${plan_prompt}
## Discoveries from Other Pipelines
${plan_discoveries}
"
        fi
    fi

    # Inject architecture patterns from intelligence layer
    local repo_hash_plan
    repo_hash_plan=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local arch_file_plan="${HOME}/.shipwright/memory/${repo_hash_plan}/architecture.json"
    if [[ -f "$arch_file_plan" ]]; then
        local arch_patterns
        arch_patterns=$(jq -r '
            "Language: \(.language // "unknown")",
            "Framework: \(.framework // "unknown")",
            "Patterns: \((.patterns // []) | join(", "))",
            "Rules: \((.rules // []) | join("; "))"
        ' "$arch_file_plan" 2>/dev/null || true)
        arch_patterns=$(prune_context_section "intelligence" "$arch_patterns" 5000)
        if [[ -n "$arch_patterns" ]]; then
            plan_prompt="${plan_prompt}
## Architecture Patterns
${arch_patterns}
"
        fi
    fi

    # Inject skill prompts based on issue type classification
    # Prefer adaptive selection when available (combines body analysis + complexity weighting)
    if type skill_select_adaptive >/dev/null 2>&1; then
        local _skill_files _skill_prompts
        _skill_files=$(skill_select_adaptive "${INTELLIGENCE_ISSUE_TYPE:-backend}" "plan" "${ISSUE_BODY:-}" "${INTELLIGENCE_COMPLEXITY:-5}" 2>/dev/null || true)
        if [[ -n "$_skill_files" ]]; then
            # Load content from skill files
            _skill_prompts=$(while IFS= read -r _path; do
                [[ -z "$_path" ]] && continue
                [[ -f "$_path" ]] && cat "$_path" 2>/dev/null
            done <<< "$_skill_files")
            if [[ -n "$_skill_prompts" ]]; then
                _skill_prompts=$(prune_context_section "skills" "$_skill_prompts" 8000)
                plan_prompt="${plan_prompt}
## Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue)
${_skill_prompts}
"
            fi
        fi
    elif type skill_load_prompts >/dev/null 2>&1; then
        # Fallback to static selection
        local _skill_prompts
        _skill_prompts=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "plan" 2>/dev/null || true)
        if [[ -n "$_skill_prompts" ]]; then
            _skill_prompts=$(prune_context_section "skills" "$_skill_prompts" 8000)
            plan_prompt="${plan_prompt}
## Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue)
${_skill_prompts}
"
        fi
    fi

    # Task-type-specific guidance
    case "${TASK_TYPE:-feature}" in
        bug)
            plan_prompt="${plan_prompt}
## Task Type: Bug Fix
Focus on: reproducing the bug, identifying root cause, minimal targeted fix, regression tests.
" ;;
        refactor)
            plan_prompt="${plan_prompt}
## Task Type: Refactor
Focus on: preserving all existing behavior, incremental changes, comprehensive test coverage.
" ;;
        security)
            plan_prompt="${plan_prompt}
## Task Type: Security
Focus on: threat modeling, OWASP top 10, input validation, authentication/authorization.
" ;;
    esac

    # Add project context
    local project_lang
    project_lang=$(detect_project_lang)
    plan_prompt="${plan_prompt}
## Project Context
- Language: ${project_lang}
- Test command: ${TEST_CMD:-not configured}
- Task type: ${TASK_TYPE:-feature}

## Context Efficiency
- Batch independent tool calls in parallel when possible
- Read specific file sections (offset/limit) instead of entire large files
- Use targeted grep searches — avoid scanning entire codebases into context
- Delegate multi-file analysis to subagents when available

## Required Output
Create a Markdown plan with these sections:

### Files to Modify
List every file to create or modify with full paths.

### Implementation Steps
Numbered steps in order of execution. Be specific about what code to write.

### Task Checklist
A checkbox list of discrete tasks that can be tracked:
- [ ] Task 1: Description
- [ ] Task 2: Description
(Include 5-15 tasks covering the full implementation)

### Testing Approach
How to verify the implementation works.

### Definition of Done
Checklist of completion criteria.
"

    # Inject acceptance criteria as constraints
    if type format_acceptance_criteria_for_prompt >/dev/null 2>&1; then
        local criteria_section
        criteria_section=$(format_acceptance_criteria_for_prompt "$ARTIFACTS_DIR" 2>/dev/null || true)
        if [[ -n "$criteria_section" ]]; then
            plan_prompt="${plan_prompt}
## Acceptance Criteria (External Constraints)
${criteria_section}
"
        fi
    fi

    # Inject mandatory failure mode analysis requirement
    if type inject_failure_mode_analysis >/dev/null 2>&1; then
        local quality_profile_path="${PROJECT_ROOT:-.}/.claude/quality-profile.json"
        plan_prompt=$(inject_failure_mode_analysis "$plan_prompt" "$quality_profile_path" 2>/dev/null || echo "$plan_prompt")
    fi

    # Inject skill prompts — prefer AI-powered plan, fallback to adaptive, then static
    local _skill_prompts=""
    if type skill_load_from_plan >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_from_plan "plan" 2>/dev/null || true)
    elif type skill_select_adaptive >/dev/null 2>&1; then
        local _skill_files
        _skill_files=$(skill_select_adaptive "${INTELLIGENCE_ISSUE_TYPE:-backend}" "plan" "${ISSUE_BODY:-}" "${INTELLIGENCE_COMPLEXITY:-5}" 2>/dev/null || true)
        if [[ -n "$_skill_files" ]]; then
            _skill_prompts=$(while IFS= read -r _path; do
                [[ -z "$_path" || ! -f "$_path" ]] && continue
                cat "$_path" 2>/dev/null
            done <<< "$_skill_files")
        fi
    elif type skill_load_prompts >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "plan" 2>/dev/null || true)
    fi
    if [[ -n "$_skill_prompts" ]]; then
        _skill_prompts=$(prune_context_section "skills" "$_skill_prompts" 8000)
        plan_prompt="${plan_prompt}
## Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue, AI-selected)
${_skill_prompts}
"
    fi

    # Guard total prompt size
    plan_prompt=$(guard_prompt_size "plan" "$plan_prompt")

    local plan_model
    plan_model=$(jq -r --arg id "plan" '(.stages[] | select(.id == $id) | .config.model) // .defaults.model // "opus"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -n "$MODEL" ]] && plan_model="$MODEL"
    [[ -z "$plan_model" || "$plan_model" == "null" ]] && plan_model="opus"
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        plan_model="$CLAUDE_MODEL"
    fi

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-plan.log"
    local _plan_flags
    _plan_flags="$(_pipeline_claude_flags "plan" "$plan_model")"
    # shellcheck disable=SC2086
    claude --print $_plan_flags --max-turns "$(_smart_int "max_turns.pipeline_stage" 25)" --dangerously-skip-permissions \
        "$plan_prompt" < /dev/null > "$plan_file" 2>"$_token_log" || true
    parse_claude_tokens "$_token_log"

    # Claude may write to disk via tools instead of stdout — rescue those files
    local _plan_rescue
    for _plan_rescue in "${PROJECT_ROOT}/PLAN.md" "${PROJECT_ROOT}/plan.md" \
                         "${PROJECT_ROOT}/implementation-plan.md"; do
        if [[ -s "$_plan_rescue" ]] && [[ $(wc -l < "$plan_file" 2>/dev/null | xargs) -lt 10 ]]; then
            info "Plan written to ${_plan_rescue} via tools — adopting as plan artifact"
            cat "$_plan_rescue" >> "$plan_file"
            rm -f "$_plan_rescue"
            break
        fi
    done

    if [[ ! -s "$plan_file" ]]; then
        error "Plan generation failed — empty output"
        return 1
    fi

    # Validate plan content — detect API/CLI errors masquerading as plans
    local _plan_fatal="Invalid API key|invalid_api_key|authentication_error|API key expired"
    _plan_fatal="${_plan_fatal}|rate_limit_error|overloaded_error|Could not resolve host|ANTHROPIC_API_KEY"
    if grep -qiE "$_plan_fatal" "$plan_file" 2>/dev/null; then
        error "Plan stage produced API/CLI error instead of a plan: $(head -1 "$plan_file" | cut -c1-100)"
        return 1
    fi

    local line_count
    line_count=$(wc -l < "$plan_file" | xargs)
    if [[ "$line_count" -lt 3 ]]; then
        error "Plan too short (${line_count} lines) — likely an error, not a real plan"
        return 1
    fi
    info "Plan saved: ${DIM}$plan_file${RESET} (${line_count} lines)"

    # Extract task checklist for GitHub issue and task tracking
    local checklist
    checklist=$(sed -n '/### Task Checklist/,/^###/p' "$plan_file" 2>/dev/null | \
        grep '^\s*- \[' | head -20)

    if [[ -z "$checklist" ]]; then
        # Fallback: extract any checkbox lines
        checklist=$(grep '^\s*- \[' "$plan_file" 2>/dev/null | head -20)
    fi

    # Write local task file for Claude Code build stage
    if [[ -n "$checklist" ]]; then
        cat > "$TASKS_FILE" <<TASKS_EOF
# Pipeline Tasks — ${GOAL}

## Implementation Checklist
${checklist}

## Context
- Pipeline: ${PIPELINE_NAME}
- Branch: ${GIT_BRANCH}
- Issue: ${GITHUB_ISSUE:-none}
- Generated: $(now_iso)
TASKS_EOF
        info "Task list: ${DIM}$TASKS_FILE${RESET} ($(echo "$checklist" | wc -l | xargs) tasks)"
    fi

    # Post plan + task checklist to GitHub issue
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local plan_summary
        plan_summary=$(head -50 "$plan_file")
        local gh_body="## 📋 Implementation Plan

<details>
<summary>Click to expand full plan (${line_count} lines)</summary>

${plan_summary}

</details>
"
        if [[ -n "$checklist" ]]; then
            gh_body="${gh_body}
## ✅ Task Checklist
${checklist}
"
        fi

        gh_body="${gh_body}
---
_Generated by \`shipwright pipeline\` at $(now_iso)_"

        gh_comment_issue "$ISSUE_NUMBER" "$gh_body"
        info "Plan posted to issue #$ISSUE_NUMBER"
    fi

    # Push plan to wiki
    gh_wiki_page "Pipeline-Plan-${ISSUE_NUMBER:-inline}" "$(<"$plan_file")"

    # Generate Claude Code task list
    local cc_tasks_file="$PROJECT_ROOT/.claude/tasks.md"
    if [[ -n "$checklist" ]]; then
        cat > "$cc_tasks_file" <<CC_TASKS_EOF
# Tasks — ${GOAL}

## Status: In Progress
Pipeline: ${PIPELINE_NAME} | Branch: ${GIT_BRANCH}

## Checklist
${checklist}

## Notes
- Generated from pipeline plan at $(now_iso)
- Pipeline will update status as tasks complete
CC_TASKS_EOF
        info "Claude Code tasks: ${DIM}$cc_tasks_file${RESET}"
    fi

    # Extract definition of done for quality gates
    sed -n '/[Dd]efinition [Oo]f [Dd]one/,/^#/p' "$plan_file" | head -20 > "$ARTIFACTS_DIR/dod.md" 2>/dev/null || true

    # ── Plan Validation Gate ──
    # Ask Claude to validate the plan before proceeding
    if command -v claude >/dev/null 2>&1 && [[ -s "$plan_file" ]]; then
        # Pre-validate: check failure mode analysis is present and adequate
        local failure_mode_status=""
        if type get_failure_mode_validation_status >/dev/null 2>&1; then
            failure_mode_status=$(get_failure_mode_validation_status "$plan_file" 2>/dev/null || echo "missing_section")
            if [[ "$failure_mode_status" != "valid" ]]; then
                warn "Plan missing adequate failure mode analysis (status: ${failure_mode_status})"
                # Log this as a validation rejection reason
                echo "missing_failure_analysis" > "$ARTIFACTS_DIR/.plan-failure-sig.txt"
            fi
        fi

        local validation_attempts=0
        local max_validation_attempts=2
        local plan_valid=false

        while [[ "$validation_attempts" -lt "$max_validation_attempts" ]]; do
            validation_attempts=$((validation_attempts + 1))
            info "Validating plan (attempt ${validation_attempts}/${max_validation_attempts})..."

            # Build enriched validation prompt with learned context
            local validation_extra=""

            # Inject rejected plan history from memory
            if type intelligence_search_memory >/dev/null 2>&1; then
                local rejected_plans
                rejected_plans=$(intelligence_search_memory "rejected plan validation failures for: ${GOAL:-}" "${HOME}/.shipwright/memory" 3 2>/dev/null) || true
                if [[ -n "$rejected_plans" ]]; then
                    validation_extra="${validation_extra}
## Previously Rejected Plans
These issues were found in past plan validations for similar tasks:
${rejected_plans}
"
                fi
            fi

            # Inject repo conventions contextually
            local claudemd="$PROJECT_ROOT/.claude/CLAUDE.md"
            if [[ -f "$claudemd" ]]; then
                local conventions_summary
                conventions_summary=$(head -100 "$claudemd" 2>/dev/null | grep -E '^##|^-|^\*' | head -15 || true)
                if [[ -n "$conventions_summary" ]]; then
                    validation_extra="${validation_extra}
## Repo Conventions
${conventions_summary}
"
                fi
            fi

            # Inject complexity estimate
            local complexity_hint=""
            if [[ -n "${INTELLIGENCE_COMPLEXITY:-}" && "${INTELLIGENCE_COMPLEXITY:-0}" -gt 0 ]]; then
                complexity_hint="This is estimated as complexity ${INTELLIGENCE_COMPLEXITY}/10. Plans for this complexity typically need ${INTELLIGENCE_COMPLEXITY} or more tasks."
            fi

            local validation_prompt="You are a plan validator. Review this implementation plan and determine if it is valid.

## Goal
${GOAL}
${complexity_hint:+
## Complexity Estimate
${complexity_hint}
}
## Plan
$(cat "$plan_file")
${validation_extra}
Evaluate:
1. Are all requirements from the goal addressed?
2. Is the plan decomposed into clear, achievable tasks?
3. Are the implementation steps specific enough to execute?

Respond with EXACTLY one of these on the first line:
VALID: true
VALID: false

Then explain your reasoning briefly."

            local validation_model="${plan_model:-opus}"
            local validation_result
            local _val_flags
            _val_flags="$(_pipeline_claude_flags "plan" "$validation_model")"
            # shellcheck disable=SC2086
            validation_result=$(claude --print --output-format text $_val_flags -p "$validation_prompt" < /dev/null 2>"${ARTIFACTS_DIR}/.claude-tokens-plan-validate.log" || true)
            parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-plan-validate.log"

            # Save validation result
            echo "$validation_result" > "$ARTIFACTS_DIR/plan-validation.md"

            if echo "$validation_result" | head -5 | grep -qi "VALID: true"; then
                success "Plan validation passed"
                plan_valid=true
                break
            fi

            warn "Plan validation failed (attempt ${validation_attempts}/${max_validation_attempts})"

            # Analyze failure mode to decide how to recover
            local failure_mode="unknown"
            local validation_lower
            validation_lower=$(echo "$validation_result" | tr '[:upper:]' '[:lower:]')
            if echo "$validation_lower" | grep -qE 'failure mode|risk.*analysis|fail|risk'; then
                failure_mode="missing_failure_analysis"
            elif echo "$validation_lower" | grep -qE 'requirements? unclear|goal.*vague|ambiguous|underspecified'; then
                failure_mode="requirements_unclear"
            elif echo "$validation_lower" | grep -qE 'insufficient detail|not specific|too high.level|missing.*steps|lacks.*detail'; then
                failure_mode="insufficient_detail"
            elif echo "$validation_lower" | grep -qE 'scope too (large|broad)|too many|overly complex|break.*down'; then
                failure_mode="scope_too_large"
            fi

            emit_event "plan.validation_failure" \
                "issue=${ISSUE_NUMBER:-0}" \
                "attempt=$validation_attempts" \
                "failure_mode=$failure_mode"

            # Track repeated failures — escalate if stuck in a loop
            if [[ -f "$ARTIFACTS_DIR/.plan-failure-sig.txt" ]]; then
                local prev_sig
                prev_sig=$(cat "$ARTIFACTS_DIR/.plan-failure-sig.txt" 2>/dev/null || true)
                if [[ "$failure_mode" == "$prev_sig" && "$failure_mode" != "unknown" ]]; then
                    warn "Same validation failure mode repeated ($failure_mode) — escalating"
                    emit_event "plan.validation_escalated" \
                        "issue=${ISSUE_NUMBER:-0}" \
                        "failure_mode=$failure_mode"
                    break
                fi
            fi
            echo "$failure_mode" > "$ARTIFACTS_DIR/.plan-failure-sig.txt"

            if [[ "$validation_attempts" -lt "$max_validation_attempts" ]]; then
                info "Regenerating plan with validation feedback (mode: ${failure_mode})..."

                # Tailor regeneration prompt based on failure mode
                local failure_guidance=""
                case "$failure_mode" in
                    missing_failure_analysis)
                        failure_guidance="The validator found the failure mode analysis insufficient. The plan MUST include a Failure Mode Analysis section with at least 3 concrete failure modes specific to this codebase (not generic). For each major component, identify runtime failures, concurrency risks, scale risks, and rollback story. Reference specific architecture constraints and project technologies." ;;
                    requirements_unclear)
                        failure_guidance="The validator found the requirements unclear. Add more specific acceptance criteria, input/output examples, and concrete success metrics." ;;
                    insufficient_detail)
                        failure_guidance="The validator found the plan lacks detail. Break each task into smaller, more specific implementation steps with exact file paths and function names." ;;
                    scope_too_large)
                        failure_guidance="The validator found the scope too large. Focus on the minimal viable implementation and defer non-essential features to follow-up tasks." ;;
                esac

                local regen_prompt="${plan_prompt}

IMPORTANT: A previous plan was rejected by validation. Issues found:
$(echo "$validation_result" | tail -20)
${failure_guidance:+
GUIDANCE: ${failure_guidance}}

Fix these issues in the new plan."

                local _regen_flags
                _regen_flags="$(_pipeline_claude_flags "plan" "$plan_model")"
                # shellcheck disable=SC2086
                claude --print $_regen_flags --max-turns "$(_smart_int "max_turns.pipeline_stage" 25)" \
                    "$regen_prompt" < /dev/null > "$plan_file" 2>"$_token_log" || true
                parse_claude_tokens "$_token_log"

                line_count=$(wc -l < "$plan_file" | xargs)
                info "Regenerated plan: ${DIM}$plan_file${RESET} (${line_count} lines)"
            fi
        done

        if [[ "$plan_valid" != "true" ]]; then
            warn "Plan validation did not pass after ${max_validation_attempts} attempts — proceeding anyway"
        fi

        emit_event "plan.validated" \
            "issue=${ISSUE_NUMBER:-0}" \
            "valid=${plan_valid}" \
            "attempts=${validation_attempts}"
    fi

    log_stage "plan" "Generated plan.md (${line_count} lines, $(echo "$checklist" | wc -l | xargs) tasks)"
}

stage_design() {
    CURRENT_STAGE_ID="design"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-design.md"
    local _design_retry_hints=""
    if [[ -s "$_retry_ctx" ]]; then
        _design_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi
    local plan_file="$ARTIFACTS_DIR/plan.md"
    local design_file="$ARTIFACTS_DIR/design.md"

    if [[ ! -s "$plan_file" ]]; then
        warn "No plan found — skipping design stage"
        return 0
    fi

    if ! command -v claude >/dev/null 2>&1; then
        error "Claude CLI not found — cannot generate design"
        return 1
    fi

    info "Generating Architecture Decision Record..."

    # Gather rich architecture context (call-graph, dependencies)
    local arch_struct_context=""
    if type gather_architecture_context &>/dev/null; then
        arch_struct_context=$(gather_architecture_context "${PROJECT_ROOT:-.}" 2>/dev/null || true)
    fi
    arch_struct_context=$(prune_context_section "architecture" "$arch_struct_context" 5000)

    # Memory integration — inject context if memory system available
    local memory_context=""
    if type intelligence_search_memory >/dev/null 2>&1; then
        local mem_dir="${HOME}/.shipwright/memory"
        memory_context=$(intelligence_search_memory "design stage architecture patterns for: ${GOAL:-}" "$mem_dir" 5 2>/dev/null) || true
    fi
    if [[ -z "$memory_context" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        memory_context=$(bash "$SCRIPT_DIR/sw-memory.sh" inject "design" 2>/dev/null) || true
    fi
    memory_context=$(prune_context_section "memory" "$memory_context" 10000)

    # Inject cross-pipeline discoveries for design stage
    local design_discoveries=""
    if [[ -x "$SCRIPT_DIR/sw-discovery.sh" ]]; then
        design_discoveries=$("$SCRIPT_DIR/sw-discovery.sh" inject "*.md,*.ts,*.tsx,*.js" 2>/dev/null | head -20 || true)
    fi
    design_discoveries=$(prune_context_section "discoveries" "$design_discoveries" 3000)

    # Inject architecture model patterns if available
    local arch_context=""
    local repo_hash
    repo_hash=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local arch_model_file="${HOME}/.shipwright/memory/${repo_hash}/architecture.json"
    if [[ -f "$arch_model_file" ]]; then
        local arch_patterns
        arch_patterns=$(jq -r '
            [.patterns // [] | .[] | "- \(.name // "unnamed"): \(.description // "no description")"] | join("\n")
        ' "$arch_model_file" 2>/dev/null) || true
        local arch_layers
        arch_layers=$(jq -r '
            [.layers // [] | .[] | "- \(.name // "unnamed"): \(.path // "")"] | join("\n")
        ' "$arch_model_file" 2>/dev/null) || true
        if [[ -n "$arch_patterns" || -n "$arch_layers" ]]; then
            arch_context="Previous designs in this repo follow these patterns:
${arch_patterns:+Patterns:
${arch_patterns}
}${arch_layers:+Layers:
${arch_layers}}"
        fi
    fi
    arch_context=$(prune_context_section "intelligence" "$arch_context" 5000)

    # Inject rejected design approaches and anti-patterns from memory
    local design_antipatterns=""
    if type intelligence_search_memory >/dev/null 2>&1; then
        local rejected_designs
        rejected_designs=$(intelligence_search_memory "rejected design approaches anti-patterns for: ${GOAL:-}" "${HOME}/.shipwright/memory" 3 2>/dev/null) || true
        if [[ -n "$rejected_designs" ]]; then
            rejected_designs=$(prune_context_section "antipatterns" "$rejected_designs" 5000)
            design_antipatterns="
## Rejected Approaches (from past reviews)
These design approaches were rejected in past reviews. Avoid repeating them:
${rejected_designs}
"
        fi
    fi

    # Build design prompt with plan + project context
    local project_lang
    project_lang=$(detect_project_lang)

    local design_prompt="You are a senior software architect. Review the implementation plan below and produce an Architecture Decision Record (ADR).

## Goal
${GOAL}

## Implementation Plan
$(cat "$plan_file")

## Project Context
- Language: ${project_lang}
- Test command: ${TEST_CMD:-not configured}
- Task type: ${TASK_TYPE:-feature}
${arch_struct_context:+
## Architecture Context (import graph, modules, test map)
${arch_struct_context}
}${memory_context:+
## Historical Context (from memory)
${memory_context}
}${arch_context:+
## Architecture Model (from previous designs)
${arch_context}
}${design_antipatterns}${design_discoveries:+
## Discoveries from Other Pipelines
${design_discoveries}
}
## Required Output — Architecture Decision Record

Produce this EXACT format:

# Design: ${GOAL}

## Context
[What problem we're solving, constraints from the codebase]

## Decision
[The chosen approach — be specific about patterns, data flow, error handling]

## Alternatives Considered
1. [Alternative A] — Pros: ... / Cons: ...
2. [Alternative B] — Pros: ... / Cons: ...

## Implementation Plan
- Files to create: [list with full paths]
- Files to modify: [list with full paths]
- Dependencies: [new deps if any]
- Risk areas: [fragile code, performance concerns]

## Validation Criteria
- [ ] [How we'll know the design is correct — testable criteria]
- [ ] [Additional validation items]

Be concrete and specific. Reference actual file paths in the codebase. Consider edge cases and failure modes."

    # Inject skill prompts for design stage
    local _skill_prompts=""
    if type skill_load_from_plan >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_from_plan "design" 2>/dev/null || true)
    elif type skill_select_adaptive >/dev/null 2>&1; then
        local _skill_files
        _skill_files=$(skill_select_adaptive "${INTELLIGENCE_ISSUE_TYPE:-backend}" "design" "${ISSUE_BODY:-}" "${INTELLIGENCE_COMPLEXITY:-5}" 2>/dev/null || true)
        if [[ -n "$_skill_files" ]]; then
            _skill_prompts=$(while IFS= read -r _path; do
                [[ -z "$_path" || ! -f "$_path" ]] && continue
                cat "$_path" 2>/dev/null
            done <<< "$_skill_files")
        fi
    elif type skill_load_prompts >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "design" 2>/dev/null || true)
    fi
    if [[ -n "$_skill_prompts" ]]; then
        _skill_prompts=$(prune_context_section "skills" "$_skill_prompts" 8000)
        design_prompt="${design_prompt}
## Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue, AI-selected)
${_skill_prompts}
"
    fi

    # Guard total prompt size
    design_prompt=$(guard_prompt_size "design" "$design_prompt")

    local design_model
    design_model=$(jq -r --arg id "design" '(.stages[] | select(.id == $id) | .config.model) // .defaults.model // "opus"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -n "$MODEL" ]] && design_model="$MODEL"
    [[ -z "$design_model" || "$design_model" == "null" ]] && design_model="opus"
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        design_model="$CLAUDE_MODEL"
    fi

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-design.log"
    local _design_flags
    _design_flags="$(_pipeline_claude_flags "design" "$design_model")"
    # shellcheck disable=SC2086
    claude --print $_design_flags --max-turns "$(_smart_int "max_turns.pipeline_stage" 25)" --dangerously-skip-permissions \
        "$design_prompt" < /dev/null > "$design_file" 2>"$_token_log" || true
    parse_claude_tokens "$_token_log"

    # Claude may write to disk via tools instead of stdout — rescue those files
    local _design_rescue
    for _design_rescue in "${PROJECT_ROOT}/design-adr.md" "${PROJECT_ROOT}/design.md" \
                           "${PROJECT_ROOT}/ADR.md" "${PROJECT_ROOT}/DESIGN.md"; do
        if [[ -s "$_design_rescue" ]] && [[ $(wc -l < "$design_file" 2>/dev/null | xargs) -lt 10 ]]; then
            info "Design written to ${_design_rescue} via tools — adopting as design artifact"
            cat "$_design_rescue" >> "$design_file"
            rm -f "$_design_rescue"
            break
        fi
    done

    if [[ ! -s "$design_file" ]]; then
        error "Design generation failed — empty output"
        return 1
    fi

    # Validate design content — detect API/CLI errors masquerading as designs
    local _design_fatal="Invalid API key|invalid_api_key|authentication_error|API key expired"
    _design_fatal="${_design_fatal}|rate_limit_error|overloaded_error|Could not resolve host|ANTHROPIC_API_KEY"
    if grep -qiE "$_design_fatal" "$design_file" 2>/dev/null; then
        error "Design stage produced API/CLI error instead of a design: $(head -1 "$design_file" | cut -c1-100)"
        return 1
    fi

    local line_count
    line_count=$(wc -l < "$design_file" | xargs)
    if [[ "$line_count" -lt 3 ]]; then
        error "Design too short (${line_count} lines) — likely an error, not a real design"
        return 1
    fi
    info "Design saved: ${DIM}$design_file${RESET} (${line_count} lines)"

    # Extract file lists for build stage awareness
    local files_to_create files_to_modify
    files_to_create=$(sed -n '/Files to create/,/^-\|^#\|^$/p' "$design_file" 2>/dev/null | grep -E '^\s*-' | head -20 || true)
    files_to_modify=$(sed -n '/Files to modify/,/^-\|^#\|^$/p' "$design_file" 2>/dev/null | grep -E '^\s*-' | head -20 || true)

    if [[ -n "$files_to_create" || -n "$files_to_modify" ]]; then
        info "Design scope: ${DIM}$(echo "$files_to_create $files_to_modify" | grep -c '^\s*-' || true) file(s)${RESET}"
    fi

    # Post design to GitHub issue
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local design_summary
        design_summary=$(head -60 "$design_file")
        gh_comment_issue "$ISSUE_NUMBER" "## 📐 Architecture Decision Record

<details>
<summary>Click to expand ADR (${line_count} lines)</summary>

${design_summary}

</details>

---
_Generated by \`shipwright pipeline\` design stage at $(now_iso)_"
    fi

    # Push design to wiki
    gh_wiki_page "Pipeline-Design-${ISSUE_NUMBER:-inline}" "$(<"$design_file")"

    log_stage "design" "Generated design.md (${line_count} lines)"
}

# ─── TDD: Generate tests before implementation ─────────────────────────────────
