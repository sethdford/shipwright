#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright templates test — Validate team template browser              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/templates"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls; do
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
# Tests
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "shipwright templates test suite"
echo ""

setup_env

# ─── 1. Script safety ────────────────────────────────────────────────────────

echo -e "${BOLD}  Script Safety${RESET}"

if grep -q 'set -euo pipefail' "$SCRIPT_DIR/sw-templates.sh"; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

if grep -q "bootstrap.sh" "$SCRIPT_DIR/sw-templates.sh" || grep "trap.*ERR" "$SCRIPT_DIR/sw-templates.sh" >/dev/null; then
    assert_pass "ERR trap present (via bootstrap or inline)"
else
    assert_fail "ERR trap present (via bootstrap or inline)"
fi

echo ""

# ─── 2. VERSION ──────────────────────────────────────────────────────────────

echo -e "${BOLD}  Version${RESET}"

if grep -q '^VERSION=' "$SCRIPT_DIR/sw-templates.sh"; then
    assert_pass "VERSION variable defined at top"
else
    assert_fail "VERSION variable defined at top"
fi

echo ""

# ─── 3. Help ─────────────────────────────────────────────────────────────────

echo -e "${BOLD}  Help${RESET}"

output=$(bash "$SCRIPT_DIR/sw-templates.sh" help 2>&1) || true
assert_contains "help contains USAGE" "$output" "USAGE"
assert_contains "help contains list subcommand" "$output" "list"
assert_contains "help contains show subcommand" "$output" "show"
assert_contains "help mentions TEMPLATE LOCATIONS" "$output" "TEMPLATE LOCATIONS"
assert_contains "help mentions CREATING TEMPLATES" "$output" "CREATING TEMPLATES"

# --help flag
output=$(bash "$SCRIPT_DIR/sw-templates.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "USAGE"

echo ""

# ─── 4. Unknown subcommand ──────────────────────────────────────────────────

echo -e "${BOLD}  Error Handling${RESET}"

if bash "$SCRIPT_DIR/sw-templates.sh" nonexistent_cmd 2>/dev/null; then
    assert_fail "unknown subcommand exits non-zero"
else
    assert_pass "unknown subcommand exits non-zero"
fi

output=$(bash "$SCRIPT_DIR/sw-templates.sh" nonexistent_cmd 2>&1) || true
assert_contains "unknown subcommand shows error" "$output" "Unknown subcommand"

echo ""

# ─── 5. List subcommand with built-in templates ─────────────────────────────

echo -e "${BOLD}  List Subcommand${RESET}"

# The script reads from tmux/templates/ in the repo — those exist
output=$(bash "$SCRIPT_DIR/sw-templates.sh" list 2>&1) || true
assert_contains "list header shows Team Templates" "$output" "Team Templates"

echo ""

# ─── 6. List with custom template ───────────────────────────────────────────

echo -e "${BOLD}  Custom Templates${RESET}"

# Create a custom template in the user templates dir
cat > "$TEST_TEMP_DIR/home/.shipwright/templates/my-custom.json" <<'TMPL'
{
  "name": "my-custom",
  "description": "A test custom template",
  "agents": [
    {"name": "builder", "role": "Builds stuff", "focus": "src/"}
  ],
  "layout": "tiled"
}
TMPL

output=$(bash "$SCRIPT_DIR/sw-templates.sh" list 2>&1) || true
assert_contains "list shows custom template name" "$output" "my-custom"
assert_contains "list shows custom template description" "$output" "A test custom template"

echo ""

# ─── 7. Show subcommand ────────────────────────────────────────────────────

echo -e "${BOLD}  Show Subcommand${RESET}"

output=$(bash "$SCRIPT_DIR/sw-templates.sh" show my-custom 2>&1) || true
assert_contains "show displays template name" "$output" "my-custom"
assert_contains "show displays description" "$output" "A test custom template"
assert_contains "show displays Agents header" "$output" "Agents"
assert_contains "show displays agent name" "$output" "builder"

echo ""

# ─── 8. Show without name errors ────────────────────────────────────────────

echo -e "${BOLD}  Show Without Name${RESET}"

if bash "$SCRIPT_DIR/sw-templates.sh" show 2>/dev/null; then
    assert_fail "show without name exits non-zero"
else
    assert_pass "show without name exits non-zero"
fi

output=$(bash "$SCRIPT_DIR/sw-templates.sh" show 2>&1) || true
assert_contains "show without name shows error" "$output" "Template name required"

echo ""

# ─── 9. Show with nonexistent template ──────────────────────────────────────

echo -e "${BOLD}  Show Nonexistent Template${RESET}"

if bash "$SCRIPT_DIR/sw-templates.sh" show nonexistent-template 2>/dev/null; then
    assert_fail "show nonexistent template exits non-zero"
else
    assert_pass "show nonexistent template exits non-zero"
fi

output=$(bash "$SCRIPT_DIR/sw-templates.sh" show nonexistent-template 2>&1) || true
assert_contains "show nonexistent shows not found" "$output" "not found"

echo ""

# ─── 10. Aliases (ls, info) ─────────────────────────────────────────────────

echo -e "${BOLD}  Subcommand Aliases${RESET}"

# ls is alias for list
output=$(bash "$SCRIPT_DIR/sw-templates.sh" ls 2>&1) || true
assert_contains "ls alias works (shows Team Templates)" "$output" "Team Templates"

# info is alias for show
output=$(bash "$SCRIPT_DIR/sw-templates.sh" info my-custom 2>&1) || true
assert_contains "info alias works (shows template)" "$output" "my-custom"

echo ""

# ─── 11. Template directories ──────────────────────────────────────────────

echo -e "${BOLD}  Template Directories${RESET}"

source_content=$(cat "$SCRIPT_DIR/sw-templates.sh")
assert_contains "defines USER_TEMPLATES_DIR" "$source_content" "USER_TEMPLATES_DIR"
assert_contains "uses ~/.shipwright/templates" "$source_content" ".shipwright/templates"
assert_contains "uses tmux/templates for built-in" "$source_content" "tmux/templates"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
