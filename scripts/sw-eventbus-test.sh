#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright eventbus test — Durable event bus tests                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    # od is used for UUID generation
    if command -v od &>/dev/null; then
        ln -sf "$(command -v od)" "$TEST_TEMP_DIR/bin/od"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
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
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Eventbus Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-eventbus.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright eventbus"
assert_contains "help shows subcommands" "$output" "SUBCOMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-eventbus.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-eventbus.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits 1" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown subcommand"

# ─── Test 4: status (empty eventbus) ──────────────────────────────────────
echo ""
echo -e "  ${CYAN}status subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-eventbus.sh" status 2>&1) && rc=0 || rc=$?
assert_eq "status exits 0 with empty bus" "0" "$rc"
assert_contains "status shows title" "$output" "Event Bus Status"

# ─── Test 5: publish an event ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}publish subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-eventbus.sh" publish "stage.complete" "pipeline" "corr-123" '{"stage": "build"}' 2>&1) && rc=0 || rc=$?
assert_eq "publish exits 0" "0" "$rc"
assert_contains "publish confirms" "$output" "Published event"

# ─── Test 6: eventbus file created ─────────────────────────────────────────
if [[ -f "$HOME/.shipwright/events.jsonl" ]]; then
    assert_pass "events.jsonl created"
else
    assert_fail "events.jsonl created"
fi

# ─── Test 7: eventbus file has valid JSONL ─────────────────────────────────
line=$(head -1 "$HOME/.shipwright/events.jsonl" 2>/dev/null || echo "")
if echo "$line" | grep -qF "stage.complete"; then
    assert_pass "events.jsonl contains published event type"
else
    assert_fail "events.jsonl contains published event type" "line: $line"
fi
if echo "$line" | grep -qF "corr-123"; then
    assert_pass "events.jsonl contains correlation_id"
else
    assert_fail "events.jsonl contains correlation_id" "line: $line"
fi

# ─── Test 8: publish multiple events ──────────────────────────────────────
bash "$SCRIPT_DIR/sw-eventbus.sh" publish "stage.start" "daemon" "corr-456" '{}' >/dev/null 2>&1
bash "$SCRIPT_DIR/sw-eventbus.sh" publish "pipeline.done" "loop" "corr-789" '{}' >/dev/null 2>&1
line_count=$(wc -l < "$HOME/.shipwright/events.jsonl" 2>/dev/null || echo 0)
line_count=$(echo "$line_count" | tr -d ' ')
if [[ "$line_count" -ge 3 ]]; then
    assert_pass "eventbus has 3+ events after multi-publish"
else
    assert_fail "eventbus has 3+ events after multi-publish" "got: $line_count"
fi

# ─── Test 9: status with events ───────────────────────────────────────────
echo ""
echo -e "  ${CYAN}status with events${RESET}"
output=$(bash "$SCRIPT_DIR/sw-eventbus.sh" status 2>&1) && rc=0 || rc=$?
assert_eq "status with events exits 0" "0" "$rc"
assert_contains "status shows total events" "$output" "Total Events"
assert_contains "status shows events by type" "$output" "Events by Type"

# ─── Test 10: clean (nothing old to clean) ─────────────────────────────────
echo ""
echo -e "  ${CYAN}clean subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-eventbus.sh" clean 2>&1) && rc=0 || rc=$?
assert_eq "clean exits 0" "0" "$rc"
assert_contains "clean reports result" "$output" "Removed"

# ─── Test 11: replay ──────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}replay subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-eventbus.sh" replay 60 2>&1) && rc=0 || rc=$?
assert_eq "replay exits 0" "0" "$rc"
assert_contains "replay shows replaying" "$output" "Replaying"

# ─── Test 12: publish missing event type ───────────────────────────────────
echo ""
echo -e "  ${CYAN}publish error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-eventbus.sh" publish "" "source" "id" '{}' 2>&1) && rc=0 || rc=$?
assert_eq "publish with empty type exits 1" "1" "$rc"

# ─── Test 13: watch with missing dir ──────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-eventbus.sh" watch "/nonexistent/dir" 2>&1) && rc=0 || rc=$?
assert_eq "watch with missing dir exits 1" "1" "$rc"
assert_contains "watch shows dir error" "$output" "not found"

echo ""
echo ""
print_test_results
