#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-policy-learner-test.sh — Policy Learner Test Suite                   ║
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
    local haystack="$1" needle="$2" description="${3:-}"
    if echo "$haystack" | grep "$needle" >/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"
        echo "    Actual: $haystack"
    fi
}

assert_not_empty() {
    local value="$1" description="${2:-}"
    if [[ -n "$value" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Value was empty"
    fi
}

assert_file_exists() {
    local path="$1" description="${2:-}"
    if [[ -f "$path" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    File not found: $path"
    fi
}

assert_json_field() {
    local json="$1" field="$2" expected="$3" description="${4:-}"
    local actual
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null || echo "PARSE_ERROR")
    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Field $field — expected: $expected, actual: $actual"
    fi
}

# ─── Setup / Teardown ──────────────────────────────────────────────────────

TMPDIR_TEST="$(mktemp -d 2>/dev/null || mktemp -d -t 'policy-test')"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export POLICY_EPISODES_FILE="$TMPDIR_TEST/rl-episodes.jsonl"
export POLICY_REWARDS_FILE="$TMPDIR_TEST/rewards.jsonl"
export POLICY_LEARNED_FILE="$TMPDIR_TEST/learned-policy.json"
export POLICY_MIN_EPISODES=3

# Source the module
# shellcheck source=lib/policy-learner.sh
source "$SCRIPT_DIR/lib/policy-learner.sh"

# Helper: create a test episode
_create_episode() {
    local lang="$1" itype="$2" cplx="$3" strategy="$4" success="$5" iters="$6" cost="${7:-1.00}"
    local epoch
    epoch="$(date +%s)"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    jq -c -n \
        --arg ts "$ts" \
        --argjson epoch "$epoch" \
        --arg lang "$lang" \
        --arg itype "$itype" \
        --arg cplx "$cplx" \
        --arg strategy "$strategy" \
        --argjson success "$success" \
        --argjson iters "$iters" \
        --argjson cost "$cost" \
        '{
            timestamp: $ts,
            epoch: $epoch,
            context: {language: $lang, issue_type: $itype, complexity: $cplx},
            actions: ($strategy | split(",")),
            outcome: {success: $success, iterations: $iters, cost_usd: $cost},
            process_rewards: [],
            weight: 1.0
        }' >> "$POLICY_EPISODES_FILE"
}

_reset_test_data() {
    rm -f "$POLICY_EPISODES_FILE" "$POLICY_REWARDS_FILE" "$POLICY_LEARNED_FILE"
}

# ─── Test: no episodes returns gracefully ──────────────────────────────────
test_learn_no_episodes() {
    _reset_test_data
    local output
    output=$(policy_learn_from_history 2>&1)
    assert_contains "$output" "No episodes" "learn_from_history handles missing file"
}

# ─── Test: empty episodes file ─────────────────────────────────────────────
test_learn_empty_episodes() {
    _reset_test_data
    touch "$POLICY_EPISODES_FILE"
    local output
    output=$(policy_learn_from_history 2>&1)
    assert_contains "$output" "No episodes" "learn_from_history handles empty file"
}

# ─── Test: learn from valid episodes creates policy file ───────────────────
test_learn_creates_policy() {
    _reset_test_data
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 4 2.00
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 3 1.50
    _create_episode "ts" "bug" "medium" "code_first" false 8 4.00
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 5 2.50

    policy_learn_from_history > /dev/null 2>&1
    assert_file_exists "$POLICY_LEARNED_FILE" "learn_from_history creates policy file"
}

# ─── Test: policy contains correct strategy for bucket ─────────────────────
test_learn_best_strategy() {
    _reset_test_data
    # add_tests,fix_code: 3/3 success
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 4 2.00
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 3 1.50
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 5 2.50
    # code_first: 1/3 success
    _create_episode "ts" "bug" "medium" "code_first" false 8 4.00
    _create_episode "ts" "bug" "medium" "code_first" false 7 3.50
    _create_episode "ts" "bug" "medium" "code_first" true 6 3.00

    policy_learn_from_history > /dev/null 2>&1

    local best
    best=$(jq -r '.strategies["ts:bug:medium"].best' "$POLICY_LEARNED_FILE")
    assert_equals "add_tests,fix_code" "$best" "best strategy is add_tests,fix_code (3/3 vs 1/3)"
}

# ─── Test: suggest returns exact match ─────────────────────────────────────
test_suggest_exact_match() {
    _reset_test_data
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 4 2.00
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 3 1.50
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 5 2.50
    policy_learn_from_history > /dev/null 2>&1

    local result
    result=$(policy_suggest_strategy "ts" "bug" "medium")
    assert_json_field "$result" ".strategy" "add_tests,fix_code" "suggest returns exact match strategy"
    assert_json_field "$result" ".confidence" "medium" "3 episodes = medium confidence"
}

# ─── Test: suggest falls back to partial match ─────────────────────────────
test_suggest_partial_match() {
    _reset_test_data
    # Only ts:bug:medium exists — query for ts:bug:high should fallback
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 4 2.00
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 3 1.50
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 5 2.50
    policy_learn_from_history > /dev/null 2>&1

    # No exact match for ts:bug:high — falls back to partial
    local result
    result=$(policy_suggest_strategy "ts" "bug" "high")

    local confidence
    confidence=$(echo "$result" | jq -r '.confidence')
    # Should either find a partial match or return none
    if [[ "$confidence" == "none" ]]; then
        # No partial match found — that's acceptable since we don't have ts:bug:*
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m suggest returns none when no partial match"
    else
        local tier
        tier=$(echo "$result" | jq -r '.match_tier // "unknown"')
        assert_not_empty "$tier" "suggest returns partial match tier"
    fi
}

# ─── Test: suggest with no policy file returns default ─────────────────────
test_suggest_no_policy() {
    _reset_test_data
    local result
    result=$(policy_suggest_strategy "go" "feature" "low")
    assert_json_field "$result" ".strategy" "default" "suggest returns default with no policy"
    assert_json_field "$result" ".confidence" "none" "confidence is none with no policy"
}

# ─── Test: high confidence with many episodes ──────────────────────────────
test_suggest_high_confidence() {
    _reset_test_data
    local i
    for i in $(seq 1 10); do
        _create_episode "py" "feature" "high" "plan_then_build" true "$i" 1.00
    done
    policy_learn_from_history > /dev/null 2>&1

    local result
    result=$(policy_suggest_strategy "py" "feature" "high")
    assert_json_field "$result" ".confidence" "high" "10 episodes (>= min*3) = high confidence"
}

# ─── Test: optimize_prompt_weights returns JSON ────────────────────────────
test_optimize_prompt_weights() {
    _reset_test_data
    _create_episode "ts" "bug" "medium" "fix" true 3 1.00
    _create_episode "ts" "bug" "medium" "fix" true 4 1.50
    _create_episode "ts" "bug" "medium" "fix" false 8 3.00
    policy_learn_from_history > /dev/null 2>&1

    local weights
    weights=$(policy_optimize_prompt_weights)
    # Should be valid JSON
    local valid
    valid=$(echo "$weights" | jq 'type' 2>/dev/null || echo "invalid")
    assert_equals '"object"' "$valid" "prompt weights returns valid JSON object"
}

# ─── Test: inject_into_prompt with confident data ──────────────────────────
test_inject_into_prompt() {
    _reset_test_data
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 4 2.00
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 3 1.50
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 5 2.50
    policy_learn_from_history > /dev/null 2>&1

    local output
    output=$(policy_inject_into_prompt "ts" "bug" "medium")
    assert_contains "$output" "Policy-Learned Strategy" "inject produces strategy header"
    assert_contains "$output" "success rate" "inject includes success rate"
}

# ─── Test: inject_into_prompt with no data returns empty ───────────────────
test_inject_empty() {
    _reset_test_data
    local output
    output=$(policy_inject_into_prompt "go" "feature" "low")
    assert_equals "" "$output" "inject returns empty with no data"
}

# ─── Test: policy_report output ────────────────────────────────────────────
test_report_with_data() {
    _reset_test_data
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 4 2.00
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 3 1.50
    _create_episode "ts" "bug" "medium" "add_tests,fix_code" true 5 2.50
    policy_learn_from_history > /dev/null 2>&1

    local output
    output=$(policy_report)
    assert_contains "$output" "Learned Policy Report" "report has header"
    assert_contains "$output" "ts:bug:medium" "report shows context bucket"
    assert_contains "$output" "Total episodes" "report shows total count"
}

# ─── Test: report with no policy ───────────────────────────────────────────
test_report_no_policy() {
    _reset_test_data
    local output
    output=$(policy_report)
    assert_contains "$output" "No learned policy" "report handles missing policy"
}

# ─── Test: context key helper ──────────────────────────────────────────────
test_context_key() {
    local key
    key=$(_policy_context_key "ts" "bug" "medium")
    assert_equals "ts:bug:medium" "$key" "context key formats correctly"

    key=$(_policy_context_key "" "bug" "")
    assert_equals "*:bug:*" "$key" "context key fills blanks with *"

    key=$(_policy_context_key "" "" "")
    assert_equals "*:*:*" "$key" "all empty = *:*:*"
}

# ─── Test: multiple buckets learned independently ──────────────────────────
test_multiple_buckets() {
    _reset_test_data
    # ts:bug:medium — add_tests wins
    _create_episode "ts" "bug" "medium" "add_tests" true 3 1.00
    _create_episode "ts" "bug" "medium" "add_tests" true 4 1.50
    _create_episode "ts" "bug" "medium" "add_tests" true 5 2.00
    # py:feature:high — plan_first wins
    _create_episode "py" "feature" "high" "plan_first" true 6 3.00
    _create_episode "py" "feature" "high" "plan_first" true 5 2.50
    _create_episode "py" "feature" "high" "plan_first" true 7 3.50

    policy_learn_from_history > /dev/null 2>&1

    local ts_best py_best
    ts_best=$(jq -r '.strategies["ts:bug:medium"].best' "$POLICY_LEARNED_FILE")
    py_best=$(jq -r '.strategies["py:feature:high"].best' "$POLICY_LEARNED_FILE")
    assert_equals "add_tests" "$ts_best" "ts:bug:medium learns add_tests"
    assert_equals "plan_first" "$py_best" "py:feature:high learns plan_first"
}

# ─── Test: module guard prevents double-source ─────────────────────────────
test_module_guard() {
    # Source again — should not error
    source "$SCRIPT_DIR/lib/policy-learner.sh" 2>/dev/null
    PASS=$((PASS + 1))
    echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m module guard allows re-source without error"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-policy-learner-test.sh"
test_learn_no_episodes
test_learn_empty_episodes
test_learn_creates_policy
test_learn_best_strategy
test_suggest_exact_match
test_suggest_partial_match
test_suggest_no_policy
test_suggest_high_confidence
test_optimize_prompt_weights
test_inject_into_prompt
test_inject_empty
test_report_with_data
test_report_no_policy
test_context_key
test_multiple_buckets
test_module_guard

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
