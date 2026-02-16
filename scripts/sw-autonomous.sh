#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright autonomous — Master controller for AI-building-AI loop      ║
# ║  Analyze → Create issues → Build → Learn → Repeat                      ║
# ║  Closes the loop: PM creates issues, daemon builds, system learns       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
CYAN="${CYAN:-\033[38;2;0;212;255m}"
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"
BLUE="${BLUE:-\033[38;2;0;102;255m}"
GREEN="${GREEN:-\033[38;2;74;222;128m}"
YELLOW="${YELLOW:-\033[38;2;250;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
RESET="${RESET:-\033[0m}"

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

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

# ─── State & Config Paths ─────────────────────────────────────────────────
STATE_DIR="${HOME}/.shipwright/autonomous"
STATE_FILE="${STATE_DIR}/state.json"
HISTORY_FILE="${STATE_DIR}/history.jsonl"
CONFIG_FILE="${STATE_DIR}/config.json"
CYCLE_COUNTER="${STATE_DIR}/cycle-counter.txt"

# Ensure directories exist
ensure_state_dir() {
    mkdir -p "$STATE_DIR"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "cycle_interval_minutes": 60,
  "max_issues_per_cycle": 5,
  "max_concurrent_pipelines": 2,
  "enable_human_approval": false,
  "approval_timeout_minutes": 30,
  "rollback_on_failures": true,
  "max_consecutive_failures": 3,
  "learning_enabled": true,
  "self_improvement_enabled": true,
  "shipwright_self_improvement_threshold": 3
}
EOF
        info "Created default config at ${CONFIG_FILE}"
    fi
}

# Get config value
get_config() {
    local key="$1"
    local default="${2:-}"
    jq -r ".${key} // \"${default}\"" "$CONFIG_FILE" 2>/dev/null || echo "$default"
}

# Set config value
set_config() {
    local key="$1"
    local value="$2"
    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-autonomous-config.XXXXXX")
    # Try to parse value as JSON first, otherwise treat as string
    local json_value
    if echo "$value" | jq . >/dev/null 2>&1; then
        json_value="$value"
    else
        json_value="\"${value//\"/\\\"}\""
    fi
    jq ".\"$key\" = $json_value" "$CONFIG_FILE" > "$tmp_file" 2>/dev/null && \
        mv "$tmp_file" "$CONFIG_FILE" || rm -f "$tmp_file"
}

# ─── State Management ───────────────────────────────────────────────────────

init_state() {
    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-autonomous-state.XXXXXX")
    jq -n \
        --arg started "$(now_iso)" \
        '{
            status: "idle",
            started: $started,
            last_cycle: null,
            cycles_completed: 0,
            issues_created: 0,
            issues_completed: 0,
            pipelines_succeeded: 0,
            pipelines_failed: 0,
            consecutive_failures: 0,
            paused_at: null
        }' > "$tmp_file" && mv "$tmp_file" "$STATE_FILE" || rm -f "$tmp_file"
}

read_state() {
    ensure_state_dir
    if [[ ! -f "$STATE_FILE" ]]; then
        init_state
    fi
    cat "$STATE_FILE"
}

update_state() {
    local key="$1"
    local value="$2"
    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-autonomous-state.XXXXXX")
    # Try to parse value as JSON first, otherwise treat as string
    local json_value
    if echo "$value" | jq . >/dev/null 2>&1; then
        json_value="$value"
    else
        json_value="\"${value//\"/\\\"}\""
    fi
    read_state | jq ".\"$key\" = $json_value" > "$tmp_file" && \
        mv "$tmp_file" "$STATE_FILE" || rm -f "$tmp_file"
}

increment_counter() {
    local key="$1"
    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-autonomous-state.XXXXXX")
    read_state | jq ".\"$key\" += 1" > "$tmp_file" && \
        mv "$tmp_file" "$STATE_FILE" || rm -f "$tmp_file"
}

record_cycle() {
    local issues_found="$1"
    local issues_created="$2"
    local status="$3"
    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-autonomous-cycle.XXXXXX")
    jq -n \
        --arg ts "$(now_iso)" \
        --argjson found "$issues_found" \
        --argjson created "$issues_created" \
        --arg status "$status" \
        '{ts: $ts, found: $found, created: $created, status: $status}' \
        >> "$HISTORY_FILE"
}

# ─── Analysis Cycle ────────────────────────────────────────────────────────

run_analysis_cycle() {
    info "Starting analysis cycle..."

    ensure_state_dir
    update_state "status" "analyzing"

    local findings
    findings=$(mktemp "${TMPDIR:-/tmp}/sw-autonomous-findings.XXXXXX")

    # Use Claude to analyze the codebase
    if command -v claude &>/dev/null; then
        info "Running codebase analysis with Claude..."

        claude -p 'You are Shipwright'"'"'s autonomous PM. Analyze this repository for:
1. Bugs & Issues: Missing error handling, potential crashes, edge cases
2. Performance: Bottlenecks, n+1 queries, memory leaks, unnecessary work
3. Missing Tests: Uncovered code paths, critical scenarios
4. Stale Documentation: Outdated guides, missing API docs
5. Security: Input validation, injection risks, credential leaks
6. Code Quality: Dead code, refactoring opportunities, tech debt
7. Self-Improvement: How Shipwright itself could be enhanced

For each finding, output JSON with fields: title, description, priority (critical/high/medium/low), effort (S/M/L), labels (array), category.
Output ONLY a JSON array, no other text.' --max-turns 3 > "$findings" 2>/dev/null || true

    else
        warn "Claude CLI not available, using static heuristics..."

        # Static heuristics for analysis
        {
            local has_tests=$(find . -type f -name "*test*" -o -name "*spec*" | wc -l || echo "0")
            local shell_scripts=$(find scripts -type f -name "*.sh" | wc -l || echo "0")

            jq -n \
                --argjson test_count "$has_tests" \
                --argjson script_count "$shell_scripts" \
                '[
                    {
                        title: "Add comprehensive test coverage for critical paths",
                        description: "Several scripts lack unit test coverage",
                        priority: "high",
                        effort: "L",
                        labels: ["test", "quality"],
                        category: "test"
                    },
                    {
                        title: "Simplify error handling in daemon.sh",
                        description: "Daemon error handling could be more robust",
                        priority: "medium",
                        effort: "M",
                        labels: ["refactor", "self-improvement"],
                        category: "self-improvement"
                    }
                ]'
        } > "$findings"
    fi

    cat "$findings"
}

# ─── Issue Creation ────────────────────────────────────────────────────────

create_issue_from_finding() {
    local title="$1"
    local description="$2"
    local priority="$3"
    local effort="$4"
    local labels="$5"

    if [[ "$NO_GITHUB" == "true" ]]; then
        warn "GitHub disabled, skipping issue creation for: $title"
        return 1
    fi

    # Check if issue already exists
    local existing
    existing=$(gh issue list --search "$title" --json number -q 'length' 2>/dev/null || echo "0")
    if [[ "${existing:-0}" -gt 0 ]]; then
        warn "Issue already exists: $title"
        return 1
    fi

    # Add shipwright label to auto-feed daemon
    local all_labels="shipwright,$labels"

    # Create GitHub issue; capture URL and parse issue number
    local create_out
    create_out=$(gh issue create \
        --title "$title" \
        --body "$description

---
**Metadata:**
- Priority: \`${priority}\`
- Effort: \`${effort}\`
- Created: \`$(now_iso)\`
- By: Autonomous loop (sw-autonomous.sh)
" \
        --label "$all_labels" 2>/dev/null) || {
        warn "Failed to create issue: $title"
        return 1
    }
    success "Created issue: $title"
    local issue_num
    issue_num=$(echo "$create_out" | sed -n 's|.*/issues/\([0-9]*\)|\1|p')
    [[ -n "$issue_num" ]] && echo "$issue_num"
    return 0
}

# ─── Issue Processing from Analysis ────────────────────────────────────────
# Trigger pipeline for a finding issue (daemon will also pick it up; this runs immediately)
trigger_pipeline_for_finding() {
    local issue_num="$1"
    local title="$2"
    if [[ -z "$issue_num" || ! "$issue_num" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    if [[ ! -x "$SCRIPT_DIR/sw-pipeline.sh" ]]; then
        return 0
    fi

    # Use recruit for model/team selection when available
    local -a recruit_args=()
    if [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
        local recruit_match
        recruit_match=$(bash "$SCRIPT_DIR/sw-recruit.sh" match --json "$title" 2>/dev/null) || true
        if [[ -n "$recruit_match" ]]; then
            local rec_model
            rec_model=$(echo "$recruit_match" | jq -r '.model // ""' 2>/dev/null) || true
            [[ -n "$rec_model" && "$rec_model" != "null" ]] && recruit_args=(--model "$rec_model")
            emit_event "autonomous.recruit_match" "issue=$issue_num" "role=$(echo "$recruit_match" | jq -r '.primary_role // ""' 2>/dev/null)" "model=$rec_model"
        fi
    fi

    info "Triggering pipeline for finding issue #${issue_num}: $title"
    (cd "$REPO_DIR" && export REPO_DIR SCRIPT_DIR && bash "$SCRIPT_DIR/sw-pipeline.sh" start --issue "$issue_num" "${recruit_args[@]}" 2>/dev/null) &
    emit_event "autonomous.pipeline_triggered" "issue=$issue_num" "title=$title"
}

# Record finding outcome for learning (which findings led to successful fixes)
record_finding_pending() {
    local issue_num="$1"
    local finding_title="$2"
    ensure_state_dir
    local state_file="${STATE_DIR}/state.json"
    local pending_file="${STATE_DIR}/pending_findings.jsonl"
    [[ ! -f "$pending_file" ]] && touch "$pending_file"
    echo "{\"issue_number\":$issue_num,\"finding_title\":\"${finding_title//\"/\\\"}\",\"created_at\":\"$(now_iso)\",\"outcome\":\"pending\"}" >> "$pending_file"
}

# Update outcomes for pending findings (called at start of each cycle)
update_finding_outcomes() {
    [[ "$NO_GITHUB" == "true" ]] && return 0
    local pending_file="${STATE_DIR}/pending_findings.jsonl"
    [[ ! -f "$pending_file" ]] && return 0
    local updated_file
    updated_file=$(mktemp "${TMPDIR:-/tmp}/sw-autonomous-pending.XXXXXX")
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local issue_num outcome
        issue_num=$(echo "$line" | jq -r '.issue_number // empty')
        outcome=$(echo "$line" | jq -r '.outcome // "pending"')
        if [[ "$outcome" != "pending" || -z "$issue_num" ]]; then
            echo "$line" >> "$updated_file"
            continue
        fi
        local state
        state=$(gh issue view "$issue_num" --json state 2>/dev/null | jq -r '.state // "OPEN"') || state="OPEN"
        if [[ "$state" != "CLOSED" ]]; then
            echo "$line" >> "$updated_file"
            continue
        fi
        local merged=""
        local merged_pipeline merged_daemon
        merged_pipeline=$(gh pr list --head "pipeline/issue-${issue_num}" --json state -q '.[0].state' 2>/dev/null || echo "")
        merged_daemon=$(gh pr list --head "daemon/issue-${issue_num}" --json state -q '.[0].state' 2>/dev/null || echo "")
        [[ "$merged_pipeline" == "MERGED" || "$merged_daemon" == "MERGED" ]] && merged="MERGED"
        if [[ "$merged" == "MERGED" ]]; then
            outcome="success"
            increment_counter "issues_completed"
            emit_event "autonomous.finding_success" "issue=$issue_num"
        else
            outcome="failure"
            emit_event "autonomous.finding_failure" "issue=$issue_num"
        fi
        echo "$line" | jq --arg o "$outcome" '.outcome = $o' >> "$updated_file"
    done < "$pending_file"
    mv "$updated_file" "$pending_file"
}

process_findings() {
    local findings_file="$1"
    local max_per_cycle
    max_per_cycle=$(get_config "max_issues_per_cycle" "5")

    info "Processing findings (max ${max_per_cycle} per cycle)..."

    local created=0
    local total=0

    # Parse findings and create issues; trigger pipeline for each; record for outcome tracking
    while IFS= read -r finding; do
        [[ -z "$finding" ]] && continue

        total=$((total + 1))
        [[ "$created" -ge "$max_per_cycle" ]] && break

        local title description priority effort labels category
        title=$(echo "$finding" | jq -r '.title // ""')
        description=$(echo "$finding" | jq -r '.description // ""')
        priority=$(echo "$finding" | jq -r '.priority // "medium"')
        effort=$(echo "$finding" | jq -r '.effort // "M"')
        labels=$(echo "$finding" | jq -r '.labels | join(",") // ""')
        category=$(echo "$finding" | jq -r '.category // ""')

        if [[ -z "$title" ]]; then
            continue
        fi

        # Add category to labels if not present
        if [[ "$labels" != *"$category"* ]]; then
            labels="${category}${labels:+,$labels}"
        fi

        # Use recruit to decompose complex findings and assess team needs
        if [[ -x "$SCRIPT_DIR/sw-recruit.sh" && "$effort" == "L" ]]; then
            local team_json
            team_json=$(bash "$SCRIPT_DIR/sw-recruit.sh" team --json "$title" 2>/dev/null) || true
            if [[ -n "$team_json" ]]; then
                local team_size
                team_size=$(echo "$team_json" | jq -r '.agents // 0' 2>/dev/null) || true
                [[ -n "$team_size" && "$team_size" -gt 0 ]] && \
                    description="${description}

---
**Recruit Recommendation:** ${team_size}-agent team ($(echo "$team_json" | jq -r '.team | join(", ")' 2>/dev/null))"
            fi
        fi

        local issue_num
        issue_num=$(create_issue_from_finding "$title" "$description" "$priority" "$effort" "$labels")
        if [[ $? -eq 0 && -n "$issue_num" ]]; then
            created=$((created + 1))
            increment_counter "issues_created"
            emit_event "autonomous.issue_created" "title=$title" "priority=$priority" "effort=$effort" "issue=$issue_num"
            trigger_pipeline_for_finding "$issue_num" "$title"
            record_finding_pending "$issue_num" "$title"
        fi
    done < <(jq -c '.[]' "$findings_file" 2>/dev/null)

    info "Created $created of $total findings as issues (pipelines triggered)"
    echo "$created"
}

# ─── Learning & Feedback ───────────────────────────────────────────────────

analyze_pipeline_result() {
    local pipeline_state="${1:-}"

    if [[ -z "$pipeline_state" || ! -f "$pipeline_state" ]]; then
        warn "Pipeline state file not found: ${pipeline_state:-<empty>}"
        return 1
    fi

    info "Analyzing pipeline result..."

    local status=""
    status=$(sed -n 's/^status: *//p' "$pipeline_state" | head -1)

    local goal=""
    goal=$(sed -n 's/^goal: *"*\([^"]*\)"*/\1/p' "$pipeline_state" | head -1)

    # Capture lessons learned
    if [[ "$status" == "complete" || "$status" == "success" ]]; then
        success "Pipeline completed successfully: $goal"
        increment_counter "pipelines_succeeded"
        update_state "consecutive_failures" "0"
        emit_event "autonomous.pipeline_success" "goal=$goal"
        return 0
    else
        warn "Pipeline failed: $goal (status: $status)"
        increment_counter "pipelines_failed"
        local failures
        failures=$(read_state | jq '.consecutive_failures // 0')
        update_state "consecutive_failures" "$((failures + 1))"
        emit_event "autonomous.pipeline_failure" "goal=$goal" "status=$status"
        return 1
    fi
}

# ─── Status & Metrics ───────────────────────────────────────────────────────

show_status() {
    ensure_state_dir

    local state
    state=$(read_state)

    local status cycles issues_created issues_completed succeeded failed
    status=$(echo "$state" | jq -r '.status')
    cycles=$(echo "$state" | jq -r '.cycles_completed')
    issues_created=$(echo "$state" | jq -r '.issues_created')
    issues_completed=$(echo "$state" | jq -r '.issues_completed')
    succeeded=$(echo "$state" | jq -r '.pipelines_succeeded')
    failed=$(echo "$state" | jq -r '.pipelines_failed')

    local cycle_interval
    cycle_interval=$(get_config "cycle_interval_minutes" "60")

    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Autonomous Loop Status${RESET}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${BOLD}Status${RESET}                ${CYAN}${status}${RESET}"
    echo -e "  ${BOLD}Cycles${RESET}                ${GREEN}${cycles}${RESET}"
    echo -e "  ${BOLD}Issues Created${RESET}        ${CYAN}${issues_created}${RESET}"
    echo -e "  ${BOLD}Issues Completed${RESET}      ${GREEN}${issues_completed}${RESET}"
    echo -e "  ${BOLD}Pipelines Succeeded${RESET}   ${GREEN}${succeeded}${RESET}"
    echo -e "  ${BOLD}Pipelines Failed${RESET}      ${RED}${failed}${RESET}"
    echo -e "  ${BOLD}Cycle Interval${RESET}       ${YELLOW}${cycle_interval}${RESET} minutes"
    echo ""
}

show_history() {
    ensure_state_dir

    if [[ ! -f "$HISTORY_FILE" ]]; then
        warn "No cycle history recorded yet"
        return 0
    fi

    echo ""
    echo -e "${CYAN}${BOLD}Recent Cycles${RESET}"
    echo ""

    tail -20 "$HISTORY_FILE" | while read -r line; do
        local ts status created
        ts=$(echo "$line" | jq -r '.ts')
        status=$(echo "$line" | jq -r '.status')
        created=$(echo "$line" | jq -r '.created')

        local status_color="$GREEN"
        [[ "$status" != "success" ]] && status_color="$RED"

        echo -e "  ${ts}  Status: ${status_color}${status}${RESET}  Created: ${CYAN}${created}${RESET}"
    done
}

# ─── Loop Control ──────────────────────────────────────────────────────────

# Scheduler: run cycles at interval (real scheduler instead of manual cycle only)
run_scheduler() {
    ensure_state_dir
    init_state
    update_state "status" "running"
    info "Autonomous scheduler started (cycle every $(get_config "cycle_interval_minutes" "60") minutes)"
    emit_event "autonomous.scheduler_started"

    while true; do
        local status
        status=$(read_state | jq -r '.status // "running"')
        if [[ "$status" != "running" ]]; then
            info "Status is ${status} — exiting scheduler"
            break
        fi
        run_single_cycle || true
        local interval_mins
        interval_mins=$(get_config "cycle_interval_minutes" "60")
        info "Next cycle in ${interval_mins} minutes"
        sleep $((interval_mins * 60))
    done
}

start_loop() {
    ensure_state_dir
    init_state
    update_state "status" "running"

    info "Starting autonomous loop..."
    success "Loop is now running in background"
    success "Run '${CYAN}sw autonomous status${RESET}' to check progress"

    emit_event "autonomous.started"
}

stop_loop() {
    ensure_state_dir
    update_state "status" "stopped"
    success "Autonomous loop stopped"
    emit_event "autonomous.stopped"
}

pause_loop() {
    ensure_state_dir
    update_state "status" "paused"
    update_state "paused_at" "$(now_iso)"
    success "Autonomous loop paused"
    emit_event "autonomous.paused"
}

resume_loop() {
    ensure_state_dir
    update_state "status" "running"
    update_state "paused_at" "null"
    success "Autonomous loop resumed"
    emit_event "autonomous.resumed"
}

run_single_cycle() {
    ensure_state_dir
    update_state "status" "analyzing"

    # Update outcomes for pending findings (which led to successful fixes)
    update_finding_outcomes

    info "Running single analysis cycle..."

    # Step 1: Analysis
    local findings
    findings=$(mktemp "${TMPDIR:-/tmp}/sw-autonomous-findings.XXXXXX")
    run_analysis_cycle > "$findings" 2>&1 || {
        warn "Analysis failed"
        rm -f "$findings"
        return 1
    }

    # Step 2: Create issues
    local created
    created=$(process_findings "$findings")

    # Step 3: Record cycle
    local total_findings
    total_findings=$(jq -s 'length' "$findings" 2>/dev/null || echo "0")
    record_cycle "$total_findings" "$created" "success"

    increment_counter "cycles_completed"
    update_state "status" "idle"
    update_state "last_cycle" "$(now_iso)"

    success "Cycle complete. Created $created issues"
    rm -f "$findings"
}

show_config() {
    ensure_state_dir
    echo ""
    echo -e "${CYAN}${BOLD}Autonomous Loop Configuration${RESET}"
    echo ""
    cat "$CONFIG_FILE" | jq '.' 2>/dev/null || cat "$CONFIG_FILE"
    echo ""
}

set_cycle_config() {
    local key="$1"
    local value="$2"
    ensure_state_dir

    case "$key" in
        interval|cycle-interval)
            set_config "cycle_interval_minutes" "$value"
            success "Cycle interval set to ${CYAN}${value}${RESET} minutes"
            ;;
        max-issues)
            set_config "max_issues_per_cycle" "$value"
            success "Max issues per cycle set to ${CYAN}${value}${RESET}"
            ;;
        max-pipelines|max-concurrent)
            set_config "max_concurrent_pipelines" "$value"
            success "Max concurrent pipelines set to ${CYAN}${value}${RESET}"
            ;;
        approval|human-approval)
            local bool_val="true"
            [[ "$value" == "false" || "$value" == "0" || "$value" == "no" ]] && bool_val="false"
            set_config "enable_human_approval" "$bool_val"
            success "Human approval set to ${CYAN}${bool_val}${RESET}"
            ;;
        rollback)
            local bool_val="true"
            [[ "$value" == "false" || "$value" == "0" || "$value" == "no" ]] && bool_val="false"
            set_config "rollback_on_failures" "$bool_val"
            success "Rollback on failures set to ${CYAN}${bool_val}${RESET}"
            ;;
        *)
            error "Unknown config key: $key"
            return 1
            ;;
    esac
}

# ─── Help ──────────────────────────────────────────────────────────────────

show_help() {
    cat << 'EOF'

USAGE
  sw autonomous <command> [options]

COMMANDS
  start                     Set status to running (use with external scheduler)
  run                       Run scheduler: cycle every N minutes until stopped
  stop                      Stop the loop gracefully
  pause                     Pause without losing state
  resume                    Resume from pause
  cycle                     Run one analysis cycle manually (create issues + trigger pipelines)
  status                    Show loop status, recent cycles, issue creation stats
  config [show|set]         Show or set configuration
  history                   Show past cycles and their outcomes
  help                      Show this help message

OPTIONS (for config)
  set interval <minutes>    Set cycle interval (default 60)
  set max-issues <num>      Set max issues per cycle (default 5)
  set max-pipelines <num>   Set max concurrent pipelines (default 2)
  set approval <bool>       Enable human approval mode (default false)
  set rollback <bool>       Rollback on failures (default true)

EXAMPLES
  sw autonomous start                        # Start the loop
  sw autonomous cycle                        # Run one cycle immediately
  sw autonomous config set interval 30       # Change cycle to 30 minutes
  sw autonomous status                       # Check progress
  sw autonomous history                      # View past cycles

EOF
}

# ─── Main ──────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        start)
            start_loop
            ;;
        run)
            run_scheduler
            ;;
        stop)
            stop_loop
            ;;
        pause)
            pause_loop
            ;;
        resume)
            resume_loop
            ;;
        cycle)
            run_single_cycle
            ;;
        status)
            show_status
            show_history
            ;;
        config)
            local subcmd="${1:-show}"
            shift 2>/dev/null || true
            case "$subcmd" in
                show)
                    show_config
                    ;;
                set)
                    set_cycle_config "$@"
                    ;;
                *)
                    error "Unknown config subcommand: $subcmd"
                    show_help
                    exit 1
                    ;;
            esac
            ;;
        history)
            show_history
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

# ─── Source Guard ───────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
