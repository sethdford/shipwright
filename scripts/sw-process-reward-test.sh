#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-process-reward-test.sh — Process Reward Model Test Suite            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" description="${3:-}"
    if echo "$haystack" | grep -F "$needle" >/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"
        echo "    Actual: $haystack"
    fi
}

assert_ge() {
    local threshold="$1" actual="$2" description="${3:-}"
    if [[ "$actual" -ge "$threshold" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected >= $threshold, got: $actual"
    fi
}

assert_le() {
    local threshold="$1" actual="$2" description="${3:-}"
    if [[ "$actual" -le "$threshold" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected <= $threshold, got: $actual"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────
TMPDIR_TEST=$(mktemp -d 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/process-reward-test-XXXXXX" 2>/dev/null || echo "${TMPDIR:-/tmp}/process-reward-test-$$")
mkdir -p "$TMPDIR_TEST" 2>/dev/null || true
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Set up a minimal git repo for tests
TEST_REPO="$TMPDIR_TEST/test-repo"
mkdir -p "$TEST_REPO"
cd "$TEST_REPO"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "initial" > file.txt
git add file.txt
git commit -q -m "initial commit"

# Override reward file location
export PROCESS_REWARD_FILE="$TMPDIR_TEST/process-rewards.jsonl"

# Source the module
source "$SCRIPT_DIR/lib/process-reward.sh"

# ─── Test: test progress — passing tests score high ────────────────────────
test_score_test_passing() {
    local score
    score=$(_reward_score_test_progress "true" "all 10 tests passed" "")
    assert_ge 80 "$score" "passing tests score >= 80"
}

# ─── Test: test progress — failing tests score low ─────────────────────────
test_score_test_failing() {
    local score
    score=$(_reward_score_test_progress "false" "3 tests failed" "")
    assert_le 40 "$score" "failing tests score <= 40"
}

# ─── Test: test progress — going from fail to pass scores 100 ──────────────
test_score_test_recovery() {
    local score
    score=$(_reward_score_test_progress "true" "all passing" "false")
    assert_equals "100" "$score" "fail-to-pass recovery scores 100"
}

# ─── Test: test progress — no test command returns neutral ──────────────────
test_score_test_no_cmd() {
    local score
    score=$(_reward_score_test_progress "" "" "")
    assert_equals "50" "$score" "no test command returns neutral 50"
}

# ─── Test: code quality — clean diff scores well ───────────────────────────
test_score_code_quality_clean() {
    # Make a small clean change
    echo "clean code" >> file.txt
    git add file.txt
    git commit -q -m "clean change"
    local score
    score=$(_reward_score_code_quality "$TEST_REPO")
    assert_ge 60 "$score" "clean small diff scores >= 60"
}

# ─── Test: security — clean code scores high ───────────────────────────────
test_score_security_clean() {
    echo "safe code" >> file.txt
    git add file.txt
    git commit -q -m "safe change"
    local score
    score=$(_reward_score_security "$TEST_REPO")
    assert_ge 80 "$score" "clean code security score >= 80"
}

# ─── Test: convergence — first iteration returns 60 ────────────────────────
test_score_convergence_first() {
    local score
    score=$(_reward_score_convergence 1 "$TEST_REPO" "$PROCESS_REWARD_FILE")
    assert_equals "60" "$score" "first iteration convergence = 60"
}

# ─── Test: composite scoring produces JSON ──────────────────────────────────
test_composite_json() {
    echo "another change" >> file.txt
    git add file.txt
    git commit -q -m "test change for composite"
    local result
    result=$(process_reward_score_iteration 1 "true" "all passed" "" "$TEST_REPO")
    # Validate it's parseable JSON with composite field
    local composite
    composite=$(echo "$result" | jq -r '.composite' 2>/dev/null || echo "FAIL")
    if [[ "$composite" != "FAIL" ]] && [[ "$composite" -ge 0 ]] && [[ "$composite" -le 100 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m composite scoring returns valid JSON with 0-100 score ($composite)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m composite scoring returns valid JSON"
        echo "    Result: $result"
    fi
}

# ─── Test: record writes JSONL ──────────────────────────────────────────────
test_record_writes_jsonl() {
    rm -f "$PROCESS_REWARD_FILE"
    local scores='{"composite":75,"scores":{"test_progress":90,"code_quality":70,"convergence":60,"architecture":80,"security":90}}'
    process_reward_record 1 "$scores" "implement feature" "tests_pass"
    if [[ -f "$PROCESS_REWARD_FILE" ]]; then
        local line_count
        line_count=$(wc -l < "$PROCESS_REWARD_FILE" | tr -d ' ')
        assert_equals "1" "$line_count" "record writes exactly 1 line to JSONL"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m record writes JSONL file"
    fi
}

# ─── Test: suggest action — no history ──────────────────────────────────────
test_suggest_no_history() {
    local suggestion
    suggestion=$(process_reward_suggest_action "/nonexistent/file.jsonl")
    assert_contains "No reward history" "$suggestion" "suggest with no history gives default message"
}

# ─── Test: suggest action — failing tests ──────────────────────────────────
test_suggest_failing_tests() {
    local tmp_rewards="$TMPDIR_TEST/suggest-test.jsonl"
    rm -f "$tmp_rewards"
    echo '{"iteration":1,"scores":{"composite":40,"test_progress":20,"code_quality":70,"convergence":50,"architecture":80,"security":90}}' >> "$tmp_rewards"
    echo '{"iteration":2,"scores":{"composite":35,"test_progress":25,"code_quality":65,"convergence":45,"architecture":80,"security":90}}' >> "$tmp_rewards"
    local suggestion
    suggestion=$(process_reward_suggest_action "$tmp_rewards")
    assert_contains "Tests are failing" "$suggestion" "suggest focuses on tests when test_progress is low"
}

# ─── Test: suggest action — declining trajectory ───────────────────────────
test_suggest_declining() {
    local tmp_rewards="$TMPDIR_TEST/suggest-decline.jsonl"
    rm -f "$tmp_rewards"
    echo '{"iteration":1,"scores":{"composite":80,"test_progress":90,"code_quality":80,"convergence":70,"architecture":80,"security":90}}' >> "$tmp_rewards"
    echo '{"iteration":2,"scores":{"composite":65,"test_progress":80,"code_quality":60,"convergence":55,"architecture":70,"security":85}}' >> "$tmp_rewards"
    echo '{"iteration":3,"scores":{"composite":50,"test_progress":70,"code_quality":45,"convergence":40,"architecture":60,"security":80}}' >> "$tmp_rewards"
    local suggestion
    suggestion=$(process_reward_suggest_action "$tmp_rewards")
    assert_contains "declining" "$suggestion" "suggest detects declining trajectory"
}

# ─── Test: inject context — empty file returns nothing ─────────────────────
test_inject_empty() {
    local output
    output=$(process_reward_inject_context "/nonexistent/file.jsonl")
    assert_equals "" "$output" "inject with no file returns empty"
}

# ─── Test: inject context — formats markdown table ──────────────────────────
test_inject_markdown() {
    local tmp_rewards="$TMPDIR_TEST/inject-test.jsonl"
    rm -f "$tmp_rewards"
    echo '{"iteration":1,"scores":{"composite":75,"test_progress":90,"code_quality":70,"convergence":60,"architecture":80,"security":90}}' >> "$tmp_rewards"
    echo '{"iteration":2,"scores":{"composite":80,"test_progress":95,"code_quality":75,"convergence":65,"architecture":85,"security":90}}' >> "$tmp_rewards"
    local output
    output=$(process_reward_inject_context "$tmp_rewards")
    assert_contains "Iteration Rewards" "$output" "inject context includes header"
    assert_contains "Composite" "$output" "inject context includes table columns"
    assert_contains "Reward signal" "$output" "inject context includes suggestion"
}

# ─── Test: module guard prevents double-source ──────────────────────────────
test_module_guard() {
    # _PROCESS_REWARD_LOADED should be set
    assert_equals "1" "$_PROCESS_REWARD_LOADED" "module guard variable is set"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-process-reward-test.sh"
test_score_test_passing
test_score_test_failing
test_score_test_recovery
test_score_test_no_cmd
test_score_code_quality_clean
test_score_security_clean
test_score_convergence_first
test_composite_json
test_record_writes_jsonl
test_suggest_no_history
test_suggest_failing_tests
test_suggest_declining
test_inject_empty
test_inject_markdown
test_module_guard

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
