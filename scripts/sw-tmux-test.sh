#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tmux test — Validate tmux doctor, install, fix, reload,     ║
# ║  CLI routing, and Claude Code compatibility checks.                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-tmux-test.XXXXXX")

    # Create repo structure
    mkdir -p "$TEMP_DIR/scripts/lib"
    mkdir -p "$TEMP_DIR/tmux"
    mkdir -p "$TEMP_DIR/home/.tmux/plugins"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/mock-log"

    # Copy the tmux script under test and helpers for color/output
    cp "$SCRIPT_DIR/sw-tmux.sh" "$TEMP_DIR/scripts/"
    mkdir -p "$TEMP_DIR/scripts/lib"
    touch "$TEMP_DIR/scripts/lib/compat.sh"
    [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEMP_DIR/scripts/lib/"

    # Create fake tmux.conf and overlay for install tests
    echo "# fake tmux.conf" > "$TEMP_DIR/tmux/tmux.conf"
    echo "# fake overlay" > "$TEMP_DIR/tmux/shipwright-overlay.conf"

    # Create mock tmux binary with controllable responses
    # The mock reads MOCK_TMUX_* env vars for option values
    cat > "$TEMP_DIR/bin/tmux" <<'TMUXMOCK'
#!/usr/bin/env bash
LOGFILE="${MOCK_TMUX_LOG:-/dev/null}"
echo "tmux $*" >> "$LOGFILE"

case "$1" in
    -V)
        echo "tmux ${MOCK_TMUX_VERSION:-3.4}"
        ;;
    show-option)
        shift
        # Parse -gv <key>
        key=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -gv|-gqv) shift; key="$1" ;;
                -g) ;;
                *) key="$1" ;;
            esac
            shift
        done
        case "$key" in
            allow-passthrough)  echo "${MOCK_TMUX_PASSTHROUGH:-on}" ;;
            extended-keys)      echo "${MOCK_TMUX_EXTKEYS:-on}" ;;
            escape-time)        echo "${MOCK_TMUX_ESCAPE_TIME:-0}" ;;
            set-clipboard)      echo "${MOCK_TMUX_CLIPBOARD:-on}" ;;
            history-limit)      echo "${MOCK_TMUX_HISTORY:-250000}" ;;
            focus-events)       echo "${MOCK_TMUX_FOCUS:-on}" ;;
            default-terminal)   echo "${MOCK_TMUX_TERM:-tmux-256color}" ;;
            pane-border-status) echo "${MOCK_TMUX_BORDER:-top}" ;;
            mouse)              echo "${MOCK_TMUX_MOUSE:-on}" ;;
            *)                  echo "unknown" ;;
        esac
        ;;
    show-window-option)
        shift
        key=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -gv|-gqv) shift; key="$1" ;;
                -g) ;;
                *) key="$1" ;;
            esac
            shift
        done
        case "$key" in
            pane-base-index) echo "${MOCK_TMUX_PBI:-0}" ;;
            *)               echo "0" ;;
        esac
        ;;
    show-hooks)
        if [[ "${MOCK_TMUX_HOOKS:-yes}" == "yes" ]]; then
            echo "after-split-window[0] -> select-pane -P 'bg=#1a1a2e,fg=#e4e4e7'"
        fi
        ;;
    list-keys)
        if [[ "${MOCK_TMUX_MOUSEKEYS:-yes}" == "yes" ]]; then
            echo "bind-key -T root MouseDown1Status select-window -t ="
        fi
        ;;
    set|set-option)
        # no-op, just log
        ;;
    set-hook)
        # no-op, just log
        ;;
    bind)
        # no-op, just log
        ;;
    source-file)
        # no-op, just log
        ;;
    *)
        ;;
esac
exit 0
TMUXMOCK
    chmod +x "$TEMP_DIR/bin/tmux"

    # Create mock git binary (for TPM clone)
    cat > "$TEMP_DIR/bin/git" <<'GITMOCK'
#!/usr/bin/env bash
LOGFILE="${MOCK_GIT_LOG:-/dev/null}"
echo "git $*" >> "$LOGFILE"
if [[ "${1:-}" == "clone" ]]; then
    # Simulate creating the TPM directory ($2=url, $3=target)
    target="${3:-$2}"
    mkdir -p "$target"
    mkdir -p "$target/bin"
    echo "#!/usr/bin/env bash" > "$target/bin/install_plugins"
    echo "echo 'plugins installed'" >> "$target/bin/install_plugins"
    chmod +x "$target/bin/install_plugins"
    exit 0
fi
echo "mock-git"
GITMOCK
    chmod +x "$TEMP_DIR/bin/git"

    # Create mock gh
    cat > "$TEMP_DIR/bin/gh" <<'GHMOCK'
#!/usr/bin/env bash
exit 1
GHMOCK
    chmod +x "$TEMP_DIR/bin/gh"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# Helper to run sw-tmux.sh in mock environment with tmux session simulated
run_tmux() {
    local log_file="$TEMP_DIR/mock-log/tmux-calls.log"
    (
        cd "$TEMP_DIR"
        PATH="$TEMP_DIR/bin:$PATH" \
        HOME="$TEMP_DIR/home" \
        TMUX="/tmp/tmux-test/default,12345,0" \
        MOCK_TMUX_LOG="$log_file" \
        MOCK_GIT_LOG="$TEMP_DIR/mock-log/git-calls.log" \
        LC_TERMINAL="Ghostty" \
            bash "$TEMP_DIR/scripts/sw-tmux.sh" "$@"
    )
}

# Helper to run with custom env overrides (pass env vars as leading KEY=VALUE args)
run_tmux_env() {
    local log_file="$TEMP_DIR/mock-log/tmux-calls.log"
    local env_vars=()
    while [[ $# -gt 0 && "$1" == *=* ]]; do
        env_vars+=("$1")
        shift
    done
    (
        cd "$TEMP_DIR"
        export PATH="$TEMP_DIR/bin:$PATH"
        export HOME="$TEMP_DIR/home"
        export TMUX="/tmp/tmux-test/default,12345,0"
        export MOCK_TMUX_LOG="$log_file"
        export MOCK_GIT_LOG="$TEMP_DIR/mock-log/git-calls.log"
        export LC_TERMINAL="Ghostty"
        for ev in "${env_vars[@]}"; do
            export "$ev"
        done
        bash "$TEMP_DIR/scripts/sw-tmux.sh" "$@"
    )
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
        echo -e "${GREEN}PASS${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TMUX DOCTOR TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. tmux doctor runs without error
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_runs() {
    local exit_code=0
    run_tmux doctor >/dev/null 2>&1 || exit_code=$?

    # With all good defaults it should exit 0
    if [[ "$exit_code" -ne 0 ]]; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. tmux doctor outputs pass/warn/fail counts
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_output_counts() {
    local output
    output=$(run_tmux doctor 2>&1 || true)

    if ! echo "$output" | grep -q "passed"; then
        return 1
    fi
    if ! echo "$output" | grep -q "warnings"; then
        return 1
    fi
    if ! echo "$output" | grep -q "failed"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. With all correct options, doctor reports all PASS (no failures)
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_all_pass() {
    # Install fake overlay and TPM
    mkdir -p "$TEMP_DIR/home/.tmux/plugins/tpm"
    mkdir -p "$TEMP_DIR/home/.tmux/plugins/tmux-sensible"
    mkdir -p "$TEMP_DIR/home/.tmux/plugins/tmux-resurrect"
    mkdir -p "$TEMP_DIR/home/.tmux/plugins/tmux-continuum"
    mkdir -p "$TEMP_DIR/home/.tmux/plugins/tmux-yank"
    mkdir -p "$TEMP_DIR/home/.tmux/plugins/tmux-fzf"
    echo "source-file shipwright-overlay.conf" > "$TEMP_DIR/home/.tmux.conf"
    echo "# overlay" > "$TEMP_DIR/home/.tmux/shipwright-overlay.conf"

    local output
    output=$(run_tmux doctor 2>&1 || true)

    # Should have "0 failed"
    if ! echo "$output" | grep -q "0 failed"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. With bad escape-time, doctor reports a FAIL
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_bad_escape_time() {
    local output
    output=$(run_tmux_env "MOCK_TMUX_ESCAPE_TIME=500" doctor 2>&1 || true)

    # Should mention escape-time failure
    if ! echo "$output" | grep -q "escape-time.*500"; then
        return 1
    fi
    # Should NOT have "0 failed"
    if echo "$output" | grep -q "0 failed"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. With bad history-limit, doctor reports a FAIL
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_bad_history() {
    local output
    output=$(run_tmux_env "MOCK_TMUX_HISTORY=2000" doctor 2>&1 || true)

    if ! echo "$output" | grep -q "history-limit.*2000"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. With passthrough off, doctor reports a FAIL
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_passthrough_off() {
    local output
    output=$(run_tmux_env "MOCK_TMUX_PASSTHROUGH=off" doctor 2>&1 || true)

    if ! echo "$output" | grep -q "allow-passthrough.*off"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Doctor detects tmux version
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_version_check() {
    local output
    output=$(run_tmux_env "MOCK_TMUX_VERSION=3.4" doctor 2>&1 || true)

    if ! echo "$output" | grep -q "3.4"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Doctor detects terminal emulator
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_terminal_detect() {
    local output
    output=$(run_tmux doctor 2>&1 || true)

    if ! echo "$output" | grep -q "Ghostty"; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# TMUX INSTALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 9. tmux install creates TPM directory (via mock git clone)
# ──────────────────────────────────────────────────────────────────────────────
test_install_tpm() {
    # Ensure TPM not already there
    rm -rf "$TEMP_DIR/home/.tmux/plugins/tpm"

    local exit_code=0
    run_tmux install >/dev/null 2>&1 || exit_code=$?

    if [[ ! -d "$TEMP_DIR/home/.tmux/plugins/tpm" ]]; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. tmux install skips TPM if already present
# ──────────────────────────────────────────────────────────────────────────────
test_install_tpm_already_exists() {
    # Ensure TPM exists
    mkdir -p "$TEMP_DIR/home/.tmux/plugins/tpm"

    local output
    output=$(run_tmux install 2>&1 || true)

    if ! echo "$output" | grep -q "already installed"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. tmux install copies overlay file
# ──────────────────────────────────────────────────────────────────────────────
test_install_copies_overlay() {
    rm -f "$TEMP_DIR/home/.tmux/shipwright-overlay.conf"

    run_tmux install >/dev/null 2>&1 || true

    if [[ ! -f "$TEMP_DIR/home/.tmux/shipwright-overlay.conf" ]]; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# TMUX FIX TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 12. tmux fix applies fixes for bad options
# ──────────────────────────────────────────────────────────────────────────────
test_fix_applies_fixes() {
    > "$TEMP_DIR/mock-log/tmux-calls.log"

    local output
    output=$(run_tmux_env \
        "MOCK_TMUX_PASSTHROUGH=off" \
        "MOCK_TMUX_ESCAPE_TIME=500" \
        "MOCK_TMUX_CLIPBOARD=off" \
        "MOCK_TMUX_HISTORY=2000" \
        "MOCK_TMUX_FOCUS=off" \
        "MOCK_TMUX_MOUSE=off" \
        "MOCK_TMUX_HOOKS=no" \
        "MOCK_TMUX_MOUSEKEYS=no" \
        "MOCK_TMUX_BORDER=off" \
        fix 2>&1 || true)

    # Should mention "Fixed" in output
    if ! echo "$output" | grep -q "Fixed"; then
        return 1
    fi

    # Should have called tmux set commands (check log)
    if ! grep -q "tmux set" "$TEMP_DIR/mock-log/tmux-calls.log" 2>/dev/null; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. tmux fix with all options already correct reports no fixes needed
# ──────────────────────────────────────────────────────────────────────────────
test_fix_no_fixes_needed() {
    > "$TEMP_DIR/mock-log/tmux-calls.log"

    local output
    output=$(run_tmux fix 2>&1 || true)

    if ! echo "$output" | grep -q "No fixes needed\|already optimized"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. tmux fix outside tmux returns error
# ──────────────────────────────────────────────────────────────────────────────
test_fix_outside_tmux() {
    local exit_code=0
    (
        cd "$TEMP_DIR"
        PATH="$TEMP_DIR/bin:$PATH" \
        HOME="$TEMP_DIR/home" \
        TMUX="" \
            bash "$TEMP_DIR/scripts/sw-tmux.sh" fix 2>/dev/null
    ) || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        return 1  # Should fail outside tmux
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# TMUX RELOAD TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 15. tmux reload calls source-file (verify via mock log)
# ──────────────────────────────────────────────────────────────────────────────
test_reload_calls_source_file() {
    # Ensure tmux.conf exists
    echo "# tmux config" > "$TEMP_DIR/home/.tmux.conf"
    > "$TEMP_DIR/mock-log/tmux-calls.log"

    run_tmux reload >/dev/null 2>&1 || true

    if ! grep -q "source-file" "$TEMP_DIR/mock-log/tmux-calls.log" 2>/dev/null; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. tmux reload outside tmux returns error
# ──────────────────────────────────────────────────────────────────────────────
test_reload_outside_tmux() {
    local exit_code=0
    (
        cd "$TEMP_DIR"
        PATH="$TEMP_DIR/bin:$PATH" \
        HOME="$TEMP_DIR/home" \
        TMUX="" \
            bash "$TEMP_DIR/scripts/sw-tmux.sh" reload 2>/dev/null
    ) || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. tmux reload with missing .tmux.conf prints error
# ──────────────────────────────────────────────────────────────────────────────
test_reload_no_conf() {
    rm -f "$TEMP_DIR/home/.tmux.conf"

    local output
    output=$(run_tmux reload 2>&1 || true)

    # Should mention missing config
    if ! echo "$output" | grep -q "No.*tmux.conf"; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLI ROUTING TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 18. CLI routes "doctor" to tmux_doctor
# ──────────────────────────────────────────────────────────────────────────────
test_cli_routes_doctor() {
    local output
    output=$(run_tmux doctor 2>&1 || true)

    if ! echo "$output" | grep -q "tmux Doctor"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 19. Help output contains: doctor, install, fix, reload
# ──────────────────────────────────────────────────────────────────────────────
test_help_output() {
    local output
    output=$(run_tmux help 2>&1 || true)

    local missing=""
    for cmd in doctor install fix reload; do
        if ! echo "$output" | grep -q "$cmd"; then
            missing="${missing} ${cmd}"
        fi
    done

    if [[ -n "$missing" ]]; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 20. Default (no args) shows help
# ──────────────────────────────────────────────────────────────────────────────
test_default_shows_help() {
    local output
    output=$(run_tmux 2>&1 || true)

    if ! echo "$output" | grep -q "COMMANDS"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 21. Unknown command exits with error
# ──────────────────────────────────────────────────────────────────────────────
test_unknown_command() {
    local exit_code=0
    run_tmux nonexistent >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 22. CLI aliases: "check" routes to doctor, "setup" routes to install
# ──────────────────────────────────────────────────────────────────────────────
test_cli_aliases() {
    local output
    output=$(run_tmux check 2>&1 || true)
    if ! echo "$output" | grep -q "tmux Doctor"; then
        return 1
    fi

    output=$(run_tmux setup 2>&1 || true)
    if ! echo "$output" | grep -q "Plugin Installer"; then
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCTOR EDGE CASES
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 23. Doctor outside tmux checks config file instead
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_outside_tmux() {
    echo "set -g allow-passthrough on" > "$TEMP_DIR/home/.tmux.conf"
    echo "set -g extended-keys on" >> "$TEMP_DIR/home/.tmux.conf"

    local exit_code=0
    local output
    output=$(
        cd "$TEMP_DIR"
        PATH="$TEMP_DIR/bin:$PATH" \
        HOME="$TEMP_DIR/home" \
        TMUX="" \
        LC_TERMINAL="Ghostty" \
            bash "$TEMP_DIR/scripts/sw-tmux.sh" doctor 2>&1
    ) || exit_code=$?

    # Should mention checking config file
    if ! echo "$output" | grep -q "config file\|\.tmux\.conf"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 24. Doctor with missing TPM reports fail
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_missing_tpm() {
    rm -rf "$TEMP_DIR/home/.tmux/plugins/tpm"

    local output
    output=$(run_tmux doctor 2>&1 || true)

    if ! echo "$output" | grep -q "TPM not installed"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 25. Doctor with old tmux version warns
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_old_tmux_version() {
    local output
    output=$(run_tmux_env "MOCK_TMUX_VERSION=3.2" doctor 2>&1 || true)

    if ! echo "$output" | grep -q "3.3.*recommended\|3.2"; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright tmux — Test Suite                     ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# Doctor tests
echo -e "${PURPLE}${BOLD}tmux Doctor${RESET}"
run_test "doctor runs without error" test_doctor_runs
run_test "doctor outputs pass/warn/fail counts" test_doctor_output_counts
run_test "doctor reports all pass with correct options" test_doctor_all_pass
run_test "doctor detects bad escape-time" test_doctor_bad_escape_time
run_test "doctor detects bad history-limit" test_doctor_bad_history
run_test "doctor detects passthrough off" test_doctor_passthrough_off
run_test "doctor detects tmux version" test_doctor_version_check
run_test "doctor detects terminal emulator" test_doctor_terminal_detect
echo ""

# Install tests
echo -e "${PURPLE}${BOLD}tmux Install${RESET}"
run_test "install creates TPM directory" test_install_tpm
run_test "install skips if TPM already exists" test_install_tpm_already_exists
run_test "install copies overlay file" test_install_copies_overlay
echo ""

# Fix tests
echo -e "${PURPLE}${BOLD}tmux Fix${RESET}"
run_test "fix applies fixes for bad options" test_fix_applies_fixes
run_test "fix reports no fixes when all correct" test_fix_no_fixes_needed
run_test "fix outside tmux returns error" test_fix_outside_tmux
echo ""

# Reload tests
echo -e "${PURPLE}${BOLD}tmux Reload${RESET}"
run_test "reload calls source-file" test_reload_calls_source_file
run_test "reload outside tmux returns error" test_reload_outside_tmux
run_test "reload with missing .tmux.conf prints error" test_reload_no_conf
echo ""

# CLI routing
echo -e "${PURPLE}${BOLD}CLI Routing${RESET}"
run_test "CLI routes doctor command" test_cli_routes_doctor
run_test "Help contains all subcommands" test_help_output
run_test "Default shows help" test_default_shows_help
run_test "Unknown command exits with error" test_unknown_command
run_test "CLI aliases work (check, setup)" test_cli_aliases
echo ""

# Edge cases
echo -e "${PURPLE}${BOLD}Edge Cases${RESET}"
run_test "Doctor outside tmux checks config file" test_doctor_outside_tmux
run_test "Doctor detects missing TPM" test_doctor_missing_tpm
run_test "Doctor warns on old tmux version" test_doctor_old_tmux_version
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo -e "  ${GREEN}${BOLD}${PASS} passed${RESET}  ${RED}${BOLD}${FAIL} failed${RESET}  ${DIM}(${TOTAL} total)${RESET}"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}${BOLD}Failed tests:${RESET}"
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
fi
echo ""

[[ $FAIL -eq 0 ]]
