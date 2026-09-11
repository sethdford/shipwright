# daemon-dispatch.sh — Spawn, reap, on_success (for sw-daemon.sh)
# Source from sw-daemon.sh. Requires state, failure, helpers.
[[ -n "${_DAEMON_DISPATCH_LOADED:-}" ]] && return 0
_DAEMON_DISPATCH_LOADED=1

# Defaults for variables normally set by sw-daemon.sh (safe under set -u).
DAEMON_DIR="${DAEMON_DIR:-${HOME}/.shipwright}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE_FILE="${STATE_FILE:-${DAEMON_DIR}/daemon-state.json}"
LOG_DIR="${LOG_DIR:-${DAEMON_DIR}/logs}"
WORKTREE_DIR="${WORKTREE_DIR:-${REPO_DIR}/.claude/worktrees}"
BASE_BRANCH="${BASE_BRANCH:-main}"
PIPELINE_TEMPLATE="${PIPELINE_TEMPLATE:-autonomous}"
EFFORT_LEVEL="${EFFORT_LEVEL:-}"
FALLBACK_MODEL="${FALLBACK_MODEL:-sonnet}"
NO_GITHUB="${NO_GITHUB:-false}"

# ─── Org-Wide Repo Management ─────────────────────────────────────────────

daemon_ensure_repo() {
    local owner="$1" repo="$2"
    local repo_dir="$DAEMON_DIR/repos/${owner}/${repo}"

    if [[ -d "$repo_dir/.git" ]]; then
        # Pull latest
        (cd "$repo_dir" && git pull --ff-only 2>/dev/null) || {
            daemon_log WARN "Failed to update ${owner}/${repo} — using existing clone"
        }
    else
        mkdir -p "$DAEMON_DIR/repos/${owner}"
        if ! git clone --depth=1 "https://github.com/${owner}/${repo}.git" "$repo_dir" 2>/dev/null; then
            daemon_log ERROR "Failed to clone ${owner}/${repo}"
            return 1
        fi
        daemon_log INFO "Cloned ${owner}/${repo} to ${repo_dir}"
    fi

    echo "$repo_dir"
}

# ─── Spawn Pipeline ─────────────────────────────────────────────────────────

daemon_spawn_pipeline() {
    local issue_num="$1"
    local issue_title="${2:-}"
    local repo_full_name="${3:-}"  # owner/repo (org mode only)
    shift 3 2>/dev/null || true
    local extra_pipeline_args=("$@")  # Optional extra args passed to sw-pipeline.sh
    local gh_timeout
    gh_timeout=$(_smart_int "daemon.gh_timeout_seconds" 30)

    # ── Input validation: Validate issue number is strictly numeric ──
    if [[ ! "$issue_num" =~ ^[0-9]+$ ]]; then
        daemon_log ERROR "Invalid issue number format: ${issue_num}"
        return 1
    fi

    # Ensure numeric conversion for safety
    issue_num=$(printf '%d' "$issue_num" 2>/dev/null) || {
        daemon_log ERROR "Issue number conversion failed: ${issue_num}"
        return 1
    }

    # ── Worktree path validation ──
    # Ensure WORKTREE_DIR is absolute and not a symlink
    if [[ -z "$WORKTREE_DIR" ]]; then
        daemon_log ERROR "WORKTREE_DIR is not set"
        return 1
    fi

    if [[ ! "$WORKTREE_DIR" = /* ]]; then
        daemon_log ERROR "WORKTREE_DIR is not absolute: ${WORKTREE_DIR}"
        return 1
    fi

    if [[ -L "$WORKTREE_DIR" ]]; then
        daemon_log ERROR "WORKTREE_DIR is a symlink: ${WORKTREE_DIR}"
        return 1
    fi

    # Self-healing: ensure worktree directory exists before resolving
    if [[ ! -d "$WORKTREE_DIR" ]]; then
        daemon_log INFO "Auto-creating worktree directory: ${WORKTREE_DIR}"
        mkdir -p "$WORKTREE_DIR" || {
            daemon_log ERROR "Failed to create WORKTREE_DIR: ${WORKTREE_DIR}"
            return 1
        }
    fi

    # Verify resolved path is within repo/daemon directory
    local resolved_wt_dir
    resolved_wt_dir=$(cd "$WORKTREE_DIR" 2>/dev/null && pwd) || {
        daemon_log ERROR "Could not resolve WORKTREE_DIR path: ${WORKTREE_DIR}"
        return 1
    }

    daemon_log INFO "Spawning pipeline for issue #${issue_num}: ${issue_title}"

    # ── Budget gate: hard-stop if daily budget exhausted ──
    if [[ -x "${SCRIPT_DIR}/sw-cost.sh" ]]; then
        local remaining
        remaining=$("${SCRIPT_DIR}/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
        if [[ -n "$remaining" && "$remaining" != "unlimited" ]]; then
            if awk -v r="$remaining" 'BEGIN { exit !(r <= 0) }' 2>/dev/null; then
                daemon_log WARN "Budget exhausted (remaining: \$${remaining}) — skipping issue #${issue_num}"
                emit_event "daemon.budget_exhausted" "remaining=$remaining" "issue=$issue_num"
                return 1
            fi
            if awk -v r="$remaining" 'BEGIN { exit !(r < 1.0) }' 2>/dev/null; then
                daemon_log WARN "Budget low: \$${remaining} remaining"
            fi
        fi
    fi

    # ── Issue decomposition (if decomposer available) ──
    local decompose_script="${SCRIPT_DIR}/sw-decompose.sh"
    if [[ -x "$decompose_script" && "$NO_GITHUB" != "true" ]]; then
        local decompose_result=""
        decompose_result=$("$decompose_script" auto "$issue_num" 2>/dev/null) || true
        if [[ "$decompose_result" == *"decomposed"* ]]; then
            daemon_log INFO "Issue #${issue_num} decomposed into subtasks — skipping pipeline"
            # Remove the shipwright label so decomposed parent doesn't re-queue
            _timeout "$gh_timeout" gh issue edit "$issue_num" --remove-label "shipwright" 2>/dev/null || true
            return 0
        fi
    fi

    # Extract goal text from issue (title + first line of body)
    local issue_goal="$issue_title"
    if [[ "$NO_GITHUB" != "true" ]]; then
        local issue_body_first
        issue_body_first=$(_timeout "$gh_timeout" gh issue view "$issue_num" --json body --jq '.body' 2>/dev/null | head -3 | tr '\n' ' ' | cut -c1-200 || true)
        if [[ -n "$issue_body_first" ]]; then
            issue_goal="${issue_title}: ${issue_body_first}"
        fi
    fi

    # ── Predictive risk assessment (if enabled) ──
    if [[ "${PREDICTION_ENABLED:-false}" == "true" ]] && type predict_pipeline_risk >/dev/null 2>&1; then
        local issue_json_for_pred=""
        if [[ "$NO_GITHUB" != "true" ]]; then
            issue_json_for_pred=$(gh issue view "$issue_num" --json number,title,body,labels 2>/dev/null || echo "")
        fi
        if [[ -n "$issue_json_for_pred" ]]; then
            local risk_result
            risk_result=$(predict_pipeline_risk "$issue_json_for_pred" "" 2>/dev/null || echo "")
            if [[ -n "$risk_result" ]]; then
                local overall_risk
                overall_risk=$(echo "$risk_result" | jq -r '.overall_risk // 50' 2>/dev/null || echo "50")
                if [[ "$overall_risk" -gt 80 ]]; then
                    daemon_log WARN "HIGH RISK (${overall_risk}%) predicted for issue #${issue_num} — upgrading model"
                    export CLAUDE_MODEL="$(_smart_model high_risk opus)"
                elif [[ "$overall_risk" -lt 30 ]]; then
                    daemon_log INFO "LOW RISK (${overall_risk}%) predicted for issue #${issue_num}"
                fi
            fi
        fi
    fi

    # Check disk space before spawning
    local free_space_kb
    free_space_kb=$(df -k "." 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$free_space_kb" ]] && [[ "$free_space_kb" -lt 1048576 ]] 2>/dev/null; then
        daemon_log WARN "Low disk space ($(( free_space_kb / 1024 ))MB) — skipping issue #${issue_num}"
        return 1
    fi

    local work_dir="" branch_name="daemon/issue-${issue_num}"

    if [[ "$WATCH_MODE" == "org" && -n "$repo_full_name" ]]; then
        # Org mode: use cloned repo directory
        local owner="${repo_full_name%%/*}"
        local repo="${repo_full_name##*/}"
        work_dir=$(daemon_ensure_repo "$owner" "$repo") || return 1

        # Create branch in the cloned repo
        (
            cd "$work_dir"
            git checkout -B "$branch_name" "${BASE_BRANCH}" 2>/dev/null
        ) || {
            daemon_log ERROR "Failed to create branch in ${repo_full_name}"
            return 1
        }
        daemon_log INFO "Org mode: working in ${work_dir} (${repo_full_name})"
    else
        # Standard mode: use git worktree
        work_dir="${WORKTREE_DIR}/daemon-issue-${issue_num}"

        # Serialize worktree operations with a lock file (run in subshell to auto-close FD)
        mkdir -p "$WORKTREE_DIR"
        local wt_ok=0
        (
            flock -w 30 200 2>/dev/null || true

            # Clean up stale worktree if it exists
            if [[ -d "$work_dir" ]]; then
                git worktree remove "$work_dir" --force 2>/dev/null || true
            fi
            git branch -D "$branch_name" 2>/dev/null || true

            git worktree add "$work_dir" -b "$branch_name" "$BASE_BRANCH" 2>/dev/null
        ) 200>"${WORKTREE_DIR}/.worktree.lock"
        wt_ok=$?

        if [[ $wt_ok -ne 0 ]]; then
            daemon_log ERROR "Failed to create worktree for issue #${issue_num}"
            return 1
        fi
        daemon_log INFO "Worktree created at ${work_dir}"
    fi

    # If template is "composed", copy the composed spec into the worktree
    if [[ "$PIPELINE_TEMPLATE" == "composed" ]]; then
        local _src_composed="${REPO_DIR:-.}/.claude/pipeline-artifacts/composed-pipeline.json"
        if [[ -f "$_src_composed" ]]; then
            local _dst_artifacts="${work_dir}/.claude/pipeline-artifacts"
            mkdir -p "$_dst_artifacts"
            cp "$_src_composed" "$_dst_artifacts/composed-pipeline.json" 2>/dev/null || true
            daemon_log INFO "Copied composed pipeline spec to worktree"
        fi
    fi

    # Build pipeline args
    # Every optional knob is read with a :- default. Under `set -u` a bare
    # "$SKIP_GATES" aborts the whole daemon when the caller has not exported the
    # var, which is exactly how the spawn path died when invoked outside a fully
    # initialised daemon config. MAX_RESTARTS_CFG/FAST_TEST_CMD_CFG below already
    # did this; these were the inconsistent ones.
    local pipeline_args=("start" "--issue" "$issue_num" "--pipeline" "${PIPELINE_TEMPLATE:-standard}")
    if [[ "${SKIP_GATES:-false}" == "true" ]]; then
        pipeline_args+=("--skip-gates")
    fi
    if [[ -n "${MODEL:-}" ]]; then
        pipeline_args+=("--model" "$MODEL")
    fi
    if [[ -n "${EFFORT_LEVEL:-}" ]]; then
        pipeline_args+=("--effort" "$EFFORT_LEVEL")
    fi
    if [[ -n "${FALLBACK_MODEL:-}" ]]; then
        pipeline_args+=("--fallback-model" "$FALLBACK_MODEL")
    fi
    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        pipeline_args+=("--no-github")
    fi
    # Pass session restart config
    if [[ "${MAX_RESTARTS_CFG:-0}" -gt 0 ]]; then
        pipeline_args+=("--max-restarts" "$MAX_RESTARTS_CFG")
    fi
    # Pass fast test command
    if [[ -n "${FAST_TEST_CMD_CFG:-}" ]]; then
        pipeline_args+=("--fast-test-cmd" "$FAST_TEST_CMD_CFG")
    fi

    # Append any extra pipeline args (from retry escalation, etc.)
    if [[ ${#extra_pipeline_args[@]} -gt 0 ]]; then
        pipeline_args+=("${extra_pipeline_args[@]}")
    fi

    # Ensure issue type is available for skill injection in pipeline
    export INTELLIGENCE_ISSUE_TYPE="${INTELLIGENCE_ISSUE_TYPE:-backend}"

    # Run pipeline — tmux window (watchable) or background subprocess
    local spawn_in_tmux
    spawn_in_tmux=$(_smart_int "spawn_in_tmux" 1)
    echo -e "\n\n===== Pipeline run $(date -u +%Y-%m-%dT%H:%M:%SZ) =====" >> "$LOG_DIR/issue-${issue_num}.log" 2>/dev/null || true

    local pid=0
    if [[ "$spawn_in_tmux" == "1" ]] && command -v tmux >/dev/null 2>&1; then
        # Spawn in tmux window for visibility
        local _tmux_session="sw-pipelines"
        local _tmux_win="p-${issue_num}"
        if ! tmux has-session -t "$_tmux_session" 2>/dev/null; then
            tmux new-session -d -s "$_tmux_session" -n "daemon" 2>/dev/null || true
        fi
        tmux new-window -t "$_tmux_session" -n "$_tmux_win" 2>/dev/null || true
        local _tmux_cmd="cd '${work_dir}' && '${SCRIPT_DIR}/sw-pipeline.sh' ${pipeline_args[*]} 2>&1 | tee -a '${LOG_DIR}/issue-${issue_num}.log'"
        tmux send-keys -t "${_tmux_session}:${_tmux_win}" "$_tmux_cmd" Enter 2>/dev/null || true
        # Store heartbeat
        local _hb_dir="$HOME/.shipwright/heartbeats"
        mkdir -p "$_hb_dir"
        local _pane_id
        _pane_id=$(tmux list-panes -t "${_tmux_session}:${_tmux_win}" -F '#{pane_id}' 2>/dev/null | head -1 || true)
        cat > "${_hb_dir}/pipeline-${issue_num}.json" <<HB_EOF
{"job_id":"pipeline-${issue_num}","pane_id":"${_pane_id:-}","window":"${_tmux_win}","session":"${_tmux_session}","status":"running","started_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
HB_EOF
        # Get PID from tmux pane
        pid=$(tmux list-panes -t "${_tmux_session}:${_tmux_win}" -F '#{pane_pid}' 2>/dev/null | head -1 || echo "0")
        daemon_log INFO "Pipeline spawned in tmux: ${_tmux_session}:${_tmux_win}"
    else
        # Fallback: background subprocess (original behavior)
        (
            trap '' HUP
            cd "$work_dir" || exit 1
            exec "$SCRIPT_DIR/sw-pipeline.sh" "${pipeline_args[@]}"
        ) >> "$LOG_DIR/issue-${issue_num}.log" 2>&1 200>&- &
        pid=$!
    fi

    daemon_log INFO "Pipeline started for issue #${issue_num} (PID: ${pid})"

    # Track the job (include repo and goal for org mode)
    daemon_track_job "$issue_num" "$pid" "$work_dir" "$issue_title" "$repo_full_name" "$issue_goal"
    emit_event "daemon.spawn" "issue=$issue_num" "pid=$pid" "repo=${repo_full_name:-local}"
    "$SCRIPT_DIR/sw-tracker.sh" notify "spawn" "$issue_num" 2>/dev/null || true

    # Comment on the issue
    if [[ "$NO_GITHUB" != "true" ]]; then
        local gh_args=()
        if [[ -n "$repo_full_name" ]]; then
            gh_args+=("--repo" "$repo_full_name")
        fi
        gh issue comment "$issue_num" ${gh_args[@]+"${gh_args[@]}"} --body "## 🤖 Pipeline Started

**Delivering:** ${issue_title}

| Field | Value |
|-------|-------|
| Template | \`${PIPELINE_TEMPLATE}\` |
| Branch | \`${branch_name}\` |
| Repo | \`${repo_full_name:-local}\` |
| Started | $(now_iso) |

_Progress updates will appear below as the pipeline advances through each stage._" 2>/dev/null || true
    fi
}

# ─── Track Job ───────────────────────────────────────────────────────────────

daemon_track_job() {
    local issue_num="$1" pid="$2" worktree="$3" title="${4:-}" repo="${5:-}" goal="${6:-}"

    # Write to SQLite (non-blocking, best-effort)
    if type db_save_job >/dev/null 2>&1; then
        local job_id="daemon-${issue_num}-$(now_epoch)"
        db_save_job "$job_id" "$issue_num" "$title" "$pid" "$worktree" "" "${PIPELINE_TEMPLATE:-autonomous}" "$goal" 2>/dev/null || true
    fi

    # Always write to JSON state file (primary for now)
    locked_state_update \
        --argjson num "$issue_num" \
        --argjson pid "$pid" \
        --arg wt "$worktree" \
        --arg title "$title" \
        --arg started "$(now_iso)" \
        --arg repo "$repo" \
        --arg goal "$goal" \
        '.active_jobs += [{
            issue: $num,
            pid: $pid,
            worktree: $wt,
            title: $title,
            started_at: $started,
            repo: $repo,
            goal: $goal
        }]'
}

# ─── Reap Completed Jobs ────────────────────────────────────────────────────

daemon_reap_completed() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return
    fi

    local jobs
    jobs=$(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null || true)
    if [[ -z "$jobs" ]]; then
        return
    fi

    local _retry_spawned_for=""

    while IFS= read -r job; do
        local issue_num pid worktree
        issue_num=$(echo "$job" | jq -r '.issue // empty')
        pid=$(echo "$job" | jq -r '.pid // empty')
        worktree=$(echo "$job" | jq -r '.worktree // empty')

        # Skip malformed entries (corrupted state file)
        [[ -z "$issue_num" || ! "$issue_num" =~ ^[0-9]+$ ]] && continue
        [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && continue

        # Check if process is still running
        if kill -0 "$pid" 2>/dev/null; then
            # Guard against PID reuse using two-tier detection:
            #   Tier 1 (always): Verify PID command matches pipeline process
            #   Tier 2 (>1 hour): Force-reap if process doesn't match
            local _proc_cmd _is_pipeline=false
            _proc_cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
            if [[ -n "$_proc_cmd" ]] && echo "$_proc_cmd" | grep -qE 'sw-pipeline|sw-loop|claude|shipwright' 2>/dev/null; then
                _is_pipeline=true
            fi

            # Also verify via process start time if available (detects PID reuse)
            local _proc_start _started_at _start_e _age_s _pid_reused=false
            _started_at=$(echo "$job" | jq -r '.started_at // empty')
            if [[ -n "$_started_at" ]]; then
                _start_e=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$_started_at" +%s 2>/dev/null || date -d "$_started_at" +%s 2>/dev/null || echo "0")
                _age_s=$(( $(now_epoch) - ${_start_e:-0} ))
                # On macOS/Linux, check process start time to detect PID reuse
                _proc_start=$(ps -p "$pid" -o lstart= 2>/dev/null || true)
                if [[ -n "$_proc_start" && -n "$_started_at" ]]; then
                    local _proc_start_epoch
                    _proc_start_epoch=$(date -j -f "%a %b %d %H:%M:%S %Y" "$_proc_start" +%s 2>/dev/null || date -d "$_proc_start" +%s 2>/dev/null || echo "0")
                    # If process started more than 60s after our job, PID was reused
                    if [[ "${_proc_start_epoch:-0}" -gt 0 && "${_start_e:-0}" -gt 0 ]]; then
                        local _start_diff=$(( _proc_start_epoch - _start_e ))
                        if [[ "$_start_diff" -gt 60 || "$_start_diff" -lt -60 ]]; then
                            _pid_reused=true
                            daemon_log WARN "PID reuse detected for job #${issue_num}: PID $pid started ${_start_diff}s off from job start"
                        fi
                    fi
                fi
            else
                _age_s=0
            fi

            # Decision: reap if PID was reused OR (not a pipeline process AND running > 1 hour)
            if [[ "$_pid_reused" == "true" ]]; then
                daemon_log WARN "Stale job #${issue_num}: PID $pid reused by another process — force-reaping"
                emit_event "daemon.stale_dead" "issue=$issue_num" "pid=$pid" "elapsed_s=${_age_s:-0}" "reason=pid_reuse"
                # Fall through to reap logic
            elif [[ "$_is_pipeline" == "false" && "${_age_s:-0}" -gt 3600 ]]; then
                daemon_log WARN "Stale job #${issue_num}: PID $pid running ${_age_s}s but not a pipeline process — force-reaping"
                emit_event "daemon.stale_dead" "issue=$issue_num" "pid=$pid" "elapsed_s=$_age_s" "reason=wrong_process"
                # Fall through to reap logic
            else
                continue
            fi
        fi

        # Process is dead — determine exit code
        # Note: wait returns 127 if process was already reaped (e.g., by init)
        # In that case, check pipeline log for success/failure indicators
        local exit_code=0
        wait "$pid" 2>/dev/null || exit_code=$?
        if [[ "$exit_code" -eq 127 ]]; then
            # Process already reaped — check log file for real outcome
            local issue_log="$LOG_DIR/issue-${issue_num}.log"
            if [[ -f "$issue_log" ]]; then
                if grep -q "Pipeline completed successfully" "$issue_log" 2>/dev/null; then
                    exit_code=0
                elif grep -q "Pipeline failed\|ERROR.*stage.*failed\|exited with status" "$issue_log" 2>/dev/null; then
                    exit_code=1
                else
                    daemon_log WARN "Could not determine exit code for issue #${issue_num} (PID ${pid} already reaped) — marking as failure"
                    exit_code=1
                fi
            else
                exit_code=1
            fi
        fi

        local started_at duration_str="" start_epoch=0 end_epoch=0
        started_at=$(echo "$job" | jq -r '.started_at // empty')
        if [[ -n "$started_at" ]]; then
            # macOS date -j for parsing ISO dates (TZ=UTC to parse Z-suffix correctly)
            start_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || date -d "$started_at" +%s 2>/dev/null || echo "0")
            end_epoch=$(now_epoch)
            if [[ "$start_epoch" -gt 0 ]]; then
                duration_str=$(format_duration $((end_epoch - start_epoch)))
            fi
        fi

        local result_str="success"
        [[ "$exit_code" -ne 0 ]] && result_str="failure"
        local dur_s=0
        [[ "$start_epoch" -gt 0 ]] && dur_s=$((end_epoch - start_epoch))
        emit_event "daemon.reap" "issue=$issue_num" "result=$result_str" "duration_s=$dur_s"

        # Update SQLite (mark job complete/failed)
        if type db_complete_job >/dev/null 2>&1 && type db_fail_job >/dev/null 2>&1; then
            local _db_job_id="daemon-${issue_num}-${start_epoch}"
            if [[ "$exit_code" -eq 0 ]]; then
                db_complete_job "$_db_job_id" "$result_str" 2>/dev/null || true
            else
                db_fail_job "$_db_job_id" "$result_str" 2>/dev/null || true
            fi
        fi

        if [[ "$exit_code" -eq 0 ]]; then
            daemon_on_success "$issue_num" "$duration_str"
        else
            daemon_on_failure "$issue_num" "$exit_code" "$duration_str"

            # Cancel any lingering in_progress GitHub Check Runs for failed job
            if [[ "${NO_GITHUB:-false}" != "true" && -n "$worktree" ]]; then
                local check_ids_file="${worktree}/.claude/pipeline-artifacts/check-run-ids.json"
                if [[ -f "$check_ids_file" ]]; then
                    daemon_log INFO "Cancelling in-progress check runs for issue #${issue_num}"
                    local _stage
                    while IFS= read -r _stage; do
                        [[ -z "$_stage" ]] && continue
                        # Direct API call since we're in daemon context
                        local _run_id
                        _run_id=$(jq -r --arg s "$_stage" '.[$s] // empty' "$check_ids_file" 2>/dev/null || true)
                        if [[ -n "$_run_id" && "$_run_id" != "null" ]]; then
                            local _detected
                            _detected=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]\(.*\)\.git$|\1|' || true)
                            if [[ -n "$_detected" ]]; then
                                local _owner="${_detected%%/*}" _repo="${_detected##*/}"
                                gh api "repos/${_owner}/${_repo}/check-runs/${_run_id}" \
                                    --method PATCH \
                                    --field status=completed \
                                    --field conclusion=cancelled \
                                    --silent --timeout 30 2>/dev/null || true
                            fi
                        fi
                    done < <(jq -r 'keys[]' "$check_ids_file" 2>/dev/null || true)
                fi
            fi
        fi

        # Finalize memory (capture failure patterns for future runs)
        if type memory_finalize_pipeline >/dev/null 2>&1; then
            local _job_state _job_artifacts
            _job_state="${worktree:-.}/.claude/pipeline-state.md"
            _job_artifacts="${worktree:-.}/.claude/pipeline-artifacts"
            memory_finalize_pipeline "$_job_state" "$_job_artifacts" 2>/dev/null || true
        fi

        # Trigger learning after pipeline reap
        if type optimize_full_analysis &>/dev/null; then
            optimize_full_analysis &>/dev/null &
            wait $! 2>/dev/null || true
        fi

        # Clean up progress tracking for this job
        daemon_clear_progress "$issue_num"

        # Release claim lock (label-based coordination)
        local reap_machine_name
        reap_machine_name=$(jq -r '.machines[] | select(.role == "primary") | .name' "$HOME/.shipwright/machines.json" 2>/dev/null || hostname -s)
        release_claim "$issue_num" "$reap_machine_name"

        # Always remove the OLD job entry from active_jobs to prevent
        # re-reaping of the dead PID on the next cycle.  When a retry was
        # spawned, daemon_spawn_pipeline already added a fresh entry with
        # the new PID — we must not leave the stale one behind.
        locked_state_update --argjson num "$issue_num" \
            --argjson old_pid "${pid:-0}" \
            '.active_jobs = [.active_jobs[] | select(.issue != $num or .pid != $old_pid)]'
        untrack_priority_job "$issue_num"

        if [[ "$_retry_spawned_for" == "$issue_num" ]]; then
            daemon_log INFO "Retry spawned for issue #${issue_num} — skipping worktree cleanup"
        else
            # Clean up worktree (skip for org-mode clones — they persist)
            local job_repo
            job_repo=$(echo "$job" | jq -r '.repo // ""')
            if [[ -z "$job_repo" ]] && [[ -d "$worktree" ]]; then
                git worktree remove "$worktree" --force 2>/dev/null || true
                daemon_log INFO "Cleaned worktree: $worktree"
                git branch -D "daemon/issue-${issue_num}" 2>/dev/null || true
            elif [[ -n "$job_repo" ]]; then
                daemon_log INFO "Org-mode: preserving clone for ${job_repo}"
            fi
        fi

        # Dequeue next issue if available AND we have capacity
        # NOTE: locked_get_active_count prevents TOCTOU race with the
        # active_jobs removal above.  A tiny window remains between
        # the count read and dequeue_next's own lock acquisition, but
        # dequeue_next is itself locked, so the worst case is a
        # missed dequeue that the next poll cycle will pick up.
        local current_active
        current_active=$(locked_get_active_count)
        if [[ "$current_active" -lt "$MAX_PARALLEL" ]]; then
            local next_issue_key
            next_issue_key=$(dequeue_next)
            if [[ -n "$next_issue_key" ]]; then
                local next_issue_num="$next_issue_key" next_repo=""
                [[ "$next_issue_key" == *:* ]] && next_repo="${next_issue_key%%:*}" && next_issue_num="${next_issue_key##*:}"
                local next_title
                next_title=$(jq -r --arg n "$next_issue_key" '.titles[$n] // ""' "$STATE_FILE" 2>/dev/null || true)
                daemon_log INFO "Dequeuing issue #${next_issue_num}${next_repo:+, repo=${next_repo}}: ${next_title}"
                daemon_spawn_pipeline "$next_issue_num" "$next_title" "$next_repo"
            fi
        fi
    done <<< "$jobs"
}

# ─── Success Handler ────────────────────────────────────────────────────────

daemon_on_success() {
    local issue_num="$1" duration="${2:-}"
    local gh_timeout
    gh_timeout=$(_smart_int "daemon.gh_timeout_seconds" 30)

    # Reset consecutive failure tracking on any success. Passing the issue also
    # drops its persisted failure signature — the streak ended here.
    reset_failure_tracking "$issue_num"

    daemon_log SUCCESS "Pipeline completed for issue #${issue_num} (${duration:-unknown})"

    # Record pipeline duration for adaptive threshold learning
    if [[ -n "$duration" && "$duration" != "unknown" ]]; then
        # Parse duration string back to seconds (e.g. "5m 30s" → 330)
        local dur_secs=0
        local _h _m _s
        _h=$(echo "$duration" | grep -oE '[0-9]+h' | grep -oE '[0-9]+' || true)
        _m=$(echo "$duration" | grep -oE '[0-9]+m' | grep -oE '[0-9]+' || true)
        _s=$(echo "$duration" | grep -oE '[0-9]+s' | grep -oE '[0-9]+' || true)
        dur_secs=$(( ${_h:-0} * 3600 + ${_m:-0} * 60 + ${_s:-0} ))
        if [[ "$dur_secs" -gt 0 ]]; then
            record_pipeline_duration "$PIPELINE_TEMPLATE" "$dur_secs" "success"
            record_scaling_outcome "$MAX_PARALLEL" "success"
        fi
    fi

    # Record in completed list + clear retry count for this issue
    locked_state_update \
        --argjson num "$issue_num" \
        --arg result "success" \
        --arg dur "${duration:-unknown}" \
        --arg completed_at "$(now_iso)" \
        '.completed += [{
            issue: $num,
            result: $result,
            duration: $dur,
            completed_at: $completed_at
        }] | .completed = .completed[-500:]
        | del(.retry_counts[($num | tostring)])
        | if (.failure_signatures | type) == "object"
          then del(.failure_signatures[($num | tostring)]) else . end'

    if [[ "$NO_GITHUB" != "true" ]]; then
        # Remove watch label, add success label
        _timeout "$gh_timeout" gh issue edit "$issue_num" \
            --remove-label "$ON_SUCCESS_REMOVE_LABEL" \
            --add-label "$ON_SUCCESS_ADD_LABEL" 2>/dev/null || true

        # Comment on issue
        _timeout "$gh_timeout" gh issue comment "$issue_num" --body "## ✅ Pipeline Complete

The autonomous pipeline finished successfully.

| Field | Value |
|-------|-------|
| Duration | ${duration:-unknown} |
| Completed | $(now_iso) |

Check the associated PR for the implementation." 2>/dev/null || true

        # Optionally close the issue
        if [[ "$ON_SUCCESS_CLOSE_ISSUE" == "true" ]]; then
            _timeout "$gh_timeout" gh issue close "$issue_num" 2>/dev/null || true
        fi
    fi

    notify "Pipeline Complete — Issue #${issue_num}" \
        "Duration: ${duration:-unknown}" "success"
    "$SCRIPT_DIR/sw-tracker.sh" notify "completed" "$issue_num" 2>/dev/null || true

    # PM agent: record success for learning
    if [[ -x "$SCRIPT_DIR/sw-pm.sh" ]]; then
        bash "$SCRIPT_DIR/sw-pm.sh" learn "$issue_num" success 2>/dev/null || true
    fi
}

# ─── Failure Classification ─────────────────────────────────────────────────

