#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fleet-discover test — Validate GitHub org auto-discovery,   ║
# ║  argument parsing, filter logic, and config merge operations.           ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-fleet-discover-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.git"
    mkdir -p "$TEMP_DIR/repo/.claude"
    mkdir -p "$TEMP_DIR/repo/scripts/lib"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEMP_DIR/bin/$cmd"
    done

    # Copy script under test
    cp "$SCRIPT_DIR/sw-fleet-discover.sh" "$TEMP_DIR/repo/scripts/"

    # Create compat.sh stub and copy helpers for color/output
    touch "$TEMP_DIR/repo/scripts/lib/compat.sh"
    [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEMP_DIR/repo/scripts/lib/"

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "abc1234"; fi ;;
    remote) echo "git@github.com:test/repo.git" ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/git"

    # Mock gh — returns mock repo data for fleet discovery
    cat > "$TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    auth)
        echo "Logged in"
        exit 0
        ;;
    api)
        # Return empty JSON array for API calls
        echo "[]"
        exit 0
        ;;
    *)
        echo "mock gh: $*"
        exit 0
        ;;
esac
MOCKEOF
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock claude, tmux
    for mock in claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEMP_DIR/bin/$mock"
        chmod +x "$TEMP_DIR/bin/$mock"
    done

    # Create a fleet config for merge tests
    cat > "$TEMP_DIR/repo/.claude/fleet-config.json" <<'EOF'
{
    "repos": [
        {"path": "existing/repo"}
    ]
}
EOF

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

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

setup_env

SUT="$TEMP_DIR/repo/scripts/sw-fleet-discover.sh"

echo ""
echo -e "${CYAN}${BOLD}  shipwright fleet-discover test${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# ─── 1. Script Safety ────────────────────────────────────────────────────────
echo -e "${BOLD}Script Safety${RESET}"

_src=$(cat "$SCRIPT_DIR/sw-fleet-discover.sh")

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

help_out=$(bash "$SUT" --help 2>&1) || true
assert_contains "help contains USAGE" "$help_out" "USAGE"
assert_contains "help contains --org option" "$help_out" "--org"
assert_contains "help contains --language option" "$help_out" "--language"
assert_contains "help contains --dry-run option" "$help_out" "--dry-run"
assert_contains "help contains --json option" "$help_out" "--json"
assert_contains "help contains --topic option" "$help_out" "--topic"
assert_contains "help contains --exclude-topic option" "$help_out" "--exclude-topic"
assert_contains "help contains --min-activity-days" "$help_out" "--min-activity-days"

echo ""

# ─── 4. Missing Required --org ───────────────────────────────────────────────
echo -e "${BOLD}Argument Validation${RESET}"

missing_org_rc=0
missing_org_out=$(bash "$SUT" 2>&1) || missing_org_rc=$?
assert_eq "missing --org exits non-zero" "1" "$missing_org_rc"
assert_contains "missing --org error message" "$missing_org_out" "Missing required argument"

echo ""

# ─── 5. Unknown Option ──────────────────────────────────────────────────────
echo -e "${BOLD}Error Handling${RESET}"

unknown_rc=0
unknown_out=$(bash "$SUT" --badopt 2>&1) || unknown_rc=$?
assert_eq "unknown option exits non-zero" "1" "$unknown_rc"
assert_contains "unknown option error" "$unknown_out" "Unknown option"

echo ""

# ─── 6. NO_GITHUB Check ─────────────────────────────────────────────────────
echo -e "${BOLD}NO_GITHUB Check${RESET}"

# With NO_GITHUB=true, discovery should fail at auth check
no_gh_rc=0
no_gh_out=$(NO_GITHUB=true bash "$SUT" --org testorg 2>&1) || no_gh_rc=$?
assert_eq "NO_GITHUB blocks discovery" "1" "$no_gh_rc"
assert_contains "NO_GITHUB shows error" "$no_gh_out" "GitHub"

echo ""

# ─── 7. Argument Parsing Variants ───────────────────────────────────────────
echo -e "${BOLD}Argument Parsing${RESET}"

assert_contains "supports --org=value syntax" "$_src" '--org=*'
assert_contains "supports --config=value syntax" "$_src" '--config=*'
assert_contains "supports --language=value syntax" "$_src" '--language=*'
assert_contains "supports --topic=value syntax" "$_src" '--topic=*'

echo ""

# ─── 8. Config Merge Function ───────────────────────────────────────────────
echo -e "${BOLD}Config Merge${RESET}"

# Source the script to test merge_into_config directly
(
    # Run in subshell to avoid polluting our env
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    source "$SUT"

    # Test merge with new repo
    merge_into_config "$TEMP_DIR/repo/.claude/fleet-config.json" "new/repo1" "new/repo2" 2>&1
) > /dev/null 2>&1 || true

# Verify config was updated
if [[ -f "$TEMP_DIR/repo/.claude/fleet-config.json" ]]; then
    config_content=$(cat "$TEMP_DIR/repo/.claude/fleet-config.json")
    assert_contains "merge added new repo" "$config_content" "new/repo1"
    assert_contains "merge preserved existing repo" "$config_content" "existing/repo"
else
    assert_fail "config file exists after merge"
fi

echo ""

# ─── 9. Filter Logic ────────────────────────────────────────────────────────
echo -e "${BOLD}Filter Logic${RESET}"

assert_contains "filters archived repos" "$_src" "archived"
assert_contains "filters disabled repos" "$_src" "disabled"
assert_contains "checks has_issues" "$_src" "has_issues"
assert_contains "language filter applied" "$_src" "language_filter"
assert_contains "topic filter applied" "$_src" "topic_filter"
assert_contains "exclude topic filter" "$_src" "exclude_topic"
assert_contains "checks .shipwright-ignore" "$_src" ".shipwright-ignore"

echo ""

# ─── 10. Event Emission ─────────────────────────────────────────────────────
echo -e "${BOLD}Event Emission${RESET}"

assert_contains "emits fleet.discover.completed event" "$_src" "fleet.discover.completed"
assert_contains "emits fleet.discover.merged event" "$_src" "fleet.discover.merged"

echo ""

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
