#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-status.sh — Dashboard showing Claude Code team status               ║
# ║                                                                          ║
# ║  Shows running teams, agent windows, and task progress.                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="2.1.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

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

# ─── Argument Parsing ─────────────────────────────────────────────────────────
JSON_OUTPUT="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)  JSON_OUTPUT="true"; shift ;;
        --help|-h)
            echo "Usage: shipwright status [--json]"
            echo ""
            echo "Options:"
            echo "  --json    Output structured JSON instead of formatted text"
            echo "  --help    Show this help message"
            exit 0
            ;;
        *)  echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ─── JSON Output Mode ─────────────────────────────────────────────────────────
if [[ "$JSON_OUTPUT" == "true" ]]; then
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required for --json output" >&2
        exit 1
    fi

    # -- tmux windows --
    WINDOWS_JSON="[]"
    if command -v tmux &>/dev/null; then
        WINDOWS_JSON=$(tmux list-windows -a -F '#{session_name}:#{window_index}|#{window_name}|#{window_panes}|#{window_active}' 2>/dev/null | \
            while IFS='|' read -r sw wn pc act; do
                is_claude="false"
                echo "$wn" | grep -qi "claude" && is_claude="true"
                is_active="false"
                [[ "$act" == "1" ]] && is_active="true"
                printf '%s\n' "{\"session_window\":\"$sw\",\"name\":\"$wn\",\"panes\":$pc,\"active\":$is_active,\"claude\":$is_claude}"
            done | jq -s '.' 2>/dev/null) || WINDOWS_JSON="[]"
    fi

    # -- team configs --
    TEAMS_JSON="[]"
    _teams_dir="${HOME}/.claude/teams"
    if [[ -d "$_teams_dir" ]]; then
        TEAMS_JSON=$(find "$_teams_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | \
            while IFS= read -r td; do
                [[ -z "$td" ]] && continue
                tn="$(basename "$td")"
                cf="${td}/config.json"
                if [[ -f "$cf" ]]; then
                    mc=$(jq '.members | length' "$cf" 2>/dev/null || echo 0)
                    printf '%s\n' "{\"name\":\"$tn\",\"members\":$mc,\"has_config\":true}"
                else
                    printf '%s\n' "{\"name\":\"$tn\",\"members\":0,\"has_config\":false}"
                fi
            done | jq -s '.' 2>/dev/null) || TEAMS_JSON="[]"
    fi

    # -- task lists --
    TASKS_JSON="[]"
    _tasks_dir="${HOME}/.claude/tasks"
    if [[ -d "$_tasks_dir" ]]; then
        _tasks_tmp=""
        while IFS= read -r td; do
            [[ -z "$td" ]] && continue
            tn="$(basename "$td")"
            _total=0; _completed=0; _in_progress=0; _pending=0
            while IFS= read -r tf; do
                [[ -z "$tf" ]] && continue
                _total=$((_total + 1))
                _st=$(jq -r '.status // "unknown"' "$tf" 2>/dev/null || echo "unknown")
                case "$_st" in
                    completed)   _completed=$((_completed + 1)) ;;
                    in_progress) _in_progress=$((_in_progress + 1)) ;;
                    pending)     _pending=$((_pending + 1)) ;;
                esac
            done < <(find "$td" -type f -name '*.json' 2>/dev/null)
            _tasks_tmp="${_tasks_tmp}{\"team\":\"$tn\",\"total\":$_total,\"completed\":$_completed,\"in_progress\":$_in_progress,\"pending\":$_pending}
"
        done < <(find "$_tasks_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
        if [[ -n "$_tasks_tmp" ]]; then
            TASKS_JSON=$(printf '%s' "$_tasks_tmp" | jq -s '.' 2>/dev/null) || TASKS_JSON="[]"
        fi
    fi

    # -- daemon --
    DAEMON_JSON="null"
    _state_file="${HOME}/.shipwright/daemon-state.json"
    _pid_file="${HOME}/.shipwright/daemon.pid"
    if [[ -f "$_state_file" ]]; then
        _d_running="false"
        _d_pid="null"
        if [[ -f "$_pid_file" ]]; then
            _d_pid_val=$(cat "$_pid_file" 2>/dev/null || true)
            if [[ -n "$_d_pid_val" ]] && kill -0 "$_d_pid_val" 2>/dev/null; then
                _d_running="true"
                _d_pid="$_d_pid_val"
            fi
        fi
        _active=$(jq -c '.active_jobs // []' "$_state_file" 2>/dev/null || echo "[]")
        _queued=$(jq -c '.queued // []' "$_state_file" 2>/dev/null || echo "[]")
        _completed=$(jq -c '[.completed // [] | reverse | .[:20][]]' "$_state_file" 2>/dev/null || echo "[]")
        _started_at=$(jq -r '.started_at // null' "$_state_file" 2>/dev/null || echo "null")
        _last_poll=$(jq -r '.last_poll // null' "$_state_file" 2>/dev/null || echo "null")
        DAEMON_JSON=$(jq -n \
            --argjson running "$_d_running" \
            --argjson pid "$_d_pid" \
            --argjson active_jobs "$_active" \
            --argjson queued "$_queued" \
            --argjson recent_completions "$_completed" \
            --arg started_at "$_started_at" \
            --arg last_poll "$_last_poll" \
            '{running:$running, pid:$pid, started_at:$started_at, last_poll:$last_poll, active_jobs:$active_jobs, queued:$queued, recent_completions:$recent_completions}') || DAEMON_JSON="null"
    fi

    # -- issue tracker --
    TRACKER_JSON="null"
    _tracker_cfg="${HOME}/.shipwright/tracker-config.json"
    if [[ -f "$_tracker_cfg" ]]; then
        _provider=$(jq -r '.provider // "none"' "$_tracker_cfg" 2>/dev/null || echo "none")
        if [[ "$_provider" != "none" && -n "$_provider" ]]; then
            _url="null"
            [[ "$_provider" == "jira" ]] && _url=$(jq -r '.jira.base_url // null' "$_tracker_cfg" 2>/dev/null || echo "null")
            TRACKER_JSON=$(jq -n --arg provider "$_provider" --arg url "$_url" '{provider:$provider, url:$url}') || TRACKER_JSON="null"
        fi
    fi

    # -- heartbeats --
    HEARTBEATS_JSON="[]"
    _hb_dir="${HOME}/.shipwright/heartbeats"
    if [[ -d "$_hb_dir" ]]; then
        HEARTBEATS_JSON=$(find "$_hb_dir" -name '*.json' -type f 2>/dev/null | \
            while IFS= read -r hf; do
                [[ -z "$hf" ]] && continue
                _jid="$(basename "$hf" .json)"
                _stage=$(jq -r '.stage // "unknown"' "$hf" 2>/dev/null || echo "unknown")
                _ts=$(jq -r '.timestamp // null' "$hf" 2>/dev/null || echo "null")
                _iter=$(jq -r '.iteration // 0' "$hf" 2>/dev/null || echo "0")
                printf '%s\n' "{\"job_id\":\"$_jid\",\"stage\":\"$_stage\",\"timestamp\":\"$_ts\",\"iteration\":$_iter}"
            done | jq -s '.' 2>/dev/null) || HEARTBEATS_JSON="[]"
    fi

    # -- remote machines --
    MACHINES_JSON="[]"
    _machines_file="${HOME}/.shipwright/machines.json"
    if [[ -f "$_machines_file" ]]; then
        MACHINES_JSON=$(jq -c '.machines // []' "$_machines_file" 2>/dev/null) || MACHINES_JSON="[]"
    fi

    # -- connected developers --
    DEVELOPERS_JSON="null"
    _team_cfg="${HOME}/.shipwright/team-config.json"
    if [[ -f "$_team_cfg" ]]; then
        _dash_url=$(jq -r '.dashboard_url // ""' "$_team_cfg" 2>/dev/null || true)
        if [[ -n "$_dash_url" ]] && command -v curl &>/dev/null; then
            _api_resp=$(curl -s --max-time 3 "${_dash_url}/api/status" 2>/dev/null || echo "")
            if [[ -n "$_api_resp" ]] && echo "$_api_resp" | jq empty 2>/dev/null; then
                _online=$(echo "$_api_resp" | jq '.total_online // 0' 2>/dev/null || echo "0")
                _devs=$(echo "$_api_resp" | jq -c '.developers // []' 2>/dev/null || echo "[]")
                DEVELOPERS_JSON=$(jq -n --argjson reachable true --argjson total_online "$_online" --argjson developers "$_devs" \
                    '{reachable:$reachable, total_online:$total_online, developers:$developers}') || DEVELOPERS_JSON="null"
            else
                DEVELOPERS_JSON='{"reachable":false,"total_online":0,"developers":[]}'
            fi
        fi
    fi

    # -- database --
    DATABASE_JSON="null"
    _db_file="${HOME}/.shipwright/shipwright.db"
    if command -v sqlite3 &>/dev/null && [[ -f "$_db_file" ]]; then
        _db_ver=$(sqlite3 "$_db_file" "SELECT MAX(version) FROM _schema;" 2>/dev/null || echo "0")
        _db_wal=$(sqlite3 "$_db_file" "PRAGMA journal_mode;" 2>/dev/null || echo "unknown")
        _db_events=$(sqlite3 "$_db_file" "SELECT COUNT(*) FROM events;" 2>/dev/null || echo "0")
        _db_runs=$(sqlite3 "$_db_file" "SELECT COUNT(*) FROM pipeline_runs;" 2>/dev/null || echo "0")
        _db_costs=$(sqlite3 "$_db_file" "SELECT COUNT(*) FROM cost_entries;" 2>/dev/null || echo "0")
        _db_size=$(ls -l "$_db_file" 2>/dev/null | awk '{print $5}')
        DATABASE_JSON=$(jq -n \
            --argjson schema_version "${_db_ver:-0}" \
            --arg wal_mode "$_db_wal" \
            --argjson events "${_db_events:-0}" \
            --argjson runs "${_db_runs:-0}" \
            --argjson costs "${_db_costs:-0}" \
            --argjson size_bytes "${_db_size:-0}" \
            '{schema_version:$schema_version, wal_mode:$wal_mode, events:$events, runs:$runs, costs:$costs, size_bytes:$size_bytes}') || DATABASE_JSON="null"
    fi

    # -- assemble and output --
    jq -n \
        --arg version "$VERSION" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson tmux_windows "$WINDOWS_JSON" \
        --argjson teams "$TEAMS_JSON" \
        --argjson task_lists "$TASKS_JSON" \
        --argjson daemon "$DAEMON_JSON" \
        --argjson issue_tracker "$TRACKER_JSON" \
        --argjson heartbeats "$HEARTBEATS_JSON" \
        --argjson remote_machines "$MACHINES_JSON" \
        --argjson connected_developers "$DEVELOPERS_JSON" \
        --argjson database "$DATABASE_JSON" \
        '{
            version: $version,
            timestamp: $timestamp,
            tmux_windows: $tmux_windows,
            teams: $teams,
            task_lists: $task_lists,
            daemon: $daemon,
            issue_tracker: $issue_tracker,
            heartbeats: $heartbeats,
            remote_machines: $remote_machines,
            connected_developers: $connected_developers,
            database: $database
        }'
    exit 0
fi

# ─── Header ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}${BOLD}  Shipwright — Status Dashboard${RESET}"
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

DAEMON_DIR="${HOME}/.shipwright"
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
        echo -e "${PURPLE}${BOLD}  DAEMON PIPELINES${RESET}  ${DIM}~/.shipwright/${RESET}"
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
                    ps_file="${a_worktree}/.claude/pipeline-state.md"
                    stage_str=$(grep -E '^current_stage:' "$ps_file" 2>/dev/null | head -1 | sed 's/^current_stage:[[:space:]]*//' || true)
                    stage_desc=$(grep -E '^current_stage_description:' "$ps_file" 2>/dev/null | head -1 | sed 's/^current_stage_description:[[:space:]]*"//;s/"$//' || true)
                    stage_progress=$(grep -E '^stage_progress:' "$ps_file" 2>/dev/null | head -1 | sed 's/^stage_progress:[[:space:]]*"//;s/"$//' || true)
                    goal_from_state=$(grep -E '^goal:' "$ps_file" 2>/dev/null | head -1 | sed 's/^goal:[[:space:]]*"//;s/"$//' || true)
                fi

                # Use goal from state file if not in daemon job data
                display_goal="${a_goal:-$goal_from_state}"

                # Title line
                echo -e "    ${CYAN}#${a_issue}${RESET}  ${BOLD}${a_title}${RESET}"

                # Goal line (if different from title)
                if [[ -n "$display_goal" && "$display_goal" != "$a_title" ]]; then
                    echo -e "           ${DIM}Delivering: ${display_goal}${RESET}"
                fi

                # Stage + description line
                if [[ -n "$stage_str" ]]; then
                    stage_icon="🔄"
                    stage_line="           ${stage_icon} ${BLUE}${stage_str}${RESET}"
                    [[ -n "$stage_desc" ]] && stage_line="${stage_line} ${DIM}— ${stage_desc}${RESET}"
                    echo -e "$stage_line"
                fi

                # Inline progress bar from stage_progress
                if [[ -n "$stage_progress" ]]; then
                    progress_bar=""
                    entry=""
                    # Parse space-separated "stage:status" pairs
                    for entry in $stage_progress; do
                        s_name="${entry%%:*}"
                        s_stat="${entry#*:}"
                        s_icon=""
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

TRACKER_CONFIG="${HOME}/.shipwright/tracker-config.json"
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

HEARTBEAT_DIR="$HOME/.shipwright/heartbeats"
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

MACHINES_FILE="$HOME/.shipwright/machines.json"
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

# ─── Database ────────────────────────────────────────────────────────────

_DB_FILE="${HOME}/.shipwright/shipwright.db"
if command -v sqlite3 &>/dev/null && [[ -f "$_DB_FILE" ]]; then
    echo ""
    echo -e "${PURPLE}${BOLD}  DATABASE${RESET}  ${DIM}~/.shipwright/shipwright.db${RESET}"
    echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

    _db_wal=$(sqlite3 "$_DB_FILE" "PRAGMA journal_mode;" 2>/dev/null || echo "?")
    _db_ver=$(sqlite3 "$_DB_FILE" "SELECT MAX(version) FROM _schema;" 2>/dev/null || echo "?")
    _db_size_bytes=$(ls -l "$_DB_FILE" 2>/dev/null | awk '{print $5}')
    _db_size_mb=$(awk -v s="${_db_size_bytes:-0}" 'BEGIN { printf "%.1f", s / 1048576 }')
    _db_events=$(sqlite3 "$_DB_FILE" "SELECT COUNT(*) FROM events;" 2>/dev/null || echo "0")
    _db_runs=$(sqlite3 "$_DB_FILE" "SELECT COUNT(*) FROM pipeline_runs;" 2>/dev/null || echo "0")
    _db_costs=$(sqlite3 "$_DB_FILE" "SELECT COUNT(*) FROM cost_entries;" 2>/dev/null || echo "0")

    echo -e "  ${GREEN}●${RESET} ${BOLD}SQLite${RESET}  ${DIM}v${_db_ver} WAL=${_db_wal} ${_db_size_mb}MB${RESET}"
    echo -e "    ${DIM}events:${_db_events}  runs:${_db_runs}  costs:${_db_costs}${RESET}"
fi

# ─── Connected Developers ─────────────────────────────────────────────────

# Check if curl and jq are available
if command -v curl &>/dev/null && command -v jq &>/dev/null; then
    # Read dashboard URL from config, fall back to default
    TEAM_CONFIG="${HOME}/.shipwright/team-config.json"
    DASHBOARD_URL=""
    if [[ -f "$TEAM_CONFIG" ]]; then
        DASHBOARD_URL=$(jq -r '.dashboard_url // ""' "$TEAM_CONFIG" 2>/dev/null || true)
    fi
    [[ -z "$DASHBOARD_URL" ]] && DASHBOARD_URL="http://localhost:8767"

    # Try to reach the dashboard /api/team endpoint with 3s timeout
    api_response=$(curl -s --max-time 3 "$DASHBOARD_URL/api/team" 2>/dev/null || true)

    # Check if we got a valid response
    if [[ -n "$api_response" ]] && echo "$api_response" | jq empty 2>/dev/null; then
        echo ""
        echo -e "${PURPLE}${BOLD}  CONNECTED DEVELOPERS${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"

        # Parse total_online count
        total_online=$(echo "$api_response" | jq -r '.total_online // 0' 2>/dev/null)

        # Parse developers array and display table
        dev_count=$(echo "$api_response" | jq '.developers | length' 2>/dev/null || echo 0)
        if [[ "$dev_count" -gt 0 ]]; then
            while IFS= read -r developer; do
                [[ -z "$developer" ]] && continue

                dev_id=$(echo "$developer" | jq -r '.developer_id // "?"')
                dev_machine=$(echo "$developer" | jq -r '.machine_name // "?"')
                dev_status=$(echo "$developer" | jq -r '.status // "offline"')
                active_jobs=$(echo "$developer" | jq '.active_jobs | length' 2>/dev/null || echo 0)
                queued=$(echo "$developer" | jq '.queued | length' 2>/dev/null || echo 0)

                # Status indicator and color
                case "$dev_status" in
                    online)
                        status_icon="${GREEN}●${RESET}"
                        status_label="${GREEN}online${RESET}"
                        ;;
                    idle)
                        status_icon="${YELLOW}●${RESET}"
                        status_label="${YELLOW}idle${RESET}"
                        ;;
                    offline|*)
                        status_icon="${DIM}●${RESET}"
                        status_label="${DIM}offline${RESET}"
                        ;;
                esac

                echo -e "  ${status_icon} ${BOLD}${dev_id}${RESET}  ${DIM}${dev_machine}${RESET}  ${status_label}  ${DIM}active:${active_jobs} queued:${queued}${RESET}"
            done < <(echo "$api_response" | jq -c '.developers[]' 2>/dev/null)

            # Display total online count
            echo -e "  ${DIM}────────────────────────────────────────────${RESET}"
            echo -e "  ${DIM}Total online: ${GREEN}${total_online}${RESET}${DIM} / ${dev_count}${RESET}"
        else
            echo -e "  ${DIM}No developers connected${RESET}"
        fi
    else
        # Dashboard not reachable — show dim message
        echo ""
        echo -e "${PURPLE}${BOLD}  CONNECTED DEVELOPERS${RESET}"
        echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
        echo -e "  ${DIM}Dashboard not reachable (${DASHBOARD_URL})${RESET}"
    fi
elif [[ -f "$HOME/.shipwright/team-config.json" ]] || [[ -f "$HOME/.shipwright/daemon-state.json" ]]; then
    # If we have shipwright config but curl/jq missing, show info
    echo ""
    echo -e "${PURPLE}${BOLD}  CONNECTED DEVELOPERS${RESET}"
    echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    echo -e "  ${DIM}curl or jq not available to check dashboard${RESET}"
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
