#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-role-color-test.sh — Agent Role Color Mapping Test Suite       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0 FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" desc="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m $desc"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m $desc"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

# ─── Setup test environment ──────────────────────────────────────────────────
setup_test_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-tmux-role-color-test.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/scripts/lib"

    # Copy script under test
    cp "$SCRIPT_DIR/sw-tmux-role-color.sh" "$TEST_TEMP_DIR/scripts/"

    # Create mock tmux
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'TMUXMOCK'
#!/bin/bash
case "$1" in
    display-message)
        # Return the mocked pane title
        echo "${MOCK_PANE_TITLE:-}"
        ;;
    set)
        # Record the set command
        echo "tmux set $*" >> "${TMUX_LOG:-/dev/null}"
        ;;
    *)
        return 0
        ;;
esac
TMUXMOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"
}

cleanup_env() {
    [[ -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
}

trap cleanup_env EXIT

# ─── Test 1: Leader role gets cyan ──────────────────────────────────────────
test_leader_cyan() {
    setup_test_env
    export MOCK_PANE_TITLE="team-leader"
    export TMUX_LOG="$TEST_TEMP_DIR/tmux.log"

    PATH="$TEST_TEMP_DIR/bin:$PATH" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1 || true

    if grep -q "#00d4ff" "$TMUX_LOG" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m leader role sets cyan color"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m leader role sets cyan color"
    fi
}

# ─── Test 2: Builder role gets blue ─────────────────────────────────────────
test_builder_blue() {
    setup_test_env
    export MOCK_PANE_TITLE="builder-agent"
    export TMUX_LOG="$TEST_TEMP_DIR/tmux.log"

    PATH="$TEST_TEMP_DIR/bin:$PATH" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1 || true

    if grep -q "#0066ff" "$TMUX_LOG" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m builder role sets blue color"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m builder role sets blue color"
    fi
}

# ─── Test 3: Reviewer role gets orange ──────────────────────────────────────
test_reviewer_orange() {
    setup_test_env
    export MOCK_PANE_TITLE="code-reviewer"
    export TMUX_LOG="$TEST_TEMP_DIR/tmux.log"

    PATH="$TEST_TEMP_DIR/bin:$PATH" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1 || true

    if grep -q "#f97316" "$TMUX_LOG" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m reviewer role sets orange color"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m reviewer role sets orange color"
    fi
}

# ─── Test 4: Tester role gets yellow ────────────────────────────────────────
test_tester_yellow() {
    setup_test_env
    export MOCK_PANE_TITLE="tester-qa"
    export TMUX_LOG="$TEST_TEMP_DIR/tmux.log"

    PATH="$TEST_TEMP_DIR/bin:$PATH" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1 || true

    if grep -q "#facc15" "$TMUX_LOG" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m tester role sets yellow color"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m tester role sets yellow color"
    fi
}

# ─── Test 5: Security role gets red ─────────────────────────────────────────
test_security_red() {
    setup_test_env
    export MOCK_PANE_TITLE="security-auditor"
    export TMUX_LOG="$TEST_TEMP_DIR/tmux.log"

    PATH="$TEST_TEMP_DIR/bin:$PATH" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1 || true

    if grep -q "#ef4444" "$TMUX_LOG" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m security role sets red color"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m security role sets red color"
    fi
}

# ─── Test 6: Docs role gets violet ──────────────────────────────────────────
test_docs_violet() {
    setup_test_env
    export MOCK_PANE_TITLE="documentation-writer"
    export TMUX_LOG="$TEST_TEMP_DIR/tmux.log"

    PATH="$TEST_TEMP_DIR/bin:$PATH" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1 || true

    if grep -q "#a78bfa" "$TMUX_LOG" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m docs role sets violet color"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m docs role sets violet color"
    fi
}

# ─── Test 7: Optimizer role gets green ──────────────────────────────────────
test_optimizer_green() {
    setup_test_env
    export MOCK_PANE_TITLE="performance-optimizer"
    export TMUX_LOG="$TEST_TEMP_DIR/tmux.log"

    PATH="$TEST_TEMP_DIR/bin:$PATH" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1 || true

    if grep -q "#4ade80" "$TMUX_LOG" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m optimizer role sets green color"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m optimizer role sets green color"
    fi
}

# ─── Test 8: Researcher role gets purple ────────────────────────────────────
test_researcher_purple() {
    setup_test_env
    export MOCK_PANE_TITLE="researcher-explorer"
    export TMUX_LOG="$TEST_TEMP_DIR/tmux.log"

    PATH="$TEST_TEMP_DIR/bin:$PATH" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1 || true

    if grep -q "#7c3aed" "$TMUX_LOG" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m researcher role sets purple color"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m researcher role sets purple color"
    fi
}

# ─── Test 9: Unknown role defaults to cyan ──────────────────────────────────
test_unknown_role_cyan() {
    setup_test_env
    export MOCK_PANE_TITLE="unknown-role-xyz"
    export TMUX_LOG="$TEST_TEMP_DIR/tmux.log"

    PATH="$TEST_TEMP_DIR/bin:$PATH" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1 || true

    if grep -q "#00d4ff" "$TMUX_LOG" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m unknown role defaults to cyan"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m unknown role defaults to cyan"
    fi
}

# ─── Test 10: Empty title defaults to cyan ───────────────────────────────────
test_empty_title_cyan() {
    setup_test_env
    export MOCK_PANE_TITLE=""
    export TMUX_LOG="$TEST_TEMP_DIR/tmux.log"

    PATH="$TEST_TEMP_DIR/bin:$PATH" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1 || true

    if grep -q "#00d4ff" "$TMUX_LOG" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m empty title defaults to cyan"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m empty title defaults to cyan"
    fi
}

# ─── Test 11: Matching ignores case ─────────────────────────────────────────
test_case_insensitive() {
    setup_test_env
    export MOCK_PANE_TITLE="TEAM-REVIEWER"
    export TMUX_LOG="$TEST_TEMP_DIR/tmux.log"

    PATH="$TEST_TEMP_DIR/bin:$PATH" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1 || true

    if grep -q "#f97316" "$TMUX_LOG" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m matching ignores case"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m matching ignores case"
    fi
}

# ─── Test 12: No tmux on PATH exits 0 ────────────────────────────────────────
test_no_tmux() {
    setup_test_env
    export MOCK_PANE_TITLE="builder"

    if PATH="$TEST_TEMP_DIR/bin-empty:$TEST_TEMP_DIR/bin" SCRIPT_DIR="$TEST_TEMP_DIR/scripts" bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m missing tmux exits 0"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m missing tmux exits 0"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-tmux-role-color-test.sh"
test_leader_cyan
test_builder_blue
test_reviewer_orange
test_tester_yellow
test_security_red
test_docs_violet
test_optimizer_green
test_researcher_purple
test_unknown_role_cyan
test_empty_title_cyan
test_case_insensitive
test_no_tmux

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
