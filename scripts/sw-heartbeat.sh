#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright heartbeat — File-based agent heartbeat protocol             ║
# ║  Write · Check · List · Clear heartbeats for autonomous agents          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="4.0.0"
# shellcheck source=lib/bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"

# SQLite persistence (DB as primary read path)
# shellcheck source=sw-db.sh
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"
# ─── Constants ──────────────────────────────────────────────────────────────
HEARTBEAT_DIR="$HOME/.shipwright/heartbeats"

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
    tmp_file="$(mktemp "${HEARTBEAT_DIR}/.tmp.XXXXXX")" || { error "mktemp failed for heartbeat"; return 1; }

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
    mv "$tmp_file" "${HEARTBEAT_DIR}/${job_id}.json" || { rm -f "$tmp_file"; return 1; }

    # Dual-write to DB when available
    if type db_record_heartbeat >/dev/null 2>&1 && db_available 2>/dev/null; then
        db_record_heartbeat "$job_id" "$pid" "${issue:-0}" "$stage" "${iteration:-0}" "$activity" "$memory_mb" 2>/dev/null || true
    fi
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

    # Try DB first when available
    if type db_list_heartbeats >/dev/null 2>&1 && db_available 2>/dev/null; then
        local hb_json
        hb_json=$(db_list_heartbeats 2>/dev/null | jq -r --arg id "$job_id" '.[] | select(.job_id == $id) | .updated_at' 2>/dev/null || true)
        if [[ -n "$hb_json" ]]; then
            local updated_at="$hb_json"
            local hb_epoch now_epoch age_secs
            hb_epoch="$(date_to_epoch "$updated_at" || echo 0)"
            now_epoch="$(date +%s)"
            age_secs=$((now_epoch - hb_epoch))
            if [[ "$age_secs" -le "$timeout" ]]; then
                success "Job ${job_id} alive (${age_secs}s ago)"
                return 0
            else
                warn "Job ${job_id} stale (${age_secs}s ago, timeout: ${timeout}s)"
                return 1
            fi
        fi
    fi

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

    hb_epoch="$(date_to_epoch "$updated_at" || echo 0)"

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

    # Try DB first when available
    if type db_list_heartbeats >/dev/null 2>&1 && db_available 2>/dev/null; then
        local db_result
        db_result=$(db_list_heartbeats 2>/dev/null || echo "[]")
        if [[ -n "$db_result" ]] && echo "$db_result" | jq -e 'length > 0' >/dev/null 2>&1; then
            echo "$db_result" | jq -c '[.[] | . + {cpu_pct: 0}]' 2>/dev/null || echo "[]"
            return 0
        fi
    fi

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

    if type db_clear_heartbeat >/dev/null 2>&1 && db_available 2>/dev/null; then
        db_clear_heartbeat "$job_id" 2>/dev/null || true
    fi

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
