#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fleet — Multi-Repo Daemon Orchestrator                            ║
# ║  Spawns daemons across repos · Fleet dashboard · Aggregate metrics     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.9.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

epoch_to_iso() {
    local epoch="$1"
    date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    echo "1970-01-01T00:00:00Z"
}

format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 3600 ]]; then
        printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%ds" "$secs"
    fi
}

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

emit_event() {
    local event_type="$1"
    shift
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            val="${val//\"/\\\"}"
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Defaults ───────────────────────────────────────────────────────────────
FLEET_DIR="$HOME/.shipwright"
FLEET_STATE="$FLEET_DIR/fleet-state.json"
CONFIG_PATH=""

# ─── CLI Argument Parsing ──────────────────────────────────────────────────
SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_PATH="${2:-}"
            shift 2
            ;;
        --config=*)
            CONFIG_PATH="${1#--config=}"
            shift
            ;;
        --help|-h)
            SUBCOMMAND="help"
            shift
            ;;
        --period)
            METRICS_PERIOD="${2:-7}"
            shift 2
            ;;
        --period=*)
            METRICS_PERIOD="${1#--period=}"
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

METRICS_PERIOD="${METRICS_PERIOD:-7}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ shipwright fleet v${VERSION} ━━━${RESET}"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright fleet${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}start${RESET}                              Start daemons for all configured repos"
    echo -e "  ${CYAN}stop${RESET}                               Stop all fleet daemons"
    echo -e "  ${CYAN}status${RESET}                             Show fleet dashboard"
    echo -e "  ${CYAN}metrics${RESET}  [--period N] [--json]     Aggregate DORA metrics across repos"
    echo -e "  ${CYAN}init${RESET}                               Generate fleet-config.json"
    echo -e "  ${CYAN}help${RESET}                               Show this help"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--config${RESET} <path>   Path to fleet-config.json ${DIM}(default: .claude/fleet-config.json)${RESET}"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright fleet init${RESET}                           # Generate config"
    echo -e "  ${DIM}shipwright fleet start${RESET}                          # Start all daemons"
    echo -e "  ${DIM}shipwright fleet start --config my-fleet.json${RESET}   # Custom config"
    echo -e "  ${DIM}shipwright fleet status${RESET}                         # Fleet dashboard"
    echo -e "  ${DIM}shipwright fleet metrics --period 30${RESET}            # 30-day aggregate"
    echo -e "  ${DIM}shipwright fleet stop${RESET}                           # Stop everything"
    echo ""
    echo -e "${BOLD}CONFIG FILE${RESET}  ${DIM}(.claude/fleet-config.json)${RESET}"
    echo -e '  {
    "repos": [
      { "path": "/path/to/api", "template": "autonomous", "max_parallel": 2 },
      { "path": "/path/to/web", "template": "standard" }
    ],
    "defaults": {
      "watch_label": "ready-to-build",
      "pipeline_template": "autonomous",
      "max_parallel": 2,
      "model": "opus"
    },
    "shared_events": true
  }'
    echo ""
}

# ─── Config Loading ─────────────────────────────────────────────────────────

load_fleet_config() {
    local config_file="${CONFIG_PATH:-.claude/fleet-config.json}"

    if [[ ! -f "$config_file" ]]; then
        error "Fleet config not found: $config_file"
        info "Run ${CYAN}shipwright fleet init${RESET} to generate one"
        exit 1
    fi

    info "Loading fleet config: ${DIM}${config_file}${RESET}" >&2

    # Validate JSON
    if ! jq empty "$config_file" 2>/dev/null; then
        error "Invalid JSON in $config_file"
        exit 1
    fi

    # Check repos array exists
    local repo_count
    repo_count=$(jq '.repos | length' "$config_file")
    if [[ "$repo_count" -eq 0 ]]; then
        error "No repos configured in $config_file"
        exit 1
    fi

    echo "$config_file"
}

# ─── Session Name ───────────────────────────────────────────────────────────

session_name_for_repo() {
    local repo_path="$1"
    local basename
    basename=$(basename "$repo_path")
    echo "shipwright-fleet-${basename}"
}

# ─── GitHub-Aware Repo Priority ──────────────────────────────────────────
# Returns a priority score (default 50) for a repo based on GitHub data.
# Used when intelligence.fleet_weighting is enabled.

_fleet_repo_priority() {
    local repo_path="$1"
    local priority=50  # default neutral priority

    type _gh_detect_repo &>/dev/null 2>&1 || { echo "$priority"; return 0; }

    # Detect repo from the repo path (run in subshell to avoid cd side-effects)
    local gh_priority
    gh_priority=$(
        cd "$repo_path" 2>/dev/null || exit 1
        _gh_detect_repo 2>/dev/null || exit 1
        local owner="${GH_OWNER:-}" repo="${GH_REPO:-}"
        [[ -z "$owner" || -z "$repo" ]] && exit 1

        local p=50

        # Factor: security alerts (urgent work)
        if type gh_security_alerts &>/dev/null 2>&1; then
            local alerts
            alerts=$(gh_security_alerts "$owner" "$repo" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
            if [[ "${alerts:-0}" -gt 5 ]]; then
                p=$((p + 20))
            elif [[ "${alerts:-0}" -gt 0 ]]; then
                p=$((p + 10))
            fi
        fi

        # Factor: contributor count (more contributors = more active = higher priority)
        if type gh_contributors &>/dev/null 2>&1; then
            local contribs
            contribs=$(gh_contributors "$owner" "$repo" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
            if [[ "${contribs:-0}" -gt 10 ]]; then
                p=$((p + 10))
            fi
        fi

        echo "$p"
    ) || echo "$priority"

    echo "${gh_priority:-$priority}"
}

# ─── Worker Pool Rebalancer ───────────────────────────────────────────────
# Runs in background, redistributes MAX_PARALLEL across repos based on demand

fleet_rebalance() {
    local config_file="$1"
    local interval
    interval=$(jq -r '.worker_pool.rebalance_interval_seconds // 120' "$config_file")
    local total_workers
    total_workers=$(jq -r '.worker_pool.total_workers // 12' "$config_file")

    local shutdown_flag="$HOME/.shipwright/fleet-rebalancer.shutdown"
    rm -f "$shutdown_flag"

    while true; do
        sleep "$interval"

        # Check for shutdown signal or missing state
        if [[ -f "$shutdown_flag" ]] || [[ ! -f "$FLEET_STATE" ]]; then
            break
        fi

        local repo_names
        repo_names=$(jq -r '.repos | keys[]' "$FLEET_STATE" 2>/dev/null || true)
        if [[ -z "$repo_names" ]]; then
            continue
        fi

        # Collect demand per repo using indexed arrays (bash 3.2 compatible)
        # When intelligence is available, weight by complexity × urgency
        local repo_list=()
        local demand_list=()
        local weight_list=()
        local total_demand=0
        local total_weight=0
        local repo_count=0

        # Check if intelligence weighting is enabled
        local intel_weighting=false
        local fleet_intel_enabled
        fleet_intel_enabled=$(jq -r '.intelligence.fleet_weighting // false' "$config_file" 2>/dev/null || echo "false")
        if [[ "$fleet_intel_enabled" == "true" ]]; then
            intel_weighting=true
        fi

        while IFS= read -r repo_name; do
            local repo_path
            repo_path=$(jq -r --arg r "$repo_name" '.repos[$r].path' "$FLEET_STATE" 2>/dev/null || true)
            [[ -z "$repo_path" || "$repo_path" == "null" ]] && continue

            # Read daemon state — try repo-local state first
            local active=0 queued=0
            local daemon_state="$repo_path/.shipwright/daemon-state.json"
            if [[ ! -f "$daemon_state" ]]; then
                # Fall back to shared state, filtered by repo
                daemon_state="$HOME/.shipwright/daemon-state.json"
            fi
            if [[ -f "$daemon_state" ]]; then
                active=$(jq -r '.active_jobs | length // 0' "$daemon_state" 2>/dev/null || echo 0)
                queued=$(jq -r '.queued | length // 0' "$daemon_state" 2>/dev/null || echo 0)
                # Validate numeric
                [[ ! "$active" =~ ^[0-9]+$ ]] && active=0
                [[ ! "$queued" =~ ^[0-9]+$ ]] && queued=0
            fi

            local demand=$((active + queued))

            # Compute intelligence weight: complexity × urgency
            # Falls back to raw demand when no intelligence data exists
            local weight="$demand"
            if [[ "$intel_weighting" == "true" && "$demand" -gt 0 ]]; then
                local intel_cache="$repo_path/.claude/intelligence-cache.json"
                local avg_complexity=50
                local urgency_factor=1

                # Read average issue complexity from intelligence cache
                if [[ -f "$intel_cache" ]]; then
                    local cached_complexity
                    cached_complexity=$(jq -r '.analysis.avg_issue_complexity // 50' "$intel_cache" 2>/dev/null || echo "50")
                    [[ "$cached_complexity" =~ ^[0-9]+$ ]] && avg_complexity="$cached_complexity"
                fi

                # Check for deadline urgency in queued issues
                if [[ -f "$daemon_state" ]]; then
                    local urgent_count=0
                    local urgent_raw
                    urgent_raw=$(jq -r '[.queued[]? | select(.labels[]? == "priority" or .labels[]? == "urgent" or .labels[]? == "hotfix")] | length' "$daemon_state" 2>/dev/null || echo "0")
                    [[ "$urgent_raw" =~ ^[0-9]+$ ]] && urgent_count="$urgent_raw"

                    if [[ "$queued" -gt 0 && "$urgent_count" -gt 0 ]]; then
                        # Urgency boost: 1.0 base + 0.5 per urgent ratio
                        urgency_factor=$(awk -v uc="$urgent_count" -v q="$queued" \
                            'BEGIN { r = uc / q; f = 1.0 + (r * 0.5); printf "%.0f", f * 100 }')
                        # urgency_factor is now scaled by 100 (e.g. 150 = 1.5x)
                    else
                        urgency_factor=100
                    fi
                else
                    urgency_factor=100
                fi

                # GitHub priority factor (normalized: priority / 50, so 50 = 1.0x)
                local gh_priority_factor=100  # 100 = 1.0x (neutral)
                if [[ -n "$repo_path" && "$repo_path" != "null" ]]; then
                    local gh_prio
                    gh_prio=$(_fleet_repo_priority "$repo_path" 2>/dev/null || echo "50")
                    [[ "$gh_prio" =~ ^[0-9]+$ ]] && gh_priority_factor=$((gh_prio * 2))
                fi

                # Weight = demand × (complexity / 50) × (urgency / 100) × (gh_priority / 100)
                weight=$(awk -v d="$demand" -v c="$avg_complexity" -v u="$urgency_factor" -v g="$gh_priority_factor" \
                    'BEGIN { w = d * (c / 50.0) * (u / 100.0) * (g / 100.0); if (w < 1) w = 1; printf "%.0f", w }')
            fi

            repo_list+=("$repo_name")
            demand_list+=("$demand")
            weight_list+=("$weight")
            total_demand=$((total_demand + demand))
            total_weight=$((total_weight + weight))
            repo_count=$((repo_count + 1))
        done <<< "$repo_names"

        if [[ "$repo_count" -eq 0 ]]; then
            continue
        fi

        # Distribute workers proportionally with budget enforcement
        # When intelligence weighting is active, use weighted demand
        local allocated_total=0
        local alloc_list=()
        local use_weight="$total_weight"
        local effective_total="$total_demand"
        if [[ "$intel_weighting" == "true" && "$total_weight" -gt 0 ]]; then
            effective_total="$total_weight"
        fi

        local i
        for i in $(seq 0 $((repo_count - 1))); do
            local new_max
            if [[ "$effective_total" -eq 0 ]]; then
                new_max=$(( total_workers / repo_count ))
            else
                local repo_score
                if [[ "$intel_weighting" == "true" && "$total_weight" -gt 0 ]]; then
                    repo_score="${weight_list[$i]}"
                else
                    repo_score="${demand_list[$i]}"
                fi
                new_max=$(awk -v d="$repo_score" -v td="$effective_total" -v tw="$total_workers" \
                    'BEGIN { v = (d / td) * tw; if (v < 1) v = 1; printf "%.0f", v }')
            fi
            [[ "$new_max" -lt 1 ]] && new_max=1
            alloc_list+=("$new_max")
            allocated_total=$((allocated_total + new_max))
        done

        # Budget correction: if we over-allocated, reduce the largest allocations
        while [[ "$allocated_total" -gt "$total_workers" ]]; do
            local max_idx=0
            local max_val="${alloc_list[0]}"
            for i in $(seq 1 $((repo_count - 1))); do
                if [[ "${alloc_list[$i]}" -gt "$max_val" ]]; then
                    max_val="${alloc_list[$i]}"
                    max_idx=$i
                fi
            done
            # Don't reduce below 1
            if [[ "${alloc_list[$max_idx]}" -le 1 ]]; then
                break
            fi
            alloc_list[$max_idx]=$(( ${alloc_list[$max_idx]} - 1 ))
            allocated_total=$((allocated_total - 1))
        done

        # Write updated configs
        local reload_needed=false
        for i in $(seq 0 $((repo_count - 1))); do
            local repo_name="${repo_list[$i]}"
            local new_max="${alloc_list[$i]}"
            local repo_path
            repo_path=$(jq -r --arg r "$repo_name" '.repos[$r].path' "$FLEET_STATE" 2>/dev/null || true)
            [[ -z "$repo_path" || "$repo_path" == "null" ]] && continue

            local fleet_config="$repo_path/.claude/.fleet-daemon-config.json"
            if [[ -f "$fleet_config" ]]; then
                local tmp_cfg="${fleet_config}.tmp.$$"
                jq --argjson mp "$new_max" '.max_parallel = $mp' "$fleet_config" > "$tmp_cfg" \
                    && mv "$tmp_cfg" "$fleet_config"
                reload_needed=true
            fi
        done

        # Signal daemons to reload
        if [[ "$reload_needed" == "true" ]]; then
            touch "$HOME/.shipwright/fleet-reload.flag"
            emit_event "fleet.rebalance" \
                "total_workers=$total_workers" \
                "total_demand=$total_demand" \
                "total_weight=$total_weight" \
                "intel_weighting=$intel_weighting" \
                "repo_count=$repo_count" \
                "allocated=$allocated_total"
        fi
    done
}

# ─── Distributed Worker Rebalancer ───────────────────────────────────────
# Extends fleet rebalancing across registered remote machines

fleet_rebalance_distributed() {
    local machines_file="$HOME/.shipwright/machines.json"
    [[ ! -f "$machines_file" ]] && return 0

    local machine_count
    machine_count=$(jq '.machines | length' "$machines_file" 2>/dev/null || echo 0)
    [[ "$machine_count" -eq 0 ]] && return 0

    local ssh_opts="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

    # Collect demand and capacity from all machines
    local machine_names=()
    local machine_hosts=()
    local machine_users=()
    local machine_paths=()
    local machine_max_workers=()
    local machine_demands=()
    local machine_actives=()
    local total_demand=0
    local total_capacity=0
    local reachable_count=0

    local i
    for i in $(seq 0 $((machine_count - 1))); do
        local name host ssh_user sw_path max_w
        name=$(jq -r --argjson i "$i" '.machines[$i].name' "$machines_file")
        host=$(jq -r --argjson i "$i" '.machines[$i].host' "$machines_file")
        ssh_user=$(jq -r --argjson i "$i" '.machines[$i].ssh_user // ""' "$machines_file")
        sw_path=$(jq -r --argjson i "$i" '.machines[$i].shipwright_path' "$machines_file")
        max_w=$(jq -r --argjson i "$i" '.machines[$i].max_workers // 4' "$machines_file")

        # Query machine for active/queued jobs
        local query_cmd="active=0; queued=0; if [ -f \"\$HOME/.shipwright/daemon-state.json\" ]; then active=\$(python3 -c \"import json; d=json.load(open('\$HOME/.shipwright/daemon-state.json')); print(len(d.get('active_jobs',{})))\" 2>/dev/null || echo 0); queued=\$(python3 -c \"import json; d=json.load(open('\$HOME/.shipwright/daemon-state.json')); print(len(d.get('queued',[])))\" 2>/dev/null || echo 0); fi; echo \"\${active}|\${queued}\""

        local result=""
        if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
            result=$(bash -c "$query_cmd" 2>/dev/null || echo "0|0")
        else
            local target="$host"
            if [[ -n "$ssh_user" && "$ssh_user" != "null" ]]; then
                target="${ssh_user}@${host}"
            fi
            # shellcheck disable=SC2086
            result=$(ssh $ssh_opts "$target" "$query_cmd" 2>/dev/null || echo "")
        fi

        if [[ -z "$result" ]]; then
            # Machine unreachable — skip
            continue
        fi

        local active_val queued_val
        active_val=$(echo "$result" | cut -d'|' -f1)
        queued_val=$(echo "$result" | cut -d'|' -f2)
        [[ ! "$active_val" =~ ^[0-9]+$ ]] && active_val=0
        [[ ! "$queued_val" =~ ^[0-9]+$ ]] && queued_val=0

        local demand=$((active_val + queued_val))

        machine_names+=("$name")
        machine_hosts+=("$host")
        machine_users+=("$ssh_user")
        machine_paths+=("$sw_path")
        machine_max_workers+=("$max_w")
        machine_demands+=("$demand")
        machine_actives+=("$active_val")
        total_demand=$((total_demand + demand))
        total_capacity=$((total_capacity + max_w))
        reachable_count=$((reachable_count + 1))
    done

    [[ "$reachable_count" -eq 0 ]] && return 0

    # Proportional allocation: distribute total capacity by demand
    local alloc_list=()
    local allocated_total=0

    for i in $(seq 0 $((reachable_count - 1))); do
        local new_max
        local cap="${machine_max_workers[$i]}"
        if [[ "$total_demand" -eq 0 ]]; then
            # No demand anywhere — give each machine its max
            new_max="$cap"
        else
            local d="${machine_demands[$i]}"
            new_max=$(awk -v d="$d" -v td="$total_demand" -v cap="$cap" \
                'BEGIN { v = (d / td) * cap; if (v < 1) v = 1; if (v > cap) v = cap; printf "%.0f", v }')
        fi
        [[ "$new_max" -lt 1 ]] && new_max=1
        [[ "$new_max" -gt "$cap" ]] && new_max="$cap"
        alloc_list+=("$new_max")
        allocated_total=$((allocated_total + new_max))
    done

    # Write allocation to each machine's daemon config
    for i in $(seq 0 $((reachable_count - 1))); do
        local name="${machine_names[$i]}"
        local host="${machine_hosts[$i]}"
        local ssh_user="${machine_users[$i]}"
        local sw_path="${machine_paths[$i]}"
        local new_max="${alloc_list[$i]}"

        local update_cmd="if [ -f '${sw_path}/.claude/daemon-config.json' ]; then tmp=\"${sw_path}/.claude/daemon-config.json.tmp.\$\$\"; jq --argjson mp ${new_max} '.max_parallel = \$mp' '${sw_path}/.claude/daemon-config.json' > \"\$tmp\" && mv \"\$tmp\" '${sw_path}/.claude/daemon-config.json'; fi"

        if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
            bash -c "$update_cmd" 2>/dev/null || true
        else
            local target="$host"
            if [[ -n "$ssh_user" && "$ssh_user" != "null" ]]; then
                target="${ssh_user}@${host}"
            fi
            # shellcheck disable=SC2086
            ssh $ssh_opts "$target" "$update_cmd" 2>/dev/null || true
        fi
    done

    emit_event "fleet.distributed_rebalance" \
        "machines=$reachable_count" \
        "total_workers=$allocated_total" \
        "total_demand=$total_demand"
}

# ─── Machine Health Monitor ─────────────────────────────────────────────
# Checks machine heartbeats and marks unreachable machines

check_machine_health() {
    local machines_file="$HOME/.shipwright/machines.json"
    [[ ! -f "$machines_file" ]] && return 0

    local machine_count
    machine_count=$(jq '.machines | length' "$machines_file" 2>/dev/null || echo 0)
    [[ "$machine_count" -eq 0 ]] && return 0

    local ssh_opts="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    local health_file="$HOME/.shipwright/machine-health.json"
    local now
    now=$(date +%s)

    # Initialize health file if needed
    if [[ ! -f "$health_file" ]]; then
        echo '{}' > "$health_file"
    fi

    local i
    for i in $(seq 0 $((machine_count - 1))); do
        local name host ssh_user
        name=$(jq -r --argjson i "$i" '.machines[$i].name' "$machines_file")
        host=$(jq -r --argjson i "$i" '.machines[$i].host' "$machines_file")
        ssh_user=$(jq -r --argjson i "$i" '.machines[$i].ssh_user // ""' "$machines_file")

        local status="online"
        local hb_cmd="if [ -f \"\$HOME/.shipwright/machine-heartbeat.json\" ]; then cat \"\$HOME/.shipwright/machine-heartbeat.json\"; else echo '{\"ts_epoch\":0}'; fi"

        local hb_result=""
        if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
            hb_result=$(bash -c "$hb_cmd" 2>/dev/null || echo '{"ts_epoch":0}')
        else
            local target="$host"
            if [[ -n "$ssh_user" && "$ssh_user" != "null" ]]; then
                target="${ssh_user}@${host}"
            fi
            # shellcheck disable=SC2086
            hb_result=$(ssh $ssh_opts "$target" "$hb_cmd" 2>/dev/null || echo "")
        fi

        if [[ -z "$hb_result" ]]; then
            status="offline"
        else
            local hb_epoch
            hb_epoch=$(echo "$hb_result" | jq -r '.ts_epoch // 0' 2>/dev/null || echo 0)
            [[ ! "$hb_epoch" =~ ^[0-9]+$ ]] && hb_epoch=0

            local age=$((now - hb_epoch))
            if [[ "$hb_epoch" -eq 0 ]]; then
                # No heartbeat file yet — treat as degraded if not localhost
                if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
                    status="online"
                else
                    status="degraded"
                fi
            elif [[ "$age" -gt 120 ]]; then
                status="offline"
            elif [[ "$age" -gt 60 ]]; then
                status="degraded"
            fi
        fi

        # Update health file atomically
        local tmp_health="${health_file}.tmp.$$"
        jq --arg name "$name" --arg status "$status" --argjson ts "$now" \
            '.[$name] = {status: $status, checked_at: $ts}' "$health_file" > "$tmp_health" \
            && mv "$tmp_health" "$health_file"

        if [[ "$status" == "offline" ]]; then
            emit_event "fleet.machine_offline" "machine=$name" "host=$host"
        fi
    done
}

# ─── Cross-Machine Event Aggregation ───────────────────────────────────

aggregate_remote_events() {
    local machines_file="$HOME/.shipwright/machines.json"
    [[ ! -f "$machines_file" ]] && return 0

    local machine_count
    machine_count=$(jq '.machines | length' "$machines_file" 2>/dev/null || echo 0)
    [[ "$machine_count" -eq 0 ]] && return 0

    local ssh_opts="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    local offsets_file="$HOME/.shipwright/remote-offsets.json"

    # Initialize offsets file if needed
    if [[ ! -f "$offsets_file" ]]; then
        echo '{}' > "$offsets_file"
    fi

    local i
    for i in $(seq 0 $((machine_count - 1))); do
        local name host ssh_user
        name=$(jq -r --argjson i "$i" '.machines[$i].name' "$machines_file")
        host=$(jq -r --argjson i "$i" '.machines[$i].host' "$machines_file")
        ssh_user=$(jq -r --argjson i "$i" '.machines[$i].ssh_user // ""' "$machines_file")

        # Skip localhost — we already have local events
        if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
            continue
        fi

        # Get last offset for this machine
        local last_offset
        last_offset=$(jq -r --arg n "$name" '.[$n] // 0' "$offsets_file" 2>/dev/null || echo 0)
        [[ ! "$last_offset" =~ ^[0-9]+$ ]] && last_offset=0

        local target="$host"
        if [[ -n "$ssh_user" && "$ssh_user" != "null" ]]; then
            target="${ssh_user}@${host}"
        fi

        # Fetch new events from remote (tail from offset)
        local next_line=$((last_offset + 1))
        local fetch_cmd="tail -n +${next_line} \"\$HOME/.shipwright/events.jsonl\" 2>/dev/null || true"
        local new_events
        # shellcheck disable=SC2086
        new_events=$(ssh $ssh_opts "$target" "$fetch_cmd" 2>/dev/null || echo "")

        if [[ -z "$new_events" ]]; then
            continue
        fi

        # Count new lines
        local new_lines
        new_lines=$(echo "$new_events" | wc -l | tr -d ' ')

        # Add machine= field to each event and append to local events
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # Add machine field via jq
            local enriched
            enriched=$(echo "$line" | jq -c --arg m "$name" '. + {machine: $m}' 2>/dev/null || true)
            if [[ -n "$enriched" ]]; then
                echo "$enriched" >> "$EVENTS_FILE"
            fi
        done <<< "$new_events"

        # Update offset
        local new_offset=$((last_offset + new_lines))
        local tmp_offsets="${offsets_file}.tmp.$$"
        jq --arg n "$name" --argjson o "$new_offset" '.[$n] = $o' "$offsets_file" > "$tmp_offsets" \
            && mv "$tmp_offsets" "$offsets_file"

    done
}

# ─── Distributed Fleet Loop ────────────────────────────────────────────
# Background loop that runs distributed rebalancing + health checks + event aggregation

fleet_distributed_loop() {
    local interval="${1:-30}"
    local shutdown_flag="$HOME/.shipwright/fleet-distributed.shutdown"
    rm -f "$shutdown_flag"

    while true; do
        sleep "$interval"

        # Check for shutdown signal
        if [[ -f "$shutdown_flag" ]]; then
            break
        fi

        # Run distributed tasks
        check_machine_health 2>/dev/null || true
        fleet_rebalance_distributed 2>/dev/null || true
        aggregate_remote_events 2>/dev/null || true
    done
}

# ─── Fleet Start ────────────────────────────────────────────────────────────

fleet_start() {
    echo -e "${PURPLE}${BOLD}━━━ shipwright fleet v${VERSION} — start ━━━${RESET}"
    echo ""

    if ! command -v tmux &>/dev/null; then
        error "tmux is required for fleet mode"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        error "jq is required. Install: brew install jq"
        exit 1
    fi

    local config_file
    config_file=$(load_fleet_config)

    local repo_count
    repo_count=$(jq '.repos | length' "$config_file")

    # Read defaults
    local default_label default_template default_max_parallel default_model
    default_label=$(jq -r '.defaults.watch_label // "ready-to-build"' "$config_file")
    default_template=$(jq -r '.defaults.pipeline_template // "autonomous"' "$config_file")
    default_max_parallel=$(jq -r '.defaults.max_parallel // 2' "$config_file")
    default_model=$(jq -r '.defaults.model // "opus"' "$config_file")
    local shared_events
    shared_events=$(jq -r '.shared_events // true' "$config_file")

    mkdir -p "$FLEET_DIR"

    # Initialize fleet state
    local fleet_state_tmp="${FLEET_STATE}.tmp.$$"
    echo '{"started_at":"'"$(now_iso)"'","repos":{}}' > "$fleet_state_tmp"

    local started=0
    local skipped=0

    for i in $(seq 0 $((repo_count - 1))); do
        local repo_path repo_template repo_max_parallel repo_label repo_model
        repo_path=$(jq -r ".repos[$i].path" "$config_file")
        repo_template=$(jq -r ".repos[$i].template // \"$default_template\"" "$config_file")
        repo_max_parallel=$(jq -r ".repos[$i].max_parallel // $default_max_parallel" "$config_file")
        repo_label=$(jq -r ".repos[$i].watch_label // \"$default_label\"" "$config_file")
        repo_model=$(jq -r ".repos[$i].model // \"$default_model\"" "$config_file")

        local repo_name
        repo_name=$(basename "$repo_path")
        local session_name
        session_name=$(session_name_for_repo "$repo_path")

        # Validate repo path
        if [[ ! -d "$repo_path" ]]; then
            warn "Repo not found: $repo_path — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ ! -d "$repo_path/.git" ]]; then
            warn "Not a git repo: $repo_path — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        # Check for existing session
        if tmux has-session -t "$session_name" 2>/dev/null; then
            warn "Session already exists: ${session_name} — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        # Generate per-repo daemon config with overrides
        local repo_config_dir="$repo_path/.claude"
        mkdir -p "$repo_config_dir"
        local repo_daemon_config="$repo_config_dir/daemon-config.json"

        # Only generate if fleet is managing the config (don't overwrite user configs)
        local fleet_managed_config="$repo_config_dir/.fleet-daemon-config.json"
        jq -n \
            --arg label "$repo_label" \
            --argjson poll 60 \
            --argjson max_parallel "$repo_max_parallel" \
            --arg template "$repo_template" \
            --arg model "$repo_model" \
            '{
                watch_label: $label,
                poll_interval: $poll,
                max_parallel: $max_parallel,
                pipeline_template: $template,
                model: $model,
                skip_gates: true,
                on_success: { remove_label: $label, add_label: "pipeline/complete" },
                on_failure: { add_label: "pipeline/failed", comment_log_lines: 50 }
            }' > "$fleet_managed_config"

        # Determine which config the daemon should use
        local daemon_config_flag=""
        if [[ -f "$repo_daemon_config" ]]; then
            # Use existing user config — don't override
            daemon_config_flag="--config $repo_daemon_config"
        else
            daemon_config_flag="--config $fleet_managed_config"
        fi

        # Spawn daemon in detached tmux session
        tmux new-session -d -s "$session_name" \
            "cd '$repo_path' && '$SCRIPT_DIR/sw-daemon.sh' start $daemon_config_flag"

        # Record in fleet state
        local tmp2="${fleet_state_tmp}.2"
        jq --arg repo "$repo_name" \
           --arg path "$repo_path" \
           --arg session "$session_name" \
           --arg template "$repo_template" \
           --argjson max_parallel "$repo_max_parallel" \
           --arg started_at "$(now_iso)" \
           '.repos[$repo] = {
               path: $path,
               session: $session,
               template: $template,
               max_parallel: $max_parallel,
               started_at: $started_at
           }' "$fleet_state_tmp" > "$tmp2" && mv "$tmp2" "$fleet_state_tmp"

        success "Started ${CYAN}${repo_name}${RESET} → tmux session ${DIM}${session_name}${RESET}"
        started=$((started + 1))
    done

    # Atomic write of fleet state
    mv "$fleet_state_tmp" "$FLEET_STATE"

    # Start worker pool rebalancer if enabled
    local pool_enabled
    pool_enabled=$(jq -r '.worker_pool.enabled // false' "$config_file")
    if [[ "$pool_enabled" == "true" ]]; then
        local pool_total
        pool_total=$(jq -r '.worker_pool.total_workers // 12' "$config_file")
        fleet_rebalance "$config_file" &
        local rebalancer_pid=$!
        sleep 1
        if ! kill -0 "$rebalancer_pid" 2>/dev/null; then
            fleet_log ERROR "Rebalancer process exited immediately (PID: $rebalancer_pid)"
        else
            # Record rebalancer PID in fleet state
            local tmp_rs="${FLEET_STATE}.tmp.$$"
            jq --argjson pid "$rebalancer_pid" '.rebalancer_pid = $pid' "$FLEET_STATE" > "$tmp_rs" \
                && mv "$tmp_rs" "$FLEET_STATE"

            success "Worker pool: ${CYAN}${pool_total} total workers${RESET} (rebalancer PID: ${rebalancer_pid})"
        fi
    fi

    # Start distributed worker loop if machines are registered
    local machines_file="$HOME/.shipwright/machines.json"
    if [[ -f "$machines_file" ]]; then
        local dist_machine_count
        dist_machine_count=$(jq '.machines | length' "$machines_file" 2>/dev/null || echo 0)
        if [[ "$dist_machine_count" -gt 0 ]]; then
            fleet_distributed_loop 30 &
            local dist_pid=$!

            # Record distributed loop PID in fleet state
            local tmp_dist="${FLEET_STATE}.tmp.$$"
            jq --argjson pid "$dist_pid" '.distributed_loop_pid = $pid' "$FLEET_STATE" > "$tmp_dist" \
                && mv "$tmp_dist" "$FLEET_STATE"

            success "Distributed workers: ${CYAN}${dist_machine_count} machines${RESET} (loop PID: ${dist_pid})"
        fi
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Fleet: ${GREEN}${started} started${RESET}"
    [[ "$skipped" -gt 0 ]] && echo -e "         ${YELLOW}${skipped} skipped${RESET}"
    echo ""
    echo -e "  ${DIM}View dashboard:${RESET}  ${CYAN}shipwright fleet status${RESET}"
    echo -e "  ${DIM}View metrics:${RESET}    ${CYAN}shipwright fleet metrics${RESET}"
    echo -e "  ${DIM}Stop all:${RESET}        ${CYAN}shipwright fleet stop${RESET}"
    echo ""

    emit_event "fleet.started" "repos=$started" "skipped=$skipped"
}

# ─── Fleet Stop ─────────────────────────────────────────────────────────────

fleet_stop() {
    echo -e "${PURPLE}${BOLD}━━━ shipwright fleet v${VERSION} — stop ━━━${RESET}"
    echo ""

    if [[ ! -f "$FLEET_STATE" ]]; then
        error "No fleet state found — is the fleet running?"
        info "Start with: ${CYAN}shipwright fleet start${RESET}"
        exit 1
    fi

    local repo_names
    repo_names=$(jq -r '.repos | keys[]' "$FLEET_STATE" 2>/dev/null || true)

    if [[ -z "$repo_names" ]]; then
        warn "No repos in fleet state"
        rm -f "$FLEET_STATE"
        return 0
    fi

    # Signal rebalancer to stop
    touch "$HOME/.shipwright/fleet-rebalancer.shutdown"

    # Signal distributed loop to stop
    touch "$HOME/.shipwright/fleet-distributed.shutdown"

    # Kill rebalancer if running
    local rebalancer_pid
    rebalancer_pid=$(jq -r '.rebalancer_pid // empty' "$FLEET_STATE" 2>/dev/null || true)
    if [[ -n "$rebalancer_pid" ]]; then
        kill "$rebalancer_pid" 2>/dev/null || true
        wait "$rebalancer_pid" 2>/dev/null || true
        success "Stopped worker pool rebalancer (PID: ${rebalancer_pid})"
    fi

    # Kill distributed loop if running
    local dist_pid
    dist_pid=$(jq -r '.distributed_loop_pid // empty' "$FLEET_STATE" 2>/dev/null || true)
    if [[ -n "$dist_pid" ]]; then
        kill "$dist_pid" 2>/dev/null || true
        wait "$dist_pid" 2>/dev/null || true
        success "Stopped distributed worker loop (PID: ${dist_pid})"
    fi

    # Clean up flags
    rm -f "$HOME/.shipwright/fleet-reload.flag"
    rm -f "$HOME/.shipwright/fleet-rebalancer.shutdown"
    rm -f "$HOME/.shipwright/fleet-distributed.shutdown"

    local stopped=0
    while IFS= read -r repo_name; do
        local session_name
        session_name=$(jq -r --arg r "$repo_name" '.repos[$r].session' "$FLEET_STATE")
        local repo_path
        repo_path=$(jq -r --arg r "$repo_name" '.repos[$r].path' "$FLEET_STATE")

        # Try graceful shutdown via the daemon's shutdown flag
        local daemon_dir="$HOME/.shipwright"
        local shutdown_flag="$daemon_dir/daemon.shutdown"

        # Send shutdown signal to the daemon process inside the tmux session
        if tmux has-session -t "$session_name" 2>/dev/null; then
            # Send Ctrl-C to the tmux session for graceful shutdown
            tmux send-keys -t "$session_name" C-c 2>/dev/null || true
            sleep 1

            # Kill the session if still alive
            if tmux has-session -t "$session_name" 2>/dev/null; then
                tmux kill-session -t "$session_name" 2>/dev/null || true
            fi
            success "Stopped ${CYAN}${repo_name}${RESET}"
            stopped=$((stopped + 1))
        else
            warn "Session not found: ${session_name} — already stopped?"
        fi

        # Clean up fleet-managed config
        local fleet_managed_config="$repo_path/.claude/.fleet-daemon-config.json"
        rm -f "$fleet_managed_config" 2>/dev/null || true

    done <<< "$repo_names"

    rm -f "$FLEET_STATE"

    echo ""
    echo -e "  Fleet: ${GREEN}${stopped} stopped${RESET}"
    echo ""

    emit_event "fleet.stopped" "repos=$stopped"
}

# ─── Fleet Status ───────────────────────────────────────────────────────────

fleet_status() {
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ shipwright fleet v${VERSION} — dashboard ━━━${RESET}"
    echo -e "  ${DIM}$(now_iso)${RESET}"
    echo ""

    if [[ ! -f "$FLEET_STATE" ]]; then
        warn "No fleet running"
        info "Start with: ${CYAN}shipwright fleet start${RESET}"
        return 0
    fi

    local repo_names
    repo_names=$(jq -r '.repos | keys[]' "$FLEET_STATE" 2>/dev/null || true)

    if [[ -z "$repo_names" ]]; then
        warn "Fleet state is empty"
        return 0
    fi

    # Show worker pool info if enabled
    local pool_enabled="false"
    local config_file_path="${CONFIG_PATH:-.claude/fleet-config.json}"
    if [[ -f "$config_file_path" ]]; then
        pool_enabled=$(jq -r '.worker_pool.enabled // false' "$config_file_path" 2>/dev/null || echo "false")
    fi

    if [[ "$pool_enabled" == "true" ]]; then
        local pool_total rebalancer_pid
        pool_total=$(jq -r '.worker_pool.total_workers // 12' "$config_file_path" 2>/dev/null || echo "12")
        rebalancer_pid=$(jq -r '.rebalancer_pid // "N/A"' "$FLEET_STATE" 2>/dev/null || echo "N/A")
        echo -e "  ${BOLD}Worker Pool:${RESET} ${CYAN}${pool_total} total workers${RESET}  ${DIM}rebalancer PID: ${rebalancer_pid}${RESET}"
        echo ""
    fi

    # Show distributed machine summary if available
    local machines_file="$HOME/.shipwright/machines.json"
    if [[ -f "$machines_file" ]]; then
        local dist_count
        dist_count=$(jq '.machines | length' "$machines_file" 2>/dev/null || echo 0)
        if [[ "$dist_count" -gt 0 ]]; then
            local health_file="$HOME/.shipwright/machine-health.json"
            local m_online=0 m_offline=0
            if [[ -f "$health_file" ]]; then
                m_online=$(jq '[to_entries[] | select(.value.status == "online")] | length' "$health_file" 2>/dev/null || echo 0)
                m_offline=$(jq '[to_entries[] | select(.value.status == "offline")] | length' "$health_file" 2>/dev/null || echo 0)
            fi
            echo -e "  ${BOLD}Machines:${RESET} ${dist_count} registered  ${GREEN}${m_online} online${RESET}  ${RED}${m_offline} offline${RESET}"
            echo ""
        fi
    fi

    # Header
    printf "  ${BOLD}%-20s %-10s %-10s %-10s %-10s %-20s${RESET}\n" \
        "REPO" "STATUS" "ACTIVE" "QUEUED" "DONE" "LAST POLL"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────────────────────────${RESET}"

    while IFS= read -r repo_name; do
        local session_name repo_path
        session_name=$(jq -r --arg r "$repo_name" '.repos[$r].session' "$FLEET_STATE")
        repo_path=$(jq -r --arg r "$repo_name" '.repos[$r].path' "$FLEET_STATE")

        # Check tmux session
        local status_icon status_text
        if tmux has-session -t "$session_name" 2>/dev/null; then
            status_icon="${GREEN}●${RESET}"
            status_text="running"
        else
            status_icon="${RED}●${RESET}"
            status_text="stopped"
        fi

        # Try to read daemon state from the repo's daemon state file
        local active="-" queued="-" done="-" last_poll="-"
        local daemon_state="$HOME/.shipwright/daemon-state.json"
        if [[ -f "$daemon_state" ]]; then
            active=$(jq -r '.active_jobs // 0' "$daemon_state" 2>/dev/null || echo "-")
            queued=$(jq -r '.queued // 0' "$daemon_state" 2>/dev/null || echo "-")
            done=$(jq -r '.completed // 0' "$daemon_state" 2>/dev/null || echo "-")
            last_poll=$(jq -r '.last_poll // "-"' "$daemon_state" 2>/dev/null || echo "-")
            # Shorten timestamp
            if [[ "$last_poll" != "-" && "$last_poll" != "null" ]]; then
                last_poll="${last_poll:11:8}"
            else
                last_poll="-"
            fi
        fi

        printf "  ${status_icon} %-19s %-10s %-10s %-10s %-10s %-20s\n" \
            "$repo_name" "$status_text" "$active" "$queued" "$done" "$last_poll"

    done <<< "$repo_names"

    echo ""

    # Summary
    local total running=0
    total=$(echo "$repo_names" | wc -l | tr -d ' ')
    while IFS= read -r repo_name; do
        local session_name
        session_name=$(jq -r --arg r "$repo_name" '.repos[$r].session' "$FLEET_STATE")
        if tmux has-session -t "$session_name" 2>/dev/null; then
            running=$((running + 1))
        fi
    done <<< "$repo_names"

    echo -e "  ${BOLD}Total:${RESET} ${total} repos  ${GREEN}${running} running${RESET}  ${DIM}$((total - running)) stopped${RESET}"
    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ─── Fleet Metrics ──────────────────────────────────────────────────────────

fleet_metrics() {
    local period_days="$METRICS_PERIOD"
    local json_output="$JSON_OUTPUT"

    if [[ ! -f "$EVENTS_FILE" ]]; then
        error "No events file found at $EVENTS_FILE"
        info "Events are generated when running ${CYAN}shipwright daemon${RESET} or ${CYAN}shipwright pipeline${RESET}"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        error "jq is required. Install: brew install jq"
        exit 1
    fi

    local cutoff_epoch
    cutoff_epoch=$(( $(now_epoch) - (period_days * 86400) ))

    # Filter events within period
    local period_events
    period_events=$(jq -c "select(.ts_epoch >= $cutoff_epoch)" "$EVENTS_FILE" 2>/dev/null)

    if [[ -z "$period_events" ]]; then
        warn "No events in the last ${period_days} day(s)"
        return 0
    fi

    # Get unique repos from events (fall back to "default" if no repo field)
    local repos
    repos=$(echo "$period_events" | jq -r '.repo // "default"' | sort -u)

    if [[ "$json_output" == "true" ]]; then
        # JSON output: per-repo metrics
        local json_result='{"period":"'"${period_days}d"'","repos":{}}'

        while IFS= read -r repo; do
            local repo_events
            if [[ "$repo" == "default" ]]; then
                repo_events=$(echo "$period_events" | jq -c 'select(.repo == null or .repo == "default")')
            else
                repo_events=$(echo "$period_events" | jq -c --arg r "$repo" 'select(.repo == $r)')
            fi

            [[ -z "$repo_events" ]] && continue

            local completed successes failures
            completed=$(echo "$repo_events" | jq -s '[.[] | select(.type == "pipeline.completed")] | length')
            successes=$(echo "$repo_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success")] | length')
            failures=$(echo "$repo_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length')

            local deploy_freq="0"
            [[ "$period_days" -gt 0 ]] && deploy_freq=$(echo "$successes $period_days" | awk '{printf "%.1f", $1 / ($2 / 7)}')

            local cfr="0"
            [[ "$completed" -gt 0 ]] && cfr=$(echo "$failures $completed" | awk '{printf "%.1f", ($1 / $2) * 100}')

            json_result=$(echo "$json_result" | jq \
                --arg repo "$repo" \
                --argjson completed "$completed" \
                --argjson successes "$successes" \
                --argjson failures "$failures" \
                --argjson deploy_freq "${deploy_freq}" \
                --arg cfr "$cfr" \
                '.repos[$repo] = {
                    completed: $completed,
                    successes: $successes,
                    failures: $failures,
                    deploy_freq_per_week: $deploy_freq,
                    change_failure_rate_pct: ($cfr | tonumber)
                }')
        done <<< "$repos"

        # Aggregate totals
        local total_completed total_successes total_failures
        total_completed=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed")] | length')
        total_successes=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success")] | length')
        total_failures=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length')

        json_result=$(echo "$json_result" | jq \
            --argjson total "$total_completed" \
            --argjson successes "$total_successes" \
            --argjson failures "$total_failures" \
            '.aggregate = { completed: $total, successes: $successes, failures: $failures }')

        echo "$json_result" | jq .
        return 0
    fi

    # Dashboard output
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Fleet Metrics ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Period: last ${period_days} day(s)    ${DIM}$(now_iso)${RESET}"
    echo ""

    # Per-repo breakdown
    echo -e "${BOLD}  PER-REPO BREAKDOWN${RESET}"
    printf "  %-20s %8s %8s %8s %12s %8s\n" "REPO" "DONE" "PASS" "FAIL" "FREQ/wk" "CFR"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────────${RESET}"

    local grand_completed=0 grand_successes=0 grand_failures=0

    while IFS= read -r repo; do
        local repo_events
        if [[ "$repo" == "default" ]]; then
            repo_events=$(echo "$period_events" | jq -c 'select(.repo == null or .repo == "default")')
        else
            repo_events=$(echo "$period_events" | jq -c --arg r "$repo" 'select(.repo == $r)')
        fi

        [[ -z "$repo_events" ]] && continue

        local completed successes failures
        completed=$(echo "$repo_events" | jq -s '[.[] | select(.type == "pipeline.completed")] | length')
        successes=$(echo "$repo_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success")] | length')
        failures=$(echo "$repo_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length')

        local deploy_freq="0"
        [[ "$period_days" -gt 0 ]] && deploy_freq=$(echo "$successes $period_days" | awk '{printf "%.1f", $1 / ($2 / 7)}')

        local cfr="0"
        [[ "$completed" -gt 0 ]] && cfr=$(echo "$failures $completed" | awk '{printf "%.1f", ($1 / $2) * 100}')

        printf "  %-20s %8s %8s %8s %12s %7s%%\n" \
            "$repo" "$completed" "${successes}" "${failures}" "$deploy_freq" "$cfr"

        grand_completed=$((grand_completed + completed))
        grand_successes=$((grand_successes + successes))
        grand_failures=$((grand_failures + failures))
    done <<< "$repos"

    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────────${RESET}"

    local grand_freq="0"
    [[ "$period_days" -gt 0 ]] && grand_freq=$(echo "$grand_successes $period_days" | awk '{printf "%.1f", $1 / ($2 / 7)}')
    local grand_cfr="0"
    [[ "$grand_completed" -gt 0 ]] && grand_cfr=$(echo "$grand_failures $grand_completed" | awk '{printf "%.1f", ($1 / $2) * 100}')

    printf "  ${BOLD}%-20s %8s %8s %8s %12s %7s%%${RESET}\n" \
        "TOTAL" "$grand_completed" "$grand_successes" "$grand_failures" "$grand_freq" "$grand_cfr"
    echo ""

    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ─── Fleet Init ─────────────────────────────────────────────────────────────

fleet_init() {
    local config_dir=".claude"
    local config_file="${config_dir}/fleet-config.json"

    if [[ -f "$config_file" ]]; then
        warn "Config file already exists: $config_file"
        info "Delete it first if you want to regenerate"
        return 0
    fi

    mkdir -p "$config_dir"

    # Scan for sibling git repos
    local parent_dir
    parent_dir=$(dirname "$(pwd)")
    local detected_repos=()

    while IFS= read -r dir; do
        [[ -d "$dir/.git" ]] && detected_repos+=("$dir")
    done < <(find "$parent_dir" -maxdepth 1 -type d ! -name ".*" 2>/dev/null | sort)

    # Build repos array JSON
    local repos_json="[]"
    for repo in "${detected_repos[@]}"; do
        repos_json=$(echo "$repos_json" | jq --arg path "$repo" '. + [{"path": $path}]')
    done

    jq -n --argjson repos "$repos_json" '{
        repos: $repos,
        defaults: {
            watch_label: "ready-to-build",
            pipeline_template: "autonomous",
            max_parallel: 2,
            model: "opus"
        },
        shared_events: true,
        worker_pool: {
            enabled: false,
            total_workers: 12,
            rebalance_interval_seconds: 120
        }
    }' > "$config_file"

    success "Generated fleet config: ${config_file}"
    echo ""
    echo -e "  Detected ${CYAN}${#detected_repos[@]}${RESET} repo(s) in parent directory"
    echo ""

    if [[ "${#detected_repos[@]}" -gt 0 ]]; then
        for repo in "${detected_repos[@]}"; do
            echo -e "    ${DIM}•${RESET} $(basename "$repo")  ${DIM}$repo${RESET}"
        done
        echo ""
    fi

    echo -e "${DIM}Edit the config to add/remove repos and set overrides, then run:${RESET}"
    echo -e "  ${CYAN}shipwright fleet start${RESET}"
}

# ─── Command Router ─────────────────────────────────────────────────────────

case "$SUBCOMMAND" in
    start)
        fleet_start
        ;;
    stop)
        fleet_stop
        ;;
    status)
        fleet_status
        ;;
    metrics)
        fleet_metrics
        ;;
    init)
        fleet_init
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        error "Unknown command: ${SUBCOMMAND}"
        echo ""
        show_help
        exit 1
        ;;
esac
