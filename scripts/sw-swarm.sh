#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright swarm — Dynamic agent swarm management                         ║
# ║  Registry, spawning, scaling, health checks, performance tracking, retire ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
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

# ─── Constants ──────────────────────────────────────────────────────────────
SWARM_DIR="${HOME}/.shipwright/swarm"
REGISTRY_FILE="${SWARM_DIR}/registry.json"
CONFIG_FILE="${SWARM_DIR}/config.json"
METRICS_FILE="${SWARM_DIR}/metrics.jsonl"
HEALTH_LOG="${SWARM_DIR}/health.jsonl"

# ─── Ensure directories exist ──────────────────────────────────────────────
ensure_dirs() {
    mkdir -p "$SWARM_DIR"
}

# ─── Initialize config ─────────────────────────────────────────────────────
init_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        trap "rm -f '$tmp_file'" RETURN
        cat > "$tmp_file" << 'JSON'
{
  "auto_scaling_enabled": false,
  "min_agents": 1,
  "max_agents": 8,
  "target_utilization": 0.75,
  "health_check_interval": 30,
  "stall_detection_threshold": 300,
  "agent_types": {
    "fast": {"cost_multiplier": 1.0, "capability": "simple"},
    "standard": {"cost_multiplier": 2.0, "capability": "complex"},
    "powerful": {"cost_multiplier": 4.0, "capability": "expert"}
  }
}
JSON
        mv "$tmp_file" "$CONFIG_FILE"
        success "Initialized swarm config"
    fi
}

# ─── Initialize registry ───────────────────────────────────────────────────
init_registry() {
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        trap "rm -f '$tmp_file'" RETURN
        cat > "$tmp_file" << 'JSON'
{
  "agents": [],
  "active_count": 0,
  "last_updated": "2025-01-01T00:00:00Z"
}
JSON
        mv "$tmp_file" "$REGISTRY_FILE"
    fi
}

# ─── Generate unique agent ID ─────────────────────────────────────────────
gen_agent_id() {
    local prefix="${1:-agent}"
    echo "${prefix}-$(date +%s)-$((RANDOM % 10000))"
}

# ─── Record metric ────────────────────────────────────────────────────────
record_metric() {
    local agent_id="$1"
    local metric_type="$2"  # spawn, complete, fail, retire, stall
    local value="${3:-1}"
    local context="${4:-}"

    local metric
    metric=$(jq -c -n \
        --arg ts "$(now_iso)" \
        --arg agent_id "$agent_id" \
        --arg metric_type "$metric_type" \
        --arg value "$value" \
        --arg context "$context" \
        '{ts: $ts, agent_id: $agent_id, metric_type: $metric_type, value: $value, context: $context}')

    echo "$metric" >> "$METRICS_FILE"
}

# ─── Spawn a new agent ────────────────────────────────────────────────────
cmd_spawn() {
    local agent_type="${1:-}"
    shift 2>/dev/null || true
    local task_desc="${1:-}"
    shift 2>/dev/null || true

    ensure_dirs
    init_registry
    init_config

    # Recruit-powered type selection when task description given but no explicit type
    if [[ -z "$agent_type" || "$agent_type" == "--task" ]] && [[ -n "$task_desc" ]]; then
        if [[ -x "${SCRIPT_DIR:-}/sw-recruit.sh" ]]; then
            local _recruit_match
            _recruit_match=$(bash "$SCRIPT_DIR/sw-recruit.sh" match --json "$task_desc" 2>/dev/null) || true
            if [[ -n "$_recruit_match" ]]; then
                local _role
                _role=$(echo "$_recruit_match" | jq -r '.primary_role // ""' 2>/dev/null) || true
                case "$_role" in
                    architect|security-auditor|incident-responder) agent_type="powerful" ;;
                    docs-writer) agent_type="fast" ;;
                    *) agent_type="standard" ;;
                esac
            fi
        fi
    fi
    [[ -z "$agent_type" ]] && agent_type="standard"

    local agent_id
    agent_id=$(gen_agent_id)

    # Validate agent type
    if ! jq -e ".agent_types | has(\"$agent_type\")" "$CONFIG_FILE" >/dev/null 2>&1; then
        error "Invalid agent type: $agent_type"
        return 1
    fi

    # Check max agents
    local max_agents
    max_agents=$(jq -r '.max_agents // 8' "$CONFIG_FILE")
    local active_count
    active_count=$(jq -r '.active_count // 0' "$REGISTRY_FILE")

    if [[ $active_count -ge $max_agents ]]; then
        error "Max agents reached ($max_agents). Retire an agent first."
        return 1
    fi

    # Add agent to registry
    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    jq --arg agent_id "$agent_id" \
       --arg agent_type "$agent_type" \
       '.agents += [{
           id: $agent_id,
           type: $agent_type,
           status: "active",
           spawned_at: "'$(now_iso)'",
           current_task: null,
           task_started_at: null,
           success_count: 0,
           failure_count: 0,
           avg_completion_time: 0,
           quality_score: 100,
           resource_usage: {cpu: 0, memory: 0},
           last_heartbeat: "'$(now_iso)'"
       }] | .active_count += 1 | .last_updated = "'$(now_iso)'"' \
        "$REGISTRY_FILE" > "$tmp_file" && [[ -s "$tmp_file" ]] && \
    mv "$tmp_file" "$REGISTRY_FILE" || { rm -f "$tmp_file"; error "Failed to update registry"; return 1; }
    record_metric "$agent_id" "spawn" "1" "$agent_type"

    # Create real tmux session for the agent (so scale/loop can send commands)
    if command -v tmux &>/dev/null; then
        local session_name="swarm-${agent_id}"
        if ! tmux has-session -t "$session_name" 2>/dev/null; then
            tmux new-session -d -s "$session_name" -c "$REPO_DIR" \
                "echo \"Agent $agent_id ready (type: $agent_type)\"; while true; do sleep 3600; done" 2>/dev/null && \
                info "Tmux session created: $session_name" || warn "Tmux session creation failed (agent still in registry)"
        fi
    fi

    success "Spawned agent: ${CYAN}${agent_id}${RESET} (type: ${agent_type})"
    echo ""
    echo -e "  Agent ID:    ${CYAN}${agent_id}${RESET}"
    echo -e "  Type:        ${CYAN}${agent_type}${RESET}"
    echo -e "  Status:      ${GREEN}active${RESET}"
    echo -e "  Spawned:     $(now_iso)"
}

# ─── Retire an agent ──────────────────────────────────────────────────────
cmd_retire() {
    local agent_id="${1:-}"
    shift 2>/dev/null || true

    if [[ -z "$agent_id" ]]; then
        error "Usage: shipwright swarm retire <agent-id>"
        return 1
    fi

    ensure_dirs
    init_registry

    # Find agent
    local agent
    agent=$(jq --arg aid "$agent_id" '.agents[] | select(.id == $aid)' "$REGISTRY_FILE" 2>/dev/null)

    if [[ -z "$agent" ]]; then
        error "Agent not found: $agent_id"
        return 1
    fi

    # Check if agent has active tasks
    local current_task
    current_task=$(echo "$agent" | jq -r '.current_task // "null"')

    if [[ "$current_task" != "null" ]]; then
        warn "Agent has active task: $current_task"
        echo "  Waiting for task completion before retirement..."
        echo "  (In production, implement drain timeout)"
        echo ""
    fi

    # Kill real tmux session if present
    local session_name="swarm-${agent_id}"
    if command -v tmux &>/dev/null && tmux has-session -t "$session_name" 2>/dev/null; then
        tmux kill-session -t "$session_name" 2>/dev/null && info "Tmux session killed: $session_name" || warn "Tmux kill failed for $session_name"
    fi

    # Mark as retiring / remove from registry
    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    jq --arg aid "$agent_id" \
       '.agents |= map(select(.id != $aid)) | .active_count = ([.agents[] | select(.status == "active")] | length) | .last_updated = "'$(now_iso)'"' \
        "$REGISTRY_FILE" > "$tmp_file" && [[ -s "$tmp_file" ]] && \
    mv "$tmp_file" "$REGISTRY_FILE" || { rm -f "$tmp_file"; error "Failed to update registry"; return 1; }
    record_metric "$agent_id" "retire" "1" "graceful_shutdown"

    success "Retired agent: ${CYAN}${agent_id}${RESET}"
    echo ""
}

# ─── Health check ────────────────────────────────────────────────────────
cmd_health() {
    local agent_id="${1:-all}"
    shift 2>/dev/null || true

    ensure_dirs
    init_registry
    init_config

    local stall_threshold
    stall_threshold=$(jq -r '.stall_detection_threshold // 300' "$CONFIG_FILE")

    local now
    now=$(now_epoch)

    if [[ "$agent_id" == "all" ]]; then
        # Health check all agents
        info "Agent Health Status"
        echo ""

        local agents_array
        agents_array=$(jq -r '.agents | length' "$REGISTRY_FILE")

        if [[ $agents_array -eq 0 ]]; then
            echo -e "  ${DIM}No agents in swarm${RESET}"
            return 0
        fi

        jq -r '.agents[] | @base64' "$REGISTRY_FILE" | while read -r line; do
            local agent
            agent=$(echo "$line" | base64 -d 2>/dev/null || echo "$line")

            local id status last_hb
            id=$(echo "$agent" | jq -r '.id')
            status=$(echo "$agent" | jq -r '.status')
            last_hb=$(echo "$agent" | jq -r '.last_heartbeat')

            # Convert ISO to epoch
            local last_hb_epoch
            last_hb_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_hb" +%s 2>/dev/null || echo "0")
            local elapsed=$((now - last_hb_epoch))

            if [[ $elapsed -gt $stall_threshold ]]; then
                echo -e "  ${RED}✗${RESET} ${id} (${YELLOW}stalled${RESET}, ${elapsed}s inactive)"
            elif [[ "$status" == "active" ]]; then
                echo -e "  ${GREEN}✓${RESET} ${id} (healthy)"
            else
                echo -e "  ${DIM}◦${RESET} ${id} (${status})"
            fi
        done

        local healthy inactive
        healthy=$(jq -r '[.agents[] | select(.status == "active")] | length' "$REGISTRY_FILE")
        inactive=$(jq -r '[.agents[] | select(.status != "active")] | length' "$REGISTRY_FILE")

        echo ""
        echo -e "  Summary: ${GREEN}${healthy}${RESET} healthy, ${DIM}${inactive}${RESET} inactive"
    else
        # Health check single agent
        local agent
        agent=$(jq --arg aid "$agent_id" '.agents[] | select(.id == $aid)' "$REGISTRY_FILE" 2>/dev/null)

        if [[ -z "$agent" ]]; then
            error "Agent not found: $agent_id"
            return 1
        fi

        info "Health Check: ${agent_id}"
        echo ""
        echo "$agent" | jq '.' | sed 's/^/  /'
    fi
}

# ─── Auto-scale logic ────────────────────────────────────────────────────
cmd_scale() {
    ensure_dirs
    init_registry
    init_config

    local auto_scale_enabled
    auto_scale_enabled=$(jq -r '.auto_scaling_enabled' "$CONFIG_FILE")

    if [[ "$auto_scale_enabled" != "true" ]]; then
        warn "Auto-scaling is disabled"
        return 0
    fi

    local min_agents max_agents target_util
    min_agents=$(jq -r '.min_agents // 1' "$CONFIG_FILE")
    max_agents=$(jq -r '.max_agents // 8' "$CONFIG_FILE")
    target_util=$(jq -r '.target_utilization // 0.75' "$CONFIG_FILE")

    local active_count
    active_count=$(jq -r '.active_count // 0' "$REGISTRY_FILE")

    # TODO: Implement queue depth and resource monitoring
    # For now, just show current state
    info "Auto-Scaling Analysis"
    echo ""
    echo -e "  Current agents:     ${CYAN}${active_count}/${max_agents}${RESET}"
    echo -e "  Min agents:         ${CYAN}${min_agents}${RESET}"
    echo -e "  Target utilization: ${CYAN}${target_util}${RESET}"
    echo ""
    echo -e "  ${DIM}Queue depth monitoring and scaling recommendations require active pipeline${RESET}"
}

# ─── Performance leaderboard ──────────────────────────────────────────────
cmd_top() {
    local limit="${1:-10}"
    shift 2>/dev/null || true

    ensure_dirs
    init_registry

    info "Agent Performance Leaderboard (Top ${limit})"
    echo ""

    jq -r --arg limit "$limit" '.agents | sort_by(-.quality_score) | .[0:($limit|tonumber)] | .[] |
        "  \(.id) — Score: \(.quality_score) | Success: \(.success_count) | Avg time: \(.avg_completion_time)s | Status: \(.status)"' \
        "$REGISTRY_FILE"

    echo ""
}

# ─── Swarm topology visualization ─────────────────────────────────────────
cmd_topology() {
    ensure_dirs
    init_registry
    init_config

    info "Swarm Topology"
    echo ""

    local active_count total_agents
    active_count=$(jq -r '.active_count // 0' "$REGISTRY_FILE")
    total_agents=$(jq -r '.agents | length' "$REGISTRY_FILE")

    echo -e "  ${CYAN}┌─ Agent Swarm ─┐${RESET}"
    echo -e "  ${CYAN}│${RESET} Active: ${GREEN}${active_count}${RESET}/${YELLOW}${total_agents}${RESET}"
    echo ""

    # Group by type
    echo -e "  Agent Types:"
    jq -r '.agents | group_by(.type) | .[] | "    ◇ \(.[0].type): \(length)"' "$REGISTRY_FILE" | \
        sed "s/◇/${CYAN}◇${RESET}/g"

    echo ""
    echo -e "  Resource Allocation:"

    jq -r '.agents | .[] |
        "    ▪ \(.id): CPU=\(.resource_usage.cpu)% MEM=\(.resource_usage.memory)MB Task: \(.current_task // "idle")"' \
        "$REGISTRY_FILE" | head -5 | sed "s/▪/${PURPLE}▪${RESET}/g"

    local remaining
    remaining=$((total_agents - 5))
    if [[ $remaining -gt 0 ]]; then
        echo -e "    ${DIM}... and ${remaining} more${RESET}"
    fi

    echo ""
}

# ─── Show swarm status ────────────────────────────────────────────────────
cmd_status() {
    ensure_dirs
    init_registry
    init_config

    info "Swarm Status"
    echo ""

    local active_count total_agents
    active_count=$(jq -r '.active_count // 0' "$REGISTRY_FILE")
    total_agents=$(jq -r '.agents | length' "$REGISTRY_FILE")

    local avg_quality=0
    if [[ $total_agents -gt 0 ]]; then
        avg_quality=$(jq '[.agents[].quality_score] | add / length' "$REGISTRY_FILE" 2>/dev/null || echo "0")
    fi

    echo -e "  Total agents:       ${CYAN}${total_agents}${RESET}"
    echo -e "  Active agents:      ${GREEN}${active_count}${RESET}"
    echo -e "  Avg quality score:  ${CYAN}${avg_quality}${RESET}"
    echo -e "  Config file:        ${DIM}${CONFIG_FILE}${RESET}"
    echo ""

    if [[ $total_agents -eq 0 ]]; then
        echo -e "  ${DIM}No agents in swarm. Spawn one with: shipwright swarm spawn${RESET}"
    fi
}

# ─── Configure scaling parameters ────────────────────────────────────────
cmd_config() {
    local subcmd="${1:-show}"
    shift 2>/dev/null || true

    ensure_dirs
    init_config

    case "$subcmd" in
        show)
            info "Swarm Configuration"
            echo ""
            cat "$CONFIG_FILE" | jq '.' | sed 's/^/  /'
            echo ""
            ;;
        set)
            local key="${1:-}"
            local value="${2:-}"

            if [[ -z "$key" || -z "$value" ]]; then
                error "Usage: shipwright swarm config set <key> <value>"
                return 1
            fi

            local tmp_file
            tmp_file=$(mktemp)
            trap "rm -f '$tmp_file'" RETURN

            jq --arg key "$key" --arg value "$value" \
                'if ($value | test("^[0-9]+$")) then
                    .[$key] = ($value | tonumber)
                elif ($value == "true" or $value == "false") then
                    .[$key] = ($value | fromjson)
                else
                    .[$key] = $value
                end' "$CONFIG_FILE" > "$tmp_file" && [[ -s "$tmp_file" ]] && \
            mv "$tmp_file" "$CONFIG_FILE" || { rm -f "$tmp_file"; error "Failed to update config"; return 1; }
            success "Updated: ${key} = ${value}"
            ;;
        reset)
            rm -f "$CONFIG_FILE"
            init_config
            success "Config reset to defaults"
            ;;
        *)
            error "Unknown subcommand: $subcmd"
            echo -e "  Valid: ${CYAN}show${RESET}, ${CYAN}set${RESET}, ${CYAN}reset${RESET}"
            return 1
            ;;
    esac
}

# ─── Help message ─────────────────────────────────────────────────────────
cmd_help() {
    cat << 'EOF'
shipwright swarm — Dynamic agent swarm management

USAGE
  shipwright swarm <command> [options]

COMMANDS
  spawn [type]       Spawn new agent (type: fast/standard/powerful, default: standard)
  retire <agent-id>  Gracefully retire an agent (drain tasks first)
  health [agent-id]  Check agent health (all agents or specific one)
  scale              Show auto-scaling status and recommendations
  top [N]            Show top N performing agents (default: 10)
  topology           Visualize swarm structure and resource allocation
  status             Show swarm overview (active agents, utilization, queue)
  config             Manage configuration parameters
  help               Show this help message

CONFIG SUBCOMMANDS
  config show        Display current swarm configuration
  config set <k> <v> Update a config parameter
  config reset       Reset to default configuration

CONFIGURATION (stored in ~/.shipwright/swarm/config.json)
  auto_scaling_enabled        Enable/disable automatic scaling (default: false)
  min_agents                  Minimum agents to maintain (default: 1)
  max_agents                  Maximum agents allowed (default: 8)
  target_utilization          Target CPU/task utilization (default: 0.75)
  health_check_interval       Interval between health checks in seconds (default: 30)
  stall_detection_threshold   Seconds before marking agent as stalled (default: 300)

AGENT TYPES
  fast        Low cost, optimized for simple tasks (1x cost multiplier)
  standard    Balanced cost/capability for complex tasks (2x cost multiplier)
  powerful    High capability for expert/difficult tasks (4x cost multiplier)

EXAMPLES
  # Spawn a standard agent
  shipwright swarm spawn

  # Spawn a fast/cheap agent
  shipwright swarm spawn fast

  # Show health of all agents
  shipwright swarm health

  # Check specific agent health
  shipwright swarm health agent-123

  # View performance leaderboard
  shipwright swarm top 20

  # Show swarm topology
  shipwright swarm topology

  # Enable auto-scaling
  shipwright swarm config set auto_scaling_enabled true

  # Set max agents to 12
  shipwright swarm config set max_agents 12

STATE FILES
  Registry:        ~/.shipwright/swarm/registry.json
  Configuration:   ~/.shipwright/swarm/config.json
  Metrics:         ~/.shipwright/swarm/metrics.jsonl
  Health Log:      ~/.shipwright/swarm/health.jsonl

EOF
}

# ─── Main router ──────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        spawn)
            cmd_spawn "$@"
            ;;
        retire)
            cmd_retire "$@"
            ;;
        health)
            cmd_health "$@"
            ;;
        scale)
            cmd_scale "$@"
            ;;
        top)
            cmd_top "$@"
            ;;
        topology)
            cmd_topology "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        config)
            cmd_config "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

# Only run main if this script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
