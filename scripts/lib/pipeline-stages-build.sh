# pipeline-stages-build.sh — test_first, build, test stages
# Source from pipeline-stages.sh. Requires all pipeline globals and dependencies.
[[ -n "${_PIPELINE_STAGES_BUILD_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_BUILD_LOADED=1

# Map pipeline stage to effort level (when no explicit --effort override)
_stage_effort_level() {
    local stage="$1"
    # Use _smart_effort if available (reads from daemon-config.json → defaults)
    if type _smart_effort >/dev/null 2>&1; then
        _smart_effort "$stage"
        return
    fi
    # Fallback if compat.sh not loaded
    case "$stage" in
        intake)              echo "low" ;;
        plan|design)         echo "high" ;;
        build)               echo "medium" ;;
        test)                echo "medium" ;;
        review|compound_quality) echo "high" ;;
        pr|merge)            echo "low" ;;
        deploy|validate|monitor) echo "medium" ;;
        *)                   echo "medium" ;;
    esac
}

# Build common claude flags for pipeline stages
_pipeline_claude_flags() {
    local stage="$1"
    local model="$2"
    local flags=("--model" "$model")

    # Effort level: explicit override > per-stage default
    local effort="${EFFORT_LEVEL_OVERRIDE:-$(_stage_effort_level "$stage")}"
    flags+=("--effort" "$effort")

    # Fallback model — only add if explicitly configured and different from primary
    local _fallback="${FALLBACK_MODEL_OVERRIDE:-${PIPELINE_FALLBACK_MODEL:-}}"
    if [[ -n "$_fallback" ]] && [[ "$_fallback" != "$model" ]]; then
        flags+=("--fallback-model" "$_fallback")
    fi

    echo "${flags[*]}"
}

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
    local tdd_timeout
    tdd_timeout=$(_smart_int "timeouts.tdd_generation" 120)
    output=$(echo "$tdd_prompt" | timeout "$tdd_timeout" claude --print --model "$model" 2>/dev/null) || {
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
    CURRENT_STAGE_ID="build"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-build.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _build_retry_hints
        _build_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi
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

    # Dark factory: inject spec context into build goal
    local spec_file="${ARTIFACTS_DIR}/spec.json"
    if [[ -f "$spec_file" ]] && type spec_to_prompt >/dev/null 2>&1; then
        local spec_prompt
        spec_prompt=$(spec_to_prompt "$spec_file" 2>/dev/null || true)
        if [[ -n "$spec_prompt" ]]; then
            enriched_goal="${enriched_goal}

${spec_prompt}"
        fi
    fi

    # Dark factory: inject formal spec constraints into build goal
    if type formal_spec_inject >/dev/null 2>&1; then
        local _formal_context
        _formal_context=$(formal_spec_inject "${PROJECT_ROOT:-.}" 2>/dev/null || true)
        if [[ -n "$_formal_context" ]]; then
            enriched_goal="${enriched_goal}

${_formal_context}"
        fi
    fi

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

    # Inject skill prompts for build stage
    local _skill_prompts=""
    if type skill_load_from_plan >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_from_plan "build" 2>/dev/null || true)
    elif type skill_select_adaptive >/dev/null 2>&1; then
        local _skill_files
        _skill_files=$(skill_select_adaptive "${INTELLIGENCE_ISSUE_TYPE:-backend}" "build" "${ISSUE_BODY:-}" "${INTELLIGENCE_COMPLEXITY:-5}" 2>/dev/null || true)
        if [[ -n "$_skill_files" ]]; then
            _skill_prompts=$(while IFS= read -r _path; do
                [[ -z "$_path" || ! -f "$_path" ]] && continue
                cat "$_path" 2>/dev/null
            done <<< "$_skill_files")
        fi
    elif type skill_load_prompts >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "build" 2>/dev/null || true)
    fi
    if [[ -n "$_skill_prompts" ]]; then
        _skill_prompts=$(prune_context_section "skills" "$_skill_prompts" 8000)
        enriched_goal="${enriched_goal}

## Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue, AI-selected)
${_skill_prompts}
"
    fi

    loop_args+=("$enriched_goal")

    # Build loop args from pipeline config + CLI overrides
    CURRENT_STAGE_ID="build"

    local test_cmd="${TEST_CMD}"
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.test_cmd) // .defaults.test_cmd // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ "$test_cmd" == "null" ]] && test_cmd=""
    fi
    # Auto-detect if still empty — prefer fast variants for build iterations
    if [[ -z "$test_cmd" ]]; then
        # Check for fast test scripts first (build loop runs tests every iteration)
        if [[ -f "$PROJECT_ROOT/package.json" ]]; then
            local _fast_test=""
            _fast_test=$(jq -r '.scripts["test:fast"] // .scripts["test:smoke"] // ""' "$PROJECT_ROOT/package.json" 2>/dev/null) || true
            if [[ -n "$_fast_test" && "$_fast_test" != "null" ]]; then
                local _pm
                _pm=$(detect_package_manager 2>/dev/null || echo "npm")
                test_cmd="$_pm run test:$(jq -r 'if .scripts["test:fast"] then "fast" else "smoke" end' "$PROJECT_ROOT/package.json" 2>/dev/null)"
                info "Using fast test command for build iterations: ${DIM}$test_cmd${RESET}"
            fi
        fi
        # Fall back to full test command
        if [[ -z "$test_cmd" ]]; then
            test_cmd=$(detect_test_cmd)
        fi
    fi

    # Discover additional test commands (subdirectories, extra scripts)
    local additional_cmds=()
    if type detect_test_commands >/dev/null 2>&1; then
        while IFS= read -r _cmd; do
            [[ -n "$_cmd" ]] && additional_cmds+=("$_cmd")
        done < <(detect_test_commands 2>/dev/null | tail -n +2)
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
    for _extra_tc in "${additional_cmds[@]+"${additional_cmds[@]}"}"; do
        [[ -n "$_extra_tc" ]] && loop_args+=(--additional-test-cmds "$_extra_tc")
    done
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

    # Effort level and fallback model
    [[ -n "${EFFORT_LEVEL_OVERRIDE:-}" ]] && loop_args+=(--effort "$EFFORT_LEVEL_OVERRIDE")
    [[ -n "${FALLBACK_MODEL_OVERRIDE:-}" ]] && loop_args+=(--fallback-model "$FALLBACK_MODEL_OVERRIDE")
    [[ -z "${FALLBACK_MODEL_OVERRIDE:-}" && -n "${PIPELINE_FALLBACK_MODEL:-}" ]] && loop_args+=(--fallback-model "$PIPELINE_FALLBACK_MODEL")

    # Definition of Done: use plan-extracted DoD if available
    [[ -s "$dod_file" ]] && loop_args+=(--definition-of-done "$dod_file")

    # Checkpoint resume: when pipeline resumed from build-stage checkpoint, pass --resume to loop
    if [[ "${RESUME_FROM_CHECKPOINT:-false}" == "true" && "${checkpoint_stage:-}" == "build" ]]; then
        loop_args+=(--resume)
    fi

    # Skip permissions — pipeline runs headlessly (claude -p) and has no terminal
    # for interactive permission prompts. Without this flag, agents can't write files.
    loop_args+=(--skip-permissions)

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

        # Detect pre-build environment failure from progress file
        local _progress_file="${PWD}/.claude/loop-logs/progress.md"
        local _loop_status=""
        if [[ -f "$_progress_file" ]]; then
            _loop_status=$(grep -oE 'Status: [a-z_]+' "$_progress_file" 2>/dev/null | awk '{print $NF}' || echo "")
        fi

        if [[ "$_loop_status" == "pre_build_failed" ]]; then
            warn "Pre-build validation failed (fatal environment issue) — not retrying"
            emit_event "pipeline.environment_error" "issue=${ISSUE_NUMBER:-0}" "stage=build"
            # Write flag for daemon retry logic (1 max retry for environment errors)
            mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
            echo "environment_error" > "$ARTIFACTS_DIR/failure-reason.txt" 2>/dev/null || true
            error "Build loop failed due to environment issue (not retrying)"
            return 1
        fi

        # Detect context exhaustion from progress file
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
    commit_count=$(_safe_base_log --oneline | wc -l | xargs)
    info "Build produced ${BOLD}$commit_count${RESET} commit(s)"

    # Commit quality evaluation when intelligence is enabled
    if type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1 && [[ "${commit_count:-0}" -gt 0 ]]; then
        local commit_msgs
        commit_msgs=$(_safe_base_log --format="%s" | head -20)
        local quality_score
        quality_score=$(claude --print --output-format text -p "Rate the quality of these git commit messages on a scale of 0-100. Consider: focus (one thing per commit), clarity (describes the why), atomicity (small logical units). Reply with ONLY a number 0-100.

Commit messages:
${commit_msgs}" --model "$(_smart_model commit_quality haiku)" < /dev/null 2>/dev/null || true)
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

    # ── Constitutional diff check (advisory, before scope enforcement) ──
    if type constitutional_check_diff >/dev/null 2>&1; then
        local const_diff_violations
        const_diff_violations=$(constitutional_check_diff "${BASE_BRANCH:-main}" "HEAD" 2>/dev/null) || true
        local const_diff_count
        const_diff_count=$(echo "${const_diff_violations:-[]}" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$const_diff_count" -gt 0 ]]; then
            warn "Constitutional diff check: $const_diff_count violation(s) in changed code"
            emit_event "build.constitutional_diff" "violations=$const_diff_count" "stage=build"
        fi
    fi

    # ── Scope Enforcement: Compare planned vs actual files (best-effort) ──
    if type generate_scope_report >/dev/null 2>&1; then
        local plan_file="$ARTIFACTS_DIR/plan.md"
        if [[ -f "$plan_file" ]]; then
            info "Analyzing scope: comparing planned vs actual files..."
            # Run in subshell to prevent set -e propagation
            (generate_scope_report "$plan_file" "origin/${BASE_BRANCH:-main}" "$ARTIFACTS_DIR" 2>/dev/null) || true
            if [[ -f "$ARTIFACTS_DIR/scope-report.json" ]]; then
                local unplanned_count
                unplanned_count=$(jq '.unplanned_files | length' "$ARTIFACTS_DIR/scope-report.json" 2>/dev/null || echo "0")
                if [[ "$unplanned_count" -gt 0 ]]; then
                    warn "Scope analysis: $unplanned_count unplanned file(s) changed (see scope-report.json)"
                else
                    info "Scope analysis: all changes are planned"
                fi
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

        # Dark factory: holdout validation — run sealed tests the agent never saw
        if type holdout_validate >/dev/null 2>&1; then
            HOLDOUT_DIR="${ARTIFACTS_DIR}/test-holdout"
            if [[ -f "${HOLDOUT_DIR}/manifest.json" ]]; then
                if holdout_validate "." "$test_cmd" 2>/dev/null; then
                    success "Holdout validation passed (agent code works on unseen tests)"
                else
                    warn "Holdout validation failed — agent may have overfit to visible tests"
                    holdout_reveal 2>/dev/null || true
                    # Don't fail the stage — holdout is advisory for now
                    emit_event "test.holdout_failed" \
                        "issue=${ISSUE_NUMBER:-0}" \
                        "stage=test" 2>/dev/null || true
                fi
            fi
        fi

        # Dark factory: mutation testing — verify test effectiveness
        if type mutation_generate >/dev/null 2>&1; then
            local _mut_dir="${ARTIFACTS_DIR}/mutations"
            mkdir -p "$_mut_dir" 2>/dev/null || true
            local _changed_files
            _changed_files=$(git diff --name-only HEAD~1 2>/dev/null | head -10 || true)
            local _mut_total=0
            while IFS= read -r _mut_file; do
                [[ -z "$_mut_file" || ! -f "$_mut_file" ]] && continue
                local _mc
                _mc=$(mutation_generate "$_mut_file" "$_mut_dir" 2>/dev/null || echo "0")
                _mut_total=$((_mut_total + _mc))
            done <<< "$_changed_files"
            if [[ "$_mut_total" -gt 0 ]]; then
                info "Mutation testing: $_mut_total mutants generated, executing..."
                local _mut_result
                _mut_result=$(mutation_execute "$_mut_dir" "$test_cmd" "${PROJECT_ROOT:-.}" 2>/dev/null || echo '{}')
                local _mut_killed _mut_survived
                _mut_killed=$(echo "$_mut_result" | jq -r '.killed // 0' 2>/dev/null || echo "0")
                _mut_survived=$(echo "$_mut_result" | jq -r '.survived // 0' 2>/dev/null || echo "0")
                mutation_report "$_mut_dir" "${ARTIFACTS_DIR}/mutation-report.json" >/dev/null 2>&1 || true
                if [[ "$_mut_survived" -gt 0 ]]; then
                    warn "Mutation testing: $_mut_killed killed, $_mut_survived survived (weak tests detected)"
                else
                    success "Mutation testing: $_mut_killed/$_mut_total mutants killed"
                fi
                emit_event "test.mutation_complete" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "killed=$_mut_killed" \
                    "survived=$_mut_survived" \
                    "total=$_mut_total" 2>/dev/null || true
            fi
        fi
    else
        error "Tests failed (exit code: $test_exit)"

        # Dark factory: build causal graph and trace failure chain
        if type causal_build_graph >/dev/null 2>&1; then
            CAUSAL_GRAPH_FILE="${ARTIFACTS_DIR}/causal-graph.json"
            causal_build_graph "." 2>/dev/null || true
            # Trace the failure to root cause
            if type causal_trace_failure >/dev/null 2>&1; then
                local _failing_tests
                _failing_tests=$(grep -l 'FAIL\|Error\|assert' "$test_log" 2>/dev/null | head -1 || true)
                if [[ -n "$_failing_tests" ]]; then
                    causal_trace_failure "$_failing_tests" "." 2>/dev/null || true
                fi
            fi
            # Suggest fix based on causal trace
            if type causal_suggest_fix >/dev/null 2>&1; then
                local _trace_file="${CAUSAL_GRAPH_FILE%.json}-trace.json"
                if [[ -f "$_trace_file" ]]; then
                    causal_suggest_fix "$_trace_file" 2>/dev/null || true
                fi
            fi
        fi

        # Extract most relevant error section (assertion failures, stack traces)
        local relevant_output=""
        relevant_output=$(grep -A5 -E 'FAIL|AssertionError|Expected.*but.*got|Error:|panic:|assert' "$test_log" 2>/dev/null | tail -40 || true)
        if [[ -z "$relevant_output" ]]; then
            relevant_output=$(tail -40 "$test_log")
        fi
        echo "$relevant_output"

        # Post failure to GitHub with more context
        if [[ -n "$ISSUE_NUMBER" ]]; then
            local log_lines
            log_lines=$(wc -l < "$test_log" 2>/dev/null || true)
            log_lines="${log_lines:-0}"
            local log_excerpt
            if [[ "$log_lines" -lt 60 ]]; then
                log_excerpt="$(cat "$test_log" 2>/dev/null || true)"
            else
                log_excerpt="$(head -20 "$test_log" 2>/dev/null || true)
... (${log_lines} lines total, showing head + tail) ...
$(tail -30 "$test_log" 2>/dev/null || true)"
            fi
            gh_comment_issue "$ISSUE_NUMBER" "❌ **Tests failed** (exit code: $test_exit, ${log_lines} lines)
\`\`\`
${log_excerpt}
\`\`\`"
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

