#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright developer-simulation test — Validate multi-persona           ║
# ║  developer simulation with mock Claude responses and config checks.     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls bc; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
    done

    # Copy script under test and intelligence dependency
    cp "$SCRIPT_DIR/sw-developer-simulation.sh" "$TEST_TEMP_DIR/repo/scripts/"
    cp "$SCRIPT_DIR/sw-intelligence.sh" "$TEST_TEMP_DIR/repo/scripts/"

    # Create compat.sh stub and copy helpers for color/output
    mkdir -p "$TEST_TEMP_DIR/repo/scripts/lib"
    touch "$TEST_TEMP_DIR/repo/scripts/lib/compat.sh"
    [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEST_TEMP_DIR/repo/scripts/lib/"

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "abc1234"; fi ;;
    config)
        if [[ "${2:-}" == "--get" && "${3:-}" == "remote.origin.url" ]]; then
            echo "https://github.com/test/repo.git"
        fi ;;
    remote) echo "git@github.com:test/repo.git" ;;
    log) echo "abc1234 Mock commit" ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock shasum for intelligence
    cat > "$TEST_TEMP_DIR/bin/shasum" <<'SHAEOF'
#!/usr/bin/env bash
echo "abcdef123456  -"
SHAEOF
    chmod +x "$TEST_TEMP_DIR/bin/shasum"

    # Mock md5
    cat > "$TEST_TEMP_DIR/bin/md5" <<'MD5EOF'
#!/usr/bin/env bash
echo "abcdef123456"
MD5EOF
    chmod +x "$TEST_TEMP_DIR/bin/md5"

    # Mock claude, gh, tmux
    for mock in gh claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    # Daemon config with simulation enabled
    cat > "$TEST_TEMP_DIR/repo/.claude/daemon-config.json" <<'EOF'
{
    "intelligence": {
        "enabled": true,
        "simulation_enabled": true
    }
}
EOF

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

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    local _count
    _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true
    if [[ "${_count:-0}" -gt 0 ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

setup_env

SUT="$TEST_TEMP_DIR/repo/scripts/sw-developer-simulation.sh"

echo ""
print_test_header "shipwright developer-simulation test"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# ─── 1. Script Safety ────────────────────────────────────────────────────────
echo -e "${BOLD}Script Safety${RESET}"

_src=$(cat "$SCRIPT_DIR/sw-developer-simulation.sh")

_count=$(printf '%s\n' "$_src" | grep -cF 'set -euo pipefail' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

_count=$(printf '%s\n' "$_src" | grep -cF 'trap' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

_count=$(printf '%s\n' "$_src" | grep -c 'if \[\[ "\${BASH_SOURCE\[0\]}" == "\$0" \]\]' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "source guard uses if/then/fi pattern"
else
    assert_fail "source guard uses if/then/fi pattern"
fi

echo ""

# ─── 2. VERSION ──────────────────────────────────────────────────────────────
echo -e "${BOLD}Version${RESET}"

_count=$(printf '%s\n' "$_src" | grep -c '^VERSION=' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

echo ""

# ─── 3. Help Output ─────────────────────────────────────────────────────────
echo -e "${BOLD}Help Output${RESET}"

help_out=$(bash "$SUT" help 2>&1) || true
assert_contains "help contains USAGE" "$help_out" "USAGE"
assert_contains "help contains review subcommand" "$help_out" "review"
assert_contains "help contains address subcommand" "$help_out" "address"
assert_contains "help contains PERSONAS" "$help_out" "PERSONAS"
assert_contains "help contains simulation_enabled" "$help_out" "simulation_enabled"

# --help flag also works
help_flag_out=$(bash "$SUT" --help 2>&1) || true
assert_contains "--help flag works" "$help_flag_out" "USAGE"

echo ""

# ─── 4. Unknown Command ─────────────────────────────────────────────────────
echo -e "${BOLD}Error Handling${RESET}"

unknown_out=$(bash "$SUT" boguscmd 2>&1) || unknown_rc=$?
assert_eq "unknown command exits non-zero" "1" "${unknown_rc:-0}"
assert_contains "unknown command mentions error" "$unknown_out" "Unknown"

echo ""

# ─── 5. Review Subcommand ───────────────────────────────────────────────────
echo -e "${BOLD}Review Subcommand${RESET}"

# Review without simulation disabled should warn
cat > "$TEST_TEMP_DIR/repo/.claude/daemon-config.json" <<'EOF'
{
    "intelligence": {
        "enabled": true,
        "simulation_enabled": false
    }
}
EOF

review_disabled=$(bash "$SUT" review "mock diff" "mock description" 2>&1) || true
assert_contains "review warns when disabled" "$review_disabled" "simulation disabled"
assert_contains "review returns empty JSON array when disabled" "$review_disabled" "[]"

echo ""

# ─── 6. Address Subcommand ──────────────────────────────────────────────────
echo -e "${BOLD}Address Subcommand${RESET}"

# Re-enable simulation
cat > "$TEST_TEMP_DIR/repo/.claude/daemon-config.json" <<'EOF'
{
    "intelligence": {
        "enabled": true,
        "simulation_enabled": true
    }
}
EOF

# Address with empty objections should succeed
address_out=$(bash "$SUT" address "[]" 2>&1) || true
assert_contains "address with no objections succeeds" "$address_out" "No objections"
assert_contains "address returns empty JSON" "$address_out" "[]"

echo ""

# ─── 7. Persona Definitions ─────────────────────────────────────────────────
echo -e "${BOLD}Persona Definitions${RESET}"

assert_contains "security persona defined" "$_src" "security"
assert_contains "performance persona defined" "$_src" "performance"
assert_contains "maintainability persona defined" "$_src" "maintainability"

echo ""

# ─── 8. Configuration ───────────────────────────────────────────────────────
echo -e "${BOLD}Configuration${RESET}"

assert_contains "SIMULATION_MAX_ROUNDS env var supported" "$_src" "SIMULATION_MAX_ROUNDS"
assert_contains "daemon-config.json checked" "$_src" "daemon-config.json"

echo ""

# ─── 9. Event Emission ──────────────────────────────────────────────────────
echo -e "${BOLD}Event Emission${RESET}"

assert_contains "emits simulation.objection events" "$_src" "simulation.objection"
assert_contains "emits simulation.complete events" "$_src" "simulation.complete"
assert_contains "emits simulation.addressed events" "$_src" "simulation.addressed"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo ""
print_test_results
