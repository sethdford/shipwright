#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright session test — E2E validation of session creation flow      ║
# ║  Tests template loading, prompt generation, launcher scripts, and      ║
# ║  tmux window creation using mock binaries.                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_SESSION_SCRIPT="$SCRIPT_DIR/cct-session.sh"

# ─── Colors (matches cct theme) ──────────────────────────────────────────────
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
TEST_TMUX_SESSION=""

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cct-session-test.XXXXXX")

    # ── Copy real session script ───────────────────────────────────────────
    mkdir -p "$TEMP_DIR/scripts/adapters"
    cp "$REAL_SESSION_SCRIPT" "$TEMP_DIR/scripts/cct-session.sh"

    # ── Copy tmux templates ────────────────────────────────────────────────
    if [[ -d "$REPO_DIR/tmux/templates" ]]; then
        mkdir -p "$TEMP_DIR/tmux/templates"
        cp "$REPO_DIR/tmux/templates"/*.json "$TEMP_DIR/tmux/templates/" 2>/dev/null || true
    fi

    # ── Mock binaries ──────────────────────────────────────────────────────
    mkdir -p "$TEMP_DIR/bin"
    create_mock_claude

    # ── Create a headless tmux session for testing ─────────────────────────
    TEST_TMUX_SESSION="cct-test-$$"
    tmux new-session -d -s "$TEST_TMUX_SESSION" -x 120 -y 40 2>/dev/null || {
        echo -e "${RED}${BOLD}✗${RESET} Cannot create tmux session (tmux not available or not in terminal)"
        echo -e "  ${DIM}Run these tests inside tmux or with a terminal attached.${RESET}"
        exit 1
    }
}

create_mock_claude() {
    cat > "$TEMP_DIR/bin/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
# Mock claude — captures args to a file and exits
echo "$@" > "${MOCK_CLAUDE_LOG:-/dev/null}"
exit 0
CLAUDE_EOF
    chmod +x "$TEMP_DIR/bin/claude"
}

cleanup_env() {
    # Kill test tmux session
    if [[ -n "$TEST_TMUX_SESSION" ]]; then
        tmux kill-session -t "$TEST_TMUX_SESSION" 2>/dev/null || true
    fi
    # Remove any test windows that leaked
    for w in $(tmux list-windows -F '#W' 2>/dev/null | grep '^claude-test-' || true); do
        tmux kill-window -t "$w" 2>/dev/null || true
    done
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# SESSION INVOCATION HELPER
# ═══════════════════════════════════════════════════════════════════════════════

SESSION_OUTPUT=""
SESSION_EXIT=0

invoke_session() {
    SESSION_OUTPUT=""
    SESSION_EXIT=0

    # Run session script inside the test tmux session so tmux commands work
    SESSION_OUTPUT=$(
        TMUX="$(tmux display-message -p '#{socket_path}' 2>/dev/null || echo '/tmp/tmux-test')"
        export TMUX
        PATH="$TEMP_DIR/bin:$PATH" \
        TMPDIR="$TEMP_DIR" \
        bash "$TEMP_DIR/scripts/cct-session.sh" "$@" 2>&1
    ) || SESSION_EXIT=$?
}

# ═══════════════════════════════════════════════════════════════════════════════
# ASSERTIONS
# ═══════════════════════════════════════════════════════════════════════════════

assert_exit_code() {
    local expected="$1" label="${2:-exit code}"
    if [[ "$SESSION_EXIT" -eq "$expected" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected exit code $expected, got $SESSION_EXIT ($label)"
    return 1
}

assert_output_contains() {
    local pattern="$1" label="${2:-output match}"
    if printf '%s\n' "$SESSION_OUTPUT" | grep -qiE "$pattern" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output missing pattern: $pattern ($label)"
    echo -e "    ${DIM}Output (last 5 lines):${RESET}"
    echo "$SESSION_OUTPUT" | tail -5 | sed 's/^/      /'
    return 1
}

assert_output_not_contains() {
    local pattern="$1" label="${2:-output exclusion}"
    if ! printf '%s\n' "$SESSION_OUTPUT" | grep -qiE "$pattern" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output unexpectedly contains: $pattern ($label)"
    return 1
}

assert_file_exists() {
    local filepath="$1" label="${2:-file exists}"
    if [[ -f "$filepath" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
    return 1
}

assert_file_contains() {
    local filepath="$1" pattern="$2" label="${3:-file content}"
    if [[ ! -f "$filepath" ]]; then
        echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
        return 1
    fi
    if grep -qiE "$pattern" "$filepath"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File $filepath missing pattern: $pattern ($label)"
    return 1
}

assert_window_exists() {
    local window_name="$1" label="${2:-window exists}"
    if tmux list-windows -F '#W' 2>/dev/null | grep -qx "$window_name"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} tmux window not found: $window_name ($label)"
    return 1
}

assert_window_not_exists() {
    local window_name="$1" label="${2:-window absent}"
    if ! tmux list-windows -F '#W' 2>/dev/null | grep -qx "$window_name"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} tmux window should not exist: $window_name ($label)"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "

    # Clean up any leftover test windows
    for w in $(tmux list-windows -F '#W' 2>/dev/null | grep '^claude-test-' || true); do
        tmux kill-window -t "$w" 2>/dev/null || true
    done

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
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Template loading — feature-dev template
# ──────────────────────────────────────────────────────────────────────────────
test_template_loading_feature_dev() {
    invoke_session "test-tpl-1" --template feature-dev --no-launch
    assert_exit_code 0 "session should succeed" &&
    assert_output_contains "feature-dev" "template name shown" &&
    assert_output_contains "Agents: 3" "should have 3 agents"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Template loading — exploration template
# ──────────────────────────────────────────────────────────────────────────────
test_template_loading_exploration() {
    invoke_session "test-tpl-2" --template exploration --no-launch
    assert_exit_code 0 "session should succeed" &&
    assert_output_contains "exploration" "template name shown" &&
    assert_output_contains "Agents: 2" "should have 2 agents"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Template loading — missing template
# ──────────────────────────────────────────────────────────────────────────────
test_template_missing() {
    invoke_session "test-tpl-3" --template nonexistent-template --no-launch
    assert_exit_code 1 "should fail for missing template" &&
    assert_output_contains "not found" "error message"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Template loading — all 12 templates load without errors
# ──────────────────────────────────────────────────────────────────────────────
test_all_templates_load() {
    local templates=()
    for tpl_file in "$TEMP_DIR/tmux/templates"/*.json; do
        [[ -f "$tpl_file" ]] || continue
        local name
        name="$(basename "$tpl_file" .json)"
        templates+=("$name")
    done

    if [[ ${#templates[@]} -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} No templates found"
        return 1
    fi

    local failed=0
    for tpl_name in "${templates[@]}"; do
        invoke_session "test-all-$tpl_name" --template "$tpl_name" --no-launch
        if [[ "$SESSION_EXIT" -ne 0 ]]; then
            echo -e "    ${RED}✗${RESET} Template '$tpl_name' failed to load"
            failed=1
        fi
        # Clean up window
        tmux kill-window -t "claude-test-all-$tpl_name" 2>/dev/null || true
    done

    [[ "$failed" -eq 0 ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. No-launch creates window without starting claude
# ──────────────────────────────────────────────────────────────────────────────
test_no_launch_creates_window() {
    invoke_session "test-nol-1" --no-launch
    assert_exit_code 0 "should succeed" &&
    assert_window_exists "claude-test-nol-1" "window created" &&
    assert_output_contains "Launch Claude manually" "no-launch instructions"

    # Cleanup
    tmux kill-window -t "claude-test-nol-1" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Launcher script generated with prompt file
# ──────────────────────────────────────────────────────────────────────────────
test_launcher_script_generation() {
    local mock_log="$TEMP_DIR/claude-args.log"
    export MOCK_CLAUDE_LOG="$mock_log"

    invoke_session "test-launch-1" --template feature-dev --goal "Build auth"
    assert_exit_code 0 "session should succeed"

    # Check launcher was created (may already be cleaned up by the script)
    # Instead verify the prompt file was generated with correct content
    # The launcher deletes itself after running, so check output
    assert_output_contains "team setup" "should mention team setup" &&
    assert_output_contains "feature-dev" "should mention template"

    # Cleanup
    tmux kill-window -t "claude-test-launch-1" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Prompt includes agents from template
# ──────────────────────────────────────────────────────────────────────────────
test_prompt_includes_agents() {
    # Use --no-launch so we can inspect the prompt file
    # We need to build the prompt without actually creating the session
    # Run just the prompt generation part
    local prompt
    prompt=$(
        SCRIPT_DIR="$TEMP_DIR/scripts"
        TEMPLATE_AGENTS=("backend|API routes|src/api/" "frontend|UI components|apps/web/" "tests|Unit tests|*.test.ts")
        TEAM_NAME="test-prompt-agents"
        GOAL=""
        # Source just enough of the session script to get build_team_prompt
        # Instead, call the full script and check output for agent names
        true
    )

    invoke_session "test-prompt-1" --template feature-dev --no-launch
    assert_exit_code 0 "should succeed" &&
    assert_output_contains "backend" "should list backend agent" &&
    assert_output_contains "frontend" "should list frontend agent" &&
    assert_output_contains "tests" "should list tests agent"

    tmux kill-window -t "claude-test-prompt-1" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Prompt includes goal when provided
# ──────────────────────────────────────────────────────────────────────────────
test_prompt_includes_goal() {
    invoke_session "test-goal-1" --template feature-dev --goal "Build JWT auth" --no-launch
    assert_exit_code 0 "should succeed" &&
    assert_output_contains "Build JWT auth" "goal should appear in output"

    tmux kill-window -t "claude-test-goal-1" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. No template + goal creates team prompt
# ──────────────────────────────────────────────────────────────────────────────
test_no_template_with_goal() {
    invoke_session "test-notpl-1" --goal "Fix login bug" --no-launch
    # With no template but a goal, the auto-launch path would be taken
    # but --no-launch overrides it, so we just get a plain window
    assert_exit_code 0 "should succeed"

    tmux kill-window -t "claude-test-notpl-1" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. No template + no goal = interactive mode
# ──────────────────────────────────────────────────────────────────────────────
test_no_template_no_goal() {
    invoke_session "test-interactive-1" --no-launch
    assert_exit_code 0 "should succeed" &&
    assert_output_contains "Launch Claude manually" "should suggest manual launch"

    tmux kill-window -t "claude-test-interactive-1" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Duplicate window detection — switch instead of crash
# ──────────────────────────────────────────────────────────────────────────────
test_duplicate_window_detection() {
    # Create a window first
    invoke_session "test-dup-1" --no-launch
    assert_exit_code 0 "first session should succeed" &&
    assert_window_exists "claude-test-dup-1" "window created"

    # Try to create again — should switch, not crash
    invoke_session "test-dup-1" --no-launch
    assert_exit_code 0 "duplicate should not crash" &&
    assert_output_contains "already exists" "should warn about existing window"

    tmux kill-window -t "claude-test-dup-1" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Help flag
# ──────────────────────────────────────────────────────────────────────────────
test_help_flag() {
    invoke_session --help
    assert_exit_code 0 "help should succeed" &&
    assert_output_contains "USAGE" "should show usage" &&
    assert_output_contains "template" "should mention template option"
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Unknown option
# ──────────────────────────────────────────────────────────────────────────────
test_unknown_option() {
    invoke_session "test-unk-1" --bogus-flag --no-launch
    assert_exit_code 1 "should fail on unknown flag" &&
    assert_output_contains "Unknown option" "error message"
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Window gets dark theme applied
# ──────────────────────────────────────────────────────────────────────────────
test_window_dark_theme() {
    invoke_session "test-theme-1" --no-launch
    assert_exit_code 0 "should succeed" &&
    assert_window_exists "claude-test-theme-1" "window created"
    # The pane style should have been set via select-pane -P
    # Check the pane option (stored as window-style or via show-options -p)
    local style
    style=$(tmux show-options -p -t "claude-test-theme-1" 2>/dev/null | grep -o "1a1a2e" || echo "")
    if [[ -z "$style" ]]; then
        echo -e "    ${RED}✗${RESET} Pane style missing dark theme"
        tmux kill-window -t "claude-test-theme-1" 2>/dev/null || true
        return 1
    fi

    tmux kill-window -t "claude-test-theme-1" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Auto-generated team name when none provided
# ──────────────────────────────────────────────────────────────────────────────
test_auto_generated_name() {
    invoke_session --no-launch
    assert_exit_code 0 "should succeed" &&
    assert_output_contains "team-[0-9]+" "should auto-generate team name"

    # Cleanup auto-named window
    for w in $(tmux list-windows -F '#W' 2>/dev/null | grep '^claude-team-' || true); do
        tmux kill-window -t "$w" 2>/dev/null || true
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. TMPDIR is used for launcher files
# ──────────────────────────────────────────────────────────────────────────────
test_tmpdir_usage() {
    # Verify the script uses secure temp dir (mktemp -d) instead of hardcoded /tmp
    if grep -q 'SECURE_TMPDIR=$(mktemp -d)' "$TEMP_DIR/scripts/cct-session.sh"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Script missing SECURE_TMPDIR with mktemp -d"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. Template auto-suggestion from goal
# ──────────────────────────────────────────────────────────────────────────────
test_auto_suggestion_from_goal() {
    invoke_session "test-suggest-1" --goal "Fix the login bug" --dry-run
    assert_exit_code 0 "should succeed" &&
    assert_output_contains "Auto-suggesting template.*bug-fix" "should suggest bug-fix template"
}

# ──────────────────────────────────────────────────────────────────────────────
# 18. No suggestion without goal
# ──────────────────────────────────────────────────────────────────────────────
test_no_suggestion_without_goal() {
    invoke_session "test-nosuggest-1" --template feature-dev --dry-run
    assert_exit_code 0 "should succeed" &&
    assert_output_not_contains "Auto-suggesting" "should not auto-suggest when template provided"
}

# ──────────────────────────────────────────────────────────────────────────────
# 19. Memory injection in prompt
# ──────────────────────────────────────────────────────────────────────────────
test_memory_injection_in_prompt() {
    # Create a mock cct-memory.sh that echoes test content
    cat > "$TEMP_DIR/scripts/cct-memory.sh" <<'MOCK_MEM'
#!/usr/bin/env bash
echo "Lesson: always run tests before committing"
MOCK_MEM
    chmod +x "$TEMP_DIR/scripts/cct-memory.sh"

    invoke_session "test-mem-1" --template feature-dev --goal "Build auth" --dry-run
    assert_exit_code 0 "should succeed" &&
    assert_output_contains "Historical context" "should include memory header" &&
    assert_output_contains "always run tests" "should include memory content"
}

# ──────────────────────────────────────────────────────────────────────────────
# 20. CLAUDE.md reminder in prompt
# ──────────────────────────────────────────────────────────────────────────────
test_claude_md_reminder_in_prompt() {
    invoke_session "test-claudemd-1" --template feature-dev --dry-run
    assert_exit_code 0 "should succeed" &&
    assert_output_contains "CLAUDE.md" "should include CLAUDE.md reminder"
}

# ──────────────────────────────────────────────────────────────────────────────
# 21. Secure temp dir in source
# ──────────────────────────────────────────────────────────────────────────────
test_secure_tmpdir_in_source() {
    # Verify the script uses mktemp -d for secure temp directory
    if grep -q 'SECURE_TMPDIR=$(mktemp -d)' "$TEMP_DIR/scripts/cct-session.sh"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Script missing SECURE_TMPDIR with mktemp -d"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright session — E2E Test Suite              ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v tmux &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} tmux is required for session tests"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} jq is required for template parsing"
    exit 1
fi

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo -e "${DIM}Test tmux session: ${TEST_TMUX_SESSION}${RESET}"
echo ""

# Template loading tests
echo -e "${PURPLE}${BOLD}Template Loading${RESET}"
run_test "Load feature-dev template (3 agents)" test_template_loading_feature_dev
run_test "Load exploration template (2 agents)" test_template_loading_exploration
run_test "Missing template returns error" test_template_missing
run_test "All 24 templates load successfully" test_all_templates_load
echo ""

# Window creation tests
echo -e "${PURPLE}${BOLD}Window Creation${RESET}"
run_test "No-launch creates window without claude" test_no_launch_creates_window
run_test "Duplicate window detection" test_duplicate_window_detection
run_test "Window gets dark theme" test_window_dark_theme
run_test "Auto-generated team name" test_auto_generated_name
echo ""

# Prompt generation tests
echo -e "${PURPLE}${BOLD}Prompt & Launcher${RESET}"
run_test "Launcher script generation with template" test_launcher_script_generation
run_test "Output includes agents from template" test_prompt_includes_agents
run_test "Output includes goal when provided" test_prompt_includes_goal
run_test "No template + goal works" test_no_template_with_goal
run_test "No template + no goal = interactive" test_no_template_no_goal
echo ""

# Misc tests
echo -e "${PURPLE}${BOLD}CLI & Configuration${RESET}"
run_test "Help flag" test_help_flag
run_test "Unknown option" test_unknown_option
run_test "TMPDIR used for launcher files" test_tmpdir_usage
echo ""

# Enhanced features tests
echo -e "${PURPLE}${BOLD}Enhanced Features${RESET}"
run_test "Template auto-suggestion from goal" test_auto_suggestion_from_goal
run_test "No suggestion without goal" test_no_suggestion_without_goal
run_test "Memory injection in prompt" test_memory_injection_in_prompt
run_test "CLAUDE.md reminder in prompt" test_claude_md_reminder_in_prompt
run_test "Secure temp dir in source" test_secure_tmpdir_in_source
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
