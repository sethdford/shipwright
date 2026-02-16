#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-logs.sh — View and search agent pane logs                          ║
# ║                                                                          ║
# ║  Captures tmux pane scrollback and provides log browsing/search.        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="2.2.0"
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

LOGS_DIR="$HOME/.shipwright/logs"

# ─── Intelligence Check ──────────────────────────────────────────────────
intelligence_available() {
    command -v claude &>/dev/null || return 1
    local config
    for config in "$(git rev-parse --show-toplevel 2>/dev/null)/.claude/daemon-config.json" \
                  "${HOME}/.shipwright/config.json"; do
        if [[ -f "$config" ]]; then
            local enabled
            enabled=$(jq -r '.intelligence.enabled // false' "$config" 2>/dev/null || echo "false")
            [[ "$enabled" == "true" ]] && return 0
        fi
    done
    return 1
}

# ─── Semantic Log Ranking ────────────────────────────────────────────────
# After grep results are collected, use Claude to rank by relevance,
# group by error type/stage, and highlight actionable entries.
semantic_rank_results() {
    local query="$1"
    local raw_results="$2"

    [[ -z "$raw_results" ]] && return 0

    # Truncate if too long to avoid overflowing Claude context
    local truncated
    truncated=$(echo "$raw_results" | head -200)

    local analysis
    analysis=$(claude --print "You are analyzing agent log search results. The user searched for: \"${query}\"

Here are the grep results:
${truncated}

Respond with:
1. MOST ACTIONABLE entries first (errors that need attention, failures with clear root causes)
2. Group by error type or pipeline stage
3. For each group, provide a one-line summary

Format your response as plain text suitable for terminal display. Use --- to separate groups. Be concise." 2>/dev/null || true)

    if [[ -n "$analysis" ]]; then
        echo ""
        echo -e "  ${PURPLE}${BOLD}Semantic Analysis${RESET} ${DIM}(intelligence-enhanced)${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
        echo "$analysis" | while IFS= read -r line; do
            echo -e "  $line"
        done
        echo ""
    fi
}

show_usage() {
    echo -e "${CYAN}${BOLD}shipwright logs${RESET} — View agent pane logs"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright logs${RESET}                              List available log directories"
    echo -e "  ${CYAN}shipwright logs${RESET} <team>                       Show logs for a team (captures live)"
    echo -e "  ${CYAN}shipwright logs${RESET} <team> ${DIM}--pane <agent>${RESET}         Show specific agent's log"
    echo -e "  ${CYAN}shipwright logs${RESET} <team> ${DIM}--follow${RESET}              Tail logs in real-time"
    echo -e "  ${CYAN}shipwright logs${RESET} <team> ${DIM}--grep <pattern>${RESET}      Search logs for a pattern"
    echo -e "  ${CYAN}shipwright logs${RESET} ${DIM}--capture${RESET}                    Capture all team pane scrollback now"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${DIM}--pane <name>${RESET}     Filter to a specific agent pane by title"
    echo -e "  ${DIM}--follow, -f${RESET}      Tail the most recent log file"
    echo -e "  ${DIM}--grep <pat>${RESET}      Search across log files with a pattern"
    echo -e "  ${DIM}--capture${RESET}         Capture current scrollback from all team panes"
    echo ""
}

# ─── Capture scrollback from all claude-* windows ────────────────────────────
capture_logs() {
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local captured=0

    while IFS='|' read -r session_window window_name pane_id pane_title; do
        [[ -z "$window_name" ]] && continue
        echo "$window_name" | grep -qi "claude" || continue

        # Sanitize names for filesystem
        local safe_window safe_title
        safe_window="$(echo "$window_name" | tr '/' '-')"
        safe_title="$(echo "${pane_title:-pane-$pane_id}" | tr '/' '-')"

        local log_dir="${LOGS_DIR}/${safe_window}"
        mkdir -p "$log_dir"

        local log_file="${log_dir}/${safe_title}-${timestamp}.log"
        tmux capture-pane -t "$pane_id" -pS - > "$log_file" 2>/dev/null || continue
        captured=$((captured + 1))
    done < <(tmux list-panes -a -F '#{session_name}:#{window_index}|#{window_name}|#{pane_id}|#{pane_title}' 2>/dev/null || true)

    if [[ $captured -gt 0 ]]; then
        success "Captured ${captured} pane(s) to ${LOGS_DIR}/"
    else
        warn "No Claude team panes found to capture"
    fi
}

# ─── List available logs ────────────────────────────────────────────────────
list_logs() {
    echo ""
    echo -e "${CYAN}${BOLD}  Agent Logs${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""

    if [[ ! -d "$LOGS_DIR" ]]; then
        echo -e "  ${DIM}No logs directory yet.${RESET}"
        echo -e "  ${DIM}Capture logs with: ${CYAN}shipwright logs --capture${RESET}"
        echo ""
        return
    fi

    local has_logs=false
    while IFS= read -r team_dir; do
        [[ -z "$team_dir" ]] && continue
        has_logs=true
        local team_name
        team_name="$(basename "$team_dir")"
        local file_count
        file_count="$(find "$team_dir" -name '*.log' -type f 2>/dev/null | wc -l | tr -d ' ')"
        local latest=""
        latest="$(find "$team_dir" -name '*.log' -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)"
        local latest_time=""
        if [[ -n "$latest" ]]; then
            latest_time="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$latest" 2>/dev/null || stat --format='%y' "$latest" 2>/dev/null | cut -d. -f1)"
        fi

        echo -e "  ${BLUE}●${RESET} ${BOLD}${team_name}${RESET}  ${DIM}${file_count} logs${RESET}"
        if [[ -n "$latest_time" ]]; then
            echo -e "    ${DIM}└─ latest: ${latest_time}${RESET}"
        fi
    done < <(find "$LOGS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    if ! $has_logs; then
        echo -e "  ${DIM}No log directories found.${RESET}"
        echo -e "  ${DIM}Capture logs with: ${CYAN}shipwright logs --capture${RESET}"
    fi
    echo ""
}

# ─── Show logs for a team ────────────────────────────────────────────────────
show_team_logs() {
    local team="$1"
    local pane_filter="${2:-}"
    local grep_pattern="${3:-}"
    local follow="${4:-false}"

    # Try exact match first, then prefix match on claude-*
    local team_dir="${LOGS_DIR}/${team}"
    if [[ ! -d "$team_dir" ]]; then
        team_dir="${LOGS_DIR}/claude-${team}"
    fi

    if [[ ! -d "$team_dir" ]]; then
        # Capture live first if no logs exist
        info "No saved logs for '${team}'. Capturing live scrollback..."
        capture_logs

        # Re-check
        team_dir="${LOGS_DIR}/${team}"
        [[ ! -d "$team_dir" ]] && team_dir="${LOGS_DIR}/claude-${team}"
        if [[ ! -d "$team_dir" ]]; then
            error "No team panes matching '${team}' found"
            exit 1
        fi
    fi

    local team_name
    team_name="$(basename "$team_dir")"

    echo ""
    echo -e "${CYAN}${BOLD}  Logs — ${team_name}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""

    # Build file list, optionally filtered by pane
    local log_files=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ -n "$pane_filter" ]]; then
            local base
            base="$(basename "$f")"
            echo "$base" | grep -qi "$pane_filter" || continue
        fi
        log_files+=("$f")
    done < <(find "$team_dir" -name '*.log' -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null)

    if [[ ${#log_files[@]} -eq 0 ]]; then
        if [[ -n "$pane_filter" ]]; then
            warn "No logs matching pane '${pane_filter}' in ${team_name}"
        else
            warn "No log files in ${team_name}"
        fi
        return
    fi

    # --follow: tail the most recent file
    if [[ "$follow" == "true" ]]; then
        local latest="${log_files[0]}"
        info "Tailing: $(basename "$latest")"
        echo -e "${DIM}  (Ctrl+C to stop)${RESET}"
        echo ""
        tail -f "$latest"
        return
    fi

    # --grep: search across all files
    if [[ -n "$grep_pattern" ]]; then
        info "Searching for '${grep_pattern}' in ${#log_files[@]} log file(s)..."
        echo ""
        local found=false
        local all_raw_matches=""
        for f in "${log_files[@]}"; do
            local matches
            matches="$(grep -n --color=always "$grep_pattern" "$f" 2>/dev/null || true)"
            if [[ -n "$matches" ]]; then
                found=true
                echo -e "  ${BLUE}──${RESET} ${BOLD}$(basename "$f")${RESET}"
                echo "$matches" | while IFS= read -r line; do
                    echo -e "    ${line}"
                done
                echo ""
                # Collect plain matches for semantic analysis
                local plain_matches
                plain_matches="$(grep -n "$grep_pattern" "$f" 2>/dev/null || true)"
                if [[ -n "$plain_matches" ]]; then
                    all_raw_matches+="=== $(basename "$f") ===
${plain_matches}

"
                fi
            fi
        done
        if ! $found; then
            warn "No matches for '${grep_pattern}'"
        fi

        # Semantic enhancement (intelligence-gated)
        if $found && intelligence_available; then
            semantic_rank_results "$grep_pattern" "$all_raw_matches"
        fi

        return
    fi

    # Default: list files then show the most recent
    info "${#log_files[@]} log file(s):"
    for f in "${log_files[@]}"; do
        local size
        size="$(wc -l < "$f" | tr -d ' ')"
        echo -e "  ${DIM}•${RESET} $(basename "$f")  ${DIM}(${size} lines)${RESET}"
    done

    echo ""
    local latest="${log_files[0]}"
    info "Most recent: ${BOLD}$(basename "$latest")${RESET}"
    echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    cat "$latest"
}

# ─── Parse Arguments ─────────────────────────────────────────────────────────
TEAM=""
PANE=""
GREP_PATTERN=""
FOLLOW=false
DO_CAPTURE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_usage
            exit 0
            ;;
        --capture)
            DO_CAPTURE=true
            shift
            ;;
        --pane)
            PANE="${2:-}"
            [[ -z "$PANE" ]] && { error "--pane requires an agent name"; exit 1; }
            shift 2
            ;;
        --follow|-f)
            FOLLOW=true
            shift
            ;;
        --grep)
            GREP_PATTERN="${2:-}"
            [[ -z "$GREP_PATTERN" ]] && { error "--grep requires a pattern"; exit 1; }
            shift 2
            ;;
        -*)
            error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            TEAM="$1"
            shift
            ;;
    esac
done

# ─── Dispatch ────────────────────────────────────────────────────────────────
if $DO_CAPTURE; then
    capture_logs
elif [[ -z "$TEAM" ]]; then
    list_logs
else
    show_team_logs "$TEAM" "$PANE" "$GREP_PATTERN" "$FOLLOW"
fi
