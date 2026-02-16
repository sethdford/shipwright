#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-cleanup.sh — Clean up orphaned Claude team sessions & artifacts     ║
# ║                                                                          ║
# ║  Default: dry-run (shows what would be cleaned).                         ║
# ║  Use --force to actually kill sessions and remove files.                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="2.1.0"
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
            echo -e "${CYAN}${BOLD}shipwright cleanup${RESET} — Clean up orphaned sessions and artifacts"
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
ARTIFACTS_FOUND=0
ARTIFACTS_REMOVED=0
CHECKPOINTS_FOUND=0
CHECKPOINTS_REMOVED=0
HEARTBEATS_FOUND=0
HEARTBEATS_REMOVED=0
BRANCHES_FOUND=0
BRANCHES_REMOVED=0
STATE_RESET=0

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

# ─── 4. Pipeline Artifacts ──────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Pipeline Artifacts${RESET}  ${DIM}.claude/pipeline-artifacts/${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

PIPELINE_ARTIFACTS=".claude/pipeline-artifacts"
if [[ -d "$PIPELINE_ARTIFACTS" ]]; then
    artifact_file_count=$(find "$PIPELINE_ARTIFACTS" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${artifact_file_count:-0}" -gt 0 ]]; then
        ARTIFACTS_FOUND=$((artifact_file_count))

        # Calculate total size
        artifact_size=$(du -sh "$PIPELINE_ARTIFACTS" 2>/dev/null | cut -f1 || echo "unknown")

        if $FORCE; then
            rm -rf "$PIPELINE_ARTIFACTS"
            mkdir -p "$PIPELINE_ARTIFACTS"
            ARTIFACTS_REMOVED=$((artifact_file_count))
            echo -e "  ${RED}✗${RESET} Cleaned ${artifact_file_count} files (${artifact_size})"
        else
            echo -e "  ${YELLOW}○${RESET} Would clean: ${artifact_file_count} files (${artifact_size})"
        fi
    else
        echo -e "  ${DIM}No pipeline artifacts found.${RESET}"
    fi
else
    echo -e "  ${DIM}No pipeline artifacts directory.${RESET}"
fi

# ─── 5. Checkpoints ────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Checkpoints${RESET}  ${DIM}.claude/pipeline-artifacts/checkpoints/${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

CHECKPOINT_DIR=".claude/pipeline-artifacts/checkpoints"
if [[ -d "$CHECKPOINT_DIR" ]]; then
    cp_file_count=0
    for cp_file in "${CHECKPOINT_DIR}"/*-checkpoint.json; do
        [[ -f "$cp_file" ]] || continue
        cp_file_count=$((cp_file_count + 1))
    done

    if [[ "$cp_file_count" -gt 0 ]]; then
        CHECKPOINTS_FOUND=$cp_file_count

        if $FORCE; then
            rm -f "${CHECKPOINT_DIR}"/*-checkpoint.json
            CHECKPOINTS_REMOVED=$cp_file_count
            echo -e "  ${RED}✗${RESET} Removed ${cp_file_count} checkpoint(s)"
        else
            echo -e "  ${YELLOW}○${RESET} Would remove: ${cp_file_count} checkpoint(s)"
        fi
    else
        echo -e "  ${DIM}No checkpoints found.${RESET}"
    fi
else
    echo -e "  ${DIM}No checkpoint directory.${RESET}"
fi

# ─── 6. Pipeline State ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Pipeline State${RESET}  ${DIM}.claude/pipeline-state.md${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

PIPELINE_STATE=".claude/pipeline-state.md"
if [[ -f "$PIPELINE_STATE" ]]; then
    state_status=$(sed -n 's/^status: *//p' "$PIPELINE_STATE" | head -1 || true)
    state_issue=$(sed -n 's/^issue: *//p' "$PIPELINE_STATE" | head -1 || true)

    case "${state_status:-}" in
        complete|failed|idle|"")
            if $FORCE; then
                rm -f "$PIPELINE_STATE"
                STATE_RESET=1
                echo -e "  ${RED}✗${RESET} Removed stale state (was: ${state_status:-empty}${state_issue:+, issue #$state_issue})"
            else
                echo -e "  ${YELLOW}○${RESET} Would remove: status=${state_status:-empty}${state_issue:+, issue #$state_issue}"
            fi
            ;;
        running|paused|interrupted)
            echo -e "  ${CYAN}●${RESET} Active pipeline: status=${state_status}${state_issue:+, issue #$state_issue} ${DIM}(skipping)${RESET}"
            ;;
        *)
            echo -e "  ${DIM}Unknown state: ${state_status}${RESET}"
            ;;
    esac
else
    echo -e "  ${DIM}No pipeline state file.${RESET}"
fi

# ─── 7. Stale Heartbeats ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Heartbeats${RESET}  ${DIM}~/.shipwright/heartbeats/${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

HEARTBEAT_DIR="${HOME}/.shipwright/heartbeats"
if [[ -d "$HEARTBEAT_DIR" ]]; then
    now_e=$(date +%s)
    stale_threshold=3600  # 1 hour

    while IFS= read -r hb_file; do
        [[ -f "$hb_file" ]] || continue
        hb_mtime=$(stat -f '%m' "$hb_file" 2>/dev/null || stat -c '%Y' "$hb_file" 2>/dev/null || echo "0")
        if [[ $((now_e - hb_mtime)) -gt $stale_threshold ]]; then
            HEARTBEATS_FOUND=$((HEARTBEATS_FOUND + 1))
            hb_name=$(basename "$hb_file" .json)

            if $FORCE; then
                rm -f "$hb_file"
                HEARTBEATS_REMOVED=$((HEARTBEATS_REMOVED + 1))
                echo -e "  ${RED}✗${RESET} Removed: ${hb_name} ${DIM}(stale >1h)${RESET}"
            else
                age_min=$(( (now_e - hb_mtime) / 60 ))
                echo -e "  ${YELLOW}○${RESET} Would remove: ${hb_name} ${DIM}(${age_min}m old)${RESET}"
            fi
        fi
    done < <(find "$HEARTBEAT_DIR" -name '*.json' -type f 2>/dev/null)

    if [[ "$HEARTBEATS_FOUND" -eq 0 ]]; then
        echo -e "  ${DIM}No stale heartbeats.${RESET}"
    fi
else
    echo -e "  ${DIM}No heartbeat directory.${RESET}"
fi

# ─── 8. Orphaned pipeline/* branches ───────────────────────────────────────

echo ""
echo -e "${BOLD}Orphaned Branches${RESET}  ${DIM}pipeline/* and daemon/*${RESET}"
echo -e "${DIM}────────────────────────────────────────${RESET}"

if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null; then
    # Collect active worktree paths
    active_worktrees=""
    while IFS= read -r wt_line; do
        active_worktrees="${active_worktrees} ${wt_line}"
    done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //')

    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        branch="${branch## }"  # trim leading spaces
        # Check if this branch has an active worktree
        has_worktree=false
        for wt in $active_worktrees; do
            if echo "$wt" | grep -q "${branch##*/}" 2>/dev/null; then
                has_worktree=true
                break
            fi
        done

        if [[ "$has_worktree" == "false" ]]; then
            BRANCHES_FOUND=$((BRANCHES_FOUND + 1))
            if $FORCE; then
                git branch -D "$branch" 2>/dev/null || true
                BRANCHES_REMOVED=$((BRANCHES_REMOVED + 1))
                echo -e "  ${RED}✗${RESET} Deleted: ${branch}"
            else
                echo -e "  ${YELLOW}○${RESET} Would delete: ${branch}"
            fi
        fi
    done < <(git branch --list 'pipeline/*' --list 'daemon/*' 2>/dev/null)

    if [[ "$BRANCHES_FOUND" -eq 0 ]]; then
        echo -e "  ${DIM}No orphaned branches.${RESET}"
    fi
else
    echo -e "  ${DIM}Not in a git repository.${RESET}"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${DIM}────────────────────────────────────────${RESET}"

TOTAL_FOUND=$((WINDOWS_FOUND + TEAM_DIRS_FOUND + TASK_DIRS_FOUND + ARTIFACTS_FOUND + CHECKPOINTS_FOUND + HEARTBEATS_FOUND + BRANCHES_FOUND + STATE_RESET))

if $FORCE; then
    TOTAL_CLEANED=$((WINDOWS_KILLED + TEAM_DIRS_REMOVED + TASK_DIRS_REMOVED + ARTIFACTS_REMOVED + CHECKPOINTS_REMOVED + HEARTBEATS_REMOVED + BRANCHES_REMOVED + STATE_RESET))
    if [[ $TOTAL_CLEANED -gt 0 ]]; then
        success "Cleaned ${TOTAL_CLEANED} items"
        echo -e "  ${DIM}windows: ${WINDOWS_KILLED}, teams: ${TEAM_DIRS_REMOVED}, tasks: ${TASK_DIRS_REMOVED}${RESET}"
        echo -e "  ${DIM}artifacts: ${ARTIFACTS_REMOVED}, checkpoints: ${CHECKPOINTS_REMOVED}, heartbeats: ${HEARTBEATS_REMOVED}${RESET}"
        echo -e "  ${DIM}branches: ${BRANCHES_REMOVED}, state: ${STATE_RESET}${RESET}"
    else
        success "Nothing to clean up."
    fi
else
    if [[ $TOTAL_FOUND -gt 0 ]]; then
        warn "Found ${TOTAL_FOUND} items to clean. Run with ${BOLD}--force${RESET} to remove them:"
        echo -e "  ${DIM}shipwright cleanup --force${RESET}"
    else
        success "Everything is clean. No orphaned sessions or artifacts found."
    fi
fi
echo ""
