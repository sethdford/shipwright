#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright replay — Pipeline run replay, timeline viewing, narratives   ║
# ║  DVR for pipeline execution: list, show, narrative, diff, export, compare ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

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

# Check if jq is available
check_jq() {
    if ! command -v jq &>/dev/null; then
        error "jq is required. Install with: brew install jq"
        exit 1
    fi
}

# Format duration in seconds to human readable
format_duration() {
    local seconds=$1
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}s"
    elif [[ $seconds -lt 3600 ]]; then
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m${secs}s"
    else
        local hours=$((seconds / 3600))
        local mins=$(((seconds % 3600) / 60))
        echo "${hours}h${mins}m"
    fi
}

# Status color coding
color_status() {
    local status="$1"
    case "$status" in
        success)  echo -e "${GREEN}${BOLD}✓${RESET} $status" ;;
        failure)  echo -e "${RED}${BOLD}✗${RESET} $status" ;;
        retry)    echo -e "${YELLOW}${BOLD}⚠${RESET} $status" ;;
        in_progress) echo -e "${CYAN}${BOLD}→${RESET} $status" ;;
        *)        echo "$status" ;;
    esac
}

# ─── List subcommand ───────────────────────────────────────────────────────

cmd_list() {
    check_jq

    if [[ ! -f "$EVENTS_FILE" ]]; then
        warn "No pipeline runs recorded yet (events file not found)"
        exit 0
    fi

    info "Pipeline runs (${DIM}from $EVENTS_FILE${RESET})"
    echo ""

    # Extract unique pipeline runs, sorted by start time
    # Use --slurpfile to handle parsing errors gracefully
    jq -r 'select(.type == "pipeline.started") | [.ts, .issue, .pipeline, .model, .goal] | @tsv' "$EVENTS_FILE" 2>/dev/null | \
    sort -r | \
    while IFS=$'\t' read -r ts issue pipeline model goal; do
        # Find corresponding completion event
        local completion
        completion=$(jq -r "select(.type == \"pipeline.completed\" and .issue == $issue) | .result, .duration_s" "$EVENTS_FILE" 2>/dev/null | head -2)

        if [[ -n "$completion" ]]; then
            local result duration
            result=$(echo "$completion" | head -1)
            duration=$(echo "$completion" | tail -1)
            duration="${duration:-0}"

            # Format date
            local date time
            date=$(echo "$ts" | cut -d'T' -f1)
            time=$(echo "$ts" | cut -d'T' -f2 | cut -d'Z' -f1)

            # Truncate goal to 40 chars
            local goal_trunc="${goal:0:40}"
            [[ ${#goal} -gt 40 ]] && goal_trunc="${goal_trunc}…"

            printf "  ${CYAN}#%-5s${RESET}  ${BOLD}%s${RESET}  %s  %s  ${DIM}%s${RESET}  %s\n" \
                "$issue" "$date" "$time" "$(color_status "${result:-success}")" "$(format_duration "$duration")" "$goal_trunc"
        fi
    done

    echo ""
    success "Use 'shipwright replay show <issue>' to see details"
}

# ─── Show subcommand ───────────────────────────────────────────────────────

cmd_show() {
    local issue="${1:-}"
    check_jq

    if [[ -z "$issue" ]]; then
        error "Usage: shipwright replay show <issue>"
        exit 1
    fi

    if [[ ! -f "$EVENTS_FILE" ]]; then
        error "No events recorded yet"
        exit 1
    fi

    # Find pipeline run for this issue
    local pipeline_start
    pipeline_start=$(jq -r "select(.type == \"pipeline.started\" and .issue == $issue) | [.ts, .pipeline, .model, .goal] | @tsv" "$EVENTS_FILE" 2>/dev/null | head -1)

    if [[ -z "$pipeline_start" ]]; then
        error "No pipeline run found for issue #$issue"
        exit 1
    fi

    local start_ts pipeline_type model goal
    start_ts=$(echo "$pipeline_start" | cut -f1)
    pipeline_type=$(echo "$pipeline_start" | cut -f2)
    model=$(echo "$pipeline_start" | cut -f3)
    goal=$(echo "$pipeline_start" | cut -f4)

    info "Pipeline Timeline for Issue #$issue"
    echo ""
    echo -e "  ${BOLD}Pipeline Type:${RESET} $pipeline_type"
    echo -e "  ${BOLD}Model:${RESET} $model"
    [[ -n "$goal" ]] && echo -e "  ${BOLD}Goal:${RESET} $goal"
    echo ""

    # Find all stage events for this issue
    echo -e "  ${BOLD}Stages:${RESET}"
    jq -r "select(.issue == $issue and .type == \"stage.completed\") | [.ts, .stage, .duration_s // 0, .result // \"success\"] | @tsv" "$EVENTS_FILE" 2>/dev/null | \
    while IFS=$'\t' read -r ts stage duration result; do
        local status_icon
        case "$result" in
            success)  status_icon="${GREEN}${BOLD}✓${RESET}" ;;
            failure)  status_icon="${RED}${BOLD}✗${RESET}" ;;
            retry)    status_icon="${YELLOW}${BOLD}⚠${RESET}" ;;
            *)        status_icon="•" ;;
        esac

        local time
        time=$(echo "$ts" | cut -d'T' -f2 | cut -d'Z' -f1)

        printf "    %s  ${CYAN}%-20s${RESET}  ${DIM}%s${RESET}  %s\n" \
            "$status_icon" "$stage" "$(format_duration "$duration")" "$time"
    done

    # Find pipeline completion
    local completion
    completion=$(jq -r "select(.type == \"pipeline.completed\" and .issue == $issue) | [.result // \"unknown\", .duration_s // 0, .input_tokens // 0, .output_tokens // 0] | @tsv" "$EVENTS_FILE" 2>/dev/null | head -1)

    if [[ -n "$completion" ]]; then
        echo ""
        local result duration input_tokens output_tokens
        result=$(echo "$completion" | cut -f1)
        duration=$(echo "$completion" | cut -f2)
        input_tokens=$(echo "$completion" | cut -f3)
        output_tokens=$(echo "$completion" | cut -f4)

        echo -e "  ${BOLD}Result:${RESET} $(color_status "$result")"
        echo -e "  ${BOLD}Duration:${RESET} $(format_duration "$duration")"
        echo -e "  ${BOLD}Tokens:${RESET} in=$input_tokens, out=$output_tokens"
    fi

    echo ""
}

# ─── Narrative subcommand ──────────────────────────────────────────────────

cmd_narrative() {
    local issue="${1:-}"
    check_jq

    if [[ -z "$issue" ]]; then
        error "Usage: shipwright replay narrative <issue>"
        exit 1
    fi

    if [[ ! -f "$EVENTS_FILE" ]]; then
        error "No events recorded yet"
        exit 1
    fi

    local pipeline_start
    pipeline_start=$(jq -r "select(.type == \"pipeline.started\" and .issue == $issue) | [.ts, .goal // \"\", .pipeline // \"standard\"] | @tsv" "$EVENTS_FILE" 2>/dev/null | head -1)

    if [[ -z "$pipeline_start" ]]; then
        error "No pipeline run found for issue #$issue"
        exit 1
    fi

    local start_ts goal pipeline_type
    start_ts=$(echo "$pipeline_start" | cut -f1)
    goal=$(echo "$pipeline_start" | cut -f2)
    pipeline_type=$(echo "$pipeline_start" | cut -f3)

    # Get pipeline completion
    local completion
    completion=$(jq -r "select(.type == \"pipeline.completed\" and .issue == $issue) | [.result // \"unknown\", .duration_s // 0, .input_tokens // 0, .output_tokens // 0] | @tsv" "$EVENTS_FILE" 2>/dev/null | head -1)

    local result duration input_tokens output_tokens
    if [[ -n "$completion" ]]; then
        result=$(echo "$completion" | cut -f1)
        duration=$(echo "$completion" | cut -f2)
        input_tokens=$(echo "$completion" | cut -f3)
        output_tokens=$(echo "$completion" | cut -f4)
    else
        result="in_progress"
        duration="0"
        input_tokens="0"
        output_tokens="0"
    fi

    # Count stages
    local stage_count
    stage_count=$(jq -r "select(.issue == $issue and .type == \"stage.completed\") | .stage" "$EVENTS_FILE" 2>/dev/null | wc -l)

    # Build narrative
    info "Pipeline Narrative"
    echo ""
    echo "Pipeline processed issue #$issue"
    [[ -n "$goal" ]] && echo "Goal: $goal"
    echo "in ${duration}s across $stage_count stages."
    echo ""
    echo "Pipeline Type: $pipeline_type"
    echo "Result: $(color_status "$result")"
    echo "Tokens Used: $input_tokens input, $output_tokens output"
    echo ""

    # Key events
    local retry_count build_iterations test_failures
    retry_count=$(jq -r "select(.issue == $issue and .type == \"stage.completed\" and .result == \"retry\") | .stage" "$EVENTS_FILE" 2>/dev/null | wc -l)
    build_iterations=$(jq -r "select(.issue == $issue and .type == \"build.iteration\") | .iteration" "$EVENTS_FILE" 2>/dev/null | tail -1)
    test_failures=$(jq -r "select(.issue == $issue and .type == \"test.failed\") | .test" "$EVENTS_FILE" 2>/dev/null | wc -l)

    echo "Key Events:"
    [[ $retry_count -gt 0 ]] && echo "  • $retry_count stage retries"
    [[ -n "$build_iterations" && "$build_iterations" != "null" ]] && echo "  • $build_iterations build iterations"
    [[ $test_failures -gt 0 ]] && echo "  • $test_failures test failures encountered"

    echo ""
}

# ─── Diff subcommand ──────────────────────────────────────────────────────

cmd_diff() {
    local issue="${1:-}"
    check_jq

    if [[ -z "$issue" ]]; then
        error "Usage: shipwright replay diff <issue>"
        exit 1
    fi

    if ! command -v git &>/dev/null; then
        error "git is required for diff subcommand"
        exit 1
    fi

    if [[ ! -f "$EVENTS_FILE" ]]; then
        error "No events recorded yet"
        exit 1
    fi

    # Check if issue was processed
    local found
    found=$(jq -r "select(.issue == $issue and .type == \"pipeline.completed\") | .issue" "$EVENTS_FILE" | head -1)

    if [[ -z "$found" ]]; then
        error "No pipeline run found for issue #$issue"
        exit 1
    fi

    info "Git commits for issue #$issue"
    echo ""

    # Try to find commits with issue reference
    git log --all --grep="#$issue" --oneline || true

    # Also try to find by branch name pattern
    local branch_pattern="issue-${issue}"
    if git show-ref --verify "refs/heads/$branch_pattern" &>/dev/null; then
        echo ""
        info "Commits on branch '$branch_pattern':"
        git log "$branch_pattern" --oneline || true
    fi

    echo ""
}

# ─── Export subcommand ──────────────────────────────────────────────────────

cmd_export() {
    local issue="${1:-}"
    check_jq

    if [[ -z "$issue" ]]; then
        error "Usage: shipwright replay export <issue>"
        exit 1
    fi

    if [[ ! -f "$EVENTS_FILE" ]]; then
        error "No events recorded yet"
        exit 1
    fi

    local pipeline_start
    pipeline_start=$(jq -r "select(.type == \"pipeline.started\" and .issue == $issue) | [.ts, .goal // \"\", .pipeline // \"standard\"] | @tsv" "$EVENTS_FILE" 2>/dev/null | head -1)

    if [[ -z "$pipeline_start" ]]; then
        error "No pipeline run found for issue #$issue"
        exit 1
    fi

    local start_ts goal pipeline_type
    start_ts=$(echo "$pipeline_start" | cut -f1)
    goal=$(echo "$pipeline_start" | cut -f2)
    pipeline_type=$(echo "$pipeline_start" | cut -f3)

    local completion
    completion=$(jq -r "select(.type == \"pipeline.completed\" and .issue == $issue) | [.result // \"unknown\", .duration_s // 0] | @tsv" "$EVENTS_FILE" 2>/dev/null | head -1)

    local result duration
    if [[ -n "$completion" ]]; then
        result=$(echo "$completion" | cut -f1)
        duration=$(echo "$completion" | cut -f2)
    else
        result="in_progress"
        duration="0"
    fi

    # Output markdown report
    cat << EOF
# Pipeline Report: Issue #$issue

**Date:** $(echo "$start_ts" | cut -d'T' -f1)
**Type:** $pipeline_type
**Result:** $result
**Duration:** $(format_duration "$duration")

## Goal
$goal

## Timeline

| Stage | Duration | Status |
|-------|----------|--------|
EOF

    # Add stage rows
    jq -r "select(.issue == $issue and .type == \"stage.completed\") | [.stage, .duration_s // 0, .result // \"success\"] | @tsv" "$EVENTS_FILE" 2>/dev/null | \
    while IFS=$'\t' read -r stage duration result; do
        printf "| %s | %s | %s |\n" "$stage" "$(format_duration "$duration")" "$result"
    done

    cat << EOF

## Summary

- **Issue Number:** #$issue
- **Pipeline Type:** $pipeline_type
- **Overall Result:** $result
- **Total Duration:** $(format_duration "$duration")

## Events

$(jq -r "select(.issue == $issue) | [.ts, .type] | @tsv" "$EVENTS_FILE" 2>/dev/null | awk '{print "- " $1 " — " $2}')

EOF

    success "Markdown report generated above"
}

# ─── Compare subcommand ───────────────────────────────────────────────────

cmd_compare() {
    local issue1="${1:-}" issue2="${2:-}"
    check_jq

    if [[ -z "$issue1" || -z "$issue2" ]]; then
        error "Usage: shipwright replay compare <issue1> <issue2>"
        exit 1
    fi

    if [[ ! -f "$EVENTS_FILE" ]]; then
        error "No events recorded yet"
        exit 1
    fi

    info "Comparing pipeline runs: #$issue1 vs #$issue2"
    echo ""

    # Get both runs
    local run1 run2
    run1=$(jq -r "select(.type == \"pipeline.started\" and .issue == $issue1) | [.goal // \"\", .pipeline, .model] | @tsv" "$EVENTS_FILE" 2>/dev/null | head -1)
    run2=$(jq -r "select(.type == \"pipeline.started\" and .issue == $issue2) | [.goal // \"\", .pipeline, .model] | @tsv" "$EVENTS_FILE" 2>/dev/null | head -1)

    if [[ -z "$run1" || -z "$run2" ]]; then
        error "Could not find both pipeline runs"
        exit 1
    fi

    # Extract details
    local goal1 type1 model1
    goal1=$(echo "$run1" | cut -f1)
    type1=$(echo "$run1" | cut -f2)
    model1=$(echo "$run1" | cut -f3)

    local goal2 type2 model2
    goal2=$(echo "$run2" | cut -f1)
    type2=$(echo "$run2" | cut -f2)
    model2=$(echo "$run2" | cut -f3)

    # Get completions
    local comp1 comp2
    comp1=$(jq -r "select(.type == \"pipeline.completed\" and .issue == $issue1) | [.result // \"unknown\", .duration_s // 0] | @tsv" "$EVENTS_FILE" 2>/dev/null | head -1)
    comp2=$(jq -r "select(.type == \"pipeline.completed\" and .issue == $issue2) | [.result // \"unknown\", .duration_s // 0] | @tsv" "$EVENTS_FILE" 2>/dev/null | head -1)

    local result1 duration1 result2 duration2
    result1=$(echo "$comp1" | cut -f1)
    duration1=$(echo "$comp1" | cut -f2)
    result2=$(echo "$comp2" | cut -f1)
    duration2=$(echo "$comp2" | cut -f2)

    # Comparison table
    printf "%-20s | %-15s | %-15s\n" "Metric" "#$issue1" "#$issue2"
    printf "%-20s | %-15s | %-15s\n" "---" "---" "---"
    printf "%-20s | %-15s | %-15s\n" "Type" "$type1" "$type2"
    printf "%-20s | %-15s | %-15s\n" "Model" "$model1" "$model2"
    printf "%-20s | %-15s | %-15s\n" "Result" "$result1" "$result2"
    printf "%-20s | %-15s | %-15s\n" "Duration" "$(format_duration "$duration1")" "$(format_duration "$duration2")"

    echo ""
}

# ─── Help and main ────────────────────────────────────────────────────────

show_help() {
    cat << EOF
${BOLD}shipwright replay${RESET} — Pipeline DVR: replay, timeline, narrative, and analysis

${BOLD}USAGE${RESET}
  shipwright replay <subcommand> [options]

${BOLD}SUBCOMMANDS${RESET}
  ${CYAN}list${RESET}                    Show all past pipeline runs
  ${CYAN}show${RESET} <issue>            Display timeline for a specific run
  ${CYAN}narrative${RESET} <issue>       Generate AI-readable summary of what happened
  ${CYAN}diff${RESET} <issue>            Show git commits made during pipeline run
  ${CYAN}export${RESET} <issue>          Export run as markdown report
  ${CYAN}compare${RESET} <issue1> <issue2>  Compare two pipeline runs side-by-side
  ${CYAN}help${RESET}                    Show this help message

${BOLD}EXAMPLES${RESET}
  shipwright replay list                             # See all runs
  shipwright replay show 42                          # Timeline for #42
  shipwright replay narrative 42                     # Summary of #42
  shipwright replay diff 42                          # Commits for #42
  shipwright replay export 42                        # Markdown report for #42
  shipwright replay compare 42 43                    # Compare two runs

${DIM}Pipeline events are read from: $EVENTS_FILE${RESET}

EOF
}

# ─── Main entry point ────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        list)       cmd_list "$@" ;;
        show)       cmd_show "$@" ;;
        narrative)  cmd_narrative "$@" ;;
        diff)       cmd_diff "$@" ;;
        export)     cmd_export "$@" ;;
        compare)    cmd_compare "$@" ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown subcommand: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
