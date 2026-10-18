#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright incident — Autonomous Incident Detection & Response               ║
# ║  Detect failures · Triage · Root cause analysis · Auto-remediate      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# shellcheck disable=SC2034
VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# DB layer for dual-read (SQLite + JSONL fallback)
# shellcheck source=sw-db.sh
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
# Issue intake caps for automated filings (ADR-0007); path is relative to this file
# shellcheck source=lib/safety-gates.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/safety-gates.sh"
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

# ─── Structured Event Log ──────────────────────────────────────────────────
# shellcheck disable=SC2034
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
  "auto_remediate_enabled": false,
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
  "escalation": {
    "p0": ["create_issue", "trigger_hotfix_pipeline", "emit_urgent_event"],
    "p1": ["create_issue", "trigger_pipeline"],
    "p2": ["create_issue"],
    "p3": ["memory_only"]
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

    db_query_events_since "$cutoff_time" 2>/dev/null | jq -e 'map(select((.type | tostring) | (test("failed") or test("error") or test("timeout")))) | length > 0' >/dev/null 2>/dev/null && return 0 || return 1
}

get_recent_failures() {
    local since="${1:-3600}"
    local cutoff_time=$(($(now_epoch) - since))

    db_query_events_since "$cutoff_time" 2>/dev/null | jq '
        map(select((.type | tostring) | (test("failed") or test("error") or test("timeout")))) |
        map({
            ts: .ts,
            ts_epoch: .ts_epoch,
            type: .type,
            issue: .issue,
            stage: .stage,
            reason: .reason,
            error: .error
        })
    ' 2>/dev/null || echo "[]"
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
    # shellcheck disable=SC2034
    local config="$2"

    local timeout_hits error_hits memory_hits dependency_hits
    timeout_hits=$(echo "$failure_log" | grep -ic "timeout\|deadline\|too slow" || true)
    timeout_hits="${timeout_hits:-0}"
    memory_hits=$(echo "$failure_log" | grep -ic "out of memory\|OOM\|heap" || true)
    memory_hits="${memory_hits:-0}"
    dependency_hits=$(echo "$failure_log" | grep -ic "dependency\|import\|require\|not found" || true)
    dependency_hits="${dependency_hits:-0}"
    error_hits=$(echo "$failure_log" | grep -c . || true)
    error_hits="${error_hits:-0}"

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

    if ! command -v gh >/dev/null 2>&1; then
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

    # shipwright label so daemon picks up; hotfix for routing. The intake cap counts open
    # issues with the first label (hotfix).
    local labels issue_url
    labels="$(_config_get "labels.incident_labels" "hotfix,shipwright")"
    issue_url=$(patrol_issue_create --intake-label "${labels%%,*}" \
        --title "$title" --body "$body" --label "$labels" 2>/dev/null || echo "")

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

# ─── Incident Timeline ─────────────────────────────────────────────────

incident_timeline_update() {
    local incident_id="$1"
    local action="$2"
    local details="${3:-}"
    local actor="${4:-agent}"

    local incident_file="${INCIDENTS_DIR}/${incident_id}.json"
    [[ ! -f "$incident_file" ]] && return 1

    local timestamp
    timestamp=$(now_iso)

    local timeline_entry
    timeline_entry=$(jq -n \
        --arg ts "$timestamp" \
        --arg action "$action" \
        --arg details "$details" \
        --arg actor "$actor" \
        '{timestamp: $ts, action: $action, details: $details, actor: $actor}')

    jq --argjson entry "$timeline_entry" '.timeline += [$entry]' "$incident_file" > "${incident_file}.tmp" && \
        mv "${incident_file}.tmp" "$incident_file"

    emit_event "incident.timeline_updated" "incident_id=$incident_id" "action=$action" "actor=$actor"
}

# ─── Intelligent Root Cause Analysis ─────────────────────────────────

incident_deep_analysis() {
    local incident_id="$1"
    local failure_log="$2"

    local incident_file="${INCIDENTS_DIR}/${incident_id}.json"
    [[ ! -f "$incident_file" ]] && return 1

    local probable_cause="Unknown cause"
    local confidence="low"
    local affected_components="unknown"
    local suggested_fix="Review logs and recent commits"

    # Fallback to keyword-based analysis
    probable_cause=$(analyze_root_cause "$failure_log" "$INCIDENT_CONFIG")

    local deep_analysis
    deep_analysis=$(jq -n \
        --arg cause "$probable_cause" \
        --arg conf "$confidence" \
        --arg comps "$affected_components" \
        --arg fix "$suggested_fix" \
        '{probable_cause: $cause, confidence: $conf, affected_components: $comps, suggested_fix: $fix}')

    jq --argjson analysis "$deep_analysis" '.deep_analysis = $analysis' "$incident_file" > "${incident_file}.tmp" && \
        mv "${incident_file}.tmp" "$incident_file"

    echo "$deep_analysis"
    emit_event "incident.deep_analysis_complete" "incident_id=$incident_id" "confidence=$confidence"
}

# ─── Incident Correlation Engine ────────────────────────────────────

incident_correlate() {
    local time_window_secs="${1:-300}"

    local current_epoch
    current_epoch=$(now_epoch)
    local window_start=$((current_epoch - time_window_secs))

    local grouped="{}"

    local incident_files
    incident_files=$(find "$INCIDENTS_DIR" -name 'inc-*.json' -type f 2>/dev/null || true)

    while IFS= read -r incident_file; do
        [[ -z "$incident_file" ]] && continue

        local id created_at signature
        id=$(jq -r '.id' "$incident_file" 2>/dev/null || echo "")
        created_at=$(jq -r '.created_at' "$incident_file" 2>/dev/null || echo "")
        local created_epoch
        created_epoch=$(date_to_epoch "$created_at" || echo "0")

        if [[ "$created_epoch" -lt "$window_start" ]]; then
            continue
        fi

        signature=$(jq -r '.root_cause // "" | .[0:30]' "$incident_file" 2>/dev/null || echo "unknown")

        if echo "$grouped" | jq -e ".\"$signature\"" >/dev/null 2>&1; then
            grouped=$(echo "$grouped" | jq --arg sig "$signature" --arg id "$id" '.[$sig] += [$id]')
        else
            grouped=$(echo "$grouped" | jq --arg sig "$signature" --arg id "$id" '.[$sig] = [$id]')
        fi
    done <<< "$incident_files"

    local correlation_groups
    correlation_groups=$(echo "$grouped" | jq -c 'to_entries | map(select(.value | length > 1) | {signature: .key, incidents: .value, count: (.value | length)})')

    echo "$correlation_groups"
    emit_event "incident.correlation_complete" "groups=$(echo "$correlation_groups" | jq 'length' 2>/dev/null || echo 0)"
}

# ─── Rollback Verification ──────────────────────────────────────────────

incident_verify_rollback() {
    local incident_id="$1"

    local incident_file="${INCIDENTS_DIR}/${incident_id}.json"
    [[ ! -f "$incident_file" ]] && return 1

    info "Verifying rollback for incident $incident_id"

    local failures_after_rollback
    failures_after_rollback=$(get_recent_failures 60)
    local failure_count
    failure_count=$(echo "$failures_after_rollback" | jq 'length' 2>/dev/null || echo "0")

    local verified="false"
    if [[ "$failure_count" -eq 0 ]]; then
        verified="true"
        success "Rollback verified — no failures detected in last 60s"
    else
        warn "Failures still detected after rollback ($failure_count failure(s))"
    fi

    incident_timeline_update "$incident_id" "rollback_verified" "Verified: $verified" "agent"

    jq --arg verified "$verified" '.remediation.rollback_verified = ($verified == "true")' "$incident_file" > "${incident_file}.tmp" && \
        mv "${incident_file}.tmp" "$incident_file"

    [[ "$verified" == "true" ]]
}

# ─── Escalation Chains ──────────────────────────────────────────────

incident_escalate() {
    local incident_id="$1"
    local severity="${2:-P3}"

    local incident_file="${INCIDENTS_DIR}/${incident_id}.json"
    [[ ! -f "$incident_file" ]] && return 1

    local root_cause
    root_cause=$(jq -r '.root_cause // "Unknown"' "$incident_file" 2>/dev/null || echo "Unknown")

    case "$severity" in
        P0)
            info "P0 Incident — escalating with hotfix pipeline and urgent notification"
            incident_timeline_update "$incident_id" "escalation_p0" "Creating hotfix issue" "agent"

            local issue_num
            issue_num=$(create_hotfix_issue "$incident_id" "$severity" "$root_cause")

            if [[ -n "$issue_num" ]]; then
                trigger_pipeline_for_incident "$issue_num" "$incident_id"
                emit_event "incident.escalated_p0" "incident_id=$incident_id" "issue=$issue_num" "severity=P0"
            fi
            ;;
        P1)
            info "P1 Incident — escalating with pipeline"
            incident_timeline_update "$incident_id" "escalation_p1" "Creating issue" "agent"

            local issue_num
            issue_num=$(create_hotfix_issue "$incident_id" "$severity" "$root_cause")

            if [[ -n "$issue_num" ]]; then
                trigger_pipeline_for_incident "$issue_num" "$incident_id"
                emit_event "incident.escalated_p1" "incident_id=$incident_id" "issue=$issue_num" "severity=P1"
            fi
            ;;
        P2)
            info "P2 Incident — creating issue"
            incident_timeline_update "$incident_id" "escalation_p2" "Creating issue" "agent"

            local issue_num
            issue_num=$(create_hotfix_issue "$incident_id" "$severity" "$root_cause")
            if [[ -n "$issue_num" ]]; then
                emit_event "incident.escalated_p2" "incident_id=$incident_id" "issue=$issue_num" "severity=P2"
            fi
            ;;
        P3)
            info "P3 Incident — recording in memory"
            incident_timeline_update "$incident_id" "escalation_p3" "Low severity — memory only" "agent"
            emit_event "incident.escalated_p3" "incident_id=$incident_id" "severity=P3"
            ;;
    esac
}

# ─── Auto-Remediation Orchestration ─────────────────────────────────

incident_auto_remediate() {
    local incident_id="$1"

    local incident_file="${INCIDENTS_DIR}/${incident_id}.json"
    [[ ! -f "$incident_file" ]] && { error "Incident not found: $incident_id"; return 1; }

    info "Starting auto-remediation for incident $incident_id"
    incident_timeline_update "$incident_id" "auto_remediation_started" "Full loop orchestration" "agent"

    info "Step 1: Correlating with recent incidents"
    local correlations
    correlations=$(incident_correlate 300)
    incident_timeline_update "$incident_id" "correlation_check" "Correlated failures: $(echo "$correlations" | jq 'length' 2>/dev/null || echo "0")" "agent"

    info "Step 2: Running deep analysis"
    local failure_log
    failure_log=$(jq -r '.failure_events | @json' "$incident_file" 2>/dev/null || echo "{}")
    local deep_analysis
    deep_analysis=$(incident_deep_analysis "$incident_id" "$failure_log")

    info "Step 3: Escalating incident"
    local severity
    severity=$(jq -r '.severity // "P3"' "$incident_file" 2>/dev/null || echo "P3")
    incident_escalate "$incident_id" "$severity"

    if [[ "$severity" == "P0" ]] || [[ "$severity" == "P1" ]]; then
        info "Step 4: Waiting for pipeline fix attempt (60s timeout)"
        incident_timeline_update "$incident_id" "pipeline_wait" "Waiting for fix" "agent"

        sleep 5

        info "Step 5: Verifying fix"
        if incident_verify_rollback "$incident_id"; then
            incident_timeline_update "$incident_id" "resolution" "Incident resolved" "agent"
            jq '.status = "resolved" | .resolved_at = (now | todate)' "$incident_file" > "${incident_file}.tmp" && \
                mv "${incident_file}.tmp" "$incident_file"
            success "Incident $incident_id auto-remediated and resolved"
        else
            warn "Automated fix failed — escalating severity"
            local new_severity
            case "$severity" in
                P1) new_severity="P0" ;;
                P2) new_severity="P1" ;;
                *) new_severity="P0" ;;
            esac

            incident_timeline_update "$incident_id" "escalation_due_to_failure" "Automated fix failed, escalating to $new_severity" "agent"
            jq --arg sev "$new_severity" '.severity = $sev' "$incident_file" > "${incident_file}.tmp" && \
                mv "${incident_file}.tmp" "$incident_file"

            incident_escalate "$incident_id" "$new_severity"
            emit_event "incident.auto_remediation_failed" "incident_id=$incident_id" "escalated_to=$new_severity"
        fi
    else
        incident_timeline_update "$incident_id" "resolution" "P2/P3 — tracked for human review" "agent"
    fi

    success "Auto-remediation orchestration complete for incident $incident_id"
    emit_event "incident.auto_remediation_complete" "incident_id=$incident_id"
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
            failure_count=$(echo "$failures_json" | jq 'length' 2>/dev/null || echo "0")

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

                # Create harness gap for test case tracking (Code Factory pattern)
                create_harness_gap "$incident_id" "$severity" "$root_cause" 2>/dev/null || true

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

    # shellcheck disable=SC2010
    if [[ ! -d "$INCIDENTS_DIR" ]] || [[ -z "$(ls -1 "$INCIDENTS_DIR"/*.json 2>/dev/null | grep -v postmortem)" ]]; then
        info "No incident data available"
        return 0
    fi

    local total_incidents
    # shellcheck disable=SC2010
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
            P0) p0_count=$((p0_count + 1)) ;;
            P1) p1_count=$((p1_count + 1)) ;;
            P2) p2_count=$((p2_count + 1)) ;;
            *) p3_count=$((p3_count + 1)) ;;
        esac

        if [[ "$status" == "resolved" ]]; then
            resolved_count=$((resolved_count + 1))
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

# ─── Harness Gap Loop ─────────────────────────────────────────────────────
# Code Factory pattern: production regression → harness gap issue → test case
# added → SLA tracked. Every incident must produce a test case within SLA.

HARNESS_GAPS_DIR="${INCIDENTS_DIR}/harness-gaps"

load_harness_gap_policy() {
    local policy="${REPO_DIR}/config/policy.json"
    if [[ -f "$policy" ]]; then
        HARNESS_GAP_ENABLED=$(jq -r '.harnessGapPolicy.enabled // false' "$policy" 2>/dev/null || echo "false")
        HARNESS_GAP_P0_SLA=$(jq -r '.harnessGapPolicy.p0SlaHours // 24' "$policy" 2>/dev/null || echo "24")
        HARNESS_GAP_P1_SLA=$(jq -r '.harnessGapPolicy.p1SlaHours // 72' "$policy" 2>/dev/null || echo "72")
        HARNESS_GAP_P2_SLA=$(jq -r '.harnessGapPolicy.p2SlaHours // 168' "$policy" 2>/dev/null || echo "168")
        HARNESS_GAP_AUTO_CREATE=$(jq -r '.harnessGapPolicy.autoCreateGapIssue // true' "$policy" 2>/dev/null || echo "true")
        HARNESS_GAP_REQUIRE_TEST=$(jq -r '.harnessGapPolicy.requireTestCaseBeforeClose // true' "$policy" 2>/dev/null || echo "true")
    else
        HARNESS_GAP_ENABLED="false"
    fi
}

create_harness_gap() {
    local incident_id="$1"
    local severity="$2"
    local root_cause="$3"

    mkdir -p "$HARNESS_GAPS_DIR"
    load_harness_gap_policy

    if [[ "$HARNESS_GAP_ENABLED" != "true" ]]; then
        return 0
    fi

    local gap_id="gap-${incident_id}"
    local gap_file="${HARNESS_GAPS_DIR}/${gap_id}.json"
    local sla_hours

    case "$severity" in
        P0) sla_hours="$HARNESS_GAP_P0_SLA" ;;
        P1) sla_hours="$HARNESS_GAP_P1_SLA" ;;
        P2) sla_hours="$HARNESS_GAP_P2_SLA" ;;
        *)  sla_hours="$HARNESS_GAP_P2_SLA" ;;
    esac

    local created_at
    created_at=$(now_iso)
    local created_epoch
    created_epoch=$(now_epoch)
    local sla_deadline_epoch=$((created_epoch + sla_hours * 3600))

    cat > "$gap_file" << EOF
{
  "gap_id": "${gap_id}",
  "incident_id": "${incident_id}",
  "severity": "${severity}",
  "root_cause": "${root_cause}",
  "created_at": "${created_at}",
  "created_epoch": ${created_epoch},
  "sla_hours": ${sla_hours},
  "sla_deadline_epoch": ${sla_deadline_epoch},
  "status": "open",
  "test_case_file": null,
  "github_issue": null,
  "resolved_at": null
}
EOF

    info "Harness gap created: ${gap_id} (SLA: ${sla_hours}h)"
    emit_event "harness_gap.created" "gap_id=${gap_id}" "incident=${incident_id}" "sla_hours=${sla_hours}"

    # Auto-create GitHub issue for gap tracking
    if [[ "$HARNESS_GAP_AUTO_CREATE" == "true" ]] && command -v gh >/dev/null 2>&1; then
        local title="[HARNESS GAP] ${severity}: Add test case for ${root_cause}"
        local body="## Harness Gap

**Incident:** \`${incident_id}\`
**Severity:** ${severity}
**Root Cause:** ${root_cause}
**SLA:** ${sla_hours} hours

## Required Action
Add a regression test case that covers this failure scenario.

## Acceptance Criteria
- [ ] Test case file created in \`scripts/\`
- [ ] Test reproduces the original failure condition
- [ ] Test passes after the fix is applied
- [ ] Gap record resolved via \`shipwright incident gap resolve ${gap_id} <test_file>\`

## Context
This gap was automatically created by the Shipwright incident commander.
Part of the Code Factory harness-gap loop: every production regression
must produce a harness test case within the SLA window.

---
*Auto-generated by Shipwright Code Factory*"

        # The intake cap counts open issues with the first label (harness-gap)
        local gap_labels issue_url
        gap_labels="$(_config_get "labels.harness_gap_labels" "harness-gap,shipwright")"
        issue_url=$(patrol_issue_create --intake-label "${gap_labels%%,*}" \
            --title "$title" --body "$body" --label "$gap_labels" 2>/dev/null || echo "")
        if [[ -n "$issue_url" ]]; then
            local issue_num
            issue_num=$(echo "$issue_url" | sed -n 's|.*/issues/\([0-9]*\)|\1|p')
            jq --arg issue "$issue_num" '.github_issue = $issue' "$gap_file" > "${gap_file}.tmp" && mv "${gap_file}.tmp" "$gap_file"
            success "Created harness gap issue: $issue_url"
        fi
    fi
}

resolve_harness_gap() {
    local gap_id="$1"
    local test_case_file="${2:-}"

    local gap_file="${HARNESS_GAPS_DIR}/${gap_id}.json"
    if [[ ! -f "$gap_file" ]]; then
        error "Harness gap not found: ${gap_id}"
        return 1
    fi

    load_harness_gap_policy

    if [[ "$HARNESS_GAP_REQUIRE_TEST" == "true" && -z "$test_case_file" ]]; then
        error "Test case file required to resolve gap (policy: requireTestCaseBeforeClose=true)"
        echo "Usage: shipwright incident gap resolve ${gap_id} <test_case_file>"
        return 1
    fi

    if [[ -n "$test_case_file" && ! -f "$test_case_file" ]]; then
        error "Test case file not found: ${test_case_file}"
        return 1
    fi

    local resolved_at
    resolved_at=$(now_iso)
    jq --arg resolved_at "$resolved_at" --arg test_file "${test_case_file:-null}" \
        '.status = "resolved" | .resolved_at = $resolved_at | .test_case_file = $test_file' \
        "$gap_file" > "${gap_file}.tmp" && mv "${gap_file}.tmp" "$gap_file"

    success "Harness gap resolved: ${gap_id}"
    emit_event "harness_gap.resolved" "gap_id=${gap_id}" "test_file=${test_case_file:-none}"

    # Close the GitHub issue if it exists
    local github_issue
    github_issue=$(jq -r '.github_issue // empty' "$gap_file" 2>/dev/null)
    if [[ -n "$github_issue" ]] && command -v gh >/dev/null 2>&1; then
        gh issue close "$github_issue" --comment "Harness gap resolved. Test case: \`${test_case_file:-none}\`" 2>/dev/null || true
    fi
}

cmd_gap() {
    local subcmd="${1:-list}"
    shift || true

    mkdir -p "$HARNESS_GAPS_DIR"

    case "$subcmd" in
        create)
            create_harness_gap "$@"
            ;;
        resolve)
            resolve_harness_gap "$@"
            ;;
        list)
            local current_epoch
            current_epoch=$(now_epoch)
            echo -e "${BOLD}Harness Gaps${RESET}"
            echo -e "${DIM}────────────────────────────────────────────────────────────────${RESET}"

            local gap_files
            gap_files=$(find "$HARNESS_GAPS_DIR" -name 'gap-*.json' -type f 2>/dev/null || true)

            if [[ -z "$gap_files" ]]; then
                info "No harness gaps recorded"
                return 0
            fi

            while IFS= read -r gf; do
                [[ -z "$gf" ]] && continue
                local gid sev status sla_deadline
                gid=$(jq -r '.gap_id // "unknown"' "$gf" 2>/dev/null)
                sev=$(jq -r '.severity // "P3"' "$gf" 2>/dev/null)
                status=$(jq -r '.status // "open"' "$gf" 2>/dev/null)
                sla_deadline=$(jq -r '.sla_deadline_epoch // 0' "$gf" 2>/dev/null)

                local sla_remaining=""
                if [[ "$status" == "open" ]]; then
                    local remaining=$((sla_deadline - current_epoch))
                    if [[ "$remaining" -lt 0 ]]; then
                        sla_remaining="${RED}OVERDUE${RESET}"
                    else
                        sla_remaining="$(format_duration "$remaining") remaining"
                    fi
                else
                    sla_remaining="${GREEN}resolved${RESET}"
                fi

                printf "  %-20s  %-4s  %-8s  %b\n" "$gid" "$sev" "$status" "$sla_remaining"
            done <<< "$gap_files"
            ;;
        sla)
            # Show SLA compliance metrics
            load_harness_gap_policy
            local current_epoch
            current_epoch=$(now_epoch)
            local total=0 resolved=0 overdue=0 within_sla=0

            local gap_files
            gap_files=$(find "$HARNESS_GAPS_DIR" -name 'gap-*.json' -type f 2>/dev/null || true)

            while IFS= read -r gf; do
                [[ -z "$gf" ]] && continue
                total=$((total + 1))
                local status sla_deadline
                status=$(jq -r '.status // "open"' "$gf" 2>/dev/null)
                sla_deadline=$(jq -r '.sla_deadline_epoch // 0' "$gf" 2>/dev/null)

                if [[ "$status" == "resolved" ]]; then
                    resolved=$((resolved + 1))
                    within_sla=$((within_sla + 1))
                elif [[ "$current_epoch" -gt "$sla_deadline" ]]; then
                    overdue=$((overdue + 1))
                fi
            done <<< "$gap_files"

            echo -e "${BOLD}Harness Gap SLA Compliance${RESET}"
            echo -e "${DIM}────────────────────────────────────────────────────────────────${RESET}"
            echo "Total gaps:     $total"
            echo "Resolved:       $resolved"
            echo "Overdue:        $overdue"
            echo "SLA compliance: $( [[ $total -gt 0 ]] && echo "$((within_sla * 100 / total))%" || echo "N/A" )"
            ;;
        *)
            echo "Usage: shipwright incident gap <create|resolve|list|sla>"
            return 1
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
    echo -e "  ${CYAN}gap${RESET} <cmd>            Harness gap loop (list|create|resolve|sla)"
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
        gap)
            cmd_gap "$@"
            ;;
        config)
            local policy="${REPO_DIR}/config/policy.json"
            if [[ ! -f "$policy" ]]; then
                warn "No policy file found at ${policy}"
                echo "  Use: shipwright init  to create one"
                return 1
            fi
            echo -e "${BOLD}Incident & Harness Gap Configuration${RESET}"
            echo ""
            echo -e "  Policy file:             ${DIM}${policy}${RESET}"
            echo -e "  Harness gap enabled:     $(jq -r '.harnessGapPolicy.enabled // false' "$policy" 2>/dev/null)"
            echo -e "  P0 SLA (hours):          $(jq -r '.harnessGapPolicy.p0SlaHours // 24' "$policy" 2>/dev/null)"
            echo -e "  P1 SLA (hours):          $(jq -r '.harnessGapPolicy.p1SlaHours // 72' "$policy" 2>/dev/null)"
            echo -e "  P2 SLA (hours):          $(jq -r '.harnessGapPolicy.p2SlaHours // 168' "$policy" 2>/dev/null)"
            echo -e "  Auto-create gap issues:  $(jq -r '.harnessGapPolicy.autoCreateGapIssue // true' "$policy" 2>/dev/null)"
            echo -e "  Require test before close: $(jq -r '.harnessGapPolicy.requireTestCaseBeforeClose // true' "$policy" 2>/dev/null)"
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
