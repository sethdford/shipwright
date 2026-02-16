#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright launchd — Process supervision (macOS + Linux)                 ║
# ║  Auto-start daemon + dashboard on boot via launchd (macOS) or systemd     ║
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

# ─── OS Detection ───────────────────────────────────────────────────────────
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]] || [[ "$OSTYPE" == "linux"* ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)

# ─── Platform-specific Constants ────────────────────────────────────────────
if [[ "$OS_TYPE" == "macos" ]]; then
    PLIST_DIR="$HOME/Library/LaunchAgents"
    DAEMON_PLIST="$PLIST_DIR/com.shipwright.daemon.plist"
    DASHBOARD_PLIST="$PLIST_DIR/com.shipwright.dashboard.plist"
    CONNECT_PLIST="$PLIST_DIR/com.shipwright.connect.plist"
    LOG_DIR="$HOME/.shipwright/logs"
elif [[ "$OS_TYPE" == "linux" ]]; then
    SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
    DAEMON_SERVICE="$SYSTEMD_USER_DIR/shipwright-daemon.service"
    DASHBOARD_SERVICE="$SYSTEMD_USER_DIR/shipwright-dashboard.service"
    CONNECT_SERVICE="$SYSTEMD_USER_DIR/shipwright-connect.service"
    LOG_DIR="$HOME/.shipwright/logs"
fi

TEAM_CONFIG="$HOME/.shipwright/team-config.json"

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright Supervisor${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright launchd <command>"
    echo ""
    echo -e "  ${BOLD}PLATFORM${RESET}: $OS_TYPE"
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo -e "    ${CYAN}install${RESET}      Install services for daemon and dashboard (auto-start on boot)"
    echo -e "    ${CYAN}uninstall${RESET}    Remove services and stop running daemons"
    echo -e "    ${CYAN}status${RESET}       Check status of services"
    echo -e "    ${CYAN}logs${RESET}         Tail service logs (systemd only)"
    echo -e "    ${CYAN}help${RESET}         Show this help message"
    echo ""
    echo -e "  ${BOLD}EXAMPLES${RESET}"
    echo -e "    ${DIM}shipwright launchd install${RESET}   # Set up auto-start on boot"
    echo -e "    ${DIM}shipwright launchd status${RESET}    # Check if services are running"
    echo -e "    ${DIM}shipwright launchd logs${RESET}      # View service logs"
    echo -e "    ${DIM}shipwright launchd uninstall${RESET} # Remove auto-start"
    echo ""
}

# ─── Systemd Unit File Generator (Linux) ──────────────────────────────────
create_systemd_unit() {
    local unit_name="$1"
    local description="$2"
    local exec_start="$3"
    local output_file="$4"

    mkdir -p "$(dirname "$output_file")"

    cat > "$output_file" <<EOF
[Unit]
Description=${description}
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exec_start}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${unit_name}
Environment="PATH=/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:\$HOME/.local/bin"
Environment="HOME=\$HOME"

[Install]
WantedBy=default.target
EOF

    chmod 644 "$output_file"
}

# ─── Install Command ─────────────────────────────────────────────────────────
cmd_install() {
    if [[ "$OS_TYPE" == "unknown" ]]; then
        error "Unsupported OS type: $OSTYPE"
        exit 1
    fi

    if [[ "$OS_TYPE" == "macos" ]]; then
        cmd_install_macos
    else
        cmd_install_linux
    fi
}

# ─── Install macOS launchd agents ──────────────────────────────────────────
cmd_install_macos() {
    info "Installing launchd agents..."

    # Create directories
    mkdir -p "$PLIST_DIR" "$LOG_DIR"

    # Find the full path to the sw CLI
    local sw_bin
    if [[ -x "$SCRIPT_DIR/sw" ]]; then
        sw_bin="$SCRIPT_DIR/sw"
    else
        # Try to find it via PATH
        sw_bin=$(command -v sw 2>/dev/null || echo "")
        if [[ -z "$sw_bin" ]]; then
            error "Could not find 'sw' binary — make sure Shipwright is installed"
            exit 1
        fi
    fi

    # Resolve symlinks in case sw is symlinked
    sw_bin=$(cd "$(dirname "$sw_bin")" && pwd)/$(basename "$sw_bin")

    # ─── Create Daemon Plist ───────────────────────────────────────────────────
    cat > "$DAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.shipwright.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>${sw_bin}</string>
        <string>daemon</string>
        <string>start</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_DIR}</string>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/daemon.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/daemon.stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>\$HOME</string>
    </dict>
</dict>
</plist>
EOF

    chmod 644 "$DAEMON_PLIST"
    success "Created daemon plist: ${DAEMON_PLIST}"

    # ─── Create Dashboard Plist ────────────────────────────────────────────────
    # Get full path to bun and server.ts
    local bun_bin
    bun_bin=$(command -v bun 2>/dev/null || echo "bun")

    local server_file="$REPO_DIR/dashboard/server.ts"
    if [[ ! -f "$server_file" ]]; then
        warn "server.ts not found at $server_file — dashboard plist will reference a missing file"
    fi

    cat > "$DASHBOARD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.shipwright.dashboard</string>
    <key>ProgramArguments</key>
    <array>
        <string>${bun_bin}</string>
        <string>run</string>
        <string>${server_file}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_DIR}/dashboard</string>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/dashboard.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/dashboard.stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>\$HOME</string>
    </dict>
</dict>
</plist>
EOF

    chmod 644 "$DASHBOARD_PLIST"
    success "Created dashboard plist: ${DASHBOARD_PLIST}"

    # ─── Create Connect Plist (only if team-config.json exists) ────────────────
    if [[ -f "$TEAM_CONFIG" ]]; then
        cat > "$CONNECT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.shipwright.connect</string>
    <key>ProgramArguments</key>
    <array>
        <string>${sw_bin}</string>
        <string>connect</string>
        <string>start</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_DIR}</string>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/connect.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/connect.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>\$HOME</string>
    </dict>
</dict>
</plist>
EOF

        chmod 644 "$CONNECT_PLIST"
        success "Created connect plist: ${CONNECT_PLIST}"
    else
        info "Skipping connect plist — ${TEAM_CONFIG} not found"
    fi

    # ─── Load Services ─────────────────────────────────────────────────────────
    info "Loading launchd services..."

    if launchctl load "$DAEMON_PLIST" 2>/dev/null; then
        success "Loaded daemon service"
    else
        warn "Could not load daemon service — it may already be loaded"
    fi

    if launchctl load "$DASHBOARD_PLIST" 2>/dev/null; then
        success "Loaded dashboard service"
    else
        warn "Could not load dashboard service — it may already be loaded"
    fi

    if [[ -f "$CONNECT_PLIST" ]]; then
        if launchctl load "$CONNECT_PLIST" 2>/dev/null; then
            success "Loaded connect service"
        else
            warn "Could not load connect service — it may already be loaded"
        fi
    fi

    echo ""
    info "Services will auto-start on next login"
    info "View logs: ${DIM}tail -f ${LOG_DIR}/*.log${RESET}"
    info "Uninstall: ${DIM}shipwright launchd uninstall${RESET}"
}

# ─── Install Linux systemd user services ───────────────────────────────────
cmd_install_linux() {
    info "Installing systemd user services..."

    # Create directories
    mkdir -p "$SYSTEMD_USER_DIR" "$LOG_DIR"

    # Find the full path to the sw CLI
    local sw_bin
    if [[ -x "$SCRIPT_DIR/sw" ]]; then
        sw_bin="$SCRIPT_DIR/sw"
    else
        # Try to find it via PATH
        sw_bin=$(command -v sw 2>/dev/null || echo "")
        if [[ -z "$sw_bin" ]]; then
            error "Could not find 'sw' binary — make sure Shipwright is installed"
            exit 1
        fi
    fi

    # Resolve symlinks in case sw is symlinked
    sw_bin=$(cd "$(dirname "$sw_bin")" && pwd)/$(basename "$sw_bin")

    # ─── Create Daemon Service ─────────────────────────────────────────────────
    create_systemd_unit "shipwright-daemon" \
        "Shipwright Daemon - Autonomous Issue Processor" \
        "env -u CLAUDECODE ${sw_bin} daemon start --detach" \
        "$DAEMON_SERVICE"

    success "Created daemon service: ${DAEMON_SERVICE}"

    # ─── Create Dashboard Service ──────────────────────────────────────────────
    local bun_bin
    bun_bin=$(command -v bun 2>/dev/null || echo "bun")

    local server_file="$REPO_DIR/dashboard/server.ts"
    if [[ ! -f "$server_file" ]]; then
        warn "server.ts not found at $server_file — dashboard service will reference a missing file"
    fi

    create_systemd_unit "shipwright-dashboard" \
        "Shipwright Dashboard - Real-time Team Status" \
        "${bun_bin} run ${server_file}" \
        "$DASHBOARD_SERVICE"

    success "Created dashboard service: ${DASHBOARD_SERVICE}"

    # ─── Create Connect Service (only if team-config.json exists) ──────────────
    if [[ -f "$TEAM_CONFIG" ]]; then
        create_systemd_unit "shipwright-connect" \
            "Shipwright Connect - Team Sync Service" \
            "env -u CLAUDECODE ${sw_bin} connect start" \
            "$CONNECT_SERVICE"

        success "Created connect service: ${CONNECT_SERVICE}"
    else
        info "Skipping connect service — ${TEAM_CONFIG} not found"
    fi

    # ─── Enable and Start Services ─────────────────────────────────────────────
    info "Enabling systemd user services..."

    if systemctl --user enable shipwright-daemon.service 2>/dev/null; then
        success "Enabled daemon service"
    else
        warn "Could not enable daemon service"
    fi

    if systemctl --user enable shipwright-dashboard.service 2>/dev/null; then
        success "Enabled dashboard service"
    else
        warn "Could not enable dashboard service"
    fi

    if [[ -f "$CONNECT_SERVICE" ]]; then
        if systemctl --user enable shipwright-connect.service 2>/dev/null; then
            success "Enabled connect service"
        else
            warn "Could not enable connect service"
        fi
    fi

    # Start services immediately
    info "Starting systemd user services..."

    if systemctl --user start shipwright-daemon.service 2>/dev/null; then
        success "Started daemon service"
    else
        warn "Could not start daemon service — enable user lingering first: loginctl enable-linger"
    fi

    if systemctl --user start shipwright-dashboard.service 2>/dev/null; then
        success "Started dashboard service"
    else
        warn "Could not start dashboard service"
    fi

    if [[ -f "$CONNECT_SERVICE" ]]; then
        if systemctl --user start shipwright-connect.service 2>/dev/null; then
            success "Started connect service"
        else
            warn "Could not start connect service"
        fi
    fi

    echo ""
    info "Services will auto-start on next login (with systemd lingering enabled)"
    info "Enable lingering: ${DIM}loginctl enable-linger${RESET}"
    info "View logs: ${DIM}journalctl --user -u shipwright-daemon -f${RESET}"
    info "View all logs: ${DIM}journalctl --user -u shipwright-* -f${RESET}"
    info "Uninstall: ${DIM}shipwright launchd uninstall${RESET}"
}

# ─── Uninstall Command ──────────────────────────────────────────────────────
cmd_uninstall() {
    if [[ "$OS_TYPE" == "unknown" ]]; then
        error "Unsupported OS type: $OSTYPE"
        exit 1
    fi

    if [[ "$OS_TYPE" == "macos" ]]; then
        cmd_uninstall_macos
    else
        cmd_uninstall_linux
    fi
}

# ─── Uninstall macOS launchd agents ────────────────────────────────────────
cmd_uninstall_macos() {
    info "Uninstalling launchd agents..."

    # Unload daemon
    if [[ -f "$DAEMON_PLIST" ]]; then
        if launchctl unload "$DAEMON_PLIST" 2>/dev/null; then
            success "Unloaded daemon service"
        else
            warn "Could not unload daemon service — it may not be loaded"
        fi
        rm -f "$DAEMON_PLIST"
        success "Removed daemon plist"
    fi

    # Unload dashboard
    if [[ -f "$DASHBOARD_PLIST" ]]; then
        if launchctl unload "$DASHBOARD_PLIST" 2>/dev/null; then
            success "Unloaded dashboard service"
        else
            warn "Could not unload dashboard service — it may not be loaded"
        fi
        rm -f "$DASHBOARD_PLIST"
        success "Removed dashboard plist"
    fi

    # Unload connect
    if [[ -f "$CONNECT_PLIST" ]]; then
        if launchctl unload "$CONNECT_PLIST" 2>/dev/null; then
            success "Unloaded connect service"
        else
            warn "Could not unload connect service — it may not be loaded"
        fi
        rm -f "$CONNECT_PLIST"
        success "Removed connect plist"
    fi

    echo ""
    success "Uninstalled all launchd agents"
}

# ─── Uninstall Linux systemd user services ────────────────────────────────
cmd_uninstall_linux() {
    info "Uninstalling systemd user services..."

    # Stop and disable daemon
    if systemctl --user is-active --quiet shipwright-daemon.service 2>/dev/null; then
        if systemctl --user stop shipwright-daemon.service 2>/dev/null; then
            success "Stopped daemon service"
        else
            warn "Could not stop daemon service"
        fi
    fi

    if systemctl --user is-enabled --quiet shipwright-daemon.service 2>/dev/null; then
        if systemctl --user disable shipwright-daemon.service 2>/dev/null; then
            success "Disabled daemon service"
        else
            warn "Could not disable daemon service"
        fi
    fi

    # Stop and disable dashboard
    if systemctl --user is-active --quiet shipwright-dashboard.service 2>/dev/null; then
        if systemctl --user stop shipwright-dashboard.service 2>/dev/null; then
            success "Stopped dashboard service"
        else
            warn "Could not stop dashboard service"
        fi
    fi

    if systemctl --user is-enabled --quiet shipwright-dashboard.service 2>/dev/null; then
        if systemctl --user disable shipwright-dashboard.service 2>/dev/null; then
            success "Disabled dashboard service"
        else
            warn "Could not disable dashboard service"
        fi
    fi

    # Stop and disable connect
    if systemctl --user is-active --quiet shipwright-connect.service 2>/dev/null; then
        if systemctl --user stop shipwright-connect.service 2>/dev/null; then
            success "Stopped connect service"
        else
            warn "Could not stop connect service"
        fi
    fi

    if systemctl --user is-enabled --quiet shipwright-connect.service 2>/dev/null; then
        if systemctl --user disable shipwright-connect.service 2>/dev/null; then
            success "Disabled connect service"
        else
            warn "Could not disable connect service"
        fi
    fi

    # Remove service files
    [[ -f "$DAEMON_SERVICE" ]] && rm -f "$DAEMON_SERVICE" && success "Removed daemon service file"
    [[ -f "$DASHBOARD_SERVICE" ]] && rm -f "$DASHBOARD_SERVICE" && success "Removed dashboard service file"
    [[ -f "$CONNECT_SERVICE" ]] && rm -f "$CONNECT_SERVICE" && success "Removed connect service file"

    # Reload systemd daemon
    if systemctl --user daemon-reload 2>/dev/null; then
        success "Reloaded systemd user daemon"
    fi

    echo ""
    success "Uninstalled all systemd user services"
}

# ─── Status Command ─────────────────────────────────────────────────────────
cmd_status() {
    if [[ "$OS_TYPE" == "unknown" ]]; then
        error "Unsupported OS type: $OSTYPE"
        exit 1
    fi

    if [[ "$OS_TYPE" == "macos" ]]; then
        cmd_status_macos
    else
        cmd_status_linux
    fi
}

# ─── Status macOS launchd services ─────────────────────────────────────────
cmd_status_macos() {
    echo ""
    echo -e "${CYAN}${BOLD}Launchd Services${RESET}"
    echo -e "${DIM}════════════════════════════════════════════${RESET}"
    echo ""

    # Check daemon
    if launchctl list 2>/dev/null | grep -q "com.shipwright.daemon"; then
        echo -e "  ${GREEN}●${RESET} Daemon service is ${GREEN}loaded${RESET}"
    else
        echo -e "  ${RED}○${RESET} Daemon service is ${RED}not loaded${RESET}"
    fi

    # Check dashboard
    if launchctl list 2>/dev/null | grep -q "com.shipwright.dashboard"; then
        echo -e "  ${GREEN}●${RESET} Dashboard service is ${GREEN}loaded${RESET}"
    else
        echo -e "  ${RED}○${RESET} Dashboard service is ${RED}not loaded${RESET}"
    fi

    # Check connect
    if launchctl list 2>/dev/null | grep -q "com.shipwright.connect"; then
        echo -e "  ${GREEN}●${RESET} Connect service is ${GREEN}loaded${RESET}"
    else
        echo -e "  ${RED}○${RESET} Connect service is ${RED}not loaded${RESET}"
    fi

    echo ""
    echo -e "  Logs: ${DIM}${LOG_DIR}${RESET}"
    echo ""

    # Show recent log entries
    if [[ -f "$LOG_DIR/daemon.stdout.log" ]]; then
        echo -e "${DIM}Recent daemon logs:${RESET}"
        tail -3 "$LOG_DIR/daemon.stdout.log" 2>/dev/null | sed 's/^/    /'
        echo ""
    fi
}

# ─── Status Linux systemd services ────────────────────────────────────────
cmd_status_linux() {
    echo ""
    echo -e "${CYAN}${BOLD}Systemd User Services${RESET}"
    echo -e "${DIM}════════════════════════════════════════════${RESET}"
    echo ""

    # Check daemon
    if systemctl --user is-active --quiet shipwright-daemon.service 2>/dev/null; then
        echo -e "  ${GREEN}●${RESET} Daemon service is ${GREEN}running${RESET}"
    else
        echo -e "  ${RED}○${RESET} Daemon service is ${RED}not running${RESET}"
    fi

    # Check dashboard
    if systemctl --user is-active --quiet shipwright-dashboard.service 2>/dev/null; then
        echo -e "  ${GREEN}●${RESET} Dashboard service is ${GREEN}running${RESET}"
    else
        echo -e "  ${RED}○${RESET} Dashboard service is ${RED}not running${RESET}"
    fi

    # Check connect
    if systemctl --user is-active --quiet shipwright-connect.service 2>/dev/null; then
        echo -e "  ${GREEN}●${RESET} Connect service is ${GREEN}running${RESET}"
    else
        echo -e "  ${RED}○${RESET} Connect service is ${RED}not running${RESET}"
    fi

    echo ""
    echo -e "  Services: ${DIM}${SYSTEMD_USER_DIR}${RESET}"
    echo -e "  Logs: ${DIM}journalctl --user${RESET}"
    echo ""

    # Show recent journal entries for daemon
    if command -v journalctl &>/dev/null; then
        echo -e "${DIM}Recent daemon logs:${RESET}"
        journalctl --user -u shipwright-daemon.service -n 3 --no-pager 2>/dev/null | tail -3 | sed 's/^/    /' || true
        echo ""
    fi
}

# ─── Logs Command (systemd only) ────────────────────────────────────────────
cmd_logs() {
    if [[ "$OS_TYPE" != "linux" ]]; then
        error "logs command is only available on Linux (systemd)"
        exit 1
    fi

    local service="${1:-shipwright-daemon.service}"

    if ! systemctl --user is-active --quiet "$service" 2>/dev/null; then
        warn "Service $service is not running"
    fi

    echo ""
    info "Tailing logs for $service (Ctrl-C to stop)..."
    echo ""

    journalctl --user -u "$service" -f --no-pager
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"

    case "$cmd" in
        install)
            cmd_install
            ;;
        uninstall)
            cmd_uninstall
            ;;
        status)
            cmd_status
            ;;
        logs)
            cmd_logs "${2:-}"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
