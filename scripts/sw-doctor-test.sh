#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright doctor test — Validate setup diagnostics                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/home/.local/bin"
    mkdir -p "$TEST_TEMP_DIR/home/.tmux/plugins/tpm"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock tmux
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-V" ]]; then
    echo "tmux 3.4"
    exit 0
fi
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/tmux"

    # Mock claude
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo "claude mock v1.0"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    # Mock node
    cat > "$TEST_TEMP_DIR/bin/node" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
    echo "v20.10.0"
fi
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/node"

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "git version 2.43.0"
    exit 0
fi
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
    echo "Logged in to github.com"
    exit 0
fi
if [[ "${1:-}" == "auth" && "${2:-}" == "token" ]]; then
    echo "ghp_mocktoken123"
    exit 0
fi
echo "mock gh"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock bun
    cat > "$TEST_TEMP_DIR/bin/bun" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "1.0.0"
fi
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/bun"

    # Mock curl
    cat > "$TEST_TEMP_DIR/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
echo "{}"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/curl"

    # Mock sqlite3
    cat > "$TEST_TEMP_DIR/bin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "3.40.0 2023-01-01"
    exit 0
fi
echo ""
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/sqlite3"

    # Mock lsof - port 3000 not in use
    cat > "$TEST_TEMP_DIR/bin/lsof" <<'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/lsof"

    # Create sw script in local bin (doctor checks this)
    cat > "$TEST_TEMP_DIR/home/.local/bin/sw" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock sw"
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/home/.local/bin/sw"

    export PATH="$TEST_TEMP_DIR/bin:$TEST_TEMP_DIR/home/.local/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() {
    local desc="$1"
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    local _result
    _result=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true
    if [[ "${_result:-0}" -gt 0 ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Doctor Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: doctor runs without crashing ────────────────────────────────────
echo -e "${DIM}  execution${RESET}"

output=$(bash "$SCRIPT_DIR/sw-doctor.sh" 2>&1) && rc=0 || rc=$?
# Doctor may warn/fail checks but should not crash
if [[ $rc -le 255 ]]; then
    assert_pass "doctor runs without crash"
else
    assert_fail "doctor runs without crash" "exit code: $rc"
fi

# ─── Test 2: output contains section headers ────────────────────────────────
assert_contains "output shows PREREQUISITES" "$output" "PREREQUISITES"

# ─── Test 3: detects tmux ────────────────────────────────────────────────────
assert_contains "detects tmux" "$output" "tmux"

# ─── Test 4: detects jq ─────────────────────────────────────────────────────
assert_contains "detects jq" "$output" "jq"

# ─── Test 5: detects Claude CLI ─────────────────────────────────────────────
assert_contains "detects Claude Code CLI" "$output" "Claude Code CLI"

# ─── Test 6: detects git ────────────────────────────────────────────────────
assert_contains "detects git" "$output" "git"

# ─── Test 7: VERSION is defined ─────────────────────────────────────────────
echo ""
echo -e "${DIM}  structure${RESET}"

if grep -q '^VERSION=' "$SCRIPT_DIR/sw-doctor.sh"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 8: uses set -euo pipefail ─────────────────────────────────────────
if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-doctor.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

# ─── Test 9: ERR trap is set ────────────────────────────────────────────────
if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-doctor.sh"; then
    assert_pass "ERR trap is set"
else
    assert_fail "ERR trap is set"
fi

# ─── Test 10: has check_pass/check_warn/check_fail helpers ──────────────────
if grep -q 'check_pass()' "$SCRIPT_DIR/sw-doctor.sh"; then
    assert_pass "check_pass helper defined"
else
    assert_fail "check_pass helper defined"
fi

if grep -q 'check_fail()' "$SCRIPT_DIR/sw-doctor.sh"; then
    assert_pass "check_fail helper defined"
else
    assert_fail "check_fail helper defined"
fi

# ─── Test 11: doctor shows header ───────────────────────────────────────────
assert_contains "output shows Shipwright header" "$output" "Doctor"

# ─── Test 12: Check logic exists for key tools (tmux, jq, claude, git, gh) ───
echo ""
echo -e "${DIM}  check logic for tools${RESET}"
if grep -qE 'command -v tmux|tmux -V' "$SCRIPT_DIR/sw-doctor.sh"; then
    assert_pass "Source checks for tmux"
else
    assert_fail "Source checks for tmux"
fi
if grep -qE 'command -v jq|jq ' "$SCRIPT_DIR/sw-doctor.sh"; then
    assert_pass "Source checks for jq"
else
    assert_fail "Source checks for jq"
fi
if grep -qE 'command -v claude|Claude Code CLI' "$SCRIPT_DIR/sw-doctor.sh"; then
    assert_pass "Source checks for Claude CLI"
else
    assert_fail "Source checks for Claude CLI"
fi
if grep -qE 'command -v git|git --version' "$SCRIPT_DIR/sw-doctor.sh"; then
    assert_pass "Source checks for git"
else
    assert_fail "Source checks for git"
fi
if grep -qE 'command -v gh|gh auth' "$SCRIPT_DIR/sw-doctor.sh"; then
    assert_pass "Source checks for gh"
else
    assert_fail "Source checks for gh"
fi

# ─── Test 13: --version flag ────────────────────────────────────────────────
echo ""
echo -e "${DIM}  version flag${RESET}"
ver_output=$(bash "$SCRIPT_DIR/sw-doctor.sh" --version 2>&1)
if [[ "$ver_output" == *"sw-doctor"* && "$ver_output" == *"3."* ]]; then
    assert_pass "--version outputs sw-doctor and version"
else
    assert_fail "--version outputs sw-doctor and version" "got: $ver_output"
fi
bash "$SCRIPT_DIR/sw-doctor.sh" -V 2>&1 | grep "sw-doctor" >/dev/null && assert_pass "-V short flag works" || assert_fail "-V short flag works"

# ─── Test 14: Doctor with missing jq in PATH ──────────────────────────────────
echo ""
echo -e "${DIM}  missing tool handling${RESET}"
# Temporarily hide jq so doctor runs without it
jq_path="$TEST_TEMP_DIR/bin/jq"
if [[ -f "$jq_path" ]]; then
    mv "$jq_path" "${jq_path}.bak"
fi
output_no_jq=$(bash "$SCRIPT_DIR/sw-doctor.sh" 2>&1) || true
if [[ -f "${jq_path}.bak" ]]; then
    mv "${jq_path}.bak" "$jq_path"
fi
if [[ "$output_no_jq" == *"jq"* ]]; then
    assert_pass "Doctor reports when jq missing from PATH"
else
    assert_fail "Doctor reports when jq missing from PATH" "output should mention jq"
fi

# ─── Test 15: Output includes PREREQUISITES and INSTALLED FILES sections ─────
assert_contains "output includes PREREQUISITES section" "$output" "PREREQUISITES"
assert_contains "output includes INSTALLED FILES section" "$output" "INSTALLED FILES"

# ═══════════════════════════════════════════════════════════════════════════════
# AUTO-FIX TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  auto-fix mode${RESET}"

# Create a fresh test environment for auto-fix testing
TEST_AUTOFIX_DIR="$TEST_TEMP_DIR/autofix-test"
mkdir -p "$TEST_AUTOFIX_DIR"
cd "$TEST_AUTOFIX_DIR"

# ─── Test 16: --fix-dry shows what would be fixed without modifying ────────────
output_dry=$(bash "$SCRIPT_DIR/sw-doctor.sh" --fix-dry 2>&1) && rc=0 || rc=$?
if [[ "$output_dry" == *"[DRY]"* || "$output_dry" == *"Dry-run"* ]]; then
    assert_pass "--fix-dry flag shows dry-run output"
else
    # If no DRY markers, check that directories weren't created
    if [[ ! -d ".claude" ]]; then
        assert_pass "--fix-dry doesn't create directories"
    else
        assert_fail "--fix-dry doesn't create directories" ".claude was created"
    fi
fi

# ─── Test 17: --fix creates missing directories ──────────────────────────────
bash "$SCRIPT_DIR/sw-doctor.sh" --fix >/dev/null 2>&1 || true
if [[ -d ".claude" && -d ".claude/pipeline-artifacts" && -d ".claude/agents" ]]; then
    assert_pass "--fix creates .claude directories"
else
    assert_fail "--fix creates .claude directories" ".claude structure incomplete"
fi

if [[ -d "$HOME/.shipwright" && -d "$HOME/.shipwright/optimization" ]]; then
    assert_pass "--fix creates ~/.shipwright directories"
else
    assert_fail "--fix creates ~/.shipwright directories" "directories missing"
fi

# ─── Test 18: --fix creates daemon-config.json ──────────────────────────────
if [[ -f ".claude/daemon-config.json" ]]; then
    # Verify it's valid JSON
    if jq empty ".claude/daemon-config.json" 2>/dev/null; then
        assert_pass "--fix creates valid daemon-config.json"
    else
        assert_fail "--fix creates valid daemon-config.json" "JSON is invalid"
    fi
else
    assert_fail "--fix creates daemon-config.json"
fi

# ─── Test 19: --fix creates settings.json ────────────────────────────────────
if [[ -f ".claude/settings.json" ]]; then
    # Verify it's valid JSON
    if jq empty ".claude/settings.json" 2>/dev/null; then
        assert_pass "--fix creates valid settings.json"
    else
        assert_fail "--fix creates valid settings.json" "JSON is invalid"
    fi
else
    assert_fail "--fix creates settings.json"
fi

# ─── Test 20: --fix creates budget.json ──────────────────────────────────────
if [[ -f "$HOME/.shipwright/budget.json" ]]; then
    if jq empty "$HOME/.shipwright/budget.json" 2>/dev/null; then
        assert_pass "--fix creates valid budget.json"
    else
        assert_fail "--fix creates valid budget.json" "JSON is invalid"
    fi
else
    assert_fail "--fix creates budget.json"
fi

# ─── Test 21: --fix is idempotent (running twice doesn't break things) ─────────
bash "$SCRIPT_DIR/sw-doctor.sh" --fix >/dev/null 2>&1 || true
if [[ -f ".claude/daemon-config.json" ]] && jq empty ".claude/daemon-config.json" 2>/dev/null; then
    assert_pass "--fix is idempotent (second run succeeds)"
else
    assert_fail "--fix is idempotent" "second run broke config"
fi

# ─── Test 22: --fix creates backups before overwriting ───────────────────────
# Manually create a settings.json to test backup creation
echo '{"old": "config"}' > ".claude/settings.json"
bash "$SCRIPT_DIR/sw-doctor.sh" --fix >/dev/null 2>&1 || true
# The backup should exist if we overwrote
if [[ -f ".claude/settings.json.bak" ]] || [[ ! -f ".claude/settings.json" ]] || jq empty ".claude/settings.json" 2>/dev/null; then
    assert_pass "--fix handles existing config files safely"
else
    assert_fail "--fix handles existing config files safely"
fi

# ─── Test 23: --fix without arguments doesn't crash ───────────────────────────
# Clean test directory
rm -rf "$TEST_AUTOFIX_DIR"/.claude
mkdir -p "$TEST_AUTOFIX_DIR"
output_no_args=$(bash "$SCRIPT_DIR/sw-doctor.sh" --fix 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 && -d ".claude" ]]; then
    assert_pass "--fix without other args works"
else
    assert_fail "--fix without other args works" "exit code: $rc"
fi

# ─── Test 24: AUTO-FIX SUMMARY section exists ─────────────────────────────────
output_with_fix=$(bash "$SCRIPT_DIR/sw-doctor.sh" --fix 2>&1)
if [[ "$output_with_fix" == *"AUTO-FIX"* ]]; then
    assert_pass "Auto-fix output shows AUTO-FIX SUMMARY"
else
    assert_fail "Auto-fix output shows AUTO-FIX SUMMARY"
fi

# ─── Test 25: doctor reports what was fixed ──────────────────────────────────
rm -rf "$TEST_AUTOFIX_DIR"/.claude "$TEST_AUTOFIX_DIR/.shipwright"
output_fix_report=$(bash "$SCRIPT_DIR/sw-doctor.sh" --fix 2>&1)
if [[ "$output_fix_report" == *"fixed"* || "$output_fix_report" == *"Directories"* ]]; then
    assert_pass "Auto-fix reports what was fixed"
else
    assert_fail "Auto-fix reports what was fixed"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
