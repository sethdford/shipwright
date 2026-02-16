#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright scale — Dynamic agent team scaling during pipeline execution ║
# ║  Scale up/down, manage rules, track history, recommend actions          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Dependency check ─────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    echo "ERROR: sw-scale.sh requires 'jq'. Install with: brew install jq (macOS) or apt install jq (Linux)" >&2
    exit 1
fi

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
SCALE_RULES_FILE="${HOME}/.shipwright/scale-rules.json"
SCALE_EVENTS_FILE="${HOME}/.shipwright/scale-events.jsonl"
SCALE_STATE_FILE="${HOME}/.shipwright/scale-state.json"

# ─── Ensure directories exist ──────────────────────────────────────────────
ensure_dirs() {
    mkdir -p "$HOME/.shipwright"
}

# ─── Initialize rules file ────────────────────────────────────────────────
init_rules() {
    if [[ ! -f "$SCALE_RULES_FILE" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        cat > "$tmp_file" << 'JSON'
{
  "iteration_threshold": 3,
  "coverage_threshold": 60,
  "module_threshold": 5,
  "budget_check": true,
  "cooldown_seconds": 120,
  "max_team_size": 8,
  "roles": ["builder", "reviewer", "tester", "security-auditor"]
}
JSON
        mv "$tmp_file" "$SCALE_RULES_FILE"
        success "Initialized scaling rules"
    fi
}

# ─── Get current unix timestamp ───────────────────────────────────────────
get_last_scale_time() {
    if [[ -f "$SCALE_STATE_FILE" ]]; then
        jq -r '.last_scale_time // 0' "$SCALE_STATE_FILE" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# ─── Check if we're within cooldown period ───────────────────────────────
in_cooldown() {
    local cooldown
    cooldown=$(jq -r '.cooldown_seconds // 120' "$SCALE_RULES_FILE" 2>/dev/null || echo "120")
    local last_time
    last_time=$(get_last_scale_time)
    local now
    now=$(now_epoch)
    local elapsed=$((now - last_time))
    [[ $elapsed -lt $cooldown ]]
}

# ─── Update scale state ───────────────────────────────────────────────────
update_scale_state() {
    local tmp_file
    tmp_file=$(mktemp)

    if [[ -f "$SCALE_STATE_FILE" ]]; then
        # Update existing state
        jq --arg now "$(now_epoch)" '.last_scale_time = ($now | tonumber)' "$SCALE_STATE_FILE" > "$tmp_file"
    else
        # Create new state
        cat > "$tmp_file" << JSON
{
  "last_scale_time": $(now_epoch),
  "team_size": 0,
  "events_count": 0
}
JSON
    fi

    mv "$tmp_file" "$SCALE_STATE_FILE"
}

# ─── Emit scaling event ───────────────────────────────────────────────────
emit_scale_event() {
    local action="$1"      # up, down, auto
    local role="$2"        # builder, reviewer, tester, security
    local reason="$3"      # iteration_threshold, coverage_threshold, etc
    local context="${4:-}" # additional context

    ensure_dirs

    local event
    event=$(jq -c -n \
        --arg ts "$(now_iso)" \
        --arg action "$action" \
        --arg role "$role" \
        --arg reason "$reason" \
        --arg context "$context" \
        '{ts: $ts, action: $action, role: $role, reason: $reason, context: $context}')

    echo "$event" >> "$SCALE_EVENTS_FILE"
    type rotate_jsonl &>/dev/null 2>&1 && rotate_jsonl "$SCALE_EVENTS_FILE" 5000
}

# ─── Scale Up: spawn new agent ───────────────────────────────────────────
cmd_up() {
    local role="${1:-builder}"
    shift 2>/dev/null || true

    ensure_dirs
    init_rules

    # Validate role
    local valid_roles="builder reviewer tester security-auditor architect docs-writer optimizer devops pm incident-responder"
    if ! echo "$valid_roles" | grep -q "$role"; then
        error "Invalid role: $role. Valid roles: $valid_roles"
        return 1
    fi

    # Check cooldown
    if in_cooldown; then
        local cooldown
        cooldown=$(jq -r '.cooldown_seconds // 120' "$SCALE_RULES_FILE")
        warn "Scaling cooldown active. Wait ${cooldown}s before next scale event."
        return 1
    fi

    # Check max team size
    local max_size
    max_size=$(jq -r '.max_team_size // 8' "$SCALE_RULES_FILE")

    info "Scaling up team with ${role} agent"
    echo -e "  Max team size: ${CYAN}${max_size}${RESET}"
    echo -e "  Role:          ${CYAN}${role}${RESET}"
    echo ""

    # TODO: Integrate with tmux/SendMessage to spawn agent
    # For now, emit event and log
    emit_scale_event "up" "$role" "manual" "$*"
    update_scale_state

    success "Scale-up event recorded (role: ${role})"
    echo ""
    echo -e "  ${DIM}Note: Actual agent spawn requires tmux/claude integration${RESET}"
}

# ─── Scale Down: send shutdown to agent ──────────────────────────────────
cmd_down() {
    local agent_id="${1:-}"
    shift 2>/dev/null || true

    if [[ -z "$agent_id" ]]; then
        error "Usage: shipwright scale down <agent-id>"
        return 1
    fi

    ensure_dirs
    init_rules

    info "Scaling down agent: ${agent_id}"
    echo ""

    # TODO: Integrate with SendMessage to shut down agent
    emit_scale_event "down" "unknown" "manual" "agent_id=$agent_id"
    update_scale_state

    success "Scale-down event recorded (agent: ${agent_id})"
    echo -e "  ${DIM}Note: Agent shutdown requires SendMessage integration${RESET}"
}

# ─── Manage scaling rules ────────────────────────────────────────────────
cmd_rules() {
    local subcmd="${1:-show}"
    shift 2>/dev/null || true

    ensure_dirs
    init_rules

    case "$subcmd" in
        show)
            info "Scaling Rules"
            echo ""
            cat "$SCALE_RULES_FILE" | jq '.' | sed 's/^/  /'
            echo ""
            ;;
        set)
            local key="${1:-}"
            local value="${2:-}"

            if [[ -z "$key" || -z "$value" ]]; then
                error "Usage: shipwright scale rules set <key> <value>"
                return 1
            fi

            local tmp_file
            tmp_file=$(mktemp)

            jq --arg key "$key" --arg value "$value" \
                'if ($value | test("^[0-9]+$")) then
                    .[$key] = ($value | tonumber)
                else
                    .[$key] = $value
                end' "$SCALE_RULES_FILE" > "$tmp_file"

            mv "$tmp_file" "$SCALE_RULES_FILE"
            success "Updated: ${key} = ${value}"
            ;;
        reset)
            rm -f "$SCALE_RULES_FILE"
            init_rules
            success "Rules reset to defaults"
            ;;
        *)
            error "Unknown subcommand: $subcmd"
            echo -e "  Valid: ${CYAN}show${RESET}, ${CYAN}set${RESET}, ${CYAN}reset${RESET}"
            return 1
            ;;
    esac
}

# ─── Show current status ──────────────────────────────────────────────────
cmd_status() {
    ensure_dirs
    init_rules

    local team_size=0
    local event_count=0

    if [[ -f "$SCALE_STATE_FILE" ]]; then
        team_size=$(jq -r '.team_size // 0' "$SCALE_STATE_FILE" 2>/dev/null || echo "0")
    fi

    if [[ -f "$SCALE_EVENTS_FILE" ]]; then
        event_count=$(wc -l < "$SCALE_EVENTS_FILE" || echo "0")
    fi

    local last_scale_time
    last_scale_time=$(get_last_scale_time)

    info "Scaling Status"
    echo ""
    echo -e "  Team size:          ${CYAN}${team_size}${RESET}"
    echo -e "  Scale events:       ${CYAN}${event_count}${RESET}"
    echo -e "  Last scale:         ${CYAN}$(date -u -d @"$last_scale_time" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "never")${RESET}"

    local max_size
    max_size=$(jq -r '.max_team_size // 8' "$SCALE_RULES_FILE")
    echo -e "  Max team size:      ${CYAN}${max_size}${RESET}"
    echo ""
}

# ─── Show scaling history ────────────────────────────────────────────────
cmd_history() {
    local limit="${1:-20}"
    shift 2>/dev/null || true

    ensure_dirs

    if [[ ! -f "$SCALE_EVENTS_FILE" ]]; then
        warn "No scaling events recorded"
        return 0
    fi

    info "Scaling History (last ${limit} events)"
    echo ""

    tail -n "$limit" "$SCALE_EVENTS_FILE" | while IFS= read -r line; do
        local ts action role reason
        ts=$(echo "$line" | jq -r '.ts // "unknown"' 2>/dev/null || echo "unknown")
        action=$(echo "$line" | jq -r '.action // "unknown"' 2>/dev/null || echo "unknown")
        role=$(echo "$line" | jq -r '.role // "unknown"' 2>/dev/null || echo "unknown")
        reason=$(echo "$line" | jq -r '.reason // "unknown"' 2>/dev/null || echo "unknown")
        printf "  %s ${CYAN}%-6s${RESET} %-10s %s\n" "$ts" "$action" "$role" "$reason"
    done

    echo ""
}

# ─── Recommend scaling actions ───────────────────────────────────────────
cmd_recommend() {
    ensure_dirs
    init_rules

    local iteration_threshold
    iteration_threshold=$(jq -r '.iteration_threshold // 3' "$SCALE_RULES_FILE")

    local coverage_threshold
    coverage_threshold=$(jq -r '.coverage_threshold // 60' "$SCALE_RULES_FILE")

    local module_threshold
    module_threshold=$(jq -r '.module_threshold // 5' "$SCALE_RULES_FILE")

    info "Scaling Recommendations"
    echo ""
    echo -e "  Thresholds:"
    echo -e "    Failed iterations: ${CYAN}${iteration_threshold}${RESET} (add tester on failure)"
    echo -e "    Test coverage:     ${CYAN}${coverage_threshold}%${RESET} (add tester below this)"
    echo -e "    Modules changed:   ${CYAN}${module_threshold}${RESET} (add reviewer above this)"
    echo ""

    # TODO: Parse pipeline context to generate actual recommendations
    echo -e "  ${DIM}Recommendations require active pipeline context (passed via environment)${RESET}"
    echo ""

    # Example output when context is available:
    # echo -e "  ${YELLOW}⚠${RESET}  Failed 4 iterations (threshold: 3)"
    # echo -e "       ${CYAN}→ Recommend adding: tester${RESET}"
    # echo ""
    # echo -e "  ${YELLOW}⚠${RESET}  Coverage at 45% (threshold: 60%)"
    # echo -e "       ${CYAN}→ Recommend adding: tester${RESET}"
}

# ─── Help message ────────────────────────────────────────────────────────
cmd_help() {
    cat << 'EOF'
shipwright scale — Dynamic agent team scaling during pipeline execution

USAGE
  shipwright scale <command> [options]

COMMANDS
  up [role]          Spawn new agent with specific role (builder/reviewer/tester/security)
  down <agent-id>    Gracefully shutdown an agent (waits for task completion)
  rules              Manage scaling rules (iteration_threshold, coverage_threshold, etc)
  status             Show current team size, scaling history, budget impact
  history [N]        Show last N scaling events (default: 20)
  recommend          Analyze pipeline state and suggest scaling actions
  help               Show this help message

RULES SUBCOMMANDS
  rules show         Display current scaling rules
  rules set <k> <v>  Update a rule (e.g., rules set max_team_size 10)
  rules reset        Reset to default rules

OPTIONS
  --cooldown <secs>  Minimum seconds between scale events (default: 120)
  --max-size <n>     Maximum team size (default: 8)

RULES (stored in ~/.shipwright/scale-rules.json)
  iteration_threshold    Scale up after N failed iterations (default: 3)
  coverage_threshold     Add tester when coverage < N% (default: 60)
  module_threshold       Split builders when touching > N modules (default: 5)
  budget_check           Factor in remaining budget before scaling (default: true)
  cooldown_seconds       Minimum time between scale events (default: 120)
  max_team_size          Maximum agents per team (default: 8)

EXAMPLES
  # Add a tester to the current team
  shipwright scale up tester

  # Remove an agent gracefully
  shipwright scale down agent-42

  # View current scaling rules
  shipwright scale rules show

  # Update max team size
  shipwright scale rules set max_team_size 10

  # Show recent scaling events
  shipwright scale history

  # Get scaling recommendations for current pipeline
  shipwright scale recommend --issue 46

INTEGRATION
  Scaling events are recorded in ~/.shipwright/scale-events.jsonl
  State is persisted in ~/.shipwright/scale-state.json
  Rules are stored in ~/.shipwright/scale-rules.json

  Actual agent spawning/shutdown integrates with:
    - tmux (for new pane creation)
    - SendMessage tool (for agent communication)
    - Pipeline context (from sw-pipeline.sh environment)

EOF
}

# ─── Main router ──────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        up)
            cmd_up "$@"
            ;;
        down)
            cmd_down "$@"
            ;;
        rules)
            cmd_rules "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        history)
            cmd_history "$@"
            ;;
        recommend)
            cmd_recommend "$@"
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
