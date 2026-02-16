#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-reaper.sh — Automatic tmux pane cleanup when agents exit           ║
# ║                                                                          ║
# ║  Detects agent panes where the Claude process has exited (shell is      ║
# ║  idle), kills them after a grace period, and cleans up associated       ║
# ║  team/task directories when no panes remain.                            ║
# ║                                                                          ║
# ║  Modes:                                                                  ║
# ║    shipwright reaper              One-shot scan, reap, exit              ║
# ║    shipwright reaper --watch      Continuous loop (default: 5s)         ║
# ║    shipwright reaper --dry-run    Preview what would be reaped          ║
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

# ─── Defaults ──────────────────────────────────────────────────────────────
WATCH=false
DRY_RUN=false
VERBOSE=false
INTERVAL=5
GRACE_PERIOD=15
LOG_FILE=""
PID_FILE="${HOME}/.sw-reaper.pid"

# ─── Parse Args ────────────────────────────────────────────────────────────
show_help() {
    echo -e "${CYAN}${BOLD}shipwright reaper${RESET} — Automatic pane cleanup when agents exit"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  shipwright reaper                     ${DIM}# One-shot: scan, reap, exit${RESET}"
    echo -e "  shipwright reaper --watch             ${DIM}# Continuous loop (5s interval)${RESET}"
    echo -e "  shipwright reaper --dry-run           ${DIM}# Preview what would be reaped${RESET}"
    echo -e "  shipwright reaper --dry-run --verbose ${DIM}# Show all panes and their status${RESET}"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  --watch              Run continuously instead of one-shot"
    echo -e "  --dry-run            Show what would be reaped without doing it"
    echo -e "  --verbose            Show details for every pane scanned"
    echo -e "  --interval <sec>     Seconds between watch scans (default: ${INTERVAL})"
    echo -e "  --grace-period <sec> Idle seconds before reaping (default: ${GRACE_PERIOD})"
    echo -e "  --log-file <path>    Append reaper activity to a log file"
    echo -e "  --help, -h           Show this help"
    echo ""
    echo -e "${BOLD}DETECTION ALGORITHM${RESET}"
    echo -e "  ${DIM}1. pane_dead == 1              → REAP (zombie pane)${RESET}"
    echo -e "  ${DIM}2. command ∉ (bash,zsh,fish,sh) → SKIP (agent still running)${RESET}"
    echo -e "  ${DIM}3. pane_title is empty          → SKIP (not initialized)${RESET}"
    echo -e "  ${DIM}4. pane_idle < grace_period      → SKIP (may be starting)${RESET}"
    echo -e "  ${DIM}5. All checks passed             → REAP (agent exited)${RESET}"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright reaper --watch --interval 10 --grace-period 30${RESET}"
    echo -e "  ${DIM}shipwright reaper --watch --log-file ~/.sw-reaper.log &${RESET}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch|-w)      WATCH=true; shift ;;
        --dry-run|-n)    DRY_RUN=true; shift ;;
        --verbose|-v)    VERBOSE=true; shift ;;
        --interval)      INTERVAL="${2:?--interval requires a value}"; shift 2 ;;
        --grace-period)  GRACE_PERIOD="${2:?--grace-period requires a value}"; shift 2 ;;
        --log-file)      LOG_FILE="${2:?--log-file requires a path}"; shift 2 ;;
        --help|-h)       show_help; exit 0 ;;
        *)               error "Unknown option: $1"; echo ""; show_help; exit 1 ;;
    esac
done

# ─── Logging ───────────────────────────────────────────────────────────────
log() {
    local msg="$1"
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE"
    fi
}

# ─── PID file management (watch mode) ─────────────────────────────────────
acquire_pid_lock() {
    if [[ -f "$PID_FILE" ]]; then
        local existing_pid
        existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            warn "Reaper already running (PID ${existing_pid}). Stop it first or remove ${PID_FILE}"
            exit 1
        fi
        # Stale PID file — clean it up
        rm -f "$PID_FILE"
    fi
    echo $$ > "$PID_FILE"
}

release_pid_lock() {
    rm -f "$PID_FILE"
}

# ─── tmux format string (reused from sw-ps.sh) ──────────────────────────
# Fields: window_name | pane_title | pane_pid | pane_current_command | pane_active | pane_idle | pane_dead | pane_id
# Uses #{pane_id} (%0, %1, ...) instead of #{pane_index} — IDs are stable
# regardless of pane-base-index setting, preventing wrong-pane kills.
FORMAT='#{window_name}|#{pane_title}|#{pane_pid}|#{pane_current_command}|#{pane_active}|#{pane_idle}|#{pane_dead}|#{pane_id}'

# ─── Detection: should this pane be reaped? ───────────────────────────────
# Returns 0 (reap) or 1 (skip), and sets REAP_REASON
REAP_REASON=""

should_reap() {
    local pane_title="$1"
    local cmd="$2"
    local pane_idle="$3"
    local pane_dead="$4"

    # 1. Zombie pane — reap immediately
    if [[ "$pane_dead" == "1" ]]; then
        REAP_REASON="zombie (pane_dead=1)"
        return 0
    fi

    # 2. Agent still running — skip
    case "$cmd" in
        claude|node|npm|npx|python|python3)
            REAP_REASON="agent running (${cmd})"
            return 1
            ;;
    esac

    # 3. Pane hasn't been initialized — skip
    if [[ -z "$pane_title" ]]; then
        REAP_REASON="no pane title (not initialized)"
        return 1
    fi

    # 4. Shell is present but hasn't been idle long enough — skip
    case "$cmd" in
        bash|zsh|fish|sh)
            if [[ "$pane_idle" -lt "$GRACE_PERIOD" ]]; then
                REAP_REASON="idle ${pane_idle}s < grace ${GRACE_PERIOD}s"
                return 1
            fi
            REAP_REASON="idle shell (${cmd}, ${pane_idle}s > ${GRACE_PERIOD}s grace)"
            return 0
            ;;
    esac

    # 5. Unknown command, not idle long enough — skip
    if [[ "$pane_idle" -lt "$GRACE_PERIOD" ]]; then
        REAP_REASON="unknown cmd (${cmd}), idle ${pane_idle}s < grace ${GRACE_PERIOD}s"
        return 1
    fi

    REAP_REASON="idle process (${cmd}, ${pane_idle}s)"
    return 0
}

# ─── Format idle time for display ─────────────────────────────────────────
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

# ─── Single scan pass ─────────────────────────────────────────────────────
scan_and_reap() {
    local reaped=0
    local skipped=0
    local scanned=0

    while IFS='|' read -r window_name pane_title pane_pid cmd pane_active pane_idle pane_dead pane_ref; do
        [[ -z "$window_name" ]] && continue

        # Only target claude-* windows
        echo "$window_name" | grep -qi "^claude" || continue
        scanned=$((scanned + 1))

        if should_reap "$pane_title" "$cmd" "$pane_idle" "$pane_dead"; then
            if $DRY_RUN; then
                echo -e "  ${YELLOW}○${RESET} Would reap: ${BOLD}${pane_title:-<untitled>}${RESET} ${DIM}(${pane_ref})${RESET} — ${REAP_REASON}"
            else
                tmux kill-pane -t "$pane_ref" 2>/dev/null && {
                    echo -e "  ${RED}✗${RESET} Reaped: ${BOLD}${pane_title:-<untitled>}${RESET} ${DIM}(${pane_ref})${RESET} — ${REAP_REASON}"
                    log "REAP pane=${pane_ref} title=${pane_title} reason=${REAP_REASON}"
                } || {
                    warn "  Could not kill pane: ${pane_ref}"
                }
            fi
            reaped=$((reaped + 1))
        else
            if $VERBOSE; then
                echo -e "  ${DIM}  skip: ${pane_title:-<untitled>} (${pane_ref}) — ${REAP_REASON}${RESET}"
            fi
            skipped=$((skipped + 1))
        fi
    done < <(tmux list-panes -a -F "$FORMAT" 2>/dev/null | sort -t'|' -k1,1 -k2,2 || true)

    # Return values via globals (bash doesn't have multi-return)
    SCAN_REAPED=$reaped
    SCAN_SKIPPED=$skipped
    SCAN_SCANNED=$scanned
}

# ─── Clean up empty windows ───────────────────────────────────────────────
cleanup_empty_windows() {
    local killed=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local win_target win_name pane_count
        win_target="$(echo "$line" | cut -d' ' -f1)"
        win_name="$(echo "$line" | cut -d' ' -f2)"
        pane_count="$(echo "$line" | cut -d' ' -f3)"

        echo "$win_name" | grep -qi "^claude" || continue

        if [[ "$pane_count" -eq 0 ]]; then
            if $DRY_RUN; then
                echo -e "  ${YELLOW}○${RESET} Would kill empty window: ${BOLD}${win_name}${RESET}"
            else
                tmux kill-window -t "$win_target" 2>/dev/null && {
                    echo -e "  ${RED}✗${RESET} Killed empty window: ${BOLD}${win_name}${RESET}"
                    log "KILL_WINDOW window=${win_name} target=${win_target}"
                    killed=$((killed + 1))
                } || true
            fi
        fi
    done < <(tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name} #{window_panes}' 2>/dev/null || true)

    WINDOWS_KILLED=$killed
}

# ─── Clean up team/task dirs when no matching windows remain ──────────────
cleanup_team_dirs() {
    local cleaned=0

    local teams_dir="${HOME}/.claude/teams"
    local tasks_dir="${HOME}/.claude/tasks"

    [[ -d "$teams_dir" ]] || return 0

    while IFS= read -r team_dir; do
        [[ -z "$team_dir" ]] && continue
        local team_name
        team_name="$(basename "$team_dir")"

        # Check if ANY claude-{team}* window still exists
        local has_windows=false
        while IFS= read -r win_name; do
            if echo "$win_name" | grep -qi "^claude-${team_name}"; then
                has_windows=true
                break
            fi
        done < <(tmux list-windows -a -F '#{window_name}' 2>/dev/null || true)

        if ! $has_windows; then
            if $DRY_RUN; then
                echo -e "  ${YELLOW}○${RESET} Would remove team dir: ${BOLD}${team_name}/${RESET}"
                if [[ -d "${tasks_dir}/${team_name}" ]]; then
                    echo -e "  ${YELLOW}○${RESET} Would remove task dir: ${BOLD}${team_name}/${RESET}"
                fi
            else
                rm -rf "$team_dir" && {
                    echo -e "  ${RED}✗${RESET} Removed team dir: ${BOLD}${team_name}/${RESET}"
                    log "CLEAN_TEAM team=${team_name}"
                    cleaned=$((cleaned + 1))
                }
                if [[ -d "${tasks_dir}/${team_name}" ]]; then
                    rm -rf "${tasks_dir}/${team_name}" && {
                        echo -e "  ${RED}✗${RESET} Removed task dir: ${BOLD}${team_name}/${RESET}"
                        log "CLEAN_TASKS team=${team_name}"
                    }
                fi
            fi
        fi
    done < <(find "$teams_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    DIRS_CLEANED=$cleaned
}

# ─── One-shot mode ─────────────────────────────────────────────────────────
run_oneshot() {
    echo ""
    if $DRY_RUN; then
        info "Reaper scan ${DIM}(dry-run, grace: ${GRACE_PERIOD}s)${RESET}"
    else
        info "Reaper scan ${DIM}(grace: ${GRACE_PERIOD}s)${RESET}"
    fi
    echo ""

    echo -e "${BOLD}Agent Panes${RESET}"
    echo -e "${DIM}────────────────────────────────────────${RESET}"

    scan_and_reap

    if [[ $SCAN_SCANNED -eq 0 ]]; then
        echo -e "  ${DIM}No Claude team panes found.${RESET}"
    fi

    echo ""
    echo -e "${BOLD}Empty Windows${RESET}"
    echo -e "${DIM}────────────────────────────────────────${RESET}"

    WINDOWS_KILLED=0
    if [[ $SCAN_REAPED -gt 0 ]] || $DRY_RUN; then
        cleanup_empty_windows
    fi

    if [[ $WINDOWS_KILLED -eq 0 ]] && ! $DRY_RUN; then
        echo -e "  ${DIM}None.${RESET}"
    fi

    echo ""
    echo -e "${BOLD}Team Directories${RESET}"
    echo -e "${DIM}────────────────────────────────────────${RESET}"

    DIRS_CLEANED=0
    cleanup_team_dirs

    if [[ $DIRS_CLEANED -eq 0 ]] && ! $DRY_RUN; then
        echo -e "  ${DIM}None to clean.${RESET}"
    fi

    # Summary
    echo ""
    echo -e "${DIM}────────────────────────────────────────${RESET}"
    if $DRY_RUN; then
        if [[ $SCAN_REAPED -gt 0 ]]; then
            warn "Would reap ${SCAN_REAPED} pane(s). Run without --dry-run to execute."
        else
            success "All ${SCAN_SCANNED} pane(s) are healthy. Nothing to reap."
        fi
    else
        if [[ $SCAN_REAPED -gt 0 ]]; then
            success "Reaped ${SCAN_REAPED} pane(s), skipped ${SCAN_SKIPPED}."
        else
            success "All ${SCAN_SCANNED} pane(s) are healthy. Nothing to reap."
        fi
    fi
    echo ""
}

# ─── Watch mode ────────────────────────────────────────────────────────────
run_watch() {
    acquire_pid_lock

    # Clean up on exit
    trap 'release_pid_lock; echo ""; info "Reaper stopped."; exit 0' SIGTERM SIGINT EXIT

    info "Reaper watching ${DIM}(interval: ${INTERVAL}s, grace: ${GRACE_PERIOD}s, PID: $$)${RESET}"
    log "START interval=${INTERVAL} grace=${GRACE_PERIOD} pid=$$"
    echo ""

    while true; do
        scan_and_reap

        if [[ $SCAN_REAPED -gt 0 ]]; then
            # After reaping, clean up empty windows and dirs
            cleanup_empty_windows
            DIRS_CLEANED=0
            cleanup_team_dirs
            log "SCAN reaped=${SCAN_REAPED} skipped=${SCAN_SKIPPED} windows_killed=${WINDOWS_KILLED} dirs_cleaned=${DIRS_CLEANED}"
        elif $VERBOSE; then
            echo -e "${DIM}  [$(date '+%H:%M:%S')] scanned ${SCAN_SCANNED}, all healthy${RESET}"
        fi

        sleep "$INTERVAL"
    done
}

# ─── Main ──────────────────────────────────────────────────────────────────
if $WATCH; then
    run_watch
else
    run_oneshot
fi
