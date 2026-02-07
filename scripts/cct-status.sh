#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  cct-status.sh — Dashboard showing Claude Code team status               ║
# ║                                                                          ║
# ║  Shows running teams, agent windows, and task progress.                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
BLUE='\033[38;2;0;102;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Header ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}${BOLD}  Claude Code Teams — Status Dashboard${RESET}"
echo -e "${DIM}  $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# ─── 1. Tmux Windows ────────────────────────────────────────────────────────

echo -e "${PURPLE}${BOLD}  TMUX WINDOWS${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

# Get all windows, highlight Claude-related ones
HAS_CLAUDE_WINDOWS=false
while IFS= read -r line; do
    session_window="$(echo "$line" | cut -d'|' -f1)"
    window_name="$(echo "$line" | cut -d'|' -f2)"
    pane_count="$(echo "$line" | cut -d'|' -f3)"
    active="$(echo "$line" | cut -d'|' -f4)"

    if echo "$window_name" | grep -qi "claude"; then
        HAS_CLAUDE_WINDOWS=true
        if [[ "$active" == "1" ]]; then
            status_icon="${GREEN}●${RESET}"
            status_label="${GREEN}active${RESET}"
        else
            status_icon="${YELLOW}●${RESET}"
            status_label="${YELLOW}idle${RESET}"
        fi
        echo -e "  ${status_icon} ${BOLD}${window_name}${RESET}  ${DIM}${session_window}${RESET}  panes:${pane_count}  ${status_label}"
    fi
done < <(tmux list-windows -a -F '#{session_name}:#{window_index}|#{window_name}|#{window_panes}|#{window_active}' 2>/dev/null || true)

if ! $HAS_CLAUDE_WINDOWS; then
    echo -e "  ${DIM}No Claude team windows found.${RESET}"
    echo -e "  ${DIM}Start one with: ${CYAN}cct session <name>${RESET}"
fi

# ─── 2. Team Configurations ─────────────────────────────────────────────────

echo ""
echo -e "${PURPLE}${BOLD}  TEAM CONFIGS${RESET}  ${DIM}~/.claude/teams/${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

TEAMS_DIR="${HOME}/.claude/teams"
HAS_TEAMS=false

if [[ -d "$TEAMS_DIR" ]]; then
    while IFS= read -r team_dir; do
        [[ -z "$team_dir" ]] && continue
        HAS_TEAMS=true
        team_name="$(basename "$team_dir")"

        # Try to read config.json for member info
        config_file="${team_dir}/config.json"
        if [[ -f "$config_file" ]]; then
            # Count members from JSON (look for "name" keys in members array)
            member_count=$(grep -c '"name"' "$config_file" 2>/dev/null || echo "0")
            # Extract member names
            member_names=$(grep '"name"' "$config_file" 2>/dev/null | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')

            echo -e "  ${GREEN}●${RESET} ${BOLD}${team_name}${RESET}  ${DIM}members:${member_count}${RESET}"
            if [[ -n "$member_names" ]]; then
                echo -e "    ${DIM}└─ ${member_names}${RESET}"
            fi
        else
            # Directory exists but no config — possibly orphaned
            echo -e "  ${RED}●${RESET} ${BOLD}${team_name}${RESET}  ${DIM}(no config — possibly orphaned)${RESET}"
        fi
    done < <(find "$TEAMS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

if ! $HAS_TEAMS; then
    echo -e "  ${DIM}No team configs found.${RESET}"
fi

# ─── 3. Task Lists ──────────────────────────────────────────────────────────

echo ""
echo -e "${PURPLE}${BOLD}  TASK LISTS${RESET}  ${DIM}~/.claude/tasks/${RESET}"
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

TASKS_DIR="${HOME}/.claude/tasks"
HAS_TASKS=false

if [[ -d "$TASKS_DIR" ]]; then
    while IFS= read -r task_dir; do
        [[ -z "$task_dir" ]] && continue
        HAS_TASKS=true
        task_team="$(basename "$task_dir")"

        # Count tasks by status
        total=0
        completed=0
        in_progress=0
        pending=0

        while IFS= read -r task_file; do
            [[ -z "$task_file" ]] && continue
            total=$((total + 1))
            status=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$task_file" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            case "$status" in
                completed)   completed=$((completed + 1)) ;;
                in_progress) in_progress=$((in_progress + 1)) ;;
                pending)     pending=$((pending + 1)) ;;
            esac
        done < <(find "$task_dir" -type f -name '*.json' 2>/dev/null)

        # Build progress bar
        if [[ $total -gt 0 ]]; then
            pct=$((completed * 100 / total))
            bar_width=20
            filled=$((pct * bar_width / 100))
            empty=$((bar_width - filled))
            bar="${GREEN}"
            for ((i=0; i<filled; i++)); do bar+="█"; done
            bar+="${DIM}"
            for ((i=0; i<empty; i++)); do bar+="░"; done
            bar+="${RESET}"

            echo -e "  ${BLUE}●${RESET} ${BOLD}${task_team}${RESET}  ${bar} ${pct}%  ${DIM}(${completed}/${total} done)${RESET}"

            # Show breakdown if there are active tasks
            details=""
            [[ $in_progress -gt 0 ]] && details+="${GREEN}${in_progress} active${RESET}  "
            [[ $pending -gt 0 ]]     && details+="${YELLOW}${pending} pending${RESET}  "
            [[ $completed -gt 0 ]]   && details+="${DIM}${completed} done${RESET}"
            [[ -n "$details" ]] && echo -e "    ${DIM}└─${RESET} ${details}"
        else
            echo -e "  ${DIM}●${RESET} ${BOLD}${task_team}${RESET}  ${DIM}(no tasks)${RESET}"
        fi
    done < <(find "$TASKS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

if ! $HAS_TASKS; then
    echo -e "  ${DIM}No task lists found.${RESET}"
fi

# ─── Footer ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
if $HAS_CLAUDE_WINDOWS || $HAS_TEAMS || $HAS_TASKS; then
    echo -e "  ${DIM}Clean up:${RESET} ${CYAN}cct cleanup${RESET}  ${DIM}|${RESET}  ${DIM}New session:${RESET} ${CYAN}cct session <name>${RESET}"
else
    echo -e "  ${DIM}No active teams. Start one:${RESET} ${CYAN}cct session <name>${RESET}"
fi
echo ""
