#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright setup test — Validate comprehensive onboarding wizard        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls uname; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
    done

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "abc1234"; fi ;;
    remote) echo "git@github.com:test/repo.git" ;;
    --version) echo "git version 2.39.0" ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh, claude, tmux
    for mock in gh claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT




# ═══════════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "shipwright setup test suite"
echo ""

setup_env

# ─── 1. Script safety ────────────────────────────────────────────────────────

echo -e "${BOLD}  Script Safety${RESET}"

if grep -q 'set -euo pipefail' "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

echo ""

# ─── 2. VERSION ──────────────────────────────────────────────────────────────

echo -e "${BOLD}  Version${RESET}"

if grep -q '^VERSION=' "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "VERSION variable defined at top"
else
    assert_fail "VERSION variable defined at top"
fi

echo ""

# ─── 3. Help ─────────────────────────────────────────────────────────────────

echo -e "${BOLD}  Help${RESET}"

output=$(bash "$SCRIPT_DIR/sw-setup.sh" --help 2>&1) || true
assert_contains "help mentions Usage" "$output" "Usage"
assert_contains "help mentions Phase 1" "$output" "Phase 1"
assert_contains "help mentions Phase 2" "$output" "Phase 2"
assert_contains "help mentions Phase 3" "$output" "Phase 3"
assert_contains "help mentions Phase 4" "$output" "Phase 4"
assert_contains "help mentions --skip-daemon-prompt" "$output" "--skip-daemon-prompt"

# -h flag
output=$(bash "$SCRIPT_DIR/sw-setup.sh" -h 2>&1) || true
assert_contains "-h flag works" "$output" "Usage"

echo ""

# ─── 4. Help exits 0 ────────────────────────────────────────────────────────

echo -e "${BOLD}  Help Exit Code${RESET}"

if bash "$SCRIPT_DIR/sw-setup.sh" --help >/dev/null 2>&1; then
    assert_pass "--help exits 0"
else
    assert_fail "--help exits 0"
fi

echo ""

# ─── 5. Four phases present in source ───────────────────────────────────────

echo -e "${BOLD}  Phase Structure${RESET}"

if grep -q "PHASE 1:" "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "PHASE 1: PREREQUISITES defined"
else
    assert_fail "PHASE 1: PREREQUISITES defined"
fi

if grep -q "PHASE 2:" "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "PHASE 2: REPO ANALYSIS defined"
else
    assert_fail "PHASE 2: REPO ANALYSIS defined"
fi

if grep -q "PHASE 3:" "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "PHASE 3: CONFIGURATION GENERATION defined"
else
    assert_fail "PHASE 3: CONFIGURATION GENERATION defined"
fi

if grep -q "PHASE 4:" "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "PHASE 4: VALIDATION defined"
else
    assert_fail "PHASE 4: VALIDATION defined"
fi

echo ""

# ─── 6. Required tools list ────────────────────────────────────────────────

echo -e "${BOLD}  Prerequisites Detection${RESET}"

if grep -q 'REQUIRED_TOOLS=' "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "REQUIRED_TOOLS array defined"
else
    assert_fail "REQUIRED_TOOLS array defined"
fi

source_content=$(cat "$SCRIPT_DIR/sw-setup.sh")
assert_contains "checks for tmux" "$source_content" "tmux"
assert_contains "checks for bash" "$source_content" "bash"
assert_contains "checks for git" "$source_content" "git"
assert_contains "checks for jq" "$source_content" "jq"
assert_contains "checks for gh" "$source_content" "gh"
assert_contains "checks for claude" "$source_content" "claude"

echo ""

# ─── 7. Language detection ──────────────────────────────────────────────────

echo -e "${BOLD}  Language Detection${RESET}"

assert_contains "detects Node.js via package.json" "$source_content" "package.json"
assert_contains "detects Rust via Cargo.toml" "$source_content" "Cargo.toml"
assert_contains "detects Go via go.mod" "$source_content" "go.mod"
assert_contains "detects Python via pyproject.toml" "$source_content" "pyproject.toml"

echo ""

# ─── 8. Skip daemon prompt flag ────────────────────────────────────────────

echo -e "${BOLD}  Skip Daemon Prompt${RESET}"

if grep -q 'SKIP_DAEMON_PROMPT=' "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "SKIP_DAEMON_PROMPT flag defined"
else
    assert_fail "SKIP_DAEMON_PROMPT flag defined"
fi

if grep -q '\-\-skip-daemon-prompt' "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "--skip-daemon-prompt flag handled"
else
    assert_fail "--skip-daemon-prompt flag handled"
fi

echo ""

# ─── 9. Calls sw-init.sh and sw-doctor.sh ──────────────────────────────────

echo -e "${BOLD}  Subprocess Calls${RESET}"

if grep -q 'sw-init.sh' "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "calls sw-init.sh for config generation"
else
    assert_fail "calls sw-init.sh for config generation"
fi

if grep -q 'sw-doctor.sh' "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "calls sw-doctor.sh for validation"
else
    assert_fail "calls sw-doctor.sh for validation"
fi

echo ""

# ─── 10. OS detection ──────────────────────────────────────────────────────

echo -e "${BOLD}  OS Detection${RESET}"

if grep -q 'detect_os' "$SCRIPT_DIR/sw-setup.sh"; then
    assert_pass "detect_os function present"
else
    assert_fail "detect_os function present"
fi

assert_contains "handles macOS" "$source_content" "macOS"
assert_contains "handles Linux" "$source_content" "Linux"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
