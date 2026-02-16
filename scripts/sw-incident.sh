#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright incident — Autonomous Incident Detection & Response               ║
# ║  Detect failures · Triage · Root cause analysis · Auto-remediate      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.0"
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

# ─── State Directories ──────────────────────────────────────────────────────
INCIDENTS_DIR="${HOME}/.shipwright/incidents"
INCIDENT_CONFIG="${INCIDENTS_DIR}/config.json"
MONITOR_PID_FILE="${INCIDENTS_DIR}/monitor.pid"

ensure_incident_dir() {
    mkdir -p "$INCIDENTS_DIR"
    [[ -f "$INCIDENT_CONFIG" ]] || cat > "$INCIDENT_CONFIG" << 'EOF'
{
  "auto_response_enabled": true,
  "p0_auto_hotfix": true,
  "p1_auto_hotfix": false,
  "auto_rollback_enabled": false,
  "notification_channels": ["stdout"],
  "severity_thresholds": {
    "p0_impact_count": 3,
    "p0_deploy_failure": true,
    "p1_test_regression_count": 5,
    "p1_pipeline_failure_rate": 0.3
  },
  "root_cause_patterns": {
    "timeout_keywords": ["timeout", "deadline", "too slow"],
    "memory_keywords": ["out of memory", "OOM", "heap"],
    "dependency_keywords": ["dependency", "import", "require", "not found"],
    "auth_keywords": ["auth", "permission", "forbidden", "401", "403"]
  }
}
EOF
}

# ─── Failure Detection ──────────────────────────────────────────────────────

detect_pipeline_failures() {
    local since="${1:-3600}"  # Last N seconds
    local cutoff_time=$(($(now_epoch) - since))

    [[ ! -f "$EVENTS_FILE" ]] && return 0

    awk -v cutoff="$cutoff_time" -F'"' '
        BEGIN { count=0 }
        /pipeline\.failed|stage\.failed|test\.failed|deploy\.failed/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /ts_epoch/) {
                    ts_epoch_val=$(i+2)
                    gsub(/^[^0-9]*/, "", ts_epoch_val)
                    gsub(/[^0-9].*/, "", ts_epoch_val)
                    if (ts_epoch_val+0 > cutoff) {
                        print $0
                        count++
                    }
                }
            }
        }
        END { exit (count > 0 ? 0 : 1) }
    ' "$EVENTS_FILE"
}

get_recent_failures() {
    local since="${1:-3600}"
    local cutoff_time=$(($(now_epoch) - since))

    [[ ! -f "$EVENTS_FILE" ]] && echo "[]" && return 0

    jq -s --arg cutoff "$cutoff_time" '
        map(
            select(
                (.ts_epoch | tonumber) > ($cutoff | tonumber) and
                (.type | contains("failed") or contains("error") or contains("timeout"))
            ) |
            {
                ts: .ts,
                ts_epoch: .ts_epoch,
                type: .type,
                issue: .issue,
                stage: .stage,
                reason: .reason,
                error: .error
            }
        )
    ' "$EVENTS_FILE" 2>/dev/null || echo "[]"
}

# ─── Severity Classification ───────────────────────────────────────────────

classify_severity() {
    local failure_type="$1"
    local impact_scope="$2"  # Number of affected resources

    case "$failure_type" in
        deploy.failed|pipeline.critical_error)
            echo "P0"
            ;;
        test.regression|stage.failed)
            if [[ "$impact_scope" -gt 5 ]]; then
                echo "P0"
            else
                echo "P1"
            fi
            ;;
        stage.timeout|health_check.failed)
            echo "P2"
            ;;
        *)
            echo "P3"
            ;;
    esac
}

# ─── Root Cause Analysis ───────────────────────────────────────────────────

analyze_root_cause() {
    local failure_log="$1"
    local config="$2"

    local timeout_hits error_hits memory_hits dependency_hits
    timeout_hits=$(echo "$failure_log" | grep -ic "timeout\|deadline\|too slow" || echo "0")
    memory_hits=$(echo "$failure_log" | grep -ic "out of memory\|OOM\|heap" || echo "0")
    dependency_hits=$(echo "$failure_log" | grep -ic "dependency\|import\|require\|not found" || echo "0")
    error_hits=$(echo "$failure_log" | grep -c . || echo "0")

    if [[ "$timeout_hits" -gt 0 ]]; then
        echo "Performance degradation: Timeout detected (${timeout_hits} occurrences)"
    elif [[ "$memory_hits" -gt 0 ]]; then
        echo "Memory pressure: OOM or heap allocation issue (${memory_hits} occurrences)"
    elif [[ "$dependency_hits" -gt 0 ]]; then
        echo "Dependency failure: Missing or incompatible dependency (${dependency_hits} occurrences)"
    else
        echo "Unknown cause: Check logs (${error_hits} error lines)"
    fi
}

# ─── Incident Record Management ─────────────────────────────────────────────

create_incident_record() {
    local incident_id="$1"
    local severity="$2"
    local root_cause="$3"
    local failure_events="$4"

    local incident_file="${INCIDENTS_DIR}/${incident_id}.json"
    local created_at
    created_at="$(now_iso)"

    cat > "$incident_file" << EOF
{
  "id": "$incident_id",
  "created_at": "$created_at",
  "severity": "$severity",
  "status": "open",
  "root_cause": "$root_cause",
  "failure_events": $failure_events,
  "timeline": [],
  "remediation": null,
  "resolved_at": null,
  "mttr_seconds": null,
  "post_mortem_url": null
}
EOF

    emit_event "incident.created" "incident_id=$incident_id" "severity=$severity"
}

# ─── Hotfix Creation ───────────────────────────────────────────────────────

create_hotfix_issue() {
    local incident_id="$1"
    local severity="$2"
    local root_cause="$3"

    if ! command -v gh &>/dev/null; then
        warn "gh CLI not found, skipping GitHub issue creation"
        return 1
    fi

    local title="[HOTFIX] $severity: $root_cause"
    local body="**Incident ID:** $incident_id
**Severity:** $severity
**Root Cause:** $root_cause

## Timeline
See incident details: \`shipwright incident show $incident_id\`

## Automated Detection
This issue was automatically created by the incident commander.
"

    # shipwright label so daemon picks up; hotfix for routing
    local issue_url
    issue_url=$(gh issue create --title "$title" --body "$body" --label "hotfix,shipwright" 2>/dev/null || echo "")

    if [[ -n "$issue_url" ]]; then
        success "Created hotfix issue: $issue_url"
        local issue_num
        issue_num=$(echo "$issue_url" | sed -n 's|.*/issues/\([0-9]*\)|\1|p')
        [[ -n "$issue_num" ]] && echo "$issue_num"
        return 0
    fi

    warn "Failed to create GitHub issue"
    return 1
}

# Trigger pipeline for P0/P1 hotfix issue (auto-remediation)
trigger_pipeline_for_incident() {
    local issue_num="$1"
    local incident_id="$2"
    if [[ -z "$issue_num" || ! "$issue_num" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    if [[ ! -x "$SCRIPT_DIR/sw-pipeline.sh" ]]; then
        return 0
    fi
    info "Auto-triggering pipeline for P0/P1 hotfix issue #${issue_num} (incident: $incident_id)"
    (cd "$REPO_DIR" && export REPO_DIR SCRIPT_DIR && bash "$SCRIPT_DIR/sw-pipeline.sh" start --issue "$issue_num" --template hotfix 2>/dev/null) &
    emit_event "incident.pipeline_triggered" "incident_id=$incident_id" "issue=$issue_num"
}

# Execute rollback when auto_rollback_enabled (wire to sw-feedback / sw-github-deploy)
trigger_rollback_for_incident() {
    local incident_id="$1"
    local reason="${2:-P0/P1 incident}"
    if [[ ! -x "$SCRIPT_DIR/sw-feedback.sh" ]]; then
        return 0
    fi
    info "Auto-rollback triggered for incident $incident_id: $reason"
    (cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-feedback.sh" rollback production "$reason" 2>/dev/null) || true
    emit_event "incident.rollback_triggered" "incident_id=$incident_id" "reason=$reason"
}

# ─── Watch Command ─────────────────────────────────────────────────────────

cmd_watch() {
    local interval="${1:-60}"

    if [[ -f "$MONITOR_PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            warn "Monitor already running with PID $old_pid"
            return 1
        fi
    fi

    info "Starting incident monitoring (interval: ${interval}s)"

    # Background process
    (
        echo $$ > "$MONITOR_PID_FILE"
        trap 'rm -f "'"$MONITOR_PID_FILE"'"' EXIT

        while true; do
            sleep "$interval"

            # Check for recent failures
            local failures_json
            failures_json=$(get_recent_failures "$interval")
            local failure_count
            failure_count=$(echo "$failures_json" | jq 'length')

            if [[ "$failure_count" -gt 0 ]]; then
                info "Detected $failure_count failure(s)"

                # Generate incident
                local incident_id
                incident_id="inc-$(date +%s)"

                local severity
                severity=$(classify_severity "$(echo "$failures_json" | jq -r '.[0].type')" "$failure_count")

                local root_cause
                root_cause=$(analyze_root_cause "$(echo "$failures_json" | jq -r '.[0] | tostring')" "$INCIDENT_CONFIG")

                create_incident_record "$incident_id" "$severity" "$root_cause" "$failures_json"

                info "Incident $incident_id created (severity: $severity)"
                emit_event "incident.detected" "incident_id=$incident_id" "severity=$severity"

                # Auto-response for P0/P1: hotfix issue, trigger pipeline, optional rollback
                if [[ "$severity" == "P0" ]] || [[ "$severity" == "P1" ]]; then
                    local auto_rollback
                    auto_rollback=$(jq -r '.auto_rollback_enabled // false' "$INCIDENT_CONFIG" 2>/dev/null || echo "false")
                    if [[ "$auto_rollback" == "true" ]]; then
                        trigger_rollback_for_incident "$incident_id" "P0/P1 incident: $root_cause"
                    fi
                    local auto_hotfix
                    auto_hotfix=$(jq -r '.p0_auto_hotfix // .p1_auto_hotfix' "$INCIDENT_CONFIG" 2>/dev/null || echo "false")
                    if [[ "$auto_hotfix" == "true" ]]; then
                        local issue_num
                        issue_num=$(create_hotfix_issue "$incident_id" "$severity" "$root_cause")
                        if [[ -n "$issue_num" ]]; then
                            trigger_pipeline_for_incident "$issue_num" "$incident_id"
                        fi
                    fi
                fi
            fi
        done
    ) &

    success "Monitor started in background (PID: $!)"
}

# ─── List Command ──────────────────────────────────────────────────────────

cmd_list() {
    local format="${1:-table}"

    local incident_files
    incident_files=$(find "$INCIDENTS_DIR" -name '*.json' -not -name '*postmortem*' -type f 2>/dev/null || true)

    if [[ -z "$incident_files" ]]; then
        info "No incidents recorded"
        return 0
    fi

    case "$format" in
        json)
            echo "["
            local first=true
            while IFS= read -r incident_file; do
                [[ -z "$incident_file" ]] && continue
                if [[ "$first" == true ]]; then
                    first=false
                else
                    echo ","
                fi
                cat "$incident_file"
            done <<< "$incident_files"
            echo "]"
            ;;
        *)
            echo -e "${BOLD}Recent Incidents${RESET}"
            echo -e "${DIM}────────────────────────────────────────────────────────────────${RESET}"

            while IFS= read -r incident_file; do
                [[ -z "$incident_file" ]] && continue

                local id severity status cause
                id=$(jq -r '.id // "unknown"' "$incident_file" 2>/dev/null || echo "unknown")
                severity=$(jq -r '.severity // "P3"' "$incident_file" 2>/dev/null || echo "P3")
                status=$(jq -r '.status // "open"' "$incident_file" 2>/dev/null || echo "open")
                cause=$(jq -r '.root_cause // "unknown"' "$incident_file" 2>/dev/null || echo "unknown")
                cause="${cause:0:50}"

                case "$severity" in
                    P0) severity="${RED}${BOLD}$severity${RESET}" ;;
                    P1) severity="${YELLOW}${BOLD}$severity${RESET}" ;;
                    P2) severity="${BLUE}$severity${RESET}" ;;
                    *) severity="${DIM}$severity${RESET}" ;;
                esac

                printf "%-20s %s  %-8s  %s\n" "$id" "$severity" "$status" "$cause"
            done <<< "$incident_files"
            ;;
    esac
}

# ─── Show Command ──────────────────────────────────────────────────────────

cmd_show() {
    local incident_id="$1"
    [[ -z "$incident_id" ]] && { error "Usage: shipwright incident show <incident_id>"; return 1; }

    local incident_file="${INCIDENTS_DIR}/${incident_id}.json"
    [[ ! -f "$incident_file" ]] && { error "Incident not found: $incident_id"; return 1; }

    info "Incident: $incident_id"
    echo ""

    jq . "$incident_file" | while read -r line; do
        echo "  $line"
    done
}

# ─── Report Command ────────────────────────────────────────────────────────

cmd_report() {
    local incident_id="$1"
    [[ -z "$incident_id" ]] && { error "Usage: shipwright incident report <incident_id>"; return 1; }

    local incident_file="${INCIDENTS_DIR}/${incident_id}.json"
    [[ ! -f "$incident_file" ]] && { error "Incident not found: $incident_id"; return 1; }

    local incident
    incident=$(jq . "$incident_file")

    local report_file="${INCIDENTS_DIR}/${incident_id}-postmortem.md"

    cat > "$report_file" << EOF
# Post-Incident Report
**Incident ID:** $incident_id
**Generated:** $(now_iso)

## Summary
$(echo "$incident" | jq -r '.root_cause')

## Timeline
EOF

    echo "$incident" | jq -r '.failure_events[] | "- \(.ts): \(.type)"' >> "$report_file"

    cat >> "$report_file" << EOF

## Impact
- Severity: $(echo "$incident" | jq -r '.severity')
- Status: $(echo "$incident" | jq -r '.status')

## Resolution
$(echo "$incident" | jq -r '.remediation // "Pending"')

## Prevention
1. Monitor for similar patterns
2. Add alerting thresholds
3. Improve automated detection
EOF

    success "Report generated: $report_file"
    echo "$report_file"
}

# ─── Stats Command ──────────────────────────────────────────────────────────

cmd_stats() {
    local format="${1:-table}"

    if [[ ! -d "$INCIDENTS_DIR" ]] || [[ -z "$(ls -1 "$INCIDENTS_DIR"/*.json 2>/dev/null | grep -v postmortem)" ]]; then
        info "No incident data available"
        return 0
    fi

    local total_incidents
    total_incidents=$(ls -1 "$INCIDENTS_DIR"/*.json 2>/dev/null | grep -v postmortem | wc -l)

    local incident_files
    incident_files=$(find "$INCIDENTS_DIR" -name '*.json' -not -name '*postmortem*' -type f 2>/dev/null || true)
    local p0_count p1_count p2_count p3_count resolved_count mttr_sum mttr_avg
    p0_count=0
    p1_count=0
    p2_count=0
    p3_count=0
    resolved_count=0
    mttr_sum=0

    while IFS= read -r incident_file; do
        [[ -z "$incident_file" ]] && continue
        local sev status mttr
        sev=$(jq -r '.severity // "P3"' "$incident_file" 2>/dev/null || echo "P3")
        status=$(jq -r '.status // "open"' "$incident_file" 2>/dev/null || echo "open")
        mttr=$(jq -r '.mttr_seconds // 0' "$incident_file" 2>/dev/null || echo "0")

        case "$sev" in
            P0) ((p0_count++)) ;;
            P1) ((p1_count++)) ;;
            P2) ((p2_count++)) ;;
            *) ((p3_count++)) ;;
        esac

        if [[ "$status" == "resolved" ]]; then
            ((resolved_count++))
            mttr_sum=$((mttr_sum + mttr))
        fi
    done <<< "$incident_files"

    mttr_avg=0
    if [[ "$resolved_count" -gt 0 ]]; then
        mttr_avg=$((mttr_sum / resolved_count))
    fi

    case "$format" in
        json)
            jq -n \
                --arg total "$total_incidents" \
                --arg p0 "$p0_count" \
                --arg p1 "$p1_count" \
                --arg p2 "$p2_count" \
                --arg p3 "$p3_count" \
                --arg resolved "$resolved_count" \
                --arg mttr "$mttr_avg" \
                '{
                    total: ($total | tonumber),
                    by_severity: {p0: ($p0 | tonumber), p1: ($p1 | tonumber), p2: ($p2 | tonumber), p3: ($p3 | tonumber)},
                    resolved: ($resolved | tonumber),
                    mttr_seconds: ($mttr | tonumber)
                }'
            ;;
        *)
            echo -e "${BOLD}Incident Statistics${RESET}"
            echo -e "${DIM}────────────────────────────────────────────────────────────────${RESET}"
            echo "Total Incidents:        $total_incidents"
            echo "  P0 (Critical):        $p0_count"
            echo "  P1 (High):            $p1_count"
            echo "  P2 (Medium):          $p2_count"
            echo "  P3 (Low):             $p3_count"
            echo ""
            echo "Resolved:               $resolved_count"
            echo "MTTR (avg):             $(format_duration "$mttr_avg")"
            ;;
    esac
}

# ─── Stop Command ──────────────────────────────────────────────────────────

cmd_stop() {
    if [[ -f "$MONITOR_PID_FILE" ]]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$MONITOR_PID_FILE"
            success "Monitor stopped (PID: $pid)"
        else
            warn "Monitor not running"
        fi
    else
        warn "Monitor not running"
    fi
}

# ─── Help Command ──────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright incident${RESET} — Autonomous incident detection & response"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright incident${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}watch${RESET} [interval]      Start monitoring for incidents (default: 60s)"
    echo -e "  ${CYAN}stop${RESET}                 Stop incident monitoring"
    echo -e "  ${CYAN}list${RESET} [format]        List recent incidents (table|json)"
    echo -e "  ${CYAN}show${RESET} <incident-id>   Show details for an incident"
    echo -e "  ${CYAN}report${RESET} <incident-id> Generate post-mortem report"
    echo -e "  ${CYAN}stats${RESET} [format]       Show incident statistics (table|json)"
    echo -e "  ${CYAN}config${RESET} <cmd>         Configure incident response (show|set)"
    echo -e "  ${CYAN}help${RESET}                 Show this help"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright incident watch          # Start monitoring${RESET}"
    echo -e "  ${DIM}shipwright incident list           # Show all incidents${RESET}"
    echo -e "  ${DIM}shipwright incident show inc-1702  # Show incident details${RESET}"
    echo -e "  ${DIM}shipwright incident report inc-1702 # Generate post-mortem${RESET}"
    echo -e "  ${DIM}shipwright incident stats          # Show MTTR and frequency${RESET}"
}

# ─── Main Router ───────────────────────────────────────────────────────────

main() {
    ensure_incident_dir

    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        watch)
            cmd_watch "$@"
            ;;
        stop)
            cmd_stop "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        show)
            cmd_show "$@"
            ;;
        report)
            cmd_report "$@"
            ;;
        stats)
            cmd_stats "$@"
            ;;
        config)
            error "config command not yet implemented"
            return 1
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
