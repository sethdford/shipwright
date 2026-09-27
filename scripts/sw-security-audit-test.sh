#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright security-audit test — Security auditing tests                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock npm
    cat > "$TEST_TEMP_DIR/bin/npm" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    list) echo "" ;;
    audit) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/npm"

    # Create a clean script (no secrets)
    cat > "$TEST_TEMP_DIR/repo/scripts/clean.sh" <<'CLEAN'
#!/usr/bin/env bash
set -euo pipefail
info() { echo "hello"; }
CLEAN

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
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

echo ""
print_test_header "Shipwright Security Audit Tests"
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
cat > "$TEST_TEMP_DIR/run_sourced.sh" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$SCRIPT_DIR"
source "\$SCRIPT_DIR/sw-security-audit.sh"
REPO_DIR="$TEST_TEMP_DIR/repo"
"\$@"
WRAPPER
chmod +x "$TEST_TEMP_DIR/run_sourced.sh"

bash "$TEST_TEMP_DIR/run_sourced.sh" scan_secrets > "$TEST_TEMP_DIR/secrets_output.txt" 2>&1 || true
output=$(cat "$TEST_TEMP_DIR/secrets_output.txt")
assert_contains "secrets scan completes on clean repo" "$output" "No obvious hardcoded secrets"

# ─── Test 6: License scan runs ───────────────────────────────────────────────
bash "$TEST_TEMP_DIR/run_sourced.sh" scan_licenses > "$TEST_TEMP_DIR/license_output.txt" 2>&1 || true
output=$(cat "$TEST_TEMP_DIR/license_output.txt")
assert_contains "license scan completes" "$output" "License compliance check complete"

# ─── Test 7: SBOM generation creates file ────────────────────────────────────
bash "$TEST_TEMP_DIR/run_sourced.sh" generate_sbom > /dev/null 2>&1 || true
if [[ -f "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/sbom.json" ]]; then
    assert_pass "SBOM file created"
else
    assert_fail "SBOM file created"
fi

# ─── Test 8: SBOM is valid JSON ──────────────────────────────────────────────
if jq '.' "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/sbom.json" >/dev/null 2>&1; then
    assert_pass "SBOM is valid JSON"
else
    assert_fail "SBOM is valid JSON"
fi

# ─── Test 9: Permissions audit runs ──────────────────────────────────────────
bash "$TEST_TEMP_DIR/run_sourced.sh" audit_permissions > "$TEST_TEMP_DIR/perm_output.txt" 2>&1 || true
output=$(cat "$TEST_TEMP_DIR/perm_output.txt")
assert_contains "permissions audit completes" "$output" "Permissions audit complete"

# ─── Test 10: Compliance report generates file ───────────────────────────────
bash "$TEST_TEMP_DIR/run_sourced.sh" generate_compliance_report > /dev/null 2>&1 || true
if [[ -f "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/security-compliance-report.md" ]]; then
    assert_pass "compliance report file created"
else
    assert_fail "compliance report file created"
fi

# ─── Test 11: VERSION is defined ─────────────────────────────────────────────
version_line=$(grep "^VERSION=" "$SCRIPT_DIR/sw-security-audit.sh" | head -1)
assert_contains "VERSION is defined" "$version_line" "VERSION="

echo ""
echo ""
print_test_results
