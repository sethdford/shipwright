#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright init test — E2E validation of init/setup flow              ║
# ║  Tests config generation, template installation, and idempotency       ║
# ║  using a sandboxed HOME directory.                                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_INIT_SCRIPT="$SCRIPT_DIR/cct-init.sh"

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

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cct-init-test.XXXXXX")

    # ── Sandboxed HOME ─────────────────────────────────────────────────────
    mkdir -p "$TEMP_DIR/home"

    # ── Mock project directory ─────────────────────────────────────────────
    mkdir -p "$TEMP_DIR/project/.claude"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# INIT INVOCATION HELPER
# Runs init with sandboxed HOME so we don't touch real config.
# Uses --no-claude-md to skip interactive prompts and auto-answers Y to
# tmux.conf overwrite by piping 'y'.
# ═══════════════════════════════════════════════════════════════════════════════

INIT_OUTPUT=""
INIT_EXIT=0

invoke_init() {
    INIT_OUTPUT=""
    INIT_EXIT=0

    # Run the REAL init script with sandboxed HOME.
    # REPO_DIR resolves from SCRIPT_DIR, so templates/tmux configs are found.
    # Doctor call uses || true so it won't break even if it fails.
    # TMUX="" prevents tmux source-file calls.
    # Provide enough "y" answers for interactive prompts via heredoc.
    # read -rp under set -e returns exit 1 on EOF, so we must provide input.
    # Using a finite heredoc avoids SIGPIPE from `yes`.
    INIT_OUTPUT=$(
        cd "$TEMP_DIR/project"
        HOME="$TEMP_DIR/home" \
        TMUX="" \
        bash "$REAL_INIT_SCRIPT" "$@" 2>&1 <<'INPUT'
y
y
y
y
INPUT
    ) || INIT_EXIT=$?
}

# ═══════════════════════════════════════════════════════════════════════════════
# ASSERTIONS
# ═══════════════════════════════════════════════════════════════════════════════

assert_exit_code() {
    local expected="$1" label="${2:-exit code}"
    if [[ "$INIT_EXIT" -eq "$expected" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected exit code $expected, got $INIT_EXIT ($label)"
    echo -e "    ${DIM}Output (last 10 lines):${RESET}"
    echo "$INIT_OUTPUT" | tail -10 | sed 's/^/      /'
    return 1
}

assert_output_contains() {
    local pattern="$1" label="${2:-output match}"
    if printf '%s\n' "$INIT_OUTPUT" | grep -qiE "$pattern" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output missing pattern: $pattern ($label)"
    echo -e "    ${DIM}Output (last 5 lines):${RESET}"
    echo "$INIT_OUTPUT" | tail -5 | sed 's/^/      /'
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

assert_dir_exists() {
    local dirpath="$1" label="${2:-dir exists}"
    if [[ -d "$dirpath" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Directory not found: $dirpath ($label)"
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

assert_file_count() {
    local dir="$1" pattern="$2" expected="$3" label="${4:-file count}"
    local count
    count=$(find "$dir" -name "$pattern" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -ge "$expected" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected >= $expected files matching $pattern in $dir, found $count ($label)"
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
# 1. Init creates settings.json with agent teams
# ──────────────────────────────────────────────────────────────────────────────
test_settings_json_created() {
    invoke_init --no-claude-md
    assert_exit_code 0 "init should succeed" &&
    assert_file_exists "$TEMP_DIR/home/.claude/settings.json" "settings.json created" &&
    assert_file_contains "$TEMP_DIR/home/.claude/settings.json" \
        "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" "agent teams env var"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Team templates installed
# ──────────────────────────────────────────────────────────────────────────────
test_team_templates_installed() {
    invoke_init --no-claude-md
    assert_exit_code 0 "init should succeed" &&
    assert_dir_exists "$TEMP_DIR/home/.shipwright/templates" "templates dir" &&
    assert_file_count "$TEMP_DIR/home/.shipwright/templates" "*.json" 10 "at least 10 templates"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Pipeline templates installed
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_templates_installed() {
    invoke_init --no-claude-md
    assert_exit_code 0 "init should succeed" &&
    assert_dir_exists "$TEMP_DIR/home/.shipwright/pipelines" "pipelines dir" &&
    assert_file_count "$TEMP_DIR/home/.shipwright/pipelines" "*.json" 5 "at least 5 pipeline templates"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. tmux.conf installed when no existing config
# ──────────────────────────────────────────────────────────────────────────────
test_tmux_conf_installed() {
    invoke_init --no-claude-md
    assert_exit_code 0 "init should succeed" &&
    assert_file_exists "$TEMP_DIR/home/.tmux.conf" "tmux.conf created"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Overlay installed
# ──────────────────────────────────────────────────────────────────────────────
test_overlay_installed() {
    invoke_init --no-claude-md
    assert_exit_code 0 "init should succeed" &&
    assert_file_exists "$TEMP_DIR/home/.tmux/claude-teams-overlay.conf" "overlay installed"
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Idempotency — running twice doesn't duplicate or corrupt
# ──────────────────────────────────────────────────────────────────────────────
test_idempotency() {
    # First run
    invoke_init --no-claude-md
    assert_exit_code 0 "first init should succeed"

    # Capture state after first run
    local first_settings
    first_settings=$(cat "$TEMP_DIR/home/.claude/settings.json" 2>/dev/null || echo "")

    # Second run
    invoke_init --no-claude-md
    assert_exit_code 0 "second init should succeed"

    # Settings should still be valid JSON
    if ! jq -e '.' "$TEMP_DIR/home/.claude/settings.json" >/dev/null 2>&1; then
        echo -e "    ${RED}✗${RESET} settings.json is invalid JSON after second run"
        return 1
    fi

    # Agent teams should still be present (not duplicated or removed)
    assert_file_contains "$TEMP_DIR/home/.claude/settings.json" \
        "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" "agent teams still present"
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Settings merge — existing settings.json preserved
# ──────────────────────────────────────────────────────────────────────────────
test_settings_merge() {
    # Create existing settings with custom content
    mkdir -p "$TEMP_DIR/home/.claude"
    cat > "$TEMP_DIR/home/.claude/settings.json" <<'EOF'
{
  "env": {
    "MY_CUSTOM_VAR": "keep-me"
  }
}
EOF

    invoke_init --no-claude-md
    assert_exit_code 0 "init should succeed" &&
    assert_file_contains "$TEMP_DIR/home/.claude/settings.json" \
        "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" "agent teams added" &&
    assert_file_contains "$TEMP_DIR/home/.claude/settings.json" \
        "MY_CUSTOM_VAR" "custom var preserved"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Help flag
# ──────────────────────────────────────────────────────────────────────────────
test_help_flag() {
    INIT_OUTPUT=""
    INIT_EXIT=0
    INIT_OUTPUT=$(bash "$REAL_INIT_SCRIPT" --help 2>&1) || INIT_EXIT=$?
    assert_exit_code 0 "help should succeed" &&
    assert_output_contains "Usage" "should show usage"
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Doctor runs at end of init
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_runs() {
    invoke_init --no-claude-md
    assert_exit_code 0 "init should succeed" &&
    assert_output_contains "doctor|Running doctor" "doctor should run"
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Legacy templates path also populated
# ──────────────────────────────────────────────────────────────────────────────
test_legacy_templates_path() {
    invoke_init --no-claude-md
    assert_exit_code 0 "init should succeed" &&
    assert_dir_exists "$TEMP_DIR/home/.claude-teams/templates" "legacy templates dir" &&
    assert_file_count "$TEMP_DIR/home/.claude-teams/templates" "*.json" 10 "legacy templates populated"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. JSONC stripped from settings.json
# ──────────────────────────────────────────────────────────────────────────────
test_jsonc_stripped() {
    invoke_init --no-claude-md
    assert_exit_code 0 "init should succeed" &&
    assert_file_exists "$TEMP_DIR/home/.claude/settings.json" "settings.json exists"

    # The template has // comments — after init, settings.json must be valid JSON
    if ! jq -e '.' "$TEMP_DIR/home/.claude/settings.json" >/dev/null 2>&1; then
        echo -e "    ${RED}✗${RESET} settings.json is not valid JSON (JSONC comments not stripped)"
        return 1
    fi

    # Ensure no // comment lines remain
    if grep -q '^[[:space:]]*//' "$TEMP_DIR/home/.claude/settings.json" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} settings.json still contains // comment lines"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Hooks wired into settings.json
# ──────────────────────────────────────────────────────────────────────────────
test_hooks_wired() {
    invoke_init --no-claude-md
    assert_exit_code 0 "init should succeed"

    # Check that hook events are configured in settings.json
    for event in TeammateIdle TaskCompleted Notification PreCompact SessionStart; do
        if ! jq -e ".hooks.${event}" "$TEMP_DIR/home/.claude/settings.json" >/dev/null 2>&1; then
            echo -e "    ${RED}✗${RESET} Hook event ${event} not found in settings.json"
            return 1
        fi
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Hook wiring preserves existing hooks
# ──────────────────────────────────────────────────────────────────────────────
test_hook_wiring_preserves_existing() {
    # First init — installs everything
    invoke_init --no-claude-md
    assert_exit_code 0 "first init should succeed"

    # Add a custom hook event to settings.json
    tmp=$(mktemp)
    jq '.hooks.CustomHook = [{"hooks": [{"type": "command", "command": "echo custom"}]}]' \
        "$TEMP_DIR/home/.claude/settings.json" > "$tmp" && mv "$tmp" "$TEMP_DIR/home/.claude/settings.json"

    # Second init
    invoke_init --no-claude-md
    assert_exit_code 0 "second init should succeed"

    # Custom hook should survive
    if ! jq -e '.hooks.CustomHook' "$TEMP_DIR/home/.claude/settings.json" >/dev/null 2>&1; then
        echo -e "    ${RED}✗${RESET} Custom hook was removed by second init"
        return 1
    fi

    # Standard hooks should still be present
    if ! jq -e '.hooks.TeammateIdle' "$TEMP_DIR/home/.claude/settings.json" >/dev/null 2>&1; then
        echo -e "    ${RED}✗${RESET} TeammateIdle hook missing after second init"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. SessionStart hook installed
# ──────────────────────────────────────────────────────────────────────────────
test_session_start_hook_installed() {
    invoke_init --no-claude-md
    assert_exit_code 0 "init should succeed"

    local hook_file="$TEMP_DIR/home/.claude/hooks/session-start.sh"
    assert_file_exists "$hook_file" "session-start.sh exists"

    if [[ ! -x "$hook_file" ]]; then
        echo -e "    ${RED}✗${RESET} session-start.sh is not executable"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Hook wiring with pre-existing settings
# ──────────────────────────────────────────────────────────────────────────────
test_hook_wiring_with_existing_settings() {
    # Create settings.json with env vars but no hooks
    mkdir -p "$TEMP_DIR/home/.claude"
    cat > "$TEMP_DIR/home/.claude/settings.json" <<'EOF'
{
  "env": {
    "MY_VAR": "keep-this",
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
EOF

    invoke_init --no-claude-md
    assert_exit_code 0 "init should succeed"

    # Env vars should be preserved
    assert_file_contains "$TEMP_DIR/home/.claude/settings.json" \
        "MY_VAR" "custom env var preserved" &&
    assert_file_contains "$TEMP_DIR/home/.claude/settings.json" \
        "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" "agent teams var preserved"

    # Hooks should be wired
    if ! jq -e '.hooks.TeammateIdle' "$TEMP_DIR/home/.claude/settings.json" >/dev/null 2>&1; then
        echo -e "    ${RED}✗${RESET} Hooks not wired into pre-existing settings"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright init — E2E Test Suite                 ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} jq is required for init tests"
    exit 1
fi

# Setup
echo -e "${DIM}Setting up sandboxed environment...${RESET}"
setup_env
echo -e "${DIM}Temp dir: ${TEMP_DIR}${RESET}"
echo ""

# Config generation tests
echo -e "${PURPLE}${BOLD}Configuration${RESET}"
run_test "Settings.json created with agent teams" test_settings_json_created
run_test "Settings merge preserves existing vars" test_settings_merge
run_test "tmux.conf installed" test_tmux_conf_installed
run_test "Overlay installed" test_overlay_installed
echo ""

# Template installation tests
echo -e "${PURPLE}${BOLD}Templates${RESET}"
run_test "Team templates installed (>= 10)" test_team_templates_installed
run_test "Pipeline templates installed (>= 5)" test_pipeline_templates_installed
run_test "Legacy templates path populated" test_legacy_templates_path
echo ""

# Robustness tests
echo -e "${PURPLE}${BOLD}Robustness${RESET}"
run_test "Idempotency — double init safe" test_idempotency
run_test "Doctor runs at end" test_doctor_runs
run_test "Help flag" test_help_flag
echo ""

# Hook wiring tests
echo -e "${PURPLE}${BOLD}Hook Wiring${RESET}"
run_test "JSONC stripped from settings.json" test_jsonc_stripped
run_test "Hooks wired into settings.json" test_hooks_wired
run_test "Hook wiring preserves existing hooks" test_hook_wiring_preserves_existing
run_test "SessionStart hook installed" test_session_start_hook_installed
run_test "Hook wiring with pre-existing settings" test_hook_wiring_with_existing_settings
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
