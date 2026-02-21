# pipeline-stages.sh — Stage implementations (intake, plan, build, test, review, pr, merge, deploy, validate, monitor) for sw-pipeline.sh
# Source from sw-pipeline.sh. Requires all pipeline globals and state/github/detection/quality modules.
[[ -n "${_PIPELINE_STAGES_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_LOADED=1

show_stage_preview() {
    local stage_id="$1"
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Stage: ${stage_id} ━━━${RESET}"
    case "$stage_id" in
        intake)   echo -e "  Fetch issue, detect task type, create branch, self-assign" ;;
        plan)     echo -e "  Generate plan via Claude, post task checklist to issue" ;;
        design)   echo -e "  Generate Architecture Decision Record (ADR), evaluate alternatives" ;;
        build)    echo -e "  Delegate to ${CYAN}shipwright loop${RESET} for autonomous building" ;;
        test_first) echo -e "  Generate tests from requirements (TDD mode) before implementation" ;;
        test)     echo -e "  Run test suite and check coverage" ;;
        review)   echo -e "  AI code review on the diff, post findings" ;;
        pr)       echo -e "  Create GitHub PR with labels, reviewers, milestone" ;;
        merge)    echo -e "  Wait for CI checks, merge PR, optionally delete branch" ;;
        deploy)   echo -e "  Deploy to staging/production with rollback" ;;
        validate) echo -e "  Smoke tests, health checks, close issue" ;;
        monitor)  echo -e "  Post-deploy monitoring, health checks, auto-rollback" ;;
    esac
    echo ""
}

stage_intake() {
    CURRENT_STAGE_ID="intake"
    local project_lang
    project_lang=$(detect_project_lang)
    info "Project: ${BOLD}$project_lang${RESET}"

    # 1. Fetch issue metadata if --issue provided
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local meta
        meta=$(gh_get_issue_meta "$ISSUE_NUMBER")

        if [[ -n "$meta" ]]; then
            GOAL=$(echo "$meta" | jq -r '.title // ""')
            ISSUE_BODY=$(echo "$meta" | jq -r '.body // ""')
            ISSUE_LABELS=$(echo "$meta" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || true)
            ISSUE_MILESTONE=$(echo "$meta" | jq -r '.milestone.title // ""' 2>/dev/null || true)
            ISSUE_ASSIGNEES=$(echo "$meta" | jq -r '[.assignees[].login] | join(",")' 2>/dev/null || true)
            [[ "$ISSUE_MILESTONE" == "null" ]] && ISSUE_MILESTONE=""
            [[ "$ISSUE_LABELS" == "null" ]] && ISSUE_LABELS=""
        else
            # Fallback: just get title
            GOAL=$(gh issue view "$ISSUE_NUMBER" --json title -q .title 2>/dev/null) || {
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
        '{goal:$goal, type:$type, template:$template, branch:$branch,
          issue:$issue, language:$lang, test_cmd:$test_cmd,
          labels:$labels, milestone:$milestone, body:$body}')"

    log_stage "intake" "Goal: $GOAL
Type: $TASK_TYPE → template: $suggested_template
Branch: $GIT_BRANCH
Language: $project_lang
Test cmd: ${TEST_CMD:-none detected}"
}

stage_plan() {
    CURRENT_STAGE_ID="plan"
    local plan_file="$ARTIFACTS_DIR/plan.md"

    if ! command -v claude >/dev/null 2>&1; then
        error "Claude CLI not found — cannot generate plan"
        return 1
    fi

    info "Generating implementation plan..."

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

    # Inject cross-pipeline discoveries (from other concurrent/similar pipelines)
    if [[ -x "$SCRIPT_DIR/sw-discovery.sh" ]]; then
        local plan_discoveries
        plan_discoveries=$("$SCRIPT_DIR/sw-discovery.sh" inject "*.md,*.json" 2>/dev/null | head -20 || true)
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
        if [[ -n "$arch_patterns" ]]; then
            plan_prompt="${plan_prompt}
## Architecture Patterns
${arch_patterns}
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

    local plan_model
    plan_model=$(jq -r --arg id "plan" '(.stages[] | select(.id == $id) | .config.model) // .defaults.model // "opus"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -n "$MODEL" ]] && plan_model="$MODEL"
    [[ -z "$plan_model" || "$plan_model" == "null" ]] && plan_model="opus"
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        plan_model="$CLAUDE_MODEL"
    fi

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-plan.log"
    claude --print --model "$plan_model" --max-turns 25 \
        "$plan_prompt" < /dev/null > "$plan_file" 2>"$_token_log" || true
    parse_claude_tokens "$_token_log"

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
            validation_result=$(claude --print --output-format text -p "$validation_prompt" --model "$validation_model" < /dev/null 2>"${ARTIFACTS_DIR}/.claude-tokens-plan-validate.log" || true)
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
            if echo "$validation_lower" | grep -qE 'requirements? unclear|goal.*vague|ambiguous|underspecified'; then
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

                claude --print --model "$plan_model" --max-turns 25 \
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

    # Memory integration — inject context if memory system available
    local memory_context=""
    if type intelligence_search_memory >/dev/null 2>&1; then
        local mem_dir="${HOME}/.shipwright/memory"
        memory_context=$(intelligence_search_memory "design stage architecture patterns for: ${GOAL:-}" "$mem_dir" 5 2>/dev/null) || true
    fi
    if [[ -z "$memory_context" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        memory_context=$(bash "$SCRIPT_DIR/sw-memory.sh" inject "design" 2>/dev/null) || true
    fi

    # Inject cross-pipeline discoveries for design stage
    local design_discoveries=""
    if [[ -x "$SCRIPT_DIR/sw-discovery.sh" ]]; then
        design_discoveries=$("$SCRIPT_DIR/sw-discovery.sh" inject "*.md,*.ts,*.tsx,*.js" 2>/dev/null | head -20 || true)
    fi

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

    # Inject rejected design approaches and anti-patterns from memory
    local design_antipatterns=""
    if type intelligence_search_memory >/dev/null 2>&1; then
        local rejected_designs
        rejected_designs=$(intelligence_search_memory "rejected design approaches anti-patterns for: ${GOAL:-}" "${HOME}/.shipwright/memory" 3 2>/dev/null) || true
        if [[ -n "$rejected_designs" ]]; then
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

    local design_model
    design_model=$(jq -r --arg id "design" '(.stages[] | select(.id == $id) | .config.model) // .defaults.model // "opus"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -n "$MODEL" ]] && design_model="$MODEL"
    [[ -z "$design_model" || "$design_model" == "null" ]] && design_model="opus"
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        design_model="$CLAUDE_MODEL"
    fi

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-design.log"
    claude --print --model "$design_model" --max-turns 25 \
        "$design_prompt" < /dev/null > "$design_file" 2>"$_token_log" || true
    parse_claude_tokens "$_token_log"

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
        info "Design scope: ${DIM}$(echo "$files_to_create $files_to_modify" | grep -c '^\s*-' || echo 0) file(s)${RESET}"
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
stage_test_first() {
    CURRENT_STAGE_ID="test_first"
    info "Generating tests from requirements (TDD mode)"

    local plan_file="${ARTIFACTS_DIR}/plan.md"
    local goal_file="${PROJECT_ROOT}/.claude/goal.md"
    local requirements=""
    if [[ -f "$plan_file" ]]; then
        requirements=$(cat "$plan_file" 2>/dev/null || true)
    elif [[ -f "$goal_file" ]]; then
        requirements=$(cat "$goal_file" 2>/dev/null || true)
    else
        requirements="${GOAL:-}: ${ISSUE_BODY:-}"
    fi

    local tdd_prompt="You are writing tests BEFORE implementation (TDD).

Based on the following plan/requirements, generate test files that define the expected behavior. These tests should FAIL initially (since the implementation doesn't exist yet) but define the correct interface and behavior.

Requirements:
${requirements}

Instructions:
1. Create test files for each component mentioned in the plan
2. Tests should verify the PUBLIC interface and expected behavior
3. Include edge cases and error handling tests
4. Tests should be runnable with the project's test framework
5. Mark tests that need implementation with clear TODO comments
6. Do NOT write implementation code — only tests

Output format: For each test file, use a fenced code block with the file path as the language identifier (e.g. \`\`\`tests/auth.test.ts):
\`\`\`path/to/test.test.ts
// file content
\`\`\`

Create files in the appropriate project directories (e.g. tests/, __tests__/, src/**/*.test.ts) per project convention."

    local model="${CLAUDE_MODEL:-${MODEL:-sonnet}}"
    [[ -z "$model" || "$model" == "null" ]] && model="sonnet"

    local output=""
    output=$(echo "$tdd_prompt" | timeout 120 claude --print --model "$model" 2>/dev/null) || {
        warn "TDD test generation failed, falling back to standard build"
        return 1
    }

    # Parse output: extract fenced code blocks and write to files
    local wrote_any=false
    local block_path="" in_block=false block_content=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\`\`\`([a-zA-Z0-9_/\.\-]+)$ ]]; then
            if [[ -n "$block_path" && -n "$block_content" ]]; then
                local out_file="${PROJECT_ROOT}/${block_path}"
                local out_dir
                out_dir=$(dirname "$out_file")
                mkdir -p "$out_dir" 2>/dev/null || true
                if echo "$block_content" > "$out_file" 2>/dev/null; then
                    wrote_any=true
                    info "  Wrote: $block_path"
                fi
            fi
            block_path="${BASH_REMATCH[1]}"
            block_content=""
            in_block=true
        elif [[ "$line" == "\`\`\`" && "$in_block" == "true" ]]; then
            if [[ -n "$block_path" && -n "$block_content" ]]; then
                local out_file="${PROJECT_ROOT}/${block_path}"
                local out_dir
                out_dir=$(dirname "$out_file")
                mkdir -p "$out_dir" 2>/dev/null || true
                if echo "$block_content" > "$out_file" 2>/dev/null; then
                    wrote_any=true
                    info "  Wrote: $block_path"
                fi
            fi
            block_path=""
            block_content=""
            in_block=false
        elif [[ "$in_block" == "true" && -n "$block_path" ]]; then
            [[ -n "$block_content" ]] && block_content="${block_content}"$'\n'
            block_content="${block_content}${line}"
        fi
    done <<< "$output"

    # Flush last block if unclosed
    if [[ -n "$block_path" && -n "$block_content" ]]; then
        local out_file="${PROJECT_ROOT}/${block_path}"
        local out_dir
        out_dir=$(dirname "$out_file")
        mkdir -p "$out_dir" 2>/dev/null || true
        if echo "$block_content" > "$out_file" 2>/dev/null; then
            wrote_any=true
            info "  Wrote: $block_path"
        fi
    fi

    if [[ "$wrote_any" == "true" ]]; then
        if (cd "$PROJECT_ROOT" && git diff --name-only 2>/dev/null | grep -qE 'test|spec'); then
            git add -A 2>/dev/null || true
            git commit -m "test: TDD - define expected behavior before implementation" 2>/dev/null || true
            emit_event "tdd.tests_generated" "{\"stage\":\"test_first\"}"
        fi
        success "TDD tests generated"
    else
        warn "No test files extracted from TDD output — check format"
    fi

    return 0
}

stage_build() {
    local plan_file="$ARTIFACTS_DIR/plan.md"
    local design_file="$ARTIFACTS_DIR/design.md"
    local dod_file="$ARTIFACTS_DIR/dod.md"
    local loop_args=()

    # Memory integration — inject context if memory system available
    local memory_context=""
    if type intelligence_search_memory >/dev/null 2>&1; then
        local mem_dir="${HOME}/.shipwright/memory"
        memory_context=$(intelligence_search_memory "build stage for: ${GOAL:-}" "$mem_dir" 5 2>/dev/null) || true
    fi
    if [[ -z "$memory_context" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        memory_context=$(bash "$SCRIPT_DIR/sw-memory.sh" inject "build" 2>/dev/null) || true
    fi

    # Build enriched goal with compact context (avoids prompt bloat)
    local enriched_goal
    enriched_goal=$(_pipeline_compact_goal "$GOAL" "$plan_file" "$design_file")

    # TDD: when test_first ran, tell build to make existing tests pass
    if [[ "${TDD_ENABLED:-false}" == "true" || "${PIPELINE_TDD:-}" == "true" ]]; then
        enriched_goal="${enriched_goal}

IMPORTANT (TDD mode): Test files already exist and define the expected behavior. Write implementation code to make ALL tests pass. Do not delete or modify the test files."
    fi

    # Inject memory context
    if [[ -n "$memory_context" ]]; then
        enriched_goal="${enriched_goal}

Historical context (lessons from previous pipelines):
${memory_context}"
    fi

    # Inject cross-pipeline discoveries for build stage
    if [[ -x "$SCRIPT_DIR/sw-discovery.sh" ]]; then
        local build_discoveries
        build_discoveries=$("$SCRIPT_DIR/sw-discovery.sh" inject "src/*,*.ts,*.tsx,*.js" 2>/dev/null | head -20 || true)
        if [[ -n "$build_discoveries" ]]; then
            enriched_goal="${enriched_goal}

Discoveries from other pipelines:
${build_discoveries}"
        fi
    fi

    # Add task list context
    if [[ -s "$TASKS_FILE" ]]; then
        enriched_goal="${enriched_goal}

Task tracking (check off items as you complete them):
$(cat "$TASKS_FILE")"
    fi

    # Inject file hotspots from GitHub intelligence
    if [[ "${NO_GITHUB:-}" != "true" ]] && type gh_file_change_frequency >/dev/null 2>&1; then
        local build_hotspots
        build_hotspots=$(gh_file_change_frequency 2>/dev/null | head -5 || true)
        if [[ -n "$build_hotspots" ]]; then
            enriched_goal="${enriched_goal}

File hotspots (most frequently changed — review these carefully):
${build_hotspots}"
        fi
    fi

    # Inject security alerts context
    if [[ "${NO_GITHUB:-}" != "true" ]] && type gh_security_alerts >/dev/null 2>&1; then
        local build_alerts
        build_alerts=$(gh_security_alerts 2>/dev/null | head -3 || true)
        if [[ -n "$build_alerts" ]]; then
            enriched_goal="${enriched_goal}

Active security alerts (do not introduce new vulnerabilities):
${build_alerts}"
        fi
    fi

    # Inject coverage baseline
    local repo_hash_build
    repo_hash_build=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local coverage_file_build="${HOME}/.shipwright/baselines/${repo_hash_build}/coverage.json"
    if [[ -f "$coverage_file_build" ]]; then
        local coverage_baseline
        coverage_baseline=$(jq -r '.coverage_percent // empty' "$coverage_file_build" 2>/dev/null || true)
        if [[ -n "$coverage_baseline" ]]; then
            enriched_goal="${enriched_goal}

Coverage baseline: ${coverage_baseline}% — do not decrease coverage."
        fi
    fi

    # Predictive: inject prevention hints when risk/memory patterns suggest build-stage failures
    if [[ -x "$SCRIPT_DIR/sw-predictive.sh" ]]; then
        local issue_json_build="{}"
        [[ -n "${ISSUE_NUMBER:-}" ]] && issue_json_build=$(jq -n --arg title "${GOAL:-}" --arg num "${ISSUE_NUMBER:-}" '{title: $title, number: $num}')
        local prevention_text
        prevention_text=$(bash "$SCRIPT_DIR/sw-predictive.sh" inject-prevention "build" "$issue_json_build" 2>/dev/null || true)
        if [[ -n "$prevention_text" ]]; then
            enriched_goal="${enriched_goal}

${prevention_text}"
        fi
    fi

    loop_args+=("$enriched_goal")

    # Build loop args from pipeline config + CLI overrides
    CURRENT_STAGE_ID="build"

    local test_cmd="${TEST_CMD}"
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.test_cmd) // .defaults.test_cmd // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ "$test_cmd" == "null" ]] && test_cmd=""
    fi
    # Auto-detect if still empty
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(detect_test_cmd)
    fi

    local max_iter
    max_iter=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.max_iterations) // 20' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$max_iter" || "$max_iter" == "null" ]] && max_iter=20
    # CLI --max-iterations override (from CI strategy engine)
    [[ -n "${MAX_ITERATIONS_OVERRIDE:-}" ]] && max_iter="$MAX_ITERATIONS_OVERRIDE"

    local agents="${AGENTS}"
    if [[ -z "$agents" ]]; then
        agents=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.agents) // .defaults.agents // 1' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$agents" || "$agents" == "null" ]] && agents=1
    fi

    # Intelligence: suggest parallelism if design indicates independent work
    if [[ "${agents:-1}" -le 1 ]] && [[ -s "$ARTIFACTS_DIR/design.md" ]]; then
        local design_lower
        design_lower=$(tr '[:upper:]' '[:lower:]' < "$ARTIFACTS_DIR/design.md" 2>/dev/null || true)
        if echo "$design_lower" | grep -qE 'independent (files|modules|components|services)|separate (modules|packages|directories)|parallel|no shared state'; then
            info "Design mentions independent modules — consider --agents 2 for parallelism"
            emit_event "build.parallelism_suggested" "issue=${ISSUE_NUMBER:-0}" "current_agents=$agents"
        fi
    fi

    local audit
    audit=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.audit) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    local quality
    quality=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.quality_gates) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true

    local build_model="${MODEL}"
    if [[ -z "$build_model" ]]; then
        build_model=$(jq -r '.defaults.model // "opus"' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$build_model" || "$build_model" == "null" ]] && build_model="opus"
    fi
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        build_model="$CLAUDE_MODEL"
    fi

    # Recruit-powered model selection (when no explicit override)
    if [[ -z "$MODEL" ]] && [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
        local _recruit_goal="${GOAL:-}"
        if [[ -n "$_recruit_goal" ]]; then
            local _recruit_match
            _recruit_match=$(bash "$SCRIPT_DIR/sw-recruit.sh" match --json "$_recruit_goal" 2>/dev/null) || true
            if [[ -n "$_recruit_match" ]]; then
                local _recruit_model
                _recruit_model=$(echo "$_recruit_match" | jq -r '.model // ""' 2>/dev/null) || true
                if [[ -n "$_recruit_model" && "$_recruit_model" != "null" && "$_recruit_model" != "" ]]; then
                    info "Recruit recommends model: ${CYAN}${_recruit_model}${RESET} for this task"
                    build_model="$_recruit_model"
                fi
            fi
        fi
    fi

    [[ -n "$test_cmd" && "$test_cmd" != "null" ]] && loop_args+=(--test-cmd "$test_cmd")
    loop_args+=(--max-iterations "$max_iter")
    loop_args+=(--model "$build_model")
    [[ "$agents" -gt 1 ]] 2>/dev/null && loop_args+=(--agents "$agents")

    # Quality gates: always enabled in CI, otherwise from template config
    if [[ "${CI_MODE:-false}" == "true" ]]; then
        loop_args+=(--audit --audit-agent --quality-gates)
    else
        [[ "$audit" == "true" ]] && loop_args+=(--audit --audit-agent)
        [[ "$quality" == "true" ]] && loop_args+=(--quality-gates)
    fi

    # Session restart capability
    [[ -n "${MAX_RESTARTS_OVERRIDE:-}" ]] && loop_args+=(--max-restarts "$MAX_RESTARTS_OVERRIDE")
    # Fast test mode
    [[ -n "${FAST_TEST_CMD_OVERRIDE:-}" ]] && loop_args+=(--fast-test-cmd "$FAST_TEST_CMD_OVERRIDE")

    # Definition of Done: use plan-extracted DoD if available
    [[ -s "$dod_file" ]] && loop_args+=(--definition-of-done "$dod_file")

    # Checkpoint resume: when pipeline resumed from build-stage checkpoint, pass --resume to loop
    if [[ "${RESUME_FROM_CHECKPOINT:-false}" == "true" && "${checkpoint_stage:-}" == "build" ]]; then
        loop_args+=(--resume)
    fi

    # Autonomous pipelines need file write permissions
    loop_args+=(--skip-permissions)

    # Skip permissions in CI (no interactive terminal)
    [[ "${CI_MODE:-false}" == "true" ]] && loop_args+=(--skip-permissions)

    info "Starting build loop: ${DIM}shipwright loop${RESET} (max ${max_iter} iterations, ${agents} agent(s))"

    # Post build start to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "🔨 **Build started** — \`shipwright loop\` with ${max_iter} max iterations, ${agents} agent(s), model: ${build_model}"
    fi

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-build.log"
    export PIPELINE_JOB_ID="${PIPELINE_NAME:-pipeline-$$}"
    sw loop "${loop_args[@]}" < /dev/null 2>"$_token_log" || {
        local _loop_exit=$?
        parse_claude_tokens "$_token_log"

        # Detect context exhaustion from progress file
        local _progress_file="${PWD}/.claude/loop-logs/progress.md"
        if [[ -f "$_progress_file" ]]; then
            local _prog_tests
            _prog_tests=$(grep -oE 'Tests passing: (true|false)' "$_progress_file" 2>/dev/null | awk '{print $NF}' || echo "unknown")
            if [[ "$_prog_tests" != "true" ]]; then
                warn "Build loop exhausted with failing tests (context exhaustion)"
                emit_event "pipeline.context_exhaustion" "issue=${ISSUE_NUMBER:-0}" "stage=build"
                # Write flag for daemon retry logic
                mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
                echo "context_exhaustion" > "$ARTIFACTS_DIR/failure-reason.txt" 2>/dev/null || true
            fi
        fi

        error "Build loop failed"
        return 1
    }
    parse_claude_tokens "$_token_log"

    # Read accumulated token counts from build loop (written by sw-loop.sh)
    local _loop_token_file="${PROJECT_ROOT}/.claude/loop-logs/loop-tokens.json"
    if [[ -f "$_loop_token_file" ]] && command -v jq >/dev/null 2>&1; then
        local _loop_in _loop_out _loop_cost
        _loop_in=$(jq -r '.input_tokens // 0' "$_loop_token_file" 2>/dev/null || echo "0")
        _loop_out=$(jq -r '.output_tokens // 0' "$_loop_token_file" 2>/dev/null || echo "0")
        _loop_cost=$(jq -r '.cost_usd // 0' "$_loop_token_file" 2>/dev/null || echo "0")
        TOTAL_INPUT_TOKENS=$(( TOTAL_INPUT_TOKENS + ${_loop_in:-0} ))
        TOTAL_OUTPUT_TOKENS=$(( TOTAL_OUTPUT_TOKENS + ${_loop_out:-0} ))
        if [[ -n "$_loop_cost" && "$_loop_cost" != "0" && "$_loop_cost" != "null" ]]; then
            TOTAL_COST_USD="${_loop_cost}"
        fi
        if [[ "${_loop_in:-0}" -gt 0 || "${_loop_out:-0}" -gt 0 ]]; then
            info "Build loop tokens: in=${_loop_in} out=${_loop_out} cost=\$${_loop_cost:-0}"
        fi
    fi

    # Count commits made during build
    local commit_count
    commit_count=$(git log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null | wc -l | xargs)
    info "Build produced ${BOLD}$commit_count${RESET} commit(s)"

    # Commit quality evaluation when intelligence is enabled
    if type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1 && [[ "${commit_count:-0}" -gt 0 ]]; then
        local commit_msgs
        commit_msgs=$(git log --format="%s" "${BASE_BRANCH}..HEAD" 2>/dev/null | head -20)
        local quality_score
        quality_score=$(claude --print --output-format text -p "Rate the quality of these git commit messages on a scale of 0-100. Consider: focus (one thing per commit), clarity (describes the why), atomicity (small logical units). Reply with ONLY a number 0-100.

Commit messages:
${commit_msgs}" --model haiku < /dev/null 2>/dev/null || true)
        quality_score=$(echo "$quality_score" | grep -oE '^[0-9]+' | head -1 || true)
        if [[ -n "$quality_score" ]]; then
            emit_event "build.commit_quality" \
                "issue=${ISSUE_NUMBER:-0}" \
                "score=$quality_score" \
                "commit_count=$commit_count"
            if [[ "$quality_score" -lt 40 ]] 2>/dev/null; then
                warn "Commit message quality low (score: ${quality_score}/100)"
            else
                info "Commit quality score: ${quality_score}/100"
            fi
        fi
    fi

    log_stage "build" "Build loop completed ($commit_count commits)"
}

stage_test() {
    CURRENT_STAGE_ID="test"
    local test_cmd="${TEST_CMD}"
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.test_cmd) // .defaults.test_cmd // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$test_cmd" || "$test_cmd" == "null" ]] && test_cmd=""
    fi
    # Auto-detect
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(detect_test_cmd)
    fi
    if [[ -z "$test_cmd" ]]; then
        warn "No test command found — skipping test stage"
        return 0
    fi

    local coverage_min
    coverage_min=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.coverage_min) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$coverage_min" || "$coverage_min" == "null" ]] && coverage_min=0

    local test_log="$ARTIFACTS_DIR/test-results.log"

    info "Running tests: ${DIM}$test_cmd${RESET}"
    local test_exit=0
    bash -c "$test_cmd" > "$test_log" 2>&1 || test_exit=$?

    if [[ "$test_exit" -eq 0 ]]; then
        success "Tests passed"
    else
        error "Tests failed (exit code: $test_exit)"
        # Extract most relevant error section (assertion failures, stack traces)
        local relevant_output=""
        relevant_output=$(grep -A5 -E 'FAIL|AssertionError|Expected.*but.*got|Error:|panic:|assert' "$test_log" 2>/dev/null | tail -40 || true)
        if [[ -z "$relevant_output" ]]; then
            relevant_output=$(tail -40 "$test_log")
        fi
        echo "$relevant_output"

        # Post failure to GitHub — filter out noisy simulator lists
        if [[ -n "$ISSUE_NUMBER" ]]; then
            local log_lines
            log_lines=$(wc -l < "$test_log" 2>/dev/null || echo "0")
            # Filter out simulator destination noise, keep meaningful errors
            local log_excerpt
            log_excerpt=$(grep -vE '^\s*\{ platform:|Available destinations|The requested device|no available devices' "$test_log" 2>/dev/null || true)
            local filtered_lines
            filtered_lines=$(echo "$log_excerpt" | wc -l | tr -d ' ')
            if [[ "$filtered_lines" -gt 50 ]]; then
                log_excerpt="$(echo "$log_excerpt" | head -20)
... (${filtered_lines} lines, showing head + tail) ...
$(echo "$log_excerpt" | tail -20)"
            fi
            gh_comment_issue "$ISSUE_NUMBER" "❌ **Tests failed** (exit code: $test_exit, ${log_lines} lines)
\`\`\`
${log_excerpt}
\`\`\`" >/dev/null 2>&1 || true
        fi
        return 1
    fi

    # Coverage check — only enforce when coverage data is actually detected
    local coverage=""
    if [[ "$coverage_min" -gt 0 ]] 2>/dev/null; then
        coverage=$(parse_coverage_from_output "$test_log")
        if [[ -z "$coverage" ]]; then
            # No coverage data found — skip enforcement (project may not have coverage tooling)
            info "No coverage data detected — skipping coverage check (min: ${coverage_min}%)"
        elif awk -v cov="$coverage" -v min="$coverage_min" 'BEGIN{exit !(cov < min)}' 2>/dev/null; then
            warn "Coverage ${coverage}% below minimum ${coverage_min}%"
            return 1
        else
            info "Coverage: ${coverage}% (min: ${coverage_min}%)"
        fi
    fi

    # Emit test.completed with coverage for adaptive learning
    if [[ -n "$coverage" ]]; then
        emit_event "test.completed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=test" \
            "coverage=$coverage"
    fi

    # Post test results to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local test_summary
        test_summary=$(tail -10 "$test_log" | sed 's/\x1b\[[0-9;]*m//g')
        local cov_line=""
        [[ -n "$coverage" ]] && cov_line="
**Coverage:** ${coverage}%"
        gh_comment_issue "$ISSUE_NUMBER" "✅ **Tests passed**${cov_line}
<details>
<summary>Test output</summary>

\`\`\`
${test_summary}
\`\`\`
</details>"
    fi

    # Write coverage summary for pre-deploy gate
    local _cov_pct=0
    if [[ -f "$ARTIFACTS_DIR/test-results.log" ]]; then
        _cov_pct=$(grep -oE '[0-9]+%' "$ARTIFACTS_DIR/test-results.log" 2>/dev/null | head -1 | tr -d '%' || true)
        _cov_pct="${_cov_pct:-0}"
    fi
    local _cov_tmp
    _cov_tmp=$(mktemp "${ARTIFACTS_DIR}/test-coverage.json.tmp.XXXXXX")
    printf '{"coverage_pct":%d}' "${_cov_pct:-0}" > "$_cov_tmp" && mv "$_cov_tmp" "$ARTIFACTS_DIR/test-coverage.json" || rm -f "$_cov_tmp"

    log_stage "test" "Tests passed${coverage:+ (coverage: ${coverage}%)}"
}

stage_review() {
    CURRENT_STAGE_ID="review"
    local diff_file="$ARTIFACTS_DIR/review-diff.patch"
    local review_file="$ARTIFACTS_DIR/review.md"

    git diff "${BASE_BRANCH}...${GIT_BRANCH}" > "$diff_file" 2>/dev/null || \
        git diff HEAD~5 > "$diff_file" 2>/dev/null || true

    if [[ ! -s "$diff_file" ]]; then
        warn "No diff found — skipping review"
        return 0
    fi

    if ! command -v claude >/dev/null 2>&1; then
        warn "Claude CLI not found — skipping AI review"
        return 0
    fi

    local diff_stats
    diff_stats=$(git diff --stat "${BASE_BRANCH}...${GIT_BRANCH}" 2>/dev/null | tail -1 || echo "")
    info "Running AI code review... ${DIM}($diff_stats)${RESET}"

    # Semantic risk scoring when intelligence is enabled
    if type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
        local diff_files
        diff_files=$(git diff --name-only "${BASE_BRANCH}...${GIT_BRANCH}" 2>/dev/null || true)
        local risk_score="low"
        # Fast heuristic: flag high-risk file patterns
        if echo "$diff_files" | grep -qiE 'migration|schema|auth|crypto|security|password|token|secret|\.env'; then
            risk_score="high"
        elif echo "$diff_files" | grep -qiE 'api|route|controller|middleware|hook'; then
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

    # Build review prompt with project context
    local review_prompt="You are a senior code reviewer. Review this git diff thoroughly.

For each issue found, use this format:
- **[SEVERITY]** file:line — description

Severity levels: Critical, Bug, Security, Warning, Suggestion

Focus on:
1. Logic bugs and edge cases
2. Security vulnerabilities (injection, XSS, auth bypass, etc.)
3. Error handling gaps
4. Performance issues
5. Missing validation
6. Project convention violations (see conventions below)

Be specific. Reference exact file paths and line numbers. Only flag genuine issues.
If no issues are found, write: \"Review clean — no issues found.\"
"

    # Inject previous review findings and anti-patterns from memory
    if type intelligence_search_memory >/dev/null 2>&1; then
        local review_memory
        review_memory=$(intelligence_search_memory "code review findings anti-patterns for: ${GOAL:-}" "${HOME}/.shipwright/memory" 5 2>/dev/null) || true
        if [[ -n "$review_memory" ]]; then
            review_prompt+="
## Known Issues from Previous Reviews
These anti-patterns and issues have been found in past reviews of this codebase. Flag them if they recur:
${review_memory}
"
        fi
    fi

    # Inject project conventions if CLAUDE.md exists
    local claudemd="$PROJECT_ROOT/.claude/CLAUDE.md"
    if [[ -f "$claudemd" ]]; then
        local conventions
        conventions=$(grep -A2 'Common Pitfalls\|Shell Standards\|Bash 3.2' "$claudemd" 2>/dev/null | head -20 || true)
        if [[ -n "$conventions" ]]; then
            review_prompt+="
## Project Conventions
${conventions}
"
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

    review_prompt+="
## Diff to Review
$(cat "$diff_file")"

    # Build claude args — add --dangerously-skip-permissions in CI
    local review_args=(--print --model "$review_model" --max-turns 25)
    if [[ "${CI_MODE:-false}" == "true" ]]; then
        review_args+=(--dangerously-skip-permissions)
    fi

    claude "${review_args[@]}" "$review_prompt" < /dev/null > "$review_file" 2>"${ARTIFACTS_DIR}/.claude-tokens-review.log" || true
    parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-review.log"

    if [[ ! -s "$review_file" ]]; then
        warn "Review produced no output — check ${ARTIFACTS_DIR}/.claude-tokens-review.log for errors"
        return 0
    fi

    # Extract severity counts — try JSON structure first, then grep fallback
    local critical_count=0 bug_count=0 warning_count=0

    # Check if review output is structured JSON (e.g. from structured review tools)
    local json_parsed=false
    if head -1 "$review_file" 2>/dev/null | grep -q '^{' 2>/dev/null; then
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
    # Block pipeline on critical/security issues unless compound_quality handles them
    local security_count
    security_count=$(grep -ciE '\*\*\[?Security\]?\*\*' "$review_file" 2>/dev/null || true)
    security_count="${security_count:-0}"

    local blocking_issues=$((critical_count + security_count))

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

    log_stage "review" "AI review complete ($total_issues issues: $critical_count critical, $bug_count bugs, $warning_count suggestions)"
}

stage_pr() {
    CURRENT_STAGE_ID="pr"
    local plan_file="$ARTIFACTS_DIR/plan.md"
    local test_log="$ARTIFACTS_DIR/test-results.log"
    local review_file="$ARTIFACTS_DIR/review.md"

    # ── PR Hygiene Checks (informational) ──
    local hygiene_commit_count
    hygiene_commit_count=$(git log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null | wc -l | xargs)
    hygiene_commit_count="${hygiene_commit_count:-0}"

    if [[ "$hygiene_commit_count" -gt 20 ]]; then
        warn "PR has ${hygiene_commit_count} commits — consider squashing before merge"
    fi

    # Check for WIP/fixup/squash commits (expanded patterns)
    local wip_commits
    wip_commits=$(git log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null | grep -ciE '^[0-9a-f]+ (WIP|fixup!|squash!|TODO|HACK|TEMP|BROKEN|wip[:-]|temp[:-]|broken[:-]|do not merge)' || true)
    wip_commits="${wip_commits:-0}"
    if [[ "$wip_commits" -gt 0 ]]; then
        warn "Branch has ${wip_commits} WIP/fixup/squash/temp commit(s) — consider cleaning up"
    fi

    # ── PR Quality Gate: reject PRs with no real code changes ──
    local real_files
    real_files=$(git diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null | grep -v '^\.claude/' | grep -v '^\.github/' || true)
    if [[ -z "$real_files" ]]; then
        error "No real code changes detected — only pipeline artifacts (.claude/ logs)."
        error "The build agent did not produce meaningful changes. Skipping PR creation."
        emit_event "pr.rejected" "issue=${ISSUE_NUMBER:-0}" "reason=no_real_changes"
        # Mark issue so auto-retry knows not to retry empty builds
        if [[ -n "${ISSUE_NUMBER:-}" && "${ISSUE_NUMBER:-0}" != "0" ]]; then
            gh issue comment "$ISSUE_NUMBER" --body "<!-- SHIPWRIGHT-NO-CHANGES: true -->" 2>/dev/null || true
        fi
        return 1
    fi
    local real_file_count
    real_file_count=$(echo "$real_files" | wc -l | xargs)
    info "PR quality gate: ${real_file_count} real file(s) changed"

    # Commit any uncommitted changes left by the build agent
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        info "Committing remaining uncommitted changes..."
        git add -A 2>/dev/null || true
        git commit -m "chore: pipeline cleanup — commit remaining build changes" --no-verify 2>/dev/null || true
    fi

    # Auto-rebase onto latest base branch before PR
    auto_rebase || {
        warn "Rebase/merge failed — pushing as-is"
    }

    # Push branch
    info "Pushing branch: $GIT_BRANCH"
    git push -u origin "$GIT_BRANCH" --force-with-lease 2>/dev/null || {
        # Retry with regular push if force-with-lease fails (first push)
        git push -u origin "$GIT_BRANCH" 2>/dev/null || {
            error "Failed to push branch"
            return 1
        }
    }

    # ── Developer Simulation (pre-PR review) ──
    local simulation_summary=""
    if type simulation_review >/dev/null 2>&1; then
        local sim_enabled
        sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
        # Also check daemon-config
        local daemon_cfg=".claude/daemon-config.json"
        if [[ "$sim_enabled" != "true" && -f "$daemon_cfg" ]]; then
            sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
        fi
        if [[ "$sim_enabled" == "true" ]]; then
            info "Running developer simulation review..."
            local diff_for_sim
            diff_for_sim=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
            if [[ -n "$diff_for_sim" ]]; then
                local sim_result
                sim_result=$(simulation_review "$diff_for_sim" "${GOAL:-}" 2>/dev/null || echo "")
                if [[ -n "$sim_result" && "$sim_result" != *'"error"'* ]]; then
                    echo "$sim_result" > "$ARTIFACTS_DIR/simulation-review.json"
                    local sim_count
                    sim_count=$(echo "$sim_result" | jq 'length' 2>/dev/null || echo "0")
                    simulation_summary="**Developer simulation:** ${sim_count} reviewer concerns pre-addressed"
                    success "Simulation complete: ${sim_count} concerns found and addressed"
                    emit_event "simulation.complete" "issue=${ISSUE_NUMBER:-0}" "concerns=${sim_count}"
                else
                    info "Simulation returned no actionable concerns"
                fi
            fi
        fi
    fi

    # ── Architecture Validation (pre-PR check) ──
    local arch_summary=""
    if type architecture_validate_changes >/dev/null 2>&1; then
        local arch_enabled
        arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
        local daemon_cfg=".claude/daemon-config.json"
        if [[ "$arch_enabled" != "true" && -f "$daemon_cfg" ]]; then
            arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
        fi
        if [[ "$arch_enabled" == "true" ]]; then
            info "Validating architecture..."
            local diff_for_arch
            diff_for_arch=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
            if [[ -n "$diff_for_arch" ]]; then
                local arch_result
                arch_result=$(architecture_validate_changes "$diff_for_arch" "" 2>/dev/null || echo "")
                if [[ -n "$arch_result" && "$arch_result" != *'"error"'* ]]; then
                    echo "$arch_result" > "$ARTIFACTS_DIR/architecture-validation.json"
                    local violation_count
                    violation_count=$(echo "$arch_result" | jq '[.violations[]? | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")
                    arch_summary="**Architecture validation:** ${violation_count} violations"
                    if [[ "$violation_count" -gt 0 ]]; then
                        warn "Architecture: ${violation_count} high/critical violations found"
                    else
                        success "Architecture validation passed"
                    fi
                    emit_event "architecture.validated" "issue=${ISSUE_NUMBER:-0}" "violations=${violation_count}"
                else
                    info "Architecture validation returned no results"
                fi
            fi
        fi
    fi

    # Pre-PR diff gate — verify meaningful code changes exist (not just bookkeeping)
    local real_changes
    real_changes=$(git diff --name-only "origin/${BASE_BRANCH:-main}...HEAD" \
        -- . ':!.claude/loop-state.md' ':!.claude/pipeline-state.md' \
        ':!.claude/pipeline-artifacts/*' ':!**/progress.md' \
        ':!**/error-summary.json' 2>/dev/null | wc -l | xargs || echo "0")
    if [[ "${real_changes:-0}" -eq 0 ]]; then
        error "No meaningful code changes detected — only bookkeeping files modified"
        error "Refusing to create PR with zero real changes"
        return 1
    fi
    info "Pre-PR diff check: ${real_changes} real files changed"

    # Build PR title — prefer GOAL over plan file first line
    # (plan file first line often contains Claude analysis text, not a clean title)
    local pr_title=""
    if [[ -n "${GOAL:-}" ]]; then
        pr_title=$(echo "$GOAL" | cut -c1-70)
    fi
    if [[ -z "$pr_title" ]] && [[ -s "$plan_file" ]]; then
        pr_title=$(head -1 "$plan_file" 2>/dev/null | sed 's/^#* *//' | cut -c1-70)
    fi
    [[ -z "$pr_title" ]] && pr_title="Pipeline changes for issue ${ISSUE_NUMBER:-unknown}"

    # Sanitize: reject PR titles that look like error messages
    if echo "$pr_title" | grep -qiE 'Invalid API|API key|authentication_error|rate_limit|CLI error|no useful output'; then
        warn "PR title looks like an error message: $pr_title"
        pr_title="Pipeline changes for issue ${ISSUE_NUMBER:-unknown}"
    fi

    # Build comprehensive PR body
    local plan_summary=""
    if [[ -s "$plan_file" ]]; then
        plan_summary=$(head -20 "$plan_file" 2>/dev/null | tail -15)
    fi

    local test_summary=""
    if [[ -s "$test_log" ]]; then
        test_summary=$(tail -10 "$test_log" | sed 's/\x1b\[[0-9;]*m//g')
    fi

    local review_summary=""
    if [[ -s "$review_file" ]]; then
        local total_issues=0
        # Try JSON structured output first
        if head -1 "$review_file" 2>/dev/null | grep -q '^{' 2>/dev/null; then
            total_issues=$(jq -r '.issues | length' "$review_file" 2>/dev/null || echo "0")
        fi
        # Grep fallback for markdown
        if [[ "${total_issues:-0}" -eq 0 ]]; then
            total_issues=$(grep -ciE '\*\*\[?(Critical|Bug|Security|Warning|Suggestion)\]?\*\*' "$review_file" 2>/dev/null || true)
            total_issues="${total_issues:-0}"
        fi
        review_summary="**Code review:** $total_issues issues found"
    fi

    local closes_line=""
    [[ -n "${GITHUB_ISSUE:-}" ]] && closes_line="Closes ${GITHUB_ISSUE}"

    local diff_stats
    diff_stats=$(git diff --stat "${BASE_BRANCH}...${GIT_BRANCH}" 2>/dev/null | tail -1 || echo "")

    local commit_count
    commit_count=$(git log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null | wc -l | xargs)

    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    local pr_body
    pr_body="$(cat <<EOF
## Summary
${plan_summary:-$GOAL}

## Changes
${diff_stats}
${commit_count} commit(s) via \`shipwright pipeline\` (${PIPELINE_NAME})

## Test Results
\`\`\`
${test_summary:-No test output}
\`\`\`

${review_summary}
${simulation_summary}
${arch_summary}

${closes_line}

---

| Metric | Value |
|--------|-------|
| Pipeline | \`${PIPELINE_NAME}\` |
| Duration | ${total_dur:-—} |
| Model | ${MODEL:-opus} |
| Agents | ${AGENTS:-1} |

Generated by \`shipwright pipeline\`
EOF
)"

    # Verify required evidence before PR (merge policy enforcement)
    local risk_tier
    risk_tier="low"
    if [[ -f "$REPO_DIR/config/policy.json" ]]; then
        local changed_files
        changed_files=$(git diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
        if [[ -n "$changed_files" ]]; then
            local policy_file="$REPO_DIR/config/policy.json"
            check_tier_match() {
                local tier="$1"
                local patterns
                patterns=$(jq -r ".riskTierRules.${tier}[]? // empty" "$policy_file" 2>/dev/null)
                [[ -z "$patterns" ]] && return 1
                while IFS= read -r pattern; do
                    [[ -z "$pattern" ]] && continue
                    local regex
                    regex=$(echo "$pattern" | sed 's/\./\\./g; s/\*\*/DOUBLESTAR/g; s/\*/[^\/]*/g; s/DOUBLESTAR/.*/g')
                    while IFS= read -r file; do
                        [[ -z "$file" ]] && continue
                        if echo "$file" | grep -qE "^${regex}$"; then
                            return 0
                        fi
                    done <<< "$changed_files"
                done <<< "$patterns"
                return 1
            }
            check_tier_match "critical" && risk_tier="critical"
            check_tier_match "high" && [[ "$risk_tier" != "critical" ]] && risk_tier="high"
            check_tier_match "medium" && [[ "$risk_tier" != "critical" && "$risk_tier" != "high" ]] && risk_tier="medium"
        fi
    fi

    local required_evidence
    required_evidence=$(jq -r ".mergePolicy.\"$risk_tier\".requiredEvidence // [] | .[]" "$REPO_DIR/config/policy.json" 2>/dev/null)

    if [[ -n "$required_evidence" ]]; then
        local evidence_dir="$REPO_DIR/.claude/evidence"
        local missing_evidence=()
        while IFS= read -r etype; do
            [[ -z "$etype" ]] && continue
            local has_evidence=false
            for f in "$evidence_dir"/*"$etype"*; do
                [[ -f "$f" ]] && has_evidence=true && break
            done
            [[ "$has_evidence" != "true" ]] && missing_evidence+=("$etype")
        done <<< "$required_evidence"

        if [[ ${#missing_evidence[@]} -gt 0 ]]; then
            warn "Missing required evidence for $risk_tier tier: ${missing_evidence[*]}"
            emit_event "evidence.missing" "{\"tier\":\"$risk_tier\",\"missing\":\"${missing_evidence[*]}\"}"
            # Collect missing evidence
            if [[ -x "$SCRIPT_DIR/sw-evidence.sh" ]]; then
                for etype in "${missing_evidence[@]}"; do
                    (cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-evidence.sh" capture "$etype" 2>/dev/null) || warn "Failed to collect $etype evidence"
                done
            fi
        fi
    fi

    # Build gh pr create args
    local pr_args=(--title "$pr_title" --body "$pr_body" --base "$BASE_BRANCH")

    # Propagate labels from issue + CLI
    local all_labels="${LABELS}"
    if [[ -n "$ISSUE_LABELS" ]]; then
        if [[ -n "$all_labels" ]]; then
            all_labels="${all_labels},${ISSUE_LABELS}"
        else
            all_labels="$ISSUE_LABELS"
        fi
    fi
    if [[ -n "$all_labels" ]]; then
        pr_args+=(--label "$all_labels")
    fi

    # Auto-detect or use provided reviewers
    local reviewers="${REVIEWERS}"
    if [[ -z "$reviewers" ]]; then
        reviewers=$(detect_reviewers)
    fi
    if [[ -n "$reviewers" ]]; then
        pr_args+=(--reviewer "$reviewers")
        info "Reviewers: ${DIM}$reviewers${RESET}"
    fi

    # Propagate milestone
    if [[ -n "$ISSUE_MILESTONE" ]]; then
        pr_args+=(--milestone "$ISSUE_MILESTONE")
        info "Milestone: ${DIM}$ISSUE_MILESTONE${RESET}"
    fi

    # Check for existing open PR on this branch to avoid duplicates (issue #12)
    local pr_url=""
    local existing_pr
    existing_pr=$(gh pr list --head "$GIT_BRANCH" --state open --json number,url --jq '.[0]' 2>/dev/null || echo "")
    if [[ -n "$existing_pr" && "$existing_pr" != "null" ]]; then
        local existing_pr_number existing_pr_url
        existing_pr_number=$(echo "$existing_pr" | jq -r '.number' 2>/dev/null || echo "")
        existing_pr_url=$(echo "$existing_pr" | jq -r '.url' 2>/dev/null || echo "")
        info "Updating existing PR #$existing_pr_number instead of creating duplicate"
        gh pr edit "$existing_pr_number" --title "$pr_title" --body "$pr_body" 2>/dev/null || true
        pr_url="$existing_pr_url"
    else
        info "Creating PR..."
        local pr_stderr pr_exit=0
        pr_url=$(gh pr create "${pr_args[@]}" 2>/tmp/shipwright-pr-stderr.txt) || pr_exit=$?
        pr_stderr=$(cat /tmp/shipwright-pr-stderr.txt 2>/dev/null || true)
        rm -f /tmp/shipwright-pr-stderr.txt

        # gh pr create may return non-zero for reviewer issues but still create the PR
        if [[ "$pr_exit" -ne 0 ]]; then
            if [[ "$pr_url" == *"github.com"* ]]; then
                # PR was created but something non-fatal failed (e.g., reviewer not found)
                warn "PR created with warnings: ${pr_stderr:-unknown}"
            else
                error "PR creation failed: ${pr_stderr:-$pr_url}"
                return 1
            fi
        fi
    fi

    success "PR created: ${BOLD}$pr_url${RESET}"
    echo "$pr_url" > "$ARTIFACTS_DIR/pr-url.txt"

    # Extract PR number
    PR_NUMBER=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)

    # ── Intelligent Reviewer Selection (GraphQL-enhanced) ──
    if [[ "${NO_GITHUB:-false}" != "true" && -n "$PR_NUMBER" && -z "$reviewers" ]]; then
        local reviewer_assigned=false

        # Try CODEOWNERS-based routing via GraphQL API
        if type gh_codeowners >/dev/null 2>&1 && [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            local codeowners_json
            codeowners_json=$(gh_codeowners "$REPO_OWNER" "$REPO_NAME" 2>/dev/null || echo "[]")
            if [[ "$codeowners_json" != "[]" && -n "$codeowners_json" ]]; then
                local changed_files
                changed_files=$(git diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
                if [[ -n "$changed_files" ]]; then
                    local co_reviewers
                    co_reviewers=$(echo "$codeowners_json" | jq -r '.[].owners[]' 2>/dev/null | sort -u | head -3 || true)
                    if [[ -n "$co_reviewers" ]]; then
                        local rev
                        while IFS= read -r rev; do
                            rev="${rev#@}"
                            [[ -n "$rev" ]] && gh pr edit "$PR_NUMBER" --add-reviewer "$rev" 2>/dev/null || true
                        done <<< "$co_reviewers"
                        info "Requested review from CODEOWNERS: $(echo "$co_reviewers" | tr '\n' ',' | sed 's/,$//')"
                        reviewer_assigned=true
                    fi
                fi
            fi
        fi

        # Fallback: contributor-based routing via GraphQL API
        if [[ "$reviewer_assigned" != "true" ]] && type gh_contributors >/dev/null 2>&1 && [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            local contributors_json
            contributors_json=$(gh_contributors "$REPO_OWNER" "$REPO_NAME" 2>/dev/null || echo "[]")
            local top_contributor
            top_contributor=$(echo "$contributors_json" | jq -r '.[0].login // ""' 2>/dev/null || echo "")
            local current_user
            current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
            if [[ -n "$top_contributor" && "$top_contributor" != "$current_user" ]]; then
                gh pr edit "$PR_NUMBER" --add-reviewer "$top_contributor" 2>/dev/null || true
                info "Requested review from top contributor: $top_contributor"
                reviewer_assigned=true
            fi
        fi

        # Final fallback: auto-approve if no reviewers assigned
        if [[ "$reviewer_assigned" != "true" ]]; then
            gh pr review "$PR_NUMBER" --approve 2>/dev/null || warn "Could not auto-approve PR"
        fi
    fi

    # Update issue with PR link
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_remove_label "$ISSUE_NUMBER" "pipeline/in-progress"
        gh_add_labels "$ISSUE_NUMBER" "pipeline/pr-created"
        gh_comment_issue "$ISSUE_NUMBER" "🎉 **PR created:** ${pr_url}

Pipeline duration so far: ${total_dur:-unknown}"

        # Notify tracker of review/PR creation
        "$SCRIPT_DIR/sw-tracker.sh" notify "review" "$ISSUE_NUMBER" "$pr_url" 2>/dev/null || true
    fi

    # Wait for CI if configured
    local wait_ci
    wait_ci=$(jq -r --arg id "pr" '(.stages[] | select(.id == $id) | .config.wait_ci) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    if [[ "$wait_ci" == "true" ]]; then
        info "Waiting for CI checks..."
        gh pr checks --watch 2>/dev/null || warn "CI checks did not all pass"
    fi

    log_stage "pr" "PR created: $pr_url (${reviewers:+reviewers: $reviewers})"
}

stage_merge() {
    CURRENT_STAGE_ID="merge"

    if [[ "$NO_GITHUB" == "true" ]]; then
        info "Merge stage skipped (--no-github)"
        return 0
    fi

    # ── Oversight gate: merge block on verdict (diff + review criticals + goal) ──
    if [[ -x "$SCRIPT_DIR/sw-oversight.sh" ]] && [[ "${SKIP_GATES:-false}" != "true" ]]; then
        local merge_diff_file="${ARTIFACTS_DIR}/review-diff.patch"
        local merge_review_file="${ARTIFACTS_DIR}/review.md"
        if [[ ! -s "$merge_diff_file" ]]; then
            git diff "${BASE_BRANCH}...${GIT_BRANCH}" > "$merge_diff_file" 2>/dev/null || \
                git diff HEAD~5 > "$merge_diff_file" 2>/dev/null || true
        fi
        if [[ -s "$merge_diff_file" ]]; then
            local _merge_critical _merge_sec _merge_blocking _merge_reject
            _merge_critical=$(grep -ciE '\*\*\[?Critical\]?\*\*' "$merge_review_file" 2>/dev/null || echo "0")
            _merge_sec=$(grep -ciE '\*\*\[?Security\]?\*\*' "$merge_review_file" 2>/dev/null || echo "0")
            _merge_blocking=$((${_merge_critical:-0} + ${_merge_sec:-0}))
            [[ "$_merge_blocking" -gt 0 ]] && _merge_reject="Review found ${_merge_blocking} critical/security issue(s)"
            if ! bash "$SCRIPT_DIR/sw-oversight.sh" gate --diff "$merge_diff_file" --description "${GOAL:-Pipeline merge}" --reject-if "${_merge_reject:-}" >/dev/null 2>&1; then
                error "Oversight gate rejected — blocking merge"
                emit_event "merge.oversight_blocked" "issue=${ISSUE_NUMBER:-0}"
                log_stage "merge" "BLOCKED: oversight gate rejected"
                return 1
            fi
        fi
    fi

    # ── Approval gates: block if merge requires approval and pending for this issue ──
    local ag_file="${HOME}/.shipwright/approval-gates.json"
    if [[ -f "$ag_file" ]] && [[ "${SKIP_GATES:-false}" != "true" ]]; then
        local ag_enabled ag_stages ag_pending_merge ag_issue_num
        ag_enabled=$(jq -r '.enabled // false' "$ag_file" 2>/dev/null || echo "false")
        ag_stages=$(jq -r '.stages // [] | if type == "array" then .[] else empty end' "$ag_file" 2>/dev/null || true)
        ag_issue_num=$(echo "${ISSUE_NUMBER:-0}" | awk '{print $1+0}')
        if [[ "$ag_enabled" == "true" ]] && echo "$ag_stages" | grep -qx "merge" 2>/dev/null; then
            local ha_file="${ARTIFACTS_DIR}/human-approval.txt"
            local ha_approved="false"
            if [[ -f "$ha_file" ]]; then
                ha_approved=$(jq -r --arg stage "merge" 'select(.stage == $stage) | .approved // false' "$ha_file" 2>/dev/null || echo "false")
            fi
            if [[ "$ha_approved" != "true" ]]; then
                ag_pending_merge=$(jq -r --argjson issue "$ag_issue_num" --arg stage "merge" \
                    '[.pending[]? | select(.issue == $issue and .stage == $stage)] | length' "$ag_file" 2>/dev/null || echo "0")
                if [[ "${ag_pending_merge:-0}" -eq 0 ]]; then
                    local req_at tmp_ag
                    req_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)
                    tmp_ag=$(mktemp "${HOME}/.shipwright/approval-gates.json.XXXXXX" 2>/dev/null || mktemp)
                    jq --argjson issue "$ag_issue_num" --arg stage "merge" --arg requested "${req_at}" \
                        '.pending += [{"issue": $issue, "stage": $stage, "requested_at": $requested}]' "$ag_file" > "$tmp_ag" 2>/dev/null && mv "$tmp_ag" "$ag_file" || rm -f "$tmp_ag"
                fi
                info "Merge requires approval — awaiting human approval via dashboard"
                emit_event "merge.approval_pending" "issue=${ISSUE_NUMBER:-0}"
                log_stage "merge" "BLOCKED: approval gate pending"
                return 1
            fi
        fi
    fi

    # ── Branch Protection Check ──
    if type gh_branch_protection >/dev/null 2>&1 && [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
        local protection_json
        protection_json=$(gh_branch_protection "$REPO_OWNER" "$REPO_NAME" "${BASE_BRANCH:-main}" 2>/dev/null || echo '{"protected": false}')
        local is_protected
        is_protected=$(echo "$protection_json" | jq -r '.protected // false' 2>/dev/null || echo "false")
        if [[ "$is_protected" == "true" ]]; then
            local required_reviews
            required_reviews=$(echo "$protection_json" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null || echo "0")
            local required_checks
            required_checks=$(echo "$protection_json" | jq -r '[.required_status_checks.contexts // [] | .[]] | length' 2>/dev/null || echo "0")

            info "Branch protection: ${required_reviews} required review(s), ${required_checks} required check(s)"

            if [[ "$required_reviews" -gt 0 ]]; then
                # Check if PR has enough approvals
                local prot_pr_number
                prot_pr_number=$(gh pr list --head "$GIT_BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")
                if [[ -n "$prot_pr_number" ]]; then
                    local approvals
                    approvals=$(gh pr view "$prot_pr_number" --json reviews --jq '[.reviews[] | select(.state == "APPROVED")] | length' 2>/dev/null || echo "0")
                    if [[ "$approvals" -lt "$required_reviews" ]]; then
                        warn "PR has $approvals approval(s), needs $required_reviews — skipping auto-merge"
                        info "PR is ready for manual merge after required reviews"
                        emit_event "merge.blocked" "issue=${ISSUE_NUMBER:-0}" "reason=insufficient_reviews" "have=$approvals" "need=$required_reviews"
                        return 0
                    fi
                fi
            fi
        fi
    fi

    local merge_method wait_ci_timeout auto_delete_branch auto_merge auto_approve merge_strategy
    merge_method=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.merge_method) // "squash"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$merge_method" || "$merge_method" == "null" ]] && merge_method="squash"
    wait_ci_timeout=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.wait_ci_timeout_s) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$wait_ci_timeout" || "$wait_ci_timeout" == "null" ]] && wait_ci_timeout=0

    # Adaptive CI timeout: 90th percentile of historical times × 1.5 safety margin
    if [[ "$wait_ci_timeout" -eq 0 ]] 2>/dev/null; then
        local repo_hash_ci
        repo_hash_ci=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
        local ci_times_file="${HOME}/.shipwright/baselines/${repo_hash_ci}/ci-times.json"
        if [[ -f "$ci_times_file" ]]; then
            local p90_time
            p90_time=$(jq '
                .times | sort |
                (length * 0.9 | floor) as $idx |
                .[$idx] // 600
            ' "$ci_times_file" 2>/dev/null || echo "0")
            if [[ -n "$p90_time" ]] && awk -v t="$p90_time" 'BEGIN{exit !(t > 0)}' 2>/dev/null; then
                # 1.5x safety margin, clamped to [120, 1800]
                wait_ci_timeout=$(awk -v p90="$p90_time" 'BEGIN{
                    t = p90 * 1.5;
                    if (t < 120) t = 120;
                    if (t > 1800) t = 1800;
                    printf "%d", t
                }')
            fi
        fi
        # Default fallback if no history
        [[ "$wait_ci_timeout" -eq 0 ]] && wait_ci_timeout=600
    fi
    auto_delete_branch=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.auto_delete_branch) // "true"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_delete_branch" || "$auto_delete_branch" == "null" ]] && auto_delete_branch="true"
    auto_merge=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.auto_merge) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_merge" || "$auto_merge" == "null" ]] && auto_merge="false"
    auto_approve=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.auto_approve) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_approve" || "$auto_approve" == "null" ]] && auto_approve="false"
    merge_strategy=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.merge_strategy) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$merge_strategy" || "$merge_strategy" == "null" ]] && merge_strategy=""
    # merge_strategy overrides merge_method if set (squash/merge/rebase)
    if [[ -n "$merge_strategy" ]]; then
        merge_method="$merge_strategy"
    fi

    # Find PR for current branch
    local pr_number
    pr_number=$(gh pr list --head "$GIT_BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")

    if [[ -z "$pr_number" ]]; then
        warn "No PR found for branch $GIT_BRANCH — skipping merge"
        return 0
    fi

    info "Found PR #${pr_number} for branch ${GIT_BRANCH}"

    # Wait for CI checks to pass
    info "Waiting for CI checks (timeout: ${wait_ci_timeout}s)..."
    local elapsed=0
    local check_interval=15

    while [[ "$elapsed" -lt "$wait_ci_timeout" ]]; do
        local check_status
        check_status=$(gh pr checks "$pr_number" --json 'bucket,name' --jq '[.[] | .bucket] | unique | sort' 2>/dev/null || echo '["pending"]')

        # If all checks passed (only "pass" in buckets)
        if echo "$check_status" | jq -e '. == ["pass"]' >/dev/null 2>&1; then
            success "All CI checks passed"
            break
        fi

        # If any check failed
        if echo "$check_status" | jq -e 'any(. == "fail")' >/dev/null 2>&1; then
            error "CI checks failed — aborting merge"
            return 1
        fi

        sleep "$check_interval"
        elapsed=$((elapsed + check_interval))
    done

    # Record CI wait time for adaptive timeout calculation
    if [[ "$elapsed" -gt 0 ]]; then
        local repo_hash_ci_rec
        repo_hash_ci_rec=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
        local ci_times_dir="${HOME}/.shipwright/baselines/${repo_hash_ci_rec}"
        local ci_times_rec_file="${ci_times_dir}/ci-times.json"
        mkdir -p "$ci_times_dir"
        local ci_history="[]"
        if [[ -f "$ci_times_rec_file" ]]; then
            ci_history=$(jq '.times // []' "$ci_times_rec_file" 2>/dev/null || echo "[]")
        fi
        local updated_ci
        updated_ci=$(echo "$ci_history" | jq --arg t "$elapsed" '. + [($t | tonumber)] | .[-20:]' 2>/dev/null || echo "[$elapsed]")
        local tmp_ci
        tmp_ci=$(mktemp "${ci_times_dir}/ci-times.json.XXXXXX")
        jq -n --argjson times "$updated_ci" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{times: $times, updated: $updated}' > "$tmp_ci" 2>/dev/null
        mv "$tmp_ci" "$ci_times_rec_file" 2>/dev/null || true
    fi

    if [[ "$elapsed" -ge "$wait_ci_timeout" ]]; then
        warn "CI check timeout (${wait_ci_timeout}s) — proceeding with merge anyway"
    fi

    # Auto-approve if configured (for branch protection requiring reviews)
    if [[ "$auto_approve" == "true" ]]; then
        info "Auto-approving PR #${pr_number}..."
        gh pr review "$pr_number" --approve 2>/dev/null || warn "Auto-approve failed (may need different permissions)"
    fi

    # Merge the PR
    if [[ "$auto_merge" == "true" ]]; then
        info "Enabling auto-merge for PR #${pr_number} (strategy: ${merge_method})..."
        local auto_merge_args=("pr" "merge" "$pr_number" "--auto" "--${merge_method}")
        if [[ "$auto_delete_branch" == "true" ]]; then
            auto_merge_args+=("--delete-branch")
        fi

        if gh "${auto_merge_args[@]}" 2>/dev/null; then
            success "Auto-merge enabled for PR #${pr_number} (strategy: ${merge_method})"
            emit_event "merge.auto_enabled" \
                "issue=${ISSUE_NUMBER:-0}" \
                "pr=$pr_number" \
                "strategy=$merge_method"
        else
            warn "Auto-merge not available — falling back to direct merge"
            # Fall through to direct merge below
            auto_merge="false"
        fi
    fi

    if [[ "$auto_merge" != "true" ]]; then
        info "Merging PR #${pr_number} (method: ${merge_method})..."
        local merge_args=("pr" "merge" "$pr_number" "--${merge_method}")
        if [[ "$auto_delete_branch" == "true" ]]; then
            merge_args+=("--delete-branch")
        fi

        if gh "${merge_args[@]}" 2>/dev/null; then
            success "PR #${pr_number} merged successfully"
        else
            error "Failed to merge PR #${pr_number}"
            return 1
        fi
    fi

    log_stage "merge" "PR #${pr_number} merged (strategy: ${merge_method}, auto_merge: ${auto_merge})"
}

stage_deploy() {
    CURRENT_STAGE_ID="deploy"
    local staging_cmd
    staging_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.staging_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$staging_cmd" == "null" ]] && staging_cmd=""

    local prod_cmd
    prod_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.production_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$prod_cmd" == "null" ]] && prod_cmd=""

    local rollback_cmd
    rollback_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.rollback_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$rollback_cmd" == "null" ]] && rollback_cmd=""

    if [[ -z "$staging_cmd" && -z "$prod_cmd" ]]; then
        warn "No deploy commands configured — skipping"
        return 0
    fi

    # Create GitHub deployment tracking
    local gh_deploy_env="production"
    [[ -n "$staging_cmd" && -z "$prod_cmd" ]] && gh_deploy_env="staging"
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_start >/dev/null 2>&1; then
        if [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            gh_deploy_pipeline_start "$REPO_OWNER" "$REPO_NAME" "${GIT_BRANCH:-HEAD}" "$gh_deploy_env" 2>/dev/null || true
            info "GitHub Deployment: tracking as $gh_deploy_env"
        fi
    fi

    # ── Pre-deploy gates ──
    local pre_deploy_ci
    pre_deploy_ci=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.pre_deploy_ci_status) // "true"' "$PIPELINE_CONFIG" 2>/dev/null) || true

    if [[ "${pre_deploy_ci:-true}" == "true" && "${NO_GITHUB:-false}" != "true" && -n "${REPO_OWNER:-}" && -n "${REPO_NAME:-}" ]]; then
        info "Pre-deploy gate: checking CI status..."
        local ci_failures
        ci_failures=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/commits/${GIT_BRANCH:-HEAD}/check-runs" \
            --jq '[.check_runs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped")] | length' 2>/dev/null || echo "0")
        if [[ "${ci_failures:-0}" -gt 0 ]]; then
            error "Pre-deploy gate FAILED: ${ci_failures} CI check(s) not passing"
            [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Pre-deploy gate: ${ci_failures} CI checks failing" 2>/dev/null || true
            return 1
        fi
        success "Pre-deploy gate: all CI checks passing"
    fi

    local pre_deploy_min_cov
    pre_deploy_min_cov=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.pre_deploy_min_coverage) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    if [[ -n "${pre_deploy_min_cov:-}" && "${pre_deploy_min_cov}" != "null" && -f "$ARTIFACTS_DIR/test-coverage.json" ]]; then
        local actual_cov
        actual_cov=$(jq -r '.coverage_pct // 0' "$ARTIFACTS_DIR/test-coverage.json" 2>/dev/null || echo "0")
        if [[ "${actual_cov:-0}" -lt "$pre_deploy_min_cov" ]]; then
            error "Pre-deploy gate FAILED: coverage ${actual_cov}% < required ${pre_deploy_min_cov}%"
            [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Pre-deploy gate: coverage ${actual_cov}% below minimum ${pre_deploy_min_cov}%" 2>/dev/null || true
            return 1
        fi
        success "Pre-deploy gate: coverage ${actual_cov}% >= ${pre_deploy_min_cov}%"
    fi

    # Post deploy start to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "Deploy started"
    fi

    # ── Deploy strategy ──
    local deploy_strategy
    deploy_strategy=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.deploy_strategy) // "direct"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$deploy_strategy" == "null" ]] && deploy_strategy="direct"

    local canary_cmd promote_cmd switch_cmd health_url deploy_log
    canary_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.canary_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$canary_cmd" == "null" ]] && canary_cmd=""
    promote_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.promote_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$promote_cmd" == "null" ]] && promote_cmd=""
    switch_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.switch_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$switch_cmd" == "null" ]] && switch_cmd=""
    health_url=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.health_url) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$health_url" == "null" ]] && health_url=""
    deploy_log="$ARTIFACTS_DIR/deploy.log"

    case "$deploy_strategy" in
        canary)
            info "Canary deployment strategy..."
            if [[ -z "$canary_cmd" ]]; then
                warn "No canary_cmd configured — falling back to direct"
                deploy_strategy="direct"
            else
                info "Deploying canary..."
                bash -c "$canary_cmd" >> "$deploy_log" 2>&1 || { error "Canary deploy failed"; return 1; }

                if [[ -n "$health_url" ]]; then
                    local canary_healthy=0
                    local _chk
                    for _chk in 1 2 3; do
                        sleep 10
                        local _status
                        _status=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "0")
                        if [[ "$_status" -ge 200 && "$_status" -lt 400 ]]; then
                            canary_healthy=$((canary_healthy + 1))
                        fi
                    done
                    if [[ "$canary_healthy" -lt 2 ]]; then
                        error "Canary health check failed ($canary_healthy/3 passed) — rolling back"
                        [[ -n "$rollback_cmd" ]] && bash -c "$rollback_cmd" 2>/dev/null || true
                        return 1
                    fi
                    success "Canary healthy ($canary_healthy/3 checks passed)"
                fi

                info "Promoting canary to full deployment..."
                if [[ -n "$promote_cmd" ]]; then
                    bash -c "$promote_cmd" >> "$deploy_log" 2>&1 || { error "Promote failed"; return 1; }
                fi
                success "Canary promoted"
            fi
            ;;
        blue-green)
            info "Blue-green deployment strategy..."
            if [[ -z "$staging_cmd" || -z "$switch_cmd" ]]; then
                warn "Blue-green requires staging_cmd + switch_cmd — falling back to direct"
                deploy_strategy="direct"
            else
                info "Deploying to inactive environment..."
                bash -c "$staging_cmd" >> "$deploy_log" 2>&1 || { error "Blue-green staging failed"; return 1; }

                if [[ -n "$health_url" ]]; then
                    local bg_healthy=0
                    local _chk
                    for _chk in 1 2 3; do
                        sleep 5
                        local _status
                        _status=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "0")
                        [[ "$_status" -ge 200 && "$_status" -lt 400 ]] && bg_healthy=$((bg_healthy + 1))
                    done
                    if [[ "$bg_healthy" -lt 2 ]]; then
                        error "Blue-green health check failed — not switching"
                        return 1
                    fi
                fi

                info "Switching traffic..."
                bash -c "$switch_cmd" >> "$deploy_log" 2>&1 || { error "Traffic switch failed"; return 1; }
                success "Blue-green switch complete"
            fi
            ;;
    esac

    # ── Direct deployment (default or fallback) ──
    if [[ "$deploy_strategy" == "direct" ]]; then
        if [[ -n "$staging_cmd" ]]; then
            info "Deploying to staging..."
            bash -c "$staging_cmd" > "$ARTIFACTS_DIR/deploy-staging.log" 2>&1 || {
                error "Staging deploy failed"
                [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Staging deploy failed"
                # Mark GitHub deployment as failed
                if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_complete >/dev/null 2>&1; then
                    gh_deploy_pipeline_complete "$REPO_OWNER" "$REPO_NAME" "$gh_deploy_env" false "Staging deploy failed" 2>/dev/null || true
                fi
                return 1
            }
            success "Staging deploy complete"
        fi

        if [[ -n "$prod_cmd" ]]; then
            info "Deploying to production..."
            bash -c "$prod_cmd" > "$ARTIFACTS_DIR/deploy-prod.log" 2>&1 || {
                error "Production deploy failed"
                if [[ -n "$rollback_cmd" ]]; then
                    warn "Rolling back..."
                    bash -c "$rollback_cmd" 2>&1 || error "Rollback also failed!"
                fi
                [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Production deploy failed — rollback ${rollback_cmd:+attempted}"
                # Mark GitHub deployment as failed
                if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_complete >/dev/null 2>&1; then
                    gh_deploy_pipeline_complete "$REPO_OWNER" "$REPO_NAME" "$gh_deploy_env" false "Production deploy failed" 2>/dev/null || true
                fi
                return 1
            }
            success "Production deploy complete"
        fi
    fi

    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "✅ **Deploy complete**"
        gh_add_labels "$ISSUE_NUMBER" "deployed"
    fi

    # Mark GitHub deployment as successful
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_complete >/dev/null 2>&1; then
        if [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            gh_deploy_pipeline_complete "$REPO_OWNER" "$REPO_NAME" "$gh_deploy_env" true "" 2>/dev/null || true
        fi
    fi

    log_stage "deploy" "Deploy complete"
}

stage_validate() {
    CURRENT_STAGE_ID="validate"
    local smoke_cmd
    smoke_cmd=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.smoke_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$smoke_cmd" == "null" ]] && smoke_cmd=""

    local health_url
    health_url=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.health_url) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$health_url" == "null" ]] && health_url=""

    local close_issue
    close_issue=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.close_issue) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true

    # Smoke tests
    if [[ -n "$smoke_cmd" ]]; then
        info "Running smoke tests..."
        bash -c "$smoke_cmd" > "$ARTIFACTS_DIR/smoke.log" 2>&1 || {
            error "Smoke tests failed"
            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh issue create --title "Deploy validation failed: $GOAL" \
                    --label "incident" --body "Pipeline smoke tests failed after deploy.

Related issue: ${GITHUB_ISSUE}
Branch: ${GIT_BRANCH}
PR: $(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo 'unknown')" 2>/dev/null || true
            fi
            return 1
        }
        success "Smoke tests passed"
    fi

    # Health check with retry
    if [[ -n "$health_url" ]]; then
        info "Health check: $health_url"
        local attempts=0
        while [[ $attempts -lt 5 ]]; do
            if curl -sf "$health_url" >/dev/null 2>&1; then
                success "Health check passed"
                break
            fi
            attempts=$((attempts + 1))
            [[ $attempts -lt 5 ]] && { info "Retry ${attempts}/5..."; sleep 10; }
        done
        if [[ $attempts -ge 5 ]]; then
            error "Health check failed after 5 attempts"
            return 1
        fi
    fi

    # Compute total duration once for both issue close and wiki report
    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    # Close original issue with comprehensive summary
    if [[ "$close_issue" == "true" && -n "$ISSUE_NUMBER" ]]; then
        gh issue close "$ISSUE_NUMBER" --comment "## ✅ Complete — Deployed & Validated

| Metric | Value |
|--------|-------|
| Pipeline | \`${PIPELINE_NAME}\` |
| Branch | \`${GIT_BRANCH}\` |
| PR | $(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo 'N/A') |
| Duration | ${total_dur:-unknown} |

_Closed automatically by \`shipwright pipeline\`_" 2>/dev/null || true

        gh_remove_label "$ISSUE_NUMBER" "pipeline/pr-created"
        gh_add_labels "$ISSUE_NUMBER" "pipeline/complete"
        success "Issue #$ISSUE_NUMBER closed"
    fi

    # Push pipeline report to wiki
    local report="# Pipeline Report — ${GOAL}

| Metric | Value |
|--------|-------|
| Pipeline | \`${PIPELINE_NAME}\` |
| Branch | \`${GIT_BRANCH}\` |
| PR | $(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo 'N/A') |
| Duration | ${total_dur:-unknown} |
| Stages | $(echo "$STAGE_TIMINGS" | tr '|' '\n' | wc -l | xargs) completed |

## Stage Timings
$(echo "$STAGE_TIMINGS" | tr '|' '\n' | sed 's/^/- /')

## Artifacts
$(ls -1 "$ARTIFACTS_DIR" 2>/dev/null | sed 's/^/- /')

---
_Generated by \`shipwright pipeline\` at $(now_iso)_"
    gh_wiki_page "Pipeline-Report-${ISSUE_NUMBER:-inline}" "$report"

    log_stage "validate" "Validation complete"
}

stage_monitor() {
    CURRENT_STAGE_ID="monitor"

    # Read config from pipeline template
    local duration_minutes health_url error_threshold log_pattern log_cmd rollback_cmd auto_rollback
    duration_minutes=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.duration_minutes) // 5' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$duration_minutes" || "$duration_minutes" == "null" ]] && duration_minutes=5
    health_url=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.health_url) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$health_url" == "null" ]] && health_url=""
    error_threshold=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.error_threshold) // 5' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$error_threshold" || "$error_threshold" == "null" ]] && error_threshold=5

    # Adaptive monitor: use historical baselines if available
    local repo_hash
    repo_hash=$(echo "${PROJECT_ROOT:-$(pwd)}" | cksum | awk '{print $1}')
    local baseline_file="${HOME}/.shipwright/baselines/${repo_hash}/deploy-monitor.json"
    if [[ -f "$baseline_file" ]]; then
        local hist_duration hist_threshold
        hist_duration=$(jq -r '.p90_stabilization_minutes // empty' "$baseline_file" 2>/dev/null || true)
        hist_threshold=$(jq -r '.p90_error_threshold // empty' "$baseline_file" 2>/dev/null || true)
        if [[ -n "$hist_duration" && "$hist_duration" != "null" ]]; then
            duration_minutes="$hist_duration"
            info "Monitor duration: ${duration_minutes}m ${DIM}(from baseline)${RESET}"
        fi
        if [[ -n "$hist_threshold" && "$hist_threshold" != "null" ]]; then
            error_threshold="$hist_threshold"
            info "Error threshold: ${error_threshold} ${DIM}(from baseline)${RESET}"
        fi
    fi
    log_pattern=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.log_pattern) // "ERROR|FATAL|PANIC"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$log_pattern" || "$log_pattern" == "null" ]] && log_pattern="ERROR|FATAL|PANIC"
    log_cmd=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.log_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$log_cmd" == "null" ]] && log_cmd=""
    rollback_cmd=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.rollback_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$rollback_cmd" == "null" ]] && rollback_cmd=""
    auto_rollback=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.auto_rollback) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_rollback" || "$auto_rollback" == "null" ]] && auto_rollback="false"

    if [[ -z "$health_url" && -z "$log_cmd" ]]; then
        warn "No health_url or log_cmd configured — skipping monitor stage"
        log_stage "monitor" "Skipped (no monitoring configured)"
        return 0
    fi

    local report_file="$ARTIFACTS_DIR/monitor-report.md"
    local deploy_log_file="$ARTIFACTS_DIR/deploy-logs.txt"
    : > "$deploy_log_file"
    local total_errors=0
    local poll_interval=30  # seconds between polls
    local total_polls=$(( (duration_minutes * 60) / poll_interval ))
    [[ "$total_polls" -lt 1 ]] && total_polls=1

    info "Post-deploy monitoring: ${duration_minutes}m (${total_polls} polls, threshold: ${error_threshold} errors)"

    emit_event "monitor.started" \
        "issue=${ISSUE_NUMBER:-0}" \
        "duration_minutes=$duration_minutes" \
        "error_threshold=$error_threshold"

    {
        echo "# Post-Deploy Monitor Report"
        echo ""
        echo "- Duration: ${duration_minutes} minutes"
        echo "- Health URL: ${health_url:-none}"
        echo "- Log command: ${log_cmd:-none}"
        echo "- Error threshold: ${error_threshold}"
        echo "- Auto-rollback: ${auto_rollback}"
        echo ""
        echo "## Poll Results"
        echo ""
    } > "$report_file"

    local poll=0
    local health_failures=0
    local log_errors=0
    while [[ "$poll" -lt "$total_polls" ]]; do
        poll=$((poll + 1))
        local poll_time
        poll_time=$(now_iso)

        # Health URL check
        if [[ -n "$health_url" ]]; then
            local http_status
            http_status=$(curl -sf -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "000")
            if [[ "$http_status" -ge 200 && "$http_status" -lt 400 ]]; then
                echo "- [${poll_time}] Health: ✅ (HTTP ${http_status})" >> "$report_file"
            else
                health_failures=$((health_failures + 1))
                total_errors=$((total_errors + 1))
                echo "- [${poll_time}] Health: ❌ (HTTP ${http_status})" >> "$report_file"
                warn "Health check failed: HTTP ${http_status}"
            fi
        fi

        # Log command check (accumulate deploy logs for feedback collect)
        if [[ -n "$log_cmd" ]]; then
            local log_output
            log_output=$(bash -c "$log_cmd" 2>/dev/null || true)
            [[ -n "$log_output" ]] && echo "$log_output" >> "$deploy_log_file"
            local error_count=0
            if [[ -n "$log_output" ]]; then
                error_count=$(echo "$log_output" | grep -cE "$log_pattern" 2>/dev/null || true)
                error_count="${error_count:-0}"
            fi
            if [[ "$error_count" -gt 0 ]]; then
                log_errors=$((log_errors + error_count))
                total_errors=$((total_errors + error_count))
                echo "- [${poll_time}] Logs: ⚠️ ${error_count} error(s) matching '${log_pattern}'" >> "$report_file"
                warn "Log errors detected: ${error_count}"
            else
                echo "- [${poll_time}] Logs: ✅ clean" >> "$report_file"
            fi
        fi

        emit_event "monitor.check" \
            "issue=${ISSUE_NUMBER:-0}" \
            "poll=$poll" \
            "total_errors=$total_errors" \
            "health_failures=$health_failures"

        # Check threshold
        if [[ "$total_errors" -ge "$error_threshold" ]]; then
            error "Error threshold exceeded: ${total_errors} >= ${error_threshold}"

            echo "" >> "$report_file"
            echo "## ❌ THRESHOLD EXCEEDED" >> "$report_file"
            echo "Total errors: ${total_errors} (threshold: ${error_threshold})" >> "$report_file"

            emit_event "monitor.alert" \
                "issue=${ISSUE_NUMBER:-0}" \
                "total_errors=$total_errors" \
                "threshold=$error_threshold"

            # Feedback loop: collect deploy logs and optionally create issue
            if [[ -f "$deploy_log_file" ]] && [[ -s "$deploy_log_file" ]] && [[ -x "$SCRIPT_DIR/sw-feedback.sh" ]]; then
                (cd "$PROJECT_ROOT" && ARTIFACTS_DIR="$ARTIFACTS_DIR" bash "$SCRIPT_DIR/sw-feedback.sh" collect "$deploy_log_file" 2>/dev/null) || true
                (cd "$PROJECT_ROOT" && ARTIFACTS_DIR="$ARTIFACTS_DIR" bash "$SCRIPT_DIR/sw-feedback.sh" create-issue 2>/dev/null) || true
            fi

            # Auto-rollback: feedback rollback (GitHub Deployments API) and/or config rollback_cmd
            if [[ "$auto_rollback" == "true" ]]; then
                warn "Auto-rolling back..."
                echo "" >> "$report_file"
                echo "## Rollback" >> "$report_file"

                # Trigger feedback rollback (calls sw-github-deploy.sh rollback)
                if [[ -x "$SCRIPT_DIR/sw-feedback.sh" ]]; then
                    (cd "$PROJECT_ROOT" && ARTIFACTS_DIR="$ARTIFACTS_DIR" bash "$SCRIPT_DIR/sw-feedback.sh" rollback production "Monitor threshold exceeded (${total_errors} errors)" >> "$report_file" 2>&1) || true
                fi

                if [[ -n "$rollback_cmd" ]] && bash -c "$rollback_cmd" >> "$report_file" 2>&1; then
                    success "Rollback executed"
                    echo "Rollback: ✅ success" >> "$report_file"

                    # Post-rollback smoke test verification
                    local smoke_cmd
                    smoke_cmd=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.smoke_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
                    [[ "$smoke_cmd" == "null" ]] && smoke_cmd=""

                    if [[ -n "$smoke_cmd" ]]; then
                        info "Verifying rollback with smoke tests..."
                        if bash -c "$smoke_cmd" > "$ARTIFACTS_DIR/rollback-smoke.log" 2>&1; then
                            success "Rollback verified — smoke tests pass"
                            echo "Rollback verification: ✅ smoke tests pass" >> "$report_file"
                            emit_event "monitor.rollback_verified" \
                                "issue=${ISSUE_NUMBER:-0}" \
                                "status=pass"
                        else
                            error "Rollback verification FAILED — smoke tests still failing"
                            echo "Rollback verification: ❌ smoke tests FAILED — manual intervention required" >> "$report_file"
                            emit_event "monitor.rollback_verified" \
                                "issue=${ISSUE_NUMBER:-0}" \
                                "status=fail"
                            if [[ -n "$ISSUE_NUMBER" ]]; then
                                gh_comment_issue "$ISSUE_NUMBER" "🚨 **Rollback executed but verification failed** — smoke tests still failing after rollback. Manual intervention required.

Smoke command: \`${smoke_cmd}\`
Log: see \`pipeline-artifacts/rollback-smoke.log\`" 2>/dev/null || true
                            fi
                        fi
                    fi
                else
                    error "Rollback failed!"
                    echo "Rollback: ❌ failed" >> "$report_file"
                fi

                emit_event "monitor.rollback" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "total_errors=$total_errors"

                # Post to GitHub
                if [[ -n "$ISSUE_NUMBER" ]]; then
                    gh_comment_issue "$ISSUE_NUMBER" "🚨 **Auto-rollback triggered** — ${total_errors} errors exceeded threshold (${error_threshold})

Rollback command: \`${rollback_cmd}\`" 2>/dev/null || true

                    # Create hotfix issue
                    if [[ "$GH_AVAILABLE" == "true" ]]; then
                        gh issue create \
                            --title "Hotfix: Deploy regression for ${GOAL}" \
                            --label "hotfix,incident" \
                            --body "Auto-rollback triggered during post-deploy monitoring.

**Original issue:** ${GITHUB_ISSUE:-N/A}
**Errors detected:** ${total_errors}
**Threshold:** ${error_threshold}
**Branch:** ${GIT_BRANCH}

## Monitor Report
$(cat "$report_file")

---
_Created automatically by \`shipwright pipeline\` monitor stage_" 2>/dev/null || true
                    fi
                fi
            fi

            log_stage "monitor" "Failed — ${total_errors} errors (threshold: ${error_threshold})"
            return 1
        fi

        # Sleep between polls (skip on last poll)
        if [[ "$poll" -lt "$total_polls" ]]; then
            sleep "$poll_interval"
        fi
    done

    # Monitoring complete — all clear
    echo "" >> "$report_file"
    echo "## ✅ Monitoring Complete" >> "$report_file"
    echo "Total errors: ${total_errors} (threshold: ${error_threshold})" >> "$report_file"
    echo "Health failures: ${health_failures}" >> "$report_file"
    echo "Log errors: ${log_errors}" >> "$report_file"

    success "Post-deploy monitoring clean (${total_errors} errors in ${duration_minutes}m)"

    # Proactive feedback collection: always collect deploy logs for trend analysis
    if [[ -f "$deploy_log_file" ]] && [[ -s "$deploy_log_file" ]] && [[ -x "$SCRIPT_DIR/sw-feedback.sh" ]]; then
        (cd "$PROJECT_ROOT" && ARTIFACTS_DIR="$ARTIFACTS_DIR" bash "$SCRIPT_DIR/sw-feedback.sh" collect "$deploy_log_file" 2>/dev/null) || true
    fi

    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "✅ **Post-deploy monitoring passed** — ${duration_minutes}m, ${total_errors} errors" 2>/dev/null || true
    fi

    log_stage "monitor" "Clean — ${total_errors} errors in ${duration_minutes}m"

    # Record baseline for adaptive monitoring on future runs
    local baseline_dir="${HOME}/.shipwright/baselines/${repo_hash}"
    mkdir -p "$baseline_dir" 2>/dev/null || true
    local baseline_tmp
    baseline_tmp="$(mktemp)"
    if [[ -f "${baseline_dir}/deploy-monitor.json" ]]; then
        # Append to history and recalculate p90
        jq --arg dur "$duration_minutes" --arg errs "$total_errors" \
            '.history += [{"duration_minutes": ($dur | tonumber), "errors": ($errs | tonumber)}] |
             .p90_stabilization_minutes = ([.history[].duration_minutes] | sort | .[length * 9 / 10 | floor]) |
             .p90_error_threshold = (([.history[].errors] | sort | .[length * 9 / 10 | floor]) + 2) |
             .updated_at = now' \
            "${baseline_dir}/deploy-monitor.json" > "$baseline_tmp" 2>/dev/null && \
            mv "$baseline_tmp" "${baseline_dir}/deploy-monitor.json" || rm -f "$baseline_tmp"
    else
        jq -n --arg dur "$duration_minutes" --arg errs "$total_errors" \
            '{history: [{"duration_minutes": ($dur | tonumber), "errors": ($errs | tonumber)}],
              p90_stabilization_minutes: ($dur | tonumber),
              p90_error_threshold: (($errs | tonumber) + 2),
              updated_at: now}' \
            > "$baseline_tmp" 2>/dev/null && \
            mv "$baseline_tmp" "${baseline_dir}/deploy-monitor.json" || rm -f "$baseline_tmp"
    fi
}

# ─── Multi-Dimensional Quality Checks ─────────────────────────────────────
# Beyond tests: security, bundle size, perf regression, API compat, coverage

