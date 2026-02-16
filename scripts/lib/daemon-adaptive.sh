# daemon-adaptive.sh — Adaptive intervals, progress tracking, learning (for sw-daemon.sh)
# Source from sw-daemon.sh. Requires state, policy, helpers.
[[ -n "${_DAEMON_ADAPTIVE_LOADED:-}" ]] && return 0
_DAEMON_ADAPTIVE_LOADED=1

# Adapt poll interval based on queue state
# Empty queue 5+ cycles → 120s; queue has items → 30s; processing → 60s
get_adaptive_poll_interval() {
    local queue_depth="$1"
    local active_count="$2"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        echo "$POLL_INTERVAL"
        return
    fi

    if [[ "$queue_depth" -eq 0 && "$active_count" -eq 0 ]]; then
        EMPTY_QUEUE_CYCLES=$((EMPTY_QUEUE_CYCLES + 1))
    else
        EMPTY_QUEUE_CYCLES=0
    fi

    local interval="$POLL_INTERVAL"
    if [[ "$EMPTY_QUEUE_CYCLES" -ge 5 ]]; then
        interval=120
    elif [[ "$queue_depth" -gt 0 ]]; then
        interval=30
    else
        interval=60
    fi

    # Persist current setting for dashboard visibility
    local tuning_file="$HOME/.shipwright/optimization/daemon-tuning.json"
    mkdir -p "$HOME/.shipwright/optimization"
    local tmp_tuning="${tuning_file}.tmp.$$"
    if [[ -f "$tuning_file" ]]; then
        jq --argjson pi "$interval" --argjson eqc "$EMPTY_QUEUE_CYCLES" \
            '.poll_interval = $pi | .empty_queue_cycles = $eqc' \
            "$tuning_file" > "$tmp_tuning" 2>/dev/null && mv "$tmp_tuning" "$tuning_file"
    else
        jq -n --argjson pi "$interval" --argjson eqc "$EMPTY_QUEUE_CYCLES" \
            '{poll_interval: $pi, empty_queue_cycles: $eqc}' > "$tmp_tuning" \
            && mv "$tmp_tuning" "$tuning_file"
    fi

    echo "$interval"
}

# Rolling average cost per template from costs.json (last 10 runs)
get_adaptive_cost_estimate() {
    local template="${1:-autonomous}"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        echo "$EST_COST_PER_JOB"
        return
    fi

    local costs_file="$HOME/.shipwright/costs.json"
    if [[ ! -f "$costs_file" ]]; then
        echo "$EST_COST_PER_JOB"
        return
    fi

    local avg_cost
    avg_cost=$(jq -r --arg tpl "$template" '
        [.sessions // [] | .[] | select(.template == $tpl) | .total_cost_usd // 0] |
        .[-10:] | if length > 0 then (add / length) else null end
    ' "$costs_file" 2>/dev/null || echo "")

    if [[ -n "$avg_cost" && "$avg_cost" != "null" && "$avg_cost" != "0" ]]; then
        echo "$avg_cost"
    else
        echo "$EST_COST_PER_JOB"
    fi
}

# Per-stage adaptive heartbeat timeout from learned stage durations
get_adaptive_heartbeat_timeout() {
    local stage="${1:-unknown}"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        echo "${HEALTH_HEARTBEAT_TIMEOUT:-120}"
        return
    fi

    # Stage-specific defaults (daemon-health.sh when sourced, else policy_get, else literal)
    local default_timeout="${HEALTH_HEARTBEAT_TIMEOUT:-120}"
    if type daemon_health_timeout_for_stage &>/dev/null 2>&1; then
        default_timeout=$(daemon_health_timeout_for_stage "$stage" "$default_timeout")
    elif type policy_get &>/dev/null 2>&1; then
        local policy_stage
        policy_stage=$(policy_get ".daemon.stage_timeouts.$stage" "")
        [[ -n "$policy_stage" && "$policy_stage" =~ ^[0-9]+$ ]] && default_timeout="$policy_stage"
    else
        case "$stage" in
            build)  default_timeout=300 ;;
            test)   default_timeout=180 ;;
            review|compound_quality) default_timeout=180 ;;
            lint|format|intake|plan|design) default_timeout=60 ;;
        esac
    fi
    [[ "$default_timeout" =~ ^[0-9]+$ ]] || default_timeout="${HEALTH_HEARTBEAT_TIMEOUT:-120}"

    local durations_file="$HOME/.shipwright/optimization/stage-durations.json"
    if [[ ! -f "$durations_file" ]]; then
        echo "$default_timeout"
        return
    fi

    local learned_duration
    learned_duration=$(jq -r --arg s "$stage" \
        '.stages[$s].p90_duration_s // 0' "$durations_file" 2>/dev/null || echo "0")

    if [[ "$learned_duration" -gt 0 ]]; then
        # 150% of p90 duration, floor of 60s
        local adaptive_timeout=$(( (learned_duration * 3) / 2 ))
        [[ "$adaptive_timeout" -lt 60 ]] && adaptive_timeout=60
        echo "$adaptive_timeout"
    else
        echo "$default_timeout"
    fi
}

# Adaptive stale pipeline timeout using 95th percentile of historical durations
get_adaptive_stale_timeout() {
    local template="${1:-autonomous}"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        echo "${HEALTH_STALE_TIMEOUT:-1800}"
        return
    fi

    local durations_file="$HOME/.shipwright/optimization/pipeline-durations.json"
    if [[ ! -f "$durations_file" ]]; then
        echo "${HEALTH_STALE_TIMEOUT:-1800}"
        return
    fi

    local p95_duration
    p95_duration=$(jq -r --arg tpl "$template" \
        '.templates[$tpl].p95_duration_s // 0' "$durations_file" 2>/dev/null || echo "0")

    if [[ "$p95_duration" -gt 0 ]]; then
        # 1.5x safety margin, clamped 600s-7200s
        local adaptive_timeout=$(( (p95_duration * 3) / 2 ))
        [[ "$adaptive_timeout" -lt 600 ]] && adaptive_timeout=600
        [[ "$adaptive_timeout" -gt 7200 ]] && adaptive_timeout=7200
        echo "$adaptive_timeout"
    else
        echo "${HEALTH_STALE_TIMEOUT:-1800}"
    fi
}

# Record pipeline duration for future threshold learning
record_pipeline_duration() {
    local template="$1" duration_s="$2" result="$3"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        return
    fi
    [[ ! "$duration_s" =~ ^[0-9]+$ ]] && return

    local durations_file="$HOME/.shipwright/optimization/pipeline-durations.json"
    mkdir -p "$HOME/.shipwright/optimization"

    if [[ ! -f "$durations_file" ]]; then
        echo '{"templates":{}}' > "$durations_file"
    fi

    local tmp_dur="${durations_file}.tmp.$$"
    jq --arg tpl "$template" --argjson dur "$duration_s" --arg res "$result" --arg ts "$(now_iso)" '
        .templates[$tpl] = (
            (.templates[$tpl] // {durations: [], p95_duration_s: 0}) |
            .durations = ((.durations + [{duration_s: $dur, result: $res, ts: $ts}]) | .[-50:]) |
            .p95_duration_s = (
                [.durations[].duration_s] | sort |
                if length > 0 then .[((length * 95 / 100) | floor)] else 0 end
            )
        )
    ' "$durations_file" > "$tmp_dur" 2>/dev/null && mv "$tmp_dur" "$durations_file"
}

# ─── Progress-Based Health Monitoring ─────────────────────────────────────────
# Instead of killing jobs after a static timeout, we check for forward progress.
# Progress signals: stage transitions, iteration advances, git diff growth, new files.
# Graduated response: healthy → slowing → stalled → stuck → kill.

PROGRESS_DIR="${PROGRESS_DIR:-$HOME/.shipwright/progress}"

# Collect a progress snapshot for an active job
# Returns JSON with stage, iteration, diff_lines, files_changed
daemon_collect_snapshot() {
    local issue_num="$1" worktree="$2" pid="$3"

    local stage="" iteration=0 diff_lines=0 files_changed=0 last_error=""

    # Get stage and iteration from heartbeat (fastest source)
    local heartbeat_dir="$HOME/.shipwright/heartbeats"
    if [[ -d "$heartbeat_dir" ]]; then
        local hb_file
        for hb_file in "$heartbeat_dir"/*.json; do
            [[ ! -f "$hb_file" ]] && continue
            local hb_pid
            hb_pid=$(jq -r '.pid // 0' "$hb_file" 2>/dev/null || echo 0)
            if [[ "$hb_pid" == "$pid" ]]; then
                stage=$(jq -r '.stage // "unknown"' "$hb_file" 2>/dev/null || echo "unknown")
                iteration=$(jq -r '.iteration // 0' "$hb_file" 2>/dev/null || echo 0)
                [[ "$iteration" == "null" ]] && iteration=0
                break
            fi
        done
    fi

    # Fallback: read stage from pipeline-state.md in worktree
    if [[ -z "$stage" || "$stage" == "unknown" ]] && [[ -d "$worktree" ]]; then
        local state_file="$worktree/.claude/pipeline-state.md"
        if [[ -f "$state_file" ]]; then
            stage=$(grep -m1 '^current_stage:' "$state_file" 2>/dev/null | sed 's/^current_stage: *//' || echo "unknown")
        fi
    fi

    # Get git diff stats from worktree (how much code has been written)
    if [[ -d "$worktree/.git" ]] || [[ -f "$worktree/.git" ]]; then
        diff_lines=$(cd "$worktree" && git diff --stat 2>/dev/null | tail -1 | grep -o '[0-9]* insertion' | grep -o '[0-9]*' || echo "0")
        [[ -z "$diff_lines" ]] && diff_lines=0
        files_changed=$(cd "$worktree" && git diff --name-only 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        # Also count untracked files the agent has created
        local untracked
        untracked=$(cd "$worktree" && git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        files_changed=$((files_changed + untracked))
    fi

    # Check last error from error log
    if [[ -d "$worktree" ]]; then
        local error_log="$worktree/.claude/pipeline-artifacts/error-log.jsonl"
        if [[ -f "$error_log" ]]; then
            last_error=$(tail -1 "$error_log" 2>/dev/null | jq -r '.signature // ""' 2>/dev/null || echo "")
        fi
    fi

    # Output JSON snapshot
    jq -n \
        --arg stage "$stage" \
        --argjson iteration "${iteration:-0}" \
        --argjson diff_lines "${diff_lines:-0}" \
        --argjson files_changed "${files_changed:-0}" \
        --arg last_error "$last_error" \
        --arg ts "$(now_iso)" \
        '{
            stage: $stage,
            iteration: $iteration,
            diff_lines: $diff_lines,
            files_changed: $files_changed,
            last_error: $last_error,
            ts: $ts
        }'
}

# Assess job progress by comparing current snapshot to previous
# Returns: healthy | slowing | stalled | stuck
daemon_assess_progress() {
    local issue_num="$1" current_snapshot="$2"

    mkdir -p "$PROGRESS_DIR"
    local progress_file="$PROGRESS_DIR/issue-${issue_num}.json"

    # If no previous snapshot, store this one and return healthy
    if [[ ! -f "$progress_file" ]]; then
        jq -n \
            --argjson snap "$current_snapshot" \
            --arg issue "$issue_num" \
            '{
                issue: $issue,
                snapshots: [$snap],
                no_progress_count: 0,
                last_progress_at: $snap.ts,
                repeated_error_count: 0
            }' > "$progress_file"
        echo "healthy"
        return
    fi

    local prev_data
    prev_data=$(cat "$progress_file")

    # Get previous snapshot values
    local prev_stage prev_iteration prev_diff_lines prev_files prev_error prev_no_progress
    prev_stage=$(echo "$prev_data" | jq -r '.snapshots[-1].stage // "unknown"')
    prev_iteration=$(echo "$prev_data" | jq -r '.snapshots[-1].iteration // 0')
    prev_diff_lines=$(echo "$prev_data" | jq -r '.snapshots[-1].diff_lines // 0')
    prev_files=$(echo "$prev_data" | jq -r '.snapshots[-1].files_changed // 0')
    prev_error=$(echo "$prev_data" | jq -r '.snapshots[-1].last_error // ""')
    prev_no_progress=$(echo "$prev_data" | jq -r '.no_progress_count // 0')
    local prev_repeated_errors
    prev_repeated_errors=$(echo "$prev_data" | jq -r '.repeated_error_count // 0')

    # Get current values
    local cur_stage cur_iteration cur_diff cur_files cur_error
    cur_stage=$(echo "$current_snapshot" | jq -r '.stage')
    cur_iteration=$(echo "$current_snapshot" | jq -r '.iteration')
    cur_diff=$(echo "$current_snapshot" | jq -r '.diff_lines')
    cur_files=$(echo "$current_snapshot" | jq -r '.files_changed')
    cur_error=$(echo "$current_snapshot" | jq -r '.last_error')

    # Detect progress
    local has_progress=false

    # Stage advanced → clear progress
    if [[ "$cur_stage" != "$prev_stage" && "$cur_stage" != "unknown" ]]; then
        has_progress=true
        daemon_log INFO "Progress: issue #${issue_num} stage ${prev_stage} → ${cur_stage}"
    fi

    # Iteration increased → clear progress (agent is looping but advancing)
    if [[ "$cur_iteration" -gt "$prev_iteration" ]]; then
        has_progress=true
        daemon_log INFO "Progress: issue #${issue_num} iteration ${prev_iteration} → ${cur_iteration}"
    fi

    # Diff lines grew (agent is writing code)
    if [[ "$cur_diff" -gt "$prev_diff_lines" ]]; then
        has_progress=true
    fi

    # More files touched
    if [[ "$cur_files" -gt "$prev_files" ]]; then
        has_progress=true
    fi

    # Claude subprocess is alive and consuming CPU — agent is thinking/working
    # During build stage, Claude can spend 10+ minutes thinking before any
    # visible git changes appear.  Detect this as progress.
    if [[ "$has_progress" != "true" ]]; then
        local _pid_for_check
        _pid_for_check=$(echo "$current_snapshot" | jq -r '.pid // empty' 2>/dev/null || true)
        if [[ -z "$_pid_for_check" ]]; then
            # Fallback: get PID from active_jobs
            _pid_for_check=$(jq -r --argjson num "$issue_num" \
                '.active_jobs[] | select(.issue == ($num | tonumber)) | .pid' "$STATE_FILE" 2>/dev/null | head -1 || true)
        fi
        if [[ -n "$_pid_for_check" ]]; then
            # Check if any child process (claude) is alive and using CPU
            local child_cpu=0
            child_cpu=$(ps -o pid=,pcpu= -p "$_pid_for_check" 2>/dev/null | awk '{sum+=$2} END{printf "%d", sum+0}' || echo "0")
            if [[ "$child_cpu" -eq 0 ]]; then
                # Check children of the pipeline process
                child_cpu=$(pgrep -P "$_pid_for_check" 2>/dev/null | xargs -I{} ps -o pcpu= -p {} 2>/dev/null | awk '{sum+=$1} END{printf "%d", sum+0}' || echo "0")
            fi
            if [[ "${child_cpu:-0}" -gt 0 ]]; then
                has_progress=true
            fi
        fi
    fi

    # Detect repeated errors (same error signature hitting again)
    local repeated_errors="$prev_repeated_errors"
    if [[ -n "$cur_error" && "$cur_error" == "$prev_error" ]]; then
        repeated_errors=$((repeated_errors + 1))
    elif [[ -n "$cur_error" && "$cur_error" != "$prev_error" ]]; then
        # Different error — reset counter (agent is making different mistakes, that's progress)
        repeated_errors=0
    fi

    # Update no_progress counter
    local no_progress_count
    if [[ "$has_progress" == "true" ]]; then
        no_progress_count=0
        repeated_errors=0
    else
        no_progress_count=$((prev_no_progress + 1))
    fi

    # Update progress file (keep last 10 snapshots)
    local tmp_progress="${progress_file}.tmp.$$"
    jq \
        --argjson snap "$current_snapshot" \
        --argjson npc "$no_progress_count" \
        --argjson rec "$repeated_errors" \
        --arg ts "$(now_iso)" \
        '
        .snapshots = ((.snapshots + [$snap]) | .[-10:]) |
        .no_progress_count = $npc |
        .repeated_error_count = $rec |
        if $npc == 0 then .last_progress_at = $ts else . end
        ' "$progress_file" > "$tmp_progress" 2>/dev/null && mv "$tmp_progress" "$progress_file"

    # ── Vitals-based verdict (preferred over static thresholds) ──
    if type pipeline_compute_vitals &>/dev/null 2>&1 && type pipeline_health_verdict &>/dev/null 2>&1; then
        # Compute vitals using the worktree's pipeline state if available
        local _worktree_state=""
        local _worktree_artifacts=""
        local _worktree_dir
        _worktree_dir=$(jq -r --arg i "$issue_num" '.active_jobs[] | select(.issue == ($i | tonumber)) | .worktree // ""' "$STATE_FILE" 2>/dev/null || echo "")
        if [[ -n "$_worktree_dir" && -d "$_worktree_dir/.claude" ]]; then
            _worktree_state="$_worktree_dir/.claude/pipeline-state.md"
            _worktree_artifacts="$_worktree_dir/.claude/pipeline-artifacts"
        fi

        local _vitals_json
        _vitals_json=$(pipeline_compute_vitals "$_worktree_state" "$_worktree_artifacts" "$issue_num" 2>/dev/null) || true
        if [[ -n "$_vitals_json" && "$_vitals_json" != "{}" ]]; then
            local _health_verdict _health_score
            _health_verdict=$(echo "$_vitals_json" | jq -r '.verdict // "continue"' 2>/dev/null || echo "continue")
            _health_score=$(echo "$_vitals_json" | jq -r '.health_score // 50' 2>/dev/null || echo "50")

            emit_event "pipeline.vitals_check" \
                "issue=$issue_num" \
                "health_score=$_health_score" \
                "verdict=$_health_verdict" \
                "no_progress=$no_progress_count" \
                "repeated_errors=$repeated_errors"

            # Map vitals verdict to daemon verdict
            case "$_health_verdict" in
                continue)
                    echo "healthy"
                    return
                    ;;
                warn)
                    # Sluggish but not dead — equivalent to slowing
                    echo "slowing"
                    return
                    ;;
                intervene)
                    echo "stalled"
                    return
                    ;;
                abort)
                    echo "stuck"
                    return
                    ;;
            esac
        fi
    fi

    # ── Fallback: static threshold verdict ──
    local warn_threshold="${PROGRESS_CHECKS_BEFORE_WARN:-3}"
    local kill_threshold="${PROGRESS_CHECKS_BEFORE_KILL:-6}"

    # Stuck in same error loop — accelerate to kill
    if [[ "$repeated_errors" -ge 3 ]]; then
        echo "stuck"
        return
    fi

    if [[ "$no_progress_count" -ge "$kill_threshold" ]]; then
        echo "stuck"
    elif [[ "$no_progress_count" -ge "$warn_threshold" ]]; then
        echo "stalled"
    elif [[ "$no_progress_count" -ge 1 ]]; then
        echo "slowing"
    else
        echo "healthy"
    fi
}

# Clean up progress tracking for a completed/failed job
daemon_clear_progress() {
    local issue_num="$1"
    rm -f "$PROGRESS_DIR/issue-${issue_num}.json"
}

# Learn actual worker memory from peak RSS of pipeline processes
learn_worker_memory() {
    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        return
    fi
    if [[ ! -f "$STATE_FILE" ]]; then
        return
    fi

    local total_rss=0
    local process_count=0

    while IFS= read -r job; do
        local pid
        pid=$(echo "$job" | jq -r '.pid // empty')
        [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && continue
        if kill -0 "$pid" 2>/dev/null; then
            local rss_kb
            rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")
            [[ ! "$rss_kb" =~ ^[0-9]+$ ]] && rss_kb=0
            if [[ "$rss_kb" -gt 0 ]]; then
                total_rss=$((total_rss + rss_kb))
                process_count=$((process_count + 1))
            fi
        fi
    done < <(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null || true)

    if [[ "$process_count" -gt 0 ]]; then
        local avg_rss_gb=$(( total_rss / process_count / 1048576 ))
        # 125% headroom, minimum 1GB, max 16GB
        local learned_mem_gb=$(( (avg_rss_gb * 5 + 3) / 4 ))
        [[ "$learned_mem_gb" -lt 1 ]] && learned_mem_gb=1
        [[ "$learned_mem_gb" -gt 16 ]] && learned_mem_gb=16

        local tuning_file="$HOME/.shipwright/optimization/daemon-tuning.json"
        mkdir -p "$HOME/.shipwright/optimization"
        local tmp_tuning="${tuning_file}.tmp.$$"
        if [[ -f "$tuning_file" ]]; then
            jq --argjson mem "$learned_mem_gb" --argjson rss "$total_rss" --argjson cnt "$process_count" \
                '.learned_worker_mem_gb = $mem | .last_rss_total_kb = $rss | .last_rss_process_count = $cnt' \
                "$tuning_file" > "$tmp_tuning" 2>/dev/null && mv "$tmp_tuning" "$tuning_file"
        else
            jq -n --argjson mem "$learned_mem_gb" \
                '{learned_worker_mem_gb: $mem}' > "$tmp_tuning" && mv "$tmp_tuning" "$tuning_file"
        fi

        WORKER_MEM_GB="$learned_mem_gb"
    fi
}

# Record scaling outcome for learning optimal parallelism
record_scaling_outcome() {
    local parallelism="$1" result="$2"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        return
    fi

    local tuning_file="$HOME/.shipwright/optimization/daemon-tuning.json"
    mkdir -p "$HOME/.shipwright/optimization"
    local tmp_tuning="${tuning_file}.tmp.$$"
    if [[ -f "$tuning_file" ]]; then
        jq --argjson p "$parallelism" --arg r "$result" --arg ts "$(now_iso)" '
            .scaling_history = ((.scaling_history // []) + [{parallelism: $p, result: $r, ts: $ts}]) |
            .scaling_history |= .[-50:]
        ' "$tuning_file" > "$tmp_tuning" 2>/dev/null && mv "$tmp_tuning" "$tuning_file"
    else
        jq -n --argjson p "$parallelism" --arg r "$result" --arg ts "$(now_iso)" '
            {scaling_history: [{parallelism: $p, result: $r, ts: $ts}]}
        ' > "$tmp_tuning" && mv "$tmp_tuning" "$tuning_file"
    fi
}

# Get success rate at a given parallelism level (for gradual scaling decisions)
get_success_rate_at_parallelism() {
    local target_parallelism="$1"

    local tuning_file="$HOME/.shipwright/optimization/daemon-tuning.json"
    if [[ ! -f "$tuning_file" ]]; then
        echo "100"
        return
    fi

    local rate
    rate=$(jq -r --argjson p "$target_parallelism" '
        [.scaling_history // [] | .[] | select(.parallelism == $p)] |
        if length > 0 then
            ([.[] | select(.result == "success")] | length) * 100 / length | floor
        else 100 end
    ' "$tuning_file" 2>/dev/null || echo "100")

    echo "${rate:-100}"
}

# Adapt patrol limits based on hit rate
adapt_patrol_limits() {
    local findings="$1" max_issues="$2"

    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        return
    fi

    local tuning_file="$HOME/.shipwright/optimization/daemon-tuning.json"
    mkdir -p "$HOME/.shipwright/optimization"

    local new_max="$max_issues"
    if [[ "$findings" -ge "$max_issues" ]]; then
        # Consistently hitting limit — increase
        new_max=$((max_issues + 2))
        [[ "$new_max" -gt 20 ]] && new_max=20
    elif [[ "$findings" -eq 0 ]]; then
        # Finds nothing — reduce
        if [[ "$max_issues" -gt 3 ]]; then
            new_max=$((max_issues - 1))
        else
            new_max=3
        fi
    fi

    local tmp_tuning="${tuning_file}.tmp.$$"
    if [[ -f "$tuning_file" ]]; then
        jq --argjson pm "$new_max" --argjson lf "$findings" --arg ts "$(now_iso)" \
            '.patrol_max_issues = $pm | .last_patrol_findings = $lf | .patrol_adapted_at = $ts' \
            "$tuning_file" > "$tmp_tuning" 2>/dev/null && mv "$tmp_tuning" "$tuning_file"
    else
        jq -n --argjson pm "$new_max" --argjson lf "$findings" --arg ts "$(now_iso)" \
            '{patrol_max_issues: $pm, last_patrol_findings: $lf, patrol_adapted_at: $ts}' \
            > "$tmp_tuning" && mv "$tmp_tuning" "$tuning_file"
    fi
}

# Load adaptive patrol limits from tuning config
load_adaptive_patrol_limits() {
    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        return
    fi

    local tuning_file="$HOME/.shipwright/optimization/daemon-tuning.json"
    if [[ ! -f "$tuning_file" ]]; then
        return
    fi

    local adaptive_max_issues
    adaptive_max_issues=$(jq -r '.patrol_max_issues // 0' "$tuning_file" 2>/dev/null || echo "0")
    if [[ "$adaptive_max_issues" -gt 0 ]]; then
        PATROL_MAX_ISSUES="$adaptive_max_issues"
    fi
}
