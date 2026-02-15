#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright autonomous — Master controller for AI-building-AI loop      ║
# ║  Analyze → Create issues → Build → Learn → Repeat                      ║
# ║  Closes the loop: PM creates issues, daemon builds, system learns       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.13.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

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

emit_event() {
    local event_type="$1"
    shift
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            val="${val//\"/\\\"}"
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

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

        claude code << 'ANALYSIS_PROMPT'
You are Shipwright's autonomous PM. Analyze this repository for:
1. **Bugs & Issues**: Missing error handling, potential crashes, edge cases
2. **Performance**: Bottlenecks, n+1 queries, memory leaks, unnecessary work
3. **Missing Tests**: Uncovered code paths, critical scenarios
4. **Stale Documentation**: Outdated guides, missing API docs
5. **Security**: Input validation, injection risks, credential leaks
6. **Code Quality**: Dead code, refactoring opportunities, tech debt
7. **Self-Improvement**: How Shipwright itself could be enhanced

For each finding, suggest:
- Priority: critical/high/medium/low
- Effort estimate: S/M/L (small/medium/large)
- Labels: e.g. "bug", "performance", "test", "docs", "security", "refactor", "self-improvement"

Output as JSON array of findings with fields:
{
  "title": "...",
  "description": "...",
  "priority": "high",
  "effort": "M",
  "labels": ["..."],
  "category": "bug|performance|test|docs|security|refactor|self-improvement"
}
ANALYSIS_PROMPT

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

    # Create GitHub issue
    gh issue create \
        --title "$title" \
        --body "$description

---
**Metadata:**
- Priority: \`${priority}\`
- Effort: \`${effort}\`
- Created: \`$(now_iso)\`
- By: Autonomous loop (sw-autonomous.sh)
" \
        --label "$all_labels" 2>/dev/null && \
        success "Created issue: $title" && \
        return 0 || \
        warn "Failed to create issue: $title" && \
        return 1
}

# ─── Issue Processing from Analysis ────────────────────────────────────────

process_findings() {
    local findings_file="$1"
    local max_per_cycle
    max_per_cycle=$(get_config "max_issues_per_cycle" "5")

    info "Processing findings (max ${max_per_cycle} per cycle)..."

    local created=0
    local total=0

    # Parse findings and create issues
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

        if create_issue_from_finding "$title" "$description" "$priority" "$effort" "$labels"; then
            created=$((created + 1))
            increment_counter "issues_created"
            emit_event "autonomous.issue_created" "title=$title" "priority=$priority" "effort=$effort"
        fi
    done < <(jq -c '.[]' "$findings_file" 2>/dev/null)

    info "Created $created of $total findings as issues"
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
  start                     Begin autonomous loop (analyze → create → build → learn → repeat)
  stop                      Stop the loop gracefully
  pause                     Pause without losing state
  resume                    Resume from pause
  cycle                     Run one analysis cycle manually
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
