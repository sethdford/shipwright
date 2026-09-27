#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pr-lifecycle test — Validate autonomous PR management       ║
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
    mkdir -p "$TEST_TEMP_DIR/repo/scripts/lib"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls chmod; do
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

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    pr)
        case "${2:-}" in
            view) echo '{"number":42,"title":"Test PR","body":"closes #10","state":"OPEN","headRefName":"feat/test","baseRefName":"main","statusCheckRollup":[],"reviews":[],"commits":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z","mergeStateStatus":"CLEAN","reviewDecision":"PENDING"}' ;;
            list) echo '[]' ;;
            diff) echo "diff --git a/file.sh b/file.sh
+added line
-removed line" ;;
            comment) echo "comment posted" ;;
            merge) echo "merged" ;;
            checks) echo '[]' ;;
            close) echo "closed" ;;
        esac ;;
    issue)
        case "${2:-}" in
            comment) echo "comment posted" ;;
            view) echo '{"body":"closes #10"}' ;;
        esac ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock claude and tmux
    for mock in claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    # Create minimal daemon config for pr_lifecycle
    echo '{"pr_lifecycle":{"auto_merge_enabled":"false","stale_days":"14"}}' > "$TEST_TEMP_DIR/repo/.claude/daemon-config.json"

    # Copy compat.sh if available
    if [[ -f "$SCRIPT_DIR/lib/compat.sh" ]]; then
        cp "$SCRIPT_DIR/lib/compat.sh" "$TEST_TEMP_DIR/repo/scripts/lib/compat.sh"
    fi

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

SRC="$SCRIPT_DIR/sw-pr-lifecycle.sh"

echo ""
print_test_header "Shipwright PR Lifecycle Test Suite"
echo ""

# ─── 1. Script Safety ─────────────────────────────────────────────────────────
echo -e "${BOLD}  Script Safety${RESET}"

if grep -q 'set -euo pipefail' "$SRC"; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

if grep -q "trap.*ERR" "$SRC"; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

if grep -q '^VERSION=' "$SRC"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

ver=$(grep -m1 '^VERSION=' "$SRC" | sed 's/VERSION="//' | sed 's/"//')
if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    assert_pass "VERSION is semver: $ver"
else
    assert_fail "VERSION is semver" "got: $ver"
fi

echo ""

# ─── 2. Source Guard ──────────────────────────────────────────────────────────
echo -e "${BOLD}  Source Guard${RESET}"

if grep -q 'BASH_SOURCE\[0\].*==.*\$0' "$SRC"; then
    assert_pass "source guard pattern present"
else
    assert_fail "source guard pattern present"
fi

# Must use if/then/fi, NOT [[ ]] && main
if grep -q 'if \[\[.*BASH_SOURCE' "$SRC"; then
    assert_pass "source guard uses if/then/fi (not && pattern)"
else
    assert_fail "source guard uses if/then/fi (not && pattern)"
fi

echo ""

# ─── 3. Help Output ──────────────────────────────────────────────────────────
echo -e "${BOLD}  Help Output${RESET}"

setup_env

help_output=$(bash "$SRC" help 2>&1) || true

assert_contains "help mentions review command" "$help_output" "review"
assert_contains "help mentions merge command" "$help_output" "merge"
assert_contains "help mentions cleanup command" "$help_output" "cleanup"
assert_contains "help mentions status command" "$help_output" "status"
assert_contains "help mentions patrol command" "$help_output" "patrol"

# --help flag
help_flag_output=$(bash "$SRC" --help 2>&1) || true
assert_contains "--help works" "$help_flag_output" "review"

echo ""

# ─── 4. Unknown Command ──────────────────────────────────────────────────────
echo -e "${BOLD}  Error Handling${RESET}"

if ! bash "$SRC" nonexistent-cmd 2>/dev/null; then
    assert_pass "unknown command exits non-zero"
else
    assert_fail "unknown command exits non-zero"
fi

unknown_output=$(bash "$SRC" nonexistent-cmd 2>&1) || true
assert_contains "unknown command shows error" "$unknown_output" "Unknown command"

echo ""

# ─── 5. Default Command ──────────────────────────────────────────────────────
echo -e "${BOLD}  Default Behavior${RESET}"

default_output=$(bash "$SRC" 2>&1) || true
assert_contains "no-arg defaults to help" "$default_output" "review"

echo ""

# ─── 6. Review Requires PR Number ────────────────────────────────────────────
echo -e "${BOLD}  Argument Validation${RESET}"

if ! bash "$SRC" review 2>/dev/null; then
    assert_pass "review without PR number exits non-zero"
else
    assert_fail "review without PR number exits non-zero"
fi

review_no_arg=$(bash "$SRC" review 2>&1) || true
assert_contains "review without arg shows error" "$review_no_arg" "PR number required"

if ! bash "$SRC" merge 2>/dev/null; then
    assert_pass "merge without PR number exits non-zero"
else
    assert_fail "merge without PR number exits non-zero"
fi

merge_no_arg=$(bash "$SRC" merge 2>&1) || true
assert_contains "merge without arg shows error" "$merge_no_arg" "PR number required"

echo ""

# ─── 7. Cleanup Subcommand ───────────────────────────────────────────────────
echo -e "${BOLD}  Cleanup Subcommand${RESET}"

cleanup_output=$(bash "$SRC" cleanup 2>&1) || true
assert_contains "cleanup runs" "$cleanup_output" "stale"

echo ""

# ─── 8. Status Subcommand ────────────────────────────────────────────────────
echo -e "${BOLD}  Status Subcommand${RESET}"

status_output=$(bash "$SRC" status 2>&1) || true
assert_contains "status shows PR info" "$status_output" "Pull Requests"

echo ""

# ─── 9. Configuration Helpers ────────────────────────────────────────────────
echo -e "${BOLD}  Configuration${RESET}"

if grep -q 'get_pr_config' "$SRC"; then
    assert_pass "get_pr_config helper defined"
else
    assert_fail "get_pr_config helper defined"
fi

if grep -q 'auto_merge_enabled' "$SRC"; then
    assert_pass "auto_merge_enabled config check present"
else
    assert_fail "auto_merge_enabled config check present"
fi

if grep -q 'stale_days' "$SRC"; then
    assert_pass "stale_days config present"
else
    assert_fail "stale_days config present"
fi

echo ""

# ─── 10. Event Emission ──────────────────────────────────────────────────────
echo -e "${BOLD}  Event Emission${RESET}"

if grep -q 'emit_event.*pr\.' "$SRC"; then
    assert_pass "emits pr lifecycle events"
else
    assert_fail "emits pr lifecycle events"
fi

if grep -q 'pr.review_complete' "$SRC"; then
    assert_pass "emits pr.review_complete event"
else
    assert_fail "emits pr.review_complete event"
fi

if grep -q 'pr.merged' "$SRC"; then
    assert_pass "emits pr.merged event"
else
    assert_fail "emits pr.merged event"
fi

echo ""

# ─── 11. Code Quality Patterns ───────────────────────────────────────────────
echo -e "${BOLD}  Code Quality Checks${RESET}"

if grep -q 'HACK\|TODO\|FIXME' "$SRC"; then
    assert_pass "review checks for HACK/TODO/FIXME patterns"
else
    assert_fail "review checks for HACK/TODO/FIXME patterns"
fi

if grep -q 'console\.' "$SRC"; then
    assert_pass "review checks for console.log statements"
else
    assert_fail "review checks for console.log statements"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
