# pipeline-stages-build.sh — test_first, build, test stages

# Agents run without GitHub credentials (#8614): claude is launched through agent-exec.sh.
SW_AGENT_EXEC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-exec.sh"
# Source from pipeline-stages.sh. Requires all pipeline globals and dependencies.
# Test commands run without credentials (#8608).
# shellcheck source=lib/test-gate-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-gate-env.sh"
# Patch handoff (#8706): the build agent works in a disposable clone and only a judged patch comes
# back. On by default; SW_PATCH_HANDOFF=false turns it off (the old shared-checkout build).
# shellcheck source=lib/patch-handoff.sh
source "$(dirname "${BASH_SOURCE[0]}")/patch-handoff.sh"
# shellcheck source=lib/test-sandbox.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-sandbox.sh"
# Prompt-injection defenses for issue text (trust boundary).
# shellcheck source=lib/untrusted.sh
source "$(dirname "${BASH_SOURCE[0]}")/untrusted.sh"
source "$(dirname "${BASH_SOURCE[0]}")/models.sh"
# shellcheck source=lib/acceptance-tests.sh
source "$(dirname "${BASH_SOURCE[0]}")/acceptance-tests.sh"
# shellcheck source=lib/repo-model.sh
source "$(dirname "${BASH_SOURCE[0]}")/repo-model.sh"
# shellcheck source=lib/claude-usage.sh
source "$(dirname "${BASH_SOURCE[0]}")/claude-usage.sh"
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
    # W2-07: the flags carry the full ID. A model that does not resolve stops the stage (never --model "").
    local resolved
    resolved="$(models_resolve "$model")" || {
        echo "pipeline: cannot resolve model '$model' for stage $stage" >&2
        return 1
    }
    local flags=("--model" "$resolved")

    # Effort level: explicit override > per-stage default
    local effort="${EFFORT_LEVEL_OVERRIDE:-$(_stage_effort_level "$stage")}"
    flags+=("--effort" "$effort")

    # Fallback model — only add if explicitly configured and different from primary
    local _fallback="${FALLBACK_MODEL_OVERRIDE:-${PIPELINE_FALLBACK_MODEL:-}}"
    if [[ -n "$_fallback" ]] && [[ "$_fallback" != "$model" ]]; then
        flags+=("--fallback-model" "$_fallback")
    fi

    # Repository world model tools (ADR-0016): nothing when SHIPWRIGHT_REPO_MODEL=off.
    local _rm_flag
    for _rm_flag in $(repo_model_mcp_flags); do flags+=("$_rm_flag"); done

    echo "${flags[*]}"
}

# _pipeline_test_cmd — the project's test command: TEST_CMD, the test stage config, else auto-detected.
_pipeline_test_cmd() {
    local test_cmd="${TEST_CMD:-}"
    if [[ -z "$test_cmd" && -n "${PIPELINE_CONFIG:-}" ]]; then
        test_cmd=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.test_cmd) // .defaults.test_cmd // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ "$test_cmd" == "null" ]] && test_cmd=""
    fi
    [[ -z "$test_cmd" ]] && test_cmd=$(detect_test_cmd 2>/dev/null || true)
    printf '%s' "$test_cmd"
}

# stage_test_first — spec-first acceptance tests (ADR-0015, lib/acceptance-tests.sh). Returns 1 only
# in enforce mode when no proven-red tests could be written; the caller stops the pipeline then.
stage_test_first() {
    CURRENT_STAGE_ID="test_first"
    local mode test_cmd
    mode=$(acceptance_mode)
    [[ "$mode" == "off" ]] && return 0
    test_cmd=$(_pipeline_test_cmd)
    if [[ -z "$test_cmd" ]]; then
        warn "Acceptance tests skipped: no test command found (set TEST_CMD or the test stage's test_cmd)"
        emit_event "acceptance.skipped" "issue=${ISSUE_NUMBER:-0}" "reason=no_test_cmd" 2>/dev/null || true
        return 0
    fi
    info "Spec-first: turning the issue into acceptance tests that must fail before implementation"
    if acceptance_generate "$test_cmd"; then
        return 0
    fi
    if [[ "$mode" == "warn" ]]; then
        warn "No proven-red acceptance tests (warn mode): building without an acceptance gate"
        return 0
    fi
    error "No acceptance tests could be proven red for the right reason; see ${ARTIFACTS_DIR}/acceptance-red.log"
    return 1
}

# ── Tournament mode (shipwright tournament) ─────────────────────────────────
# N independent attempts; a cross-test matrix, a per-issue rubric and a blind group-wise judge pick
# one patch. Under patch handoff (the default, ADR-0011) the whole tournament runs in a disposable
# clone without credentials, and the winner reaches the trusted checkout only as a judged patch,
# exactly like a single build loop. With SW_PATCH_HANDOFF=false it runs in the checkout and the
# winner is fast-forwarded onto the pipeline branch.
# On when PIPELINE_ATTEMPTS (or .defaults.attempts in the pipeline config) is 2 to 5 and the
# pipeline knows a test command: the tournament gates every attempt on the repository's tests.
_build_tournament_attempts() {
    local n="${PIPELINE_ATTEMPTS:-}"
    if [[ -z "$n" && -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG}" ]]; then
        n=$(jq -r '.defaults.attempts // empty' "$PIPELINE_CONFIG" 2>/dev/null || true)
    fi
    case "$n" in
        2|3|4|5) echo "$n" ;;
        *) echo "1" ;;
    esac
}

# _build_tournament_clone BASE — the tournament's disposable clone (patch handoff). Edits earlier
# stages left in the trusted checkout are moved into it and committed there, so every attempt starts
# from them and they are judged with the winner. Prints the clone's path.
_build_tournament_clone() {
    local base="$1" tmp dir
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-agent.XXXXXX") || return 1
    [[ -n "$tmp" && -d "$tmp" ]] || return 1
    dir="$tmp/repo"
    if ! handoff_prepare "$PROJECT_ROOT" "$base" "$dir" \
        || ! handoff_carry_over "$PROJECT_ROOT" "$base" "$dir" "${ARTIFACTS_DIR}/pre-build.patch"; then
        rm -rf -- "$tmp"
        return 1
    fi
    if [[ -s "${ARTIFACTS_DIR}/pre-build.patch" ]]; then
        warn "Patch handoff: moved uncommitted edits from earlier stages into the tournament clone (they are judged with the winner)" >&2
        if ! GIT_AUTHOR_NAME=shipwright-pipeline GIT_AUTHOR_EMAIL=pipeline@shipwright.local \
            GIT_COMMITTER_NAME=shipwright-pipeline GIT_COMMITTER_EMAIL=pipeline@shipwright.local \
            _handoff_in "$dir" commit -q --no-verify -m "pre-build edits (carried over)" >&2; then
            rm -rf -- "$tmp"
            return 1
        fi
    fi
    printf '%s\n' "$dir"
}

_build_tournament() {
    local goal="$1" test_cmd="$2" model="$3" attempts="$4"
    mkdir -p "$ARTIFACTS_DIR"
    # Absolute: under patch handoff the tournament runs in another directory.
    local art
    art=$(cd "$ARTIFACTS_DIR" && pwd) || return 1
    local goal_file="$art/tournament-goal.md"
    local report="$art/tournament.json"
    printf '%s\n' "$goal" > "$goal_file"
    local args=(--goal-file "$goal_file" --test-cmd "$test_cmd" --attempts "$attempts" --model "$model" --format json)
    [[ -n "${PIPELINE_TOURNAMENT_BUDGET_USD:-}" ]] && args+=(--budget-usd "$PIPELINE_TOURNAMENT_BUDGET_USD")
    [[ -n "${PIPELINE_SETUP_CMD:-}" ]] && args+=(--setup-cmd "$PIPELINE_SETUP_CMD")

    local base="" dir="" run_dir="$PROJECT_ROOT"
    if [[ "${SW_PATCH_HANDOFF:-true}" != "false" ]]; then
        base=$(git -C "$PROJECT_ROOT" rev-parse HEAD) || { error "Patch handoff: no base commit"; return 1; }
        dir=$(_build_tournament_clone "$base") \
            || { error "Patch handoff: could not prepare the tournament clone"; return 1; }
        run_dir="$dir"
        info "Patch handoff: tournament runs in ${DIM}${dir}${RESET} (base ${base:0:12})"
    fi

    info "Starting build tournament: ${attempts} parallel attempts, model ${model}"
    if [[ -n "${ISSUE_NUMBER:-}" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "🔨 **Build started** — tournament mode: ${attempts} independent attempts, model: ${model}"
    fi
    local rc=0
    # Under handoff it holds no GitHub or fleet credentials, like the build loop (_build_run_loop).
    # It runs the sw beside this pipeline, never one from PATH (an older install would run instead).
    (cd "$run_dir" && _build_run_loop "${SHIPWRIGHT_SW_BIN:-$SCRIPT_DIR/sw}" tournament "${args[@]}") < /dev/null > "${report}.tmp" || rc=$?
    mv "${report}.tmp" "$report"

    local winner confidence cost
    winner=$(jq -r '.selection.winner // empty' "$report" 2>/dev/null || true)
    confidence=$(jq -r '.selection.confidence // empty' "$report" 2>/dev/null || true)
    cost=$(jq -r '.costUsd // 0' "$report" 2>/dev/null || echo "0")
    if [[ -n "$cost" && "$cost" != "0" && "$cost" != "null" ]]; then
        TOTAL_COST_USD="$cost"
    fi
    emit_event "build.tournament" "issue=${ISSUE_NUMBER:-0}" "attempts=$attempts" \
        "winner=${winner:-none}" "confidence=${confidence:-none}" "cost_usd=${cost:-0}" "exit=$rc"
    if [[ "$rc" -ne 0 ]]; then
        [[ -n "$dir" ]] && rm -rf -- "${dir%/repo}"
        if [[ "$rc" -eq 3 ]]; then
            echo "tournament_no_winner" > "$ARTIFACTS_DIR/failure-reason.txt" 2>/dev/null || true
            error "Build tournament: no attempt passed the tests and the judge (see tournament.json)"
        else
            error "Build tournament failed (exit $rc)"
        fi
        return 1
    fi
    info "Build tournament winner: ${winner} (${confidence} confidence, \$${cost})"
    # The winner was adopted in the clone; it reaches the trusted checkout only as a judged patch.
    if [[ -n "$dir" ]]; then
        _build_handoff_return "$dir" "$base" || return 1
    fi
}

# _build_run_loop LOOP_SCRIPT ARGS... — runs the loop script (the sw-loop.sh beside this pipeline,
# never `sw` from PATH). Under patch handoff the loop holds no GitHub or fleet credentials: it works
# in the agent's clone, and nothing it does there is trusted.
_build_run_loop() {
    local loop_script="$1"
    shift
    # The loop runs as a waited-on background child: bash defers a trap until a foreground child
    # exits, so an abort (SIGTERM) would otherwise wait for the whole loop. cleanup_on_exit stops it.
    local rc=0
    if [[ "${SW_PATCH_HANDOFF:-true}" == "false" ]]; then
        "$loop_script" "$@" < /dev/null &
        _PIPELINE_CHILD_PID=$!
        wait "$_PIPELINE_CHILD_PID" || rc=$?
        _PIPELINE_CHILD_PID=""
        return "$rc"
    fi
    local _empty_gh
    _empty_gh=$(mktemp -d "${TMPDIR:-/tmp}/sw-nogh.XXXXXX") || return 1
    env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_PAT \
        -u SHIPWRIGHT_FLEET_TOKEN -u SHIPWRIGHT_FLEET_TOKEN_FILE -u SSH_AUTH_SOCK \
        -u SW_PIPELINE_PUSH_URL GH_CONFIG_DIR="$_empty_gh" GIT_CONFIG_GLOBAL=/dev/null \
        GIT_TERMINAL_PROMPT=0 "$loop_script" "$@" < /dev/null &
    _PIPELINE_CHILD_PID=$!
    wait "$_PIPELINE_CHILD_PID" || rc=$?
    _PIPELINE_CHILD_PID=""
    rm -rf "$_empty_gh"
    return "$rc"
}

# _build_handoff_return AGENT_DIR BASE — export the agent's work as a patch, judge it, and commit
# it to the trusted checkout. Any refusal fails the build (fail closed).
_build_handoff_return() {
    local dir="$1" base="$2"
    local patch="${ARTIFACTS_DIR}/agent.patch"
    mkdir -p "$ARTIFACTS_DIR" "${ARTIFACTS_DIR}/agent-loop-logs"
    # Loop logs come back as data for humans and token accounting, never into the repo.
    cp -R "${dir}/.claude/loop-logs/." "${ARTIFACTS_DIR}/agent-loop-logs/" 2>/dev/null || true
    handoff_export "$dir" "$base" "$PROJECT_ROOT" "$patch" || { error "Patch handoff: export failed"; return 1; }
    if [[ ! -s "$patch" ]]; then
        # Nothing changed (for example a self-heal pass that needed no edit): nothing to apply.
        warn "Patch handoff: the build produced no changes"
        emit_event "build.patch_empty" "issue=${ISSUE_NUMBER:-0}" "base=$base"
        rm -rf "$(dirname "$dir")"
        return 0
    fi
    local why
    if ! why=$(handoff_judge "$patch"); then
        printf '%s\n' "$why" > "${ARTIFACTS_DIR}/agent.patch.refused"
        error "Patch handoff: patch refused: $(printf '%s' "$why" | tr '\n' ';')"
        emit_event "build.patch_refused" "issue=${ISSUE_NUMBER:-0}" "base=$base"
        return 1
    fi
    local sha
    sha=$(handoff_apply "$PROJECT_ROOT" "$base" "$patch" "build: ${GOAL:-issue ${ISSUE_NUMBER:-}}") || {
        error "Patch handoff: apply failed"
        return 1
    }
    emit_event "build.patch_applied" "issue=${ISSUE_NUMBER:-0}" "base=$base" "head=$sha"
    success "Patch handoff: applied the agent's patch as ${sha:0:12}"
    rm -rf "$(dirname "$dir")"
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

    # Spec-first: the locked acceptance tests define done (ADR-0015)
    local acceptance_brief
    acceptance_brief=$(acceptance_build_brief 2>/dev/null || true)
    if [[ -n "$acceptance_brief" ]]; then
        enriched_goal="${enriched_goal}

${acceptance_brief}"
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
        if echo "$design_lower" | grep >/dev/null -E 'independent (files|modules|components|services)|separate (modules|packages|directories)|parallel|no shared state'; then
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
    # W2-07: recruit's model override is off unless SW_LEGACY_MODEL_ROUTING=true.
    if [[ "${SW_LEGACY_MODEL_ROUTING:-false}" == "true" ]] && [[ -z "$MODEL" ]] && [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
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
    # A template's iteration count may auto-extend; a --max-iterations the operator set is a hard cap.
    [[ -z "${MAX_ITERATIONS_OVERRIDE:-}" ]] && loop_args+=(--auto-extend)
    # W2-07: resolve the alias (opus, sonnet, haiku) through config/models.json. This is the one point where
    # $MODEL, CLAUDE_MODEL and the template values have all been applied.
    build_model=$(models_resolve "$build_model") || return 1
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
    # (absolute: under patch handoff the loop runs in another directory)
    [[ -s "$dod_file" ]] && loop_args+=(--definition-of-done "$(cd "$(dirname "$dod_file")" && pwd)/$(basename "$dod_file")")

    # Checkpoint resume: when pipeline resumed from build-stage checkpoint, pass --resume to loop.
    # Not under patch handoff: each build gets a fresh agent clone, so there is no loop state to resume.
    if [[ "${RESUME_FROM_CHECKPOINT:-false}" == "true" && "${checkpoint_stage:-}" == "build" \
        && "${SW_PATCH_HANDOFF:-true}" == "false" ]]; then
        loop_args+=(--resume)
    fi

    # Skip permissions — pipeline runs headlessly (claude -p) and has no terminal
    # for interactive permission prompts. Without this flag, agents can't write files.
    loop_args+=(--skip-permissions)

    local _attempts
    _attempts=$(_build_tournament_attempts)
    if [[ "$_attempts" -gt 1 && -n "$test_cmd" && "$test_cmd" != "null" ]]; then
        _build_tournament "$enriched_goal" "$test_cmd" "$build_model" "$_attempts" || return 1
    else
        info "Starting build loop: ${DIM}shipwright loop${RESET} (max ${max_iter} iterations, ${agents} agent(s))"

        # Post build start to GitHub
        if [[ -n "$ISSUE_NUMBER" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" "🔨 **Build started** — \`shipwright loop\` with ${max_iter} max iterations, ${agents} agent(s), model: ${build_model}"
        fi

        local _token_log="${ARTIFACTS_DIR}/.claude-tokens-build.log"
        # sw-loop writes its token and USD totals under the git top level of the directory it runs in (a
        # --worktree run's worktree, which PROJECT_ROOT may not name). Drop a previous run's file first, so
        # a loop that dies before writing one adds nothing rather than an old run's spend.
        local _loop_root
        _loop_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_ROOT")"
        local _loop_token_file="${_loop_root}/.claude/loop-logs/loop-tokens.json"
        [[ -f "$_loop_token_file" ]] && rm -f "$_loop_token_file"
        export PIPELINE_JOB_ID="${PIPELINE_NAME:-pipeline-$$}"

        # Patch handoff (#8706): the loop and its agents work in a disposable clone of the recorded base;
        # only a judged patch comes back. Loop logs are read from where the loop ran.
        local _handoff_base="" _handoff_dir="" _loop_logs="${PROJECT_ROOT}/.claude/loop-logs"
        local _progress_file="${PWD}/.claude/loop-logs/progress.md"
        if [[ "${SW_PATCH_HANDOFF:-true}" != "false" ]]; then
            _handoff_base=$(git -C "$PROJECT_ROOT" rev-parse HEAD) || { error "Patch handoff: no base commit"; return 1; }
            _handoff_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-agent.XXXXXX")/repo"
            handoff_prepare "$PROJECT_ROOT" "$_handoff_base" "$_handoff_dir" \
                || { error "Patch handoff: could not prepare the agent clone"; return 1; }
            mkdir -p "$ARTIFACTS_DIR"
            handoff_carry_over "$PROJECT_ROOT" "$_handoff_base" "$_handoff_dir" "${ARTIFACTS_DIR}/pre-build.patch" \
                || { error "Patch handoff: could not move earlier stages' edits into the agent clone"; return 1; }
            [[ -s "${ARTIFACTS_DIR}/pre-build.patch" ]] \
                && warn "Patch handoff: moved uncommitted edits from earlier stages into the agent clone (they are judged with the build)"
            loop_args+=(--repo "$_handoff_dir")
            _loop_logs="${_handoff_dir}/.claude/loop-logs"
            _progress_file="${_loop_logs}/progress.md"
            _loop_token_file="${_loop_logs}/loop-tokens.json"
            info "Patch handoff: agent works in ${DIM}${_handoff_dir}${RESET} (base ${_handoff_base:0:12})"
        fi

        # Run the loop that ships with this pipeline, not whatever `sw` is first on PATH: an older global
        # install there runs an old sw-loop.sh (one that recorded 0 tokens and $0 for every build).
        # SHIPWRIGHT_LOOP_SCRIPT replaces it in tests only.
        _build_run_loop "${SHIPWRIGHT_LOOP_SCRIPT:-$SCRIPT_DIR/sw-loop.sh}" "${loop_args[@]}" < /dev/null 2>"$_token_log" || {
            local _loop_exit=$?
            # A failed build still spent money: count it before returning.
            _pipeline_add_loop_tokens "$_loop_token_file"

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
        if [[ -n "$_handoff_dir" ]]; then
            _build_handoff_return "$_handoff_dir" "$_handoff_base" || return 1
            # The agent clone is gone; its loop logs (with loop-tokens.json) were copied here.
            _loop_token_file="${ARTIFACTS_DIR}/agent-loop-logs/loop-tokens.json"
        fi
        _pipeline_add_loop_tokens "$_loop_token_file"
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
        quality_score=$("$SW_AGENT_EXEC" claude --print --output-format text -p "Rate the quality of these git commit messages on a scale of 0-100. Consider: focus (one thing per commit), clarity (describes the why), atomicity (small logical units). Reply with ONLY a number 0-100.

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
    local test_cmd
    test_cmd=$(_pipeline_test_cmd)
    if [[ -z "$test_cmd" ]]; then
        warn "No test command found — skipping test stage"
        return 0
    fi

    # Spec-first gate (ADR-0015): the locked acceptance tests, restored byte for byte, must pass
    # (fail-to-pass) before the full suite runs (pass-to-pass).
    if ! acceptance_gate "$ARTIFACTS_DIR/test-results.log"; then
        return 1
    fi

    # The suite runs the agent's code: in a disposable sandbox under the OS write jail, never in the
    # trusted checkout (lib/test-sandbox.sh, ADR-0011). Only the exit code and the log come back.
    local sb="" rc=0
    if [[ "$(test_sandbox_mode)" != "off" ]]; then
        sb=$(test_sandbox_open "$PROJECT_ROOT") || {
            error "Test sandbox could not be prepared; tests not run (fail closed)"
            emit_event "test.sandbox_failed" "issue=${ISSUE_NUMBER:-0}" 2>/dev/null || true
            return 1
        }
    fi
    export SW_TEST_JAIL="$sb"
    _stage_test_suite "${sb:-$PROJECT_ROOT}" "$test_cmd" || rc=$?
    unset SW_TEST_JAIL
    test_sandbox_close "$sb"
    return "$rc"
}

# _defang_log — stdin to stdout with anything that could act as a bot marker or end a code fence
# neutralised. Test output is agent-controlled and is posted as the bot account, and
# scripts/ci/bot-comments.sh trusts every bot comment, so a test printing
# "<!-- SHIPWRIGHT-RETRY: 99 -->" would otherwise be read as a real marker.
_defang_log() {
    sed -e 's/<!--/< !--/g' -e 's/-->/-- >/g' \
        -e 's/[Ss][Hh][Ii][Pp][Ww][Rr][Ii][Gg][Hh][Tt]-/SHIPWRIGHT_/g' -e 's/```/` ` `/g'
}

# _stage_test_suite RUN_DIR TEST_CMD — the suite, holdout and mutation runs, with RUN_DIR (the
# sandbox, or the trusted checkout when SW_TEST_SANDBOX=off) as the working directory.
_stage_test_suite() {
    local run_dir="$1" test_cmd="$2"
    local coverage_min
    coverage_min=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.coverage_min) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$coverage_min" || "$coverage_min" == "null" ]] && coverage_min=0

    local test_log="$ARTIFACTS_DIR/test-results.log"

    info "Running tests: ${DIM}$test_cmd${RESET}"
    local test_exit=0
    (cd "$run_dir" && sw_test_gate_run "$test_cmd") > "$test_log" 2>&1 || test_exit=$?

    if [[ "$test_exit" -eq 0 ]]; then
        success "Tests passed"

        # Dark factory: holdout validation — run sealed tests the agent never saw
        if type holdout_validate >/dev/null 2>&1; then
            HOLDOUT_DIR="${ARTIFACTS_DIR}/test-holdout"
            if [[ -f "${HOLDOUT_DIR}/manifest.json" ]]; then
                if holdout_validate "$run_dir" "$test_cmd" 2>/dev/null; then
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
            _changed_files=$(git -C "$run_dir" diff --name-only HEAD~1 2>/dev/null | head -10 || true)
            local _mut_total=0
            while IFS= read -r _mut_file; do
                [[ -z "$_mut_file" || ! -f "$run_dir/$_mut_file" ]] && continue
                local _mc
                _mc=$(cd "$run_dir" && mutation_generate "$_mut_file" "$_mut_dir" 2>/dev/null || echo "0")
                _mut_total=$((_mut_total + _mc))
            done <<< "$_changed_files"
            if [[ "$_mut_total" -gt 0 ]]; then
                info "Mutation testing: $_mut_total mutants generated, executing..."
                local _mut_result
                _mut_result=$(cd "$run_dir" && mutation_execute "$_mut_dir" "$test_cmd" "$run_dir" 2>/dev/null || echo '{}')
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
                log_excerpt="$(_defang_log < "$test_log" 2>/dev/null || true)"
            else
                log_excerpt="$(head -20 "$test_log" 2>/dev/null | _defang_log || true)
... (${log_lines} lines total, showing head + tail) ...
$(tail -30 "$test_log" 2>/dev/null | _defang_log || true)"
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
        test_summary=$(tail -10 "$test_log" | sed 's/\x1b\[[0-9;]*m//g' | _defang_log)
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

