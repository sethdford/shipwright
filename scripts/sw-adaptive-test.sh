#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright adaptive test — Validate data-driven pipeline tuning         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-adaptive-test.XXXXXX")
    # Scripts under test read and write the intelligence cache here, not in the repo (#8609).
    export SHIPWRIGHT_INTELLIGENCE_CACHE="$TEST_TEMP_DIR/project/.claude/intelligence-cache.json"
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Create empty events file
    touch "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap 'cleanup_test_env; sw_test_teardown' EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_header "Shipwright Adaptive Tests"

setup_env

# ─── Test 1: help command ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-adaptive.sh" help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0" "exit code: $rc"
fi
assert_contains "help shows USAGE" "$output" "USAGE"
assert_contains "help shows SUBCOMMANDS" "$output" "SUBCOMMANDS"
assert_contains "help mentions get" "$output" "get"
assert_contains "help mentions train" "$output" "train"
assert_contains "help mentions profile" "$output" "profile"

# ─── Test 2: version command ────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-adaptive.sh" version 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "version exits 0"
else
    assert_fail "version exits 0" "exit code: $rc"
fi
assert_contains "version output contains version string" "$output" "sw-adaptive"

# ─── Test 3: unknown command exits non-zero ─────────────────────────────────
echo ""
echo -e "${DIM}  error handling${RESET}"

output=$(bash "$SCRIPT_DIR/sw-adaptive.sh" nonexistent 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "Unknown command exits non-zero"
else
    assert_fail "Unknown command exits non-zero"
fi

# ─── Test 4: get with default value ─────────────────────────────────────────
echo ""
echo -e "${DIM}  get command${RESET}"

# With no events data, get should return the default value
output=$(bash "$SCRIPT_DIR/sw-adaptive.sh" get timeout --default 300 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "get timeout with default exits 0"
else
    assert_fail "get timeout with default exits 0" "exit code: $rc"
fi

# ─── Test 5: profile command ────────────────────────────────────────────────
echo ""
echo -e "${DIM}  profile command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-adaptive.sh" profile 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "profile exits 0"
else
    assert_fail "profile exits 0" "exit code: $rc"
fi

# ─── Test 6: reset command ──────────────────────────────────────────────────
echo ""
echo -e "${DIM}  reset command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-adaptive.sh" reset 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "reset exits 0"
else
    assert_fail "reset exits 0" "exit code: $rc"
fi

# ─── Test 7: source guard pattern ───────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-adaptive.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q 'BASH_SOURCE\[0\].*==.*\$0' "$SCRIPT_DIR/sw-adaptive.sh"; then
    assert_pass "Has source guard pattern"
else
    assert_fail "Has source guard pattern"
fi

# ─── Test 8: percentile, mean, median statistical functions ───────────────────
echo ""
echo -e "${DIM}  statistical functions${RESET}"
if grep -qE '^percentile\(\)|^mean\(\)|^median\(\)' "$SCRIPT_DIR/sw-adaptive.sh"; then
    assert_pass "percentile, mean, median functions defined in source"
else
    assert_fail "percentile, mean, median functions defined in source"
fi
m=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
mean "[1, 2, 3, 4, 5]"
' 2>/dev/null)
if [[ -n "$m" && "$m" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    assert_pass "mean returns numeric value (avg of 1-5 is 3)"
else
    assert_fail "mean returns numeric value" "got: $m"
fi
# percentile/median use jq --arg for p; test via get_timeout which uses them internally

# ─── Test 9: get_timeout with and without event data ──────────────────────────
echo ""
echo -e "${DIM}  get_timeout / get_iterations / get_model${RESET}"
timeout_def=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
get_timeout "build" "." "1800"
' 2>/dev/null)
if [[ -n "$timeout_def" && "$timeout_def" =~ ^[0-9]+$ ]]; then
    assert_pass "get_timeout returns number (default with no events)"
else
    assert_fail "get_timeout returns number" "got: $timeout_def"
fi
iter_val=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
get_iterations 5 "build" "10"
' 2>/dev/null)
if [[ -n "$iter_val" && "$iter_val" =~ ^[0-9]+$ ]]; then
    assert_pass "get_iterations returns number"
else
    assert_fail "get_iterations returns number" "got: $iter_val"
fi
model_val=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
get_model "build" "opus"
' 2>/dev/null)
if [[ -n "$model_val" && "$model_val" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    assert_pass "get_model returns valid model name"
else
    assert_fail "get_model returns valid model name" "got: $model_val"
fi

# ─── Test 10: train subcommand with mock events data ──────────────────────────
echo ""
echo -e "${DIM}  train subcommand${RESET}"
# Add mock events matching pipeline schema (stage.completed, pipeline.completed, model.outcome)
for i in 1 2 3 4 5; do
    echo "{\"ts\":\"2024-01-0${i}T12:00:00Z\",\"type\":\"stage.completed\",\"stage\":\"build\",\"duration_s\":$((i * 120)),\"issue\":1}"
done >> "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
for i in 1 2 3 4 5; do
    echo "{\"ts\":\"2024-01-0${i}T12:05:00Z\",\"type\":\"pipeline.completed\",\"issue\":1,\"result\":\"success\",\"duration_s\":600,\"self_heal_count\":$((i-1)),\"iterations\":$i}"
done >> "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
for i in 1 2 3 4 5; do
    echo "{\"ts\":\"2024-01-0${i}T12:06:00Z\",\"type\":\"model.outcome\",\"stage\":\"build\",\"model\":\"opus\",\"success\":true,\"issue\":1}"
done >> "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
train_out=$(bash "$SCRIPT_DIR/sw-adaptive.sh" train --repo "$SCRIPT_DIR" 2>&1) || true
if [[ "$train_out" == *"trained"* ]] || [[ "$train_out" == *"Models"* ]] || [[ "$train_out" == *"Training"* ]] || [[ -f "$TEST_TEMP_DIR/home/.shipwright/adaptive-models.json" ]]; then
    assert_pass "train subcommand runs with mock events"
else
    assert_fail "train subcommand runs with mock events" "out: ${train_out:0:100}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_results
