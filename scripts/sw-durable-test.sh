#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright durable test — Validate durable workflow engine              ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-durable-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/durable/event-log"
    mkdir -p "$TEMP_DIR/home/.shipwright/durable/checkpoints"
    mkdir -p "$TEMP_DIR/home/.shipwright/durable/dlq"
    mkdir -p "$TEMP_DIR/home/.shipwright/durable/locks"
    mkdir -p "$TEMP_DIR/home/.shipwright/durable/offsets"
    mkdir -p "$TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/git"

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

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
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

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Durable Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: help command ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-durable.sh" help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0" "exit code: $rc"
fi
assert_contains "help shows USAGE" "$output" "USAGE"
assert_contains "help mentions publish" "$output" "publish"
assert_contains "help mentions consume" "$output" "consume"
assert_contains "help mentions checkpoint" "$output" "checkpoint"
assert_contains "help mentions lock" "$output" "lock"
assert_contains "help mentions compact" "$output" "compact"
assert_contains "help mentions status" "$output" "status"

# ─── Test 2: VERSION is defined ─────────────────────────────────────────────
if grep -q '^VERSION=' "$SCRIPT_DIR/sw-durable.sh"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 3: publish event ──────────────────────────────────────────────────
echo ""
echo -e "${DIM}  publish events${RESET}"

event_id=$(bash "$SCRIPT_DIR/sw-durable.sh" publish "test.event" '{"key":"value"}' 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "publish exits 0"
else
    assert_fail "publish exits 0" "exit code: $rc"
fi

# Check event was written to WAL
wal_file="$HOME/.shipwright/durable/event-log/events.jsonl"
if [[ -f "$wal_file" ]]; then
    assert_pass "WAL file created"
    line_count=$(wc -l < "$wal_file" | tr -d ' ')
    if [[ "$line_count" -ge 1 ]]; then
        assert_pass "Event written to WAL"
    else
        assert_fail "Event written to WAL" "WAL is empty"
    fi
else
    assert_fail "WAL file created"
    assert_fail "Event written to WAL"
fi

# ─── Test 4: publish missing args ───────────────────────────────────────────
echo ""
echo -e "${DIM}  error handling${RESET}"

output=$(bash "$SCRIPT_DIR/sw-durable.sh" publish 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "publish without args exits non-zero"
else
    assert_fail "publish without args exits non-zero"
fi

# ─── Test 5: unknown command ────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-durable.sh" nonexistent 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "Unknown command exits non-zero"
else
    assert_fail "Unknown command exits non-zero"
fi

# ─── Test 6: status command ─────────────────────────────────────────────────
echo ""
echo -e "${DIM}  status command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-durable.sh" status 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "status exits 0"
else
    assert_fail "status exits 0" "exit code: $rc"
fi

# ─── Test 7: checkpoint save and restore ─────────────────────────────────────
echo ""
echo -e "${DIM}  checkpointing${RESET}"

output=$(bash "$SCRIPT_DIR/sw-durable.sh" checkpoint save "wf-test" "build" "1" '{"state":"running"}' 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "checkpoint save exits 0"
else
    assert_fail "checkpoint save exits 0" "exit code: $rc"
fi

# Check checkpoint file exists
cp_file="$HOME/.shipwright/durable/checkpoints/wf-test.json"
if [[ -f "$cp_file" ]]; then
    assert_pass "Checkpoint file created"
else
    assert_fail "Checkpoint file created"
fi

output=$(bash "$SCRIPT_DIR/sw-durable.sh" checkpoint restore "wf-test" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "checkpoint restore exits 0"
else
    assert_fail "checkpoint restore exits 0" "exit code: $rc"
fi

# ─── Test 8: lock acquire and release ────────────────────────────────────────
echo ""
echo -e "${DIM}  distributed locks${RESET}"

output=$(bash "$SCRIPT_DIR/sw-durable.sh" lock acquire "test-resource" 5 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "lock acquire exits 0"
else
    assert_fail "lock acquire exits 0" "exit code: $rc"
fi

output=$(bash "$SCRIPT_DIR/sw-durable.sh" lock release "test-resource" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "lock release exits 0"
else
    assert_fail "lock release exits 0" "exit code: $rc"
fi

# ─── Test 9: script safety ──────────────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-durable.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q 'BASH_SOURCE\[0\].*==.*\$0' "$SCRIPT_DIR/sw-durable.sh"; then
    assert_pass "Has source guard pattern"
else
    assert_fail "Has source guard pattern"
fi

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
