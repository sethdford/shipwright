#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  cct-status.sh — Dashboard showing Claude Code team status               ║
# ║                                                                          ║
# ║  Shows running teams, agent windows, and task progress.                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
VERSION="1.7.1"

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

# ─── Cross-platform compatibility ──────────────────────────────────────────
_COMPAT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/compat.sh"
# shellcheck source=lib/compat.sh
[[ -f "$_COMPAT" ]] && source "$_COMPAT"

# ─── Argument parsing ─────────────────────────────────────────────────────────
JSON_OUTPUT=false
for arg in "$@"; do
    case "$arg" in
        --json) JSON_OUTPUT=true ;;
        --help|-h)
            echo "Usage: shipwright status [OPTIONS]"
            echo ""
            echo "Show team dashboard with running agents, tasks, and pipelines."
            echo ""
            echo "Options:"
            echo "  --json    Output machine-readable JSON instead of human-readable dashboard"
            echo "  --help    Show this help message"
            exit 0
            ;;
    esac
done

if [[ "$JSON_OUTPUT" == "true" ]]; then

# ─── JSON Output Mode ──────────────────────────────────────────────────────

# Require jq for JSON output
if ! command -v jq &>/dev/null; then
    echo '{"error":"jq is required for --json output"}' >&2
    exit 1
fi

# ── Helper: cross-platform ISO date → epoch ──
parse_iso_epoch() {
    local ts="$1"
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
        || date -d "$ts" +%s 2>/dev/null \
        || echo 0
}

# ── 1. Teams (tmux windows) ──
teams_json="[]"
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    w_session_window="$(echo "$line" | cut -d'|' -f1)"
    w_name="$(echo "$line" | cut -d'|' -f2)"
    w_panes="$(echo "$line" | cut -d'|' -f3)"
    w_active="$(echo "$line" | cut -d'|' -f4)"

    if echo "$w_name" | grep -qi "claude"; then
        w_status="active"
        [[ "$w_active" != "1" ]] && w_status="idle"
        teams_json=$(echo "$teams_json" | jq \
            --arg name "$w_name" \
            --argjson panes "$w_panes" \
            --arg status "$w_status" \
            --arg session "$w_session_window" \
            '. + [{"name": $name, "panes": $panes, "status": $status, "session": $session}]')
    fi
done < <(tmux list-windows -a -F '#{session_name}:#{window_index}|#{window_name}|#{window_panes}|#{window_active}' 2>/dev/null || true)

# ── 2. Tasks ──
tasks_json="[]"
TASKS_DIR="${HOME}/.claude/tasks"
if [[ -d "$TASKS_DIR" ]]; then
    while IFS= read -r task_dir; do
        [[ -z "$task_dir" ]] && continue
        t_team="$(basename "$task_dir")"
        t_total=0
        t_completed=0
        t_in_progress=0
        t_pending=0

        while IFS= read -r task_file; do
            [[ -z "$task_file" ]] && continue
            t_total=$((t_total + 1))
            t_status=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$task_file" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            case "$t_status" in
                completed)   t_completed=$((t_completed + 1)) ;;
                in_progress) t_in_progress=$((t_in_progress + 1)) ;;
                pending)     t_pending=$((t_pending + 1)) ;;
            esac
        done < <(find "$task_dir" -type f -name '*.json' 2>/dev/null)

        tasks_json=$(echo "$tasks_json" | jq \
            --arg team "$t_team" \
            --argjson total "$t_total" \
            --argjson completed "$t_completed" \
            --argjson in_progress "$t_in_progress" \
            --argjson pending "$t_pending" \
            '. + [{"team": $team, "total": $total, "completed": $completed, "in_progress": $in_progress, "pending": $pending}]')
    done < <(find "$TASKS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

# ── 3. Daemon ──
daemon_json="null"
DAEMON_DIR="${HOME}/.claude-teams"
STATE_FILE="${DAEMON_DIR}/daemon-state.json"
PID_FILE="${DAEMON_DIR}/daemon.pid"

if [[ -f "$STATE_FILE" ]]; then
    d_pid=""
    d_running=false
    if [[ -f "$PID_FILE" ]]; then
        d_pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$d_pid" ]] && kill -0 "$d_pid" 2>/dev/null; then
            d_running=true
        fi
    fi

    d_active=$(jq -r '.active_jobs | length' "$STATE_FILE" 2>/dev/null || echo 0)
    d_queued=$(jq -r '.queued | length' "$STATE_FILE" 2>/dev/null || echo 0)
    d_completed=$(jq -r '.completed | length' "$STATE_FILE" 2>/dev/null || echo 0)

    daemon_json=$(jq -n \
        --argjson running "$d_running" \
        --argjson active_jobs "${d_active:-0}" \
        --argjson queued "${d_queued:-0}" \
        --argjson completed "${d_completed:-0}" \
        '{running: $running, active_jobs: $active_jobs, queued: $queued, completed: $completed}')
fi

# ── 4. Heartbeats ──
heartbeats_json="[]"
HEARTBEAT_DIR="$HOME/.claude-teams/heartbeats"
if [[ -d "$HEARTBEAT_DIR" ]]; then
    for hb_file in "${HEARTBEAT_DIR}"/*.json; do
        [[ -f "$hb_file" ]] || continue
        hb_job_id="$(basename "$hb_file" .json)"
        hb_pid=$(jq -r '.pid // ""' "$hb_file" 2>/dev/null || true)
        hb_stage=$(jq -r '.stage // ""' "$hb_file" 2>/dev/null || true)
        hb_issue=$(jq -r '.issue // ""' "$hb_file" 2>/dev/null || true)
        hb_updated=$(jq -r '.updated_at // ""' "$hb_file" 2>/dev/null || true)

        hb_alive=false
        if [[ -n "$hb_pid" && "$hb_pid" != "null" ]] && kill -0 "$hb_pid" 2>/dev/null; then
            hb_alive=true
        fi

        hb_age_s=0
        if [[ -n "$hb_updated" && "$hb_updated" != "null" ]]; then
            hb_epoch=$(parse_iso_epoch "$hb_updated")
            if [[ "$hb_epoch" -gt 0 ]]; then
                now_e=$(date +%s)
                hb_age_s=$((now_e - hb_epoch))
            fi
        fi

        heartbeats_json=$(echo "$heartbeats_json" | jq \
            --arg job_id "$hb_job_id" \
            --arg stage "$hb_stage" \
            --arg issue "$hb_issue" \
            --argjson age_s "$hb_age_s" \
            --argjson alive "$hb_alive" \
            '. + [{"job_id": $job_id, "stage": $stage, "issue": $issue, "age_s": $age_s, "alive": $alive}]')
    done
fi

# ── 5. Machines ──
machines_json="[]"
MACHINES_FILE="$HOME/.claude-teams/machines.json"
if [[ -f "$MACHINES_FILE" ]]; then
    machines_json=$(jq '[.machines[] | {name: .name, host: .host, cores: (.cores // null), memory_gb: (.memory_gb // null), max_workers: (.max_workers // null)}]' "$MACHINES_FILE" 2>/dev/null || echo "[]")
fi

# ── Emit final JSON ──
jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson teams "$teams_json" \
    --argjson tasks "$tasks_json" \
    --argjson daemon "$daemon_json" \
    --argjson heartbeats "$heartbeats_json" \
    --argjson machines "$machines_json" \
    '{timestamp: $ts, teams: $teams, tasks: $tasks, daemon: $daemon, heartbeats: $heartbeats, machines: $machines}'

else

# ─── Human-Readable Output Mode ───────────────────────────────────────────

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
    echo -e "  ${DIM}Start one with: ${CYAN}shipwright session <name>${RESET}"
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
            member_count=$(grep -c '"name"' "$config_file" 2>/dev/null || true)
            member_count="${member_count:-0}"
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

# ─── 4. Daemon Pipelines ──────────────────────────────────────────────────

DAEMON_DIR="${HOME}/.claude-teams"
STATE_FILE="${DAEMON_DIR}/daemon-state.json"
PID_FILE="${DAEMON_DIR}/daemon.pid"
EVENTS_FILE="${DAEMON_DIR}/events.jsonl"
HAS_DAEMON=false

if [[ -f "$STATE_FILE" ]]; then
    # Check daemon process
    daemon_pid=""
    daemon_running=false
    if [[ -f "$PID_FILE" ]]; then
        daemon_pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
            daemon_running=true
        fi
    fi

    active_count=$(jq -r '.active_jobs | length' "$STATE_FILE" 2>/dev/null || echo 0)
    queue_count=$(jq -r '.queued | length' "$STATE_FILE" 2>/dev/null || echo 0)
    completed_count=$(jq -r '.completed | length' "$STATE_FILE" 2>/dev/null || echo 0)

    if $daemon_running || [[ "$active_count" -gt 0 ]] || [[ "$queue_count" -gt 0 ]] || [[ "$completed_count" -gt 0 ]]; then
        HAS_DAEMON=true
        echo ""
        echo -e "${PURPLE}${BOLD}  DAEMON PIPELINES${RESET}  ${DIM}~/.claude-teams/${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

        # ── Daemon Health ──
        if $daemon_running; then
            started_at=$(jq -r '.started_at // "unknown"' "$STATE_FILE" 2>/dev/null)
            last_poll=$(jq -r '.last_poll // "never"' "$STATE_FILE" 2>/dev/null)
            # Calculate uptime
            uptime_str=""
            if [[ "$started_at" != "unknown" && "$started_at" != "null" ]]; then
                start_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || echo 0)
                if [[ "$start_epoch" -gt 0 ]]; then
                    now_e=$(date +%s)
                    elapsed=$((now_e - start_epoch))
                    if [[ "$elapsed" -ge 3600 ]]; then
                        uptime_str=$(printf "%dh %dm" $((elapsed/3600)) $((elapsed%3600/60)))
                    elif [[ "$elapsed" -ge 60 ]]; then
                        uptime_str=$(printf "%dm %ds" $((elapsed/60)) $((elapsed%60)))
                    else
                        uptime_str=$(printf "%ds" "$elapsed")
                    fi
                fi
            fi
            echo -e "  ${GREEN}●${RESET} ${BOLD}Running${RESET}  ${DIM}PID:${daemon_pid}${RESET}  ${DIM}up:${uptime_str:-?}${RESET}  ${DIM}poll:${last_poll}${RESET}"
        else
            echo -e "  ${RED}●${RESET} ${BOLD}Stopped${RESET}"
        fi

        # ── Active Jobs ──
        if [[ "$active_count" -gt 0 ]]; then
            echo ""
            echo -e "  ${BOLD}Active Jobs (${active_count})${RESET}"
            while IFS= read -r job; do
                [[ -z "$job" ]] && continue
                a_issue=$(echo "$job" | jq -r '.issue')
                a_title=$(echo "$job" | jq -r '.title // ""')
                a_worktree=$(echo "$job" | jq -r '.worktree // ""')
                a_started=$(echo "$job" | jq -r '.started_at // ""')
                a_goal=$(echo "$job" | jq -r '.goal // ""')

                # Look up title from title cache if empty
                if [[ -z "$a_title" ]]; then
                    a_title=$(jq -r --arg n "$a_issue" '.titles[$n] // ""' "$STATE_FILE" 2>/dev/null || true)
                fi

                # Time elapsed
                age_str=""
                if [[ -n "$a_started" && "$a_started" != "null" ]]; then
                    s_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$a_started" +%s 2>/dev/null || echo 0)
                    if [[ "$s_epoch" -gt 0 ]]; then
                        now_e=$(date +%s)
                        el=$((now_e - s_epoch))
                        if [[ "$el" -ge 3600 ]]; then
                            age_str=$(printf "%dh %dm" $((el/3600)) $((el%3600/60)))
                        elif [[ "$el" -ge 60 ]]; then
                            age_str=$(printf "%dm %ds" $((el/60)) $((el%60)))
                        else
                            age_str=$(printf "%ds" "$el")
                        fi
                    fi
                fi

                # Read enriched pipeline state from worktree
                stage_str=""
                stage_desc=""
                stage_progress=""
                goal_from_state=""
                if [[ -n "$a_worktree" && -f "${a_worktree}/.claude/pipeline-state.md" ]]; then
                    local ps_file="${a_worktree}/.claude/pipeline-state.md"
                    stage_str=$(grep -E '^current_stage:' "$ps_file" 2>/dev/null | head -1 | sed 's/^current_stage:[[:space:]]*//' || true)
                    stage_desc=$(grep -E '^current_stage_description:' "$ps_file" 2>/dev/null | head -1 | sed 's/^current_stage_description:[[:space:]]*"//;s/"$//' || true)
                    stage_progress=$(grep -E '^stage_progress:' "$ps_file" 2>/dev/null | head -1 | sed 's/^stage_progress:[[:space:]]*"//;s/"$//' || true)
                    goal_from_state=$(grep -E '^goal:' "$ps_file" 2>/dev/null | head -1 | sed 's/^goal:[[:space:]]*"//;s/"$//' || true)
                fi

                # Use goal from state file if not in daemon job data
                local display_goal="${a_goal:-$goal_from_state}"

                # Title line
                echo -e "    ${CYAN}#${a_issue}${RESET}  ${BOLD}${a_title}${RESET}"

                # Goal line (if different from title)
                if [[ -n "$display_goal" && "$display_goal" != "$a_title" ]]; then
                    echo -e "           ${DIM}Delivering: ${display_goal}${RESET}"
                fi

                # Stage + description line
                if [[ -n "$stage_str" ]]; then
                    local stage_icon="🔄"
                    local stage_line="           ${stage_icon} ${BLUE}${stage_str}${RESET}"
                    [[ -n "$stage_desc" ]] && stage_line="${stage_line} ${DIM}— ${stage_desc}${RESET}"
                    echo -e "$stage_line"
                fi

                # Inline progress bar from stage_progress
                if [[ -n "$stage_progress" ]]; then
                    local progress_bar=""
                    local entry=""
                    # Parse space-separated "stage:status" pairs
                    for entry in $stage_progress; do
                        local s_name="${entry%%:*}"
                        local s_stat="${entry#*:}"
                        local s_icon=""
                        case "$s_stat" in
                            complete) s_icon="✅" ;;
                            running)  s_icon="🔄" ;;
                            failed)   s_icon="❌" ;;
                            *)        s_icon="⬜" ;;
                        esac
                        if [[ -n "$progress_bar" ]]; then
                            progress_bar="${progress_bar} → ${s_icon}${s_name}"
                        else
                            progress_bar="${s_icon}${s_name}"
                        fi
                    done
                    echo -e "           ${DIM}${progress_bar}${RESET}"
                fi

                # Elapsed time
                [[ -n "$age_str" ]] && echo -e "           ${DIM}Elapsed: ${age_str}${RESET}"
            done < <(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null)
        fi

        # ── Queued Issues ──
        if [[ "$queue_count" -gt 0 ]]; then
            echo ""
            echo -e "  ${BOLD}Queued (${queue_count})${RESET}"
            while read -r q_num; do
                [[ -z "$q_num" ]] && continue
                q_title=$(jq -r --arg n "$q_num" '.titles[$n] // ""' "$STATE_FILE" 2>/dev/null || true)
                title_display=""
                [[ -n "$q_title" ]] && title_display="  ${q_title}"
                echo -e "    ${YELLOW}#${q_num}${RESET}${title_display}"
            done < <(jq -r '.queued[]' "$STATE_FILE" 2>/dev/null)
        fi

        # ── Recent Completions ──
        if [[ "$completed_count" -gt 0 ]]; then
            echo ""
            echo -e "  ${BOLD}Recent Completions${RESET}"
            while IFS=$'\t' read -r c_num c_result c_dur c_at; do
                [[ -z "$c_num" ]] && continue
                if [[ "$c_result" == "success" ]]; then
                    c_icon="${GREEN}✓${RESET}"
                else
                    c_icon="${RED}✗${RESET}"
                fi
                echo -e "    ${c_icon} ${CYAN}#${c_num}${RESET}  ${c_result}  ${DIM}(${c_dur})${RESET}"
            done < <(jq -r '.completed | reverse | .[:5][] | "\(.issue)\t\(.result)\t\(.duration // "—")\t\(.completed_at // "")"' "$STATE_FILE" 2>/dev/null)
        fi

        # ── Recent Activity (from events.jsonl) ──
        if [[ -f "$EVENTS_FILE" ]]; then
            # Get last 8 relevant events (spawns, stage changes, completions)
            recent_events=$(tail -200 "$EVENTS_FILE" 2>/dev/null | \
                grep -E '"type":"(daemon\.spawn|daemon\.reap|stage\.(started|completed)|daemon\.poll)"' 2>/dev/null | \
                tail -8 || true)
            if [[ -n "$recent_events" ]]; then
                echo ""
                echo -e "  ${BOLD}Recent Activity${RESET}"
                while IFS= read -r evt; do
                    [[ -z "$evt" ]] && continue
                    evt_ts=$(echo "$evt" | jq -r '.ts // ""' 2>/dev/null)
                    evt_type=$(echo "$evt" | jq -r '.type // ""' 2>/dev/null)
                    evt_issue=$(echo "$evt" | jq -r '.issue // ""' 2>/dev/null)

                    # Format timestamp as HH:MM
                    evt_time=""
                    if [[ -n "$evt_ts" && "$evt_ts" != "null" ]]; then
                        evt_time=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$evt_ts" +"%H:%M" 2>/dev/null || echo "")
                    fi

                    case "$evt_type" in
                        daemon.spawn)
                            echo -e "    ${DIM}${evt_time}${RESET}  ${GREEN}↳${RESET} Spawned pipeline for #${evt_issue}"
                            ;;
                        daemon.reap)
                            evt_result=$(echo "$evt" | jq -r '.result // ""' 2>/dev/null)
                            evt_dur=$(echo "$evt" | jq -r '.duration_s // 0' 2>/dev/null)
                            dur_display=""
                            if [[ "$evt_dur" -gt 0 ]] 2>/dev/null; then
                                if [[ "$evt_dur" -ge 3600 ]]; then
                                    dur_display=$(printf " (%dh %dm)" $((evt_dur/3600)) $((evt_dur%3600/60)))
                                elif [[ "$evt_dur" -ge 60 ]]; then
                                    dur_display=$(printf " (%dm %ds)" $((evt_dur/60)) $((evt_dur%60)))
                                else
                                    dur_display=$(printf " (%ds)" "$evt_dur")
                                fi
                            fi
                            if [[ "$evt_result" == "success" ]]; then
                                echo -e "    ${DIM}${evt_time}${RESET}  ${GREEN}●${RESET} #${evt_issue} completed${dur_display}"
                            else
                                echo -e "    ${DIM}${evt_time}${RESET}  ${RED}●${RESET} #${evt_issue} failed${dur_display}"
                            fi
                            ;;
                        stage.started)
                            evt_stage=$(echo "$evt" | jq -r '.stage // ""' 2>/dev/null)
                            echo -e "    ${DIM}${evt_time}${RESET}  ${BLUE}●${RESET} #${evt_issue} started ${evt_stage}"
                            ;;
                        stage.completed)
                            evt_stage=$(echo "$evt" | jq -r '.stage // ""' 2>/dev/null)
                            echo -e "    ${DIM}${evt_time}${RESET}  ${DIM}●${RESET} #${evt_issue} completed ${evt_stage}"
                            ;;
                        daemon.poll)
                            evt_found=$(echo "$evt" | jq -r '.issues_found // 0' 2>/dev/null)
                            echo -e "    ${DIM}${evt_time}  ⟳ Polled — ${evt_found} issue(s) found${RESET}"
                            ;;
                    esac
                done <<< "$recent_events"
            fi
        fi
    fi
fi

# ─── Issue Tracker ─────────────────────────────────────────────────────────

TRACKER_CONFIG="${HOME}/.claude-teams/tracker-config.json"
if [[ -f "$TRACKER_CONFIG" ]]; then
    TRACKER_PROVIDER=$(jq -r '.provider // "none"' "$TRACKER_CONFIG" 2>/dev/null || echo "none")
    if [[ "$TRACKER_PROVIDER" != "none" && -n "$TRACKER_PROVIDER" ]]; then
        echo ""
        echo -e "${PURPLE}${BOLD}  ISSUE TRACKER${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
        case "$TRACKER_PROVIDER" in
            linear)
                echo -e "  ${GREEN}●${RESET} ${BOLD}Linear${RESET}  ${DIM}(run shipwright linear status for details)${RESET}"
                ;;
            jira)
                JIRA_URL=$(jq -r '.jira.base_url // ""' "$TRACKER_CONFIG" 2>/dev/null || true)
                echo -e "  ${GREEN}●${RESET} ${BOLD}Jira${RESET}  ${DIM}${JIRA_URL}${RESET}  ${DIM}(run shipwright jira status for details)${RESET}"
                ;;
        esac
    fi
fi

# ─── Agent Heartbeats ──────────────────────────────────────────────────────

HEARTBEAT_DIR="$HOME/.claude-teams/heartbeats"
HAS_HEARTBEATS=false

if [[ -d "$HEARTBEAT_DIR" ]]; then
    hb_count=0
    for hb_file in "${HEARTBEAT_DIR}"/*.json; do
        [[ -f "$hb_file" ]] || continue
        hb_count=$((hb_count + 1))
    done

    if [[ "$hb_count" -gt 0 ]]; then
        HAS_HEARTBEATS=true
        echo ""
        echo -e "${PURPLE}${BOLD}  AGENT HEARTBEATS${RESET}  ${DIM}(${hb_count} active)${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

        for hb_file in "${HEARTBEAT_DIR}"/*.json; do
            [[ -f "$hb_file" ]] || continue
            local_job_id="$(basename "$hb_file" .json)"
            hb_pid=$(jq -r '.pid // ""' "$hb_file" 2>/dev/null || true)
            hb_stage=$(jq -r '.stage // ""' "$hb_file" 2>/dev/null || true)
            hb_issue=$(jq -r '.issue // ""' "$hb_file" 2>/dev/null || true)
            hb_iter=$(jq -r '.iteration // ""' "$hb_file" 2>/dev/null || true)
            hb_activity=$(jq -r '.last_activity // ""' "$hb_file" 2>/dev/null || true)
            hb_updated=$(jq -r '.updated_at // ""' "$hb_file" 2>/dev/null || true)
            hb_mem=$(jq -r '.memory_mb // 0' "$hb_file" 2>/dev/null || true)

            # Check if process is still alive
            hb_alive=false
            if [[ -n "$hb_pid" && "$hb_pid" != "null" ]] && kill -0 "$hb_pid" 2>/dev/null; then
                hb_alive=true
            fi

            # Calculate age
            hb_age_str=""
            if [[ -n "$hb_updated" && "$hb_updated" != "null" ]]; then
                hb_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$hb_updated" +%s 2>/dev/null || echo 0)
                if [[ "$hb_epoch" -gt 0 ]]; then
                    now_e=$(date +%s)
                    hb_age=$((now_e - hb_epoch))
                    if [[ "$hb_age" -ge 120 ]]; then
                        hb_age_str="${RED}${hb_age}s ago (STALE)${RESET}"
                    else
                        hb_age_str="${DIM}${hb_age}s ago${RESET}"
                    fi
                fi
            fi

            if $hb_alive; then
                hb_icon="${GREEN}●${RESET}"
            else
                hb_icon="${RED}●${RESET}"
            fi

            echo -e "  ${hb_icon} ${BOLD}${local_job_id}${RESET}  ${DIM}pid:${hb_pid}${RESET}"
            detail_line="    "
            [[ -n "$hb_issue" && "$hb_issue" != "null" && "$hb_issue" != "0" ]] && detail_line+="${CYAN}#${hb_issue}${RESET}  "
            [[ -n "$hb_stage" && "$hb_stage" != "null" ]] && detail_line+="${BLUE}${hb_stage}${RESET}  "
            [[ -n "$hb_iter" && "$hb_iter" != "null" ]] && detail_line+="${DIM}iter:${hb_iter}${RESET}  "
            [[ -n "$hb_age_str" ]] && detail_line+="${hb_age_str}  "
            [[ "${hb_mem:-0}" -gt 0 ]] && detail_line+="${DIM}${hb_mem}MB${RESET}"
            echo -e "$detail_line"
            [[ -n "$hb_activity" && "$hb_activity" != "null" ]] && echo -e "    ${DIM}${hb_activity}${RESET}"
        done
    fi
fi

# ─── Remote Machines ──────────────────────────────────────────────────────

MACHINES_FILE="$HOME/.claude-teams/machines.json"
if [[ -f "$MACHINES_FILE" ]]; then
    machine_count=$(jq '.machines | length' "$MACHINES_FILE" 2>/dev/null || echo 0)
    if [[ "$machine_count" -gt 0 ]]; then
        echo ""
        echo -e "${PURPLE}${BOLD}  REMOTE MACHINES${RESET}  ${DIM}(${machine_count} registered)${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

        while IFS= read -r machine; do
            [[ -z "$machine" ]] && continue
            m_name=$(echo "$machine" | jq -r '.name // ""')
            m_host=$(echo "$machine" | jq -r '.host // ""')
            m_cores=$(echo "$machine" | jq -r '.cores // "?"')
            m_mem=$(echo "$machine" | jq -r '.memory_gb // "?"')
            m_workers=$(echo "$machine" | jq -r '.max_workers // "?"')

            echo -e "  ${BLUE}●${RESET} ${BOLD}${m_name}${RESET}  ${DIM}${m_host}${RESET}  ${DIM}cores:${m_cores} mem:${m_mem}GB workers:${m_workers}${RESET}"
        done < <(jq -c '.machines[]' "$MACHINES_FILE" 2>/dev/null)
    fi
fi

# ─── Footer ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
if $HAS_CLAUDE_WINDOWS || $HAS_TEAMS || $HAS_TASKS || $HAS_DAEMON || ${HAS_HEARTBEATS:-false}; then
    echo -e "  ${DIM}Clean up:${RESET} ${CYAN}shipwright cleanup${RESET}  ${DIM}|${RESET}  ${DIM}New session:${RESET} ${CYAN}shipwright session <name>${RESET}"
else
    echo -e "  ${DIM}No active teams. Start one:${RESET} ${CYAN}shipwright session <name>${RESET}"
fi
echo ""

fi  # end JSON_OUTPUT conditional
