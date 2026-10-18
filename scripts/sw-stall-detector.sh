#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright stall-detector — Pipeline Stall & Deadlock Detection         ║
# ║  Monitor running pipelines, detect stalls, classify issues, auto-abort   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="3.3.0"
# shellcheck source=lib/bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"

# ─── Constants ──────────────────────────────────────────────────────────────
HEARTBEAT_DIR="$HOME/.shipwright/heartbeats"
PIPELINE_ARTIFACTS_DIR="${PIPELINE_ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
STATE_FILE="${PIPELINE_ARTIFACTS_DIR:-pipeline-state.md}"
STALL_DETECTOR_STATE="${HOME}/.shipwright/stall-detector-state.json"

# Default configuration
STALL_TIMEOUT_SECONDS="${STALL_TIMEOUT_SECONDS:-300}"
MAX_STAGE_RETRIES="${MAX_STAGE_RETRIES:-5}"
HEARTBEAT_MAX_AGE_SECONDS="${HEARTBEAT_MAX_AGE_SECONDS:-120}"
AUTO_ABORT_ENABLED="${AUTO_ABORT_ENABLED:-true}"
CREATE_ISSUE_ON_ABORT="${CREATE_ISSUE_ON_ABORT:-false}"
STALL_DETECTOR_INTERVAL="${STALL_DETECTOR_INTERVAL:-30}"

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright Stall Detector${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright stall-detector <command> [options]"
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo -e "    ${CYAN}check${RESET}        Single-shot detection, return JSON"
    echo -e "    ${CYAN}watch${RESET}        Background monitor (runs every N seconds)"
    echo -e "    ${CYAN}abort${RESET}        Manually abort a stalled pipeline"
    echo -e "    ${CYAN}config${RESET}       Show current configuration"
    echo -e "    ${CYAN}status${RESET}       Show detection stats and recent stalls"
    echo ""
    echo -e "  ${BOLD}CHECK OPTIONS${RESET}"
    echo -e "    (none)"
    echo ""
    echo -e "  ${BOLD}WATCH OPTIONS${RESET}"
    echo -e "    --interval <secs>       Check interval (default: 30)"
    echo -e "    --once                  Run once and exit"
    echo ""
    echo -e "  ${BOLD}ABORT OPTIONS${RESET}"
    echo -e "    <pipeline-id>           Pipeline ID or PID to abort"
    echo -e "    --reason <text>         Abort reason (optional)"
    echo ""
    echo -e "  ${BOLD}EXAMPLES${RESET}"
    echo -e "    ${DIM}# One-shot detection${RESET}"
    echo -e "    shipwright stall-detector check"
    echo ""
    echo -e "    ${DIM}# Monitor in background${RESET}"
    echo -e "    shipwright stall-detector watch --interval 60"
    echo ""
    echo -e "    ${DIM}# Manually abort a stalled pipeline${RESET}"
    echo -e "    shipwright stall-detector abort pipeline-12345 --reason \"build timeout\""
    echo ""
}

# ─── Ensure heartbeat and artifacts directories exist ──────────────────────
ensure_dirs() {
    mkdir -p "$HEARTBEAT_DIR"
    mkdir -p "${PIPELINE_ARTIFACTS_DIR%/*}" 2>/dev/null || true
    mkdir -p "${STALL_DETECTOR_STATE%/*}" 2>/dev/null || true
}

# ─── Load Configuration ──────────────────────────────────────────────────────
load_config() {
    local config_file=".claude/daemon-config.json"

    if [[ -f "$config_file" ]]; then
        STALL_TIMEOUT_SECONDS=$(jq -r '.stall_detection.stall_timeout_seconds // 300' "$config_file" 2>/dev/null || echo "300")
        MAX_STAGE_RETRIES=$(jq -r '.stall_detection.max_stage_retries // 5' "$config_file" 2>/dev/null || echo "5")
        HEARTBEAT_MAX_AGE_SECONDS=$(jq -r '.stall_detection.heartbeat_max_age_seconds // 120' "$config_file" 2>/dev/null || echo "120")
        AUTO_ABORT_ENABLED=$(jq -r '.stall_detection.auto_abort_enabled // true' "$config_file" 2>/dev/null || echo "true")
        CREATE_ISSUE_ON_ABORT=$(jq -r '.stall_detection.create_issue_on_abort // false' "$config_file" 2>/dev/null || echo "false")
        STALL_DETECTOR_INTERVAL=$(jq -r '.stall_detection.interval // 30' "$config_file" 2>/dev/null || echo "30")
    fi
}

# ─── Classify Stall Type ────────────────────────────────────────────────────
# Returns: {type, reason, severity}
stall_detector_classify() {
    local heartbeat_age="$1"
    local stage="$2"
    local retry_count="${3:-0}"

    local classification_json

    # Determine stall type based on evidence
    if [[ "$heartbeat_age" -gt "$STALL_TIMEOUT_SECONDS" ]]; then
        classification_json=$(jq -n \
            --arg type "heartbeat_stale" \
            --arg reason "No heartbeat update for ${heartbeat_age}s (threshold: ${STALL_TIMEOUT_SECONDS}s)" \
            --arg severity "critical" \
            '{type: $type, reason: $reason, severity: $severity}')
    elif [[ "$retry_count" -gt "$MAX_STAGE_RETRIES" ]]; then
        classification_json=$(jq -n \
            --arg type "loop_detected" \
            --arg reason "Stage ${stage} restarted ${retry_count} times (max: ${MAX_STAGE_RETRIES})" \
            --arg severity "warning" \
            '{type: $type, reason: $reason, severity: $severity}')
    else
        classification_json=$(jq -n \
            --arg type "timeout" \
            --arg reason "Stage ${stage} exceeded max duration" \
            --arg severity "warning" \
            '{type: $type, reason: $reason, severity: $severity}')
    fi

    echo "$classification_json"
}

# ─── Single-shot stall check ─────────────────────────────────────────────────
# Returns JSON: {stalled: [...], deadlocked: [...], looping: [...]}
cmd_check() {
    ensure_dirs
    load_config

    # Build arrays using jq
    local result_json

    # Read all heartbeat files
    if [[ ! -d "$HEARTBEAT_DIR" ]]; then
        result_json=$(jq -n '{stalled: [], deadlocked: [], looping: [], checked_at: "'"$(now_iso)"'", pipeline_count: 0}')
        echo "$result_json"
        return 0
    fi

    local now_epoch
    now_epoch="$(now_epoch)"

    # Build stalled list using jq
    local stalled_items=""
    for hb_file in "${HEARTBEAT_DIR}"/*.json; do
        [[ ! -f "$hb_file" ]] && continue

        local job_id updated_at stage
        job_id="$(basename "$hb_file" .json)"
        updated_at=$(jq -r '.updated_at // empty' "$hb_file" 2>/dev/null || true)
        stage=$(jq -r '.stage // empty' "$hb_file" 2>/dev/null || true)

        if [[ -z "$updated_at" ]]; then
            continue
        fi

        # Calculate heartbeat age
        local hb_epoch
        hb_epoch="$(date_to_epoch "$updated_at" || echo 0)"

        local current_age=$((now_epoch - hb_epoch))

        # Check for stale heartbeat
        if [[ "$current_age" -gt "$HEARTBEAT_MAX_AGE_SECONDS" ]]; then
            stalled_items="${stalled_items} \"$job_id\""
            emit_event "stall_detector.stalled" "job_id=$job_id" "age_seconds=$current_age" "stage=$stage" 2>/dev/null || true
        fi
    done

    # Build final JSON result
    result_json=$(jq -n \
        --arg checked_at "$(now_iso)" \
        '{
            stalled: ['"${stalled_items# }"'],
            deadlocked: [],
            looping: [],
            checked_at: $checked_at,
            pipeline_count: 0
        }' 2>/dev/null || jq -n '{stalled: [], deadlocked: [], looping: [], checked_at: "'"$(now_iso)"'", pipeline_count: 0}')

    # Fix pipeline_count
    result_json=$(echo "$result_json" | jq '.pipeline_count = ((.stalled | length) + (.deadlocked | length) + (.looping | length))')

    echo "$result_json" | jq '.'
}

# ─── Auto-abort a stalled pipeline ──────────────────────────────────────────
cmd_abort() {
    local pipeline_id="${1:-}"
    if [[ -z "$pipeline_id" ]]; then
        error "Usage: shipwright stall-detector abort <pipeline-id> [--reason <text>]"
        exit 1
    fi
    shift

    local reason="User abort"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reason) reason="${2:-}"; shift 2 ;;
            *)       shift ;;
        esac
    done

    ensure_dirs
    load_config

    local hb_file="${HEARTBEAT_DIR}/${pipeline_id}.json"

    if [[ ! -f "$hb_file" ]]; then
        error "No heartbeat found for pipeline: ${pipeline_id}"
        return 1
    fi

    local pid
    pid=$(jq -r '.pid // empty' "$hb_file" 2>/dev/null || true)

    if [[ -z "$pid" ]]; then
        error "Invalid heartbeat file for pipeline: ${pipeline_id}"
        return 1
    fi

    # Send SIGTERM to pipeline process
    if kill -0 "$pid" 2>/dev/null; then
        info "Sending SIGTERM to pipeline process $pid..."
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2

        # If still alive, send SIGKILL
        if kill -0 "$pid" 2>/dev/null; then
            warn "Process did not respond to SIGTERM, sending SIGKILL..."
            kill -KILL "$pid" 2>/dev/null || true
        fi

        success "Aborted pipeline: ${pipeline_id} (reason: ${reason})"
    else
        warn "Pipeline process $pid not running (already dead)"
    fi

    # Update heartbeat to mark as aborted
    local tmp_file
    tmp_file="$(mktemp "${HEARTBEAT_DIR}/.tmp.XXXXXX")" || { error "mktemp failed"; return 1; }

    jq --arg reason "$reason" --arg aborted_at "$(now_iso)" \
        '. + {status: "aborted", abort_reason: $reason, aborted_at: $aborted_at}' \
        "$hb_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

    mv "$tmp_file" "$hb_file" || { rm -f "$tmp_file"; return 1; }

    # Emit abort event
    emit_event "pipeline.stall_aborted" "pipeline_id=$pipeline_id" "reason=$reason" "pid=$pid" 2>/dev/null || true

    # Clear heartbeat file (optional - mark as processed)
    rm -f "$hb_file" 2>/dev/null || true

    return 0
}

# ─── Background watch loop ──────────────────────────────────────────────────
cmd_watch() {
    local interval="$STALL_DETECTOR_INTERVAL"
    local once=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval) interval="${2:-30}"; shift 2 ;;
            --once)     once=true; shift ;;
            *)          shift ;;
        esac
    done

    ensure_dirs
    load_config

    info "Starting stall detector (interval: ${interval}s, auto-abort: ${AUTO_ABORT_ENABLED})"

    # Write PID to state file
    local tmp_state
    tmp_state="$(mktemp)" || { error "mktemp failed"; return 1; }
    jq -n --arg pid "$$" --arg started_at "$(now_iso)" \
        '{pid: ($pid | tonumber), started_at: $started_at, checks: 0, aborts: 0}' > "$tmp_state" || { rm -f "$tmp_state"; return 1; }
    mv "$tmp_state" "$STALL_DETECTOR_STATE" 2>/dev/null || true

    while true; do
        local check_result
        check_result=$(cmd_check)

        local stalled_count deadlocked_count looping_count
        stalled_count=$(echo "$check_result" | jq '.stalled | length' 2>/dev/null || echo "0")
        deadlocked_count=$(echo "$check_result" | jq '.deadlocked | length' 2>/dev/null || echo "0")
        looping_count=$(echo "$check_result" | jq '.looping | length' 2>/dev/null || echo "0")

        # Log check result if any stalls detected
        if [[ "$stalled_count" -gt 0 || "$deadlocked_count" -gt 0 || "$looping_count" -gt 0 ]]; then
            warn "Detected stalls: $stalled_count stalled, $deadlocked_count deadlocked, $looping_count looping"

            # Auto-abort if enabled
            if [[ "$AUTO_ABORT_ENABLED" == "true" ]]; then
                local stalled_pids
                stalled_pids=$(echo "$check_result" | jq -r '.stalled[] // empty' 2>/dev/null || true)
                while IFS= read -r pid_or_id; do
                    [[ -z "$pid_or_id" ]] && continue
                    info "Auto-aborting stalled pipeline: $pid_or_id"
                    cmd_abort "$pid_or_id" --reason "auto-abort: stall detected (no heartbeat update)"
                done <<< "$stalled_pids"
            fi
        fi

        [[ "$once" == "true" ]] && break

        sleep "$interval"
    done
}

# ─── Show configuration ─────────────────────────────────────────────────────
cmd_config() {
    ensure_dirs
    load_config

    echo ""
    echo -e "${BOLD}Stall Detection Configuration${RESET}"
    echo -e "${DIM}═════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${CYAN}stall_timeout_seconds${RESET}       ${STALL_TIMEOUT_SECONDS}"
    echo -e "  ${CYAN}max_stage_retries${RESET}          ${MAX_STAGE_RETRIES}"
    echo -e "  ${CYAN}heartbeat_max_age_seconds${RESET}  ${HEARTBEAT_MAX_AGE_SECONDS}"
    echo -e "  ${CYAN}auto_abort_enabled${RESET}         ${AUTO_ABORT_ENABLED}"
    echo -e "  ${CYAN}create_issue_on_abort${RESET}      ${CREATE_ISSUE_ON_ABORT}"
    echo -e "  ${CYAN}detector_interval${RESET}          ${STALL_DETECTOR_INTERVAL}s"
    echo ""
    echo -e "${DIM}Configure via: .claude/daemon-config.json${RESET}"
    echo -e "${DIM}Example:${RESET}"
    echo '  {
    "stall_detection": {
      "stall_timeout_seconds": 300,
      "max_stage_retries": 5,
      "heartbeat_max_age_seconds": 120,
      "auto_abort_enabled": true,
      "create_issue_on_abort": false,
      "interval": 30
    }
  }'
    echo ""
}

# ─── Show detection statistics ──────────────────────────────────────────────
cmd_status() {
    ensure_dirs

    echo ""
    echo -e "${BOLD}Stall Detection Status${RESET}"
    echo -e "${DIM}══════════════════════${RESET}"
    echo ""

    # Show detector process info if running
    if [[ -f "$STALL_DETECTOR_STATE" ]]; then
        local pid started_at checks aborts
        pid=$(jq -r '.pid // empty' "$STALL_DETECTOR_STATE" 2>/dev/null || true)
        started_at=$(jq -r '.started_at // empty' "$STALL_DETECTOR_STATE" 2>/dev/null || true)
        checks=$(jq -r '.checks // 0' "$STALL_DETECTOR_STATE" 2>/dev/null || true)
        aborts=$(jq -r '.aborts // 0' "$STALL_DETECTOR_STATE" 2>/dev/null || true)

        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo -e "  ${GREEN}✓${RESET} Detector running (PID: $pid)"
            echo -e "    Started: $started_at"
            echo -e "    Checks performed: $checks"
            echo -e "    Pipelines aborted: $aborts"
        else
            echo -e "  ${YELLOW}✗${RESET} Detector not running"
        fi
    else
        echo -e "  ${YELLOW}✗${RESET} Detector not running"
    fi

    echo ""

    # Show recent stalls
    if [[ -d "$HEARTBEAT_DIR" ]]; then
        local stall_count
        stall_count=$(ls -1 "$HEARTBEAT_DIR"/*.json 2>/dev/null | wc -l)
        echo -e "  ${CYAN}Active heartbeats: $stall_count${RESET}"
    fi

    echo ""
}

# ─── Command Router ────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        check)              cmd_check "$@" ;;
        watch)              cmd_watch "$@" ;;
        abort)              cmd_abort "$@" ;;
        config)             cmd_config "$@" ;;
        status)             cmd_status "$@" ;;
        help|--help|-h)     show_help ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
