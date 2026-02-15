#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright security-audit test — Security auditing tests                ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-security-audit-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.claude/pipeline-artifacts"
    mkdir -p "$TEMP_DIR/repo/.git"
    mkdir -p "$TEMP_DIR/repo/scripts"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock npm
    cat > "$TEMP_DIR/bin/npm" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    list) echo "" ;;
    audit) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/npm"

    # Create a clean script (no secrets)
    cat > "$TEMP_DIR/repo/scripts/clean.sh" <<'CLEAN'
#!/usr/bin/env bash
set -euo pipefail
info() { echo "hello"; }
CLEAN

    export PATH="$TEMP_DIR/bin:$PATH"
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

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

assert_contains_regex() {
    local desc="$1" haystack="$2" pattern="$3"
    if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing pattern: $pattern"
    fi
}

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Security Audit Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: Help output ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-security-audit.sh" help 2>&1) || true
assert_contains "help shows usage text" "$output" "shipwright security-audit"

# ─── Test 2: Help exits 0 ────────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-security-audit.sh" help >/dev/null 2>&1
assert_eq "help exits 0" "0" "$?"

# ─── Test 3: --help flag works ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-security-audit.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "COMMANDS"

# ─── Test 4: Unknown command exits 1 ─────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-security-audit.sh" nonexistent >/dev/null 2>&1; then
    assert_fail "unknown command exits 1"
else
    assert_pass "unknown command exits 1"
fi

# ─── Test 5: Secrets scan on clean repo ──────────────────────────────────────
# Create a wrapper script that overrides REPO_DIR before sourcing
cat > "$TEMP_DIR/run_sourced.sh" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$SCRIPT_DIR"
source "\$SCRIPT_DIR/sw-security-audit.sh"
REPO_DIR="$TEMP_DIR/repo"
"\$@"
WRAPPER
chmod +x "$TEMP_DIR/run_sourced.sh"

bash "$TEMP_DIR/run_sourced.sh" scan_secrets > "$TEMP_DIR/secrets_output.txt" 2>&1 || true
output=$(cat "$TEMP_DIR/secrets_output.txt")
assert_contains "secrets scan completes on clean repo" "$output" "No obvious hardcoded secrets"

# ─── Test 6: License scan runs ───────────────────────────────────────────────
bash "$TEMP_DIR/run_sourced.sh" scan_licenses > "$TEMP_DIR/license_output.txt" 2>&1 || true
output=$(cat "$TEMP_DIR/license_output.txt")
assert_contains "license scan completes" "$output" "License compliance check complete"

# ─── Test 7: SBOM generation creates file ────────────────────────────────────
bash "$TEMP_DIR/run_sourced.sh" generate_sbom > /dev/null 2>&1 || true
if [[ -f "$TEMP_DIR/repo/.claude/pipeline-artifacts/sbom.json" ]]; then
    assert_pass "SBOM file created"
else
    assert_fail "SBOM file created"
fi

# ─── Test 8: SBOM is valid JSON ──────────────────────────────────────────────
if jq '.' "$TEMP_DIR/repo/.claude/pipeline-artifacts/sbom.json" >/dev/null 2>&1; then
    assert_pass "SBOM is valid JSON"
else
    assert_fail "SBOM is valid JSON"
fi

# ─── Test 9: Permissions audit runs ──────────────────────────────────────────
bash "$TEMP_DIR/run_sourced.sh" audit_permissions > "$TEMP_DIR/perm_output.txt" 2>&1 || true
output=$(cat "$TEMP_DIR/perm_output.txt")
assert_contains "permissions audit completes" "$output" "Permissions audit complete"

# ─── Test 10: Compliance report generates file ───────────────────────────────
bash "$TEMP_DIR/run_sourced.sh" generate_compliance_report > /dev/null 2>&1 || true
if [[ -f "$TEMP_DIR/repo/.claude/pipeline-artifacts/security-compliance-report.md" ]]; then
    assert_pass "compliance report file created"
else
    assert_fail "compliance report file created"
fi

# ─── Test 11: VERSION is defined ─────────────────────────────────────────────
version_line=$(grep "^VERSION=" "$SCRIPT_DIR/sw-security-audit.sh" | head -1)
assert_contains "VERSION is defined" "$version_line" "VERSION="

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
