#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright worktree test — Git worktree management for agent isolation  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    # Mock git that simulates a repo at TEMP_DIR/repo
    MOCK_REPO="$TEST_TEMP_DIR/repo"
    mkdir -p "$MOCK_REPO/.worktrees"
    # Create a .gitignore file (not directory)
    touch "$MOCK_REPO/.gitignore"
    cat > "$TEST_TEMP_DIR/bin/git" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
    rev-parse)
        if [[ "\${2:-}" == "--show-toplevel" ]]; then echo "$MOCK_REPO"
        elif [[ "\${2:-}" == "--abbrev-ref" ]]; then echo "main"
        elif [[ "\${2:-}" == "--is-inside-work-tree" ]]; then echo "true"
        elif [[ "\${2:-}" == "--verify" ]]; then exit 0
        else echo "abc1234"; fi ;;
    branch)
        if [[ "\${2:-}" == "--show-current" ]]; then echo "main"
        elif [[ "\${2:-}" == "--list" ]]; then echo ""
        else echo "main"; fi
        exit 0 ;;
    worktree)
        case "\${2:-}" in
            add) exit 0 ;;
            remove) exit 0 ;;
            prune) exit 0 ;;
            list) echo "$MOCK_REPO abc1234 [main]" ;;
        esac
        exit 0 ;;
    merge) exit 0 ;;
    fetch) exit 0 ;;
    status) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap 'cleanup_test_env; sw_test_teardown' EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Worktree Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-worktree.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows create" "$output" "create"
assert_contains "help shows list" "$output" "list"
assert_contains "help shows sync" "$output" "sync"
assert_contains "help shows merge" "$output" "merge"
assert_contains "help shows remove" "$output" "remove"
assert_contains "help shows cleanup" "$output" "cleanup"
assert_contains "help shows status" "$output" "status"

# ─── Test 2: List with no worktrees ──────────────────────────────────────
echo ""
echo -e "${BOLD}  List Command${RESET}"
# Remove the .worktrees dir so list sees nothing
rmdir "$MOCK_REPO/.worktrees" 2>/dev/null || true
output=$(bash "$SCRIPT_DIR/sw-worktree.sh" list 2>&1) || true
assert_contains "list with no worktrees" "$output" "No worktrees found"

# ─── Test 3: Create without name ─────────────────────────────────────────
echo ""
echo -e "${BOLD}  Create Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-worktree.sh" create 2>&1) && rc=0 || rc=$?
assert_eq "create without name exits non-zero" "1" "$rc"
assert_contains "create without name shows usage" "$output" "Usage"

# ─── Test 4: Create with name (uses mock git) ────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-worktree.sh" create agent-1 2>&1) || true
assert_contains "create confirms worktree" "$output" "agent-1"

# ─── Test 5: Sync without name ───────────────────────────────────────────
echo ""
echo -e "${BOLD}  Sync Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-worktree.sh" sync 2>&1) && rc=0 || rc=$?
assert_eq "sync without name exits non-zero" "1" "$rc"
assert_contains "sync shows usage" "$output" "Usage"

# ─── Test 6: Merge without name ──────────────────────────────────────────
echo ""
echo -e "${BOLD}  Merge Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-worktree.sh" merge 2>&1) && rc=0 || rc=$?
assert_eq "merge without name exits non-zero" "1" "$rc"
assert_contains "merge shows usage" "$output" "Usage"

# ─── Test 7: Remove without name ─────────────────────────────────────────
echo ""
echo -e "${BOLD}  Remove Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-worktree.sh" remove 2>&1) && rc=0 || rc=$?
assert_eq "remove without name exits non-zero" "1" "$rc"
assert_contains "remove shows usage" "$output" "Usage"

# ─── Test 8: Status with no worktrees ─────────────────────────────────────
echo ""
echo -e "${BOLD}  Status Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-worktree.sh" status 2>&1) || true
assert_contains "status with no worktrees" "$output" "No worktrees found"

# ─── Test 9: Cleanup with no worktrees ────────────────────────────────────
echo ""
echo -e "${BOLD}  Cleanup Command${RESET}"
# Remove .worktrees that create test may have recreated
rm -rf "$MOCK_REPO/.worktrees"
output=$(bash "$SCRIPT_DIR/sw-worktree.sh" cleanup 2>&1) || true
assert_contains "cleanup with no worktrees" "$output" "clean"

# ─── Test 10: Sync-all with no worktrees ──────────────────────────────────
echo ""
echo -e "${BOLD}  Sync-All Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-worktree.sh" sync-all 2>&1) || true
assert_contains "sync-all with no worktrees" "$output" "No worktrees found"

# ─── Test 11: Unknown command ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-worktree.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits non-zero" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

echo ""
echo ""
print_test_results
