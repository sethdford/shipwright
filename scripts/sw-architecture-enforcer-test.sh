#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright architecture-enforcer test — Validate architecture model     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/memory"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls shasum; do
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
    config) echo "git@github.com:test/repo.git" ;;
    log) echo "abc1234 Mock commit" ;;
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

    # Copy script under test into mock repo with a stub intelligence
    cp "$SCRIPT_DIR/sw-architecture-enforcer.sh" "$TEST_TEMP_DIR/repo/scripts/"

    # Create a stub sw-intelligence.sh
    cat > "$TEST_TEMP_DIR/repo/scripts/sw-intelligence.sh" <<'STUBEOF'
#!/usr/bin/env bash
_intelligence_call_claude() { echo '{"layers":["core","scripts"],"patterns":["pipeline"],"conventions":["bash3.2"],"dependencies":["jq"]}'; return 0; }
_intelligence_md5() { echo "mock-md5"; }
STUBEOF

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
    if [[ -n "$detail" ]]; then echo -e "    ${DIM}${detail}${RESET}"; fi
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

# ─── Setup ────────────────────────────────────────────────────────────────────
setup_env

SRC="$SCRIPT_DIR/sw-architecture-enforcer.sh"
MOCK_SRC="$TEST_TEMP_DIR/repo/scripts/sw-architecture-enforcer.sh"

echo ""
print_test_header "shipwright architecture-enforcer test"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# ─── 1. Script Safety ────────────────────────────────────────────────────────
echo -e "${BOLD}  Script Safety${RESET}"

if grep -qF 'set -euo pipefail' "$SRC" 2>/dev/null; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

if grep -qF 'trap' "$SRC" 2>/dev/null; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

if grep -qE 'if \[\[.*BASH_SOURCE' "$SRC" 2>/dev/null; then
    assert_pass "Source guard pattern (if/then/fi)"
else
    assert_fail "Source guard pattern (if/then/fi)"
fi

if grep -qE '^VERSION=' "$SRC" 2>/dev/null; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

echo ""

# ─── 2. Help ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}  Help Output${RESET}"

HELP_OUT=$(bash "$SRC" help 2>&1) || true

assert_contains "help exits 0 and contains USAGE" "$HELP_OUT" "USAGE"
assert_contains "help lists 'build' subcommand" "$HELP_OUT" "build"
assert_contains "help lists 'validate' subcommand" "$HELP_OUT" "validate"
assert_contains "help lists 'evolve' subcommand" "$HELP_OUT" "evolve"
assert_contains "help mentions architecture_enabled flag" "$HELP_OUT" "architecture_enabled"

HELP2=$(bash "$SRC" --help 2>&1) || true
assert_contains "--help alias works" "$HELP2" "USAGE"

HELP3=$(bash "$SRC" -h 2>&1) || true
assert_contains "-h alias works" "$HELP3" "USAGE"

echo ""

# ─── 3. Error Handling ───────────────────────────────────────────────────────
echo -e "${BOLD}  Error Handling${RESET}"

if bash "$SRC" nonexistent-cmd 2>/dev/null; then
    assert_fail "Unknown command exits non-zero"
else
    assert_pass "Unknown command exits non-zero"
fi

echo ""

# ─── 4. Build subcommand ────────────────────────────────────────────────────
echo -e "${BOLD}  Build Subcommand${RESET}"

# build with architecture disabled (no config) should return "{}"
OUT=$(bash "$MOCK_SRC" build 2>/dev/null) || true
assert_contains "build disabled returns empty JSON object" "$OUT" "{}"

# Enable architecture and build
cat > "$TEST_TEMP_DIR/repo/.claude/daemon-config.json" <<'EOF'
{"intelligence":{"architecture_enabled":true}}
EOF

OUT=$(bash "$MOCK_SRC" build "$TEST_TEMP_DIR/repo" 2>/dev/null) || true

# Should produce JSON with layers array
if echo "$OUT" | jq -e '.layers' >/dev/null 2>&1; then
    assert_pass "build with enabled returns model with layers"
else
    assert_fail "build with enabled returns model with layers" "$OUT"
fi

if echo "$OUT" | jq -e '.patterns' >/dev/null 2>&1; then
    assert_pass "build model contains patterns array"
else
    assert_fail "build model contains patterns array" "$OUT"
fi

if echo "$OUT" | jq -e '.conventions' >/dev/null 2>&1; then
    assert_pass "build model contains conventions array"
else
    assert_fail "build model contains conventions array" "$OUT"
fi

echo ""

# ─── 5. Validate subcommand ─────────────────────────────────────────────────
echo -e "${BOLD}  Validate Subcommand${RESET}"

# validate with disabled returns "[]"
cat > "$TEST_TEMP_DIR/repo/.claude/daemon-config.json" <<'EOF'
{"intelligence":{"architecture_enabled":false}}
EOF
OUT=$(bash "$MOCK_SRC" validate "some diff" 2>/dev/null) || true
assert_contains "validate disabled returns empty array" "$OUT" "[]"

# validate without diff arg exits non-zero
cat > "$TEST_TEMP_DIR/repo/.claude/daemon-config.json" <<'EOF'
{"intelligence":{"architecture_enabled":true}}
EOF
if bash "$MOCK_SRC" validate 2>/dev/null; then
    assert_fail "validate without diff arg exits non-zero"
else
    assert_pass "validate without diff arg exits non-zero"
fi

# validate without model file returns "[]"
OUT=$(bash "$MOCK_SRC" validate "some diff" "/nonexistent/model.json" 2>/dev/null) || true
assert_contains "validate without model file returns empty array" "$OUT" "[]"

echo ""

# ─── 6. Evolve subcommand ───────────────────────────────────────────────────
echo -e "${BOLD}  Evolve Subcommand${RESET}"

# evolve with disabled exits gracefully
cat > "$TEST_TEMP_DIR/repo/.claude/daemon-config.json" <<'EOF'
{"intelligence":{"architecture_enabled":false}}
EOF
if bash "$MOCK_SRC" evolve 2>/dev/null; then
    assert_pass "evolve disabled exits 0"
else
    assert_fail "evolve disabled exits 0"
fi

# evolve without model file exits gracefully
cat > "$TEST_TEMP_DIR/repo/.claude/daemon-config.json" <<'EOF'
{"intelligence":{"architecture_enabled":true}}
EOF
if bash "$MOCK_SRC" evolve "/nonexistent/model.json" 2>/dev/null; then
    assert_pass "evolve without model exits 0"
else
    assert_fail "evolve without model exits 0"
fi

echo ""

# ─── 7. Model storage ───────────────────────────────────────────────────────
echo -e "${BOLD}  Model Storage${RESET}"

# After a build, the model should be stored in memory dir
cat > "$TEST_TEMP_DIR/repo/.claude/daemon-config.json" <<'EOF'
{"intelligence":{"architecture_enabled":true}}
EOF
bash "$MOCK_SRC" build "$TEST_TEMP_DIR/repo" >/dev/null 2>&1 || true

# Check that some architecture.json was created under memory dir
ARCH_FILES=$(find "$HOME/.shipwright/memory" -name "architecture.json" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ARCH_FILES" -gt 0 ]]; then
    assert_pass "build stores model in ~/.shipwright/memory/"
else
    assert_fail "build stores model in ~/.shipwright/memory/"
fi

# Verify the model file is valid JSON
ARCH_FILE=$(find "$HOME/.shipwright/memory" -name "architecture.json" 2>/dev/null | head -1)
if [[ -n "$ARCH_FILE" ]] && jq empty "$ARCH_FILE" 2>/dev/null; then
    assert_pass "Stored model is valid JSON"
else
    assert_fail "Stored model is valid JSON"
fi

echo ""

# ─── 8. Event emission ──────────────────────────────────────────────────────
echo -e "${BOLD}  Event Emission${RESET}"

rm -f "$HOME/.shipwright/events.jsonl"

# Source the mock script to get emit_event
# shellcheck disable=SC1090
source "$MOCK_SRC"

emit_event "architecture.test" "layers=3"

if [[ -f "$HOME/.shipwright/events.jsonl" ]]; then
    assert_pass "emit_event creates events.jsonl"
else
    assert_fail "emit_event creates events.jsonl"
fi

LAST_LINE=$(tail -1 "$HOME/.shipwright/events.jsonl")
if echo "$LAST_LINE" | jq empty 2>/dev/null; then
    assert_pass "emit_event writes valid JSON"
else
    assert_fail "emit_event writes valid JSON" "$LAST_LINE"
fi

assert_contains "Event contains type field" "$LAST_LINE" '"type":"architecture.test"'

echo ""

# ─── Results ─────────────────────────────────────────────────────────────────
echo ""
echo ""
print_test_results
