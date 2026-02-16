#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright remote — Machine Registry & Remote Daemon Management        ║
# ║  Register machines · Deploy scripts · Monitor distributed workers       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.1"
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

# ─── Defaults ───────────────────────────────────────────────────────────────
MACHINES_FILE="$HOME/.shipwright/machines.json"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

# ─── CLI Argument Parsing ──────────────────────────────────────────────────
SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

# Collect positional args and flags
POSITIONAL_ARGS=()
OPT_HOST=""
OPT_USER=""
OPT_PATH=""
OPT_MAX_WORKERS=""
OPT_ROLE=""
OPT_STOP_DAEMON=false
OPT_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            OPT_HOST="${2:-}"
            shift 2
            ;;
        --host=*)
            OPT_HOST="${1#--host=}"
            shift
            ;;
        --user)
            OPT_USER="${2:-}"
            shift 2
            ;;
        --user=*)
            OPT_USER="${1#--user=}"
            shift
            ;;
        --path)
            OPT_PATH="${2:-}"
            shift 2
            ;;
        --path=*)
            OPT_PATH="${1#--path=}"
            shift
            ;;
        --max-workers)
            OPT_MAX_WORKERS="${2:-}"
            shift 2
            ;;
        --max-workers=*)
            OPT_MAX_WORKERS="${1#--max-workers=}"
            shift
            ;;
        --role)
            OPT_ROLE="${2:-}"
            shift 2
            ;;
        --role=*)
            OPT_ROLE="${1#--role=}"
            shift
            ;;
        --stop-daemon)
            OPT_STOP_DAEMON=true
            shift
            ;;
        --json)
            OPT_JSON=true
            shift
            ;;
        --help|-h)
            SUBCOMMAND="help"
            shift
            ;;
        -*)
            error "Unknown option: $1"
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ shipwright remote v${VERSION} ━━━${RESET}"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright remote${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}add${RESET} <name>    Register a machine"
    echo -e "  ${CYAN}remove${RESET} <name> Remove a machine from registry"
    echo -e "  ${CYAN}list${RESET}          Show registered machines"
    echo -e "  ${CYAN}status${RESET}        Health check all machines"
    echo -e "  ${CYAN}deploy${RESET} <name> Deploy shipwright to a remote machine"
    echo -e "  ${CYAN}help${RESET}          Show this help"
    echo ""
    echo -e "${BOLD}ADD OPTIONS${RESET}"
    echo -e "  ${CYAN}--host${RESET} <host>           Hostname or IP ${DIM}(required)${RESET}"
    echo -e "  ${CYAN}--user${RESET} <user>           SSH user for remote machines"
    echo -e "  ${CYAN}--path${RESET} <path>           Shipwright install path on machine ${DIM}(required)${RESET}"
    echo -e "  ${CYAN}--max-workers${RESET} <N>       Maximum worker count ${DIM}(default: 4)${RESET}"
    echo -e "  ${CYAN}--role${RESET} <primary|worker> Machine role ${DIM}(default: worker)${RESET}"
    echo ""
    echo -e "${BOLD}REMOVE OPTIONS${RESET}"
    echo -e "  ${CYAN}--stop-daemon${RESET}           Stop remote daemon before removing"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright remote add dev-laptop --host localhost --path /Users/seth/shipwright --role primary${RESET}"
    echo -e "  ${DIM}shipwright remote add build-srv --host 192.168.1.100 --user seth --path /home/seth/shipwright --max-workers 8${RESET}"
    echo -e "  ${DIM}shipwright remote list${RESET}"
    echo -e "  ${DIM}shipwright remote status${RESET}"
    echo -e "  ${DIM}shipwright remote deploy build-srv${RESET}"
    echo -e "  ${DIM}shipwright remote remove build-srv --stop-daemon${RESET}"
    echo ""
}

# ─── Machine Registry Helpers ──────────────────────────────────────────────

ensure_machines_file() {
    mkdir -p "$HOME/.shipwright"
    if [[ ! -f "$MACHINES_FILE" ]]; then
        echo '{"machines":[]}' > "$MACHINES_FILE"
    fi
    # Validate JSON
    if ! jq empty "$MACHINES_FILE" 2>/dev/null; then
        error "Corrupted machines file: $MACHINES_FILE"
        exit 1
    fi
}

get_machine() {
    local name="$1"
    jq -r --arg n "$name" '.machines[] | select(.name == $n)' "$MACHINES_FILE"
}

machine_exists() {
    local name="$1"
    local found
    found=$(jq -r --arg n "$name" '.machines[] | select(.name == $n) | .name' "$MACHINES_FILE" 2>/dev/null || true)
    [[ -n "$found" ]]
}

is_localhost() {
    local host="$1"
    [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]
}

# Run a command on a machine (local or remote)
run_on_machine() {
    local host="$1"
    local ssh_user="$2"
    local cmd="$3"

    if is_localhost "$host"; then
        bash -c "$cmd"
    else
        local target="$host"
        if [[ -n "$ssh_user" && "$ssh_user" != "null" ]]; then
            target="${ssh_user}@${host}"
        fi
        # shellcheck disable=SC2086
        ssh $SSH_OPTS "$target" "$cmd"
    fi
}

# ─── Add Machine ───────────────────────────────────────────────────────────

remote_add() {
    local name="${POSITIONAL_ARGS[0]:-}"
    local host="$OPT_HOST"
    local ssh_user="$OPT_USER"
    local sw_path="$OPT_PATH"
    local max_workers="${OPT_MAX_WORKERS:-4}"
    local role="${OPT_ROLE:-worker}"

    # Validate required fields
    if [[ -z "$name" ]]; then
        error "Machine name is required"
        echo ""
        echo -e "  Usage: ${CYAN}shipwright remote add <name> --host <host> --path <path>${RESET}"
        exit 1
    fi
    if [[ -z "$host" ]]; then
        error "Host is required (--host)"
        exit 1
    fi
    if [[ -z "$sw_path" ]]; then
        error "Shipwright path is required (--path)"
        exit 1
    fi

    # Validate role
    if [[ "$role" != "primary" && "$role" != "worker" ]]; then
        error "Role must be 'primary' or 'worker', got: $role"
        exit 1
    fi

    # Validate max_workers is numeric
    if ! [[ "$max_workers" =~ ^[0-9]+$ ]]; then
        error "max-workers must be a positive integer, got: $max_workers"
        exit 1
    fi

    ensure_machines_file

    # Check for duplicate
    if machine_exists "$name"; then
        error "Machine '$name' already registered"
        info "Use ${CYAN}shipwright remote remove $name${RESET} first"
        exit 1
    fi

    # Test SSH connectivity for remote machines
    if ! is_localhost "$host"; then
        info "Testing SSH connectivity to ${BOLD}$host${RESET}..."
        local target="$host"
        if [[ -n "$ssh_user" ]]; then
            target="${ssh_user}@${host}"
        fi
        # shellcheck disable=SC2086
        if ! ssh $SSH_OPTS "$target" "echo ok" >/dev/null 2>&1; then
            error "Cannot connect to $target via SSH"
            echo ""
            echo -e "  Ensure SSH access is configured:"
            echo -e "    ${DIM}ssh-copy-id ${target}${RESET}"
            echo -e "    ${DIM}ssh ${target} echo ok${RESET}"
            exit 1
        fi
        success "SSH connection verified"
    fi

    # Check shipwright is installed at the given path
    info "Checking shipwright installation at ${DIM}${sw_path}${RESET}..."
    local check_cmd="test -f '${sw_path}/scripts/sw' && echo 'found' || echo 'missing'"
    local result
    result=$(run_on_machine "$host" "$ssh_user" "$check_cmd" 2>/dev/null || echo "error")

    if [[ "$result" == "missing" ]]; then
        warn "Shipwright not found at $sw_path on $host"
        info "Use ${CYAN}shipwright remote deploy $name${RESET} after registering to install"
    elif [[ "$result" == "error" ]]; then
        warn "Could not verify shipwright installation on $host"
    else
        success "Shipwright found at $sw_path"
    fi

    # Build the new machine entry and add to registry atomically
    local tmp_file="${MACHINES_FILE}.tmp.$$"
    jq --arg name "$name" \
       --arg host "$host" \
       --arg role "$role" \
       --arg ssh_user "$ssh_user" \
       --arg sw_path "$sw_path" \
       --argjson max_workers "$max_workers" \
       --arg ts "$(now_iso)" \
       '.machines += [{
           name: $name,
           host: $host,
           role: $role,
           ssh_user: (if $ssh_user == "" then null else $ssh_user end),
           shipwright_path: $sw_path,
           max_workers: $max_workers,
           registered_at: $ts
       }]' "$MACHINES_FILE" > "$tmp_file" && mv "$tmp_file" "$MACHINES_FILE"

    emit_event "remote.add" "machine=$name" "host=$host" "role=$role" "max_workers=$max_workers"
    success "Registered machine: ${BOLD}$name${RESET} ($host, $role, ${max_workers} workers)"
}

# ─── Remove Machine ───────────────────────────────────────────────────────

remote_remove() {
    local name="${POSITIONAL_ARGS[0]:-}"

    if [[ -z "$name" ]]; then
        error "Machine name is required"
        echo ""
        echo -e "  Usage: ${CYAN}shipwright remote remove <name>${RESET}"
        exit 1
    fi

    ensure_machines_file

    if ! machine_exists "$name"; then
        error "Machine '$name' not found in registry"
        exit 1
    fi

    # Optionally stop remote daemon
    if [[ "$OPT_STOP_DAEMON" == true ]]; then
        info "Stopping daemon on ${BOLD}$name${RESET}..."
        local host ssh_user sw_path
        host=$(jq -r --arg n "$name" '.machines[] | select(.name == $n) | .host' "$MACHINES_FILE")
        ssh_user=$(jq -r --arg n "$name" '.machines[] | select(.name == $n) | .ssh_user // ""' "$MACHINES_FILE")
        sw_path=$(jq -r --arg n "$name" '.machines[] | select(.name == $n) | .shipwright_path' "$MACHINES_FILE")

        local stop_cmd="cd '${sw_path}' && ./scripts/sw daemon stop 2>/dev/null || true"
        if run_on_machine "$host" "$ssh_user" "$stop_cmd" 2>/dev/null; then
            success "Daemon stopped on $name"
        else
            warn "Could not stop daemon on $name (may not be running)"
        fi
    fi

    # Remove from registry atomically
    local tmp_file="${MACHINES_FILE}.tmp.$$"
    jq --arg name "$name" '.machines = [.machines[] | select(.name != $name)]' "$MACHINES_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$MACHINES_FILE"

    emit_event "remote.remove" "machine=$name"
    success "Removed machine: ${BOLD}$name${RESET}"
}

# ─── List Machines ─────────────────────────────────────────────────────────

remote_list() {
    ensure_machines_file

    local count
    count=$(jq '.machines | length' "$MACHINES_FILE")

    if [[ "$count" -eq 0 ]]; then
        echo ""
        echo -e "  ${DIM}No machines registered.${RESET}"
        echo -e "  ${DIM}Register one with: ${CYAN}shipwright remote add <name> --host <host> --path <path>${RESET}"
        echo ""
        return
    fi

    # JSON output mode
    if [[ "$OPT_JSON" == true ]]; then
        jq '.' "$MACHINES_FILE"
        return
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Registered Machines ━━━${RESET}"
    echo ""

    # Table header
    printf "  ${BOLD}%-16s %-20s %-8s %-8s %-22s${RESET}\n" "NAME" "HOST" "ROLE" "WORKERS" "REGISTERED"
    echo -e "  ${DIM}$(printf '─%.0s' {1..76})${RESET}"

    # Table rows
    local i
    for i in $(seq 0 $((count - 1))); do
        local name host role max_workers registered_at
        name=$(jq -r --argjson i "$i" '.machines[$i].name' "$MACHINES_FILE")
        host=$(jq -r --argjson i "$i" '.machines[$i].host' "$MACHINES_FILE")
        role=$(jq -r --argjson i "$i" '.machines[$i].role' "$MACHINES_FILE")
        max_workers=$(jq -r --argjson i "$i" '.machines[$i].max_workers' "$MACHINES_FILE")
        registered_at=$(jq -r --argjson i "$i" '.machines[$i].registered_at' "$MACHINES_FILE")

        # Trim timestamp for display
        local display_ts
        display_ts=$(echo "$registered_at" | cut -c1-19 | tr 'T' ' ')

        # Color role
        local role_display
        if [[ "$role" == "primary" ]]; then
            role_display="${CYAN}${role}${RESET}"
        else
            role_display="${DIM}${role}${RESET}"
        fi

        printf "  %-16s %-20s " "$name" "$host"
        echo -ne "$role_display"
        # Pad after colored role (role is max 7 chars)
        local pad=$((8 - ${#role}))
        printf "%${pad}s" ""
        printf "%-8s %s\n" "$max_workers" "$display_ts"
    done

    echo ""
    echo -e "  ${DIM}${count} machine(s) registered${RESET}"
    echo ""
}

# ─── Status / Health Check ─────────────────────────────────────────────────

remote_status() {
    ensure_machines_file

    local count
    count=$(jq '.machines | length' "$MACHINES_FILE")

    if [[ "$count" -eq 0 ]]; then
        echo ""
        echo -e "  ${DIM}No machines registered.${RESET}"
        echo ""
        return
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Machine Health Status ━━━${RESET}"
    echo -e "${DIM}  $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo ""

    # Table header
    printf "  ${BOLD}%-16s %-20s %-10s %-10s %-12s${RESET}\n" "NAME" "HOST" "STATUS" "WORKERS" "HEARTBEATS"
    echo -e "  ${DIM}$(printf '─%.0s' {1..70})${RESET}"

    local online_count=0
    local offline_count=0
    local degraded_count=0

    local i
    for i in $(seq 0 $((count - 1))); do
        local name host ssh_user sw_path max_workers
        name=$(jq -r --argjson i "$i" '.machines[$i].name' "$MACHINES_FILE")
        host=$(jq -r --argjson i "$i" '.machines[$i].host' "$MACHINES_FILE")
        ssh_user=$(jq -r --argjson i "$i" '.machines[$i].ssh_user // ""' "$MACHINES_FILE")
        sw_path=$(jq -r --argjson i "$i" '.machines[$i].shipwright_path' "$MACHINES_FILE")
        max_workers=$(jq -r --argjson i "$i" '.machines[$i].max_workers' "$MACHINES_FILE")

        local status_label status_icon active_workers heartbeat_count
        active_workers=0
        heartbeat_count=0

        # Build health check command
        local health_cmd
        health_cmd=$(cat <<'HEALTHEOF'
            daemon_pid=""
            hb_count=0
            active=0
            # Check for daemon PID
            if [ -f "$HOME/.shipwright/daemon.pid" ]; then
                daemon_pid=$(cat "$HOME/.shipwright/daemon.pid" 2>/dev/null || true)
                if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
                    daemon_pid="$daemon_pid"
                else
                    daemon_pid=""
                fi
            fi
            # Count heartbeat files
            if [ -d "$HOME/.shipwright/heartbeats" ]; then
                hb_count=$(ls -1 "$HOME/.shipwright/heartbeats/" 2>/dev/null | wc -l | tr -d ' ')
            fi
            # Count active jobs from daemon state
            if [ -f "$HOME/.shipwright/daemon-state.json" ]; then
                active=$(python3 -c "import json; d=json.load(open('$HOME/.shipwright/daemon-state.json')); print(len(d.get('active_jobs',{})))" 2>/dev/null || echo 0)
            fi
            echo "${daemon_pid:-none}|${hb_count}|${active}"
HEALTHEOF
        )

        local result
        result=$(run_on_machine "$host" "$ssh_user" "$health_cmd" 2>/dev/null || echo "error|0|0")

        local daemon_pid hb_val active_val
        daemon_pid=$(echo "$result" | cut -d'|' -f1)
        hb_val=$(echo "$result" | cut -d'|' -f2)
        active_val=$(echo "$result" | cut -d'|' -f3)

        # Sanitize numeric values
        [[ ! "$hb_val" =~ ^[0-9]+$ ]] && hb_val=0
        [[ ! "$active_val" =~ ^[0-9]+$ ]] && active_val=0
        heartbeat_count="$hb_val"
        active_workers="$active_val"

        if [[ "$daemon_pid" == "error" ]]; then
            status_label="${RED}offline${RESET}"
            status_icon="${RED}●${RESET}"
            offline_count=$((offline_count + 1))
        elif [[ "$daemon_pid" == "none" ]]; then
            if is_localhost "$host"; then
                status_label="${YELLOW}no-daemon${RESET}"
                status_icon="${YELLOW}●${RESET}"
                degraded_count=$((degraded_count + 1))
            else
                status_label="${RED}offline${RESET}"
                status_icon="${RED}●${RESET}"
                offline_count=$((offline_count + 1))
            fi
        else
            status_label="${GREEN}online${RESET}"
            status_icon="${GREEN}●${RESET}"
            online_count=$((online_count + 1))
        fi

        local worker_display="${active_val}/${max_workers}"

        printf "  %-16s %-20s " "$name" "$host"
        echo -ne "${status_icon} "
        echo -ne "$status_label"
        # Pad after colored status
        local status_text
        if [[ "$daemon_pid" == "error" ]]; then
            status_text="offline"
        elif [[ "$daemon_pid" == "none" ]]; then
            if is_localhost "$host"; then
                status_text="no-daemon"
            else
                status_text="offline"
            fi
        else
            status_text="online"
        fi
        local spad=$((10 - ${#status_text} - 2))
        [[ "$spad" -lt 0 ]] && spad=0
        printf "%${spad}s" ""
        printf "%-10s %s\n" "$worker_display" "$heartbeat_count"
    done

    echo ""
    echo -e "  ${GREEN}●${RESET} ${online_count} online  ${YELLOW}●${RESET} ${degraded_count} degraded  ${RED}●${RESET} ${offline_count} offline"
    echo ""
}

# ─── Deploy ────────────────────────────────────────────────────────────────

remote_deploy() {
    local name="${POSITIONAL_ARGS[0]:-}"

    if [[ -z "$name" ]]; then
        error "Machine name is required"
        echo ""
        echo -e "  Usage: ${CYAN}shipwright remote deploy <name>${RESET}"
        exit 1
    fi

    ensure_machines_file

    if ! machine_exists "$name"; then
        error "Machine '$name' not found in registry"
        exit 1
    fi

    local host ssh_user sw_path
    host=$(jq -r --arg n "$name" '.machines[] | select(.name == $n) | .host' "$MACHINES_FILE")
    ssh_user=$(jq -r --arg n "$name" '.machines[] | select(.name == $n) | .ssh_user // ""' "$MACHINES_FILE")
    sw_path=$(jq -r --arg n "$name" '.machines[] | select(.name == $n) | .shipwright_path' "$MACHINES_FILE")

    if is_localhost "$host"; then
        error "Cannot deploy to localhost — shipwright is already local"
        info "Use ${CYAN}shipwright upgrade --apply${RESET} to update the local installation"
        exit 1
    fi

    local target="$host"
    if [[ -n "$ssh_user" && "$ssh_user" != "null" ]]; then
        target="${ssh_user}@${host}"
    fi

    info "Deploying shipwright to ${BOLD}$name${RESET} ($host)..."
    echo ""

    # Step 1: Ensure target directory exists
    info "Creating target directory..."
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$target" "mkdir -p '${sw_path}'" || {
        error "Failed to create directory $sw_path on $host"
        exit 1
    }

    # Step 2: rsync scripts and essential files
    info "Syncing scripts..."
    local rsync_src="${REPO_DIR}/"
    local rsync_dst="${target}:${sw_path}/"

    rsync -avz --delete \
        --include='scripts/***' \
        --include='templates/***' \
        --include='tmux/***' \
        --include='install.sh' \
        --include='package.json' \
        --exclude='*' \
        -e "ssh $SSH_OPTS" \
        "$rsync_src" "$rsync_dst" || {
        error "rsync failed"
        exit 1
    }
    success "Scripts synced"

    # Step 3: Run install.sh remotely
    info "Running install.sh on remote..."
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$target" "cd '${sw_path}' && bash install.sh --non-interactive" || {
        warn "install.sh returned non-zero (may need manual intervention)"
    }

    # Step 4: Verify
    info "Verifying installation..."
    local verify_cmd="test -x '${sw_path}/scripts/sw' && '${sw_path}/scripts/sw' --version 2>/dev/null || echo 'verify-failed'"
    local verify_result
    # shellcheck disable=SC2086
    verify_result=$(ssh $SSH_OPTS "$target" "$verify_cmd" 2>/dev/null || echo "verify-failed")

    if [[ "$verify_result" == "verify-failed" ]]; then
        warn "Could not verify installation — check manually"
    else
        success "Verified: $verify_result"
    fi

    emit_event "remote.deploy" "machine=$name" "host=$host"
    echo ""
    success "Deployment complete for ${BOLD}$name${RESET}"
    echo ""
}

# ─── Command Router ─────────────────────────────────────────────────────────

case "$SUBCOMMAND" in
    add)
        remote_add
        ;;
    remove|rm)
        remote_remove
        ;;
    list|ls)
        remote_list
        ;;
    status)
        remote_status
        ;;
    deploy)
        remote_deploy
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
