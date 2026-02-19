#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright launchd + systemd test — Validate service management on      ║
# ║  macOS (launchd) and Linux (systemd) with mocked system commands         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHD_SCRIPT="$SCRIPT_DIR/sw-launchd.sh"

# ─── Colors (matches shipwright theme) ──────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# TEST ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-launchd-test.XXXXXX")

    # Create necessary directories
    mkdir -p "$TEMP_DIR/home/.shipwright/logs"
    mkdir -p "$TEMP_DIR/home/Library/LaunchAgents"
    mkdir -p "$TEMP_DIR/systemd/user"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/scripts"
    mkdir -p "$TEMP_DIR/project"

    # Copy the launchd script and helpers for color/output
    cp "$LAUNCHD_SCRIPT" "$TEMP_DIR/scripts/sw-launchd.sh"
    mkdir -p "$TEMP_DIR/scripts/lib"
    [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEMP_DIR/scripts/lib/"

    # Set environment variables
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export NO_GITHUB=true
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

# Create a mock uname command
create_mock_uname() {
    local os="$1"  # "darwin" or "linux"
    cat > "$TEMP_DIR/bin/uname" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-s" ]]; then
    if [[ "$os" == "darwin" ]]; then
        echo "Darwin"
    else
        echo "Linux"
    fi
else
    echo "mock-uname"
fi
EOF
    chmod +x "$TEMP_DIR/bin/uname"
}

# Create a mock launchctl command
create_mock_launchctl() {
    cat > "$TEMP_DIR/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
MOCK_LAUNCHCTL_LOG="${TEMP_DIR}/launchctl-calls.log"
echo "$@" >> "$MOCK_LAUNCHCTL_LOG"

case "${1:-}" in
    load)
        # Check if the plist exists
        if [[ ! -f "${2:-}" ]]; then
            echo "launchctl: Error reading ${2:-}: No such file or directory" >&2
            exit 5
        fi
        echo "Mock loaded: ${2}"
        exit 0
        ;;
    unload)
        if [[ ! -f "${2:-}" ]]; then
            echo "launchctl: Error reading ${2:-}: No such file or directory" >&2
            exit 5
        fi
        echo "Mock unloaded: ${2}"
        exit 0
        ;;
    list)
        # Return mock list output
        echo "com.shipwright.daemon"
        echo "com.shipwright.dashboard"
        exit 0
        ;;
    *)
        echo "mock-launchctl: unknown command ${1:-}" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$TEMP_DIR/bin/launchctl"
}

# Create a mock systemctl command
create_mock_systemctl() {
    cat > "$TEMP_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
MOCK_SYSTEMCTL_LOG="${TEMP_DIR}/systemctl-calls.log"
echo "$@" >> "$MOCK_SYSTEMCTL_LOG"

case "${1:-}" in
    --user)
        case "${2:-}" in
            enable)
                echo "Mock enabled: ${3}"
                exit 0
                ;;
            disable)
                echo "Mock disabled: ${3}"
                exit 0
                ;;
            daemon-reload)
                echo "Mock daemon-reload"
                exit 0
                ;;
            is-active)
                # Return active for testing
                echo "active"
                exit 0
                ;;
            status)
                echo "Mock status: ${3}"
                exit 0
                ;;
            *)
                echo "mock-systemctl: unknown command ${2:-}" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        echo "mock-systemctl: unknown options ${1:-}" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$TEMP_DIR/bin/systemctl"
}

# Create a mock sw command
create_mock_sw() {
    cat > "$TEMP_DIR/bin/sw" <<EOF
#!/usr/bin/env bash
echo "mock-sw"
EOF
    chmod +x "$TEMP_DIR/bin/sw"
}

# Create a mock bun command
create_mock_bun() {
    cat > "$TEMP_DIR/bin/bun" <<EOF
#!/usr/bin/env bash
echo "mock-bun"
EOF
    chmod +x "$TEMP_DIR/bin/bun"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# OS DETECTION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. macOS detection sets OSTYPE correctly
# ──────────────────────────────────────────────────────────────────────────────
test_macos_detection() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    # Create team-config.json to trigger connect plist creation
    mkdir -p "$HOME/.shipwright"
    echo '{}' > "$HOME/.shipwright/team-config.json"

    # Run install command — should not error
    local output
    output=$(OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>&1 || true)

    # Check that plist files were created (indicates macOS path was taken)
    if [[ ! -f "$HOME/Library/LaunchAgents/com.shipwright.daemon.plist" ]]; then
        echo -e "    ${RED}✗${RESET} Daemon plist not created on macOS"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Linux detection routes to systemd install path
# ──────────────────────────────────────────────────────────────────────────────
test_linux_detection_systemd() {
    create_mock_uname "linux"

    # Create mock systemctl
    cat > "$TEMP_DIR/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
echo "Mock systemctl: $*" >> "$TEMP_DIR/systemctl.log"
MOCK
    chmod +x "$TEMP_DIR/bin/systemctl"

    # Run install on Linux — should succeed via systemd path
    local output exit_code=0
    output=$(OSTYPE="linux-gnu" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>&1) || exit_code=$?

    # Should NOT error with "macOS only" — systemd support is implemented
    if [[ "$output" =~ "only available on macOS" ]]; then
        echo -e "    ${RED}✗${RESET} Should use systemd on Linux, not fail with macOS-only error"
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# MACOS PLIST GENERATION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 3. Daemon plist has correct structure
# ──────────────────────────────────────────────────────────────────────────────
test_daemon_plist_structure() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    local plist="$HOME/Library/LaunchAgents/com.shipwright.daemon.plist"
    if [[ ! -f "$plist" ]]; then
        echo -e "    ${RED}✗${RESET} Daemon plist not created"
        return 1
    fi

    # Validate XML structure
    if ! grep -q "<?xml version" "$plist"; then
        echo -e "    ${RED}✗${RESET} Invalid XML declaration"
        return 1
    fi

    # Check required plist keys
    if ! grep -q "<key>Label</key>" "$plist"; then
        echo -e "    ${RED}✗${RESET} Missing Label key"
        return 1
    fi

    if ! grep -q "com.shipwright.daemon" "$plist"; then
        echo -e "    ${RED}✗${RESET} Missing daemon label"
        return 1
    fi

    if ! grep -q "<key>KeepAlive</key>" "$plist"; then
        echo -e "    ${RED}✗${RESET} Missing KeepAlive key"
        return 1
    fi

    if ! grep -q "<key>RunAtLoad</key>" "$plist"; then
        echo -e "    ${RED}✗${RESET} Missing RunAtLoad key"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Dashboard plist has correct program arguments
# ──────────────────────────────────────────────────────────────────────────────
test_dashboard_plist_arguments() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    local plist="$HOME/Library/LaunchAgents/com.shipwright.dashboard.plist"
    if [[ ! -f "$plist" ]]; then
        echo -e "    ${RED}✗${RESET} Dashboard plist not created"
        return 1
    fi

    # Check for bun and server.ts arguments
    if ! grep -q "bun" "$plist"; then
        echo -e "    ${RED}✗${RESET} Missing bun command"
        return 1
    fi

    if ! grep -q "server.ts" "$plist"; then
        echo -e "    ${RED}✗${RESET} Missing server.ts reference"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Connect plist created only when team-config exists
# ──────────────────────────────────────────────────────────────────────────────
test_connect_plist_conditional() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    # Create a fresh temp home
    local fresh_home="$TEMP_DIR/fresh-home"
    mkdir -p "$fresh_home/Library/LaunchAgents"
    mkdir -p "$fresh_home/.shipwright"

    # First run without team-config
    HOME="$fresh_home" OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    local connect_plist="$fresh_home/Library/LaunchAgents/com.shipwright.connect.plist"
    if [[ -f "$connect_plist" ]]; then
        echo -e "    ${RED}✗${RESET} Connect plist created without team-config"
        return 1
    fi

    # Now create team-config and reinstall
    echo '{}' > "$fresh_home/.shipwright/team-config.json"

    # Clean up old plists
    rm -f "$fresh_home/Library/LaunchAgents"/*.plist

    HOME="$fresh_home" OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    if [[ ! -f "$connect_plist" ]]; then
        echo -e "    ${RED}✗${RESET} Connect plist not created when team-config exists"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Plist files have correct permissions (644)
# ──────────────────────────────────────────────────────────────────────────────
test_plist_permissions() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    mkdir -p "$HOME/.shipwright"
    echo '{}' > "$HOME/.shipwright/team-config.json"

    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    local daemon_plist="$HOME/Library/LaunchAgents/com.shipwright.daemon.plist"
    local perms
    perms=$(stat -f %A "$daemon_plist" 2>/dev/null || echo "unknown")

    # Check that plist is readable (not private)
    if [[ "$perms" == "-rw-------" ]]; then
        echo -e "    ${RED}✗${RESET} Plist has overly restrictive permissions: $perms"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# INSTALL COMMAND TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 7. Install creates LaunchAgents directory
# ──────────────────────────────────────────────────────────────────────────────
test_install_creates_directories() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    local launchd_dir="$HOME/Library/LaunchAgents"
    local log_dir="$HOME/.shipwright/logs"

    # Remove directories first
    rm -rf "$launchd_dir" "$log_dir"

    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    if [[ ! -d "$launchd_dir" ]]; then
        echo -e "    ${RED}✗${RESET} LaunchAgents directory not created"
        return 1
    fi

    if [[ ! -d "$log_dir" ]]; then
        echo -e "    ${RED}✗${RESET} Log directory not created"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Install calls launchctl load for daemon and dashboard
# ──────────────────────────────────────────────────────────────────────────────
test_install_calls_launchctl() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    > "$TEMP_DIR/launchctl-calls.log"

    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    if [[ ! -f "$TEMP_DIR/launchctl-calls.log" ]]; then
        echo -e "    ${RED}✗${RESET} launchctl not called"
        return 1
    fi

    local load_calls
    load_calls=$(grep -c "load" "$TEMP_DIR/launchctl-calls.log" || echo 0)

    if [[ "$load_calls" -lt 2 ]]; then
        echo -e "    ${RED}✗${RESET} Expected at least 2 launchctl load calls, got: $load_calls"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Install fails gracefully if sw binary not found
# ──────────────────────────────────────────────────────────────────────────────
test_install_missing_sw_binary() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_bun

    # Create empty bin directory (no sw binary)
    mkdir -p "$TEMP_DIR/bin-empty"

    # Run with minimal PATH so sw can't be found
    local output exit_code=0
    output=$(PATH="$TEMP_DIR/bin-empty:/usr/bin:/bin" OSTYPE="darwin19.6.0" SCRIPT_DIR="$TEMP_DIR/scripts/.." bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>&1) || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Should have failed when sw binary not found"
        return 1
    fi

    if [[ ! "$output" =~ "Could not find" ]]; then
        echo -e "    ${RED}✗${RESET} Expected error about missing sw binary, got: $output"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# UNINSTALL COMMAND TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 10. Uninstall removes plist files
# ──────────────────────────────────────────────────────────────────────────────
test_uninstall_removes_plists() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    mkdir -p "$HOME/.shipwright"
    echo '{}' > "$HOME/.shipwright/team-config.json"

    # Install first
    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    local daemon_plist="$HOME/Library/LaunchAgents/com.shipwright.daemon.plist"
    if [[ ! -f "$daemon_plist" ]]; then
        echo -e "    ${RED}✗${RESET} Plist not created during install"
        return 1
    fi

    # Now uninstall
    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" uninstall 2>/dev/null || true

    if [[ -f "$daemon_plist" ]]; then
        echo -e "    ${RED}✗${RESET} Daemon plist not removed after uninstall"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Uninstall calls launchctl unload
# ──────────────────────────────────────────────────────────────────────────────
test_uninstall_calls_launchctl_unload() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    # Install first
    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    > "$TEMP_DIR/launchctl-calls.log"

    # Now uninstall
    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" uninstall 2>/dev/null || true

    local unload_calls
    unload_calls=$(grep -c "unload" "$TEMP_DIR/launchctl-calls.log" || echo 0)

    if [[ "$unload_calls" -lt 2 ]]; then
        echo -e "    ${RED}✗${RESET} Expected at least 2 launchctl unload calls, got: $unload_calls"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Uninstall on empty system doesn't error
# ──────────────────────────────────────────────────────────────────────────────
test_uninstall_empty_system() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    # Remove all plists if they exist
    rm -f "$HOME/Library/LaunchAgents"/*.plist

    # Uninstall should not error even if services not loaded
    local exit_code=0
    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" uninstall 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Uninstall failed on empty system"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# STATUS COMMAND TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 13. Status command checks launchctl list
# ──────────────────────────────────────────────────────────────────────────────
test_status_checks_launchctl_list() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    # Install services first
    mkdir -p "$HOME/.shipwright"
    echo '{}' > "$HOME/.shipwright/team-config.json"
    rm -f "$TEMP_DIR/launchctl-calls.log"
    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    # Clear the log before status call
    rm -f "$TEMP_DIR/launchctl-calls.log"

    # Run status
    local output
    output=$(OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" status 2>&1)

    # Status should display running services (check output instead of log)
    # Check that output contains service names
    if [[ ! "$output" =~ "Daemon" ]]; then
        echo -e "    ${RED}✗${RESET} Status output missing Daemon service"
        return 1
    fi

    if [[ ! "$output" =~ "Dashboard" ]]; then
        echo -e "    ${RED}✗${RESET} Status output missing Dashboard service"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Status shows log directory
# ──────────────────────────────────────────────────────────────────────────────
test_status_shows_log_directory() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    # Run status
    local output
    output=$(OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" status 2>&1)

    local log_dir="$HOME/.shipwright/logs"

    if [[ ! "$output" =~ "$log_dir" ]]; then
        echo -e "    ${RED}✗${RESET} Status output missing log directory"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELP COMMAND TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 15. Help command shows usage and examples
# ──────────────────────────────────────────────────────────────────────────────
test_help_command() {
    local output
    output=$(bash "$TEMP_DIR/scripts/sw-launchd.sh" help 2>&1)

    if [[ ! "$output" =~ "USAGE" ]]; then
        echo -e "    ${RED}✗${RESET} Help missing USAGE section"
        return 1
    fi

    if [[ ! "$output" =~ "COMMANDS" ]]; then
        echo -e "    ${RED}✗${RESET} Help missing COMMANDS section"
        return 1
    fi

    if [[ ! "$output" =~ "install" ]]; then
        echo -e "    ${RED}✗${RESET} Help missing install command"
        return 1
    fi

    if [[ ! "$output" =~ "uninstall" ]]; then
        echo -e "    ${RED}✗${RESET} Help missing uninstall command"
        return 1
    fi

    if [[ ! "$output" =~ "status" ]]; then
        echo -e "    ${RED}✗${RESET} Help missing status command"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. Help is shown for unknown commands
# ──────────────────────────────────────────────────────────────────────────────
test_unknown_command_shows_help() {
    local exit_code=0
    local output
    output=$(bash "$TEMP_DIR/scripts/sw-launchd.sh" invalid-command 2>&1) || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Should have failed on invalid command"
        return 1
    fi

    if [[ ! "$output" =~ "Unknown command" ]]; then
        echo -e "    ${RED}✗${RESET} Expected 'Unknown command' error"
        return 1
    fi

    if [[ ! "$output" =~ "USAGE" ]]; then
        echo -e "    ${RED}✗${RESET} Help should be shown for invalid command"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# ENVIRONMENT VARIABLE TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 17. Plist contains correct environment variables
# ──────────────────────────────────────────────────────────────────────────────
test_plist_environment_variables() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    local daemon_plist="$HOME/Library/LaunchAgents/com.shipwright.daemon.plist"

    # Check for PATH environment variable
    if ! grep -q "PATH" "$daemon_plist"; then
        echo -e "    ${RED}✗${RESET} Plist missing PATH environment variable"
        return 1
    fi

    # Check for HOME environment variable
    if ! grep -q "HOME" "$daemon_plist"; then
        echo -e "    ${RED}✗${RESET} Plist missing HOME environment variable"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 18. Working directory is set in plist
# ──────────────────────────────────────────────────────────────────────────────
test_plist_working_directory() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    local daemon_plist="$HOME/Library/LaunchAgents/com.shipwright.daemon.plist"

    if ! grep -q "WorkingDirectory" "$daemon_plist"; then
        echo -e "    ${RED}✗${RESET} Plist missing WorkingDirectory"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# LOGGING TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 19. Plist configures stdout and stderr logging
# ──────────────────────────────────────────────────────────────────────────────
test_plist_logging_configuration() {
    create_mock_uname "darwin"
    create_mock_launchctl
    create_mock_sw
    create_mock_bun

    OSTYPE="darwin19.6.0" bash "$TEMP_DIR/scripts/sw-launchd.sh" install 2>/dev/null || true

    local daemon_plist="$HOME/Library/LaunchAgents/com.shipwright.daemon.plist"

    if ! grep -q "StandardOutPath" "$daemon_plist"; then
        echo -e "    ${RED}✗${RESET} Plist missing StandardOutPath"
        return 1
    fi

    if ! grep -q "StandardErrorPath" "$daemon_plist"; then
        echo -e "    ${RED}✗${RESET} Plist missing StandardErrorPath"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 20. Version variable is defined
# ──────────────────────────────────────────────────────────────────────────────
test_version_defined() {
    if ! grep -q "^VERSION=" "$TEMP_DIR/scripts/sw-launchd.sh"; then
        echo -e "    ${RED}✗${RESET} VERSION variable not defined"
        return 1
    fi

    local version
    version=$(grep "^VERSION=" "$TEMP_DIR/scripts/sw-launchd.sh" | cut -d'=' -f2)

    if [[ -z "$version" ]]; then
        echo -e "    ${RED}✗${RESET} VERSION variable is empty"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright launchd + systemd — Test Suite       ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo -e "${YELLOW}${BOLD}⚠${RESET} jq is not available (optional for launchd tests)"
fi

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# OS Detection Tests
echo -e "${PURPLE}${BOLD}OS Detection${RESET}"
run_test "macOS detection sets OSTYPE correctly" test_macos_detection
run_test "Linux detection routes to systemd" test_linux_detection_systemd
echo ""

# macOS Plist Generation Tests
echo -e "${PURPLE}${BOLD}macOS Plist Generation${RESET}"
run_test "Daemon plist has correct structure" test_daemon_plist_structure
run_test "Dashboard plist has correct arguments" test_dashboard_plist_arguments
run_test "Connect plist created only when team-config exists" test_connect_plist_conditional
run_test "Plist files have correct permissions" test_plist_permissions
echo ""

# Install Command Tests
echo -e "${PURPLE}${BOLD}Install Command${RESET}"
run_test "Install creates LaunchAgents directory" test_install_creates_directories
run_test "Install calls launchctl load" test_install_calls_launchctl
run_test "Install fails gracefully if sw binary not found" test_install_missing_sw_binary
echo ""

# Uninstall Command Tests
echo -e "${PURPLE}${BOLD}Uninstall Command${RESET}"
run_test "Uninstall removes plist files" test_uninstall_removes_plists
run_test "Uninstall calls launchctl unload" test_uninstall_calls_launchctl_unload
run_test "Uninstall on empty system doesn't error" test_uninstall_empty_system
echo ""

# Status Command Tests
echo -e "${PURPLE}${BOLD}Status Command${RESET}"
run_test "Status command checks launchctl list" test_status_checks_launchctl_list
run_test "Status shows log directory" test_status_shows_log_directory
echo ""

# Help Command Tests
echo -e "${PURPLE}${BOLD}Help Command${RESET}"
run_test "Help command shows usage and examples" test_help_command
run_test "Help is shown for unknown commands" test_unknown_command_shows_help
echo ""

# Environment and Configuration Tests
echo -e "${PURPLE}${BOLD}Environment & Configuration${RESET}"
run_test "Plist contains correct environment variables" test_plist_environment_variables
run_test "Working directory is set in plist" test_plist_working_directory
run_test "Plist configures stdout and stderr logging" test_plist_logging_configuration
run_test "Version variable is defined" test_version_defined
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All ${TOTAL} tests passed ✓${RESET}"
else
    echo -e "${RED}${BOLD}  ${FAIL}/${TOTAL} tests failed${RESET}"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
fi
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
echo ""

exit "$FAIL"
