# daemon-poll.sh — Poll loop, health, scale, cleanup (for sw-daemon.sh)
# Source from sw-daemon.sh. Requires daemon-health, state, dispatch, failure, patrol.
[[ -n "${_DAEMON_POLL_LOADED:-}" ]] && return 0
_DAEMON_POLL_LOADED=1

# Defaults for variables normally set by sw-daemon.sh (safe under set -u).
DAEMON_DIR="${DAEMON_DIR:-${HOME}/.shipwright}"
STATE_FILE="${STATE_FILE:-${DAEMON_DIR}/daemon-state.json}"
PAUSE_FLAG="${PAUSE_FLAG:-${DAEMON_DIR}/daemon-pause.flag}"
SHUTDOWN_FLAG="${SHUTDOWN_FLAG:-${DAEMON_DIR}/daemon.shutdown}"
EVENTS_FILE="${EVENTS_FILE:-${DAEMON_DIR}/events.jsonl}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NO_GITHUB="${NO_GITHUB:-false}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
WATCH_LABEL="${WATCH_LABEL:-shipwright}"
WATCH_MODE="${WATCH_MODE:-repo}"
PIPELINE_TEMPLATE="${PIPELINE_TEMPLATE:-autonomous}"
ISSUE_LIMIT="${ISSUE_LIMIT:-100}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
BACKOFF_SECS="${BACKOFF_SECS:-0}"
POLL_CYCLE_COUNT="${POLL_CYCLE_COUNT:-0}"

# Source sub-modules
if [[ -f "${SCRIPT_DIR}/lib/daemon-poll-github.sh" ]]; then
    source "${SCRIPT_DIR}/lib/daemon-poll-github.sh"
fi
if [[ -f "${SCRIPT_DIR}/lib/daemon-poll-health.sh" ]]; then
    source "${SCRIPT_DIR}/lib/daemon-poll-health.sh"
fi

daemon_auto_scale() {
    if [[ "${AUTO_SCALE:-false}" != "true" ]]; then
        return
    fi

    local prev_max="$MAX_PARALLEL"

    # ── Learn worker memory from actual RSS (adaptive) ──
    learn_worker_memory

    # ── Adaptive cost estimate per template ──
    local effective_cost_per_job
    effective_cost_per_job=$(get_adaptive_cost_estimate "$PIPELINE_TEMPLATE")

    # ── CPU cores ──
    local cpu_cores=2
    if [[ "$(uname -s)" == "Darwin" ]]; then
        cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
    else
        cpu_cores=$(nproc 2>/dev/null || echo 2)
    fi
    local max_by_cpu=$(( (cpu_cores * 3) / 4 ))  # 75% utilization cap
    [[ "$max_by_cpu" -lt 1 ]] && max_by_cpu=1

    # ── Load average check — gradual scaling curve (replaces 90% cliff) ──
    local load_avg
    load_avg=$(uptime | awk -F'load averages?: ' '{print $2}' | awk -F'[, ]+' '{print $1}' 2>/dev/null || echo "0")
    if [[ ! "$load_avg" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        load_avg="0"
    fi
    local load_ratio=0
    if [[ "$cpu_cores" -gt 0 ]]; then
        load_ratio=$(awk -v load="$load_avg" -v cores="$cpu_cores" 'BEGIN { printf "%.0f", (load / cores) * 100 }')
    fi
    # Gradual load scaling curve (replaces binary 90% cliff)
    if [[ "$load_ratio" -gt 95 ]]; then
        # 95%+: minimum workers only
        max_by_cpu="$MIN_WORKERS"
        daemon_log WARN "Auto-scale: critical load (${load_ratio}%) — minimum workers only"
    elif [[ "$load_ratio" -gt 85 ]]; then
        # 85-95%: reduce by 50%
        max_by_cpu=$(( max_by_cpu / 2 ))
        [[ "$max_by_cpu" -lt "$MIN_WORKERS" ]] && max_by_cpu="$MIN_WORKERS"
        daemon_log WARN "Auto-scale: high load (${load_ratio}%) — reducing capacity 50%"
    elif [[ "$load_ratio" -gt 70 ]]; then
        # 70-85%: reduce by 25%
        max_by_cpu=$(( (max_by_cpu * 3) / 4 ))
        [[ "$max_by_cpu" -lt "$MIN_WORKERS" ]] && max_by_cpu="$MIN_WORKERS"
        daemon_log INFO "Auto-scale: moderate load (${load_ratio}%) — reducing capacity 25%"
    fi
    # 0-70%: full capacity (no change)

    # ── Available memory ──
    local avail_mem_gb=8
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local page_size free_pages inactive_pages purgeable_pages speculative_pages
        page_size=$(vm_stat | awk '/page size of/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) print $i}')
        page_size="${page_size:-16384}"
        free_pages=$(vm_stat | awk '/^Pages free:/ {gsub(/\./, "", $NF); print $NF}')
        free_pages="${free_pages:-0}"
        speculative_pages=$(vm_stat | awk '/^Pages speculative:/ {gsub(/\./, "", $NF); print $NF}')
        speculative_pages="${speculative_pages:-0}"
        inactive_pages=$(vm_stat | awk '/^Pages inactive:/ {gsub(/\./, "", $NF); print $NF}')
        inactive_pages="${inactive_pages:-0}"
        purgeable_pages=$(vm_stat | awk '/^Pages purgeable:/ {gsub(/\./, "", $NF); print $NF}')
        purgeable_pages="${purgeable_pages:-0}"
        local avail_pages=$(( free_pages + speculative_pages + inactive_pages + purgeable_pages ))
        if [[ "$avail_pages" -gt 0 && "$page_size" -gt 0 ]]; then
            local free_bytes=$(( avail_pages * page_size ))
            avail_mem_gb=$(( free_bytes / 1073741824 ))
        fi
    else
        local avail_kb
        avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo "8388608")
        avail_mem_gb=$(( avail_kb / 1048576 ))
    fi
    [[ "$avail_mem_gb" -lt 1 ]] && avail_mem_gb=1
    local max_by_mem=$(( avail_mem_gb / WORKER_MEM_GB ))
    [[ "$max_by_mem" -lt 1 ]] && max_by_mem=1

    # ── Budget remaining (adaptive cost estimate) ──
    local max_by_budget="$MAX_WORKERS"
    local remaining_usd
    remaining_usd=$("$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "unlimited")
    if [[ "$remaining_usd" != "unlimited" && -n "$remaining_usd" ]]; then
        if awk -v r="$remaining_usd" -v c="$effective_cost_per_job" 'BEGIN { exit !(r > 0 && c > 0) }'; then
            max_by_budget=$(awk -v r="$remaining_usd" -v c="$effective_cost_per_job" 'BEGIN { printf "%.0f", r / c }')
            [[ "$max_by_budget" -lt 0 ]] && max_by_budget=0
        else
            max_by_budget=0
        fi
    fi

    # ── Queue depth (don't over-provision) ──
    local queue_depth active_count
    queue_depth=$(jq -r '.queued | length' "$STATE_FILE" 2>/dev/null || echo 0)
    queue_depth="${queue_depth:-0}"
    [[ ! "$queue_depth" =~ ^[0-9]+$ ]] && queue_depth=0
    active_count=$(get_active_count)
    active_count="${active_count:-0}"
    [[ ! "$active_count" =~ ^[0-9]+$ ]] && active_count=0
    local max_by_queue=$(( queue_depth + active_count ))
    [[ "$max_by_queue" -lt 1 ]] && max_by_queue=1

    # ── Vitals-driven scaling factor ──
    local max_by_vitals="$MAX_WORKERS"
    if type pipeline_compute_vitals >/dev/null 2>&1 && [[ -f "$STATE_FILE" ]]; then
        local _total_health=0 _health_count=0
        while IFS= read -r _job; do
            local _job_issue _job_worktree
            _job_issue=$(echo "$_job" | jq -r '.issue // 0')
            _job_worktree=$(echo "$_job" | jq -r '.worktree // ""')
            if [[ -n "$_job_worktree" && -d "$_job_worktree/.claude" ]]; then
                local _job_vitals _job_health
                _job_vitals=$(pipeline_compute_vitals "$_job_worktree/.claude/pipeline-state.md" "$_job_worktree/.claude/pipeline-artifacts" "$_job_issue" 2>/dev/null) || true
                if [[ -n "$_job_vitals" && "$_job_vitals" != "{}" ]]; then
                    _job_health=$(echo "$_job_vitals" | jq -r '.health_score // 50' 2>/dev/null || echo "50")
                    _total_health=$((_total_health + _job_health))
                    _health_count=$((_health_count + 1))
                fi
            fi
        done < <(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null || true)

        if [[ "$_health_count" -gt 0 ]]; then
            local _avg_health=$((_total_health / _health_count))
            if [[ "$_avg_health" -lt 50 ]]; then
                # Pipelines struggling — reduce workers to give each more resources
                max_by_vitals=$(( MAX_WORKERS * _avg_health / 100 ))
                [[ "$max_by_vitals" -lt "$MIN_WORKERS" ]] && max_by_vitals="$MIN_WORKERS"
                daemon_log INFO "Auto-scale: vitals avg health ${_avg_health}% — capping at ${max_by_vitals} workers"
            fi
            # avg_health > 70: no reduction (full capacity available)
        fi
    fi

    # ── Compute final value ──
    local computed="$max_by_cpu"
    [[ "$max_by_mem" -lt "$computed" ]] && computed="$max_by_mem"
    [[ "$max_by_budget" -lt "$computed" ]] && computed="$max_by_budget"
    [[ "$max_by_queue" -lt "$computed" ]] && computed="$max_by_queue"
    [[ "$max_by_vitals" -lt "$computed" ]] && computed="$max_by_vitals"
    [[ "$MAX_WORKERS" -lt "$computed" ]] && computed="$MAX_WORKERS"

    # Respect fleet-assigned ceiling if set
    if [[ -n "${FLEET_MAX_PARALLEL:-}" && "$FLEET_MAX_PARALLEL" -lt "$computed" ]]; then
        computed="$FLEET_MAX_PARALLEL"
    fi

    # Clamp to min_workers
    [[ "$computed" -lt "$MIN_WORKERS" ]] && computed="$MIN_WORKERS"

    # ── Gradual scaling: change by at most 1 at a time (adaptive) ──
    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" == "true" ]]; then
        if [[ "$computed" -gt "$prev_max" ]]; then
            # Check success rate at target parallelism before scaling up
            local target_rate
            target_rate=$(get_success_rate_at_parallelism "$((prev_max + 1))")
            if [[ "$target_rate" -lt 50 ]]; then
                # Poor success rate at higher parallelism — hold steady
                computed="$prev_max"
                daemon_log INFO "Auto-scale: holding at ${prev_max} (success rate ${target_rate}% at $((prev_max + 1)))"
            else
                # Scale up by 1, not jump to target
                computed=$((prev_max + 1))
            fi
        elif [[ "$computed" -lt "$prev_max" ]]; then
            # Scale down by 1, not drop to minimum
            computed=$((prev_max - 1))
            [[ "$computed" -lt "$MIN_WORKERS" ]] && computed="$MIN_WORKERS"
        fi
    fi

    MAX_PARALLEL="$computed"

    if [[ "$MAX_PARALLEL" -ne "$prev_max" ]]; then
        daemon_log INFO "Auto-scale: ${prev_max} → ${MAX_PARALLEL} (cpu=${max_by_cpu} mem=${max_by_mem} budget=${max_by_budget} queue=${max_by_queue} load=${load_ratio}%)"
        emit_event "daemon.scale" \
            "from=$prev_max" \
            "to=$MAX_PARALLEL" \
            "max_by_cpu=$max_by_cpu" \
            "max_by_mem=$max_by_mem" \
            "max_by_budget=$max_by_budget" \
            "max_by_queue=$max_by_queue" \
            "cpu_cores=$cpu_cores" \
            "avail_mem_gb=$avail_mem_gb" \
            "remaining_usd=$remaining_usd" \
            "load_ratio=$load_ratio"
    fi
}

# ─── Fleet Config Reload ──────────────────────────────────────────────────
# Checks for fleet-reload.flag and reloads MAX_PARALLEL from fleet-managed config


daemon_self_optimize() {
    if [[ "${SELF_OPTIMIZE:-false}" != "true" ]]; then
        return
    fi

    if [[ ! -f "$EVENTS_FILE" ]]; then
        return
    fi

    # ── Intelligence-powered optimization (if enabled) ──
    if [[ "${OPTIMIZATION_ENABLED:-false}" == "true" ]] && type optimize_full_analysis >/dev/null 2>&1; then
        daemon_log INFO "Running intelligence-powered optimization"
        optimize_full_analysis 2>/dev/null || {
            daemon_log WARN "Intelligence optimization failed — falling back to DORA-based tuning"
        }
        # Still run DORA-based tuning below as a complement
    fi

    daemon_log INFO "Running self-optimization check"

    # Read DORA metrics from recent events (last 7 days)
    local cutoff_epoch
    cutoff_epoch=$(( $(now_epoch) - (7 * 86400) ))

    local period_events
    period_events=$(jq -c "select(.ts_epoch >= $cutoff_epoch)" "$EVENTS_FILE" 2>/dev/null || true)

    if [[ -z "$period_events" ]]; then
        daemon_log INFO "No recent events for optimization"
        return
    fi

    local total_completed successes failures
    total_completed=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed")] | length')
    successes=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success")] | length')
    failures=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length')

    # Change Failure Rate
    local cfr=0
    if [[ "$total_completed" -gt 0 ]]; then
        cfr=$(echo "$failures $total_completed" | awk '{printf "%.0f", ($1 / $2) * 100}')
    fi

    # Cycle time (median, in seconds)
    local cycle_time_median
    cycle_time_median=$(echo "$period_events" | \
        jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success") | .duration_s // 0] | sort | if length > 0 then .[length/2 | floor] else 0 end')

    # Deploy frequency (per week)
    local deploy_freq
    deploy_freq=$(echo "$successes" | awk '{printf "%.1f", $1 / 1}')  # Already 7 days

    # MTTR
    local mttr
    mttr=$(echo "$period_events" | \
        jq -s '
            [.[] | select(.type == "pipeline.completed")] | sort_by(.ts_epoch // 0) |
            [range(length) as $i |
                if .[$i].result == "failure" then
                    [.[$i+1:][] | select(.result == "success")][0] as $next |
                    if $next and $next.ts_epoch and .[$i].ts_epoch then
                        ($next.ts_epoch - .[$i].ts_epoch)
                    else null end
                else null end
            ] | map(select(. != null)) |
            if length > 0 then (add / length | floor) else 0 end
        ')

    local adjustments=()

    # ── CFR > 20%: enable compound_quality, increase max_cycles ──
    if [[ "$cfr" -gt 40 ]]; then
        PIPELINE_TEMPLATE="full"
        adjustments+=("template→full (CFR ${cfr}% > 40%)")
        daemon_log WARN "Self-optimize: CFR ${cfr}% critical — switching to full template"
    elif [[ "$cfr" -gt 20 ]]; then
        adjustments+=("compound_quality enabled (CFR ${cfr}% > 20%)")
        daemon_log WARN "Self-optimize: CFR ${cfr}% elevated — enabling compound quality"
    fi

    # ── Lead time > 4hrs: increase max_parallel, reduce poll_interval ──
    if [[ "$cycle_time_median" -gt 14400 ]]; then
        MAX_PARALLEL=$((MAX_PARALLEL + 1))
        if [[ "$POLL_INTERVAL" -gt 30 ]]; then
            POLL_INTERVAL=$((POLL_INTERVAL / 2))
        fi
        adjustments+=("max_parallel→${MAX_PARALLEL}, poll_interval→${POLL_INTERVAL}s (lead time > 4hrs)")
        daemon_log WARN "Self-optimize: lead time $(format_duration "$cycle_time_median") — increasing parallelism"
    elif [[ "$cycle_time_median" -gt 7200 ]]; then
        # ── Lead time > 2hrs: enable auto_template for fast-pathing ──
        AUTO_TEMPLATE="true"
        adjustments+=("auto_template enabled (lead time > 2hrs)")
        daemon_log INFO "Self-optimize: lead time $(format_duration "$cycle_time_median") — enabling adaptive templates"
    fi

    # ── Deploy freq < 1/day (< 7/week): enable merge stage ──
    if [[ "$(echo "$deploy_freq < 7" | bc -l 2>/dev/null || echo 0)" == "1" ]]; then
        adjustments+=("merge stage recommended (deploy freq ${deploy_freq}/week)")
        daemon_log INFO "Self-optimize: low deploy frequency — consider enabling merge stage"
    fi

    # ── MTTR > 2hrs: enable auto_rollback ──
    if [[ "$mttr" -gt 7200 ]]; then
        adjustments+=("auto_rollback recommended (MTTR $(format_duration "$mttr"))")
        daemon_log WARN "Self-optimize: high MTTR $(format_duration "$mttr") — consider enabling auto-rollback"
    fi

    # Write adjustments to state and persist to config
    if [[ ${#adjustments[@]} -gt 0 ]]; then
        local adj_str
        adj_str=$(printf '%s; ' "${adjustments[@]}")

        locked_state_update \
            --arg adj "$adj_str" \
            --arg ts "$(now_iso)" \
            '.last_optimization = {timestamp: $ts, adjustments: $adj}'

        # ── Persist adjustments to daemon-config.json (survives restart) ──
        local config_file="${CONFIG_PATH:-.claude/daemon-config.json}"
        if [[ -f "$config_file" ]]; then
            local tmp_config
            tmp_config=$(jq \
                --argjson max_parallel "$MAX_PARALLEL" \
                --argjson poll_interval "$POLL_INTERVAL" \
                --arg template "$PIPELINE_TEMPLATE" \
                --arg auto_template "${AUTO_TEMPLATE:-false}" \
                --arg ts "$(now_iso)" \
                --arg adj "$adj_str" \
                '.max_parallel = $max_parallel |
                 .poll_interval = $poll_interval |
                 .pipeline_template = $template |
                 .auto_template = ($auto_template == "true") |
                 .last_optimization = {timestamp: $ts, adjustments: $adj}' \
                "$config_file")
            # Atomic write: tmp file + mv
            local tmp_cfg_file="${config_file}.tmp.$$"
            echo "$tmp_config" > "$tmp_cfg_file"
            mv "$tmp_cfg_file" "$config_file"
            daemon_log INFO "Self-optimize: persisted adjustments to ${config_file}"
        fi

        emit_event "daemon.optimize" "adjustments=${adj_str}" "cfr=$cfr" "cycle_time=$cycle_time_median" "deploy_freq=$deploy_freq" "mttr=$mttr"
        daemon_log SUCCESS "Self-optimization applied ${#adjustments[@]} adjustment(s)"
    else
        daemon_log INFO "Self-optimization: all metrics within thresholds"
    fi
}

# ─── Stale State Reaper ──────────────────────────────────────────────────────
# Cleans old worktrees, pipeline artifacts, and completed state entries.
# Called every N poll cycles (configurable via stale_reaper_interval).


daemon_cleanup_stale() {
    if [[ "${STALE_REAPER_ENABLED:-true}" != "true" ]]; then
        return
    fi

    daemon_log INFO "Running stale state reaper"
    local cleaned=0
    local age_days="${STALE_REAPER_AGE_DAYS:-7}"
    local age_secs=$((age_days * 86400))
    local now_e
    now_e=$(now_epoch)

    # ── 1. Clean old git worktrees ──
    if command -v git >/dev/null 2>&1; then
        while IFS= read -r line; do
            local wt_path
            wt_path=$(echo "$line" | awk '{print $1}')
            # Only clean daemon-created worktrees
            [[ "$wt_path" == *"daemon-issue-"* ]] || continue
            # Check worktree age via directory mtime
            local mtime
            mtime=$(file_mtime "$wt_path")
            if [[ $((now_e - mtime)) -gt $age_secs ]]; then
                daemon_log INFO "Removing stale worktree: ${wt_path}"
                git worktree remove "$wt_path" --force 2>/dev/null || true
                cleaned=$((cleaned + 1))
            fi
        done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //')
    fi

    # ── 2. Expire old checkpoints ──
    if [[ -x "$SCRIPT_DIR/sw-checkpoint.sh" ]]; then
        local expired_output
        expired_output=$(bash "$SCRIPT_DIR/sw-checkpoint.sh" expire --hours "$((age_days * 24))" 2>/dev/null || true)
        if [[ -n "$expired_output" ]] && echo "$expired_output" | grep -q "Expired"; then
            local expired_count
            expired_count=$(echo "$expired_output" | grep -c "Expired" || true)
            cleaned=$((cleaned + ${expired_count:-0}))
            daemon_log INFO "Expired ${expired_count:-0} old checkpoint(s)"
        fi
    fi

    # ── 3. Clean old pipeline artifacts (subdirectories only) ──
    local artifacts_dir=".claude/pipeline-artifacts"
    if [[ -d "$artifacts_dir" ]]; then
        while IFS= read -r artifact_dir; do
            [[ -d "$artifact_dir" ]] || continue
            local mtime
            mtime=$(file_mtime "$artifact_dir")
            if [[ $((now_e - mtime)) -gt $age_secs ]]; then
                daemon_log INFO "Removing stale artifact: ${artifact_dir}"
                rm -rf "$artifact_dir"
                cleaned=$((cleaned + 1))
            fi
        done < <(find "$artifacts_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi

    # ── 3. Clean orphaned daemon/* branches (no matching worktree or active job) ──
    if command -v git >/dev/null 2>&1; then
        while IFS= read -r branch; do
            [[ -z "$branch" ]] && continue
            branch="${branch## }"  # trim leading spaces
            # Only clean daemon-created branches
            [[ "$branch" == daemon/issue-* ]] || continue
            # Extract issue number
            local branch_issue_num="${branch#daemon/issue-}"
            # Skip if there's an active job for this issue
            if daemon_is_inflight "$branch_issue_num" 2>/dev/null; then
                continue
            fi
            daemon_log INFO "Removing orphaned branch: ${branch}"
            git branch -D "$branch" 2>/dev/null || true
            cleaned=$((cleaned + 1))
        done < <(git branch --list 'daemon/issue-*' 2>/dev/null)
    fi

    # ── 4. Prune completed/failed state entries older than age_days ──
    if [[ -f "$STATE_FILE" ]]; then
        local cutoff_iso
        cutoff_iso=$(epoch_to_iso $((now_e - age_secs)))
        local before_count
        before_count=$(jq '.completed | length' "$STATE_FILE" 2>/dev/null || echo 0)
        locked_state_update --arg cutoff "$cutoff_iso" \
            '.completed = [.completed[] | select(.completed_at > $cutoff)]' 2>/dev/null || true
        local after_count
        after_count=$(jq '.completed | length' "$STATE_FILE" 2>/dev/null || echo 0)
        local pruned=$((before_count - after_count))
        if [[ "$pruned" -gt 0 ]]; then
            daemon_log INFO "Pruned ${pruned} old completed state entries"
            cleaned=$((cleaned + pruned))
        fi
    fi

    # ── 5. Prune stale retry_counts + failure_signatures (issues no longer in
    #      flight or queued). Both are keyed by issue number and both are written
    #      on the retry path, so they go stale together. ──
    if [[ -f "$STATE_FILE" ]]; then
        local retry_keys
        retry_keys=$(jq -r '((.retry_counts // {}) + (.failure_signatures // {})) | keys[]' "$STATE_FILE" 2>/dev/null || true)
        local stale_keys=()
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            if ! daemon_is_inflight "$key" 2>/dev/null; then
                stale_keys+=("$key")
            fi
        done <<< "$retry_keys"
        if [[ ${#stale_keys[@]} -gt 0 ]]; then
            for sk in "${stale_keys[@]}"; do
                locked_state_update --arg k "$sk" '
                    del(.retry_counts[$k])
                    | if (.failure_signatures | type) == "object" then del(.failure_signatures[$k]) else . end
                ' 2>/dev/null || continue
            done
            daemon_log INFO "Pruned ${#stale_keys[@]} stale retry count(s)"
            cleaned=$((cleaned + ${#stale_keys[@]}))
        fi
    fi

    # ── 6. Detect stale pipeline-state.md stuck in "running" ──
    local pipeline_state=".claude/pipeline-state.md"
    if [[ -f "$pipeline_state" ]]; then
        local ps_status=""
        ps_status=$(sed -n 's/^status: *//p' "$pipeline_state" 2>/dev/null | head -1 | tr -d ' ')
        if [[ "$ps_status" == "running" ]]; then
            local ps_mtime
            ps_mtime=$(file_mtime "$pipeline_state")
            local ps_age=$((now_e - ps_mtime))
            # If pipeline-state.md has been "running" for more than 2 hours and no active job
            if [[ "$ps_age" -gt 7200 ]]; then
                local has_active=false
                if [[ -f "$STATE_FILE" ]]; then
                    local active_count
                    active_count=$(jq '.active_jobs | length' "$STATE_FILE" 2>/dev/null || echo "0")
                    [[ "${active_count:-0}" -gt 0 ]] && has_active=true
                fi
                if [[ "$has_active" == "false" ]]; then
                    daemon_log WARN "Stale pipeline-state.md stuck in 'running' for ${ps_age}s with no active jobs — marking failed"
                    # Atomically update status to failed
                    local tmp_ps="${pipeline_state}.tmp.$$"
                    sed 's/^status: *running/status: failed (stale — cleaned by daemon)/' "$pipeline_state" > "$tmp_ps" 2>/dev/null && mv "$tmp_ps" "$pipeline_state" || rm -f "$tmp_ps"
                    emit_event "daemon.stale_pipeline_state" "age_s=$ps_age"
                    cleaned=$((cleaned + 1))
                fi
            fi
        fi
    fi

    # ── 7. Clean remote branches for merged pipeline/* branches ──
    if command -v git >/dev/null 2>&1 && [[ "${NO_GITHUB:-}" != "true" ]]; then
        while IFS= read -r branch; do
            [[ -z "$branch" ]] && continue
            branch="${branch## }"
            [[ "$branch" == pipeline/* ]] || continue
            local br_issue="${branch#pipeline/pipeline-issue-}"
            if ! daemon_is_inflight "$br_issue" 2>/dev/null; then
                daemon_log INFO "Removing orphaned pipeline branch: ${branch}"
                git branch -D "$branch" 2>/dev/null || true
                git push origin --delete "$branch" 2>/dev/null || true
                cleaned=$((cleaned + 1))
            fi
        done < <(git branch --list 'pipeline/*' 2>/dev/null)
    fi

    if [[ "$cleaned" -gt 0 ]]; then
        emit_event "daemon.cleanup" "cleaned=$cleaned" "age_days=$age_days"
        daemon_log SUCCESS "Stale reaper cleaned ${cleaned} item(s)"
    else
        daemon_log INFO "Stale reaper: nothing to clean"
    fi
}

# ─── Poll Loop ───────────────────────────────────────────────────────────────

POLL_CYCLE_COUNT=0


daemon_poll_loop() {
    daemon_log INFO "Entering poll loop (interval: ${POLL_INTERVAL}s, max_parallel: ${MAX_PARALLEL})"
    daemon_log INFO "Watching for label: ${CYAN}${WATCH_LABEL}${RESET}"

    while [[ ! -f "$SHUTDOWN_FLAG" ]]; do
        # All poll loop calls are error-guarded to prevent set -e from killing the daemon.
        # The || operator disables set -e for the entire call chain, so transient failures
        # (GitHub API timeouts, jq errors, intelligence failures) are logged and skipped.
        daemon_preflight_auth_check || daemon_log WARN "Auth check failed — daemon may be paused"
        daemon_poll_issues || daemon_log WARN "daemon_poll_issues failed — continuing"
        daemon_reap_completed || daemon_log WARN "daemon_reap_completed failed — continuing"
        daemon_health_check || daemon_log WARN "daemon_health_check failed — continuing"

        # Fleet failover: re-queue work from offline machines
        if [[ -f "$HOME/.shipwright/machines.json" ]]; then
            [[ -f "$SCRIPT_DIR/lib/fleet-failover.sh" ]] && source "$SCRIPT_DIR/lib/fleet-failover.sh" 2>/dev/null || true
            fleet_failover_check 2>/dev/null || true
        fi

        # Increment cycle counter (must be before all modulo checks)
        POLL_CYCLE_COUNT=$((POLL_CYCLE_COUNT + 1))

        # Fleet config reload every 3 cycles
        if [[ $((POLL_CYCLE_COUNT % 3)) -eq 0 ]]; then
            daemon_reload_config || daemon_log WARN "daemon_reload_config failed — continuing"
        fi

        # Check degradation every 5 poll cycles
        if [[ $((POLL_CYCLE_COUNT % 5)) -eq 0 ]]; then
            daemon_check_degradation || daemon_log WARN "daemon_check_degradation failed — continuing"
        fi

        # Auto-scale every N cycles (default: 5)
        if [[ $((POLL_CYCLE_COUNT % ${AUTO_SCALE_INTERVAL:-5})) -eq 0 ]]; then
            daemon_auto_scale || daemon_log WARN "daemon_auto_scale failed — continuing"
        fi

        # Self-optimize every N cycles (default: 10)
        if [[ $((POLL_CYCLE_COUNT % ${OPTIMIZE_INTERVAL:-10})) -eq 0 ]]; then
            daemon_self_optimize || daemon_log WARN "daemon_self_optimize failed — continuing"
        fi

        # Stale state reaper every N cycles (default: 10)
        if [[ $((POLL_CYCLE_COUNT % ${STALE_REAPER_INTERVAL:-10})) -eq 0 ]]; then
            daemon_cleanup_stale || daemon_log WARN "daemon_cleanup_stale failed — continuing"
        fi

        # Rotate event log every 10 cycles (~10 min with 60s interval)
        if [[ $((POLL_CYCLE_COUNT % 10)) -eq 0 ]]; then
            rotate_event_log || true
        fi

        # Proactive patrol during quiet periods (with adaptive limits)
        local issue_count_now active_count_now
        issue_count_now=$(jq -r '.queued | length' "$STATE_FILE" 2>/dev/null || echo 0)
        active_count_now=$(get_active_count || echo 0)
        if [[ "$issue_count_now" -eq 0 ]] && [[ "$active_count_now" -eq 0 ]]; then
            local now_e
            now_e=$(now_epoch || date +%s)
            if [[ $((now_e - LAST_PATROL_EPOCH)) -ge "$PATROL_INTERVAL" ]]; then
                load_adaptive_patrol_limits || true
                daemon_log INFO "No active work — running patrol"
                daemon_patrol --once || daemon_log WARN "daemon_patrol failed — continuing"
                LAST_PATROL_EPOCH=$now_e
            fi

            # Decision engine cycle (if enabled)
            local _decision_enabled
            _decision_enabled=$(policy_get ".decision.enabled" "false" 2>/dev/null || echo "false")
            if [[ "$_decision_enabled" == "true" ]]; then
                local _decision_interval
                _decision_interval=$(policy_get ".decision.cycle_interval_seconds" "1800" 2>/dev/null || echo "1800")
                local _last_decision_epoch="${_LAST_DECISION_EPOCH:-0}"
                if [[ $((now_e - _last_decision_epoch)) -ge "$_decision_interval" ]]; then
                    daemon_log INFO "Running decision engine cycle"
                    if [[ -f "$SCRIPT_DIR/sw-decide.sh" ]]; then
                        DECISION_ENGINE_ENABLED=true bash "$SCRIPT_DIR/sw-decide.sh" run --once 2>/dev/null || \
                            daemon_log WARN "Decision engine cycle failed — continuing"
                    fi
                    _LAST_DECISION_EPOCH=$now_e
                fi
            fi
        fi

        # ── Adaptive poll interval: adjust sleep based on queue state ──
        local effective_interval
        effective_interval=$(get_adaptive_poll_interval "$issue_count_now" "$active_count_now" || echo "${POLL_INTERVAL:-30}")

        # Sleep in 1s intervals so we can catch shutdown quickly
        local i=0
        while [[ $i -lt $effective_interval ]] && [[ ! -f "$SHUTDOWN_FLAG" ]]; do
            sleep "$(_smart_int "daemon.poll_tick_seconds" 1)" || true  # Guard against signal interruption under set -e
            i=$((i + 1))
        done
    done

    daemon_log INFO "Shutdown flag detected — exiting poll loop"
}
