#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright launchd — Process supervision on macOS                        ║
# ║  Auto-start daemon + dashboard on boot via launchd                       ║
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

# ─── Constants ──────────────────────────────────────────────────────────────
PLIST_DIR="$HOME/Library/LaunchAgents"
DAEMON_PLIST="$PLIST_DIR/com.shipwright.daemon.plist"
DASHBOARD_PLIST="$PLIST_DIR/com.shipwright.dashboard.plist"
CONNECT_PLIST="$PLIST_DIR/com.shipwright.connect.plist"
LOG_DIR="$HOME/.shipwright/logs"
TEAM_CONFIG="$HOME/.shipwright/team-config.json"

# ─── Check macOS ─────────────────────────────────────────────────────────────
check_macos() {
    if [[ "$OSTYPE" != "darwin"* ]]; then
        error "launchd is only available on macOS"
        exit 1
    fi
}

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright launchd${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright launchd <command>"
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo -e "    ${CYAN}install${RESET}      Install launchd agents for daemon and dashboard (auto-start on boot)"
    echo -e "    ${CYAN}uninstall${RESET}    Remove launchd agents and stop services"
    echo -e "    ${CYAN}status${RESET}       Check status of launchd services"
    echo -e "    ${CYAN}help${RESET}         Show this help message"
    echo ""
    echo -e "  ${BOLD}EXAMPLES${RESET}"
    echo -e "    ${DIM}shipwright launchd install${RESET}   # Set up auto-start on boot"
    echo -e "    ${DIM}shipwright launchd status${RESET}    # Check if services are running"
    echo -e "    ${DIM}shipwright launchd uninstall${RESET} # Remove auto-start"
    echo ""
}

# ─── Install Command ─────────────────────────────────────────────────────────
cmd_install() {
    check_macos

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
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
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
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
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
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
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

# ─── Uninstall Command ──────────────────────────────────────────────────────
cmd_uninstall() {
    check_macos

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

# ─── Status Command ─────────────────────────────────────────────────────────
cmd_status() {
    check_macos

    echo ""
    echo -e "${CYAN}${BOLD}Launchd Services${RESET}"
    echo -e "${DIM}════════════════════════════════════════════${RESET}"
    echo ""

    # Check daemon
    if launchctl list | grep -q "com.shipwright.daemon" 2>/dev/null; then
        echo -e "  ${GREEN}●${RESET} Daemon service is ${GREEN}loaded${RESET}"
    else
        echo -e "  ${RED}○${RESET} Daemon service is ${RED}not loaded${RESET}"
    fi

    # Check dashboard
    if launchctl list | grep -q "com.shipwright.dashboard" 2>/dev/null; then
        echo -e "  ${GREEN}●${RESET} Dashboard service is ${GREEN}loaded${RESET}"
    else
        echo -e "  ${RED}○${RESET} Dashboard service is ${RED}not loaded${RESET}"
    fi

    # Check connect
    if launchctl list | grep -q "com.shipwright.connect" 2>/dev/null; then
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
        tail -3 "$LOG_DIR/daemon.stdout.log" | sed 's/^/    /'
        echo ""
    fi
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

main "$@"
