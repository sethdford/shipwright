#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright self-optimize test — Unit tests for learning & tuning system ║
# ║  Mock outcomes · Template weights · Model routing · Memory evolution     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═════════════════════════════════════════════════════════════════════════════
# TEST ENVIRONMENT SETUP
# ═════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-self-optimize-test.XXXXXX")

    mkdir -p "$TEMP_DIR/.shipwright/optimization"
    mkdir -p "$TEMP_DIR/.shipwright/memory/repo1"
    mkdir -p "$TEMP_DIR/.shipwright/memory/repo2"
    mkdir -p "$TEMP_DIR/.shipwright/memory/repo3"

    # Redirect HOME so all scripts write to temp
    export HOME="$TEMP_DIR"
    export EVENTS_FILE="$TEMP_DIR/.shipwright/events.jsonl"
    export NO_GITHUB=true

    # Override storage paths for the script under test
    export OPTIMIZATION_DIR="$TEMP_DIR/.shipwright/optimization"
    export OUTCOMES_FILE="$OPTIMIZATION_DIR/outcomes.jsonl"
    export TEMPLATE_WEIGHTS_FILE="$OPTIMIZATION_DIR/template-weights.json"
    export MODEL_ROUTING_FILE="$OPTIMIZATION_DIR/model-routing.json"
    export ITERATION_MODEL_FILE="$OPTIMIZATION_DIR/iteration-model.json"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
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
    # HOME is already set to TEMP_DIR by setup_env, so storage paths resolve there.
    source "$SCRIPT_DIR/sw-self-optimize.sh"

    # Re-override storage paths with our test-specific locations
    OPTIMIZATION_DIR="$TEMP_DIR/.shipwright/optimization"
    OUTCOMES_FILE="$OPTIMIZATION_DIR/outcomes.jsonl"
    TEMPLATE_WEIGHTS_FILE="$OPTIMIZATION_DIR/template-weights.json"
    MODEL_ROUTING_FILE="$OPTIMIZATION_DIR/model-routing.json"
    ITERATION_MODEL_FILE="$OPTIMIZATION_DIR/iteration-model.json"
    EVENTS_FILE="$TEMP_DIR/.shipwright/events.jsonl"
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
    local state_file="$TEMP_DIR/mock-state.md"
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
    local state_file="$TEMP_DIR/mock-state.md"
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

    # Weight should be >= 1.0 (boosted or capped at 1.0)
    local weight
    weight=$(jq -r '.["standard|bug"] // 0' "$TEMPLATE_WEIGHTS_FILE")
    # 100% success rate > 90% → weight * 1.1, capped at 1.0
    awk "BEGIN{exit !($weight >= 0.9)}" || return 1
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

    optimize_tune_templates "$OUTCOMES_FILE" > /dev/null 2>&1

    local weight
    weight=$(jq -r '.["fast|feature"] // 1' "$TEMPLATE_WEIGHTS_FILE")
    # 20% < 60% → weight * 0.7 = 0.7
    awk "BEGIN{exit !($weight < 0.8)}" || return 1
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

    # Verify low mean is ~7 (5+7+9)/3
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

    # Build stage: sonnet has 100% success with 5 samples → should recommend sonnet
    local build_rec
    build_rec=$(jq -r '.build.recommended // "none"' "$MODEL_ROUTING_FILE")
    [[ "$build_rec" == "sonnet" ]] || return 1

    # Verify sample counts
    local sonnet_n
    sonnet_n=$(jq '.build.sonnet_samples' "$MODEL_ROUTING_FILE")
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
    build_rec=$(jq -r '.build.recommended // "none"' "$MODEL_ROUTING_FILE")
    [[ "$build_rec" == "opus" ]] || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Memory pruning removes old patterns (>30 days), keeps recent ones
# ──────────────────────────────────────────────────────────────────────────────
test_memory_pruning() {
    local mem_dir="$TEMP_DIR/.shipwright/memory/repo1"
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
    echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$TEMP_DIR/.shipwright/memory/global.json"

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
    local mem_dir="$TEMP_DIR/.shipwright/memory/repo1"
    mkdir -p "$mem_dir"

    local recent_date
    recent_date=$(now_iso)

    # Pattern seen 5 times recently — should be strengthened
    jq -n \
        --arg recent "$recent_date" \
        '{failures: [
            {pattern: "flaky test", stage: "test", seen_count: 5, last_seen: $recent, weight: 1.0}
        ]}' > "$mem_dir/failures.json"

    echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$TEMP_DIR/.shipwright/memory/global.json"

    optimize_evolve_memory > /dev/null 2>&1

    local weight
    weight=$(jq '.failures[0].weight' "$mem_dir/failures.json")
    # Should be boosted: 1.0 * 1.5 = 1.5
    awk "BEGIN{exit !($weight > 1.0)}" || return 1
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
        mkdir -p "$TEMP_DIR/.shipwright/memory/$repo_dir"
        jq -n \
            --arg recent "$recent_date" \
            '{failures: [
                {pattern: "shared error pattern", stage: "build", seen_count: 2, last_seen: $recent}
            ]}' > "$TEMP_DIR/.shipwright/memory/$repo_dir/failures.json"
    done

    local global_file="$TEMP_DIR/.shipwright/memory/global.json"
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
    echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$TEMP_DIR/.shipwright/memory/global.json"
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
    echo "$output" | grep -q "Last 7 Days" || return 1
    echo "$output" | grep -q "Pipelines:" || return 1
    echo "$output" | grep -q "Success rate:" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Report handles empty outcomes gracefully
# ──────────────────────────────────────────────────────────────────────────────
test_report_empty() {
    local output
    output=$(optimize_report 2>&1)
    echo "$output" | grep -q "No outcomes data" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. Outcome analysis extracts stage data
# ──────────────────────────────────────────────────────────────────────────────
test_outcome_stages() {
    local state_file="$TEMP_DIR/mock-state-stages.md"
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
        "test_memory_promotion:Memory promotion copies cross-repo patterns"
        "test_full_analysis_empty:Full analysis runs on empty data"
        "test_report_with_data:Report generates output with data"
        "test_report_empty:Report handles empty outcomes"
        "test_outcome_stages:Outcome analysis extracts stage data"
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
