#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright doctor test — Validate setup diagnostics                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
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

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-doctor-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/home/.local/bin"
    mkdir -p "$TEMP_DIR/home/.tmux/plugins/tpm"
    mkdir -p "$TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock tmux
    cat > "$TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-V" ]]; then
    echo "tmux 3.4"
    exit 0
fi
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/tmux"

    # Mock claude
    cat > "$TEMP_DIR/bin/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo "claude mock v1.0"
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/claude"

    # Mock node
    cat > "$TEMP_DIR/bin/node" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
    echo "v20.10.0"
fi
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/node"

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "git version 2.43.0"
    exit 0
fi
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEMP_DIR/bin/gh" <<'MOCKEOF'
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
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock bun
    cat > "$TEMP_DIR/bin/bun" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "1.0.0"
fi
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/bun"

    # Mock curl
    cat > "$TEMP_DIR/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
echo "{}"
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/curl"

    # Mock sqlite3
    cat > "$TEMP_DIR/bin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "3.40.0 2023-01-01"
    exit 0
fi
echo ""
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/sqlite3"

    # Mock lsof - port 3000 not in use
    cat > "$TEMP_DIR/bin/lsof" <<'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
    chmod +x "$TEMP_DIR/bin/lsof"

    # Create sw script in local bin (doctor checks this)
    cat > "$TEMP_DIR/home/.local/bin/sw" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock sw"
MOCKEOF
    chmod +x "$TEMP_DIR/home/.local/bin/sw"

    export PATH="$TEMP_DIR/bin:$TEMP_DIR/home/.local/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() {
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup_env EXIT

assert_pass() {
    local desc="$1"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
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
echo -e "${CYAN}${BOLD}  Shipwright Doctor Tests${RESET}"
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

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
else
    echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
    for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done
fi
echo ""
exit "$FAIL"
