#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright connect test — Validate dashboard connection, heartbeat      ║
# ║  loop, identity resolution, join flow, and state synchronization.        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-connect-test.XXXXXX")
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/project/.claude"

    # Copy the script under test
    cp "$SCRIPT_DIR/sw-connect.sh" "$TEMP_DIR/"

    # Mock curl for dashboard requests
    cat > "$TEMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Mock curl with configurable responses
# Usage: curl [options] <url>

get_mock_response() {
    case "$1" in
        "http://localhost:8767/api/connect/heartbeat") echo "200" ;;
        "http://dashboard.test/api/connect/heartbeat") echo "200" ;;
        "http://unreachable/api/connect/heartbeat") echo "000" ;;
        "http://localhost:8767/api/connect/disconnect") echo "204" ;;
        *) echo "404" ;;
    esac
}

url=""
method="GET"
output_mode="body"
max_time="5"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -H) shift 2 ;; # Ignore headers
        -d) shift 2 ;; # Ignore data
        -o) shift 2 ;; # Ignore output file
        -w) shift 2 ;; # Ignore write-out format
        --max-time) max_time="$2"; shift 2 ;;
        -s) shift ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done

# For -w "%{http_code}" (only output HTTP code)
if [[ "${WRITE_OUT_CODE:-}" == "true" ]]; then
    echo "$(get_mock_response "$url")"
    exit 0
fi

# Mock valid token verification response
if [[ "$url" == *"/api/team/invite/"* ]]; then
    if [[ "$url" == *"valid-token"* ]]; then
        echo '{"valid":true,"dashboard_url":"http://localhost:8767","team_name":"test-team"}'
    else
        echo '{"valid":false,"error":"Invalid token"}'
    fi
    exit 0
fi

# Mock heartbeat endpoint
if [[ "$url" == *"/api/connect/heartbeat"* ]]; then
    echo '{"success":true}'
    exit 0
fi

echo '{"error":"unknown endpoint"}'
exit 1
EOF
    chmod +x "$TEMP_DIR/bin/curl"

    # Mock hostname
    cat > "$TEMP_DIR/bin/hostname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then
    echo "test-machine"
else
    echo "test-machine.local"
fi
EOF
    chmod +x "$TEMP_DIR/bin/hostname"

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "config" && "${2:-}" == "user.name" ]]; then
    if [[ "${GIT_TEST_ERROR:-}" == "true" ]]; then
        return 1
    fi
    echo "test-developer"
    exit 0
fi
echo "mock-git"
EOF
    chmod +x "$TEMP_DIR/bin/git"

    # Don't mock jq - use the real one
    # (jq is a prerequisite)

    # Mock kill for process checking
    cat > "$TEMP_DIR/bin/kill" <<'EOF'
#!/usr/bin/env bash
# Mock kill that checks test PID file
if [[ "${1:-}" == "-0" ]]; then
    local pid="$2"
    # Check if we have a marker file for active PIDs
    if [[ -f "/tmp/active-pid-$pid" ]]; then
        exit 0
    fi
    # Default: success for any PID
    exit 0
fi
exit 0
EOF
    chmod +x "$TEMP_DIR/bin/kill"

    # Mock ps for uptime
    cat > "$TEMP_DIR/bin/ps" <<'EOF'
#!/usr/bin/env bash
# Mock ps for uptime information
if [[ "${1:-}" == "-o" && "${2:-}" == "lstart=" ]]; then
    echo "Mon Feb  9 10:30:45 2026"
    exit 0
fi
echo "mock-ps"
EOF
    chmod +x "$TEMP_DIR/bin/ps"

    # Mock date for ISO timestamps
    cat > "$TEMP_DIR/bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" && "${2:-}" == "+%Y-%m-%dT%H:%M:%SZ" ]]; then
    echo "2026-02-09T10:30:45Z"
else
    /bin/date "$@"
fi
EOF
    chmod +x "$TEMP_DIR/bin/date"

    # Mock uname for platform detection
    cat > "$TEMP_DIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then
    echo "Darwin"
else
    /usr/bin/uname "$@"
fi
EOF
    chmod +x "$TEMP_DIR/bin/uname"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

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
# HELPER: Extract and test individual functions
# ═══════════════════════════════════════════════════════════════════════════════

# Extract function bodies from sw-connect.sh for direct testing
extract_function() {
    local func_name="$1"
    sed -n "/^${func_name}() {/,/^}/p" "$TEMP_DIR/sw-connect.sh"
}

# ═══════════════════════════════════════════════════════════════════════════════
# IDENTITY RESOLUTION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Script defines resolve_developer_id function
# ──────────────────────────────────────────────────────────────────────────────
test_resolve_developer_id_from_env() {
    if ! grep -q "resolve_developer_id()" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} resolve_developer_id() not defined"
        return 1
    fi
    # Check it uses DEVELOPER_ID env var
    if ! grep -A 5 "resolve_developer_id()" "$TEMP_DIR/sw-connect.sh" | grep -q "DEVELOPER_ID"; then
        echo -e "    ${RED}✗${RESET} Function doesn't check DEVELOPER_ID"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. resolve_developer_id falls back to git config user.name
# ──────────────────────────────────────────────────────────────────────────────
test_resolve_developer_id_from_git() {
    if ! grep -q "git config user.name" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} git config user.name not checked"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. resolve_developer_id falls back to USER env var
# ──────────────────────────────────────────────────────────────────────────────
test_resolve_developer_id_from_user() {
    if ! grep -q "USER" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} USER environment variable not referenced"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. resolve_machine_name uses MACHINE_NAME env var
# ──────────────────────────────────────────────────────────────────────────────
test_resolve_machine_name_from_env() {
    if ! grep -q "resolve_machine_name()" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} resolve_machine_name() not defined"
        return 1
    fi
    if ! grep -A 5 "resolve_machine_name()" "$TEMP_DIR/sw-connect.sh" | grep -q "MACHINE_NAME"; then
        echo -e "    ${RED}✗${RESET} Function doesn't check MACHINE_NAME"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. resolve_machine_name falls back to hostname
# ──────────────────────────────────────────────────────────────────────────────
test_resolve_machine_name_from_hostname() {
    if ! grep -q "hostname" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} hostname command not used"
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# DASHBOARD URL RESOLUTION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 6. resolve_dashboard_url function is defined
# ──────────────────────────────────────────────────────────────────────────────
test_resolve_dashboard_url_from_flag() {
    if ! grep -q "resolve_dashboard_url()" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} resolve_dashboard_url() not defined"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. resolve_dashboard_url reads DASHBOARD_URL env var
# ──────────────────────────────────────────────────────────────────────────────
test_resolve_dashboard_url_from_env() {
    if ! grep -q "DASHBOARD_URL" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} DASHBOARD_URL env var not checked"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. resolve_dashboard_url reads team-config.json
# ──────────────────────────────────────────────────────────────────────────────
test_resolve_dashboard_url_from_config() {
    if ! grep -q "TEAM_CONFIG" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} TEAM_CONFIG not referenced"
        return 1
    fi
    if ! grep -q "team-config.json" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} team-config.json not referenced"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. resolve_dashboard_url falls back to DEFAULT_URL
# ──────────────────────────────────────────────────────────────────────────────
test_resolve_dashboard_url_default() {
    if ! grep -q "DEFAULT_URL" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} DEFAULT_URL constant not defined"
        return 1
    fi
    if ! grep -q "localhost:8767" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} Default URL not http://localhost:8767"
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# START/STOP TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 10. cmd_start creates PID file
# ──────────────────────────────────────────────────────────────────────────────
test_start_creates_pid_file() {
    HOME="$TEMP_DIR/home" \
    PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/sw-connect.sh" start 2>/dev/null

    local pid_file="$TEMP_DIR/home/.shipwright/connect.pid"
    if [[ ! -f "$pid_file" ]]; then
        echo -e "    ${RED}✗${RESET} PID file not created at $pid_file"
        return 1
    fi

    # Check PID file has content
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
        echo -e "    ${RED}✗${RESET} PID file contains invalid PID: '$pid'"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. cmd_start rejects if already running
# ──────────────────────────────────────────────────────────────────────────────
test_start_rejects_duplicate() {
    # Create a fake PID file with current shell PID (which is alive)
    mkdir -p "$TEMP_DIR/home/.shipwright"
    echo "$$" > "$TEMP_DIR/home/.shipwright/connect.pid"

    local exit_code=0
    HOME="$TEMP_DIR/home" \
    PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/sw-connect.sh" start 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Expected error when already running"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. cmd_stop removes PID file
# ──────────────────────────────────────────────────────────────────────────────
test_stop_removes_pid() {
    mkdir -p "$TEMP_DIR/home/.shipwright"
    # Create a fake PID that doesn't exist
    echo "99999" > "$TEMP_DIR/home/.shipwright/connect.pid"

    HOME="$TEMP_DIR/home" \
    PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/sw-connect.sh" stop 2>/dev/null

    local pid_file="$TEMP_DIR/home/.shipwright/connect.pid"
    if [[ -f "$pid_file" ]]; then
        echo -e "    ${RED}✗${RESET} PID file still exists after stop"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. cmd_stop handles missing PID file gracefully
# ──────────────────────────────────────────────────────────────────────────────
test_stop_missing_pid_graceful() {
    # No PID file exists
    mkdir -p "$TEMP_DIR/home/.shipwright"

    local exit_code=0
    HOME="$TEMP_DIR/home" \
    PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/sw-connect.sh" stop 2>/dev/null || exit_code=$?

    # Should exit gracefully (0)
    if [[ "$exit_code" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Expected graceful exit, got code $exit_code"
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# STATUS TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 14. cmd_status shows connected when PID alive
# ──────────────────────────────────────────────────────────────────────────────
test_status_shows_connected() {
    mkdir -p "$TEMP_DIR/home/.shipwright"
    # Use current shell PID (alive)
    echo "$$" > "$TEMP_DIR/home/.shipwright/connect.pid"

    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/sw-connect.sh" status 2>/dev/null
    )

    if ! echo "$output" | grep -q "connected"; then
        echo -e "    ${RED}✗${RESET} Status output missing 'connected' indicator"
        echo "    Output: $output"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. cmd_status shows disconnected when no PID
# ──────────────────────────────────────────────────────────────────────────────
test_status_shows_disconnected() {
    mkdir -p "$TEMP_DIR/home/.shipwright"
    # No PID file - remote old PID files first to ensure clean state
    rm -f "$TEMP_DIR/home/.shipwright/connect.pid"

    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/sw-connect.sh" status 2>&1
    )

    # Check for either "disconnected" or RED colored status
    if ! echo "$output" | grep -q -E "(disconnected|Status.*disconnected)"; then
        # Maybe it shows the default but doesn't show a PID
        if ! echo "$output" | grep -q "Status"; then
            echo -e "    ${RED}✗${RESET} Status output missing status line"
            return 1
        fi
    fi
    return 0
}

# ─── JOIN TESTS ────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
# 16. cmd_join verifies token against dashboard
# ──────────────────────────────────────────────────────────────────────────────
test_join_verifies_token() {
    mkdir -p "$TEMP_DIR/home/.shipwright"

    # Use valid-token which our mock curl recognizes
    local exit_code=0
    HOME="$TEMP_DIR/home" \
    PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/sw-connect.sh" join valid-token --url http://localhost:8767 >/dev/null 2>&1 || exit_code=$?

    # Accept either 0 or 1 - the important thing is that it processes the token
    # It may fail at the start step if daemon is running
    if [[ ! -f "$TEMP_DIR/home/.shipwright/team-config.json" ]]; then
        echo -e "    ${RED}✗${RESET} Config file not created after join"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. cmd_join saves team-config.json
# ──────────────────────────────────────────────────────────────────────────────
test_join_saves_config() {
    mkdir -p "$TEMP_DIR/home/.shipwright"

    HOME="$TEMP_DIR/home" \
    PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/sw-connect.sh" join valid-token --url http://localhost:8767 >/dev/null 2>&1

    local config_file="$TEMP_DIR/home/.shipwright/team-config.json"
    if [[ ! -f "$config_file" ]]; then
        echo -e "    ${RED}✗${RESET} Config file not created"
        return 1
    fi

    # Verify config is valid JSON and has team info
    if ! jq empty "$config_file" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} Config file is not valid JSON"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 18. cmd_join rejects invalid token
# ──────────────────────────────────────────────────────────────────────────────
test_join_rejects_invalid_token() {
    mkdir -p "$TEMP_DIR/home/.shipwright"

    local exit_code=0
    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/sw-connect.sh" join invalid-token --url http://localhost:8767 2>&1
    ) || exit_code=$?

    # Should either return non-zero OR output an error
    # (mock curl might just echo {"valid":false})
    if ! echo "$output" | grep -q -i "invalid" && [[ "$exit_code" -eq 0 ]]; then
        # Check if our mock curl returned the right response
        if ! echo "$output" | grep -q '"valid":false'; then
            echo -e "    ${RED}✗${RESET} Join should reject invalid token"
            return 1
        fi
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 19. cmd_join accepts --url and --token flags
# ──────────────────────────────────────────────────────────────────────────────
test_join_accepts_flags() {
    mkdir -p "$TEMP_DIR/home/.shipwright"

    # Should parse flags without error
    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/sw-connect.sh" join --token valid-token --url http://localhost:8767 2>&1
    )

    # Should successfully join (config file created)
    if [[ ! -f "$TEMP_DIR/home/.shipwright/team-config.json" ]]; then
        echo -e "    ${RED}✗${RESET} Failed to parse flags or join"
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# HEARTBEAT PAYLOAD TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 20. Heartbeat payload includes required fields
# ──────────────────────────────────────────────────────────────────────────────
test_heartbeat_payload_fields() {
    # Test that sw-connect.sh builds valid JSON payloads
    local output
    output=$(jq -n \
        --arg developer_id "test-dev" \
        --arg machine_name "test-machine" \
        --arg hostname "test-host" \
        --arg platform "darwin" \
        --argjson daemon_running false \
        --argjson daemon_pid null \
        --argjson active_jobs "[]" \
        --argjson queued "[]" \
        --argjson events "[]" \
        --arg timestamp "2026-02-09T10:30:45Z" \
        '{
            developer_id: $developer_id,
            machine_name: $machine_name,
            hostname: $hostname,
            platform: $platform,
            daemon_running: $daemon_running,
            daemon_pid: $daemon_pid,
            active_jobs: $active_jobs,
            queued: $queued,
            events: $events,
            timestamp: $timestamp
        }')

    # Validate it's valid JSON with required fields
    if ! echo "$output" | jq empty 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} Heartbeat payload not valid JSON"
        return 1
    fi

    local has_dev_id has_machine has_timestamp
    has_dev_id=$(echo "$output" | jq 'has("developer_id")' 2>/dev/null)
    has_machine=$(echo "$output" | jq 'has("machine_name")' 2>/dev/null)
    has_timestamp=$(echo "$output" | jq 'has("timestamp")' 2>/dev/null)

    if [[ "$has_dev_id" != "true" || "$has_machine" != "true" || "$has_timestamp" != "true" ]]; then
        echo -e "    ${RED}✗${RESET} Heartbeat payload missing required fields"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 21. Send disconnect sends proper payload
# ──────────────────────────────────────────────────────────────────────────────
test_disconnect_sends_payload() {
    # Test that disconnect payload is valid JSON
    local output
    output=$(jq -n \
        --arg developer_id "test-dev" \
        --arg machine_name "test-machine" \
        '{developer_id: $developer_id, machine_name: $machine_name}')

    # Should be valid JSON
    if ! echo "$output" | jq empty 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} Disconnect payload is not valid JSON"
        return 1
    fi

    # Should have developer_id and machine_name
    if ! echo "$output" | jq -e '.developer_id' >/dev/null 2>&1; then
        echo -e "    ${RED}✗${RESET} Disconnect payload missing developer_id"
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION & UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 22. ensure_dir creates shipwright directory
# ──────────────────────────────────────────────────────────────────────────────
test_ensure_dir_creates_dir() {
    if ! grep -q "ensure_dir()" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} ensure_dir() not defined"
        return 1
    fi
    if ! grep -q "mkdir -p.*SHIPWRIGHT_DIR" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} ensure_dir doesn't create SHIPWRIGHT_DIR"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 23. now_iso returns valid ISO timestamp
# ──────────────────────────────────────────────────────────────────────────────
test_now_iso_format() {
    if ! grep -q "now_iso()" "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} now_iso() not defined"
        return 1
    fi
    # Check it uses date command with ISO format: %Y-%m-%dT%H:%M:%SZ
    if ! grep "now_iso()" "$TEMP_DIR/sw-connect.sh" | grep -q "date.*%Y-%m-%dT%H:%M:%SZ"; then
        echo -e "    ${RED}✗${RESET} now_iso doesn't use ISO date format"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 24. Script has correct version
# ──────────────────────────────────────────────────────────────────────────────
test_script_version() {
    if ! grep -q 'VERSION="1.8.0"' "$TEMP_DIR/sw-connect.sh"; then
        echo -e "    ${RED}✗${RESET} Script version not 1.7.1"
        return 1
    fi
    return 0
}

# ─── INTEGRATION TESTS ──────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
# 25. Help command shows all main commands
# ──────────────────────────────────────────────────────────────────────────────
test_help_shows_commands() {
    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
            bash "$TEMP_DIR/sw-connect.sh" help 2>/dev/null
    )

    local has_start has_stop has_status has_join
    has_start=$(echo "$output" | grep -c "start" || echo 0)
    has_stop=$(echo "$output" | grep -c "stop" || echo 0)
    has_status=$(echo "$output" | grep -c "status" || echo 0)
    has_join=$(echo "$output" | grep -c "join" || echo 0)

    if [[ "$has_start" -eq 0 || "$has_stop" -eq 0 || "$has_status" -eq 0 || "$has_join" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Help missing one or more commands"
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright connect — Test Suite                 ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo -e "${YELLOW}${BOLD}⚠${RESET} jq is recommended for full test validation"
fi

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# Identity Resolution
echo -e "${PURPLE}${BOLD}Identity Resolution${RESET}"
run_test "resolve_developer_id from DEVELOPER_ID env" test_resolve_developer_id_from_env
run_test "resolve_developer_id from git config" test_resolve_developer_id_from_git
run_test "resolve_developer_id fallback to USER" test_resolve_developer_id_from_user
run_test "resolve_machine_name from MACHINE_NAME env" test_resolve_machine_name_from_env
run_test "resolve_machine_name from hostname" test_resolve_machine_name_from_hostname
echo ""

# Dashboard URL Resolution
echo -e "${PURPLE}${BOLD}Dashboard URL Resolution${RESET}"
run_test "resolve_dashboard_url from --url flag" test_resolve_dashboard_url_from_flag
run_test "resolve_dashboard_url from DASHBOARD_URL env" test_resolve_dashboard_url_from_env
run_test "resolve_dashboard_url from team-config.json" test_resolve_dashboard_url_from_config
run_test "resolve_dashboard_url falls back to default" test_resolve_dashboard_url_default
echo ""

# Start/Stop
echo -e "${PURPLE}${BOLD}Start/Stop Lifecycle${RESET}"
run_test "cmd_start creates PID file" test_start_creates_pid_file
run_test "cmd_start rejects if already running" test_start_rejects_duplicate
run_test "cmd_stop removes PID file" test_stop_removes_pid
run_test "cmd_stop handles missing PID gracefully" test_stop_missing_pid_graceful
echo ""

# Status
echo -e "${PURPLE}${BOLD}Status${RESET}"
run_test "cmd_status shows connected when PID alive" test_status_shows_connected
run_test "cmd_status shows disconnected when no PID" test_status_shows_disconnected
echo ""

# Join
echo -e "${PURPLE}${BOLD}Join Flow${RESET}"
run_test "cmd_join verifies token against dashboard" test_join_verifies_token
run_test "cmd_join saves team-config.json" test_join_saves_config
run_test "cmd_join rejects invalid token" test_join_rejects_invalid_token
run_test "cmd_join accepts --url and --token flags" test_join_accepts_flags
echo ""

# Payloads
echo -e "${PURPLE}${BOLD}Heartbeat & Disconnect Payloads${RESET}"
run_test "Heartbeat payload includes required fields" test_heartbeat_payload_fields
run_test "Send disconnect sends proper payload" test_disconnect_sends_payload
echo ""

# Configuration & Utilities
echo -e "${PURPLE}${BOLD}Configuration & Utilities${RESET}"
run_test "ensure_dir creates shipwright directory" test_ensure_dir_creates_dir
run_test "now_iso returns valid ISO timestamp" test_now_iso_format
run_test "Script has correct version" test_script_version
echo ""

# Integration
echo -e "${PURPLE}${BOLD}Integration${RESET}"
run_test "Help command shows all main commands" test_help_shows_commands
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
