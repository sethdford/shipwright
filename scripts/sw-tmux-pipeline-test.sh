#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tmux-pipeline test — Validate tmux pipeline management       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-tmux-pipeline-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/heartbeats"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/home/.claude"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi
    cat > "$TEMP_DIR/bin/sqlite3" <<'MOCK'
#!/usr/bin/env bash
echo ""
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/sqlite3"
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        else echo "abc1234"; fi ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"
    cat > "$TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/gh"
    cat > "$TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/claude"

    # tmux mock - tracks what was called
    TMUX_CALL_LOG="$TEMP_DIR/tmux-calls.log"
    export TMUX_CALL_LOG
    cat > "$TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${TMUX_CALL_LOG:-/dev/null}"
case "${1:-}" in
    has-session)
        # Simulate daemon session exists
        exit 0
        ;;
    list-sessions)
        echo "sw-daemon: 1 windows (created ...)"
        ;;
    list-windows)
        # Return pipeline windows
        echo "0: main (1 panes)"
        echo "1: pipeline-42 (1 panes)"
        ;;
    list-panes)
        echo "%5"
        ;;
    new-window)
        echo "%10"
        ;;
    capture-pane)
        echo "Mock pipeline output line 1"
        echo "Mock pipeline output line 2"
        ;;
    send-keys|select-window|attach-session|select-layout|kill-window)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
MOCK
    chmod +x "$TEMP_DIR/bin/tmux"
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright tmux-pipeline Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help ────────────────────────────────────────────────────
echo -e "${BOLD}  Help${RESET}"
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ─────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "USAGE"

# ─── Test 3: Unknown command ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" nonexistent 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: Spawn requires issue ────────────────────────────────────
echo -e "${BOLD}  Spawn${RESET}"
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" spawn 2>&1) || true
assert_contains "spawn without issue errors" "$output" "Issue number required"

# ─── Test 5: Spawn with existing window warns ───────────────────────
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" spawn --issue 42 2>&1) || true
assert_contains "spawn existing window warns" "$output" "already exists"

# ─── Test 6: Spawn with new issue ───────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" spawn --issue 99 2>&1) || true
assert_contains "spawn new pipeline succeeds" "$output" "Pipeline spawned"

# ─── Test 7: Heartbeat created ──────────────────────────────────────
if [[ -f "$HOME/.shipwright/heartbeats/pipeline-99.json" ]]; then
    hb_content=$(cat "$HOME/.shipwright/heartbeats/pipeline-99.json")
    assert_contains "heartbeat has job_id" "$hb_content" "pipeline-99"
    assert_contains "heartbeat has pane_id" "$hb_content" "pane_id"
else
    assert_fail "heartbeat has job_id" "heartbeat file not created"
    assert_fail "heartbeat has pane_id" "heartbeat file not created"
fi

# ─── Test 8: List shows pipelines ───────────────────────────────────
echo -e "${BOLD}  List${RESET}"
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" list 2>&1) || true
assert_contains "list shows pipeline windows" "$output" "Pipeline windows"
assert_contains "list shows pipeline-42" "$output" "42"

# ─── Test 9: Capture requires issue ─────────────────────────────────
echo -e "${BOLD}  Capture${RESET}"
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" capture 2>&1) || true
assert_contains "capture without issue errors" "$output" "Issue number required"

# ─── Test 10: Capture with valid issue ──────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" capture 42 2>&1) || true
assert_contains "capture shows output" "$output" "Mock pipeline output"

# ─── Test 11: Kill with valid issue ─────────────────────────────────
echo -e "${BOLD}  Kill${RESET}"
# Create heartbeat file first
echo '{"job_id":"pipeline-42"}' > "$HOME/.shipwright/heartbeats/pipeline-42.json"
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" kill 42 2>&1) || true
assert_contains "kill succeeds" "$output" "Pipeline killed"

# Verify heartbeat cleaned up
if [[ ! -f "$HOME/.shipwright/heartbeats/pipeline-42.json" ]]; then
    assert_pass "kill removes heartbeat file"
else
    assert_fail "kill removes heartbeat file" "heartbeat file still exists"
fi

# ─── Test 12: Layout valid type ──────────────────────────────────────
echo -e "${BOLD}  Layout${RESET}"
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" layout tiled 2>&1) || true
assert_contains "layout tiled succeeds" "$output" "Layout applied"

# ─── Test 13: Layout horizontal ─────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" layout horizontal 2>&1) || true
assert_contains "layout horizontal succeeds" "$output" "Layout applied"

# ─── Test 14: Layout invalid type ───────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" layout bogus 2>&1) || true
assert_contains "layout bogus errors" "$output" "Unknown layout"

# ─── Test 15: Attach requires issue ─────────────────────────────────
echo -e "${BOLD}  Attach${RESET}"
output=$(bash "$SCRIPT_DIR/sw-tmux-pipeline.sh" attach 2>&1) || true
assert_contains "attach without issue errors" "$output" "Issue number required"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
