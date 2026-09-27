#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cleanup test — Clean up orphaned sessions & artifacts       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--is-inside-work-tree" ]]; then echo "true"
        else echo "abc1234"; fi ;;
    branch)
        echo "" ;;
    worktree)
        case "${2:-}" in
            list) echo "" ;;
            prune) exit 0 ;;
        esac ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows) echo "" ;;
    list-sessions) echo "" ;;
    kill-window) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"
    # Also link common utils we need
    for cmd in find stat du wc sed; do
        if command -v "$cmd" &>/dev/null; then
            ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
        fi
    done
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    # Create a mock repo dir and cd there so relative paths (.claude/) don't pick up real artifacts
    mkdir -p "$TEST_TEMP_DIR/repo"
    cd "$TEST_TEMP_DIR/repo"
}

trap cleanup_test_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1"; local detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; if [[ -n "$detail" ]]; then echo -e "    ${DIM}${detail}${RESET}"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; local _count; _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true; if [[ "${_count:-0}" -gt 0 ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; local _count; _count=$(printf '%s\n' "$haystack" | grep -cE -- "$pattern" 2>/dev/null) || true; if [[ "${_count:-0}" -gt 0 ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
print_test_header "Shipwright Cleanup Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help${RESET}"
output=$(bash "$SCRIPT_DIR/sw-cleanup.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows --force" "$output" "--force"
assert_contains "help shows dry-run" "$output" "Dry-run"

# ─── Test 2: Dry-run with nothing to clean ────────────────────────────────
echo ""
echo -e "${BOLD}  Dry-Run (Empty)${RESET}"
output=$(bash "$SCRIPT_DIR/sw-cleanup.sh" 2>&1) || true
assert_contains "dry-run shows Tmux Windows section" "$output" "Tmux Windows"
assert_contains "dry-run shows Team Configs section" "$output" "Team Configs"
assert_contains "dry-run shows Task Lists section" "$output" "Task Lists"
assert_contains "dry-run shows Pipeline Artifacts section" "$output" "Pipeline Artifacts"
assert_contains "dry-run shows Pipeline State section" "$output" "Pipeline State"
assert_contains "dry-run shows Heartbeats section" "$output" "Heartbeats"
assert_contains "dry-run reports clean" "$output" "Everything is clean"

# ─── Test 3: Force mode with nothing to clean ─────────────────────────────
echo ""
echo -e "${BOLD}  Force Mode (Empty)${RESET}"
output=$(bash "$SCRIPT_DIR/sw-cleanup.sh" --force 2>&1) || true
assert_contains "force shows FORCE MODE" "$output" "FORCE MODE"
assert_contains "force reports nothing to clean" "$output" "Nothing to clean up"

# ─── Test 4: Dry-run detects team directories ─────────────────────────────
echo ""
echo -e "${BOLD}  Detect Team Configs${RESET}"
mkdir -p "$HOME/.claude/teams/test-team"
echo '{}' > "$HOME/.claude/teams/test-team/config.json"
output=$(bash "$SCRIPT_DIR/sw-cleanup.sh" 2>&1) || true
assert_contains "dry-run detects team dir" "$output" "test-team"
assert_contains "dry-run shows would remove" "$output" "Would remove"

# ─── Test 5: Force mode removes team directories ──────────────────────────
echo ""
echo -e "${BOLD}  Force Removes Teams${RESET}"
output=$(bash "$SCRIPT_DIR/sw-cleanup.sh" --force 2>&1) || true
assert_contains "force removes team dir" "$output" "Removed"
if [[ ! -d "$HOME/.claude/teams/test-team" ]]; then
    assert_pass "team directory actually removed"
else
    assert_fail "team directory actually removed" "still exists"
fi

# ─── Test 6: Dry-run detects task directories ─────────────────────────────
echo ""
echo -e "${BOLD}  Detect Task Lists${RESET}"
mkdir -p "$HOME/.claude/tasks/test-tasks"
echo '{}' > "$HOME/.claude/tasks/test-tasks/task-1.json"
output=$(bash "$SCRIPT_DIR/sw-cleanup.sh" 2>&1) || true
assert_contains "dry-run detects task dir" "$output" "test-tasks"

# ─── Test 7: Force mode removes task directories ──────────────────────────
output=$(bash "$SCRIPT_DIR/sw-cleanup.sh" --force 2>&1) || true
if [[ ! -d "$HOME/.claude/tasks/test-tasks" ]]; then
    assert_pass "task directory actually removed"
else
    assert_fail "task directory actually removed" "still exists"
fi

# ─── Test 8: Detect stale heartbeats ──────────────────────────────────────
echo ""
echo -e "${BOLD}  Detect Stale Heartbeats${RESET}"
mkdir -p "$HOME/.shipwright/heartbeats"
echo '{}' > "$HOME/.shipwright/heartbeats/agent-1.json"
# Make it old by touching with old date
touch -t 202001010000 "$HOME/.shipwright/heartbeats/agent-1.json" 2>/dev/null || true
output=$(bash "$SCRIPT_DIR/sw-cleanup.sh" 2>&1) || true
assert_contains "dry-run detects stale heartbeat" "$output" "agent-1"

# ─── Test 9: Unknown option ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-cleanup.sh" --bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown option exits non-zero" "1" "$rc"
assert_contains "unknown option shows error" "$output" "Unknown option"

# ─── Test 10: Summary counts items ───────────────────────────────────────
echo ""
echo -e "${BOLD}  Summary Counting${RESET}"
# Set up items to find
mkdir -p "$HOME/.claude/teams/team-a"
echo '{}' > "$HOME/.claude/teams/team-a/config.json"
mkdir -p "$HOME/.claude/tasks/task-a"
echo '{}' > "$HOME/.claude/tasks/task-a/t.json"
output=$(bash "$SCRIPT_DIR/sw-cleanup.sh" 2>&1) || true
assert_contains "summary shows found count" "$output" "Found"
assert_contains "summary shows --force hint" "$output" "--force"

echo ""
echo ""
print_test_results
