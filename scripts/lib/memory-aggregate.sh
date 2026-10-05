#!/usr/bin/env bash
# Memory aggregate — Pattern aggregation, global rollup, DORA metrics, stats, A/B testing
# Depends on: memory-common.sh, memory-capture.sh (memory_finalize_pipeline)

[[ -n "${_MEMORY_AGGREGATE_LOADED:-}" ]] && return 0
_MEMORY_AGGREGATE_LOADED=1

# ─── A/B Testing Framework ─────────────────────────────────────────────────
# Test memory system effectiveness by randomly assigning control vs treatment.
#   - Control: pipeline runs without memory injection
#   - Treatment: pipeline runs with memory injection
# Emits events to track metrics: iterations, cost, test_failures, completion_status

AB_RESULTS_DIR="${HOME}/.shipwright/memory"
AB_RESULTS_FILE="${AB_RESULTS_DIR}/ab-results.jsonl"

# Assign control or treatment for this pipeline run
#   Returns: "control" or "treatment"
memory_ab_assign_group() {
    local ab_ratio="${1:-0.2}"  # Read from daemon-config intelligence.ab_test_ratio

    # Validate ratio is between 0 and 1
    if ! echo "$ab_ratio" | grep -qE '^0(\.[0-9]+)?$|^1(\.0+)?$'; then
        ab_ratio="0.2"
    fi

    # Generate random 0-100
    local rand=$((RANDOM % 100))
    local threshold
    threshold=$(echo "$ab_ratio * 100" | bc 2>/dev/null || echo "20")
    threshold=${threshold%.*}  # Remove decimal

    if [[ "$rand" -lt "$threshold" ]]; then
        echo "control"
    else
        echo "treatment"
    fi
}

# Record A/B test assignment at pipeline start
#   $1: pipeline_id
#   $2: group (control|treatment)
memory_ab_record_assignment() {
    local pipeline_id="$1"
    local group="${2:-}"

    [[ -z "$pipeline_id" || -z "$group" ]] && return 1

    # Emit event for tracking
    emit_event "memory.ab_assigned" \
        "pipeline_id=$pipeline_id" \
        "group=$group" \
        "timestamp=$(now_iso)"

    return 0
}

# Record A/B test result after pipeline completion
#   $1: pipeline_id
#   $2: group (control|treatment)
#   $3: iterations (number of build iterations)
#   $4: cost (estimated token cost)
#   $5: test_failures (number of test failures)
#   $6: completion_status (success|failure)
memory_ab_record_result() {
    local pipeline_id="$1"
    local group="$2"
    local iterations="$3"
    local cost="$4"
    local test_failures="$5"
    local completion_status="$6"

    [[ -z "$pipeline_id" || -z "$group" ]] && return 1

    mkdir -p "$AB_RESULTS_DIR"

    # Record result as JSONL
    local result_json
    result_json=$(jq -n \
        --arg pipeline_id "$pipeline_id" \
        --arg group "$group" \
        --arg timestamp "$(now_iso)" \
        --arg iterations "$iterations" \
        --arg cost "$cost" \
        --arg test_failures "$test_failures" \
        --arg completion_status "$completion_status" \
        '{
            pipeline_id: $pipeline_id,
            group: $group,
            timestamp: $timestamp,
            iterations: ($iterations | tonumber? // 0),
            cost: ($cost | tonumber? // 0),
            test_failures: ($test_failures | tonumber? // 0),
            completion_status: $completion_status
        }')

    echo "$result_json" >> "$AB_RESULTS_FILE"

    # Emit event
    emit_event "memory.ab_result" \
        "pipeline_id=$pipeline_id" \
        "group=$group" \
        "iterations=$iterations" \
        "cost=$cost" \
        "test_failures=$test_failures" \
        "completion_status=$completion_status"

    return 0
}

# Generate A/B test report comparing control vs treatment
cmd_memory_ab_report() {
    if [[ ! -f "$AB_RESULTS_FILE" ]]; then
        warn "No A/B test results found at $AB_RESULTS_FILE"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        error "jq required for A/B report generation"
        return 1
    fi

    info "Memory A/B Test Report"
    echo ""

    local control_count treatment_count
    control_count=$(grep -c '"control"' "$AB_RESULTS_FILE" 2>/dev/null || echo "0")
    treatment_count=$(grep -c '"treatment"' "$AB_RESULTS_FILE" 2>/dev/null || echo "0")

    echo -e "${BOLD}Sample Sizes${RESET}"
    printf "  Control:   %3d pipelines\n" "$control_count"
    printf "  Treatment: %3d pipelines\n" "$treatment_count"
    echo ""

    # Calculate metrics for control group
    local control_data
    control_data=$(grep '"control"' "$AB_RESULTS_FILE" 2>/dev/null | jq -s '
        if length == 0 then
            {count: 0, avg_iterations: 0, avg_cost: 0, success_rate: 0}
        else
            {
                count: length,
                avg_iterations: ([.[].iterations // 0] | add / length | floor),
                avg_cost: ([.[].cost // 0] | add / length | floor),
                success_rate: (([.[] | select(.completion_status == "success")] | length) / length * 100 | floor)
            }
        end
    ' || echo '{"count": 0, "avg_iterations": 0, "avg_cost": 0, "success_rate": 0}')

    # Calculate metrics for treatment group
    local treatment_data
    treatment_data=$(grep '"treatment"' "$AB_RESULTS_FILE" 2>/dev/null | jq -s '
        if length == 0 then
            {count: 0, avg_iterations: 0, avg_cost: 0, success_rate: 0}
        else
            {
                count: length,
                avg_iterations: ([.[].iterations // 0] | add / length | floor),
                avg_cost: ([.[].cost // 0] | add / length | floor),
                success_rate: (([.[] | select(.completion_status == "success")] | length) / length * 100 | floor)
            }
        end
    ' || echo '{"count": 0, "avg_iterations": 0, "avg_cost": 0, "success_rate": 0}')

    # Extract values
    local c_iterations t_iterations c_cost t_cost c_success t_success
    c_iterations=$(echo "$control_data" | jq -r '.avg_iterations // 0')
    t_iterations=$(echo "$treatment_data" | jq -r '.avg_iterations // 0')
    c_cost=$(echo "$control_data" | jq -r '.avg_cost // 0')
    t_cost=$(echo "$treatment_data" | jq -r '.avg_cost // 0')
    c_success=$(echo "$control_data" | jq -r '.success_rate // 0')
    t_success=$(echo "$treatment_data" | jq -r '.success_rate // 0')

    # Calculate deltas
    local iter_delta cost_delta success_delta
    iter_delta=$((c_iterations - t_iterations))
    cost_delta=$((c_cost - t_cost))
    success_delta=$((t_success - c_success))

    # Direction indicators
    local iter_dir cost_dir success_dir
    [[ $iter_delta -gt 0 ]] && iter_dir="${GREEN}↓${RESET}" || iter_dir="${RED}↑${RESET}"
    [[ $cost_delta -gt 0 ]] && cost_dir="${GREEN}↓${RESET}" || cost_dir="${RED}↑${RESET}"
    [[ $success_delta -gt 0 ]] && success_dir="${GREEN}↑${RESET}" || success_dir="${RED}↓${RESET}"

    echo -e "${BOLD}Metrics${RESET}"
    echo ""
    printf "  %-28s %10s %10s %10s\n" "Metric" "Control" "Treatment" "Delta"
    printf "  %s\n" "$(printf '%.0s-' {1..60})"
    printf "  %-28s %10d %10d %10s %s\n" "Avg Iterations" "$c_iterations" "$t_iterations" "$iter_delta" "$iter_dir"
    printf "  %-28s %10d %10d %10s %s\n" "Avg Cost (tokens)" "$c_cost" "$t_cost" "$cost_delta" "$cost_dir"
    printf "  %-28s %10d%% %10d%% %10s %s\n" "Success Rate" "$c_success" "$t_success" "$success_delta" "$success_dir"
    echo ""

    # Summary
    echo -e "${BOLD}Summary${RESET}"
    if [[ $iter_delta -gt 0 ]]; then
        success "Memory injection reduces iterations by ${iter_delta} (${GREEN}$(echo "scale=1; $iter_delta * 100 / $c_iterations" | bc)% improvement${RESET})"
    elif [[ $iter_delta -lt 0 ]]; then
        warn "Memory injection increases iterations by $((iter_delta * -1)) (regression)"
    else
        info "No significant difference in iteration count"
    fi

    if [[ $cost_delta -gt 0 ]]; then
        success "Memory injection reduces cost by ${cost_delta} tokens (${GREEN}$(echo "scale=1; $cost_delta * 100 / $c_cost" | bc)% savings${RESET})"
    elif [[ $cost_delta -lt 0 ]]; then
        warn "Memory injection increases cost by $((cost_delta * -1)) tokens (regression)"
    fi

    if [[ $success_delta -gt 0 ]]; then
        success "Memory injection improves success rate by ${success_delta}pp (${GREEN}$(echo "scale=1; $success_delta" | bc)% better${RESET})"
    elif [[ $success_delta -lt 0 ]]; then
        warn "Memory injection reduces success rate by $((success_delta * -1))pp (regression)"
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# _memory_aggregate_global
# Promotes high-frequency failure patterns to global.json for cross-repo learning
_memory_aggregate_global() {
    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"
    [[ ! -f "$failures_file" ]] && return 0

    local global_file="$GLOBAL_MEMORY"
    [[ ! -f "$global_file" ]] && return 0

    # Find patterns with seen_count >= 3
    local frequent_patterns
    frequent_patterns=$(jq -r '.failures[] | select(.seen_count >= 3) | .pattern' \
        "$failures_file" 2>/dev/null) || return 0
    [[ -z "$frequent_patterns" ]] && return 0

    local promoted=0
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue

        # Check if already in global
        local exists
        exists=$(jq --arg p "$pattern" \
            '[.common_patterns[] | select(.pattern == $p)] | length' \
            "$global_file" 2>/dev/null || echo "0")
        if [[ "${exists:-0}" -gt 0 ]]; then
            continue
        fi

        # Add to global, cap at 100 entries
        local tmp_global
        tmp_global=$(mktemp "${global_file}.tmp.XXXXXX")
    # shellcheck disable=SC2064
        trap "rm -f '$tmp_global'" RETURN
        jq --arg p "$pattern" \
           --arg ts "$(now_iso)" \
           --arg cat "general" \
           '.common_patterns += [{pattern: $p, promoted_at: $ts, category: $cat, source: "aggregate"}] |
            .common_patterns = (.common_patterns | .[-100:])' \
           "$global_file" > "$tmp_global" && mv "$tmp_global" "$global_file" || rm -f "$tmp_global"
        promoted=$((promoted + 1))
    done <<< "$frequent_patterns"

    if [[ "$promoted" -gt 0 ]]; then
        emit_event "memory.global_aggregated" "promoted=$promoted"
    fi
}

# memory_finalize_pipeline <state_file> <artifacts_dir>
# Single call that closes multiple feedback loops at pipeline completion
memory_finalize_pipeline() {
    local state_file="${1:-}"
    local artifacts_dir="${2:-}"
    [[ -z "$state_file" || ! -f "$state_file" ]] && return 0

    # Step 1: Capture pipeline-level learnings
    memory_capture_pipeline "$state_file" "$artifacts_dir" 2>/dev/null || true

    # Step 2: Process error log into failures.json
    memory_capture_failure_from_log "$artifacts_dir" 2>/dev/null || true

    # Step 3: Aggregate high-frequency patterns to global memory
    _memory_aggregate_global 2>/dev/null || true
}

# memory_get_dora_baseline [window_days] [offset_days]
# Calculates DORA metrics for a time window from events.jsonl.
# Returns JSON: {deploy_freq, cycle_time, cfr, mttr, total, grades: {df, ct, cfr, mttr}}
memory_get_dora_baseline() {
    local window_days="${1:-7}"
    local offset_days="${2:-0}"

    local events_file="${HOME}/.shipwright/events.jsonl"
    if [[ ! -f "$events_file" ]]; then
        echo '{"deploy_freq":0,"cycle_time":0,"cfr":0,"mttr":0,"total":0}'
        return 0
    fi

    local now_e
    now_e=$(now_epoch)
    local window_end=$((now_e - offset_days * 86400))
    local window_start=$((window_end - window_days * 86400))

    # Extract pipeline events for the window
    local metrics
    metrics=$(jq -s --argjson start "$window_start" --argjson end "$window_end" '
        [.[] | select(.ts_epoch >= $start and .ts_epoch < $end)] as $events |
        [$events[] | select(.type == "pipeline.completed")] as $completed |
        ($completed | length) as $total |
        [$completed[] | select(.result == "success")] as $successes |
        [$completed[] | select(.result == "failure")] as $failures |
        ($successes | length) as $success_count |
        ($failures | length) as $failure_count |

        # Deploy frequency (per week)
        (if $total > 0 then ($success_count * 7 / '"$window_days"') else 0 end) as $deploy_freq |

        # Cycle time median
        ([$successes[] | .duration_s] | sort |
            if length > 0 then .[length/2 | floor] else 0 end) as $cycle_time |

        # Change failure rate
        (if $total > 0 then ($failure_count / $total * 100) else 0 end) as $cfr |

        # MTTR
        ($completed | sort_by(.ts_epoch // 0) |
            [range(length) as $i |
                if .[$i].result == "failure" then
                    [.[$i+1:][] | select(.result == "success")][0] as $next |
                    if $next and $next.ts_epoch and .[$i].ts_epoch then
                        ($next.ts_epoch - .[$i].ts_epoch)
                    else null end
                else null end
            ] | map(select(. != null)) |
            if length > 0 then (add / length | floor) else 0 end
        ) as $mttr |

        {
            deploy_freq: ($deploy_freq * 10 | floor / 10),
            cycle_time: $cycle_time,
            cfr: ($cfr * 10 | floor / 10),
            mttr: $mttr,
            total: $total
        }
    ' "$events_file" 2>/dev/null || echo '{"deploy_freq":0,"cycle_time":0,"cfr":0,"mttr":0,"total":0}')

    echo "$metrics"
}

# memory_stats - display memory size and contents
memory_stats() {
    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local repo
    repo="$(repo_name)"

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Memory Stats: ${repo} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    # Size
    local total_size=0
    for f in "$mem_dir"/*.json; do
        if [[ -f "$f" ]]; then
            local fsize
            fsize=$(wc -c < "$f" | tr -d ' ')
            total_size=$((total_size + fsize))
        fi
    done

    local size_human
    if [[ "$total_size" -ge 1048576 ]]; then
        size_human="$(echo "$total_size" | awk '{printf "%.1fMB", $1/1048576}')"
    elif [[ "$total_size" -ge 1024 ]]; then
        size_human="$(echo "$total_size" | awk '{printf "%.1fKB", $1/1024}')"
    else
        size_human="${total_size}B"
    fi

    echo -e "  ${BOLD}Storage${RESET}"
    printf "    %-18s %s\n" "Total size:" "$size_human"
    printf "    %-18s %s\n" "Location:" "$mem_dir"
    echo ""

    # Counts
    local failure_count decision_count baseline_count known_issue_count
    failure_count=$(jq '.failures | length' "$mem_dir/failures.json" 2>/dev/null || echo 0)
    decision_count=$(jq '.decisions | length' "$mem_dir/decisions.json" 2>/dev/null || echo 0)
    baseline_count=$(jq '.baselines | length' "$mem_dir/metrics.json" 2>/dev/null || echo 0)
    known_issue_count=$(jq '.known_issues // [] | length' "$mem_dir/patterns.json" 2>/dev/null || echo 0)

    echo -e "  ${BOLD}Contents${RESET}"
    printf "    %-18s %s\n" "Failure patterns:" "$failure_count"
    printf "    %-18s %s\n" "Decisions:" "$decision_count"
    printf "    %-18s %s\n" "Baselines:" "$baseline_count"
    printf "    %-18s %s\n" "Known issues:" "$known_issue_count"
    echo ""

    # Age — oldest captured_at
    local captured_at
    captured_at=$(jq -r '.captured_at // ""' "$mem_dir/patterns.json" 2>/dev/null || echo "")
    if [[ -n "$captured_at" && "$captured_at" != "null" ]]; then
        printf "    %-18s %s\n" "First captured:" "$captured_at"
    fi

    # Event-based hit rate
    local inject_count capture_count
    if [[ -f "$EVENTS_FILE" ]]; then
        inject_count=$(grep -c '"memory.inject"' "$EVENTS_FILE" 2>/dev/null || true)
        inject_count="${inject_count:-0}"
        capture_count=$(grep -c '"memory.capture"' "$EVENTS_FILE" 2>/dev/null || true)
        capture_count="${capture_count:-0}"
        echo ""
        echo -e "  ${BOLD}Usage${RESET}"
        printf "    %-18s %s\n" "Context injections:" "$inject_count"
        printf "    %-18s %s\n" "Pipeline captures:" "$capture_count"
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# Reduce weight of memory entries older than threshold.
# Args: $1=days_threshold (default 30), $2=memory_dir (optional)
memory_decay_old() {
    local days_threshold="${1:-30}"
    local memory_dir="${2:-}"

    if [[ -z "$memory_dir" ]] && type repo_memory_dir >/dev/null 2>&1; then
        memory_dir="$(repo_memory_dir)"
    fi
    memory_dir="${memory_dir:-$HOME/.shipwright/memory}"

    if [[ ! -d "$memory_dir" ]]; then
        return 0
    fi

    local now_epoch decayed_count
    now_epoch="$(date +%s)"
    decayed_count=0
    local threshold_epoch
    threshold_epoch=$(( now_epoch - (days_threshold * 86400) ))

    # Process failure patterns file if it exists
    local failures_file="${memory_dir}/failures.json"
    if [[ -f "$failures_file" ]]; then
        local tmp
        tmp="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/mem-decay-$$.tmp")"
        jq --argjson threshold "$threshold_epoch" --argjson half "$days_threshold" '
            if type == "array" then
                [.[] | if (.timestamp // 0) < $threshold then
                    .weight = ((.weight // 1) * 0.5 | if . < 0.1 then 0.1 else . end)
                else . end]
            else . end
        ' "$failures_file" > "$tmp" 2>/dev/null
        if [[ -s "$tmp" ]]; then
            mv "$tmp" "$failures_file"
            decayed_count=$((decayed_count + 1))
        else
            rm -f "$tmp"
        fi
    fi

    # Process decisions file if it exists
    local decisions_file="${memory_dir}/decisions.json"
    if [[ -f "$decisions_file" ]]; then
        local tmp
        tmp="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/mem-decay2-$$.tmp")"
        jq --argjson threshold "$threshold_epoch" '
            if type == "array" then
                [.[] | if (.timestamp // 0) < $threshold then
                    .weight = ((.weight // 1) * 0.5 | if . < 0.1 then 0.1 else . end)
                else . end]
            else . end
        ' "$decisions_file" > "$tmp" 2>/dev/null
        if [[ -s "$tmp" ]]; then
            mv "$tmp" "$decisions_file"
            decayed_count=$((decayed_count + 1))
        else
            rm -f "$tmp"
        fi
    fi

    if [[ "$decayed_count" -gt 0 ]]; then
        emit_event "memory.decay_applied" "files=$decayed_count" "threshold_days=$days_threshold"
    fi
}
