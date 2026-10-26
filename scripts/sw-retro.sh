#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright retro — Sprint Retrospective Engine                         ║
# ║  Analyze metrics · Identify improvements · Create action items          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# shellcheck disable=SC2034
VERSION="4.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
_COMPAT="$SCRIPT_DIR/lib/compat.sh"
# shellcheck disable=SC1090
[[ -f "$_COMPAT" ]] && source "$_COMPAT"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# DB layer for dual-read (SQLite + JSONL fallback)
# shellcheck source=sw-db.sh
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi

format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 3600 ]]; then
        printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%ds" "$secs"
    fi
}

# ─── State Storage ──────────────────────────────────────────────────────────
RETRO_DIR="${HOME}/.shipwright/retros"
ensure_retro_dir() {
    mkdir -p "$RETRO_DIR"
}

# ─── Sprint Date Calculation ────────────────────────────────────────────────
get_sprint_dates() {
    local from_date="${1:-}"
    local to_date="${2:-}"

    if [[ -z "$from_date" ]]; then
        # Default: last 7 days (cross-platform: date_days_ago from compat.sh)
        to_date=$(date -u +"%Y-%m-%d")
        from_date=$(date_days_ago 7 2>/dev/null || python3 -c "from datetime import datetime, timedelta; print((datetime.utcnow() - timedelta(days=7)).strftime('%Y-%m-%d'))")
    elif [[ -z "$to_date" ]]; then
        to_date=$(date -u +"%Y-%m-%d")
    fi

    echo "${from_date} ${to_date}"
}

# ─── Analyze Pipeline Events ────────────────────────────────────────────────
analyze_sprint_data() {
    local from_date="$1"
    local to_date="$2"

    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required for sprint analysis"
        return 1
    fi

    # Convert dates to epoch (cross-platform: date_to_epoch from compat.sh)
    local from_epoch to_epoch
    from_epoch=$(date_to_epoch "${from_date}T00:00:00Z" || echo 0)
    to_epoch=$(date_to_epoch "${to_date}T23:59:59Z" || echo 0)

    # Use db_query_events_since (SQLite + JSONL fallback)
    db_query_events_since "$from_epoch" "" "$to_epoch" | jq --argjson from "$from_epoch" --argjson to "$to_epoch" '
        (if type == "array" then . else [] end) as $events |
        [$events[] | select(.type == "pipeline.completed")] as $completed |
        ($completed | length) as $total_pipelines |
        [$completed[] | select(.result == "success")] as $successes |
        ($successes | length) as $succeeded |
        ($total_pipelines - $succeeded) as $failed |
        [$events[] | select(.type == "pipeline.retry")] as $retries |
        ($retries | length) as $retry_count |
        [$completed[].duration_s // 0] | (if length > 0 then (add / length) else 0 end) as $avg_duration |
        [$successes[] | (.stages_passed // 0)] | (if length > 0 then (add / length) else 0 end) as $avg_stages |
        [$completed[] | select(.slowest_stage) | .slowest_stage] | .[0] // "unknown" as $slowest |
        (if $total_pipelines > 0 then ((($succeeded / $total_pipelines) * 100) | floor) else 0 end) as $quality |
        {
            pipelines: $total_pipelines,
            succeeded: $succeeded,
            failed: $failed,
            retries: $retry_count,
            avg_duration: ($avg_duration | floor),
            avg_stages: ($avg_stages * 10 | floor / 10),
            slowest_stage: $slowest,
            quality_score: $quality
        }
    ' 2>/dev/null || echo '{"pipelines":0,"succeeded":0,"failed":0,"retries":0,"avg_duration":0,"avg_stages":0,"slowest_stage":"","quality_score":0}'
}

# ─── Agent Performance Analysis ─────────────────────────────────────────────
analyze_agent_performance() {
    local from_date="$1"
    local to_date="$2"

    if ! command -v jq >/dev/null 2>&1; then
        echo '{"agents":[]}'
        return 0
    fi

    local from_epoch to_epoch
    from_epoch=$(date_to_epoch "${from_date}T00:00:00Z" || echo 0)
    to_epoch=$(date_to_epoch "${to_date}T23:59:59Z" || echo 0)

    db_query_events_since "$from_epoch" "" "$to_epoch" | jq --argjson from "$from_epoch" --argjson to "$to_epoch" '
        (if type == "array" then . else [] end) as $events |
        [$events[] | select(.type == "pipeline.completed" and (.agent_id // .agent))] as $completions |
        $completions | group_by(.agent_id // .agent) | map({
            agent: .[0].agent_id // .[0].agent,
            completed: length,
            succeeded: ([.[] | select(.result == "success")] | length),
            failed: ([.[] | select(.result == "failure")] | length),
            avg_duration: (([.[].duration_s // 0] | add / length) | floor)
        }) | sort_by(-.completed) as $agent_stats |
        { agents: $agent_stats }
    ' 2>/dev/null || echo '{"agents":[]}'
}

# ─── Velocity & Trends ──────────────────────────────────────────────────────
analyze_velocity() {
    local from_date="$1"
    local to_date="$2"

    if ! command -v jq >/dev/null 2>&1; then
        echo '{"current":0,"previous":0,"trend":"→"}'
        return 0
    fi

    # Get current period (cross-platform: date_to_epoch from compat.sh)
    local from_epoch to_epoch prev_from_epoch prev_to_epoch
    from_epoch=$(date_to_epoch "${from_date}T00:00:00Z" || echo 0)
    to_epoch=$(date_to_epoch "${to_date}T23:59:59Z" || echo 0)

    # Get previous period (same duration before current)
    local duration_days
    duration_days=$(( (to_epoch - from_epoch) / 86400 ))
    prev_to_epoch=$from_epoch
    prev_from_epoch=$((from_epoch - (duration_days * 86400)))

    # Need full event range for current + previous; use db_query_events since prev_from may be before from
    db_query_events "" 10000 | jq --argjson curr_from "$from_epoch" --argjson curr_to "$to_epoch" \
           --argjson prev_from "$prev_from_epoch" --argjson prev_to "$prev_to_epoch" '
        (if type == "array" then . else [] end) as $all |
        [$all[] | select(.ts_epoch >= $curr_from and .ts_epoch <= $curr_to and .type == "pipeline.completed" and .result == "success")] | length as $current |
        [$all[] | select(.ts_epoch >= $prev_from and .ts_epoch <= $prev_to and .type == "pipeline.completed" and .result == "success")] | length as $previous |
        (if $previous > 0 and $current > $previous then "↑" elif $current < $previous then "↓" else "→" end) as $trend |
        {
            current: $current,
            previous: $previous,
            trend: $trend
        }
    ' 2>/dev/null || echo '{"current":0,"previous":0,"trend":"→"}'
}

# ─── Generate Insights & Actions ────────────────────────────────────────────
generate_improvement_actions() {
    local analysis_json="$1"

    if ! command -v jq >/dev/null 2>&1; then
        echo '{"actions":[]}'
        return 0
    fi

    local quality_score failed_pipelines retries slowest_stage
    quality_score=$(echo "$analysis_json" | jq -r '.quality_score // 0')
    failed_pipelines=$(echo "$analysis_json" | jq -r '.failed // 0')
    retries=$(echo "$analysis_json" | jq -r '.retries // 0')
    slowest_stage=$(echo "$analysis_json" | jq -r '.slowest_stage // ""')

    local actions_json='{"actions":['

    # Action 1: Quality improvement
    if [[ "$quality_score" -lt 80 ]]; then
        actions_json="${actions_json}{\"priority\":\"high\",\"title\":\"Improve pipeline success rate to 85%+\",\"description\":\"Current: ${quality_score}%. Investigate $failed_pipelines failed pipelines and reduce quality gate failures.\",\"label\":\"improvement\"},"
    fi

    # Action 2: Reduce retries
    if [[ "$retries" -gt 2 ]]; then
        actions_json="${actions_json}{\"priority\":\"high\",\"title\":\"Reduce retry count\",\"description\":\"${retries} retries detected. Analyze root causes and add early detection.\",\"label\":\"reliability\"},"
    fi

    # Action 3: Optimize slow stages
    if [[ -n "$slowest_stage" && "$slowest_stage" != "unknown" ]]; then
        actions_json="${actions_json}{\"priority\":\"medium\",\"title\":\"Optimize ${slowest_stage} stage performance\",\"description\":\"This is the slowest pipeline stage. Consider parallelization or caching.\",\"label\":\"performance\"},"
    fi

    # Action 4: Consistency
    actions_json="${actions_json}{\"priority\":\"medium\",\"title\":\"Stabilize pipeline execution time\",\"description\":\"Review variance in stage durations and standardize resource allocation.\",\"label\":\"process\"},"

    # Remove trailing comma and close
    actions_json="${actions_json%,}]}"
    echo "$actions_json"
}

# ─── Create GitHub Issues for Actions ────────────────────────────────────────
create_action_issues() {
    local actions_json="$1"

    if ! command -v gh >/dev/null 2>&1; then
        warn "GitHub CLI (gh) not found. Skipping issue creation."
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found. Skipping issue creation."
        return 1
    fi

    local action_count
    action_count=$(echo "$actions_json" | jq '.actions | length' 2>/dev/null || echo "0")

    for ((i = 0; i < action_count; i++)); do
        local title description label priority
        title=$(echo "$actions_json" | jq -r ".actions[$i].title")
        description=$(echo "$actions_json" | jq -r ".actions[$i].description")
        label=$(echo "$actions_json" | jq -r ".actions[$i].label")
        priority=$(echo "$actions_json" | jq -r ".actions[$i].priority")

        # Create GitHub issue
        if gh issue create \
            --title "Retro: $title" \
            --body "$description" \
            --label "$label,retro" \
            --label "$priority" 2>/dev/null; then
            success "Created issue: $title"
        fi
    done
}

# ─── Report Generation ──────────────────────────────────────────────────────
generate_retro_report() {
    local from_date="$1"
    local to_date="$2"
    local analysis_json="$3"
    local agent_json="$4"
    local velocity_json="$5"

    ensure_retro_dir

    local report_file="${RETRO_DIR}/retro-${from_date}-to-${to_date}.md"
    local report_json="${RETRO_DIR}/retro-${from_date}-to-${to_date}.json"

    # Extract metrics
    local pipelines succeeded failed retries avg_duration quality_score
    pipelines=$(echo "$analysis_json" | jq -r '.pipelines // 0')
    succeeded=$(echo "$analysis_json" | jq -r '.succeeded // 0')
    failed=$(echo "$analysis_json" | jq -r '.failed // 0')
    retries=$(echo "$analysis_json" | jq -r '.retries // 0')
    avg_duration=$(echo "$analysis_json" | jq -r '.avg_duration // 0')
    quality_score=$(echo "$analysis_json" | jq -r '.quality_score // 0')

    local current_velocity previous_velocity trend
    current_velocity=$(echo "$velocity_json" | jq -r '.current // 0')
    previous_velocity=$(echo "$velocity_json" | jq -r '.previous // 0')
    trend=$(echo "$velocity_json" | jq -r '.trend // "→"')

    # Generate markdown report
    {
        echo "# Sprint Retrospective"
        echo ""
        echo "**Period**: ${from_date} to ${to_date}"
        echo "**Generated**: $(now_iso)"
        echo ""
        echo "## Summary"
        echo ""
        echo "| Metric | Value |"
        echo "|--------|-------|"
        echo "| Total Pipelines | $pipelines |"
        echo "| Succeeded | $succeeded |"
        echo "| Failed | $failed |"
        echo "| Success Rate | ${quality_score}% |"
        echo "| Retries | $retries |"
        echo "| Avg Duration | $(format_duration "$avg_duration") |"
        echo ""
        echo "## Velocity"
        echo ""
        echo "| Period | Successful Pipelines | Trend |"
        echo "|--------|----------------------|-------|"
        echo "| Current | $current_velocity | $trend |"
        echo "| Previous | $previous_velocity | |"
        echo ""
        echo "## What Went Well"
        echo ""
        if [[ "$quality_score" -ge 90 ]]; then
            echo "- **High quality**: ${quality_score}% success rate demonstrates strong pipeline stability"
        fi
        if [[ "$retries" -le 1 ]]; then
            echo "- **Low retry rate**: Minimal retries indicate reliable execution"
        fi
        if [[ "$current_velocity" -gt "$previous_velocity" ]]; then
            echo "- **Velocity increase**: $trend Successful deliveries increasing"
        fi
        echo ""
        echo "## What Went Wrong"
        echo ""
        if [[ "$quality_score" -lt 80 ]]; then
            echo "- **Quality concerns**: ${quality_score}% success rate needs improvement"
        fi
        if [[ "$failed" -gt 0 ]]; then
            echo "- **Pipeline failures**: $failed failed pipelines in this sprint"
        fi
        if [[ "$retries" -gt 2 ]]; then
            echo "- **High retry count**: $retries retries indicates instability"
        fi
        echo ""
        echo "## Agent Performance"
        echo ""
        echo "| Agent | Completed | Succeeded | Failed | Avg Duration |"
        echo "|-------|-----------|-----------|--------|--------------|"
    } > "$report_file"

    # Add agent stats
    if command -v jq >/dev/null 2>&1; then
        local agent_count
        agent_count=$(echo "$agent_json" | jq '.agents | length' 2>/dev/null || echo 0)
        for ((i = 0; i < agent_count; i++)); do
            local agent completed succeeded_agent failed_agent avg_dur
            agent=$(echo "$agent_json" | jq -r ".agents[$i].agent" 2>/dev/null || echo "unknown")
            completed=$(echo "$agent_json" | jq -r ".agents[$i].completed // 0" 2>/dev/null || echo 0)
            succeeded_agent=$(echo "$agent_json" | jq -r ".agents[$i].succeeded // 0" 2>/dev/null || echo 0)
            failed_agent=$(echo "$agent_json" | jq -r ".agents[$i].failed // 0" 2>/dev/null || echo 0)
            avg_dur=$(echo "$agent_json" | jq -r ".agents[$i].avg_duration // 0" 2>/dev/null || echo 0)

            echo "| $agent | $completed | $succeeded_agent | $failed_agent | $(format_duration "$avg_dur") |" >> "$report_file"
        done
    fi

    {
        echo ""
        echo "## Improvement Actions"
        echo ""
    } >> "$report_file"

    # Capture full analysis to JSON
    # shellcheck disable=SC2046
    jq -n \
        --argjson analysis "$analysis_json" \
        --argjson agents "$agent_json" \
        --argjson velocity "$velocity_json" \
        --arg from_date "$from_date" \
        --arg to_date "$to_date" \
        '{
            from_date: $from_date,
            to_date: $to_date,
            generated_at: "'$(now_iso)'",
            analysis: $analysis,
            agents: $agents,
            velocity: $velocity
        }' > "$report_json"

    success "Report generated: $report_file"
    emit_event "retro.completed" "from_date=$from_date" "to_date=$to_date" "quality_score=$quality_score"
}

# ─── Subcommands ───────────────────────────────────────────────────────────

cmd_run() {
    local from_date to_date
    from_date="${1:-}"
    to_date="${2:-}"

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)
                from_date="$2"
                shift 2
                ;;
            --to)
                to_date="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Get sprint dates
    read -r from_date to_date <<< "$(get_sprint_dates "$from_date" "$to_date")"

    info "Running sprint retrospective for ${from_date} to ${to_date}"
    echo ""

    # Analyze data
    local analysis agent_perf velocity
    analysis=$(analyze_sprint_data "$from_date" "$to_date")
    agent_perf=$(analyze_agent_performance "$from_date" "$to_date")
    velocity=$(analyze_velocity "$from_date" "$to_date")

    # Display summary
    echo -e "${BOLD}Sprint Summary${RESET}"
    if command -v jq >/dev/null 2>&1; then
        local pipelines succeeded failed quality_score
        pipelines=$(echo "$analysis" | jq -r '.pipelines // 0')
        succeeded=$(echo "$analysis" | jq -r '.succeeded // 0')
        failed=$(echo "$analysis" | jq -r '.failed // 0')
        quality_score=$(echo "$analysis" | jq -r '.quality_score // 0')

        echo "Pipelines: $pipelines total | ${GREEN}$succeeded succeeded${RESET} | ${RED}$failed failed${RESET}"
        echo "Success Rate: ${quality_score}%"
        echo ""
    fi

    # Generate improvements
    local improvements
    improvements=$(generate_improvement_actions "$analysis")

    # Generate report
    generate_retro_report "$from_date" "$to_date" "$analysis" "$agent_perf" "$velocity"

    # Feed retro into self-optimization loop (|| true to avoid breaking retro if optimization unavailable)
    [[ -f "$SCRIPT_DIR/sw-self-optimize.sh" ]] && "$SCRIPT_DIR/sw-self-optimize.sh" ingest-retro || true

    # Offer to create issues
    if command -v gh >/dev/null 2>&1; then
        echo ""
        info "Create improvement issues? (y/n)"
        read -r -t 5 response || response="n"
        if [[ "$response" =~ ^[yY]$ ]]; then
            create_action_issues "$improvements"
        fi
    fi
}

cmd_summary() {
    local from_date to_date
    from_date="${1:-}"
    to_date="${2:-}"

    read -r from_date to_date <<< "$(get_sprint_dates "$from_date" "$to_date")"

    info "Sprint Summary for ${from_date} to ${to_date}"
    echo ""

    local analysis
    analysis=$(analyze_sprint_data "$from_date" "$to_date")

    if command -v jq >/dev/null 2>&1; then
        echo "$analysis" | jq '.'
    else
        echo "$analysis"
    fi
}

cmd_trends() {
    info "Multi-Sprint Trend Analysis"
    echo ""

    local event_check
    event_check=$(db_query_events "" 1 2>/dev/null || echo "[]")
    if [[ "$event_check" == "[]" ]] || [[ -z "$event_check" ]]; then
        error "No event data found. Run pipelines first."
        return 1
    fi

    # Show last 4 sprints
    local today
    today=$(date -u +"%Y-%m-%d")

    for i in 0 1 2 3; do
        local offset_end offset_start end_date start_date
        offset_end=$((i * 7))
        offset_start=$(((i + 1) * 7))

        end_date=$(date_days_ago "$offset_end" 2>/dev/null || echo "$today")
        start_date=$(date_days_ago "$offset_start" 2>/dev/null || echo "$today")

        local analysis
        analysis=$(analyze_sprint_data "$start_date" "$end_date")

        if command -v jq >/dev/null 2>&1; then
            local quality pipelines
            quality=$(echo "$analysis" | jq -r '.quality_score')
            pipelines=$(echo "$analysis" | jq -r '.pipelines')
            echo "Sprint $(($i + 1)) (${start_date} to ${end_date}): ${quality}% success, $pipelines pipelines"
        fi
    done
}

cmd_agents() {
    local from_date to_date
    from_date="${1:-}"
    to_date="${2:-}"

    read -r from_date to_date <<< "$(get_sprint_dates "$from_date" "$to_date")"

    info "Agent Performance for ${from_date} to ${to_date}"
    echo ""

    local agent_perf
    agent_perf=$(analyze_agent_performance "$from_date" "$to_date")

    if command -v jq >/dev/null 2>&1; then
        echo "$agent_perf" | jq '.agents[] | "\(.agent): \(.completed) completed, \(.succeeded) succeeded, \(.failed) failed"' -r
    else
        echo "$agent_perf"
    fi
}

cmd_actions() {
    local from_date to_date
    from_date="${1:-}"
    to_date="${2:-}"

    read -r from_date to_date <<< "$(get_sprint_dates "$from_date" "$to_date")"

    info "Improvement Actions for ${from_date} to ${to_date}"
    echo ""

    local analysis improvements
    analysis=$(analyze_sprint_data "$from_date" "$to_date")
    improvements=$(generate_improvement_actions "$analysis")

    if command -v jq >/dev/null 2>&1; then
        echo "$improvements" | jq '.actions[] | "\(.priority | ascii_upcase): \(.title)\n  \(.description)"' -r
    else
        echo "$improvements"
    fi
}

cmd_compare() {
    local period1="${1:-}"
    local period2="${2:-}"

    if [[ -z "$period1" || -z "$period2" ]]; then
        error "Usage: sw retro compare <from-date1> <from-date2>"
        return 1
    fi

    info "Comparing sprints starting ${period1} vs ${period2}"
    echo ""

    local analysis1 analysis2
    analysis1=$(analyze_sprint_data "$period1" "$(date_add_days "$period1" 7)")
    analysis2=$(analyze_sprint_data "$period2" "$(date_add_days "$period2" 7)")

    if command -v jq >/dev/null 2>&1; then
        echo "Sprint 1 (${period1}):"
        echo "$analysis1" | jq '.'
        echo ""
        echo "Sprint 2 (${period2}):"
        echo "$analysis2" | jq '.'
    fi
}

cmd_history() {
    info "Sprint Retrospective History"
    echo ""

    ensure_retro_dir
    if [[ ! -d "$RETRO_DIR" || -z "$(ls -A "$RETRO_DIR" 2>/dev/null)" ]]; then
        warn "No retrospectives found. Run 'sw retro run' first."
        return 0
    fi

    ls -1t "$RETRO_DIR"/retro-*.md 2>/dev/null | while read -r file; do
        basename "$file" .md
    done
}

# ─── Negative-Critical Retrospective ───────────────────────────────────────
# Analyze pipelines for silent failures and quality gate skipping
cmd_negative_audit() {
    local from_date="${1:-}"
    local to_date="${2:-}"

    if [[ -z "$from_date" ]]; then
        to_date=$(date -u +"%Y-%m-%d")
        from_date=$(date_days_ago 7 2>/dev/null || python3 -c "from datetime import datetime, timedelta; print((datetime.utcnow() - timedelta(days=7)).strftime('%Y-%m-%d'))")
    elif [[ -z "$to_date" ]]; then
        to_date=$(date -u +"%Y-%m-%d")
    fi

    info "Negative Audit for ${from_date} to ${to_date}"
    echo ""

    if ! command -v jq >/dev/null 2>&1; then
        error "jq required for negative audit"
        return 1
    fi

    local from_epoch to_epoch
    from_epoch=$(date_to_epoch "${from_date}T00:00:00Z" || echo 0)
    to_epoch=$(date_to_epoch "${to_date}T23:59:59Z" || echo 0)

    local findings='{"issues":[]}'
    local issue_count=0

    # Check for empty artifacts (silent stage failures)
    echo ""
    echo -e "${BOLD}1. Empty Artifacts Detection${RESET}"
    local empty_count=0
    if [[ -d ".claude/pipeline-artifacts" ]]; then
        while IFS= read -r artifact_file; do
            if [[ -f "$artifact_file" && ! -s "$artifact_file" ]]; then
                local basename
                basename=$(basename "$artifact_file")
                warn "Empty artifact: $basename"
                findings=$(echo "$findings" | jq --arg msg "Empty artifact: $basename" '.issues += [{"type": "empty_artifact", "message": $msg}]')
                empty_count=$((empty_count + 1))
                issue_count=$((issue_count + 1))
            fi
        done < <(find ".claude/pipeline-artifacts" -type f 2>/dev/null)
    fi
    [[ $empty_count -eq 0 ]] && echo "  ✓ No empty artifacts found"

    # Check for skipped quality gates
    echo ""
    echo -e "${BOLD}2. Skipped Quality Gates${RESET}"
    local skipped_count=0
    if [[ -f ".claude/pipeline-artifacts/compound-quality.log" ]]; then
        local skip_lines
        skip_lines=$(grep -c "skipped\|SKIP" ".claude/pipeline-artifacts/compound-quality.log" 2>/dev/null || echo "0")
        if [[ "$skip_lines" -gt 0 ]]; then
            warn "Found $skip_lines skipped quality checks"
            findings=$(echo "$findings" | jq --arg msg "Skipped $skip_lines quality gates" '.issues += [{"type": "skipped_gates", "message": $msg}]')
            skipped_count=$skip_lines
            issue_count=$((issue_count + skipped_count))
        fi
    fi
    [[ $skipped_count -eq 0 ]] && echo "  ✓ No skipped quality gates"

    # Check cost vs predicted
    echo ""
    echo -e "${BOLD}3. Cost Prediction Accuracy${RESET}"
    local intel_cache="${SHIPWRIGHT_INTELLIGENCE_CACHE:-.claude/intelligence-cache.json}"
    if [[ -f "$intel_cache" ]]; then
        local predicted_cost actual_cost
        predicted_cost=$(jq -r '.cost_estimate // 0' "$intel_cache" 2>/dev/null)
        if [[ -f ".claude/pipeline-artifacts/pipeline-state.md" ]]; then
            actual_cost=$(grep -oP "Cost: \K[0-9]+" ".claude/pipeline-artifacts/pipeline-state.md" | tail -1 || echo "0")
            if [[ -n "$predicted_cost" && "$predicted_cost" != "0" ]]; then
                local cost_delta
                cost_delta=$((actual_cost - predicted_cost))
                local percent_error
                percent_error=$((cost_delta * 100 / predicted_cost))
                if [[ $percent_error -gt 30 || $percent_error -lt -30 ]]; then
                    warn "Cost prediction off by ${percent_error}% (predicted: $predicted_cost, actual: $actual_cost)"
                    findings=$(echo "$findings" | jq --arg msg "Cost off by ${percent_error}%" '.issues += [{"type": "cost_prediction", "message": $msg}]')
                    issue_count=$((issue_count + 1))
                fi
            fi
        fi
    fi
    [[ $issue_count -lt 4 ]] && echo "  ✓ Cost predictions accurate"

    # Check loop iteration limit exhaustion
    echo ""
    echo -e "${BOLD}4. Loop Convergence Status${RESET}"
    if [[ -f ".claude/pipeline-artifacts/pipeline-state.md" ]]; then
        local loop_iter loop_limit
        loop_iter=$(grep -oP "Iteration: \K[0-9]+" ".claude/pipeline-artifacts/pipeline-state.md" | tail -1 || echo "0")
        loop_limit=$(grep -oP "Limit: \K[0-9]+" ".claude/pipeline-artifacts/pipeline-state.md" | tail -1 || echo "20")
        if [[ "$loop_iter" -ge "$loop_limit" ]]; then
            warn "Loop exhausted iterations ($loop_iter/$loop_limit)"
            findings=$(echo "$findings" | jq --arg msg "Loop iteration limit exhausted: $loop_iter/$loop_limit" '.issues += [{"type": "loop_exhaustion", "message": $msg}]')
            issue_count=$((issue_count + 1))
        fi
    fi
    [[ $issue_count -lt 5 ]] && echo "  ✓ Loop convergence normal"

    # Check for || true errors
    echo ""
    echo -e "${BOLD}5. Unsafe Error Suppression${RESET}"
    if [[ -f ".claude/pipeline-artifacts/error-log.jsonl" ]]; then
        local true_errors
        true_errors=$(grep -c "|| true" ".claude/pipeline-artifacts/error-log.jsonl" 2>/dev/null || echo "0")
        if [[ "$true_errors" -gt 0 ]]; then
            warn "Found $true_errors errors suppressed with || true"
            findings=$(echo "$findings" | jq --arg msg "Found $true_errors unsuppressed || true errors" '.issues += [{"type": "error_suppression", "message": $msg}]')
            issue_count=$((issue_count + 1))
        fi
    fi
    [[ $true_errors -eq 0 ]] && echo "  ✓ No unsafe error suppression"

    # Summary
    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    if [[ $issue_count -eq 0 ]]; then
        success "Negative audit passed: no critical issues detected"
    else
        warn "Negative audit found $issue_count issue(s)"
        echo "$findings" | jq '.issues[] | "\(.type): \(.message)"' -r
    fi

    # Store in memory as retrospective pattern
    if type memory_capture_pattern >/dev/null 2>&1; then
        local pattern_data
        pattern_data=$(echo "$findings" | jq -n \
            --argjson findings "$(echo "$findings" | jq '.issues | length')" \
            --arg from_date "$from_date" \
            --arg to_date "$to_date" \
            '{
                type: "negative_audit",
                date_range: ($from_date + " to " + $to_date),
                issues_found: $findings
            }')
        memory_capture_pattern "negative_audit" "$pattern_data" 2>/dev/null || true
    fi

    emit_event "retro.negative_audit" \
        "from_date=$from_date" \
        "to_date=$to_date" \
        "issues=$issue_count"

    echo ""
}

cmd_help() {
    cat << 'EOF'
Usage: shipwright retro <subcommand> [options]

Subcommands:
  run [--from DATE] [--to DATE]  Run retrospective for sprint (default: last 7 days)
  summary [DATE1] [DATE2]         Quick sprint summary stats
  trends                          Multi-sprint trend analysis (last 4 sprints)
  agents [DATE1] [DATE2]          Agent performance breakdown
  actions [DATE1] [DATE2]         List generated improvement actions
  compare DATE1 DATE2             Compare two sprint periods
  history                         Show past retrospective reports
  quality                         Show quality index trend (longitudinal)
  negative [--from DATE] [--to]   Negative audit: detect silent failures, skipped gates
  help                            Show this help message

Options:
  --from DATE                      Start date (YYYY-MM-DD)
  --to DATE                        End date (YYYY-MM-DD)

Examples:
  shipwright retro run                              # Last 7 days
  shipwright retro run --from 2025-02-01 --to 2025-02-08
  shipwright retro summary
  shipwright retro trends
  shipwright retro agents
  shipwright retro compare 2025-02-01 2025-01-25
  shipwright retro negative                         # Last 7 days audit

EOF
}

# ─── Main ──────────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    subcommand="${1:-help}"
    shift 2>/dev/null || true

    case "$subcommand" in
        run)
            cmd_run "$@"
            ;;
        summary)
            cmd_summary "$@"
            ;;
        trends)
            cmd_trends "$@"
            ;;
        agents)
            cmd_agents "$@"
            ;;
        actions)
            cmd_actions "$@"
            ;;
        compare)
            cmd_compare "$@"
            ;;
        history)
            cmd_history "$@"
            ;;
        quality)
            if [[ -f "$SCRIPT_DIR/sw-self-optimize.sh" ]]; then
                source "$SCRIPT_DIR/sw-self-optimize.sh" 2>/dev/null || true
                cmd_quality_index 2>/dev/null || {
                    echo "No quality data yet. Run some pipelines first."
                }
            else
                error "sw-self-optimize.sh not found"
                exit 1
            fi
            ;;
        negative)
            cmd_negative_audit "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            error "Unknown subcommand: $subcommand"
            cmd_help
            exit 1
            ;;
    esac
fi
