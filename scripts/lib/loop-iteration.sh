#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_ITERATION_LOADED:-}" ]] && return 0
_LOOP_ITERATION_LOADED=1

# ─── Prompt Composition ──────────────────────────────────────────────────────

manage_context_window() {
    local prompt="$1"
    local budget="${CONTEXT_BUDGET_CHARS:-200000}"
    local current_len=${#prompt}

    # Read trimming tunables from config (env > daemon-config > policy > defaults.json)
    local trim_memory_chars trim_git_entries trim_hotspot_files trim_test_lines
    trim_memory_chars=$(_config_get_int "loop.context_trim_memory_chars" 20000 2>/dev/null || echo 20000)
    trim_git_entries=$(_config_get_int "loop.context_trim_git_entries" 10 2>/dev/null || echo 10)
    trim_hotspot_files=$(_config_get_int "loop.context_trim_hotspot_files" 5 2>/dev/null || echo 5)
    trim_test_lines=$(_config_get_int "loop.context_trim_test_lines" 50 2>/dev/null || echo 50)

    if [[ "$current_len" -le "$budget" ]]; then
        echo "$prompt"
        return
    fi

    # Over budget — progressively trim sections (least important first)
    local trimmed="$prompt"

    # 1. Trim DORA/Performance baselines (least critical for code generation)
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk '/^## Performance Baselines/{skip=1; next} skip && /^## [^#]/{skip=0} !skip{print}')
    fi

    # 2. Trim file hotspots to top N
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk -v max="$trim_hotspot_files" '/## File Hotspots/{p=1; c=0} p && /^- /{c++; if(c>max) next} {print}')
    fi

    # 3. Trim git log to last N entries
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk -v max="$trim_git_entries" '/## Recent Git Activity/{p=1; c=0} p && /^[a-f0-9]/{c++; if(c>max) next} {print}')
    fi

    # 4. Truncate memory context to first N chars
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk -v max="$trim_memory_chars" '
            /## Memory Context/{mem=1; skip_rest=0; chars=0; print; next}
            mem && /^## [^#]/{mem=0; print; next}
            mem{chars+=length($0)+1; if(chars>max){print "... (memory truncated for context budget)"; skip_rest=1; mem=0; next}}
            skip_rest && /^## [^#]/{skip_rest=0; print; next}
            skip_rest{next}
            {print}
        ')
    fi

    # 5. Truncate test output to last N lines
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk -v max="$trim_test_lines" '
            /## Test Results/{found=1; buf=""; print; next}
            found && /^## [^#]/{found=0; n=split(buf,arr,"\n"); start=(n>max)?(n-max+1):1; for(i=start;i<=n;i++) if(arr[i]!="") print arr[i]; print; next}
            found{buf=buf $0 "\n"; next}
            {print}
        ')
    fi

    # 6. Last resort: hard truncate with notice
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed="${trimmed:0:$budget}

... [CONTEXT TRUNCATED: prompt exceeded ${budget} char budget. Focus on the goal and most recent errors.]"
    fi

    # Log the trimming
    local final_len=${#trimmed}
    if [[ "$final_len" -lt "$current_len" ]]; then
        warn "Context trimmed from ${current_len} to ${final_len} chars (budget: ${budget})"
        emit_event "loop.context_trimmed" "original=$current_len" "trimmed=$final_len" "budget=$budget" 2>/dev/null || true
    fi

    echo "$trimmed"
}

compose_prompt() {
    local recent_log
    # Get last 3 iteration summaries from log entries
    recent_log="$(echo "$LOG_ENTRIES" | tail -15)"
    if [[ -z "$recent_log" ]]; then
        recent_log="(first iteration — no previous progress)"
    fi

    local git_log
    git_log="$(git_recent_log)"

    local test_section
    if [[ -z "$TEST_CMD" ]]; then
        test_section="No test command configured."
    elif [[ -z "$TEST_PASSED" ]]; then
        test_section="No test results yet (first iteration). Test command: $TEST_CMD"
    elif $TEST_PASSED; then
        test_section="$TEST_OUTPUT"
    else
        test_section="TESTS FAILED — fix these before proceeding:
$TEST_OUTPUT"
    fi

    # Structured error context (machine-readable)
    local error_summary_section=""
    local error_json="$LOG_DIR/error-summary.json"
    if [[ -f "$error_json" ]]; then
        local err_count err_lines
        err_count=$(jq -r '.error_count // 0' "$error_json" 2>/dev/null || echo "0")
        err_lines=$(jq -r '.error_lines[]? // empty' "$error_json" 2>/dev/null | head -10 || true)
        if [[ "$err_count" -gt 0 ]] && [[ -n "$err_lines" ]]; then
            error_summary_section="## Structured Error Summary (${err_count} errors detected)
${err_lines}

Fix these specific errors. Each line above is one distinct error from the test output."
        fi
    fi

    # Build audit sections (captured before heredoc to avoid nested heredoc issues)
    local audit_section
    audit_section="$(compose_audit_section)"
    local audit_feedback_section
    audit_feedback_section="$(compose_audit_feedback_section)"
    local rejection_notice_section
    rejection_notice_section="$(compose_rejection_notice_section)"

    # Memory context injection (failure patterns + past learnings)
    local memory_section=""
    if type memory_inject_context >/dev/null 2>&1; then
        memory_section="$(memory_inject_context "build" 2>/dev/null || true)"
    elif [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
        memory_section="$("$SCRIPT_DIR/sw-memory.sh" inject build 2>/dev/null || true)"
    fi

    # Cross-pipeline discovery injection (learnings from other pipeline runs)
    local discovery_section=""
    if type inject_discoveries >/dev/null 2>&1; then
        local disc_output
        disc_output="$(inject_discoveries "${GOAL:-}" 2>/dev/null || true)"
        if [[ -n "$disc_output" ]]; then
            discovery_section="$disc_output"
        fi
    fi

    # DORA baselines for context
    local dora_section=""
    if type memory_get_dora_baseline >/dev/null 2>&1; then
        local dora_json
        dora_json="$(memory_get_dora_baseline 7 2>/dev/null || echo "{}")"
        local dora_total
        dora_total=$(echo "$dora_json" | jq -r '.total // 0' 2>/dev/null || echo "0")
        if [[ "$dora_total" -gt 0 ]]; then
            local dora_df dora_cfr
            dora_df=$(echo "$dora_json" | jq -r '.deploy_freq // 0' 2>/dev/null || echo "0")
            dora_cfr=$(echo "$dora_json" | jq -r '.cfr // 0' 2>/dev/null || echo "0")
            dora_section="## Performance Baselines (Last 7 Days)
- Deploy frequency: ${dora_df}/week
- Change failure rate: ${dora_cfr}%
- Total pipeline runs: ${dora_total}"
        fi
    fi

    # Append mid-loop memory refresh if available
    local memory_refresh_file="$LOG_DIR/memory-refresh-$(( ITERATION - 1 )).txt"
    if [[ -f "$memory_refresh_file" ]]; then
        memory_section="${memory_section}

## Fresh Context (from iteration $(( ITERATION - 1 )) analysis)
$(cat "$memory_refresh_file")"
    fi

    # GitHub intelligence context (gated by availability)
    local intelligence_section=""
    if [[ "${NO_GITHUB:-}" != "true" ]]; then
        # File hotspots — top 5 most-changed files
        if type gh_file_change_frequency >/dev/null 2>&1; then
            local hotspots
            hotspots=$(gh_file_change_frequency 2>/dev/null | head -5 || true)
            if [[ -n "$hotspots" ]]; then
                intelligence_section="${intelligence_section}
## File Hotspots (most frequently changed)
${hotspots}"
            fi
        fi

        # CODEOWNERS context
        if type gh_codeowners >/dev/null 2>&1; then
            local owners
            owners=$(gh_codeowners 2>/dev/null | head -10 || true)
            if [[ -n "$owners" ]]; then
                intelligence_section="${intelligence_section}
## Code Owners
${owners}"
            fi
        fi

        # Active security alerts
        if type gh_security_alerts >/dev/null 2>&1; then
            local alerts
            alerts=$(gh_security_alerts 2>/dev/null | head -5 || true)
            if [[ -n "$alerts" ]]; then
                intelligence_section="${intelligence_section}
## Active Security Alerts
${alerts}"
            fi
        fi
    fi

    # Architecture rules (from intelligence layer)
    local repo_hash
    repo_hash=$(echo -n "$(pwd)" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local arch_file="${HOME}/.shipwright/memory/${repo_hash}/architecture.json"
    if [[ -f "$arch_file" ]]; then
        local arch_rules
        arch_rules=$(jq -r '.rules[]? // empty' "$arch_file" 2>/dev/null | head -10 || true)
        if [[ -n "$arch_rules" ]]; then
            intelligence_section="${intelligence_section}
## Architecture Rules
${arch_rules}"
        fi
    fi

    # Coverage baseline
    local coverage_file="${HOME}/.shipwright/baselines/${repo_hash}/coverage.json"
    if [[ -f "$coverage_file" ]]; then
        local coverage_pct
        coverage_pct=$(jq -r '.coverage_percent // empty' "$coverage_file" 2>/dev/null || true)
        if [[ -n "$coverage_pct" ]]; then
            intelligence_section="${intelligence_section}
## Coverage Baseline
Current coverage: ${coverage_pct}% — do not decrease this."
        fi
    fi

    # Error classification from last failure
    local error_log=".claude/pipeline-artifacts/error-log.jsonl"
    if [[ -f "$error_log" ]]; then
        local last_error
        last_error=$(tail -1 "$error_log" 2>/dev/null | jq -r '"Type: \(.type), Exit: \(.exit_code), Error: \(.error | split("\n") | first)"' 2>/dev/null || true)
        if [[ -n "$last_error" ]]; then
            intelligence_section="${intelligence_section}
## Last Error Context
${last_error}"
        fi
    fi

    # Stuckness detection — compare last 3 iteration outputs
    local stuckness_section=""
    stuckness_section="$(detect_stuckness)"
    local _stuck_ret=$?
    local stuckness_detected=false
    [[ "$_stuck_ret" -eq 0 ]] && stuckness_detected=true

    # Strategy exploration when stuck — append alternative strategy to GOAL
    if [[ "$stuckness_detected" == "true" ]]; then
        local last_error diagnosis
        last_error=$(tail -1 "${ARTIFACTS_DIR:-${PROJECT_ROOT:-.}/.claude/pipeline-artifacts}/error-log.jsonl" 2>/dev/null | jq -r '"Type: \(.type), Exit: \(.exit_code), Error: \(.error | split("\n") | first)"' 2>/dev/null || true)
        [[ -z "$last_error" || "$last_error" == "null" ]] && last_error="unknown"
        diagnosis="${STUCKNESS_DIAGNOSIS:-}"
        local alt_strategy
        alt_strategy=$(explore_alternative_strategy "$last_error" "${ITERATION:-0}" "$diagnosis")
        GOAL="${GOAL}

${alt_strategy}"

        # Handle model escalation
        if [[ "${ESCALATE_MODEL:-}" == "true" ]]; then
            if [[ -f "$SCRIPT_DIR/sw-model-router.sh" ]]; then
                source "$SCRIPT_DIR/sw-model-router.sh" 2>/dev/null || true
            fi
            if type escalate_model &>/dev/null; then
                MODEL=$(escalate_model "${MODEL:-sonnet}")
                info "Escalated to model: $MODEL"
            fi
            unset ESCALATE_MODEL
        fi
    fi

    # Session restart context — inject intelligent briefing or fallback to progress
    local restart_section=""
    if [[ "$SESSION_RESTART" == "true" ]]; then
        local briefing_file="${ARTIFACTS_DIR:-${LOG_DIR}}/restart-briefing.md"
        if [[ -f "$briefing_file" ]]; then
            # Inject intelligent briefing from session-restart.sh
            restart_section="## Session Restart Briefing
$(cat "$briefing_file")

You are starting a FRESH session after the previous one exhausted its context.
Read the briefing above carefully and continue from where the previous session left off.
Do NOT repeat work already done. Focus on what's failing and what to try next."
        elif [[ -f "$LOG_DIR/progress.md" ]]; then
            # Fallback to basic progress.md
            restart_section="## Previous Session Progress
$(cat "$LOG_DIR/progress.md")

You are starting a FRESH session after the previous one exhausted its iterations.
Read the progress above and continue from where it left off. Do NOT repeat work already done."
        fi
    fi

    # Resume-from-checkpoint context — reconstruct Claude context for meaningful resume
    local resume_section=""
    if [[ -n "${RESUMED_FROM_ITERATION:-}" && "${RESUMED_FROM_ITERATION:-0}" -gt 0 ]]; then
        local _test_tail="  (none recorded)"
        [[ -n "${RESUMED_TEST_OUTPUT:-}" ]] && _test_tail="$(echo "$RESUMED_TEST_OUTPUT" | tail -20)"
        resume_section="## RESUMING FROM ITERATION ${RESUMED_FROM_ITERATION}

Continue from where you left off. Do NOT repeat work already done.

Previous work modified these files:
${RESUMED_MODIFIED:-  (none recorded)}

Previous findings/errors from earlier iterations:
${RESUMED_FINDINGS:-  (none recorded)}

Last test output (fix any failures, tail):
${_test_tail}

---
"
        # Clear after first use so we don't keep injecting on every iteration
        RESUMED_FROM_ITERATION=""
        RESUMED_MODIFIED=""
        RESUMED_FINDINGS=""
        RESUMED_TEST_OUTPUT=""
    fi

    # Build cumulative progress summary showing all iterations' work
    local cumulative_section=""
    if [[ -n "${LOOP_START_COMMIT:-}" ]] && [[ "$ITERATION" -gt 1 ]]; then
        local cum_stat
        cum_stat="$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null | tail -1 || true)"
        if [[ -n "$cum_stat" ]]; then
            cumulative_section="## Cumulative Progress (all iterations combined)
${cum_stat}
"
        fi
    fi

    # Process reward context injection (from process-reward.sh)
    local reward_section=""
    if type process_reward_inject_context >/dev/null 2>&1; then
        reward_section="$(process_reward_inject_context 2>/dev/null || true)"
    fi

    # RL optimizer context injection (from rl-optimizer.sh, Phase 7)
    local rl_section=""
    if type rl_compose_prompt_section >/dev/null 2>&1; then
        rl_section="$(rl_compose_prompt_section 2>/dev/null || true)"
    fi

    # Autoresearch RL Phase 8: policy and reward feedback injection
    local policy_section=""
    if type policy_inject_into_prompt >/dev/null 2>&1; then
        policy_section="$(policy_inject_into_prompt 2>/dev/null || true)"
    fi
    local reward_feedback=""
    if type reward_inject_feedback >/dev/null 2>&1; then
        reward_feedback="$(reward_inject_feedback 2>/dev/null || true)"
    fi

    # Auto-recovery hint injection (from auto-recovery.sh)
    local recovery_section=""
    if [[ -n "${RECOVERY_HINT:-}" ]]; then
        recovery_section="## Auto-Recovery Guidance
${RECOVERY_HINT}
"
    fi
    if [[ -n "${RECOVERY_ESCALATED_MODEL:-}" ]]; then
        MODEL="${RECOVERY_ESCALATED_MODEL}"
        info "Model escalated to: ${MODEL} (auto-recovery)"
    fi

    cat <<PROMPT
You are an autonomous coding agent on iteration ${ITERATION}/${MAX_ITERATIONS} of a continuous loop.
${resume_section}
${recovery_section}
## Your Goal
${GOAL}

${cumulative_section}
## Current Progress
${recent_log}

## Recent Git Activity
${git_log}

## Test Results (Previous Iteration)
${test_section}

${error_summary_section:+$error_summary_section
}
${memory_section:+## Memory Context
$memory_section
}
${discovery_section:+## Cross-Pipeline Learnings
$discovery_section
}
${reward_section:+$reward_section
}
${rl_section:+$rl_section
}
${policy_section:+$policy_section
}
${reward_feedback:+$reward_feedback
}
${dora_section:+$dora_section
}
${intelligence_section:+$intelligence_section
}
${restart_section:+$restart_section
}
## Instructions
1. Read the codebase and understand the current state
2. Identify the highest-priority remaining work toward the goal
3. Implement ONE meaningful chunk of progress
4. Run tests if a test command exists: ${TEST_CMD:-"(none)"}
5. Commit your work with a descriptive message
6. When the goal is FULLY achieved, output exactly: LOOP_COMPLETE

## Context Efficiency
- Batch independent tool calls in parallel — avoid sequential round-trips
- Use targeted file reads (offset/limit) instead of reading entire large files
- Delegate large searches to subagents — only import the summary
- Filter tool results with grep/jq before reasoning over them
- Keep working memory lean — summarize completed steps, don't preserve full outputs

${audit_section}

${audit_feedback_section}

${rejection_notice_section}

${stuckness_section}

## Rules
- Focus on ONE task per iteration — do it well
- Always commit with descriptive messages
- If tests fail, fix them before ending
- If stuck on the same issue for 2+ iterations, try a different approach
- Do NOT output LOOP_COMPLETE unless the goal is genuinely achieved
PROMPT
}

# ─── Alternative Strategy Exploration ─────────────────────────────────────────

explore_alternative_strategy() {
    local last_error="${1:-unknown}"
    local iteration="${2:-0}"
    local diagnosis="${3:-}"

    # Track attempted strategies to avoid repeating them
    local strategy_file="${LOG_DIR:-/tmp}/strategy-attempts.txt"
    local attempted
    attempted=$(cat "$strategy_file" 2>/dev/null || true)

    local strategy=""

    # If quality gates are passing but evaluators disagree, suggest focusing on evaluator alignment
    if [[ "${TEST_PASSED:-}" == "true" ]] && [[ "${QUALITY_GATE_PASSED:-}" == "true" || "${AUDIT_RESULT:-}" == "pass" ]]; then
        if ! echo "$attempted" | grep -q "evaluator_alignment"; then
            echo "evaluator_alignment" >> "$strategy_file"
            strategy="## Alternative Strategy: Evaluator Alignment
The code appears functionally complete (tests pass). Focus on satisfying the remaining
quality gate evaluators. Check the DoD log and audit log for specific complaints, then
address those exact points rather than adding new features."
        fi
    fi

    # If no code changes in last iteration, suggest verifying existing work
    if echo "$last_error" | grep -qi "no code changes" || [[ "$diagnosis" == *"no code"* ]]; then
        if ! echo "$attempted" | grep -q "verify_existing"; then
            echo "verify_existing" >> "$strategy_file"
            strategy="## Alternative Strategy: Verify Existing Work
Recent iterations made no code changes. The work may already be complete.
Run the full test suite, verify all features work, and if everything passes,
commit a verification message and declare LOOP_COMPLETE with evidence."
        fi
    fi

    # Generic fallback: break the problem down
    if [[ -z "$strategy" ]]; then
        if ! echo "$attempted" | grep -q "decompose"; then
            echo "decompose" >> "$strategy_file"
            strategy="## Alternative Strategy: Decompose
Break the remaining work into smaller, independent steps. Focus on one specific
file or function at a time. Read error messages literally — the root cause may
differ from your assumption."
        fi
    fi

    echo "$strategy"
}

# ─── Claude Execution ────────────────────────────────────────────────────────

build_claude_flags() {
    local flags=()
    flags+=("--model" "$MODEL")
    flags+=("--output-format" "json")

    if $SKIP_PERMISSIONS; then
        flags+=("--dangerously-skip-permissions")
    fi

    if [[ -n "$MAX_TURNS" ]]; then
        flags+=("--max-turns" "$MAX_TURNS")
    fi

    if [[ -n "${EFFORT_LEVEL:-}" ]]; then
        flags+=("--effort" "$EFFORT_LEVEL")
    fi

    # Only add fallback-model if it differs from primary (Claude CLI rejects same model)
    if [[ -n "${FALLBACK_MODEL:-}" ]] && [[ "${FALLBACK_MODEL}" != "$MODEL" ]]; then
        flags+=("--fallback-model" "$FALLBACK_MODEL")
    fi

    # Keep the cached prompt prefix stable across iterations. The per-machine
    # sections (cwd, env info, memory paths, git status) sit at the FRONT of the
    # system prompt, and prompt caching is a prefix match — so git status
    # changing between iterations, which it does constantly during a build loop,
    # invalidated everything after it. This moves them into the first user
    # message instead. The CLI ignores the flag when a custom --system-prompt is
    # in play, which this loop does not pass.
    if [[ "${LOOP_STABLE_PROMPT_PREFIX:-true}" == "true" ]]; then
        flags+=("--exclude-dynamic-system-prompt-sections")
    fi

    # Session continuity: reuse one session across iterations so the loop stops
    # paying a cold start (and a fresh cache write) every time. LOOP_SESSION_ID
    # is only set when continuity is enabled — see sw-loop.sh — and is
    # regenerated on a deliberate session restart so context-exhaustion recovery
    # still gets the clean slate it depends on.
    if [[ -n "${LOOP_SESSION_ID:-}" ]]; then
        flags+=("--session-id" "$LOOP_SESSION_ID")
    fi

    echo "${flags[*]}"
}

run_claude_iteration() {
    local log_file="$LOG_DIR/iteration-${ITERATION}.log"
    local json_file="$LOG_DIR/iteration-${ITERATION}.json"
    local prompt
    prompt="$(compose_prompt)"

    # Context budget monitoring and proactive trimming (issue #209)
    local budget_estimate=""
    local budget_status=""
    if type context_budget_estimate >/dev/null 2>&1; then
        budget_estimate=$(context_budget_estimate "$prompt" "${ARTIFACTS_DIR:-./.claude/pipeline-artifacts}" 2>/dev/null || echo "{}")
        if [[ -n "$budget_estimate" ]]; then
            budget_status=$(context_budget_check "$budget_estimate" 2>/dev/null || echo "{}")
            local status_val=$(echo "$budget_status" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

            # Log budget state
            if type context_budget_log_state >/dev/null 2>&1; then
                context_budget_log_state "$budget_estimate" "$budget_status" "${ARTIFACTS_DIR:-./.claude/pipeline-artifacts}" 2>/dev/null || true
            fi

            # Warn if approaching limits
            if [[ "$status_val" == "yellow" ]] || [[ "$status_val" == "red" ]] || [[ "$status_val" == "critical" ]]; then
                local msg=$(echo "$budget_status" | jq -r '.message // "context budget alert"' 2>/dev/null || echo "")
                if [[ -n "$msg" ]]; then
                    warn "$msg"
                fi
            fi
        fi
    fi

    local final_prompt
    final_prompt=$(manage_context_window "$prompt")

    # Apply proactive trimming if budget is tight
    if [[ -n "$budget_status" ]]; then
        local action=$(echo "$budget_status" | jq -r '.action // "continue"' 2>/dev/null || echo "continue")
        if [[ "$action" != "continue" ]] && type context_budget_trim >/dev/null 2>&1; then
            local trim_status=$(echo "$budget_status" | jq -r '.status // "green"' 2>/dev/null || echo "green")
            final_prompt=$(context_budget_trim "$final_prompt" "$trim_status" 200000 2>/dev/null || echo "$final_prompt")
        fi
    fi

    local raw_prompt_chars=${#prompt}
    local prompt_chars=${#final_prompt}
    local approx_tokens=$((prompt_chars / 4))
    info "Prompt: ~${approx_tokens} tokens (${prompt_chars} chars)"

    # Audit: save full prompt to disk for traceability
    if type audit_save_prompt >/dev/null 2>&1; then
        audit_save_prompt "$final_prompt" "$ITERATION" || true
    fi
    if type audit_emit >/dev/null 2>&1; then
        audit_emit "loop.prompt" "iteration=$ITERATION" "chars=$prompt_chars" \
            "raw_chars=$raw_prompt_chars" "path=iteration-${ITERATION}.prompt.txt" || true
    fi

    # Emit context efficiency metrics
    if type emit_event >/dev/null 2>&1; then
        local trim_ratio=0
        local budget_utilization=0
        if [[ "$raw_prompt_chars" -gt 0 ]]; then
            trim_ratio=$(awk -v raw="$raw_prompt_chars" -v trimmed="$prompt_chars" \
                'BEGIN { printf "%.1f", ((raw - trimmed) / raw) * 100 }')
        fi
        if [[ "${CONTEXT_BUDGET_CHARS:-0}" -gt 0 ]]; then
            budget_utilization=$(awk -v used="$prompt_chars" -v budget="${CONTEXT_BUDGET_CHARS}" \
                'BEGIN { printf "%.1f", (used / budget) * 100 }')
        fi
        emit_event "loop.context_efficiency" \
            "iteration=$ITERATION" \
            "raw_prompt_chars=$raw_prompt_chars" \
            "trimmed_prompt_chars=$prompt_chars" \
            "trim_ratio=$trim_ratio" \
            "budget_utilization=$budget_utilization" \
            "budget_chars=${CONTEXT_BUDGET_CHARS:-0}" \
            "job_id=${PIPELINE_JOB_ID:-loop-$$}" 2>/dev/null || true
    fi

    local flags
    flags="$(build_claude_flags)"

    local iter_start
    iter_start="$(now_epoch)"

    echo -e "\n${CYAN}${BOLD}▸${RESET} ${BOLD}Iteration ${ITERATION}/${MAX_ITERATIONS}${RESET} — Starting..."

    # Run Claude headless (with timeout + PID capture for signal handling)
    # Output goes to .json first, then we extract text into .log for compat
    local exit_code=0
    # shellcheck disable=SC2086
    local err_file="${json_file%.json}.stderr"
    if [[ -n "$TIMEOUT_CMD" ]]; then
        $TIMEOUT_CMD "$CLAUDE_TIMEOUT" claude -p "$final_prompt" $flags > "$json_file" 2>"$err_file" &
    else
        claude -p "$final_prompt" $flags > "$json_file" 2>"$err_file" &
    fi
    CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null || exit_code=$?
    CHILD_PID=""
    if [[ "$exit_code" -eq 124 ]]; then
        warn "Claude CLI timed out after ${CLAUDE_TIMEOUT}s"
    fi

    # Extract text result from JSON into .log for backwards compatibility
    # With --output-format json, stdout is a JSON array; .[-1].result has the text
    _extract_text_from_json "$json_file" "$log_file" "$err_file"

    local iter_end
    iter_end="$(now_epoch)"
    local iter_duration=$(( iter_end - iter_start ))

    echo -e "  ${GREEN}✓${RESET} Claude session completed ($(format_duration "$iter_duration"), exit $exit_code)"

    # Accumulate token usage from this iteration's JSON output
    accumulate_loop_tokens "$json_file"

    # Audit: record response metadata
    if type audit_emit >/dev/null 2>&1; then
        local response_chars=0
        [[ -f "$log_file" ]] && response_chars=$(wc -c < "$log_file" | tr -d ' ')
        audit_emit "loop.response" "iteration=$ITERATION" "chars=$response_chars" \
            "exit_code=$exit_code" "duration_s=$iter_duration" \
            "path=iteration-${ITERATION}.json" || true
    fi

    # Context budget: record iteration summary for context compression (issue #209)
    if type context_budget_summarize_iteration >/dev/null 2>&1; then
        # Extract test result from log or TEST_PASSED variable
        local test_result="${TEST_OUTPUT:-}"
        [[ -z "$test_result" && -n "${TEST_PASSED:-}" ]] && test_result=$([ "$TEST_PASSED" = true ] && echo "PASSED" || echo "FAILED")
        context_budget_summarize_iteration "$ITERATION" "$log_file" "$test_result" "${ARTIFACTS_DIR:-./.claude/pipeline-artifacts}" 2>/dev/null || true
    fi

    # Show verbose output if requested
    if $VERBOSE; then
        echo -e "  ${DIM}─── Claude Output ───${RESET}"
        sed 's/^/  /' "$log_file" | head -100
        echo -e "  ${DIM}─────────────────────${RESET}"
    fi

    return $exit_code
}

# ─── Iteration Summary Extraction ────────────────────────────────────────────

extract_summary() {
    local log_file="$1"
    # Grab last meaningful lines from Claude output, skipping empty lines
    local summary
    summary="$(grep -v '^$' "$log_file" | tail -5 | head -3 2>/dev/null || echo "(no output)")"
    # Truncate long lines
    summary="$(echo "$summary" | cut -c1-120)"

    # Sanitize: if summary is just a CLI/API error, replace with generic text
    if echo "$summary" | grep -qiE 'Invalid API key|authentication_error|rate_limit|API key expired|ANTHROPIC_API_KEY'; then
        summary="(CLI error — no useful output this iteration)"
    fi

    echo "$summary"
}

# ─── Adaptive Model Selection ────────────────────────────────────────────────
# Uses intelligence engine when available, falls back to defaults.
select_adaptive_model() {
    local role="${1:-build}"
    local default_model="${2:-opus}"
    # If user explicitly set --model, respect it
    if [[ "$default_model" != "${SW_MODEL:-opus}" ]]; then
        echo "$default_model"
        return 0
    fi
    # Read learned model routing
    local _routing_file="${HOME}/.shipwright/optimization/model-routing.json"
    if [[ -f "$_routing_file" ]] && command -v jq >/dev/null 2>&1; then
        local _routed_model
        _routed_model=$(jq -r --arg r "$role" '.routes[$r].model // ""' "$_routing_file" 2>/dev/null) || true
        if [[ -n "${_routed_model:-}" && "${_routed_model:-}" != "null" ]]; then
            echo "${_routed_model}"
            return 0
        fi
    fi

    # Try intelligence-based recommendation
    if type intelligence_recommend_model >/dev/null 2>&1; then
        local rec
        rec=$(intelligence_recommend_model "$role" "${COMPLEXITY:-5}" "${BUDGET:-0}" 2>/dev/null || echo "")
        if [[ -n "$rec" ]]; then
            local recommended
            recommended=$(echo "$rec" | jq -r '.model // ""' 2>/dev/null || echo "")
            if [[ -n "$recommended" && "$recommended" != "null" ]]; then
                echo "$recommended"
                return 0
            fi
        fi
    fi
    echo "$default_model"
}

# Select audit/DoD model — uses haiku if success rate is high enough, else sonnet
select_audit_model() {
    local default_model
    default_model=$(_smart_model "audit" "haiku")
    local opt_file="$HOME/.shipwright/optimization/audit-tuning.json"
    if [[ -f "$opt_file" ]] && command -v jq >/dev/null 2>&1; then
        local success_rate
        success_rate=$(jq -r '.haiku_success_rate // 100' "$opt_file" 2>/dev/null || echo "100")
        if [[ "${success_rate%%.*}" -lt 90 ]]; then
            echo "sonnet"
            return 0
        fi
    fi
    echo "$default_model"
}

# ─── Timing Helpers ───────────────────────────────────────────────────────────
format_duration() {
    local secs="$1"
    local mins=$(( secs / 60 ))
    local remaining_secs=$(( secs % 60 ))
    if [[ $mins -gt 0 ]]; then
        printf "%dm %ds" "$mins" "$remaining_secs"
    else
        printf "%ds" "$remaining_secs"
    fi
}

# ─── Git Helpers ──────────────────────────────────────────────────────────────
git_commit_count() {
    git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null || echo 0
}

git_recent_log() {
    git -C "$PROJECT_ROOT" log --oneline -20 2>/dev/null || echo "(no commits)"
}

git_diff_stat() {
    git -C "$PROJECT_ROOT" diff --stat HEAD~1 2>/dev/null | tail -1 || echo ""
}

git_auto_commit() {
    local work_dir="${1:-$PROJECT_ROOT}"
    # Only commit if there are changes
    if git -C "$work_dir" diff --quiet && git -C "$work_dir" diff --cached --quiet; then
        # Check for untracked files
        local untracked
        untracked="$(git -C "$work_dir" ls-files --others --exclude-standard | head -1)"
        if [[ -z "$untracked" ]]; then
            return 1  # Nothing to commit
        fi
    fi

    git -C "$work_dir" add -A 2>/dev/null || true

    # Semantic validation before commit — skip commit if validation fails
    if ! validate_claude_output "$work_dir"; then
        warn "Validation failed — skipping commit for this iteration"
        git -C "$work_dir" reset --hard HEAD 2>/dev/null || true
        return 1
    fi

    git -C "$work_dir" commit -m "loop: iteration $ITERATION — autonomous progress" --no-verify 2>/dev/null || return 1
    return 0
}

# ─── Audit Prompt Sections ────────────────────────────────────────────────────
compose_audit_section() {
    if ! $AUDIT_ENABLED; then
        return
    fi

    # Try to inject audit items from past review feedback in memory
    local memory_audit_items=""
    if [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
        local mem_dir_path
        mem_dir_path="$HOME/.shipwright/memory"
        # Look for review feedback in any repo memory
        local repo_hash_val
        repo_hash_val=$(git config --get remote.origin.url 2>/dev/null | shasum -a 256 2>/dev/null | cut -c1-12 || echo "")
        if [[ -n "$repo_hash_val" && -f "$mem_dir_path/$repo_hash_val/failures.json" ]]; then
            memory_audit_items=$(jq -r '.failures[] | select(.stage == "review" and .pattern != "") |
                "- Check for: \(.pattern[:100])"' \
                "$mem_dir_path/$repo_hash_val/failures.json" 2>/dev/null | head -5 || true)
        fi
    fi

    echo "## Self-Audit Checklist"
    echo "Before declaring LOOP_COMPLETE, critically evaluate your own work:"
    echo "1. Does the implementation FULLY satisfy the goal, not just partially?"
    echo "2. Are there any edge cases you haven't handled?"
    echo "3. Did you leave any TODO, FIXME, HACK, or XXX comments in new code?"
    echo "4. Are all new functions/modules tested (if a test command exists)?"
    echo "5. Would a code reviewer approve this, or would they request changes?"
    echo "6. Is the code clean, well-structured, and following project conventions?"
    if [[ -n "$memory_audit_items" ]]; then
        echo ""
        echo "Common review findings from this repo's history:"
        echo "$memory_audit_items"
    fi
    echo ""
    echo "If ANY answer is \"no\", do NOT output LOOP_COMPLETE. Instead, fix the issues first."
}

compose_audit_feedback_section() {
    if [[ -z "$AUDIT_RESULT" ]] || [[ "$AUDIT_RESULT" == "pass" ]]; then
        return
    fi
    cat <<AUDIT_FEEDBACK
## Audit Feedback (Previous Iteration)
An independent audit of your last iteration found these issues:
${AUDIT_RESULT}

Address ALL audit findings before proceeding with new work.
AUDIT_FEEDBACK
}

compose_rejection_notice_section() {
    if ! $COMPLETION_REJECTED; then
        return
    fi
    COMPLETION_REJECTED=false
    cat <<'REJECTION'
## ⚠ Completion Rejected
Your previous LOOP_COMPLETE was REJECTED because quality gates did not pass.
Review the audit feedback and test results above, fix the issues, then try again.
Do NOT output LOOP_COMPLETE until all quality checks pass.
REJECTION
}

# ─── Main: Single-Agent Loop ──────────────────────────────────────────────────
run_single_agent_loop() {
    # Save original environment variables before loop starts
    local SAVED_CLAUDE_MODEL="${CLAUDE_MODEL:-}"
    local SAVED_ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

    # One session ID per entry; see loop_session_init (#816).
    loop_session_init

    if [[ "$SESSION_RESTART" == "true" ]]; then
        # Restart: state already reset by run_loop_with_restarts, skip init
        # Restore environment variables for clean iteration state
        [[ -n "$SAVED_CLAUDE_MODEL" ]] && export CLAUDE_MODEL="$SAVED_CLAUDE_MODEL"
        # Reset context exhaustion counter for this session (it tracks restarts WITHIN a single session)
        CONTEXT_RESTART_COUNT=0
        info "Session restart ${RESTART_COUNT}/${MAX_RESTARTS} — fresh context, reading progress"
    elif $RESUME; then
        resume_state
    else
        initialize_state
    fi

    # Ensure LOOP_START_COMMIT is set (may not be on resume/restart)
    if [[ -z "${LOOP_START_COMMIT:-}" ]]; then
        LOOP_START_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")"
    fi

    # Apply adaptive budget/model before showing banner
    apply_adaptive_budget
    MODEL="$(select_adaptive_model "build" "$MODEL")"

    # Track applied memory fix patterns for outcome recording
    _applied_fix_pattern=""
    STUCKNESS_COUNT=0
    STUCKNESS_TRACKING_FILE="$LOG_DIR/stuckness-tracking.txt"
    : > "$STUCKNESS_TRACKING_FILE" 2>/dev/null || true
    : > "${LOG_DIR}/strategy-attempts.txt" 2>/dev/null || true

    show_banner

    while true; do
        # Reset environment variables at start of each iteration
        # Prevents previous iterations from affecting model selection or API keys
        [[ -n "$SAVED_CLAUDE_MODEL" ]] && export CLAUDE_MODEL="$SAVED_CLAUDE_MODEL"
        [[ -n "$SAVED_ANTHROPIC_API_KEY" ]] && export ANTHROPIC_API_KEY="$SAVED_ANTHROPIC_API_KEY"

        # Pre-checks (before incrementing — ITERATION tracks completed count)
        check_circuit_breaker || break
        check_max_iterations || break
        check_budget_gate || {
            STATUS="budget_exhausted"
            write_state
            write_progress
            error "Budget exhausted — stopping pipeline"
            show_summary
            return 1
        }
        ITERATION=$(( ITERATION + 1 ))

        # Emit iteration start event for pipeline visibility
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.iteration_start" \
                "iteration=$ITERATION" \
                "max=$MAX_ITERATIONS" \
                "job_id=${PIPELINE_JOB_ID:-loop-$$}" \
                "agent=${AGENT_NUM:-1}" \
                "test_passed=${TEST_PASSED:-unknown}"
        fi

        # Root-cause diagnosis and memory-based fix on retry after test failure
        if [[ "${TEST_PASSED:-}" == "false" ]]; then
            # Source memory module for diagnosis and fix lookup
            [[ -f "$SCRIPT_DIR/sw-memory.sh" ]] && source "$SCRIPT_DIR/sw-memory.sh" 2>/dev/null || true

            # Capture failure for memory (enables memory_analyze_failure and future fix lookup)
            if type memory_capture_failure &>/dev/null && [[ -n "${TEST_OUTPUT:-}" ]]; then
                memory_capture_failure "test" "$TEST_OUTPUT" 2>/dev/null || true
            fi

            # Pattern-based diagnosis (no Claude needed) — inject into goal for smarter retry
            local _changed_files=""
            _changed_files=$(git diff --name-only HEAD 2>/dev/null | head -50 | tr '\n' ',' | sed 's/,$//')
            local _diagnosis
            _diagnosis=$(diagnose_failure "${TEST_OUTPUT:-}" "$_changed_files" "$ITERATION" 2>/dev/null || true)

            if [[ -n "$_diagnosis" ]]; then
                GOAL="${GOAL}

${_diagnosis}"
                info "Failure diagnosis injected (classification from error pattern)"
            fi

            # Memory-based fix suggestion (from past successful fixes)
            local _last_error=""
            local _prev_log="$LOG_DIR/iteration-$(( ITERATION - 1 )).log"
            if [[ -f "$_prev_log" ]]; then
                _last_error=$(tail -20 "$_prev_log" 2>/dev/null | grep -iE '(error|fail|exception)' | head -1 || true)
            fi
            [[ -z "$_last_error" ]] && _last_error=$(echo "${TEST_OUTPUT:-}" | head -3 | tr '\n' ' ')
            local _fix_suggestion=""
            if type memory_closed_loop_inject >/dev/null 2>&1 && [[ -n "${_last_error:-}" ]]; then
                _fix_suggestion=$(memory_closed_loop_inject "$_last_error" 2>/dev/null) || true
            fi
            if [[ -n "${_fix_suggestion:-}" ]]; then
                _applied_fix_pattern="${_last_error}"
                GOAL="KNOWN FIX (from past success): ${_fix_suggestion}

${GOAL}"
                info "Memory fix injected: ${_fix_suggestion:0:80}"
                # Track memory injection for effectiveness measurement
                if type memeff_on_injection >/dev/null 2>&1; then
                    memeff_on_injection "closed_loop_fix" "${PIPELINE_JOB_ID:-$$}" "build" 2>/dev/null || true
                fi
            fi

            # Analyze failure via Claude (background, non-blocking) for richer root_cause/fix in memory
            if type memory_analyze_failure &>/dev/null && [[ "${INTELLIGENCE_ENABLED:-auto}" != "false" ]]; then
                local _test_log="${TEST_LOG_FILE:-$LOG_DIR/tests-iter-$(( ITERATION - 1 )).log}"
                if [[ -f "$_test_log" ]]; then
                    memory_analyze_failure "$_test_log" "test" 2>/dev/null &
                fi
            fi
        fi

        # Run Claude
        local exit_code=0
        run_claude_iteration || exit_code=$?

        local log_file="$LOG_DIR/iteration-${ITERATION}.log"

        # Record iteration data for stuckness detection (diff hash, error hash, exit code)
        record_iteration_stuckness_data "$exit_code"

        # Dark factory: score this iteration with process reward model
        if type process_reward_score_iteration >/dev/null 2>&1; then
            process_reward_score_iteration "$PROJECT_ROOT" "${TEST_OUTPUT:-}" "$ITERATION" 2>/dev/null || true
        fi

        # Detect fatal CLI errors (API key, auth, network) — abort immediately
        if check_fatal_error "$log_file" "$exit_code"; then
            STATUS="error"
            write_state
            write_progress
            error "Fatal CLI error detected — aborting loop (see iteration log)"
            show_summary
            return 1
        fi

        # Detect context exhaustion and trigger intelligent restart
        local log_content=""
        [[ -f "$log_file" ]] && log_content=$(cat "$log_file" 2>/dev/null || true)
        local stderr_file="${LOG_DIR}/iteration-${ITERATION}.stderr"
        local stderr_content=""
        [[ -f "$stderr_file" ]] && stderr_content=$(cat "$stderr_file" 2>/dev/null || true)

        if echo "${log_content}${stderr_content}" | grep -qiE "$CONTEXT_EXHAUSTION_PATTERNS" 2>/dev/null; then
            if [[ "${CONTEXT_RESTART_COUNT:-0}" -lt "${CONTEXT_RESTART_LIMIT:-2}" ]]; then
                CONTEXT_RESTART_COUNT=$(( CONTEXT_RESTART_COUNT + 1 ))
                STATUS="context_exhaustion_restart"
                write_state
                write_progress
                warn "Context exhaustion detected (iteration $ITERATION) — triggering intelligent restart ($CONTEXT_RESTART_COUNT/$CONTEXT_RESTART_LIMIT)"
                if type emit_event >/dev/null 2>&1; then
                    emit_event "loop.context_exhaustion" "iteration=$ITERATION" "restart_count=$CONTEXT_RESTART_COUNT" "max_restarts=$MAX_RESTARTS"
                fi
                break
            else
                warn "Context exhaustion detected but restart limit ($CONTEXT_RESTART_LIMIT) reached"
                STATUS="context_exhaustion_fatal"
                write_state
                write_progress
            fi
        fi

        # Mid-loop memory refresh — re-query with current error context after iteration 3
        if [[ "$ITERATION" -ge 3 ]] && type memory_inject_context >/dev/null 2>&1; then
            local refresh_ctx
            refresh_ctx=$(tail -20 "$log_file" 2>/dev/null || true)
            if [[ -n "$refresh_ctx" ]]; then
                local refreshed_memory
                refreshed_memory=$(memory_inject_context "build" "$refresh_ctx" 2>/dev/null | head -5 || true)
                if [[ -n "$refreshed_memory" ]]; then
                    # Append to next iteration's memory context
                    local memory_refresh_file="$LOG_DIR/memory-refresh-${ITERATION}.txt"
                    echo "$refreshed_memory" > "$memory_refresh_file"
                    # Track memory injection for effectiveness measurement
                    if type memeff_on_injection >/dev/null 2>&1; then
                        memeff_on_injection "context_refresh" "${PIPELINE_JOB_ID:-$$}" "build" 2>/dev/null || true
                    fi
                fi
            fi
        fi

        # Auto-commit if Claude didn't
        local commits_before
        commits_before="$(git_commit_count)"
        git_auto_commit "$PROJECT_ROOT" || true
        local commits_after
        commits_after="$(git_commit_count)"
        local new_commits=$(( commits_after - commits_before ))
        TOTAL_COMMITS=$(( TOTAL_COMMITS + new_commits ))

        # Git diff stats
        local diff_stat
        diff_stat="$(git_diff_stat)"
        if [[ -n "$diff_stat" ]]; then
            echo -e "  ${GREEN}✓${RESET} Git: $diff_stat"
        fi

        # Track velocity for adaptive extension budget
        track_iteration_velocity

        # Test gate
        run_test_gate
        write_error_summary
        if [[ -n "$TEST_CMD" ]]; then
            if [[ "$TEST_PASSED" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Tests: passed"
            else
                echo -e "  ${RED}✗${RESET} Tests: failed"
            fi
        fi

        # Dark factory: update RL weights based on test outcome
        if type rl_update_weights >/dev/null 2>&1; then
            if [[ "${TEST_PASSED:-}" == "true" ]]; then
                rl_update_weights "success" 2>/dev/null || true
            elif [[ "${TEST_PASSED:-}" == "false" ]]; then
                rl_update_weights "failure" 2>/dev/null || true
            fi
        fi

        # Track fix outcome for memory effectiveness
        if [[ -n "${_applied_fix_pattern:-}" ]]; then
            if type memory_record_fix_outcome >/dev/null 2>&1; then
                if [[ "${TEST_PASSED:-}" == "true" ]]; then
                    memory_record_fix_outcome "$_applied_fix_pattern" "true" "true" 2>/dev/null || true
                else
                    memory_record_fix_outcome "$_applied_fix_pattern" "true" "false" 2>/dev/null || true
                fi
            fi
            _applied_fix_pattern=""
        fi

        # Save Claude context for checkpoint resume (goal, findings, test output)
        export SW_LOOP_GOAL="$GOAL"
        export SW_LOOP_ITERATION="$ITERATION"
        export SW_LOOP_STATUS="${STATUS:-running}"
        export SW_LOOP_TEST_OUTPUT="${TEST_OUTPUT:-}"
        export SW_LOOP_FINDINGS="${LOG_ENTRIES:-}"
        # shellcheck disable=SC2155
        export SW_LOOP_MODIFIED="$(git diff --name-only HEAD 2>/dev/null | head -50 | tr '\n' ',' | sed 's/,$//')"
        "$SCRIPT_DIR/sw-checkpoint.sh" save-context --stage build 2>/dev/null || true

        # Audit agent (reviews implementer's work)
        run_audit_agent

        # Verification gap detection: audit failed but tests passed
        handle_verification_gap

        # Auto-commit any remaining changes before quality gates
        # (audit agent, verification handler, or test evidence may create files)
        if ! git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null || \
           ! git -C "$PROJECT_ROOT" diff --cached --quiet 2>/dev/null || \
           [[ -n "$(git -C "$PROJECT_ROOT" ls-files --others --exclude-standard 2>/dev/null | head -1)" ]]; then
            git -C "$PROJECT_ROOT" add -A 2>/dev/null || true
            git -C "$PROJECT_ROOT" commit -m "loop: iteration $ITERATION — post-audit cleanup" --no-verify 2>/dev/null || true
        fi

        # Quality gates (automated checks)
        run_quality_gates

        # Convergence detection (issue #203) — score iteration progress and detect convergence
        if type convergence_integrate >/dev/null 2>&1; then
            local conv_exit=0
            convergence_integrate || conv_exit=$?
            case "$conv_exit" in
                1)
                    # Converged — stop successfully
                    info "Build loop converged — stopping"
                    STATUS="complete"
                    write_state
                    write_progress
                    show_summary
                    return 0
                    ;;
                2)
                    # Diverging — stop with failure
                    warn "Build loop diverging — stopping (scores declining consistently)"
                    STATUS="diverging"
                    write_state
                    write_progress
                    show_summary
                    return 1
                    ;;
                3)
                    # Oscillating — escalate to manual review
                    warn "Build loop oscillating — consider manual review or model escalation"
                    ;;
            esac
        fi

        # Guarded completion (replaces naive grep check)
        if guard_completion; then
            STATUS="complete"
            write_state
            write_progress
            show_summary
            return 0
        fi

        # Check progress (circuit breaker)
        if check_progress; then
            CONSECUTIVE_FAILURES=0
            # Reset auto-recovery state on progress (tests passing, code advancing)
            if type recovery_reset >/dev/null 2>&1; then
                recovery_reset
            fi
            echo -e "  ${GREEN}✓${RESET} Progress detected — continuing"
        else
            CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
            echo -e "  ${YELLOW}⚠${RESET} Low progress (${CONSECUTIVE_FAILURES}/${CIRCUIT_BREAKER_THRESHOLD} before circuit breaker)"
        fi

        # Extract summary and update state
        local summary
        summary="$(extract_summary "$log_file")"
        append_log_entry "### Iteration $ITERATION ($(now_iso))
$summary
"
        write_state
        write_progress

        # Emit iteration complete event for pipeline visibility
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.iteration_complete" \
                "iteration=$ITERATION" \
                "max=$MAX_ITERATIONS" \
                "job_id=${PIPELINE_JOB_ID:-loop-$$}" \
                "agent=${AGENT_NUM:-1}" \
                "test_passed=${TEST_PASSED:-unknown}" \
                "commits=$TOTAL_COMMITS" \
                "status=${STATUS:-running}"
        fi

        # Update heartbeat
        "$SCRIPT_DIR/sw-heartbeat.sh" write "${PIPELINE_JOB_ID:-loop-$$}" \
            --pid $$ \
            --stage "build" \
            --iteration "$ITERATION" \
            --activity "Loop iteration $ITERATION" 2>/dev/null || true

        # Human intervention: check for human message between iterations
        local human_msg_file="$STATE_DIR/pipeline-artifacts/human-message.txt"
        if [[ -f "$human_msg_file" ]]; then
            local human_msg
            human_msg="$(cat "$human_msg_file" 2>/dev/null || true)"
            if [[ -n "$human_msg" ]]; then
                echo -e "  ${PURPLE}${BOLD}💬 Human message:${RESET} $human_msg"
                # Inject human message as additional context for next iteration
                GOAL="${GOAL}

HUMAN FEEDBACK (received after iteration $ITERATION): $human_msg"
                rm -f "$human_msg_file"
            fi
        fi

        # Stuckness-triggered restart: if detected 3+ times, break to allow session restart
        if [[ "${STUCKNESS_COUNT:-0}" -ge 3 ]]; then
            STATUS="stuck_restart"
            write_state
            write_progress
            warn "Stuckness detected 3+ times — triggering session restart"
            break
        fi

        sleep "$(_config_get_int "loop.sleep_between_iterations" 2 2>/dev/null || echo 2)"
    done

    # Write final state after loop exits
    write_state
    write_progress
    show_summary
}
