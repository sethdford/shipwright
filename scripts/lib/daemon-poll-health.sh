# daemon-poll-health.sh — Health checks and degradation detection for daemon-poll.sh
# Source from daemon-poll.sh. Requires state, helpers.
[[ -n "${_DAEMON_POLL_HEALTH_LOADED:-}" ]] && return 0
_DAEMON_POLL_HEALTH_LOADED=1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"

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

daemon_health_check() {
    local findings=0
    local now_e
    now_e=$(now_epoch)

    if [[ -f "$STATE_FILE" ]]; then
        # ── Intelligent Health Monitoring ──
        # Instead of killing after a countdown, sense what the agent is doing.
        # Agents think for long stretches — that's normal and expected.
        # Strategy: sense → understand → be patient → nudge → only kill as last resort.

        local hard_limit="${PROGRESS_HARD_LIMIT_S:-0}"
        local use_progress="${PROGRESS_MONITORING:-true}"
        local nudge_enabled="${NUDGE_ENABLED:-true}"
        local nudge_after="${NUDGE_AFTER_CHECKS:-40}"

        while IFS= read -r job; do
            local pid started_at issue_num worktree
            pid=$(echo "$job" | jq -r '.pid')
            started_at=$(echo "$job" | jq -r '.started_at // empty')
            issue_num=$(echo "$job" | jq -r '.issue')
            worktree=$(echo "$job" | jq -r '.worktree // ""')

            # Skip dead processes
            if ! kill -0 "$pid" 2>/dev/null; then
                continue
            fi

            local elapsed=0
            if [[ -n "$started_at" ]]; then
                local start_e
                start_e=$(date_to_epoch "$started_at" || echo "0")
                elapsed=$(( now_e - start_e ))
            fi

            # Hard wall-clock limit — disabled by default (0 = off)
            if [[ "$hard_limit" -gt 0 && "$elapsed" -gt "$hard_limit" ]]; then
                daemon_log WARN "Hard limit exceeded: issue #${issue_num} (${elapsed}s > ${hard_limit}s, PID $pid) — killing"
                emit_event "daemon.hard_limit" "issue=$issue_num" "elapsed_s=$elapsed" "limit_s=$hard_limit" "pid=$pid"
                kill "$pid" 2>/dev/null || true
                daemon_clear_progress "$issue_num"
                findings=$((findings + 1))
                continue
            fi

            # ── Intelligent Progress Sensing ──
            if [[ "$use_progress" == "true" && -n "$worktree" ]]; then
                local snapshot verdict
                snapshot=$(daemon_collect_snapshot "$issue_num" "$worktree" "$pid" 2>/dev/null || echo '{}')

                if [[ "$snapshot" != "{}" ]]; then
                    verdict=$(daemon_assess_progress "$issue_num" "$snapshot" 2>/dev/null || echo "healthy")

                    local no_progress_count=0
                    no_progress_count=$(jq -r '.no_progress_count // 0' "$PROGRESS_DIR/issue-${issue_num}.json" 2>/dev/null || echo 0)
                    local cur_stage
                    cur_stage=$(echo "$snapshot" | jq -r '.stage // "unknown"')

                    case "$verdict" in
                        healthy)
                            # All good — agent is making progress
                            ;;
                        slowing)
                            daemon_log INFO "Issue #${issue_num} slowing (no visible changes for ${no_progress_count} checks, ${elapsed}s elapsed, stage=${cur_stage})"
                            ;;
                        stalled)
                            # Check if agent subprocess is alive and consuming CPU
                            local agent_alive=false
                            local child_cpu=0
                            child_cpu=$(pgrep -P "$pid" 2>/dev/null | xargs -I{} ps -o pcpu= -p {} 2>/dev/null | awk '{sum+=$1} END{printf "%d", sum+0}' || echo "0")
                            if [[ "${child_cpu:-0}" -gt 0 ]]; then
                                agent_alive=true
                            fi

                            if [[ "$agent_alive" == "true" ]]; then
                                daemon_log INFO "Issue #${issue_num} no visible progress (${no_progress_count} checks) but agent is alive (CPU: ${child_cpu}%, stage=${cur_stage}, ${elapsed}s) — being patient"
                            else
                                daemon_log WARN "Issue #${issue_num} stalled: no progress for ${no_progress_count} checks, no CPU activity (${elapsed}s elapsed, PID $pid)"
                                emit_event "daemon.stalled" "issue=$issue_num" "no_progress=$no_progress_count" "elapsed_s=$elapsed" "pid=$pid"
                            fi
                            ;;
                        stuck)
                            local repeated_errors
                            repeated_errors=$(jq -r '.repeated_error_count // 0' "$PROGRESS_DIR/issue-${issue_num}.json" 2>/dev/null || echo 0)

                            # Even "stuck" — check if the process tree is alive first
                            local agent_alive=false
                            local child_cpu=0
                            child_cpu=$(pgrep -P "$pid" 2>/dev/null | xargs -I{} ps -o pcpu= -p {} 2>/dev/null | awk '{sum+=$1} END{printf "%d", sum+0}' || echo "0")
                            if [[ "${child_cpu:-0}" -gt 0 ]]; then
                                agent_alive=true
                            fi

                            if [[ "$agent_alive" == "true" && "$repeated_errors" -lt 3 ]]; then
                                # Agent is alive — nudge instead of kill
                                if [[ "$nudge_enabled" == "true" && "$no_progress_count" -ge "$nudge_after" ]]; then
                                    local nudge_file="${worktree}/.claude/nudge.md"
                                    if [[ ! -f "$nudge_file" ]]; then
                                        cat > "$nudge_file" <<NUDGE_EOF
# Nudge from Daemon Health Monitor

The daemon has noticed no visible progress for $(( no_progress_count * 30 / 60 )) minutes.
Current stage: ${cur_stage}

If you're stuck, consider:
- Breaking the task into smaller steps
- Committing partial progress
- Running tests to validate current state

This is just a gentle check-in — take your time if you're working through a complex problem.
NUDGE_EOF
                                        daemon_log INFO "Issue #${issue_num} nudged (${no_progress_count} checks, stage=${cur_stage}, CPU=${child_cpu}%) — file written to worktree"
                                        emit_event "daemon.nudge" "issue=$issue_num" "no_progress=$no_progress_count" "stage=$cur_stage" "elapsed_s=$elapsed"
                                    fi
                                else
                                    daemon_log INFO "Issue #${issue_num} no visible progress (${no_progress_count} checks) but agent is alive (CPU: ${child_cpu}%, stage=${cur_stage}) — waiting"
                                fi
                            elif [[ "$repeated_errors" -ge 5 ]]; then
                                # Truly stuck in an error loop — kill as last resort
                                daemon_log WARN "Issue #${issue_num} in error loop: ${repeated_errors} repeated errors (stage=${cur_stage}, ${elapsed}s, PID $pid) — killing"
                                emit_event "daemon.stuck_kill" "issue=$issue_num" "no_progress=$no_progress_count" "repeated_errors=$repeated_errors" "stage=$cur_stage" "elapsed_s=$elapsed" "pid=$pid" "reason=error_loop"
                                kill "$pid" 2>/dev/null || true
                                daemon_clear_progress "$issue_num"
                                findings=$((findings + 1))
                            elif [[ "$agent_alive" != "true" && "$no_progress_count" -ge "$((PROGRESS_CHECKS_BEFORE_KILL * 2))" ]]; then
                                # Process tree is dead AND no progress for very long time
                                daemon_log WARN "Issue #${issue_num} appears dead: no CPU, no progress for ${no_progress_count} checks (${elapsed}s, PID $pid) — killing"
                                emit_event "daemon.stuck_kill" "issue=$issue_num" "no_progress=$no_progress_count" "repeated_errors=$repeated_errors" "stage=$cur_stage" "elapsed_s=$elapsed" "pid=$pid" "reason=dead_process"
                                kill "$pid" 2>/dev/null || true
                                daemon_clear_progress "$issue_num"
                                findings=$((findings + 1))
                            else
                                daemon_log WARN "Issue #${issue_num} struggling (${no_progress_count} checks, ${repeated_errors} errors, CPU=${child_cpu}%, stage=${cur_stage}) — monitoring"
                            fi
                            ;;
                    esac
                fi
            else
                # Fallback: legacy time-based detection when progress monitoring is off
                local stale_timeout
                stale_timeout=$(get_adaptive_stale_timeout "$PIPELINE_TEMPLATE")
                if [[ "$elapsed" -gt "$stale_timeout" ]]; then
                    # Check if process is still alive
                    if kill -0 "$pid" 2>/dev/null; then
                        # Kill at 2x stale timeout — the process is truly hung
                        local kill_threshold=$(( stale_timeout * 2 ))
                        if [[ "$elapsed" -gt "$kill_threshold" ]]; then
                            daemon_log WARN "Killing stale job (legacy): issue #${issue_num} (${elapsed}s > ${kill_threshold}s kill threshold, PID $pid)"
                            emit_event "daemon.stale_kill" "issue=$issue_num" "elapsed_s=$elapsed" "pid=$pid"
                            kill "$pid" 2>/dev/null || true
                            sleep "$(_smart_int "daemon.kill_grace_seconds" 2)"
                            kill -9 "$pid" 2>/dev/null || true
                        else
                            daemon_log WARN "Stale job (legacy): issue #${issue_num} (${elapsed}s > ${stale_timeout}s, PID $pid) — will kill at ${kill_threshold}s"
                            emit_event "daemon.stale_warning" "issue=$issue_num" "elapsed_s=$elapsed" "pid=$pid"
                        fi
                    else
                        daemon_log WARN "Stale job with dead process: issue #${issue_num} (PID $pid no longer exists)"
                        emit_event "daemon.stale_dead" "issue=$issue_num" "pid=$pid"
                    fi
                    findings=$((findings + 1))
                fi
            fi
        done < <(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null || true)
    fi

    # Disk space warning (check both repo dir and ~/.shipwright)
    local free_kb
    free_kb=$(df -k "." 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$free_kb" ]] && [[ "$free_kb" -lt 1048576 ]] 2>/dev/null; then
        daemon_log WARN "Low disk space: $(( free_kb / 1024 ))MB free"
        findings=$((findings + 1))
    fi

    # Critical disk space on ~/.shipwright — pause spawning
    local sw_free_kb
    sw_free_kb=$(df -k "$HOME/.shipwright" 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$sw_free_kb" ]] && [[ "$sw_free_kb" -lt 512000 ]] 2>/dev/null; then
        daemon_log WARN "Critical disk space on ~/.shipwright: $(( sw_free_kb / 1024 ))MB — pausing spawns"
        emit_event "daemon.disk_low" "free_mb=$(( sw_free_kb / 1024 ))"
        mkdir -p "$HOME/.shipwright"
        echo '{"paused":true,"reason":"disk_low"}' > "$HOME/.shipwright/daemon-pause.flag"
        findings=$((findings + 1))
    fi

    # Events file size warning
    if [[ -f "$EVENTS_FILE" ]]; then
        local events_size
        events_size=$(wc -c < "$EVENTS_FILE" 2>/dev/null || echo 0)
        if [[ "$events_size" -gt 104857600 ]]; then  # 100MB
            daemon_log WARN "Events file large ($(( events_size / 1048576 ))MB) — consider rotating"
            findings=$((findings + 1))
        fi
    fi

    if [[ "$findings" -gt 0 ]]; then
        emit_event "daemon.health" "findings=$findings"
    fi
}

# ─── Degradation Alerting ─────────────────────────────────────────────────────


daemon_check_degradation() {
    if [[ ! -f "$EVENTS_FILE" ]]; then return; fi

    local window="${DEGRADATION_WINDOW:-5}"
    local cfr_threshold="${DEGRADATION_CFR_THRESHOLD:-30}"
    local success_threshold="${DEGRADATION_SUCCESS_THRESHOLD:-50}"

    # Get last N pipeline completions
    local recent
    recent=$(tail -200 "$EVENTS_FILE" | jq -s "[.[] | select(.type == \"pipeline.completed\")] | .[-${window}:]" 2>/dev/null)
    local count
    count=$(echo "$recent" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$count" -lt "$window" ]]; then return; fi

    local failures successes
    failures=$(echo "$recent" | jq '[.[] | select(.result == "failure")] | length')
    successes=$(echo "$recent" | jq '[.[] | select(.result == "success")] | length')
    local cfr_pct=0 success_pct=0
    if [[ "${count:-0}" -gt 0 ]]; then
        cfr_pct=$(( failures * 100 / count ))
        success_pct=$(( successes * 100 / count ))
    fi

    local alerts=""
    if [[ "$cfr_pct" -gt "$cfr_threshold" ]]; then
        alerts="CFR ${cfr_pct}% exceeds threshold ${cfr_threshold}%"
        daemon_log WARN "DEGRADATION: $alerts"
    fi
    if [[ "$success_pct" -lt "$success_threshold" ]]; then
        local msg="Success rate ${success_pct}% below threshold ${success_threshold}%"
        [[ -n "$alerts" ]] && alerts="$alerts; $msg" || alerts="$msg"
        daemon_log WARN "DEGRADATION: $msg"
    fi

    if [[ -n "$alerts" ]]; then
        emit_event "daemon.alert" "alerts=$alerts" "cfr_pct=$cfr_pct" "success_pct=$success_pct"

        # Slack notification
        if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
            notify "Pipeline Degradation Alert" "$alerts" "warn"
        fi
    fi
}

# ─── Auto-Scaling ─────────────────────────────────────────────────────────
# Dynamically adjusts MAX_PARALLEL based on CPU, memory, budget, and queue depth


daemon_reload_config() {
    local reload_flag="$HOME/.shipwright/fleet-reload.flag"
    if [[ ! -f "$reload_flag" ]]; then
        return
    fi

    local fleet_config=".claude/.fleet-daemon-config.json"
    if [[ -f "$fleet_config" ]]; then
        local new_max
        new_max=$(jq -r '.max_parallel // empty' "$fleet_config" 2>/dev/null || true)
        if [[ -n "$new_max" && "$new_max" != "null" ]]; then
            local prev="$MAX_PARALLEL"
            FLEET_MAX_PARALLEL="$new_max"
            MAX_PARALLEL="$new_max"
            daemon_log INFO "Fleet reload: max_parallel ${prev} → ${MAX_PARALLEL} (fleet ceiling: ${FLEET_MAX_PARALLEL})"
            emit_event "daemon.fleet_reload" "from=$prev" "to=$MAX_PARALLEL"
        fi
    fi

    rm -f "$reload_flag"
}

# ─── Self-Optimizing Metrics Loop ──────────────────────────────────────────

