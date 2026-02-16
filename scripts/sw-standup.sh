#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright standup — Automated Daily Standups for AI Agent Teams       ║
# ║  Gather status, identify blockers, summarize work, deliver reports      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.2"
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

# ─── Constants ──────────────────────────────────────────────────────────────
STANDUP_DIR="${HOME}/.shipwright/standups"
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"
DAEMON_STATE="${HOME}/.shipwright/daemon-state.json"
HEARTBEATS_DIR="${HOME}/.shipwright/heartbeats"

# Seconds in 24 hours
SECONDS_24H=86400

# ─── Ensure directories exist ───────────────────────────────────────────────
ensure_dirs() {
    mkdir -p "$STANDUP_DIR"
}

# ─── Epoch conversion helper ────────────────────────────────────────────────
# Convert ISO 8601 timestamp to epoch seconds (works on macOS and Linux)
iso_to_epoch() {
    local iso="$1"
    if TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s &>/dev/null 2>&1; then
        TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null || echo 0
    else
        date -d "$iso" +%s 2>/dev/null || echo 0
    fi
}

# ─── Gather Yesterday's Work ────────────────────────────────────────────────
# Scan events.jsonl for commits, PRs, tests, reviews in the last 24h
cmd_yesterday() {
    ensure_dirs

    local now_epoch
    now_epoch="$(now_epoch)"
    local cutoff=$((now_epoch - SECONDS_24H))

    local report_file="${STANDUP_DIR}/yesterday-$(date +%Y-%m-%d).txt"

    {
        echo "╔════════════════════════════════════════════════════════════════════╗"
        echo "║  Yesterday's Work (Last 24 Hours)                                  ║"
        echo "╚════════════════════════════════════════════════════════════════════╝"
        echo ""

        if [[ ! -f "$EVENTS_FILE" ]]; then
            echo "No events recorded yet."
            echo ""
            return 0
        fi

        # Group events by job/agent
        local commits=0
        local prs=0
        local tests_run=0
        local tests_passed=0
        local tests_failed=0
        local reviews=0

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            local ts_epoch
            ts_epoch=$(echo "$line" | jq -r '.ts_epoch // 0' 2>/dev/null || echo 0)

            if [[ "$ts_epoch" -lt "$cutoff" ]]; then
                continue
            fi

            local event_type
            event_type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null || true)

            case "$event_type" in
                pipeline_commit)
                    commits=$((commits + 1))
                    ;;
                pipeline_pr)
                    prs=$((prs + 1))
                    ;;
                test_run)
                    tests_run=$((tests_run + 1))
                    ;;
                test_pass)
                    tests_passed=$((tests_passed + 1))
                    ;;
                test_fail)
                    tests_failed=$((tests_failed + 1))
                    ;;
                pr_review)
                    reviews=$((reviews + 1))
                    ;;
            esac
        done < "$EVENTS_FILE"

        echo "Commits:        ${GREEN}${commits}${RESET}"
        echo "PRs Created:    ${GREEN}${prs}${RESET}"
        echo "Tests Run:      ${GREEN}${tests_run}${RESET}"
        echo "  ├─ Passed:    ${GREEN}${tests_passed}${RESET}"
        echo "  └─ Failed:    ${RED}${tests_failed}${RESET}"
        echo "Reviews:        ${GREEN}${reviews}${RESET}"
        echo ""

    } | tee "$report_file"

    success "Yesterday's report saved to ${STANDUP_DIR}/yesterday-*.txt"
}

# ─── Gather Today's Plan ────────────────────────────────────────────────────
# Read daemon state to see queued issues and active pipelines
cmd_today() {
    ensure_dirs

    local report_file="${STANDUP_DIR}/today-$(date +%Y-%m-%d).txt"

    {
        echo "╔════════════════════════════════════════════════════════════════════╗"
        echo "║  Today's Plan (Active & Queued Work)                               ║"
        echo "╚════════════════════════════════════════════════════════════════════╝"
        echo ""

        if [[ ! -f "$DAEMON_STATE" ]]; then
            echo "No daemon state available."
            echo ""
            return 0
        fi

        # Active jobs
        local active_jobs
        active_jobs=$(jq -r '.active_jobs // []' "$DAEMON_STATE" 2>/dev/null | jq length)

        echo "Active Pipelines:  ${CYAN}${active_jobs}${RESET}"
        if [[ "$active_jobs" -gt 0 ]]; then
            jq -r '.active_jobs[] | "  • Issue \(.issue_number): \(.title)"' "$DAEMON_STATE" 2>/dev/null | head -5
            if [[ "$active_jobs" -gt 5 ]]; then
                echo "  ... and $((active_jobs - 5)) more"
            fi
        fi
        echo ""

        # Queued jobs
        local queued
        queued=$(jq -r '.queued // []' "$DAEMON_STATE" 2>/dev/null | jq length)

        echo "Queued Issues:     ${YELLOW}${queued}${RESET}"
        if [[ "$queued" -gt 0 ]]; then
            jq -r '.queued[] | "  • Issue \(.issue_number): \(.title)"' "$DAEMON_STATE" 2>/dev/null | head -5
            if [[ "$queued" -gt 5 ]]; then
                echo "  ... and $((queued - 5)) more"
            fi
        fi
        echo ""

    } | tee "$report_file"

    success "Today's plan saved to ${STANDUP_DIR}/today-*.txt"
}

# ─── Detect Blockers ────────────────────────────────────────────────────────
# Identify stalled pipelines, failed stages, resource constraints
cmd_blockers() {
    ensure_dirs

    local report_file="${STANDUP_DIR}/blockers-$(date +%Y-%m-%d).txt"

    {
        echo "╔════════════════════════════════════════════════════════════════════╗"
        echo "║  Current Blockers                                                  ║"
        echo "╚════════════════════════════════════════════════════════════════════╝"
        echo ""

        local blocker_count=0

        # Check for stale heartbeats (agents not responding)
        if [[ -d "$HEARTBEATS_DIR" ]]; then
            local now_epoch
            now_epoch="$(now_epoch)"

            for hb_file in "${HEARTBEATS_DIR}"/*.json; do
                [[ ! -f "$hb_file" ]] && continue

                local updated_at
                updated_at=$(jq -r '.updated_at' "$hb_file" 2>/dev/null || true)
                [[ -z "$updated_at" || "$updated_at" == "null" ]] && continue

                local hb_epoch
                hb_epoch="$(iso_to_epoch "$updated_at")"
                local age=$((now_epoch - hb_epoch))

                # If older than 5 minutes, it's stale
                if [[ "$age" -gt 300 ]]; then
                    local job_id
                    job_id="$(basename "$hb_file" .json)"
                    local stage
                    stage=$(jq -r '.stage // "unknown"' "$hb_file" 2>/dev/null || echo "unknown")

                    echo "${RED}✗ STALE AGENT${RESET}: ${job_id} (stage: ${stage}, silent for ${age}s)"
                    blocker_count=$((blocker_count + 1))
                fi
            done
        fi

        # Check for failed pipeline stages in events
        if [[ -f "$EVENTS_FILE" ]]; then
            local failed_stages
            failed_stages=$(grep '"type":"stage_failed"' "$EVENTS_FILE" 2>/dev/null | tail -5 || true)

            if [[ -n "$failed_stages" ]]; then
                echo ""
                echo "${RED}Failed Pipeline Stages:${RESET}"
                echo "$failed_stages" | jq -r '"\(.type): \(.stage // "unknown") - \(.reason // "")"' 2>/dev/null | while read -r line; do
                    echo "  • $line"
                    blocker_count=$((blocker_count + 1))
                done
            fi
        fi

        if [[ "$blocker_count" -eq 0 ]]; then
            echo "${GREEN}✓ No blockers detected${RESET}"
        fi
        echo ""

    } | tee "$report_file"

    success "Blockers report saved to ${STANDUP_DIR}/blockers-*.txt"
}

# ─── Gather Velocity & Burn-Down Metrics ────────────────────────────────────
cmd_velocity() {
    ensure_dirs

    local report_file="${STANDUP_DIR}/velocity-$(date +%Y-%m-%d).txt"

    {
        echo "╔════════════════════════════════════════════════════════════════════╗"
        echo "║  Sprint Velocity & Burn-Down                                       ║"
        echo "╚════════════════════════════════════════════════════════════════════╝"
        echo ""

        if [[ ! -f "$DAEMON_STATE" ]]; then
            echo "No daemon state available."
            echo ""
            return 0
        fi

        # Completed in the last 24h
        local completed_24h=0
        local total_completed=0

        if [[ -f "$EVENTS_FILE" ]]; then
            local now_epoch
            now_epoch="$(now_epoch)"
            local cutoff=$((now_epoch - SECONDS_24H))

            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local ts_epoch
                ts_epoch=$(echo "$line" | jq -r '.ts_epoch // 0' 2>/dev/null || echo 0)

                if [[ "$ts_epoch" -ge "$cutoff" ]]; then
                    local event_type
                    event_type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null || true)
                    if [[ "$event_type" == "pipeline_completed" ]]; then
                        completed_24h=$((completed_24h + 1))
                    fi
                fi

                local event_type
                event_type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null || true)
                if [[ "$event_type" == "pipeline_completed" ]]; then
                    total_completed=$((total_completed + 1))
                fi
            done < "$EVENTS_FILE"
        fi

        local active_jobs
        active_jobs=$(jq -r '.active_jobs // []' "$DAEMON_STATE" 2>/dev/null | jq length)
        local queued
        queued=$(jq -r '.queued // []' "$DAEMON_STATE" 2>/dev/null | jq length)

        local total_work=$((active_jobs + queued))

        echo "Completed (24h):   ${GREEN}${completed_24h}${RESET}"
        echo "Total Completed:   ${GREEN}${total_completed}${RESET}"
        echo "Active:            ${CYAN}${active_jobs}${RESET}"
        echo "Queued:            ${YELLOW}${queued}${RESET}"
        echo "Work in Progress:  ${BLUE}${total_work}${RESET}"
        echo ""

        if [[ "$total_work" -gt 0 && "$completed_24h" -gt 0 ]]; then
            local days_remaining=$(((total_work * SECONDS_24H) / (completed_24h * 3600)))
            [[ "$days_remaining" -lt 1 ]] && days_remaining=1
            echo "Estimated Completion: ${CYAN}~${days_remaining} day(s)${RESET}"
        fi
        echo ""

    } | tee "$report_file"

    success "Velocity report saved to ${STANDUP_DIR}/velocity-*.txt"
}

# ─── Full Standup Digest ────────────────────────────────────────────────────
cmd_digest() {
    ensure_dirs

    local report_file="${STANDUP_DIR}/digest-$(date +%Y-%m-%d-%H%M%S).txt"

    {
        echo ""
        echo "╔════════════════════════════════════════════════════════════════════╗"
        echo "║  ${BOLD}DAILY STANDUP DIGEST${RESET}  ${DIM}$(date '+%A, %B %d, %Y')${RESET}                    ║"
        echo "╚════════════════════════════════════════════════════════════════════╝"
        echo ""

        # Yesterday's summary
        echo "${CYAN}${BOLD}YESTERDAY'S ACCOMPLISHMENTS${RESET}"
        echo "──────────────────────────────────────────"
        if [[ -f "$EVENTS_FILE" ]]; then
            local now_epoch
            now_epoch="$(now_epoch)"
            local cutoff=$((now_epoch - SECONDS_24H))

            local commits=0
            local prs=0
            local tests_passed=0
            local tests_failed=0

            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local ts_epoch
                ts_epoch=$(echo "$line" | jq -r '.ts_epoch // 0' 2>/dev/null || echo 0)

                if [[ "$ts_epoch" -lt "$cutoff" ]]; then
                    continue
                fi

                local event_type
                event_type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null || true)

                case "$event_type" in
                    pipeline_commit)  commits=$((commits + 1)) ;;
                    pipeline_pr)      prs=$((prs + 1)) ;;
                    test_pass)        tests_passed=$((tests_passed + 1)) ;;
                    test_fail)        tests_failed=$((tests_failed + 1)) ;;
                esac
            done < "$EVENTS_FILE"

            echo "  • ${commits} commits"
            echo "  • ${prs} PRs created/merged"
            echo "  • ${tests_passed} tests passed"
            if [[ "$tests_failed" -gt 0 ]]; then
                echo "  • ${RED}${tests_failed} tests failed${RESET}"
            fi
        else
            echo "  No events recorded yet"
        fi
        echo ""

        # Today's focus
        echo "${CYAN}${BOLD}TODAY'S FOCUS${RESET}"
        echo "──────────────────────────────────────────"
        if [[ -f "$DAEMON_STATE" ]]; then
            local active_jobs
            active_jobs=$(jq -r '.active_jobs // []' "$DAEMON_STATE" 2>/dev/null | jq length)
            local queued
            queued=$(jq -r '.queued // []' "$DAEMON_STATE" 2>/dev/null | jq length)

            echo "  • ${CYAN}${active_jobs}${RESET} active pipelines"
            echo "  • ${YELLOW}${queued}${RESET} queued issues"

            if [[ "$active_jobs" -gt 0 ]]; then
                echo ""
                echo "  Active Issues:"
                jq -r '.active_jobs[] | "    → Issue #\(.issue_number): \(.title // "untitled")"' "$DAEMON_STATE" 2>/dev/null | head -3
                if [[ "$active_jobs" -gt 3 ]]; then
                    echo "    ... and more"
                fi
            fi
        else
            echo "  No daemon activity"
        fi
        echo ""

        # Blockers
        echo "${CYAN}${BOLD}BLOCKERS & RISKS${RESET}"
        echo "──────────────────────────────────────────"
        local blocker_count=0

        if [[ -d "$HEARTBEATS_DIR" ]]; then
            local now_epoch
            now_epoch="$(now_epoch)"

            for hb_file in "${HEARTBEATS_DIR}"/*.json; do
                [[ ! -f "$hb_file" ]] && continue

                local updated_at
                updated_at=$(jq -r '.updated_at' "$hb_file" 2>/dev/null || true)
                [[ -z "$updated_at" || "$updated_at" == "null" ]] && continue

                local hb_epoch
                hb_epoch="$(iso_to_epoch "$updated_at")"
                local age=$((now_epoch - hb_epoch))

                if [[ "$age" -gt 300 ]]; then
                    local job_id
                    job_id="$(basename "$hb_file" .json)"
                    echo "  ${RED}✗${RESET} Stale agent: ${job_id} (${age}s silent)"
                    blocker_count=$((blocker_count + 1))
                fi
            done
        fi

        if [[ "$blocker_count" -eq 0 ]]; then
            echo "  ${GREEN}✓ No critical blockers${RESET}"
        fi
        echo ""

        # System health
        echo "${CYAN}${BOLD}SYSTEM HEALTH${RESET}"
        echo "──────────────────────────────────────────"

        local daemon_running="false"
        if [[ -f "${HOME}/.shipwright/daemon.pid" ]]; then
            local daemon_pid
            daemon_pid=$(cat "${HOME}/.shipwright/daemon.pid" 2>/dev/null || true)
            if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
                daemon_running="true"
            fi
        fi

        if [[ "$daemon_running" == "true" ]]; then
            echo "  ${GREEN}✓${RESET} Daemon running"
        else
            echo "  ${RED}✗${RESET} Daemon not running"
        fi

        local hb_count=0
        [[ -d "$HEARTBEATS_DIR" ]] && hb_count=$(find "$HEARTBEATS_DIR" -name "*.json" -type f 2>/dev/null | wc -l || true)
        echo "  • ${hb_count} active agents"

        echo ""
        echo "─────────────────────────────────────────"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo ""

    } | tee "$report_file"

    success "Full digest saved to ${report_file}"
}

# ─── Notify via Webhook (Slack-compatible) ──────────────────────────────────
cmd_notify() {
    local webhook_url="${1:-}"
    local message_file="${2:-}"

    if [[ -z "$webhook_url" ]]; then
        error "Usage: shipwright standup notify <webhook_url> [message_file]"
        exit 1
    fi

    if [[ -z "$message_file" ]]; then
        # Generate a digest
        message_file=$(mktemp)
        cmd_digest > "$message_file" 2>&1 || true
    fi

    if [[ ! -f "$message_file" ]]; then
        error "Message file not found: $message_file"
        exit 1
    fi

    # Read message and format for Slack
    local text
    text=$(cat "$message_file" | head -100)

    # Build JSON payload
    local payload
    payload=$(jq -n \
        --arg text "$(printf '%s' "$text")" \
        '{
            text: "Daily Standup",
            blocks: [
                {
                    type: "section",
                    text: {
                        type: "mrkdwn",
                        text: $text
                    }
                }
            ]
        }')

    if command -v curl &>/dev/null; then
        if curl -s -X POST -H 'Content-type: application/json' \
            --data "$payload" "$webhook_url" &>/dev/null; then
            success "Standup delivered to webhook"
        else
            error "Failed to deliver standup to webhook"
            return 1
        fi
    else
        error "curl not found, cannot send webhook"
        return 1
    fi
}

# ─── List Past Standups ──────────────────────────────────────────────────────
cmd_history() {
    ensure_dirs

    info "Past Standup Reports:"
    echo ""

    if [[ -d "$STANDUP_DIR" ]]; then
        ls -lhT "$STANDUP_DIR"/*.txt 2>/dev/null | tail -20 || warn "No reports found"
    else
        warn "No standup history yet"
    fi
}

# ─── Schedule Automatic Standups ────────────────────────────────────────────
cmd_schedule() {
    local time="${1:-09:00}"

    info "Setting up daily standup at ${time}..."

    # Validate time format (HH:MM)
    if ! [[ "$time" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
        error "Invalid time format. Use HH:MM (24-hour format)"
        exit 1
    fi

    ensure_dirs

    # Create a wrapper script for cron
    local cron_script="${STANDUP_DIR}/run-standup.sh"
    {
        echo "#!/usr/bin/env bash"
        echo "set -euo pipefail"
        echo "SHIPWRIGHT_SCRIPTS=\"\${1:-${SCRIPT_DIR}}\""
        echo "cd \"\$SHIPWRIGHT_SCRIPTS/..\""
        echo "\"${SCRIPT_DIR}/sw-standup.sh\" digest > /dev/null 2>&1"
        echo "# Uncomment to send to Slack:"
        echo "# \"${SCRIPT_DIR}/sw-standup.sh\" notify \"\${SLACK_WEBHOOK_URL}\" >> \"${STANDUP_DIR}/notify.log\" 2>&1"
    } > "$cron_script"

    chmod +x "$cron_script"

    # Install cron job or launchd plist on macOS
    if [[ "$(uname)" == "Darwin" ]]; then
        # Create launchd plist
        local plist="${HOME}/Library/LaunchAgents/com.shipwright.standup.plist"

        {
            echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            echo "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
            echo "<plist version=\"1.0\">"
            echo "<dict>"
            echo "  <key>Label</key>"
            echo "  <string>com.shipwright.standup</string>"
            echo "  <key>ProgramArguments</key>"
            echo "  <array>"
            echo "    <string>${cron_script}</string>"
            echo "    <string>${SCRIPT_DIR}</string>"
            echo "  </array>"
            echo "  <key>StartCalendarInterval</key>"
            echo "  <dict>"
            echo "    <key>Hour</key>"
            echo "    <integer>${time%%:*}</integer>"
            echo "    <key>Minute</key>"
            echo "    <integer>${time##*:}</integer>"
            echo "  </dict>"
            echo "  <key>StandardErrorPath</key>"
            echo "  <string>${STANDUP_DIR}/launchd.log</string>"
            echo "  <key>StandardOutPath</key>"
            echo "  <string>${STANDUP_DIR}/launchd.log</string>"
            echo "</dict>"
            echo "</plist>"
        } > "$plist"

        success "Scheduled daily standup at ${time} (launchd)"
        info "To activate: launchctl load ${plist}"
        info "To deactivate: launchctl unload ${plist}"
    else
        # Linux: add to crontab
        local hour="${time%%:*}"
        local minute="${time##*:}"
        local cron_entry="${minute} ${hour} * * * bash \"${cron_script}\" \"${SCRIPT_DIR}\" >> \"${STANDUP_DIR}/cron.log\" 2>&1"

        warn "Please add this line to your crontab:"
        echo ""
        echo "    ${cron_entry}"
        echo ""
    fi
}

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright Standup${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright standup <command> [options]"
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo -e "    ${CYAN}run${RESET}          Generate and display standup now"
    echo -e "    ${CYAN}digest${RESET}      Full formatted standup digest"
    echo -e "    ${CYAN}yesterday${RESET}    Summarize last 24 hours of work"
    echo -e "    ${CYAN}today${RESET}        Show today's planned work"
    echo -e "    ${CYAN}blockers${RESET}     Identify current blockers and risks"
    echo -e "    ${CYAN}velocity${RESET}     Sprint velocity and burn-down metrics"
    echo -e "    ${CYAN}history${RESET}      List past standup reports"
    echo -e "    ${CYAN}notify${RESET}       Send standup to webhook (Slack-compatible)"
    echo -e "    ${CYAN}schedule${RESET}     Set daily standup time (cron/launchd)"
    echo -e "    ${CYAN}help${RESET}         Show this help message"
    echo ""
    echo -e "  ${BOLD}NOTIFY OPTIONS${RESET}"
    echo -e "    shipwright standup notify <webhook_url> [message_file]"
    echo ""
    echo -e "  ${BOLD}SCHEDULE OPTIONS${RESET}"
    echo -e "    shipwright standup schedule [HH:MM]     ${DIM}(default: 09:00)${RESET}"
    echo ""
    echo -e "  ${BOLD}EXAMPLES${RESET}"
    echo -e "    ${DIM}# Daily standup now${RESET}"
    echo -e "    shipwright standup digest"
    echo ""
    echo -e "    ${DIM}# Send to Slack webhook${RESET}"
    echo -e "    shipwright standup notify https://hooks.slack.com/..."
    echo ""
    echo -e "    ${DIM}# Schedule for 9:30 AM daily${RESET}"
    echo -e "    shipwright standup schedule 09:30"
    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        run|digest)
            cmd_digest
            ;;
        yesterday)
            cmd_yesterday
            ;;
        today)
            cmd_today
            ;;
        blockers)
            cmd_blockers
            ;;
        velocity|metrics)
            cmd_velocity
            ;;
        history)
            cmd_history
            ;;
        notify)
            cmd_notify "$@"
            ;;
        schedule)
            cmd_schedule "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
