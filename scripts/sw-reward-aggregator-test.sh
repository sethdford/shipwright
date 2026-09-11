#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-reward-aggregator-test.sh — Reward Aggregator Test Suite             ║
# ║  12+ tests covering composite reward computation, history, baseline,     ║
# ║  trend detection, feedback injection, and edge cases                     ║
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

assert_in_range() {
    local min="$1" max="$2" actual="$3" description="${4:-}"
    if awk -v a="$actual" -v mn="$min" -v mx="$max" 'BEGIN { exit (a >= mn && a <= mx) ? 0 : 1 }'; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected range: [$min, $max]"
        echo "    Actual: $actual"
    fi
}

# ─── Setup / Teardown ──────────────────────────────────────────────────────
TEST_DIR=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/reward-test-$$")
[[ -d "$TEST_DIR" ]] || mkdir -p "$TEST_DIR"
ARTIFACTS_DIR="$TEST_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Override all file paths to use test directory
export REWARDS_FILE="$TEST_DIR/rewards.jsonl"
export PROCESS_REWARDS_FILE="$ARTIFACTS_DIR/process-rewards.jsonl"
export COSTS_FILE="$TEST_DIR/costs.json"
export STAGE_EFFECTIVENESS_FILE="$ARTIFACTS_DIR/stage-effectiveness.jsonl"
export RECOVERY_LOG_FILE="$ARTIFACTS_DIR/recovery-log.jsonl"
export QUALITY_SCORES_FILE="$ARTIFACTS_DIR/quality-scores.jsonl"
export MEMORY_OUTCOMES_FILE="$ARTIFACTS_DIR/memory-outcomes.jsonl"

# Source the library
# shellcheck source=lib/reward-aggregator.sh
source "$SCRIPT_DIR/lib/reward-aggregator.sh"

# ─── Test 1: Aggregate with no data files returns defaults ──────────────────
test_aggregate_no_data() {
    rm -f "$REWARDS_FILE"
    local output
    output=$(reward_aggregate_pipeline "test-001" "bash" "low")
    local reward
    reward=$(echo "$output" | jq -r '.reward')
    # All defaults are 0.5, so composite should be 0.5
    assert_equals "0.5000" "$reward" "aggregate with no data returns 0.5 default"
}

# ─── Test 2: Aggregate with perfect scores ──────────────────────────────────
test_aggregate_perfect() {
    rm -f "$REWARDS_FILE"
    # Create perfect process-rewards
    echo '{"pipeline_id":"perfect-001","scores":{"test_outcome":1.0},"iteration":1,"max_iterations":10}' > "$PROCESS_REWARDS_FILE"
    # Perfect cost efficiency
    echo '{"total_cost":1,"budget":100}' > "$COSTS_FILE"
    # All stages passed
    echo '{"stage":"build","status":"passed"}' > "$STAGE_EFFECTIVENESS_FILE"
    echo '{"stage":"test","status":"passed"}' >> "$STAGE_EFFECTIVENESS_FILE"
    echo '{"stage":"review","status":"passed"}' >> "$STAGE_EFFECTIVENESS_FILE"
    # Perfect quality
    echo '{"pipeline_id":"perfect-001","score":1.0}' > "$QUALITY_SCORES_FILE"
    # Perfect memory
    echo '{"hit":true}' > "$MEMORY_OUTCOMES_FILE"
    echo '{"hit":true}' >> "$MEMORY_OUTCOMES_FILE"

    local output
    output=$(reward_aggregate_pipeline "perfect-001" "ts" "low")
    local reward
    reward=$(echo "$output" | jq -r '.reward')
    # test=1.0*0.3 + iter=(1-0.1)*0.2=0.18 + cost=0.99*0.15=0.1485 + qual=1.0*0.15 + conv=1.0*0.1 + mem=1.0*0.1 = 0.9285
    assert_in_range "0.85" "1.0" "$reward" "aggregate with near-perfect scores is high"

    # Clean up
    rm -f "$PROCESS_REWARDS_FILE" "$COSTS_FILE" "$STAGE_EFFECTIVENESS_FILE" "$QUALITY_SCORES_FILE" "$MEMORY_OUTCOMES_FILE"
}

# ─── Test 3: Aggregate with poor scores ─────────────────────────────────────
test_aggregate_poor() {
    rm -f "$REWARDS_FILE"
    # Failed tests
    echo '{"pipeline_id":"poor-001","scores":{"test_outcome":0.0},"iteration":10,"max_iterations":10}' > "$PROCESS_REWARDS_FILE"
    # Over budget
    echo '{"total_cost":100,"budget":50}' > "$COSTS_FILE"
    # All stages failed
    echo '{"stage":"build","status":"failed"}' > "$STAGE_EFFECTIVENESS_FILE"
    echo '{"stage":"test","status":"failed"}' >> "$STAGE_EFFECTIVENESS_FILE"
    # Zero quality
    echo '{"pipeline_id":"poor-001","score":0.0}' > "$QUALITY_SCORES_FILE"
    # No memory hits
    echo '{"hit":false}' > "$MEMORY_OUTCOMES_FILE"
    echo '{"hit":false}' >> "$MEMORY_OUTCOMES_FILE"

    local output
    output=$(reward_aggregate_pipeline "poor-001" "go" "high")
    local reward
    reward=$(echo "$output" | jq -r '.reward')
    assert_in_range "0.0" "0.15" "$reward" "aggregate with poor scores is low"

    rm -f "$PROCESS_REWARDS_FILE" "$COSTS_FILE" "$STAGE_EFFECTIVENESS_FILE" "$QUALITY_SCORES_FILE" "$MEMORY_OUTCOMES_FILE"
}

# ─── Test 4: Output JSON structure is correct ───────────────────────────────
test_output_structure() {
    rm -f "$REWARDS_FILE"
    local output
    output=$(reward_aggregate_pipeline "struct-001" "python" "medium")

    local has_ts has_pid has_reward has_components has_context
    has_ts=$(echo "$output" | jq 'has("timestamp")')
    has_pid=$(echo "$output" | jq 'has("pipeline_id")')
    has_reward=$(echo "$output" | jq 'has("reward")')
    has_components=$(echo "$output" | jq 'has("components")')
    has_context=$(echo "$output" | jq 'has("context")')

    assert_equals "true" "$has_ts" "output has timestamp"
    assert_equals "true" "$has_pid" "output has pipeline_id"
    assert_equals "true" "$has_reward" "output has reward"
    assert_equals "true" "$has_components" "output has components"
    assert_equals "true" "$has_context" "output has context"

    local lang
    lang=$(echo "$output" | jq -r '.context.language')
    assert_equals "python" "$lang" "context.language is correct"
}

# ─── Test 5: Rewards file is appended ───────────────────────────────────────
test_rewards_appended() {
    rm -f "$REWARDS_FILE"
    reward_aggregate_pipeline "append-001" > /dev/null
    reward_aggregate_pipeline "append-002" > /dev/null
    reward_aggregate_pipeline "append-003" > /dev/null

    local count
    count=$(wc -l < "$REWARDS_FILE" | tr -d ' ')
    assert_equals "3" "$count" "rewards file has 3 entries after 3 calls"
}

# ─── Test 6: Get history returns correct count ──────────────────────────────
test_get_history() {
    rm -f "$REWARDS_FILE"
    reward_aggregate_pipeline "hist-001" > /dev/null
    reward_aggregate_pipeline "hist-002" > /dev/null
    reward_aggregate_pipeline "hist-003" > /dev/null
    reward_aggregate_pipeline "hist-004" > /dev/null
    reward_aggregate_pipeline "hist-005" > /dev/null

    local history count
    history=$(reward_get_history 3)
    count=$(echo "$history" | jq 'length')
    assert_equals "3" "$count" "get_history(3) returns 3 entries"

    local all_count
    all_count=$(echo "$(reward_get_history)" | jq 'length')
    assert_equals "5" "$all_count" "get_history() returns all 5 entries"
}

# ─── Test 7: Get history with no file returns empty array ───────────────────
test_get_history_empty() {
    rm -f "$REWARDS_FILE"
    local history
    history=$(reward_get_history)
    assert_equals "[]" "$history" "get_history with no file returns []"
}

# ─── Test 8: Compute baseline returns average ──────────────────────────────
test_compute_baseline() {
    rm -f "$REWARDS_FILE"
    # Write rewards with known values
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"bl-001\",\"reward\":0.8}" >> "$REWARDS_FILE"
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"bl-002\",\"reward\":0.6}" >> "$REWARDS_FILE"
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"bl-003\",\"reward\":0.4}" >> "$REWARDS_FILE"

    local baseline
    baseline=$(reward_compute_baseline 30)
    # Average of 0.8, 0.6, 0.4 = 0.6
    assert_equals "0.6000" "$baseline" "baseline is average of rewards (0.6)"
}

# ─── Test 9: Compute baseline with no data returns 0.5 ─────────────────────
test_compute_baseline_empty() {
    rm -f "$REWARDS_FILE"
    local baseline
    baseline=$(reward_compute_baseline)
    assert_equals "0.5000" "$baseline" "baseline with no data returns 0.5"
}

# ─── Test 10: Is improving detects upward trend ────────────────────────────
test_is_improving_up() {
    rm -f "$REWARDS_FILE"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # Older low scores
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"imp-001\",\"reward\":0.3}" >> "$REWARDS_FILE"
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"imp-002\",\"reward\":0.3}" >> "$REWARDS_FILE"
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"imp-003\",\"reward\":0.3}" >> "$REWARDS_FILE"
    # Recent high scores
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"imp-004\",\"reward\":0.9}" >> "$REWARDS_FILE"
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"imp-005\",\"reward\":0.9}" >> "$REWARDS_FILE"

    local result improving
    result=$(reward_is_improving 2 30)
    improving=$(echo "$result" | jq -r '.improving')
    assert_equals "true" "$improving" "detects improving trend (recent > baseline)"
}

# ─── Test 11: Is improving detects downward trend ──────────────────────────
test_is_improving_down() {
    rm -f "$REWARDS_FILE"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # Older high scores
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"dec-001\",\"reward\":0.9}" >> "$REWARDS_FILE"
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"dec-002\",\"reward\":0.9}" >> "$REWARDS_FILE"
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"dec-003\",\"reward\":0.9}" >> "$REWARDS_FILE"
    # Recent low scores
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"dec-004\",\"reward\":0.2}" >> "$REWARDS_FILE"
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"dec-005\",\"reward\":0.2}" >> "$REWARDS_FILE"

    local result improving
    result=$(reward_is_improving 2 30)
    improving=$(echo "$result" | jq -r '.improving')
    assert_equals "false" "$improving" "detects declining trend (recent < baseline)"
}

# ─── Test 12: Inject feedback formats markdown ─────────────────────────────
test_inject_feedback() {
    rm -f "$REWARDS_FILE"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"fb-001\",\"reward\":0.5}" >> "$REWARDS_FILE"
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"fb-002\",\"reward\":0.5}" >> "$REWARDS_FILE"
    echo "{\"timestamp\":\"$ts\",\"pipeline_id\":\"fb-003\",\"reward\":0.8}" >> "$REWARDS_FILE"

    local feedback
    feedback=$(reward_inject_feedback)
    assert_contains "Your pipeline performance:" "$feedback" "feedback contains performance header"
    assert_contains "baseline" "$feedback" "feedback mentions baseline"
}

# ─── Test 13: Clamp function bounds values ──────────────────────────────────
test_clamp() {
    local low high normal
    low=$(_reward_clamp "-0.5")
    high=$(_reward_clamp "1.5")
    normal=$(_reward_clamp "0.75")

    assert_equals "0.0000" "$low" "clamp(-0.5) = 0.0"
    assert_equals "1.0000" "$high" "clamp(1.5) = 1.0"
    assert_equals "0.7500" "$normal" "clamp(0.75) = 0.75"
}

# ─── Test 14: Division by zero guard ────────────────────────────────────────
test_div_zero() {
    local result
    result=$(_reward_div "5" "0")
    assert_equals "5.0000" "$result" "div(5,0) returns 5 (zero guard)"
}

# ─── Test 15: Components are present in output ─────────────────────────────
test_components_present() {
    rm -f "$REWARDS_FILE"
    local output
    output=$(reward_aggregate_pipeline "comp-001")

    local keys
    keys=$(echo "$output" | jq -r '.components | keys[]' | sort | tr '\n' ',')
    assert_contains "convergence_speed" "$keys" "components has convergence_speed"
    assert_contains "cost_efficiency" "$keys" "components has cost_efficiency"
    assert_contains "iteration_efficiency" "$keys" "components has iteration_efficiency"
    assert_contains "memory_hit_rate" "$keys" "components has memory_hit_rate"
    assert_contains "quality_score" "$keys" "components has quality_score"
    assert_contains "test_outcome" "$keys" "components has test_outcome"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-reward-aggregator-test.sh"
echo ""

echo "Signal extraction & aggregation:"
test_aggregate_no_data
test_aggregate_perfect
test_aggregate_poor

echo ""
echo "Output structure:"
test_output_structure
test_components_present

echo ""
echo "History & persistence:"
test_rewards_appended
test_get_history
test_get_history_empty

echo ""
echo "Baseline & trends:"
test_compute_baseline
test_compute_baseline_empty
test_is_improving_up
test_is_improving_down

echo ""
echo "Feedback injection:"
test_inject_feedback

echo ""
echo "Edge cases:"
test_clamp
test_div_zero

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
