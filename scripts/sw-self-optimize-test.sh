#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright self-optimize test — Unit tests for learning & tuning system ║
# ║  Mock outcomes · Template weights · Model routing · Memory evolution     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ─── Colors (matches shipwright theme) ────────────────────────────────────
# shellcheck disable=SC2034

# ─── Counters ────────────────────────────────────────────────────────────────

# ═════════════════════════════════════════════════════════════════════════════
# TEST ENVIRONMENT SETUP
# ═════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-self-optimize-test.XXXXXX")

    mkdir -p "$TEST_TEMP_DIR/.shipwright/optimization"
    mkdir -p "$TEST_TEMP_DIR/.shipwright/memory/repo1"
    mkdir -p "$TEST_TEMP_DIR/.shipwright/memory/repo2"
    mkdir -p "$TEST_TEMP_DIR/.shipwright/memory/repo3"

    # Redirect HOME so all scripts write to temp
    export HOME="$TEST_TEMP_DIR"
    export EVENTS_FILE="$TEST_TEMP_DIR/.shipwright/events.jsonl"
    export NO_GITHUB=true

    # Override storage paths for the script under test
    export OPTIMIZATION_DIR="$TEST_TEMP_DIR/.shipwright/optimization"
    export OUTCOMES_FILE="$OPTIMIZATION_DIR/outcomes.jsonl"
    export TEMPLATE_WEIGHTS_FILE="$OPTIMIZATION_DIR/template-weights.json"
    export MODEL_ROUTING_FILE="$OPTIMIZATION_DIR/model-routing.json"
    export ITERATION_MODEL_FILE="$OPTIMIZATION_DIR/iteration-model.json"
}

cleanup_env() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}
trap cleanup_env EXIT

reset_test() {
    rm -f "$EVENTS_FILE"
    rm -f "$OUTCOMES_FILE"
    rm -f "$TEMPLATE_WEIGHTS_FILE"
    rm -f "$MODEL_ROUTING_FILE"
    rm -f "$ITERATION_MODEL_FILE"
    # Re-initialize empty files
    echo '{}' > "$TEMPLATE_WEIGHTS_FILE"
    echo '{}' > "$MODEL_ROUTING_FILE"
    echo '{}' > "$ITERATION_MODEL_FILE"
}

# ═════════════════════════════════════════════════════════════════════════════
# SOURCE FUNCTIONS UNDER TEST
# ═════════════════════════════════════════════════════════════════════════════

source_optimize_functions() {
    # Source the whole script — the BASH_SOURCE guard prevents main() from running.
    # HOME is already set to TEST_TEMP_DIR by setup_env, so storage paths resolve there.
    source "$SCRIPT_DIR/sw-self-optimize.sh"

    # Re-override storage paths with our test-specific locations
    OPTIMIZATION_DIR="$TEST_TEMP_DIR/.shipwright/optimization"
    OUTCOMES_FILE="$OPTIMIZATION_DIR/outcomes.jsonl"
    TEMPLATE_WEIGHTS_FILE="$OPTIMIZATION_DIR/template-weights.json"
    MODEL_ROUTING_FILE="$OPTIMIZATION_DIR/model-routing.json"
    ITERATION_MODEL_FILE="$OPTIMIZATION_DIR/iteration-model.json"
    EVENTS_FILE="$TEST_TEMP_DIR/.shipwright/events.jsonl"
}

# ═════════════════════════════════════════════════════════════════════════════
# MOCK DATA GENERATORS
# ═════════════════════════════════════════════════════════════════════════════

# Create a mock pipeline state file
create_mock_state() {
    local file="$1"
    local issue="${2:-42}"
    local template="${3:-standard}"
    local status="${4:-success}"
    local iterations="${5:-10}"
    local cost="${6:-3.50}"
    local complexity="${7:-5}"
    local model="${8:-opus}"
    local labels="${9:-bug,frontend}"

    cat > "$file" << EOF
issue: #${issue}
template: ${template}
status: ${status}
iterations: ${iterations}
cost: \$${cost}
complexity: ${complexity}
model: ${model}
labels: ${labels}
stages:
  intake: complete
  plan: complete
  build: complete
  test: ${status}
---
EOF
}

# Add synthetic outcome lines to outcomes.jsonl
add_mock_outcome() {
    local template="${1:-standard}"
    local result="${2:-success}"
    local labels="${3:-bug}"
    local model="${4:-opus}"
    local iterations="${5:-10}"
    local cost="${6:-3.50}"
    local complexity="${7:-5}"
    local stages="${8:-[]}"

    jq -c -n \
        --arg ts "$(now_iso)" \
        --arg template "$template" \
        --arg result "$result" \
        --arg labels "$labels" \
        --arg model "$model" \
        --argjson iterations "$iterations" \
        --argjson cost "$cost" \
        --argjson complexity "$complexity" \
        --argjson stages "$stages" \
        '{
            ts: $ts,
            issue: "mock",
            template: $template,
            result: $result,
            labels: $labels,
            model: $model,
            iterations: $iterations,
            cost: $cost,
            complexity: $complexity,
            stages: $stages
        }' >> "$OUTCOMES_FILE"
}

# ═════════════════════════════════════════════════════════════════════════════
# RUN TEST HELPER
# ═════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "
    reset_test

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# TESTS
# ═════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Outcome analysis extracts correct metrics from mock pipeline state
# ──────────────────────────────────────────────────────────────────────────────
test_outcome_analysis() {
    local state_file="$TEST_TEMP_DIR/mock-state.md"
    create_mock_state "$state_file" "42" "standard" "success" "12" "5.25" "7" "opus" "bug,backend"

    optimize_analyze_outcome "$state_file" > /dev/null 2>&1

    # Verify outcome was written
    [[ -f "$OUTCOMES_FILE" ]] || return 1

    local count
    count=$(wc -l < "$OUTCOMES_FILE" | tr -d ' ')
    [[ "$count" -eq 1 ]] || return 1

    # Verify fields
    local issue template result iterations cost
    issue=$(jq -r '.issue' "$OUTCOMES_FILE")
    template=$(jq -r '.template' "$OUTCOMES_FILE")
    result=$(jq -r '.result' "$OUTCOMES_FILE")
    iterations=$(jq -r '.iterations' "$OUTCOMES_FILE")
    cost=$(jq -r '.cost' "$OUTCOMES_FILE")

    [[ "$issue" == "42" ]] || return 1
    [[ "$template" == "standard" ]] || return 1
    [[ "$result" == "success" ]] || return 1
    [[ "$iterations" == "12" ]] || return 1
    [[ "$cost" == "5.25" ]] || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Outcome analysis emits event
# ──────────────────────────────────────────────────────────────────────────────
test_outcome_emits_event() {
    local state_file="$TEST_TEMP_DIR/mock-state.md"
    create_mock_state "$state_file" "99" "fast" "completed" "5" "1.00" "2"

    optimize_analyze_outcome "$state_file" > /dev/null 2>&1

    [[ -f "$EVENTS_FILE" ]] || return 1
    grep -q "optimize.outcome_analyzed" "$EVENTS_FILE" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Outcome analysis rejects missing state file
# ──────────────────────────────────────────────────────────────────────────────
test_outcome_missing_file() {
    local result=0
    optimize_analyze_outcome "/nonexistent/file" > /dev/null 2>&1 || result=$?
    [[ "$result" -ne 0 ]] || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Template weights converge for high-success templates
# ──────────────────────────────────────────────────────────────────────────────
test_template_weight_high_success() {
    # Add 10 successes for standard+bug
    local i
    for i in $(seq 1 10); do
        add_mock_outcome "standard" "success" "bug"
    done

    optimize_tune_templates "$OUTCOMES_FILE" > /dev/null 2>&1

    # With .weights wrapper, check the raw_weights or success_rate
    local success_rate
    success_rate=$(jq -r '.weights.standard.success_rate // 0' "$TEMPLATE_WEIGHTS_FILE" 2>/dev/null || echo "0")
    # 100% success rate for standard template
    awk "BEGIN{exit !($success_rate >= 0.9)}" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Template weights decrease for low-success templates
# ──────────────────────────────────────────────────────────────────────────────
test_template_weight_low_success() {
    # Add 2 successes, 8 failures for fast+feature → 20% success rate
    local i
    for i in 1 2; do
        add_mock_outcome "fast" "success" "feature"
    done
    for i in $(seq 1 8); do
        add_mock_outcome "fast" "failed" "feature"
    done
    # Add high-success template to shift average up (proportional update needs contrast)
    for i in $(seq 1 8); do
        add_mock_outcome "standard" "success" "feature"
    done
    for i in 1 2; do
        add_mock_outcome "standard" "failed" "feature"
    done

    optimize_tune_templates "$OUTCOMES_FILE" > /dev/null 2>&1

    # With .weights wrapper, check fast template success_rate
    local fast_rate
    fast_rate=$(jq -r '.weights.fast.success_rate // 1' "$TEMPLATE_WEIGHTS_FILE" 2>/dev/null || echo "1")
    # fast=20% success rate → should be lower than standard
    awk "BEGIN{exit !($fast_rate < 0.5)}" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. A/B test selects ~20% sample (run 100 iterations, verify 5-40% range)
# ──────────────────────────────────────────────────────────────────────────────
test_ab_test_distribution() {
    local selected=0
    local i
    for i in $(seq 1 100); do
        if optimize_should_ab_test "build"; then
            selected=$((selected + 1))
        fi
    done

    # With 20% probability, expect 5-40 in 100 trials (generous bounds)
    [[ "$selected" -ge 5 ]] || return 1
    [[ "$selected" -le 40 ]] || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Iteration model updates with new data points
# ──────────────────────────────────────────────────────────────────────────────
test_iteration_model() {
    # Low complexity (1-3): iterations 5, 7, 9
    add_mock_outcome "standard" "success" "bug" "opus" 5 "1.00" 2
    add_mock_outcome "standard" "success" "bug" "opus" 7 "1.50" 1
    add_mock_outcome "standard" "success" "bug" "opus" 9 "2.00" 3

    # Medium complexity (4-6): iterations 12, 15, 18
    add_mock_outcome "standard" "success" "bug" "opus" 12 "3.00" 5
    add_mock_outcome "standard" "success" "bug" "opus" 15 "4.00" 4
    add_mock_outcome "standard" "success" "bug" "opus" 18 "5.00" 6

    # High complexity (7-10): iterations 20, 25, 30
    add_mock_outcome "standard" "success" "bug" "opus" 20 "7.00" 8
    add_mock_outcome "standard" "success" "bug" "opus" 25 "8.00" 9
    add_mock_outcome "standard" "success" "bug" "opus" 30 "9.00" 10

    optimize_learn_iterations "$OUTCOMES_FILE" > /dev/null 2>&1

    [[ -f "$ITERATION_MODEL_FILE" ]] || return 1

    # Flat format: access via .low, .medium, .high (no .predictions wrapper)
    local low_mean
    low_mean=$(jq '.low.mean' "$ITERATION_MODEL_FILE")
    awk "BEGIN{exit !($low_mean >= 6 && $low_mean <= 8)}" || return 1

    # Verify medium samples = 3
    local med_samples
    med_samples=$(jq '.medium.samples' "$ITERATION_MODEL_FILE")
    [[ "$med_samples" -eq 3 ]] || return 1

    # Verify high mean is ~25 (20+25+30)/3
    local high_mean
    high_mean=$(jq '.high.mean' "$ITERATION_MODEL_FILE")
    awk "BEGIN{exit !($high_mean >= 24 && $high_mean <= 26)}" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Model routing tracks success rates correctly
# ──────────────────────────────────────────────────────────────────────────────
test_model_routing() {
    local build_stages='[{"name":"build","status":"complete"},{"name":"test","status":"complete"}]'
    # shellcheck disable=SC2034
    local fail_stages='[{"name":"build","status":"complete"},{"name":"test","status":"failed"}]'

    # Sonnet: 5 successes on build
    local i
    for i in $(seq 1 5); do
        add_mock_outcome "standard" "success" "bug" "sonnet" 10 "1.00" 5 "$build_stages"
    done

    # Opus: 3 successes on build
    for i in $(seq 1 3); do
        add_mock_outcome "standard" "success" "bug" "opus" 10 "3.00" 5 "$build_stages"
    done

    optimize_route_models "$OUTCOMES_FILE" > /dev/null 2>&1

    [[ -f "$MODEL_ROUTING_FILE" ]] || return 1

    # With .routes wrapper, access via .routes.build
    local build_rec
    build_rec=$(jq -r '.routes.build.model // "none"' "$MODEL_ROUTING_FILE")
    [[ "$build_rec" == "sonnet" ]] || return 1

    # Verify sample counts
    local sonnet_n
    sonnet_n=$(jq '.routes.build.sonnet_samples' "$MODEL_ROUTING_FILE")
    [[ "$sonnet_n" -eq 5 ]] || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Model routing keeps opus when sonnet data insufficient
# ──────────────────────────────────────────────────────────────────────────────
test_model_routing_insufficient_data() {
    local build_stages='[{"name":"build","status":"complete"}]'

    # Only 2 sonnet samples (below threshold of 3)
    add_mock_outcome "standard" "success" "bug" "sonnet" 10 "1.00" 5 "$build_stages"
    add_mock_outcome "standard" "success" "bug" "sonnet" 10 "1.00" 5 "$build_stages"

    # 5 opus samples
    local i
    for i in $(seq 1 5); do
        add_mock_outcome "standard" "success" "bug" "opus" 10 "3.00" 5 "$build_stages"
    done

    optimize_route_models "$OUTCOMES_FILE" > /dev/null 2>&1

    local build_rec
    build_rec=$(jq -r '.routes.build.model // "none"' "$MODEL_ROUTING_FILE")
    [[ "$build_rec" == "opus" ]] || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Memory pruning removes old patterns (>30 days), keeps recent ones
# ──────────────────────────────────────────────────────────────────────────────
test_memory_pruning() {
    local mem_dir="$TEST_TEMP_DIR/.shipwright/memory/repo1"
    mkdir -p "$mem_dir"

    # Create failures.json with one old and one recent pattern
    local old_date="2025-01-01T00:00:00Z"
    local recent_date
    recent_date=$(now_iso)

    jq -n \
        --arg old "$old_date" \
        --arg recent "$recent_date" \
        '{failures: [
            {pattern: "old error", stage: "build", seen_count: 1, last_seen: $old},
            {pattern: "recent error", stage: "test", seen_count: 2, last_seen: $recent}
        ]}' > "$mem_dir/failures.json"

    # Initialize global.json
    echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$TEST_TEMP_DIR/.shipwright/memory/global.json"

    optimize_evolve_memory > /dev/null 2>&1

    # Old pattern should be pruned
    local count
    count=$(jq '.failures | length' "$mem_dir/failures.json")
    [[ "$count" -eq 1 ]] || return 1

    # Remaining pattern should be the recent one
    local remaining
    remaining=$(jq -r '.failures[0].pattern' "$mem_dir/failures.json")
    [[ "$remaining" == "recent error" ]] || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Memory strengthening increases weight for confirmed patterns
# ──────────────────────────────────────────────────────────────────────────────
test_memory_strengthening() {
    local mem_dir="$TEST_TEMP_DIR/.shipwright/memory/repo1"
    mkdir -p "$mem_dir"

    local recent_date
    recent_date=$(now_iso)

    # Pattern seen 5 times recently — should be strengthened
    jq -n \
        --arg recent "$recent_date" \
        '{failures: [
            {pattern: "flaky test", stage: "test", seen_count: 5, last_seen: $recent, weight: 1.0}
        ]}' > "$mem_dir/failures.json"

    echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$TEST_TEMP_DIR/.shipwright/memory/global.json"

    optimize_evolve_memory > /dev/null 2>&1

    local weight
    weight=$(jq '.failures[0].weight' "$mem_dir/failures.json")
    # Should be boosted: 1.0 * 1.5 = 1.5
    awk "BEGIN{exit !($weight > 1.0)}" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 11b. Prune cutoff is a real 30-day-old timestamp, not "now"
# Regression: the cutoff was built with `date -u -r <epoch> || date -u`, and on
# GNU date `-r` means "this file's mtime", so the fallback produced the current
# second. Everything not written in that exact second was pruned.
# ──────────────────────────────────────────────────────────────────────────────
test_memory_prune_cutoff_is_not_now() {
    local mem_dir="$TEST_TEMP_DIR/.shipwright/memory/repo1"
    mkdir -p "$mem_dir"

    # One hour old: far inside the 30-day window, but not the current second.
    local hour_old
    hour_old=$(epoch_to_iso "$(( $(now_epoch) - 3600 ))")

    jq -n --arg ts "$hour_old" \
        '{failures: [{pattern: "hour old error", stage: "build", seen_count: 1, last_seen: $ts}]}' \
        > "$mem_dir/failures.json"

    echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$TEST_TEMP_DIR/.shipwright/memory/global.json"

    optimize_evolve_memory > /dev/null 2>&1

    local count
    count=$(jq '.failures | length' "$mem_dir/failures.json")
    [[ "$count" -eq 1 ]] || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Memory promotion copies cross-repo patterns to global.json
# ──────────────────────────────────────────────────────────────────────────────
test_memory_promotion() {
    local recent_date
    recent_date=$(now_iso)

    # Same pattern in 3 different repos
    local repo_dir
    for repo_dir in repo1 repo2 repo3; do
        mkdir -p "$TEST_TEMP_DIR/.shipwright/memory/$repo_dir"
        jq -n \
            --arg recent "$recent_date" \
            '{failures: [
                {pattern: "shared error pattern", stage: "build", seen_count: 2, last_seen: $recent}
            ]}' > "$TEST_TEMP_DIR/.shipwright/memory/$repo_dir/failures.json"
    done

    local global_file="$TEST_TEMP_DIR/.shipwright/memory/global.json"
    echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$global_file"

    optimize_evolve_memory > /dev/null 2>&1

    # Pattern should appear in global common_patterns
    local global_count
    global_count=$(jq '.common_patterns | length' "$global_file")
    [[ "$global_count" -ge 1 ]] || return 1

    local promoted_pattern
    promoted_pattern=$(jq -r '.common_patterns[0].pattern' "$global_file")
    [[ "$promoted_pattern" == "shared error pattern" ]] || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Full analysis runs without errors on empty data
# ──────────────────────────────────────────────────────────────────────────────
test_full_analysis_empty() {
    # Should complete without error even with no data
    echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$TEST_TEMP_DIR/.shipwright/memory/global.json"
    optimize_full_analysis > /dev/null 2>&1
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Report generates output with data
# ──────────────────────────────────────────────────────────────────────────────
test_report_with_data() {
    # Add some recent outcomes
    add_mock_outcome "standard" "success" "bug" "opus" 10 "3.50" 5
    add_mock_outcome "standard" "success" "feature" "opus" 15 "5.00" 7
    add_mock_outcome "fast" "failed" "bug" "sonnet" 20 "2.00" 3

    local output
    output=$(optimize_report 2>&1)

    # Should contain key report sections
    echo "$output" | grep "Last 7 Days" >/dev/null || return 1
    echo "$output" | grep "Pipelines:" >/dev/null || return 1
    echo "$output" | grep "Success rate:" >/dev/null || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Report handles empty outcomes gracefully
# ──────────────────────────────────────────────────────────────────────────────
test_report_empty() {
    local output
    output=$(optimize_report 2>&1)
    echo "$output" | grep "No outcomes data" >/dev/null || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. Outcome analysis extracts stage data
# ──────────────────────────────────────────────────────────────────────────────
test_outcome_stages() {
    local state_file="$TEST_TEMP_DIR/mock-state-stages.md"
    create_mock_state "$state_file" "55" "full" "success" "8" "4.00" "6"

    optimize_analyze_outcome "$state_file" > /dev/null 2>&1

    # Verify stages were captured
    local stage_count
    stage_count=$(jq '.stages | length' "$OUTCOMES_FILE")
    [[ "$stage_count" -ge 1 ]] || return 1

    # First stage should be intake
    local first_stage
    first_stage=$(jq -r '.stages[0].name' "$OUTCOMES_FILE")
    [[ "$first_stage" == "intake" ]] || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. Template weights output has .weights wrapper
# ──────────────────────────────────────────────────────────────────────────────
test_template_weights_format() {
    reset_test

    # Add enough outcomes to trigger weight calculation (multiple templates)
    for i in 1 2 3 4 5; do
        add_mock_outcome "fast" "success" "5" "1.00" "low" "opus" "bug"
    done
    for i in 1 2 3 4 5; do
        add_mock_outcome "standard" "failure" "15" "5.00" "medium" "opus" "feature"
    done

    optimize_tune_templates > /dev/null 2>&1

    # Verify the file has a .weights top-level key
    local has_weights
    has_weights=$(jq 'has("weights")' "$TEMPLATE_WEIGHTS_FILE" 2>/dev/null || echo "false")
    [[ "$has_weights" == "true" ]] || { echo "Expected .weights wrapper in template-weights.json"; return 1; }

    # Verify updated_at is present
    local has_updated
    has_updated=$(jq 'has("updated_at")' "$TEMPLATE_WEIGHTS_FILE" 2>/dev/null || echo "false")
    [[ "$has_updated" == "true" ]] || { echo "Expected .updated_at in template-weights.json"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 18. Iteration model output has flat format (.low, .medium, .high)
# ──────────────────────────────────────────────────────────────────────────────
test_iteration_model_format() {
    reset_test

    # Add outcomes across complexity buckets
    for i in 1 2 3 4 5; do
        add_mock_outcome "standard" "success" "8" "2.00" "low" "opus" "bug"
    done
    for i in 1 2 3 4 5; do
        add_mock_outcome "standard" "success" "15" "4.00" "medium" "opus" "feature"
    done

    optimize_learn_iterations > /dev/null 2>&1

    # Verify flat format: low/medium/high at root level (no .predictions wrapper)
    local has_low has_medium has_high
    has_low=$(jq 'has("low")' "$ITERATION_MODEL_FILE" 2>/dev/null || echo "false")
    has_medium=$(jq 'has("medium")' "$ITERATION_MODEL_FILE" 2>/dev/null || echo "false")
    has_high=$(jq 'has("high")' "$ITERATION_MODEL_FILE" 2>/dev/null || echo "false")
    [[ "$has_low" == "true" && "$has_medium" == "true" && "$has_high" == "true" ]] || \
        { echo "Expected .{low,medium,high} at root level"; return 1; }

    # Verify max_iterations field exists
    local max_iter
    max_iter=$(jq '.low.max_iterations // 0' "$ITERATION_MODEL_FILE" 2>/dev/null || echo "0")
    [[ "$max_iter" -gt 0 ]] || { echo "Expected max_iterations > 0, got $max_iter"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 19. Model routing output has .routes wrapper
# ──────────────────────────────────────────────────────────────────────────────
test_model_routing_format() {
    reset_test

    # Add enough outcomes to build model routing
    for i in 1 2 3 4 5 6 7 8; do
        add_mock_outcome "standard" "success" "10" "2.00" "medium" "sonnet" "bug"
    done
    for i in 1 2 3 4 5 6 7 8; do
        add_mock_outcome "standard" "failure" "10" "5.00" "medium" "opus" "feature"
    done

    optimize_route_models > /dev/null 2>&1

    # Verify .routes wrapper
    local has_routes
    has_routes=$(jq 'has("routes")' "$MODEL_ROUTING_FILE" 2>/dev/null || echo "false")
    [[ "$has_routes" == "true" ]] || { echo "Expected .routes wrapper in model-routing.json"; return 1; }

    # Verify updated_at is present
    local has_updated
    has_updated=$(jq 'has("updated_at")' "$MODEL_ROUTING_FILE" 2>/dev/null || echo "false")
    [[ "$has_updated" == "true" ]] || { echo "Expected .updated_at in model-routing.json"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 20. Full analysis calls report and writes last-report.txt
# ──────────────────────────────────────────────────────────────────────────────
test_full_analysis_calls_report() {
    reset_test

    # Add minimal outcomes so full analysis can run
    for i in 1 2 3; do
        add_mock_outcome "standard" "success" "10" "2.00" "medium" "opus" "bug"
    done

    optimize_full_analysis > /dev/null 2>&1

    # Verify last-report.txt was created by the report step
    local report_file="$OPTIMIZATION_DIR/last-report.txt"
    [[ -f "$report_file" ]] || { echo "Expected last-report.txt to exist"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 21. Context efficiency with no events gracefully skips
# ──────────────────────────────────────────────────────────────────────────────
test_context_efficiency_no_events() {
    reset_test
    rm -f "$EVENTS_FILE"

    local output
    output=$(optimize_tune_context_efficiency 2>&1)
    echo "$output" | grep "No events file\|No context efficiency\|skipping" >/dev/null || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 22. Context efficiency detects high budget utilization (>90%)
# ──────────────────────────────────────────────────────────────────────────────
test_context_efficiency_high_utilization() {
    reset_test
    mkdir -p "$(dirname "$EVENTS_FILE")"

    # Write 5 events with budget_utilization > 90%
    local i
    for i in 1 2 3 4 5; do
        echo '{"ts":"2026-02-27T10:00:00Z","type":"loop.context_efficiency","iteration":"'$i'","raw_prompt_chars":"190000","trimmed_prompt_chars":"180000","trim_ratio":"5.3","budget_utilization":"95.0","budget_chars":"180000","job_id":"test-1"}' >> "$EVENTS_FILE"
    done

    local output
    output=$(optimize_tune_context_efficiency 2>&1)

    # Should recommend increasing budget
    echo "$output" | grep "Budget utilization high" >/dev/null || { echo "Expected budget increase recommendation"; return 1; }

    # Should emit recommendation event
    grep -q "optimize.context_recommendation" "$EVENTS_FILE" || { echo "Expected recommendation event"; return 1; }

    # Should write summary file
    local summary_file="$OPTIMIZATION_DIR/context-efficiency.json"
    [[ -f "$summary_file" ]] || { echo "Expected context-efficiency.json"; return 1; }

    local rec_count
    rec_count=$(jq '.recommendation_count' "$summary_file" 2>/dev/null)
    [[ "$rec_count" -ge 1 ]] || { echo "Expected at least 1 recommendation, got $rec_count"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 23. Context efficiency detects high trim ratio (>30%)
# ──────────────────────────────────────────────────────────────────────────────
test_context_efficiency_high_trim() {
    reset_test
    mkdir -p "$(dirname "$EVENTS_FILE")"

    # Write 5 events with trim_ratio > 30%
    local i
    for i in 1 2 3 4 5; do
        echo '{"ts":"2026-02-27T10:00:00Z","type":"loop.context_efficiency","iteration":"'$i'","raw_prompt_chars":"260000","trimmed_prompt_chars":"180000","trim_ratio":"35.0","budget_utilization":"80.0","budget_chars":"180000","job_id":"test-2"}' >> "$EVENTS_FILE"
    done

    local output
    output=$(optimize_tune_context_efficiency 2>&1)

    # Should recommend reducing verbose context
    echo "$output" | grep "Trim ratio high" >/dev/null || { echo "Expected trim reduction recommendation"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 24. Context efficiency healthy — no recommendations
# ──────────────────────────────────────────────────────────────────────────────
test_context_efficiency_healthy() {
    reset_test
    mkdir -p "$(dirname "$EVENTS_FILE")"

    # Write 5 events with healthy metrics
    local i
    for i in 1 2 3 4 5; do
        echo '{"ts":"2026-02-27T10:00:00Z","type":"loop.context_efficiency","iteration":"'$i'","raw_prompt_chars":"140000","trimmed_prompt_chars":"135000","trim_ratio":"3.6","budget_utilization":"75.0","budget_chars":"180000","job_id":"test-3"}' >> "$EVENTS_FILE"
    done

    local output
    output=$(optimize_tune_context_efficiency 2>&1)

    # Should report healthy
    echo "$output" | grep "healthy" >/dev/null || { echo "Expected healthy status"; return 1; }

    # Summary should have 0 recommendations
    local summary_file="$OPTIMIZATION_DIR/context-efficiency.json"
    [[ -f "$summary_file" ]] || { echo "Expected context-efficiency.json"; return 1; }
    local rec_count
    rec_count=$(jq '.recommendation_count' "$summary_file" 2>/dev/null)
    [[ "$rec_count" -eq 0 ]] || { echo "Expected 0 recommendations, got $rec_count"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 25. Context efficiency is called during full analysis
# ──────────────────────────────────────────────────────────────────────────────
test_full_analysis_includes_context_efficiency() {
    reset_test
    mkdir -p "$(dirname "$EVENTS_FILE")"

    # Add context efficiency events
    local i
    for i in 1 2 3 4 5; do
        echo '{"ts":"2026-02-27T10:00:00Z","type":"loop.context_efficiency","iteration":"'$i'","raw_prompt_chars":"140000","trimmed_prompt_chars":"135000","trim_ratio":"3.6","budget_utilization":"75.0","budget_chars":"180000","job_id":"test-full"}' >> "$EVENTS_FILE"
    done

    # Add minimal outcomes
    for i in 1 2 3; do
        add_mock_outcome "standard" "success" "bug" "opus" 10 "2.00" 5
    done

    echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$TEST_TEMP_DIR/.shipwright/memory/global.json"

    optimize_full_analysis > /dev/null 2>&1

    # Context efficiency summary should exist
    local summary_file="$OPTIMIZATION_DIR/context-efficiency.json"
    [[ -f "$summary_file" ]] || { echo "Expected context-efficiency.json from full analysis"; return 1; }
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ shipwright self-optimize tests ━━━${RESET}"
    echo ""

    setup_env
    source_optimize_functions

    local tests=(
        "test_outcome_analysis:Outcome analysis extracts correct metrics"
        "test_outcome_emits_event:Outcome analysis emits event"
        "test_outcome_missing_file:Outcome analysis rejects missing file"
        "test_template_weight_high_success:Template weight increases for high success"
        "test_template_weight_low_success:Template weight decreases for low success"
        "test_ab_test_distribution:A/B test selects ~20% sample"
        "test_iteration_model:Iteration model updates with data points"
        "test_model_routing:Model routing tracks success rates"
        "test_model_routing_insufficient_data:Model routing keeps opus with few sonnet samples"
        "test_memory_pruning:Memory pruning removes old patterns"
        "test_memory_strengthening:Memory strengthening boosts confirmed patterns"
        "test_memory_prune_cutoff_is_not_now:Memory prune cutoff is 30 days back, not now"
        "test_memory_promotion:Memory promotion copies cross-repo patterns"
        "test_full_analysis_empty:Full analysis runs on empty data"
        "test_report_with_data:Report generates output with data"
        "test_report_empty:Report handles empty outcomes"
        "test_outcome_stages:Outcome analysis extracts stage data"
        "test_template_weights_format:Template weights output has .weights wrapper"
        "test_iteration_model_format:Iteration model output has flat format"
        "test_model_routing_format:Model routing output has .routes wrapper"
        "test_full_analysis_calls_report:Full analysis creates last-report.txt"
        "test_context_efficiency_no_events:Context efficiency skips with no events"
        "test_context_efficiency_high_utilization:Context efficiency detects high budget utilization"
        "test_context_efficiency_high_trim:Context efficiency detects high trim ratio"
        "test_context_efficiency_healthy:Context efficiency reports healthy when metrics normal"
        "test_full_analysis_includes_context_efficiency:Full analysis includes context efficiency"
    )

    for entry in "${tests[@]}"; do
        local fn="${entry%%:*}"
        local desc="${entry#*:}"

        if [[ -n "$filter" && "$fn" != "$filter" ]]; then
            continue
        fi

        run_test "$desc" "$fn"
    done

    # ── Summary ───────────────────────────────────────────────────────────
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Results ━━━${RESET}"
    echo -e "  ${GREEN}Passed:${RESET} $PASS"
    echo -e "  ${RED}Failed:${RESET} $FAIL"
    echo -e "  ${DIM}Total:${RESET}  $TOTAL"
    echo ""

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "${RED}${BOLD}Failed tests:${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
        exit 1
    fi

    echo -e "${GREEN}${BOLD}All $PASS tests passed!${RESET}"
    echo ""
    exit 0
}

main "$@"
