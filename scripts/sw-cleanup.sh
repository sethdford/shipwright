#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-cleanup.sh — Clean up orphaned Claude team sessions                 ║
# ║                                                                          ║
# ║  Default: dry-run (shows what would be cleaned).                         ║
# ║  Use --force to actually kill sessions and remove files.                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="1.7.1"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

# ─── Parse Args ──────────────────────────────────────────────────────────────

FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
        --help|-h)
            echo -e "${CYAN}${BOLD}shipwright cleanup${RESET} — Clean up orphaned Claude team sessions"
            echo ""
            echo -e "${BOLD}USAGE${RESET}"
            echo -e "  shipwright cleanup            ${DIM}# Dry-run: show what would be cleaned${RESET}"
            echo -e "  shipwright cleanup --force    ${DIM}# Actually kill sessions and remove files${RESET}"
            exit 0
            ;;
        *)
            error "Unknown option: ${arg}"
            exit 1
            ;;
    esac
done

# ─── Track cleanup stats ────────────────────────────────────────────────────

WINDOWS_FOUND=0
WINDOWS_KILLED=0
TEAM_DIRS_FOUND=0
TEAM_DIRS_REMOVED=0
TASK_DIRS_FOUND=0
TASK_DIRS_REMOVED=0

# ─── 1. Find orphaned tmux windows ──────────────────────────────────────────

echo ""
if $FORCE; then
    info "Cleaning up Claude team sessions ${RED}${BOLD}(FORCE MODE)${RESET}"
else
    info "Scanning for orphaned Claude team sessions ${DIM}(dry-run)${RESET}"
fi
echo ""

echo -e "${BOLD}Tmux Windows${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

# Look for windows with "claude" in the name across all sessions
CLAUDE_WINDOWS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && CLAUDE_WINDOWS+=("$line")
done < <(tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}' 2>/dev/null | grep -i "claude" || true)

if [[ ${#CLAUDE_WINDOWS[@]} -eq 0 ]]; then
    echo -e "  ${DIM}No Claude team windows found.${RESET}"
else
    for win in "${CLAUDE_WINDOWS[@]}"; do
        WINDOWS_FOUND=$((WINDOWS_FOUND + 1))
        local_target="$(echo "$win" | cut -d' ' -f1)"
        local_name="$(echo "$win" | cut -d' ' -f2-)"

        if $FORCE; then
            tmux kill-window -t "$local_target" 2>/dev/null && {
                echo -e "  ${RED}✗${RESET} Killed: ${local_name} ${DIM}(${local_target})${RESET}"
                WINDOWS_KILLED=$((WINDOWS_KILLED + 1))
            } || {
                warn "  Could not kill: ${local_name} (${local_target})"
            }
        else
            echo -e "  ${YELLOW}○${RESET} Would kill: ${local_name} ${DIM}(${local_target})${RESET}"
        fi
    done
fi

# ─── 2. Clean up ~/.claude/teams/ ───────────────────────────────────────────

echo ""
echo -e "${BOLD}Team Configs${RESET}  ${DIM}~/.claude/teams/${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

TEAMS_DIR="${HOME}/.claude/teams"
if [[ -d "$TEAMS_DIR" ]]; then
    while IFS= read -r team_dir; do
        [[ -z "$team_dir" ]] && continue
        TEAM_DIRS_FOUND=$((TEAM_DIRS_FOUND + 1))
        team_name="$(basename "$team_dir")"

        if $FORCE; then
            rm -rf "$team_dir" && {
                echo -e "  ${RED}✗${RESET} Removed: ${team_name}/"
                TEAM_DIRS_REMOVED=$((TEAM_DIRS_REMOVED + 1))
            }
        else
            # Count files inside
            file_count=$(find "$team_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            echo -e "  ${YELLOW}○${RESET} Would remove: ${team_name}/ ${DIM}(${file_count} files)${RESET}"
        fi
    done < <(find "$TEAMS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
else
    echo -e "  ${DIM}No team configs found.${RESET}"
fi

# ─── 3. Clean up ~/.claude/tasks/ ───────────────────────────────────────────

echo ""
echo -e "${BOLD}Task Lists${RESET}  ${DIM}~/.claude/tasks/${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

TASKS_DIR="${HOME}/.claude/tasks"
if [[ -d "$TASKS_DIR" ]]; then
    while IFS= read -r task_dir; do
        [[ -z "$task_dir" ]] && continue
        TASK_DIRS_FOUND=$((TASK_DIRS_FOUND + 1))
        task_name="$(basename "$task_dir")"

        if $FORCE; then
            rm -rf "$task_dir" && {
                echo -e "  ${RED}✗${RESET} Removed: ${task_name}/"
                TASK_DIRS_REMOVED=$((TASK_DIRS_REMOVED + 1))
            }
        else
            task_count=$(find "$task_dir" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
            echo -e "  ${YELLOW}○${RESET} Would remove: ${task_name}/ ${DIM}(${task_count} tasks)${RESET}"
        fi
    done < <(find "$TASKS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
else
    echo -e "  ${DIM}No task directories found.${RESET}"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${DIM}────────────────────────────────────────${RESET}"

TOTAL_FOUND=$((WINDOWS_FOUND + TEAM_DIRS_FOUND + TASK_DIRS_FOUND))

if $FORCE; then
    TOTAL_CLEANED=$((WINDOWS_KILLED + TEAM_DIRS_REMOVED + TASK_DIRS_REMOVED))
    if [[ $TOTAL_CLEANED -gt 0 ]]; then
        success "Cleaned ${TOTAL_CLEANED} items (${WINDOWS_KILLED} windows, ${TEAM_DIRS_REMOVED} team dirs, ${TASK_DIRS_REMOVED} task dirs)"
    else
        success "Nothing to clean up."
    fi
else
    if [[ $TOTAL_FOUND -gt 0 ]]; then
        warn "Found ${TOTAL_FOUND} items to clean. Run with ${BOLD}--force${RESET} to remove them:"
        echo -e "  ${DIM}shipwright cleanup --force${RESET}"
    else
        success "Everything is clean. No orphaned sessions found."
    fi
fi
echo ""
