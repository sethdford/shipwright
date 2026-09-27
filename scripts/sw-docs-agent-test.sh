#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright docs-agent test — Validate documentation agent operations    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/docs-agent"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/sqlite3" <<'MOCK'
#!/usr/bin/env bash
echo ""
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/sqlite3"
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        else echo "abc1234"; fi ;;
    diff) echo "scripts/sw-test.sh" ;;
    log) echo "abc1234 fix: something" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"
    # Mock wc to return numbers
    cat > "$TEST_TEMP_DIR/bin/stat" <<'MOCK'
#!/usr/bin/env bash
# Return a mock modification time
if [[ "${1:-}" == "-c" ]]; then
    echo "1700000000"
elif [[ "${1:-}" == "-f" ]]; then
    echo "1700000000"
else
    /usr/bin/stat "$@"
fi
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/stat"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true

    # Create mock scripts and CLAUDE.md for coverage tests
    for name in sw-pipeline sw-daemon sw-loop sw-status sw-doctor; do
        cat > "$TEST_TEMP_DIR/repo/scripts/${name}.sh" <<SCRIPT
#!/usr/bin/env bash
# ║  ${name} — Mock script for testing
VERSION="3.3.0"
show_help() { echo "Usage: ${name}"; }
SCRIPT
    done

    cat > "$TEST_TEMP_DIR/repo/.claude/CLAUDE.md" <<'DOC'
# Test CLAUDE.md
pipeline and daemon are documented here.
<!-- AUTO:test-section -->
test content
<!-- /AUTO:test-section -->
DOC

    cat > "$TEST_TEMP_DIR/repo/README.md" <<'DOC'
# Test README
<!-- AUTO:core-scripts -->
test
<!-- /AUTO:core-scripts -->
DOC
}

trap cleanup_test_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; local _count; _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true; if [[ "${_count:-0}" -gt 0 ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
echo ""
print_test_header "Shipwright Docs Agent Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# Override REPO_DIR for the script
export REPO_DIR="$TEST_TEMP_DIR/repo"

# ─── Test 1: Help ────────────────────────────────────────────────────
echo -e "${BOLD}  Help${RESET}"
output=$(bash "$SCRIPT_DIR/sw-docs-agent.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ─────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-docs-agent.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "USAGE"

# ─── Test 3: Unknown command ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-docs-agent.sh" nonexistent 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: Coverage shows metrics ─────────────────────────────────
echo -e "${BOLD}  Coverage${RESET}"
output=$(bash "$SCRIPT_DIR/sw-docs-agent.sh" coverage 2>&1) || true
assert_contains "coverage shows header" "$output" "coverage"
assert_contains "coverage shows total scripts" "$output" "Total Scripts"

# ─── Test 5: API reference generation ────────────────────────────────
echo -e "${BOLD}  API Reference${RESET}"
api_file="$TEST_TEMP_DIR/api-ref.md"
output=$(bash "$SCRIPT_DIR/sw-docs-agent.sh" api "$api_file" 2>&1) || true
assert_contains "api generation succeeds" "$output" "API reference generated"
if [[ -f "$api_file" ]]; then
    api_content=$(cat "$api_file")
    assert_contains "api file has title" "$api_content" "API Reference"
else
    assert_fail "api file has title" "file not created"
fi

# ─── Test 6: Wiki generation ─────────────────────────────────────────
echo -e "${BOLD}  Wiki${RESET}"
wiki_dir="$TEST_TEMP_DIR/wiki-out"
output=$(bash "$SCRIPT_DIR/sw-docs-agent.sh" wiki "$wiki_dir" 2>&1) || true
assert_contains "wiki generation succeeds" "$output" "Wiki generated"
if [[ -d "$wiki_dir" ]]; then
    assert_pass "wiki directory created"
else
    assert_fail "wiki directory created" "dir not found"
fi

# ─── Test 7: Scan for gaps ──────────────────────────────────────────
echo -e "${BOLD}  Scan${RESET}"
output=$(bash "$SCRIPT_DIR/sw-docs-agent.sh" scan 2>&1) || true
assert_contains "scan shows scanning" "$output" "Scanning"

# ─── Test 8: Sync updates docs ──────────────────────────────────────
echo -e "${BOLD}  Sync${RESET}"
output=$(bash "$SCRIPT_DIR/sw-docs-agent.sh" sync 2>&1) || true
assert_contains "sync shows sync complete" "$output" "sync complete"

# ─── Test 9: Impact analysis ────────────────────────────────────────
echo -e "${BOLD}  Impact${RESET}"
output=$(bash "$SCRIPT_DIR/sw-docs-agent.sh" impact "HEAD~1..HEAD" 2>&1) || true
assert_contains "impact shows analysis" "$output" "documentation impact"

# ─── Test 10: Agent home dir created ─────────────────────────────────
echo -e "${BOLD}  State${RESET}"
if [[ -d "$HOME/.shipwright/docs-agent" ]]; then
    assert_pass "docs-agent home directory exists"
else
    assert_fail "docs-agent home directory exists" "dir not found"
fi

echo ""
echo ""
print_test_results
