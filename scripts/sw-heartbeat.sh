#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright heartbeat — File-based agent heartbeat protocol             ║
# ║  Write · Check · List · Clear heartbeats for autonomous agents          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ─── Constants ──────────────────────────────────────────────────────────────
HEARTBEAT_DIR="$HOME/.shipwright/heartbeats"

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ─── Ensure heartbeat directory exists ──────────────────────────────────────
ensure_dir() {
    mkdir -p "$HEARTBEAT_DIR"
}

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright Heartbeat${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright heartbeat <command> [options]"
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo -e "    ${CYAN}write${RESET} <job-id>    Write/update heartbeat for a job"
    echo -e "    ${CYAN}check${RESET} <job-id>    Check if a job is alive (exit 0) or stale (exit 1)"
    echo -e "    ${CYAN}list${RESET}              List all active heartbeats as JSON"
    echo -e "    ${CYAN}clear${RESET} <job-id>    Remove heartbeat file for a job"
    echo ""
    echo -e "  ${BOLD}WRITE OPTIONS${RESET}"
    echo -e "    --pid <pid>          Process ID (default: current PID)"
    echo -e "    --issue <num>        Issue number"
    echo -e "    --stage <stage>      Pipeline stage name"
    echo -e "    --iteration <n>      Build iteration number"
    echo -e "    --activity <desc>    Description of current activity"
    echo ""
    echo -e "  ${BOLD}CHECK OPTIONS${RESET}"
    echo -e "    --timeout <secs>     Staleness threshold (default: 120)"
    echo ""
    echo -e "  ${BOLD}EXAMPLES${RESET}"
    echo -e "    ${DIM}# Agent writes heartbeat every 30s${RESET}"
    echo -e "    shipwright heartbeat write job-42 --stage build --iteration 3 --activity \"Running tests\""
    echo ""
    echo -e "    ${DIM}# Daemon checks if agent is alive${RESET}"
    echo -e "    shipwright heartbeat check job-42 --timeout 120"
    echo ""
    echo -e "    ${DIM}# Dashboard lists all heartbeats${RESET}"
    echo -e "    shipwright heartbeat list"
    echo ""
}

# ─── Write Heartbeat ───────────────────────────────────────────────────────
cmd_write() {
    local job_id="${1:-}"
    if [[ -z "$job_id" ]]; then
        error "Usage: shipwright heartbeat write <job-id> [options]"
        exit 1
    fi
    shift

    local pid="$$"
    local issue=""
    local stage=""
    local iteration=""
    local activity=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pid)       pid="${2:-}"; shift 2 ;;
            --issue)     issue="${2:-}"; shift 2 ;;
            --stage)     stage="${2:-}"; shift 2 ;;
            --iteration) iteration="${2:-}"; shift 2 ;;
            --activity)  activity="${2:-}"; shift 2 ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    # Collect resource metrics from the process
    local memory_mb=0
    local cpu_pct=0

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        local rss_kb
        rss_kb="$(ps -o rss= -p "$pid" 2>/dev/null || true)"
        rss_kb="$(echo "$rss_kb" | tr -d ' ')"
        if [[ -n "$rss_kb" && "$rss_kb" =~ ^[0-9]+$ ]]; then
            memory_mb=$((rss_kb / 1024))
        fi

        local cpu_raw
        cpu_raw="$(ps -o %cpu= -p "$pid" 2>/dev/null || true)"
        cpu_raw="$(echo "$cpu_raw" | tr -d ' ')"
        if [[ -n "$cpu_raw" ]]; then
            # Truncate to integer for JSON safety
            cpu_pct="${cpu_raw%%.*}"
            cpu_pct="${cpu_pct:-0}"
        fi
    fi

    ensure_dir

    local tmp_file
    tmp_file="$(mktemp "${HEARTBEAT_DIR}/.tmp.XXXXXX")"

    # Build JSON with jq for proper escaping
    jq -n \
        --argjson pid "$pid" \
        --arg issue "$issue" \
        --arg stage "$stage" \
        --arg iteration "$iteration" \
        --argjson memory_mb "$memory_mb" \
        --arg cpu_pct "$cpu_pct" \
        --arg last_activity "$activity" \
        --arg updated_at "$(now_iso)" \
        '{
            pid: $pid,
            issue: (if $issue == "" then null else ($issue | tonumber) end),
            stage: (if $stage == "" then null else $stage end),
            iteration: (if $iteration == "" then null else ($iteration | tonumber) end),
            memory_mb: $memory_mb,
            cpu_pct: ($cpu_pct | tonumber),
            last_activity: $last_activity,
            updated_at: $updated_at
        }' > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

    # Atomic write
    mv "$tmp_file" "${HEARTBEAT_DIR}/${job_id}.json"
}

# ─── Check Heartbeat ───────────────────────────────────────────────────────
cmd_check() {
    local job_id="${1:-}"
    if [[ -z "$job_id" ]]; then
        error "Usage: shipwright heartbeat check <job-id> [--timeout <secs>]"
        exit 1
    fi
    shift

    local timeout=120

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) timeout="${2:-120}"; shift 2 ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    local hb_file="${HEARTBEAT_DIR}/${job_id}.json"

    if [[ ! -f "$hb_file" ]]; then
        error "No heartbeat found for job: ${job_id}"
        return 1
    fi

    local updated_at
    updated_at="$(jq -r '.updated_at' "$hb_file" 2>/dev/null || true)"

    if [[ -z "$updated_at" || "$updated_at" == "null" ]]; then
        error "Invalid heartbeat file for job: ${job_id}"
        return 1
    fi

    # Convert ISO timestamp to epoch for comparison
    local hb_epoch now_epoch age_secs

    # macOS date -j -f vs GNU date -d (TZ=UTC since timestamps are UTC)
    if TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s &>/dev/null; then
        hb_epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null)"
    else
        hb_epoch="$(date -d "$updated_at" +%s 2>/dev/null || echo 0)"
    fi

    now_epoch="$(date +%s)"
    age_secs=$((now_epoch - hb_epoch))

    if [[ "$age_secs" -le "$timeout" ]]; then
        success "Job ${job_id} alive (${age_secs}s ago)"
        return 0
    else
        warn "Job ${job_id} stale (${age_secs}s ago, timeout: ${timeout}s)"
        return 1
    fi
}

# ─── List Heartbeats ───────────────────────────────────────────────────────
cmd_list() {
    ensure_dir

    local result="["
    local first=true

    for hb_file in "${HEARTBEAT_DIR}"/*.json; do
        # Handle no matches (glob returns literal pattern)
        if [[ ! -f "$hb_file" ]]; then
            continue
        fi

        local job_id
        job_id="$(basename "$hb_file" .json)"

        local content
        content="$(jq -c --arg job_id "$job_id" '. + {job_id: $job_id}' "$hb_file" 2>/dev/null || true)"

        if [[ -z "$content" ]]; then
            continue
        fi

        if [[ "$first" == "true" ]]; then
            first=false
        else
            result="${result},"
        fi
        result="${result}${content}"
    done

    result="${result}]"
    echo "$result" | jq '.'
}

# ─── Clear Heartbeat ───────────────────────────────────────────────────────
cmd_clear() {
    local job_id="${1:-}"
    if [[ -z "$job_id" ]]; then
        error "Usage: shipwright heartbeat clear <job-id>"
        exit 1
    fi

    local hb_file="${HEARTBEAT_DIR}/${job_id}.json"

    if [[ -f "$hb_file" ]]; then
        rm -f "$hb_file"
        success "Cleared heartbeat for job: ${job_id}"
    else
        warn "No heartbeat found for job: ${job_id}"
    fi
}

# ─── Command Router ────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        write)              cmd_write "$@" ;;
        check)              cmd_check "$@" ;;
        list)               cmd_list "$@" ;;
        clear)              cmd_clear "$@" ;;
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
