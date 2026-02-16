#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-ps.sh — Show running agent process status                          ║
# ║                                                                          ║
# ║  Displays a table of agents running in claude-* tmux windows with       ║
# ║  PID, status, idle time, and pane references.                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="2.2.2"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ─── Format idle time ───────────────────────────────────────────────────────
format_idle() {
    local seconds="$1"
    if [[ "$seconds" -lt 60 ]]; then
        echo "${seconds}s"
    elif [[ "$seconds" -lt 3600 ]]; then
        echo "$((seconds / 60))m $((seconds % 60))s"
    else
        echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
    fi
}

# ─── Determine status from command and idle time ─────────────────────────────
get_status() {
    local cmd="$1"
    local idle="$2"
    local is_dead="${3:-0}"

    if [[ "$is_dead" == "1" ]]; then
        echo "dead"
        return
    fi

    # Active process patterns — claude, node, npm are likely active agents
    case "$cmd" in
        claude|node|npm|npx)
            if [[ "$idle" -gt 300 ]]; then
                echo "idle"
            else
                echo "running"
            fi
            ;;
        bash|zsh|fish|sh)
            # Shell prompt — agent likely finished or hasn't started
            echo "idle"
            ;;
        *)
            if [[ "$idle" -gt 300 ]]; then
                echo "idle"
            else
                echo "running"
            fi
            ;;
    esac
}

status_display() {
    local status="$1"
    case "$status" in
        running) echo -e "${GREEN}${BOLD}running${RESET}" ;;
        idle)    echo -e "${YELLOW}idle${RESET}" ;;
        dead)    echo -e "${RED}${BOLD}dead${RESET}" ;;
        *)       echo -e "${DIM}${status}${RESET}" ;;
    esac
}

# ─── Header ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}  Shipwright — Process Status${RESET}"
echo -e "${DIM}  $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# ─── Collect pane data ──────────────────────────────────────────────────────
HAS_AGENTS=false
CURRENT_WINDOW=""

# Format strings for tmux:
# window_name | pane_title | pane_pid | pane_current_command | pane_active | pane_idle | pane_dead | pane_id
# Uses #{pane_id} instead of #{pane_index} — stable regardless of pane-base-index
FORMAT='#{window_name}|#{pane_title}|#{pane_pid}|#{pane_current_command}|#{pane_active}|#{pane_idle}|#{pane_dead}|#{pane_id}'

while IFS='|' read -r window_name pane_title pane_pid cmd pane_active pane_idle pane_dead pane_ref; do
    [[ -z "$window_name" ]] && continue

    # Only show claude-* windows
    echo "$window_name" | grep -qi "^claude" || continue
    HAS_AGENTS=true

    # Print team header when window changes
    if [[ "$window_name" != "$CURRENT_WINDOW" ]]; then
        if [[ -n "$CURRENT_WINDOW" ]]; then
            echo ""
        fi
        echo -e "${PURPLE}${BOLD}  ${window_name}${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
        printf "  ${DIM}%-20s %-8s %-10s %-10s %s${RESET}\n" "AGENT" "PID" "STATUS" "IDLE" "PANE"
        CURRENT_WINDOW="$window_name"
    fi

    # Determine status
    local_status="$(get_status "$cmd" "$pane_idle" "$pane_dead")"
    local_idle_fmt="$(format_idle "$pane_idle")"

    # Active pane indicator
    active_marker=""
    if [[ "$pane_active" == "1" ]]; then
        active_marker=" ${CYAN}●${RESET}"
    fi

    # Agent display name
    agent_name="${pane_title:-${cmd}}"

    printf "  %-20s %-8s " "$agent_name" "$pane_pid"
    status_display "$local_status"
    # Re-align after color codes in status
    printf "     %-10s %s" "$local_idle_fmt" "$pane_ref"
    echo -e "${active_marker}"

done < <(tmux list-panes -a -F "$FORMAT" 2>/dev/null | sort -t'|' -k1,1 -k2,2 || true)

if ! $HAS_AGENTS; then
    echo -e "  ${DIM}No Claude team windows found.${RESET}"
    echo -e "  ${DIM}Start one with: ${CYAN}shipwright session <name>${RESET}"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

if $HAS_AGENTS; then
    # Quick counts
    running=0
    idle=0
    dead=0
    total=0

    while IFS='|' read -r window_name _ _ cmd _ pane_idle pane_dead _; do
        echo "$window_name" | grep -qi "^claude" || continue
        total=$((total + 1))
        s="$(get_status "$cmd" "$pane_idle" "$pane_dead")"
        case "$s" in
            running) running=$((running + 1)) ;;
            idle)    idle=$((idle + 1)) ;;
            dead)    dead=$((dead + 1)) ;;
        esac
    done < <(tmux list-panes -a -F "$FORMAT" 2>/dev/null || true)

    echo -e "  ${GREEN}${running} running${RESET}  ${YELLOW}${idle} idle${RESET}  ${RED}${dead} dead${RESET}  ${DIM}(${total} total)${RESET}"
else
    echo -e "  ${DIM}No active agents.${RESET}"
fi
echo ""
