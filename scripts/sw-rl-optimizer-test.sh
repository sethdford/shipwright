#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-rl-optimizer-test.sh — RL Optimizer Test Suite (Phase 7)             ║
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
    if echo "$haystack" | grep "$needle" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"
        echo "    In: $(echo "$haystack" | head -3)"
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

assert_empty() {
    local value="$1" description="${2:-}"
    if [[ -z "$value" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected empty, got: $(echo "$value" | head -1)"
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

# ─── Setup ──────────────────────────────────────────────────────────────────

TEST_DIR="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/rl-test-$$")"
[[ -d "$TEST_DIR" ]] || mkdir -p "$TEST_DIR"

# Override RL file location for testing
export RL_EPISODES_FILE="${TEST_DIR}/rl-episodes.jsonl"
export RL_DECAY_HALF_LIFE_DAYS=30

# Source the module
source "$SCRIPT_DIR/lib/rl-optimizer.sh"

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Test: record episode creates file ──────────────────────────────────────

test_record_episode_creates_file() {
    rm -f "$RL_EPISODES_FILE"
    rl_record_episode \
        '{"language":"ts","complexity":"medium","issue_type":"bug"}' \
        '["read_code","add_tests","fix_type_error"]' \
        '{"success":true,"iterations":5,"cost_usd":2.50}' \
        '[45,55,70,85,95]'
    assert_file_exists "$RL_EPISODES_FILE" "record_episode creates episodes file"
}

# ─── Test: recorded episode has correct structure ───────────────────────────

test_record_episode_structure() {
    local ep
    ep=$(tail -1 "$RL_EPISODES_FILE")
    local lang
    lang=$(echo "$ep" | jq -r '.context.language')
    assert_equals "ts" "$lang" "recorded episode has correct language"

    local success
    success=$(echo "$ep" | jq -r '.outcome.success')
    assert_equals "true" "$success" "recorded episode has correct success flag"

    local weight
    weight=$(echo "$ep" | jq -r '.weight')
    # jq outputs 1 or 1.0 depending on version
    local weight_int
    weight_int=$(awk -v w="$weight" 'BEGIN{printf "%d", w}')
    assert_equals "1" "$weight_int" "recorded episode has initial weight of 1"

    local actions_count
    actions_count=$(echo "$ep" | jq '.actions | length')
    assert_equals "3" "$actions_count" "recorded episode has 3 actions"
}

# ─── Test: suggest approach with no episodes ────────────────────────────────

test_suggest_empty() {
    local save="$RL_EPISODES_FILE"
    RL_EPISODES_FILE="${TEST_DIR}/nonexistent.jsonl"
    local result
    result="$(rl_suggest_approach "ts" "bug" "medium")"
    assert_empty "$result" "suggest_approach returns empty with no episodes file"
    RL_EPISODES_FILE="$save"
}

# ─── Test: suggest approach with matching episodes ──────────────────────────

test_suggest_with_data() {
    rm -f "$RL_EPISODES_FILE"
    # Record several episodes with same context
    local i
    for i in 1 2 3 4 5; do
        rl_record_episode \
            '{"language":"ts","complexity":"medium","issue_type":"bug"}' \
            '["add_tests","fix_type_error"]' \
            '{"success":true,"iterations":4,"cost_usd":1.50}' \
            '[]'
    done
    # Record a failing episode
    rl_record_episode \
        '{"language":"ts","complexity":"medium","issue_type":"bug"}' \
        '["add_tests","fix_type_error"]' \
        '{"success":false,"iterations":10,"cost_usd":5.00}' \
        '[]'

    local result
    result="$(rl_suggest_approach "ts" "bug" "medium")"
    assert_not_empty "$result" "suggest_approach returns results with matching episodes"
    assert_contains "$result" "success rate" "suggestions include success rate"
}

# ─── Test: suggest approach filters by context ──────────────────────────────

test_suggest_filters_context() {
    rm -f "$RL_EPISODES_FILE"
    # Record python episodes
    rl_record_episode \
        '{"language":"python","complexity":"low","issue_type":"feature"}' \
        '["scaffold","implement"]' \
        '{"success":true,"iterations":3,"cost_usd":1.00}' \
        '[]'

    # Should not match when querying for go/bug
    local result
    result="$(rl_suggest_approach "go" "bug" "high")"
    assert_empty "$result" "suggest_approach returns empty for non-matching context"
}

# ─── Test: effectiveness score output ───────────────────────────────────────

test_effectiveness_score() {
    rm -f "$RL_EPISODES_FILE"
    rl_record_episode \
        '{"language":"ts","complexity":"medium","issue_type":"bug"}' \
        '["read_code","add_tests"]' \
        '{"success":true,"iterations":3,"cost_usd":1.00}' \
        '[]'
    rl_record_episode \
        '{"language":"ts","complexity":"medium","issue_type":"bug"}' \
        '["read_code","refactor"]' \
        '{"success":false,"iterations":8,"cost_usd":3.00}' \
        '[]'

    local result
    result="$(rl_effectiveness_score)"
    assert_not_empty "$result" "effectiveness_score returns output"
    assert_contains "$result" "success" "effectiveness includes success rate"
}

# ─── Test: inject context produces markdown ─────────────────────────────────

test_inject_context() {
    rm -f "$RL_EPISODES_FILE"
    # Need enough episodes to produce suggestions
    local i
    for i in 1 2 3; do
        rl_record_episode \
            '{"language":"ts","complexity":"medium","issue_type":"bug"}' \
            '["add_tests","fix"]' \
            '{"success":true,"iterations":4,"cost_usd":1.50}' \
            '[]'
    done

    local result
    result="$(rl_inject_context "ts" "bug" "medium")"
    assert_not_empty "$result" "inject_context produces output"
    assert_contains "$result" "RL-Suggested" "inject_context has RL header"
}

# ─── Test: update weights increases on success ──────────────────────────────

test_update_weights_success() {
    rm -f "$RL_EPISODES_FILE"
    rl_record_episode \
        '{"language":"ts","complexity":"low","issue_type":"bug"}' \
        '["fix"]' \
        '{"success":true,"iterations":2,"cost_usd":0.50}' \
        '[]'

    local before_weight
    before_weight=$(tail -1 "$RL_EPISODES_FILE" | jq -r '.weight')

    rl_update_weights '["fix"]' "true"

    local after_weight
    after_weight=$(tail -1 "$RL_EPISODES_FILE" | jq -r '.weight')

    # Weight should increase by RL_SUCCESS_REWARD (1.0)
    local expected
    expected=$(awk -v b="$before_weight" -v r="$RL_SUCCESS_REWARD" 'BEGIN{print b + r}')
    assert_equals "$expected" "$after_weight" "weight increases on success"
}

# ─── Test: update weights decreases on failure with min floor ───────────────

test_update_weights_failure() {
    rm -f "$RL_EPISODES_FILE"
    # Record with already low weight
    echo '{"timestamp":"2026-01-01T00:00:00Z","epoch":1735689600,"context":{},"actions":["x"],"outcome":{"success":false,"iterations":10,"cost_usd":5},"process_rewards":[],"weight":0.3}' > "$RL_EPISODES_FILE"

    rl_update_weights '["x"]' "false"

    local after_weight
    after_weight=$(tail -1 "$RL_EPISODES_FILE" | jq -r '.weight')

    # 0.3 - 0.5 = -0.2 -> clamped to 0.1 (min)
    assert_equals "0.1" "$after_weight" "weight floors at minimum on failure"
}

# ─── Test: record from pipeline convenience ─────────────────────────────────

test_record_from_pipeline() {
    rm -f "$RL_EPISODES_FILE"
    rl_record_from_pipeline "true" "5" "2.50" "ts" "medium" "bug" '["plan","build","test"]' '[50,70,90]'

    local ep
    ep=$(head -1 "$RL_EPISODES_FILE")
    local lang
    lang=$(echo "$ep" | jq -r '.context.language')
    assert_equals "ts" "$lang" "record_from_pipeline sets language"

    local iters
    iters=$(echo "$ep" | jq -r '.outcome.iterations')
    assert_equals "5" "$iters" "record_from_pipeline sets iterations"
}

# ─── Test: empty file effectiveness score ───────────────────────────────────

test_effectiveness_empty() {
    local save="$RL_EPISODES_FILE"
    RL_EPISODES_FILE="${TEST_DIR}/empty.jsonl"
    local result
    result="$(rl_effectiveness_score)"
    assert_contains "$result" "No episodes" "effectiveness handles no file"
    RL_EPISODES_FILE="$save"
}

# ─── Test: decay factor computation ─────────────────────────────────────────

test_decay_factor() {
    # Recent episode should have factor ~1.0
    local now
    now="$(date +%s)"
    local factor
    factor=$(_rl_decay_factor "$now")
    assert_equals "1.0" "$factor" "decay factor is 1.0 for current epoch"

    # Episode from 30 days ago should have factor ~0.5
    local old_epoch
    old_epoch=$(( now - 2592000 ))
    factor=$(_rl_decay_factor "$old_epoch")
    assert_equals "0.5000" "$factor" "decay factor is 0.5 at half-life"
}

# ─── Test: compose_prompt_section uses globals ──────────────────────────────

test_compose_prompt_section() {
    rm -f "$RL_EPISODES_FILE"
    for i in 1 2 3; do
        rl_record_episode \
            '{"language":"go","complexity":"high","issue_type":"feature"}' \
            '["design","implement","test"]' \
            '{"success":true,"iterations":6,"cost_usd":3.00}' \
            '[]'
    done

    INTELLIGENCE_LANGUAGE="go"
    INTELLIGENCE_ISSUE_TYPE="feature"
    INTELLIGENCE_COMPLEXITY="high"

    local result
    result="$(rl_compose_prompt_section)"
    assert_not_empty "$result" "compose_prompt_section produces output with matching globals"

    unset INTELLIGENCE_LANGUAGE INTELLIGENCE_ISSUE_TYPE INTELLIGENCE_COMPLEXITY
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-rl-optimizer-test.sh"
test_record_episode_creates_file
test_record_episode_structure
test_suggest_empty
test_suggest_with_data
test_suggest_filters_context
test_effectiveness_score
test_inject_context
test_update_weights_success
test_update_weights_failure
test_record_from_pipeline
test_effectiveness_empty
test_decay_factor
test_compose_prompt_section

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
