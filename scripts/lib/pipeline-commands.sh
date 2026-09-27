#!/usr/bin/env bash
# Module: pipeline-commands
# CLI commands: start, resume, status, abort, dry-run, reasoning trace, post-completion
set -euo pipefail

# Module guard
[[ -n "${_MODULE_PIPELINE_COMMANDS_LOADED:-}" ]] && return 0; _MODULE_PIPELINE_COMMANDS_LOADED=1

# ─── Defaults (needed if sourced independently) ──────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="${STATE_DIR:-$PROJECT_ROOT/.claude}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/pipeline-state.md}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$STATE_DIR/pipeline-artifacts}"

# Variables that pipeline_start references (set by sw-pipeline.sh, defaults here for safety)
COST_MODEL_RATES="${COST_MODEL_RATES:-'{\"opus\":{\"input\":15,\"output\":75},\"sonnet\":{\"input\":3,\"output\":15},\"haiku\":{\"input\":0.25,\"output\":1.25}}'}"
SELF_HEAL_COUNT="${SELF_HEAL_COUNT:-0}"
TOTAL_INPUT_TOKENS="${TOTAL_INPUT_TOKENS:-0}"
TOTAL_OUTPUT_TOKENS="${TOTAL_OUTPUT_TOKENS:-0}"
STASHED_CHANGES="${STASHED_CHANGES:-false}"
PIPELINE_START_EPOCH="${PIPELINE_START_EPOCH:-}"
PIPELINE_STATUS="${PIPELINE_STATUS:-}"
PIPELINE_STAGES_PASSED="${PIPELINE_STAGES_PASSED:-}"
PIPELINE_SLOWEST_STAGE="${PIPELINE_SLOWEST_STAGE:-}"

# Ensure helpers are loaded
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
[[ "$(type -t info 2>/dev/null)" == "function" ]] || info() { echo "$*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]] || warn() { echo "$*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]] || error() { echo "$*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { true; }

# ─── Post-Completion Cleanup ───────────────────────────────────────
pipeline_post_completion_cleanup() {
    local cleaned=0

    # 1. Clear checkpoints and context files (they only matter for resume; pipeline is done)
    if [[ -d "${ARTIFACTS_DIR}/checkpoints" ]]; then
        local cp_count=0
        local cp_file
        for cp_file in "${ARTIFACTS_DIR}/checkpoints"/*-checkpoint.json; do
            [[ -f "$cp_file" ]] || continue
            rm -f "$cp_file"
            cp_count=$((cp_count + 1))
        done
        for cp_file in "${ARTIFACTS_DIR}/checkpoints"/*-claude-context.json; do
            [[ -f "$cp_file" ]] || continue
            rm -f "$cp_file"
            cp_count=$((cp_count + 1))
        done
        if [[ "$cp_count" -gt 0 ]]; then
            cleaned=$((cleaned + cp_count))
        fi
    fi

    # 2. Clear per-run intelligence artifacts (not needed after completion)
    local intel_files=(
        "${ARTIFACTS_DIR}/classified-findings.json"
        "${ARTIFACTS_DIR}/reassessment.json"
        "${ARTIFACTS_DIR}/skip-stage.txt"
        "${ARTIFACTS_DIR}/human-message.txt"
    )
    local f
    for f in "${intel_files[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            cleaned=$((cleaned + 1))
        fi
    done

    # 3. Clear stale pipeline state (mark as idle so next run starts clean)
    if [[ -f "$STATE_FILE" ]]; then
        # Reset status to idle (preserves the file for reference but unblocks new runs)
        local tmp_state
        tmp_state=$(mktemp "${TMPDIR:-/tmp}/sw-state.XXXXXX") || { warn "mktemp failed for state reset"; return 0; }
        # shellcheck disable=SC2064  # intentional expansion at definition time
        trap "rm -f '$tmp_state'" RETURN
        sed 's/^status: .*/status: idle/' "$STATE_FILE" > "$tmp_state" 2>/dev/null || true
        mv "$tmp_state" "$STATE_FILE"
    fi

    if [[ "$cleaned" -gt 0 ]]; then
        emit_event "pipeline.cleanup" \
            "issue=${ISSUE_NUMBER:-0}" \
            "cleaned=$cleaned" \
            "type=post_completion"
    fi
}

# ─── Cancel GitHub Check Runs ──────────────────────────────────────
pipeline_cancel_check_runs() {
    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        return
    fi

    if ! type gh_checks_stage_update >/dev/null 2>&1; then
        return
    fi

    local ids_file="${ARTIFACTS_DIR:-/dev/null}/check-run-ids.json"
    [[ -f "$ids_file" ]] || return

    local stage
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue
        gh_checks_stage_update "$stage" "completed" "cancelled" "Pipeline interrupted" 2>/dev/null || true
    done < <(jq -r 'keys[]' "$ids_file" 2>/dev/null || true)
}

# ─── Worktree Isolation ────────────────────────────────────────────
pipeline_setup_worktree() {
    local worktree_base=".worktrees"
    local name="${WORKTREE_NAME}"

    # Auto-generate name from issue number or timestamp
    if [[ -z "$name" ]]; then
        if [[ -n "${ISSUE_NUMBER:-}" ]]; then
            name="pipeline-issue-${ISSUE_NUMBER}"
        else
            name="pipeline-$(date +%s)"
        fi
    fi

    local worktree_path="${worktree_base}/${name}"
    local branch_name="pipeline/${name}"

    info "Setting up worktree: ${DIM}${worktree_path}${RESET}"

    # Ensure worktree base exists
    mkdir -p "$worktree_base"

    # Remove stale worktree if it exists
    if [[ -d "$worktree_path" ]]; then
        warn "Worktree already exists — removing: ${worktree_path}"
        git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi

    # Delete stale branch if it exists
    git branch -D "$branch_name" 2>/dev/null || true

    # Create worktree with new branch from current HEAD
    git worktree add -b "$branch_name" "$worktree_path" HEAD

    # Store original dir for cleanup, then cd into worktree
    ORIGINAL_REPO_DIR="$(pwd)"
    cd "$worktree_path" || { error "Failed to cd into worktree: $worktree_path"; return 1; }
    CLEANUP_WORKTREE=true

    success "Worktree ready: ${CYAN}${worktree_path}${RESET} (branch: ${branch_name})"
}

pipeline_cleanup_worktree() {
    if [[ "${CLEANUP_WORKTREE:-false}" != "true" ]]; then
        return
    fi

    local worktree_path
    worktree_path="$(pwd)"

    if [[ -n "${ORIGINAL_REPO_DIR:-}" && "$worktree_path" != "$ORIGINAL_REPO_DIR" ]]; then
        cd "$ORIGINAL_REPO_DIR" 2>/dev/null || cd /
        # Only clean up worktree on success — preserve on failure for inspection
        if [[ "${PIPELINE_EXIT_CODE:-1}" -eq 0 ]]; then
            info "Cleaning up worktree: ${DIM}${worktree_path}${RESET}"
            # Extract branch name before removing worktree
            local _wt_branch=""
            _wt_branch=$(git worktree list --porcelain 2>/dev/null | grep -A1 "worktree ${worktree_path}$" | grep "^branch " | sed 's|^branch refs/heads/||' || true)
            if ! git worktree remove --force "$worktree_path" 2>/dev/null; then
                warn "Failed to remove worktree at ${worktree_path} — may need manual cleanup"
            fi
            # Clean up the local branch
            if [[ -n "$_wt_branch" ]]; then
                if ! git branch -D "$_wt_branch" 2>/dev/null; then
                    warn "Failed to delete local branch ${_wt_branch}"
                fi
            fi
            # Clean up the remote branch (if it was pushed)
            if [[ -n "$_wt_branch" && "${NO_GITHUB:-}" != "true" ]]; then
                git push origin --delete "$_wt_branch" 2>/dev/null || true
            fi
        else
            warn "Pipeline failed — worktree preserved for inspection: ${DIM}${worktree_path}${RESET}"
            warn "Clean up manually: ${DIM}git worktree remove --force ${worktree_path}${RESET}"
        fi
    fi
}

# ─── Dry Run Mode ───────────────────────────────────────────────────────────

# ─── Dry-Run Mode ──────────────────────────────────────────────────
run_dry_run() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━ Dry Run: Pipeline Validation ━━━${RESET}"
    echo ""

    # Validate pipeline config
    if [[ ! -f "$PIPELINE_CONFIG" ]]; then
        error "Pipeline config not found: $PIPELINE_CONFIG"
        return 1
    fi

    # Validate JSON structure
    local validate_json
    validate_json=$(jq . "$PIPELINE_CONFIG" 2>/dev/null) || {
        error "Pipeline config is not valid JSON: $PIPELINE_CONFIG"
        return 1
    }

    # Extract pipeline metadata
    local pipeline_name stages_count enabled_stages gated_stages
    pipeline_name=$(jq -r '.name // "unknown"' "$PIPELINE_CONFIG")
    stages_count=$(jq '.stages | length' "$PIPELINE_CONFIG")
    enabled_stages=$(jq '[.stages[] | select(.enabled == true)] | length' "$PIPELINE_CONFIG")
    gated_stages=$(jq '[.stages[] | select(.enabled == true and .gate == "approve")] | length' "$PIPELINE_CONFIG")

    # Build model (per-stage override or default)
    local default_model stage_model
    default_model=$(jq -r '.defaults.model // "opus"' "$PIPELINE_CONFIG")
    stage_model="$MODEL"
    [[ -z "$stage_model" ]] && stage_model="$default_model"

    echo -e "  ${BOLD}Pipeline:${RESET}       $pipeline_name"
    echo -e "  ${BOLD}Stages:${RESET}         $enabled_stages enabled of $stages_count total"
    if [[ "$SKIP_GATES" == "true" ]]; then
        echo -e "  ${BOLD}Gates:${RESET}         ${YELLOW}all auto (--skip-gates)${RESET}"
    else
        echo -e "  ${BOLD}Gates:${RESET}         $gated_stages approval gate(s)"
    fi
    echo -e "  ${BOLD}Model:${RESET}         $stage_model"
    echo ""

    # Table header
    echo -e "${CYAN}${BOLD}Stage         Enabled  Gate     Model${RESET}"
    echo -e "${CYAN}────────────────────────────────────────${RESET}"

    # List all stages
    while IFS= read -r stage_json; do
        local stage_id stage_enabled stage_gate stage_config_model stage_model_display
        stage_id=$(echo "$stage_json" | jq -r '.id')
        stage_enabled=$(echo "$stage_json" | jq -r '.enabled')
        stage_gate=$(echo "$stage_json" | jq -r '.gate')

        # Determine stage model (config override or default)
        stage_config_model=$(echo "$stage_json" | jq -r '.config.model // ""')
        if [[ -n "$stage_config_model" && "$stage_config_model" != "null" ]]; then
            stage_model_display="$stage_config_model"
        else
            stage_model_display="$default_model"
        fi

        # Format enabled
        local enabled_str
        if [[ "$stage_enabled" == "true" ]]; then
            enabled_str="${GREEN}yes${RESET}"
        else
            enabled_str="${DIM}no${RESET}"
        fi

        # Format gate
        local gate_str
        if [[ "$stage_enabled" == "true" ]]; then
            if [[ "$stage_gate" == "approve" ]]; then
                gate_str="${YELLOW}approve${RESET}"
            else
                gate_str="${GREEN}auto${RESET}"
            fi
        else
            gate_str="${DIM}—${RESET}"
        fi

        printf "%-15s %s  %s  %s\n" "$stage_id" "$enabled_str" "$gate_str" "$stage_model_display"
    done < <(jq -c '.stages[]' "$PIPELINE_CONFIG")

    echo ""

    # Validate required tools
    echo -e "${BLUE}${BOLD}━━━ Tool Validation ━━━${RESET}"
    echo ""

    local tool_errors=0
    local required_tools=("git" "jq")
    local optional_tools=("gh" "claude" "bc")

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${RED}✗${RESET} $tool ${RED}(required)${RESET}"
            tool_errors=$((tool_errors + 1))
        fi
    done

    for tool in "${optional_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${DIM}○${RESET} $tool"
        fi
    done

    echo ""

    # Cost estimation: use historical averages from past pipelines when available
    echo -e "${BLUE}${BOLD}━━━ Estimated Resource Usage ━━━${RESET}"
    echo ""

    local stages_json
    stages_json=$(jq '[.stages[] | select(.enabled == true)]' "$PIPELINE_CONFIG" 2>/dev/null || echo "[]")
    local est
    est=$(estimate_pipeline_cost "$stages_json")
    local input_tokens_estimate output_tokens_estimate
    input_tokens_estimate=$(echo "$est" | jq -r '.input_tokens // 0')
    output_tokens_estimate=$(echo "$est" | jq -r '.output_tokens // 0')

    # Calculate cost based on selected model
    local input_rate output_rate input_cost output_cost total_cost
    input_rate=$(echo "$COST_MODEL_RATES" | jq -r ".${stage_model}.input // 3" 2>/dev/null || echo "3")
    output_rate=$(echo "$COST_MODEL_RATES" | jq -r ".${stage_model}.output // 15" 2>/dev/null || echo "15")

    # Cost calculation: tokens per million * rate
    input_cost=$(awk -v tokens="$input_tokens_estimate" -v rate="$input_rate" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
    output_cost=$(awk -v tokens="$output_tokens_estimate" -v rate="$output_rate" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
    total_cost=$(awk -v i="$input_cost" -v o="$output_cost" 'BEGIN{printf "%.4f", i + o}')

    echo -e "  ${BOLD}Estimated Input Tokens:${RESET}  ~$input_tokens_estimate"
    echo -e "  ${BOLD}Estimated Output Tokens:${RESET} ~$output_tokens_estimate"
    echo -e "  ${BOLD}Model Cost Rate:${RESET}        $stage_model"
    echo -e "  ${BOLD}Estimated Cost:${RESET}         \$$total_cost USD"
    echo ""

    # Validate composed pipeline if intelligence is enabled
    if [[ -f "$ARTIFACTS_DIR/composed-pipeline.json" ]] && type composer_validate_pipeline >/dev/null 2>&1; then
        echo -e "${BLUE}${BOLD}━━━ Intelligence-Composed Pipeline ━━━${RESET}"
        echo ""

        if composer_validate_pipeline "$(cat "$ARTIFACTS_DIR/composed-pipeline.json" 2>/dev/null || echo "")" 2>/dev/null; then
            echo -e "  ${GREEN}✓${RESET} Composed pipeline is valid"
        else
            echo -e "  ${YELLOW}⚠${RESET} Composed pipeline validation failed (will use template defaults)"
        fi
        echo ""
    fi

    # Final validation result
    if [[ "$tool_errors" -gt 0 ]]; then
        error "Dry run validation failed: $tool_errors required tool(s) missing"
        return 1
    fi

    success "Dry run validation passed"
    echo ""
    echo -e "  To execute this pipeline: ${DIM}remove --dry-run flag${RESET}"
    echo ""
    return 0
}

# ─── Reasoning Trace Generation ─────────────────────────────────────
generate_reasoning_trace() {
    local job_id="${SHIPWRIGHT_PIPELINE_ID:-$$}"
    local issue="${ISSUE_NUMBER:-}"
    local goal="${GOAL:-}"

    # Step 1: Analyze issue complexity and risk
    local complexity="medium"
    local risk_score=50
    if [[ -n "$issue" ]] && type intelligence_analyze_issue >/dev/null 2>&1; then
        local issue_json analysis
        issue_json=$(gh issue view "$issue" --json number,title,body,labels 2>/dev/null || echo "{}")
        if [[ -n "$issue_json" && "$issue_json" != "{}" ]]; then
            analysis=$(intelligence_analyze_issue "$issue_json" 2>/dev/null || echo "")
            if [[ -n "$analysis" ]]; then
                local comp_num
                comp_num=$(echo "$analysis" | jq -r '.complexity // 5' 2>/dev/null || echo "5")
                if [[ "$comp_num" -le 3 ]]; then
                    complexity="low"
                elif [[ "$comp_num" -le 6 ]]; then
                    complexity="medium"
                else
                    complexity="high"
                fi
                risk_score=$((100 - $(echo "$analysis" | jq -r '.success_probability // 50' 2>/dev/null || echo "50")))
            fi
        fi
    elif [[ -n "$goal" ]]; then
        issue_json=$(jq -n --arg title "${goal}" --arg body "" '{title: $title, body: $body, labels: []}')
        if type intelligence_analyze_issue >/dev/null 2>&1; then
            analysis=$(intelligence_analyze_issue "$issue_json" 2>/dev/null || echo "")
            if [[ -n "$analysis" ]]; then
                local comp_num
                comp_num=$(echo "$analysis" | jq -r '.complexity // 5' 2>/dev/null || echo "5")
                if [[ "$comp_num" -le 3 ]]; then complexity="low"; elif [[ "$comp_num" -le 6 ]]; then complexity="medium"; else complexity="high"; fi
                risk_score=$((100 - $(echo "$analysis" | jq -r '.success_probability // 50' 2>/dev/null || echo "50")))
            fi
        fi
    fi

    # Step 2: Query similar past issues
    local similar_context=""
    if type memory_semantic_search >/dev/null 2>&1 && [[ -n "$goal" ]]; then
        similar_context=$(memory_semantic_search "$goal" "" 3 2>/dev/null || echo "")
    fi

    # Step 3: Select template using Thompson sampling
    local selected_template="${PIPELINE_TEMPLATE:-}"
    if [[ -z "$selected_template" ]] && type thompson_select_template >/dev/null 2>&1; then
        selected_template=$(thompson_select_template "$complexity" 2>/dev/null || echo "standard")
    fi
    [[ -z "$selected_template" ]] && selected_template="standard"

    # Step 4: Predict failure modes from memory
    local failure_predictions=""
    if type memory_semantic_search >/dev/null 2>&1 && [[ -n "$goal" ]]; then
        failure_predictions=$(memory_semantic_search "failure error $goal" "" 3 2>/dev/null || echo "")
    fi

    # Save reasoning traces to DB
    if type db_save_reasoning_trace >/dev/null 2>&1; then
        db_save_reasoning_trace "$job_id" "complexity_analysis" \
            "issue=$issue goal=$goal" \
            "Analyzed complexity=$complexity risk=$risk_score" \
            "complexity=$complexity risk_score=$risk_score" 0.7 2>/dev/null || true

        db_save_reasoning_trace "$job_id" "template_selection" \
            "complexity=$complexity historical_outcomes" \
            "Thompson sampling over historical success rates" \
            "template=$selected_template" 0.8 2>/dev/null || true

        if [[ -n "$similar_context" && "$similar_context" != "[]" ]]; then
            db_save_reasoning_trace "$job_id" "similar_issues" \
                "$goal" \
                "Found similar past issues for context injection" \
                "$similar_context" 0.6 2>/dev/null || true
        fi

        if [[ -n "$failure_predictions" && "$failure_predictions" != "[]" ]]; then
            db_save_reasoning_trace "$job_id" "failure_prediction" \
                "$goal" \
                "Predicted potential failure modes from history" \
                "$failure_predictions" 0.5 2>/dev/null || true
        fi
    fi

    # Export for use by pipeline stages
    [[ -n "$selected_template" && -z "${PIPELINE_TEMPLATE:-}" ]] && export PIPELINE_TEMPLATE="$selected_template"

    emit_event "reasoning.trace" "job_id=$job_id" "complexity=$complexity" "risk=$risk_score" "template=${selected_template:-standard}" 2>/dev/null || true
}

# ─── tmux Pipeline Session ─────────────────────────────────────────
SW_PIPELINE_SESSION="sw-pipelines"

_ensure_tmux_session() {
    if ! command -v tmux >/dev/null 2>&1; then
        error "tmux is required for --detach mode"
        return 1
    fi
    if ! tmux has-session -t "$SW_PIPELINE_SESSION" 2>/dev/null; then
        tmux new-session -d -s "$SW_PIPELINE_SESSION" -n "status" 2>/dev/null || true
        tmux send-keys -t "$SW_PIPELINE_SESSION:status" "echo 'Shipwright Pipeline Session — use shipwright pipeline list'" Enter 2>/dev/null || true
    fi
}

_pipeline_window_name() {
    local issue="${1:-}"
    local goal="${2:-}"
    if [[ -n "$issue" ]]; then
        echo "p-${issue}"
    elif [[ -n "$goal" ]]; then
        # Slugify goal: first 30 chars, lowercase, spaces to dashes
        local slug
        slug=$(echo "$goal" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | head -c 30 | sed 's/-$//')
        echo "p-${slug}"
    else
        echo "p-$$"
    fi
}

# ─── Detached Pipeline Start ──────────────────────────────────────
pipeline_start_detached() {
    _ensure_tmux_session || { error "Cannot create tmux session"; exit 1; }

    local win_name
    win_name=$(_pipeline_window_name "${ISSUE_NUMBER:-}" "${GOAL:-}")

    # Build the command to run inside tmux
    local cmd="cd '$(pwd)' && "
    cmd+="'${SCRIPT_DIR}/../sw-pipeline.sh' start"
    [[ -n "${ISSUE_NUMBER:-}" ]] && cmd+=" --issue '${ISSUE_NUMBER}'"
    [[ -n "${GOAL:-}" ]] && cmd+=" --goal '${GOAL}'"
    [[ -n "${PIPELINE_NAME:-}" && "${PIPELINE_NAME:-}" != "standard" ]] && cmd+=" --pipeline '${PIPELINE_NAME}'"
    [[ -n "${TEST_CMD:-}" ]] && cmd+=" --test-cmd '${TEST_CMD}'"
    [[ -n "${MODEL:-}" ]] && cmd+=" --model '${MODEL}'"
    [[ "${SKIP_GATES:-}" == "true" ]] && cmd+=" --skip-gates"
    [[ "${AUTO_WORKTREE:-}" == "true" ]] && cmd+=" --worktree"
    [[ -n "${WORKTREE_NAME:-}" ]] && cmd+=" --worktree='${WORKTREE_NAME}'"
    cmd+=" --foreground"  # Inside tmux, run foreground

    # Create window and send command
    tmux new-window -t "$SW_PIPELINE_SESSION" -n "$win_name" 2>/dev/null || true
    local pane_id
    pane_id=$(tmux list-panes -t "${SW_PIPELINE_SESSION}:${win_name}" -F '#{pane_id}' 2>/dev/null | head -1)

    # Set pane title
    tmux send-keys -t "$pane_id" "printf '\\033]2;shipwright pipeline #${ISSUE_NUMBER:-${GOAL:0:30}}\\033\\\\'" Enter 2>/dev/null || true
    tmux send-keys -t "$pane_id" "$cmd" Enter

    # Store heartbeat for attach/tail
    local hb_dir="$HOME/.shipwright/heartbeats"
    mkdir -p "$hb_dir"
    local hb_file="${hb_dir}/pipeline-${ISSUE_NUMBER:-goal-$$}.json"
    cat > "$hb_file" <<HEARTBEAT
{
  "job_id": "pipeline-${ISSUE_NUMBER:-goal-$$}",
  "pane_id": "${pane_id:-unknown}",
  "window": "${win_name}",
  "session": "${SW_PIPELINE_SESSION}",
  "status": "running",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "goal": "${GOAL:-issue #${ISSUE_NUMBER:-}}",
  "pid": 0
}
HEARTBEAT

    emit_event "pipeline.detached" \
        "issue=${ISSUE_NUMBER:-0}" \
        "window=${win_name}" \
        "session=${SW_PIPELINE_SESSION}"

    echo ""
    echo -e "${CYAN}${BOLD}Pipeline started in tmux${RESET}"
    echo ""
    echo -e "  ${BOLD}Attach:${RESET}  shipwright pipeline attach ${ISSUE_NUMBER:-}"
    echo -e "  ${BOLD}Tail:${RESET}    shipwright pipeline tail ${ISSUE_NUMBER:-}"
    echo -e "  ${BOLD}Status:${RESET}  shipwright pipeline status"
    echo -e "  ${BOLD}tmux:${RESET}    tmux attach -t ${SW_PIPELINE_SESSION}:${win_name}"
    echo ""
    echo -e "  ${DIM}Detach from tmux: Ctrl-a d${RESET}"
}

# ─── Attach to Pipeline ───────────────────────────────────────────
pipeline_attach() {
    local target="${1:-}"

    if ! command -v tmux >/dev/null 2>&1; then
        error "tmux is required for attach"
        exit 1
    fi

    # Find the window
    local win_name=""
    if [[ -n "$target" ]]; then
        win_name="p-${target}"
    else
        # Find most recent pipeline window
        win_name=$(tmux list-windows -t "$SW_PIPELINE_SESSION" -F '#{window_name}' 2>/dev/null | grep '^p-' | tail -1 || true)
    fi

    if [[ -z "$win_name" ]]; then
        error "No pipeline windows found"
        echo -e "  ${DIM}Start one: shipwright pipeline start --issue N --detach${RESET}"
        exit 1
    fi

    # Check window exists
    if ! tmux list-windows -t "$SW_PIPELINE_SESSION" -F '#{window_name}' 2>/dev/null | grep -q "^${win_name}$"; then
        # Try heartbeat fallback
        local hb_file="$HOME/.shipwright/heartbeats/pipeline-${target}.json"
        if [[ -f "$hb_file" ]]; then
            local hb_session hb_window
            hb_session=$(jq -r '.session // ""' "$hb_file" 2>/dev/null || true)
            hb_window=$(jq -r '.window // ""' "$hb_file" 2>/dev/null || true)
            if [[ -n "$hb_session" && -n "$hb_window" ]]; then
                tmux select-window -t "${hb_session}:${hb_window}" 2>/dev/null && \
                exec tmux attach -t "$hb_session" 2>/dev/null
            fi
        fi
        error "Pipeline window not found: $win_name"
        echo -e "  ${DIM}Available windows:${RESET}"
        tmux list-windows -t "$SW_PIPELINE_SESSION" -F '  #{window_name}' 2>/dev/null || echo "  (none)"
        exit 1
    fi

    tmux select-window -t "${SW_PIPELINE_SESSION}:${win_name}" 2>/dev/null
    exec tmux attach -t "$SW_PIPELINE_SESSION"
}

# ─── Tail Pipeline Output ─────────────────────────────────────────
pipeline_tail() {
    local target="${1:-}"

    # Try tmux capture first
    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SW_PIPELINE_SESSION" 2>/dev/null; then
        local win_name=""
        if [[ -n "$target" ]]; then
            win_name="p-${target}"
        else
            win_name=$(tmux list-windows -t "$SW_PIPELINE_SESSION" -F '#{window_name}' 2>/dev/null | grep '^p-' | tail -1 || true)
        fi

        if [[ -n "$win_name" ]] && tmux list-windows -t "$SW_PIPELINE_SESSION" -F '#{window_name}' 2>/dev/null | grep -q "^${win_name}$"; then
            local pane_id
            pane_id=$(tmux list-panes -t "${SW_PIPELINE_SESSION}:${win_name}" -F '#{pane_id}' 2>/dev/null | head -1)
            if [[ -n "$pane_id" ]]; then
                info "Streaming pipeline output (Ctrl-C to stop)..."
                echo ""
                while true; do
                    tmux capture-pane -t "$pane_id" -p -S -50 2>/dev/null || break
                    sleep 2
                    # Clear and redraw
                    printf '\033[H\033[2J'
                done
                return 0
            fi
        fi
    fi

    # Fallback: tail log file
    local log_dir="$HOME/.shipwright/logs"
    local log_file=""
    if [[ -n "$target" ]]; then
        log_file="${log_dir}/issue-${target}.log"
    else
        # Find most recent log
        log_file=$(ls -t "${log_dir}"/issue-*.log 2>/dev/null | head -1 || true)
    fi

    if [[ -n "$log_file" && -f "$log_file" ]]; then
        info "Tailing log: $log_file"
        tail -f "$log_file"
    else
        error "No pipeline output found for: ${target:-most recent}"
        echo -e "  ${DIM}Start a pipeline: shipwright pipeline start --issue N --detach${RESET}"
        exit 1
    fi
}

# ─── Main 'start' Command ──────────────────────────────────────────
pipeline_start() {
    # Detach mode: spawn in tmux and return
    if [[ "${DETACH:-false}" == "true" ]]; then
        pipeline_start_detached
        return 0
    fi

    # Handle --repo flag: change to directory before running
    if [[ -n "$REPO_OVERRIDE" ]]; then
        if [[ ! -d "$REPO_OVERRIDE" ]]; then
            error "Directory does not exist: $REPO_OVERRIDE"
            exit 1
        fi
        if ! cd "$REPO_OVERRIDE" 2>/dev/null; then
            error "Cannot cd to: $REPO_OVERRIDE"
            exit 1
        fi
        if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
            error "Not a git repository: $REPO_OVERRIDE"
            exit 1
        fi
        ORIGINAL_REPO_DIR="$(pwd)"
        info "Using repository: $ORIGINAL_REPO_DIR"
    fi

    # Bootstrap optimization & memory if cold start (before first intelligence use)
    if [[ -f "$SCRIPT_DIR/lib/bootstrap.sh" ]]; then
        source "$SCRIPT_DIR/lib/bootstrap.sh"
        [[ ! -f "$HOME/.shipwright/optimization/iteration-model.json" ]] && bootstrap_optimization 2>/dev/null || true
        [[ ! -f "$HOME/.shipwright/memory/patterns.json" ]] && bootstrap_memory 2>/dev/null || true
    fi

    if [[ -z "$GOAL" && -z "$ISSUE_NUMBER" ]]; then
        error "Must provide --goal or --issue"
        echo -e "  Example: ${DIM}shipwright pipeline start --goal \"Add JWT auth\"${RESET}"
        echo -e "  Example: ${DIM}shipwright pipeline start --issue 123${RESET}"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required. Install it: brew install jq"
        exit 1
    fi

    # Set up worktree isolation if requested
    if [[ "$AUTO_WORKTREE" == "true" ]]; then
        pipeline_setup_worktree
    fi

    # Register worktree cleanup on exit (chain with existing cleanup)
    if [[ "$CLEANUP_WORKTREE" == "true" ]]; then
        trap 'pipeline_cleanup_worktree; cleanup_on_exit' SIGINT SIGTERM
        trap 'pipeline_cleanup_worktree; cleanup_on_exit' EXIT
    fi

    setup_dirs

    # Acquire durable lock to prevent concurrent pipelines on the same issue/goal
    _PIPELINE_LOCK_ID=""
    if type acquire_lock >/dev/null 2>&1; then
        _PIPELINE_LOCK_ID="pipeline-${ISSUE_NUMBER:-goal-$$}"
        if ! acquire_lock "$_PIPELINE_LOCK_ID" 5 2>/dev/null; then
            error "Another pipeline is already running for this issue/goal"
            echo -e "  Wait for it to finish, or remove stale lock:"
            echo -e "  ${DIM}rm -rf ~/.shipwright/durable/locks/${_PIPELINE_LOCK_ID}.lock${RESET}"
            _PIPELINE_LOCK_ID=""
            exit 1
        fi
    fi

    # Generate reasoning trace (complexity analysis, template selection, failure predictions)
    local user_specified_pipeline="$PIPELINE_NAME"
    generate_reasoning_trace 2>/dev/null || true
    if [[ -n "${PIPELINE_TEMPLATE:-}" && "$user_specified_pipeline" == "standard" && "$PIPELINE_NAME_EXPLICIT" != "true" ]]; then
        PIPELINE_NAME="$PIPELINE_TEMPLATE"
    fi

    # Budget-aware template selection: check remaining budget and downgrade if needed
    # This is only applied when template was not explicitly set via --template/--pipeline
    if type budget_select_template >/dev/null 2>&1; then
        PIPELINE_NAME="$(budget_select_template "$PIPELINE_NAME" "$PIPELINE_NAME_EXPLICIT" pipeline)"
    fi

    # Check for existing pipeline
    if [[ -f "$STATE_FILE" ]]; then
        local existing_status
        existing_status=$(sed -n 's/^status: *//p' "$STATE_FILE" | head -1)
        if [[ "$existing_status" == "running" || "$existing_status" == "paused" || "$existing_status" == "interrupted" ]]; then
            warn "A pipeline is already in progress (status: $existing_status)"
            echo -e "  Resume it: ${DIM}shipwright pipeline resume${RESET}"
            echo -e "  Abort it:  ${DIM}shipwright pipeline abort${RESET}"
            exit 1
        fi
    fi

    # Pre-flight checks
    preflight_checks || exit 1

    # Initialize GitHub integration
    gh_init

    load_pipeline_config

    # Checkpoint resume: when --resume is passed, try DB first, then file-based
    checkpoint_stage=""
    checkpoint_iteration=0
    if $RESUME_FROM_CHECKPOINT && type db_load_checkpoint >/dev/null 2>&1; then
        local saved_checkpoint
        saved_checkpoint=$(db_load_checkpoint "pipeline-${SHIPWRIGHT_PIPELINE_ID:-$$}" 2>/dev/null || echo "")
        if [[ -n "$saved_checkpoint" ]]; then
            checkpoint_stage=$(echo "$saved_checkpoint" | jq -r '.stage // ""' 2>/dev/null || echo "")
            if [[ -n "$checkpoint_stage" ]]; then
                info "Resuming from DB checkpoint: stage=$checkpoint_stage"
                checkpoint_iteration=$(echo "$saved_checkpoint" | jq -r '.iteration // 0' 2>/dev/null || echo "0")
                # Build COMPLETED_STAGES: all enabled stages before checkpoint_stage
                local enabled_list before_list=""
                enabled_list=$(jq -r '.stages[] | select(.enabled == true) | .id' "$PIPELINE_CONFIG" 2>/dev/null) || true
                local s
                while IFS= read -r s; do
                    [[ -z "$s" ]] && continue
                    if [[ "$s" == "$checkpoint_stage" ]]; then
                        break
                    fi
                    [[ -n "$before_list" ]] && before_list="${before_list},${s}" || before_list="$s"
                done <<< "$enabled_list"
                if [[ -n "$before_list" ]]; then
                    COMPLETED_STAGES="${before_list}"
                    SELF_HEAL_COUNT="${checkpoint_iteration}"
                fi
            fi
        fi
    fi
    if $RESUME_FROM_CHECKPOINT && [[ -z "$checkpoint_stage" ]] && [[ -d "${ARTIFACTS_DIR}/checkpoints" ]]; then
        local cp_dir="${ARTIFACTS_DIR}/checkpoints"
        local latest_cp="" latest_mtime=0
        local f
        for f in "$cp_dir"/*-checkpoint.json; do
            [[ -f "$f" ]] || continue
            local mtime
            mtime=$(file_mtime "$f" 2>/dev/null || echo "0")
            if [[ "${mtime:-0}" -gt "$latest_mtime" ]]; then
                latest_mtime="${mtime}"
                latest_cp="$f"
            fi
        done
        if [[ -n "$latest_cp" && -x "$SCRIPT_DIR/sw-checkpoint.sh" ]]; then
            checkpoint_stage="$(basename "$latest_cp" -checkpoint.json)"
            local cp_json
            cp_json="$("$SCRIPT_DIR/sw-checkpoint.sh" restore --stage "$checkpoint_stage" 2>/dev/null)" || true
            if [[ -n "$cp_json" ]] && command -v jq >/dev/null 2>&1; then
                checkpoint_iteration="$(echo "$cp_json" | jq -r '.iteration // 0' 2>/dev/null)" || checkpoint_iteration=0
                info "Checkpoint resume: stage=${checkpoint_stage} iteration=${checkpoint_iteration}"
                # Build COMPLETED_STAGES: all enabled stages before checkpoint_stage
                local enabled_list before_list=""
                enabled_list="$(jq -r '.stages[] | select(.enabled == true) | .id' "$PIPELINE_CONFIG" 2>/dev/null)" || true
                local s
                while IFS= read -r s; do
                    [[ -z "$s" ]] && continue
                    if [[ "$s" == "$checkpoint_stage" ]]; then
                        break
                    fi
                    [[ -n "$before_list" ]] && before_list="${before_list},${s}" || before_list="$s"
                done <<< "$enabled_list"
                if [[ -n "$before_list" ]]; then
                    COMPLETED_STAGES="${before_list}"
                    SELF_HEAL_COUNT="${checkpoint_iteration}"
                fi
            fi
        fi
    fi

    # Restore from state file if resuming (failed/interrupted pipeline); else initialize fresh
    if $RESUME_FROM_CHECKPOINT && [[ -f "$STATE_FILE" ]]; then
        local existing_status
        existing_status="$(sed -n 's/^status: *//p' "$STATE_FILE" | head -1)"
        if [[ "$existing_status" == "failed" || "$existing_status" == "interrupted" ]]; then
            resume_state
        else
            initialize_state
        fi
    else
        initialize_state
    fi

    # CI resume: restore branch + goal context when intake is skipped
    if [[ -n "${COMPLETED_STAGES:-}" ]] && echo "$COMPLETED_STAGES" | tr ',' '\n' | grep -qx "intake"; then
        # Intake was completed in a previous run — restore context
        # The workflow merges the partial work branch, so code changes are on HEAD

        # Restore GOAL from issue if not already set
        if [[ -z "$GOAL" && -n "$ISSUE_NUMBER" ]]; then
            GOAL=$(_timeout "$(_config_get_int "network.gh_timeout" 30 2>/dev/null || echo 30)" gh issue view "$ISSUE_NUMBER" --json title --jq '.title' 2>/dev/null || echo "Issue #${ISSUE_NUMBER}")
            info "CI resume: goal from issue — ${GOAL}"
        fi

        # Restore branch context
        if [[ -z "$GIT_BRANCH" ]]; then
            local ci_branch="ci/issue-${ISSUE_NUMBER}"
            info "CI resume: creating branch ${ci_branch} from current HEAD"
            if ! git checkout -b "$ci_branch" 2>/dev/null && ! git checkout "$ci_branch" 2>/dev/null; then
                warn "CI resume: failed to create or checkout branch ${ci_branch}"
            fi
            GIT_BRANCH="$ci_branch"
        elif [[ "$(git branch --show-current 2>/dev/null)" != "$GIT_BRANCH" ]]; then
            info "CI resume: checking out branch ${GIT_BRANCH}"
            if ! git checkout -b "$GIT_BRANCH" 2>/dev/null && ! git checkout "$GIT_BRANCH" 2>/dev/null; then
                warn "CI resume: failed to create or checkout branch ${GIT_BRANCH}"
            fi
        fi
        write_state 2>/dev/null || true
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright pipeline — Autonomous Feature Delivery               ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Comprehensive environment summary
    if [[ -n "$GOAL" ]]; then
        echo -e "  ${BOLD}Goal:${RESET}        $GOAL"
    fi
    if [[ -n "$ISSUE_NUMBER" ]]; then
        echo -e "  ${BOLD}Issue:${RESET}       #$ISSUE_NUMBER"
    fi

    echo -e "  ${BOLD}Pipeline:${RESET}    $PIPELINE_NAME"

    local enabled_stages
    enabled_stages=$(jq -r '.stages[] | select(.enabled == true) | .id' "$PIPELINE_CONFIG" | tr '\n' ' ')
    echo -e "  ${BOLD}Stages:${RESET}      $enabled_stages"

    local gate_count
    gate_count=$(jq '[.stages[] | select(.gate == "approve" and .enabled == true)] | length' "$PIPELINE_CONFIG")
    if [[ "$HEADLESS" == "true" ]]; then
        echo -e "  ${BOLD}Gates:${RESET}       ${YELLOW}all auto (headless — non-interactive stdin detected)${RESET}"
    elif [[ "$SKIP_GATES" == "true" ]]; then
        echo -e "  ${BOLD}Gates:${RESET}       ${YELLOW}all auto (--skip-gates)${RESET}"
    else
        echo -e "  ${BOLD}Gates:${RESET}       ${gate_count} approval gate(s)"
    fi

    echo -e "  ${BOLD}Model:${RESET}       ${MODEL:-$(jq -r '.defaults.model // "opus"' "$PIPELINE_CONFIG")}"
    echo -e "  ${BOLD}Self-heal:${RESET}   ${BUILD_TEST_RETRIES} retry cycle(s)"

    if [[ "$GH_AVAILABLE" == "true" ]]; then
        echo -e "  ${BOLD}GitHub:${RESET}      ${GREEN}✓${RESET} ${DIM}${REPO_OWNER}/${REPO_NAME}${RESET}"
    else
        echo -e "  ${BOLD}GitHub:${RESET}      ${DIM}disabled${RESET}"
    fi

    if [[ -n "$SLACK_WEBHOOK" ]]; then
        echo -e "  ${BOLD}Slack:${RESET}       ${GREEN}✓${RESET} notifications enabled"
    fi

    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        run_dry_run
        return $?
    fi

    # Capture predictions for feedback loop (intelligence → actuals → learning)
    if type intelligence_analyze_issue >/dev/null 2>&1 && (type intelligence_estimate_iterations >/dev/null 2>&1 || type intelligence_predict_cost >/dev/null 2>&1); then
        local issue_json="${INTELLIGENCE_ANALYSIS:-}"
        if [[ -z "$issue_json" || "$issue_json" == "{}" ]]; then
            if [[ -n "$ISSUE_NUMBER" ]]; then
                issue_json=$(gh issue view "$ISSUE_NUMBER" --json number,title,body,labels 2>/dev/null || echo "{}")
            else
                issue_json=$(jq -n --arg title "${GOAL:-untitled}" --arg body "" '{title: $title, body: $body, labels: []}')
            fi
            if [[ -n "$issue_json" && "$issue_json" != "{}" ]]; then
                issue_json=$(intelligence_analyze_issue "$issue_json" 2>/dev/null || echo "{}")
            fi
        fi
        if [[ -n "$issue_json" && "$issue_json" != "{}" ]]; then
            if type intelligence_estimate_iterations >/dev/null 2>&1; then
                PREDICTED_ITERATIONS=$(intelligence_estimate_iterations "$issue_json" "" 2>/dev/null || echo "")
                export PREDICTED_ITERATIONS
            fi
            if type intelligence_predict_cost >/dev/null 2>&1; then
                local cost_json
                cost_json=$(intelligence_predict_cost "$issue_json" "{}" 2>/dev/null || echo "{}")
                PREDICTED_COST=$(echo "$cost_json" | jq -r '.estimated_cost_usd // empty' 2>/dev/null || echo "")
                export PREDICTED_COST
            fi
        fi
    fi

    # Start background heartbeat writer
    start_heartbeat

    # Initialize GitHub Check Runs for all pipeline stages
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_pipeline_start >/dev/null 2>&1; then
        local head_sha
        head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        if [[ -n "$head_sha" && -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            local stages_json
            stages_json=$(jq -c '[.stages[] | select(.enabled == true) | .id]' "$PIPELINE_CONFIG" 2>/dev/null || echo '[]')
            gh_checks_pipeline_start "$REPO_OWNER" "$REPO_NAME" "$head_sha" "$stages_json" >/dev/null 2>/dev/null || true
            info "GitHub Checks: created check runs for pipeline stages"
        fi
    fi

    # Send start notification
    notify "Pipeline Started" "Goal: ${GOAL}\nPipeline: ${PIPELINE_NAME}" "info"

    emit_event "pipeline.started" \
        "issue=${ISSUE_NUMBER:-0}" \
        "template=${PIPELINE_NAME}" \
        "complexity=${INTELLIGENCE_COMPLEXITY:-0}" \
        "machine=$(hostname 2>/dev/null || echo "unknown")" \
        "pipeline=${PIPELINE_NAME}" \
        "model=${MODEL:-opus}" \
        "goal=${GOAL}"

    # Record pipeline run in SQLite for dashboard visibility
    if type add_pipeline_run >/dev/null 2>&1; then
        add_pipeline_run "${SHIPWRIGHT_PIPELINE_ID}" "${ISSUE_NUMBER:-0}" "${GOAL}" "${BRANCH:-}" "${PIPELINE_NAME}" 2>/dev/null || true
    fi

    # Durable WAL: publish pipeline start event
    if type publish_event >/dev/null 2>&1; then
        publish_event "pipeline.started" "{\"issue\":\"${ISSUE_NUMBER:-0}\",\"pipeline\":\"${PIPELINE_NAME}\",\"goal\":\"${GOAL:0:200}\"}" 2>/dev/null || true
    fi


    run_pipeline
    local exit_code=$?
    PIPELINE_EXIT_CODE="$exit_code"

    # Compute total cost for pipeline.completed (prefer actual from Claude when available)
    local model_key="${MODEL:-sonnet}"
    local total_cost
    if [[ -n "${TOTAL_COST_USD:-}" && "${TOTAL_COST_USD}" != "0" && "${TOTAL_COST_USD}" != "null" ]]; then
        total_cost="${TOTAL_COST_USD}"
    else
        local input_cost output_cost
        input_cost=$(awk -v tokens="$TOTAL_INPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key}.input // 3")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
        output_cost=$(awk -v tokens="$TOTAL_OUTPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key}.output // 15")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
        total_cost=$(awk -v i="$input_cost" -v o="$output_cost" 'BEGIN{printf "%.4f", i + o}')
    fi

    # Send completion notification + event
    local total_dur_s=""
    [[ -n "$PIPELINE_START_EPOCH" ]] && total_dur_s=$(( $(now_epoch) - PIPELINE_START_EPOCH ))
    if [[ "$exit_code" -eq 0 ]]; then
        local total_dur=""
        [[ -n "$total_dur_s" ]] && total_dur=$(format_duration "$total_dur_s")
        local pr_url
        pr_url=$(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo "")
        notify "Pipeline Complete" "Goal: ${GOAL}\nDuration: ${total_dur:-unknown}\nPR: ${pr_url:-N/A}" "success"
        emit_event "pipeline.completed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "result=success" \
            "duration_s=${total_dur_s:-0}" \
            "iterations=$((SELF_HEAL_COUNT + 1))" \
            "template=${PIPELINE_NAME}" \
            "complexity=${INTELLIGENCE_COMPLEXITY:-0}" \
            "stages_passed=${PIPELINE_STAGES_PASSED:-0}" \
            "slowest_stage=${PIPELINE_SLOWEST_STAGE:-}" \
            "pr_url=${pr_url:-}" \
            "agent_id=${PIPELINE_AGENT_ID}" \
            "input_tokens=$TOTAL_INPUT_TOKENS" \
            "output_tokens=$TOTAL_OUTPUT_TOKENS" \
            "total_cost=$total_cost" \
            "self_heal_count=$SELF_HEAL_COUNT"

        # Finalize audit trail
        if type audit_finalize >/dev/null 2>&1; then
            audit_finalize "success" || true
        fi

        # Update pipeline run status in SQLite
        if type update_pipeline_status >/dev/null 2>&1; then
            update_pipeline_status "${SHIPWRIGHT_PIPELINE_ID}" "completed" "${PIPELINE_SLOWEST_STAGE:-}" "complete" "${total_dur_s:-0}" 2>/dev/null || true
        fi

        # Auto-ingest pipeline outcome into recruit profiles
        if [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
            bash "$SCRIPT_DIR/sw-recruit.sh" ingest-pipeline 1 2>/dev/null || true
        fi

        # Capture success patterns to memory (learn what works — parallel the failure path)
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            bash "$SCRIPT_DIR/sw-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
        fi
        # Record RL episode for cross-session learning (Phase 7)
        if type rl_record_from_pipeline >/dev/null 2>&1; then
            rl_record_from_pipeline true "$((SELF_HEAL_COUNT + 1))" "${total_cost:-0}" \
                "${INTELLIGENCE_LANGUAGE:-}" "${INTELLIGENCE_COMPLEXITY:-}" \
                "${INTELLIGENCE_ISSUE_TYPE:-}" "[]" "[]" 2>/dev/null || true
        fi
        # Autoresearch RL Phase 8: aggregate rewards, update bandits, learn policy
        if type reward_aggregate_pipeline >/dev/null 2>&1; then
            reward_aggregate_pipeline "${PIPELINE_JOB_ID:-$$}" "${INTELLIGENCE_LANGUAGE:-unknown}" "${INTELLIGENCE_COMPLEXITY:-medium}" 2>/dev/null || true
        fi
        # Track memory effectiveness — close the feedback loop on injected memories
        if type memeff_on_pipeline_complete >/dev/null 2>&1; then
            memeff_on_pipeline_complete "${PIPELINE_JOB_ID:-$$}" "success" "" 2>/dev/null || true
        fi
        if type bandit_update >/dev/null 2>&1; then
            bandit_update "model" "${CURRENT_STAGE_ID:-build}:${MODEL:-opus}" "success" 2>/dev/null || true
        fi
        if type policy_learn_from_history >/dev/null 2>&1; then
            policy_learn_from_history 2>/dev/null || true
        fi
        # Update memory baselines with successful run metrics
        if type memory_update_metrics >/dev/null 2>&1; then
            memory_update_metrics "build_duration_s" "${total_dur_s:-0}" 2>/dev/null || true
            memory_update_metrics "total_cost_usd" "${total_cost:-0}" 2>/dev/null || true
            memory_update_metrics "iterations" "$((SELF_HEAL_COUNT + 1))" 2>/dev/null || true
        fi

        # Record positive fix outcome if self-healing succeeded
        if [[ "$SELF_HEAL_COUNT" -gt 0 && -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            local _success_sig
            _success_sig=$(tail -30 "$ARTIFACTS_DIR/test-results.log" 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/^ *//;s/ *$//' || true)
            if [[ -n "$_success_sig" ]]; then
                bash "$SCRIPT_DIR/sw-memory.sh" fix-outcome "$_success_sig" "true" "true" 2>/dev/null || true
            fi
        fi
    else
        notify "Pipeline Failed" "Goal: ${GOAL}\nFailed at: ${CURRENT_STAGE_ID:-unknown}" "error"
        emit_event "pipeline.completed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "result=failure" \
            "duration_s=${total_dur_s:-0}" \
            "iterations=$((SELF_HEAL_COUNT + 1))" \
            "template=${PIPELINE_NAME}" \
            "complexity=${INTELLIGENCE_COMPLEXITY:-0}" \
            "failed_stage=${CURRENT_STAGE_ID:-unknown}" \
            "error_class=${LAST_STAGE_ERROR_CLASS:-unknown}" \
            "agent_id=${PIPELINE_AGENT_ID}" \
            "input_tokens=$TOTAL_INPUT_TOKENS" \
            "output_tokens=$TOTAL_OUTPUT_TOKENS" \
            "total_cost=$total_cost" \
            "self_heal_count=$SELF_HEAL_COUNT"

        # Finalize audit trail
        if type audit_finalize >/dev/null 2>&1; then
            audit_finalize "failure" || true
        fi

        # Update pipeline run status in SQLite
        if type update_pipeline_status >/dev/null 2>&1; then
            update_pipeline_status "${SHIPWRIGHT_PIPELINE_ID}" "failed" "${CURRENT_STAGE_ID:-unknown}" "failed" "${total_dur_s:-0}" 2>/dev/null || true
        fi

        # Auto-ingest pipeline outcome into recruit profiles
        if [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
            bash "$SCRIPT_DIR/sw-recruit.sh" ingest-pipeline 1 2>/dev/null || true
        fi

        # Record RL episode for cross-session learning (Phase 7 — failure case)
        if type rl_record_from_pipeline >/dev/null 2>&1; then
            rl_record_from_pipeline false "$((SELF_HEAL_COUNT + 1))" "${total_cost:-0}" \
                "${INTELLIGENCE_LANGUAGE:-}" "${INTELLIGENCE_COMPLEXITY:-}" \
                "${INTELLIGENCE_ISSUE_TYPE:-}" "[]" "[]" 2>/dev/null || true
        fi
        # Autoresearch RL Phase 8: aggregate rewards, update bandits, learn policy (failure case)
        if type reward_aggregate_pipeline >/dev/null 2>&1; then
            reward_aggregate_pipeline "${PIPELINE_JOB_ID:-$$}" "${INTELLIGENCE_LANGUAGE:-unknown}" "${INTELLIGENCE_COMPLEXITY:-medium}" 2>/dev/null || true
        fi
        # Track memory effectiveness — close the feedback loop on injected memories (failure case)
        if type memeff_on_pipeline_complete >/dev/null 2>&1; then
            memeff_on_pipeline_complete "${PIPELINE_JOB_ID:-$$}" "failure" "${CURRENT_STAGE_ID:-unknown}" 2>/dev/null || true
        fi
        if type bandit_update >/dev/null 2>&1; then
            bandit_update "model" "${CURRENT_STAGE_ID:-build}:${MODEL:-opus}" "failure" 2>/dev/null || true
        fi
        if type policy_learn_from_history >/dev/null 2>&1; then
            policy_learn_from_history 2>/dev/null || true
        fi

        # Capture failure learnings to memory
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            bash "$SCRIPT_DIR/sw-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
            bash "$SCRIPT_DIR/sw-memory.sh" analyze-failure "$ARTIFACTS_DIR/.claude-tokens-${CURRENT_STAGE_ID:-build}.log" "${CURRENT_STAGE_ID:-unknown}" 2>/dev/null || true

            # Record negative fix outcome — memory suggested a fix but it didn't resolve the issue
            # This closes the negative side of the fix-outcome feedback loop
            if [[ "$SELF_HEAL_COUNT" -gt 0 ]]; then
                local _fail_sig
                _fail_sig=$(tail -30 "$ARTIFACTS_DIR/test-results.log" 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/^ *//;s/ *$//' || true)
                if [[ -n "$_fail_sig" ]]; then
                    bash "$SCRIPT_DIR/sw-memory.sh" fix-outcome "$_fail_sig" "true" "false" 2>/dev/null || true
                fi
            fi
        fi
    fi

    # AI-powered outcome learning
    if type skill_analyze_outcome >/dev/null 2>&1; then
        local _failed_stage=""
        local _error_ctx=""
        if [[ "$exit_code" -ne 0 ]]; then
            _failed_stage="${CURRENT_STAGE_ID:-unknown}"
            _error_ctx=$(tail -30 "$ARTIFACTS_DIR/errors-collected.json" 2>/dev/null || true)
        fi
        local _outcome_result="success"
        [[ "$exit_code" -ne 0 ]] && _outcome_result="failure"

        if skill_analyze_outcome "$_outcome_result" "$ARTIFACTS_DIR" "$_failed_stage" "$_error_ctx" 2>/dev/null; then
            info "Skill outcome analysis complete — learnings recorded"
        fi
    fi

    # ── Prediction Validation Events ──
    # Compare predicted vs actual outcomes for feedback loop calibration
    local pipeline_success="false"
    [[ "$exit_code" -eq 0 ]] && pipeline_success="true"

    # Complexity prediction vs actual iterations
    emit_event "prediction.validated" \
        "issue=${ISSUE_NUMBER:-0}" \
        "predicted_complexity=${INTELLIGENCE_COMPLEXITY:-0}" \
        "actual_iterations=$SELF_HEAL_COUNT" \
        "success=$pipeline_success"

    # Close intelligence prediction feedback loop — validate predicted vs actual
    if type intelligence_validate_prediction >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
        intelligence_validate_prediction \
            "$ISSUE_NUMBER" \
            "${INTELLIGENCE_COMPLEXITY:-0}" \
            "${SELF_HEAL_COUNT:-0}" \
            "$pipeline_success" 2>/dev/null || true
    fi

    # Validate iterations prediction against actuals (cost validation moved below after total_cost is computed)
    local ACTUAL_ITERATIONS=$((SELF_HEAL_COUNT + 1))
    if [[ -n "${PREDICTED_ITERATIONS:-}" ]] && type intelligence_validate_prediction >/dev/null 2>&1; then
        intelligence_validate_prediction "iterations" "$PREDICTED_ITERATIONS" "$ACTUAL_ITERATIONS" 2>/dev/null || true
    fi

    # Close predictive anomaly feedback loop — confirm whether flagged anomalies were real
    if [[ -x "$SCRIPT_DIR/sw-predictive.sh" ]]; then
        local _actual_failure="false"
        [[ "$exit_code" -ne 0 ]] && _actual_failure="true"
        # Confirm anomalies for build and test stages based on pipeline outcome
        for _anomaly_stage in build test; do
            bash "$SCRIPT_DIR/sw-predictive.sh" confirm-anomaly "$_anomaly_stage" "duration_s" "$_actual_failure" 2>/dev/null || true
        done
    fi

    # Template outcome tracking
    emit_event "template.outcome" \
        "issue=${ISSUE_NUMBER:-0}" \
        "template=${PIPELINE_NAME}" \
        "success=$pipeline_success" \
        "duration_s=${total_dur_s:-0}" \
        "complexity=${INTELLIGENCE_COMPLEXITY:-0}"

    # Risk prediction vs actual failure
    local predicted_risk="${INTELLIGENCE_RISK_SCORE:-0}"
    emit_event "risk.outcome" \
        "issue=${ISSUE_NUMBER:-0}" \
        "predicted_risk=$predicted_risk" \
        "actual_failure=$([[ "$exit_code" -ne 0 ]] && echo "true" || echo "false")"

    # Per-stage model outcome events (read from stage timings)
    local routing_log="${ARTIFACTS_DIR}/model-routing.log"
    if [[ -f "$routing_log" ]]; then
        while IFS='|' read -r s_stage s_model s_success; do
            [[ -z "$s_stage" ]] && continue
            emit_event "model.outcome" \
                "issue=${ISSUE_NUMBER:-0}" \
                "stage=$s_stage" \
                "model=$s_model" \
                "success=$s_success"
        done < "$routing_log"
    fi

    # Record pipeline outcome for model routing feedback loop
    if type optimize_analyze_outcome >/dev/null 2>&1; then
        optimize_analyze_outcome "$STATE_FILE" 2>/dev/null || true
    fi

    # Auto-learn after pipeline completion (non-blocking)
    if type optimize_tune_templates &>/dev/null; then
        (
            optimize_tune_templates 2>/dev/null
            optimize_learn_iterations 2>/dev/null
            optimize_route_models 2>/dev/null
            optimize_learn_risk_keywords 2>/dev/null
        ) &
    fi

    if type memory_finalize_pipeline >/dev/null 2>&1; then
        memory_finalize_pipeline "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
    fi

    # Broadcast discovery for cross-pipeline learning
    if type broadcast_discovery >/dev/null 2>&1; then
        local _disc_result="failure"
        [[ "$exit_code" -eq 0 ]] && _disc_result="success"
        local _disc_files=""
        _disc_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null | head -20 | tr '\n' ',' || true)
        broadcast_discovery "pipeline_${_disc_result}" "${_disc_files:-unknown}" \
            "Pipeline ${_disc_result} for issue #${ISSUE_NUMBER:-0} (${PIPELINE_NAME:-unknown} template, stage=${CURRENT_STAGE_ID:-unknown})" \
            "${_disc_result}" 2>/dev/null || true
    fi

    # Emit cost event — prefer actual cost from Claude CLI when available
    local model_key="${MODEL:-sonnet}"
    local total_cost
    if [[ -n "${TOTAL_COST_USD:-}" && "${TOTAL_COST_USD}" != "0" && "${TOTAL_COST_USD}" != "null" ]]; then
        total_cost="${TOTAL_COST_USD}"
    else
        # Fallback: estimate from token counts and model rates
        local input_cost output_cost
        input_cost=$(awk -v tokens="$TOTAL_INPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key}.input // 3")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
        output_cost=$(awk -v tokens="$TOTAL_OUTPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key}.output // 15")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
        total_cost=$(awk -v i="$input_cost" -v o="$output_cost" 'BEGIN{printf "%.4f", i + o}')
    fi

    emit_event "pipeline.cost" \
        "input_tokens=$TOTAL_INPUT_TOKENS" \
        "output_tokens=$TOTAL_OUTPUT_TOKENS" \
        "model=$model_key" \
        "cost_usd=$total_cost"

    # Persist cost entry to costs.json + SQLite (was missing — tokens accumulated but never written)
    if type cost_record >/dev/null 2>&1; then
        cost_record "$TOTAL_INPUT_TOKENS" "$TOTAL_OUTPUT_TOKENS" "$model_key" "pipeline" "${ISSUE_NUMBER:-}" 2>/dev/null || true
    fi

    # Record pipeline outcome for Thompson sampling / outcome-based learning
    if type db_record_outcome >/dev/null 2>&1; then
        local _outcome_success=0
        [[ "$exit_code" -eq 0 ]] && _outcome_success=1
        local _outcome_complexity="medium"
        [[ "${INTELLIGENCE_COMPLEXITY:-5}" -le 3 ]] && _outcome_complexity="low"
        [[ "${INTELLIGENCE_COMPLEXITY:-5}" -ge 7 ]] && _outcome_complexity="high"
        db_record_outcome \
            "${SHIPWRIGHT_PIPELINE_ID:-pipeline-$$-${ISSUE_NUMBER:-0}}" \
            "${ISSUE_NUMBER:-}" \
            "${PIPELINE_NAME:-standard}" \
            "$_outcome_success" \
            "${total_dur_s:-0}" \
            "${SELF_HEAL_COUNT:-0}" \
            "${total_cost:-0}" \
            "$_outcome_complexity" 2>/dev/null || true
    fi

    # Validate cost prediction against actual (after total_cost is computed)
    if [[ -n "${PREDICTED_COST:-}" ]] && type intelligence_validate_prediction >/dev/null 2>&1; then
        intelligence_validate_prediction "cost" "$PREDICTED_COST" "$total_cost" 2>/dev/null || true
    fi

    return $exit_code
}

# ─── Resume, Status, Abort Commands ────────────────────────────────
pipeline_resume() {
    setup_dirs
    resume_state
    echo ""
    run_pipeline
}

pipeline_status() {
    setup_dirs

    if [[ ! -f "$STATE_FILE" ]]; then
        info "No active pipeline."
        echo -e "  Start one: ${DIM}shipwright pipeline start --goal \"...\"${RESET}"
        return
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Pipeline Status ━━━${RESET}"
    echo ""

    local p_name="" p_goal="" p_status="" p_branch="" p_stage="" p_started="" p_issue="" p_elapsed="" p_pr=""
    local in_frontmatter=false
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if $in_frontmatter; then break; else in_frontmatter=true; continue; fi
        fi
        if $in_frontmatter; then
            case "$line" in
                pipeline:*)      p_name="$(echo "${line#pipeline:}" | xargs)" ;;
                goal:*)          p_goal="$(echo "${line#goal:}" | sed 's/^ *"//;s/" *$//')" ;;
                status:*)        p_status="$(echo "${line#status:}" | xargs)" ;;
                branch:*)        p_branch="$(echo "${line#branch:}" | sed 's/^ *"//;s/" *$//')" ;;
                current_stage:*) p_stage="$(echo "${line#current_stage:}" | xargs)" ;;
                started_at:*)    p_started="$(echo "${line#started_at:}" | xargs)" ;;
                issue:*)         p_issue="$(echo "${line#issue:}" | sed 's/^ *"//;s/" *$//')" ;;
                elapsed:*)       p_elapsed="$(echo "${line#elapsed:}" | xargs)" ;;
                pr_number:*)     p_pr="$(echo "${line#pr_number:}" | xargs)" ;;
            esac
        fi
    done < "$STATE_FILE"

    local status_icon
    case "$p_status" in
        running)     status_icon="${CYAN}●${RESET}" ;;
        complete)    status_icon="${GREEN}✓${RESET}" ;;
        paused)      status_icon="${YELLOW}⏸${RESET}" ;;
        interrupted) status_icon="${YELLOW}⚡${RESET}" ;;
        failed)      status_icon="${RED}✗${RESET}" ;;
        aborted)     status_icon="${RED}◼${RESET}" ;;
        *)           status_icon="${DIM}○${RESET}" ;;
    esac

    echo -e "  ${BOLD}Pipeline:${RESET}  $p_name"
    echo -e "  ${BOLD}Goal:${RESET}      $p_goal"
    echo -e "  ${BOLD}Status:${RESET}    $status_icon $p_status"
    [[ -n "$p_branch" ]]  && echo -e "  ${BOLD}Branch:${RESET}    $p_branch"
    [[ -n "$p_issue" ]]   && echo -e "  ${BOLD}Issue:${RESET}     $p_issue"
    [[ -n "$p_pr" ]]      && echo -e "  ${BOLD}PR:${RESET}        #$p_pr"
    [[ -n "$p_stage" ]]   && echo -e "  ${BOLD}Stage:${RESET}     $p_stage"
    [[ -n "$p_started" ]] && echo -e "  ${BOLD}Started:${RESET}   $p_started"
    [[ -n "$p_elapsed" ]] && echo -e "  ${BOLD}Elapsed:${RESET}   $p_elapsed"

    echo ""
    echo -e "  ${BOLD}Stages:${RESET}"

    local in_stages=false
    while IFS= read -r line; do
        if [[ "$line" == "stages:" ]]; then
            in_stages=true; continue
        fi
        if $in_stages; then
            if [[ "$line" == "---" || ! "$line" =~ ^" " ]]; then break; fi
            local trimmed
            trimmed="$(echo "$line" | xargs)"
            if [[ "$trimmed" == *":"* ]]; then
                local sid="${trimmed%%:*}"
                local sst="${trimmed#*: }"
                local s_icon
                case "$sst" in
                    complete) s_icon="${GREEN}✓${RESET}" ;;
                    running)  s_icon="${CYAN}●${RESET}" ;;
                    failed)   s_icon="${RED}✗${RESET}" ;;
                    *)        s_icon="${DIM}○${RESET}" ;;
                esac
                echo -e "    $s_icon $sid"
            fi
        fi
    done < "$STATE_FILE"

    if [[ -d "$ARTIFACTS_DIR" ]]; then
        local artifact_count
        artifact_count=$(find "$ARTIFACTS_DIR" -type f 2>/dev/null | wc -l | xargs)
        if [[ "$artifact_count" -gt 0 ]]; then
            echo ""
            echo -e "  ${BOLD}Artifacts:${RESET} ($artifact_count files)"
            ls "$ARTIFACTS_DIR" 2>/dev/null | sed 's/^/    /'
        fi
    fi

    # Show tmux attach hint if pipeline is running in tmux
    if [[ "$p_status" == "running" ]] && command -v tmux >/dev/null 2>&1; then
        local issue_num="${p_issue#\#}"
        local hb_file="$HOME/.shipwright/heartbeats/pipeline-${issue_num:-goal}.json"
        if [[ -f "$hb_file" ]]; then
            local hb_session hb_window
            hb_session=$(jq -r '.session // ""' "$hb_file" 2>/dev/null || true)
            hb_window=$(jq -r '.window // ""' "$hb_file" 2>/dev/null || true)
            if [[ -n "$hb_session" ]] && tmux has-session -t "$hb_session" 2>/dev/null; then
                echo -e "  ${BOLD}Watch:${RESET}     shipwright pipeline attach ${issue_num}"
                echo -e "  ${BOLD}Tail:${RESET}      shipwright pipeline tail ${issue_num}"
            fi
        fi
    fi
    echo ""
}

pipeline_abort() {
    setup_dirs

    if [[ ! -f "$STATE_FILE" ]]; then
        info "No active pipeline to abort."
        return
    fi

    local current_status
    current_status=$(sed -n 's/^status: *//p' "$STATE_FILE" | head -1)

    if [[ "$current_status" == "complete" || "$current_status" == "aborted" ]]; then
        info "Pipeline already $current_status."
        return
    fi

    resume_state 2>/dev/null || true
    PIPELINE_STATUS="aborted"
    write_state

    # Update GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_init
        gh_remove_label "$ISSUE_NUMBER" "pipeline/in-progress"
        gh_comment_issue "$ISSUE_NUMBER" "⏹️ **Pipeline aborted** at stage: ${CURRENT_STAGE:-unknown}"
    fi

    warn "Pipeline aborted."
    echo -e "  State saved at: ${DIM}$STATE_FILE${RESET}"
}
