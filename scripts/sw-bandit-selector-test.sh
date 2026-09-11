#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-bandit-selector-test.sh — Bandit Selector Test Suite                 ║
# ║  12+ tests: init, selection, update, convergence, explore rate, report  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Setup / Teardown ─────────────────────────────────────────────────────────
TEST_TMPDIR=""
setup() {
    TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/bandit-test.XXXXXX")
    export BANDIT_STATE_FILE="$TEST_TMPDIR/bandits.json"
    # Narrow the arms to keep tests fast
    export BANDIT_MODELS="haiku,sonnet,opus"
    export BANDIT_STAGES="build,review"
    export BANDIT_TEMPLATES="fast,standard"
    export BANDIT_ISSUE_TYPES="bug,feature"
}

teardown() {
    [[ -n "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
}

trap teardown EXIT

# ─── Source the library ───────────────────────────────────────────────────────
# shellcheck source=lib/bandit-selector.sh
source "$SCRIPT_DIR/lib/bandit-selector.sh"

# ─── Test Helpers ─────────────────────────────────────────────────────────────
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

assert_not_empty() {
    local actual="$1" description="${2:-}"
    if [[ -n "$actual" ]]; then
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
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

# ─── Test 1: bandit_init creates state file ────────────────────────────────────
test_init_creates_file() {
    setup
    bandit_init >/dev/null 2>&1
    assert_file_exists "$BANDIT_STATE_FILE" "bandit_init creates state file"
}

# ─── Test 2: bandit_init creates correct model arms ────────────────────────────
test_init_model_arms() {
    setup
    bandit_init >/dev/null 2>&1
    local state
    state=$(cat "$BANDIT_STATE_FILE")
    # 2 stages × 3 models = 6 model arms
    local count
    count=$(echo "$state" | jq '.model_arms | length')
    assert_equals "6" "$count" "bandit_init creates 6 model arms (2 stages × 3 models)"
}

# ─── Test 3: bandit_init creates correct template arms ─────────────────────────
test_init_template_arms() {
    setup
    bandit_init >/dev/null 2>&1
    local state
    state=$(cat "$BANDIT_STATE_FILE")
    # 2 issue types × 2 templates = 4 template arms
    local count
    count=$(echo "$state" | jq '.template_arms | length')
    assert_equals "4" "$count" "bandit_init creates 4 template arms (2 types × 2 templates)"
}

# ─── Test 4: arms start with Beta(1,1) ─────────────────────────────────────────
test_init_beta_priors() {
    setup
    bandit_init >/dev/null 2>&1
    local state
    state=$(cat "$BANDIT_STATE_FILE")
    local arm
    arm=$(echo "$state" | jq '.model_arms["build:haiku"]')
    assert_json_field "$arm" '.alpha' '1' "model arm starts with alpha=1"
    assert_json_field "$arm" '.beta' '1' "model arm starts with beta=1"
    assert_json_field "$arm" '.pulls' '0' "model arm starts with pulls=0"
    assert_json_field "$arm" '.successes' '0' "model arm starts with successes=0"
}

# ─── Test 5: bandit_init is idempotent ──────────────────────────────────────────
test_init_idempotent() {
    setup
    bandit_init >/dev/null 2>&1
    # Update an arm
    bandit_update "model" "build:opus" "success"
    # Re-init should NOT overwrite
    bandit_init >/dev/null 2>&1
    local arm
    arm=$(bandit_get_arm "model" "build:opus")
    local alpha
    alpha=$(echo "$arm" | jq -r '.alpha')
    assert_equals "2" "$alpha" "bandit_init does not overwrite existing arms"
}

# ─── Test 6: bandit_select_model returns valid model ────────────────────────────
test_select_model_valid() {
    setup
    bandit_init >/dev/null 2>&1
    local model
    model=$(bandit_select_model "build" "haiku,sonnet,opus")
    local valid=0
    case "$model" in
        haiku|sonnet|opus) valid=1 ;;
    esac
    assert_equals "1" "$valid" "bandit_select_model returns a valid model name ($model)"
}

# ─── Test 7: bandit_select_template returns valid template ──────────────────────
test_select_template_valid() {
    setup
    bandit_init >/dev/null 2>&1
    local tmpl
    tmpl=$(bandit_select_template "bug" "fast,standard")
    local valid=0
    case "$tmpl" in
        fast|standard) valid=1 ;;
    esac
    assert_equals "1" "$valid" "bandit_select_template returns a valid template ($tmpl)"
}

# ─── Test 8: bandit_update success increments alpha ─────────────────────────────
test_update_success() {
    setup
    bandit_init >/dev/null 2>&1
    bandit_update "model" "build:sonnet" "success"
    local arm
    arm=$(bandit_get_arm "model" "build:sonnet")
    assert_json_field "$arm" '.alpha' '2' "success increments alpha"
    assert_json_field "$arm" '.beta' '1' "success does not change beta"
    assert_json_field "$arm" '.pulls' '1' "success increments pulls"
    assert_json_field "$arm" '.successes' '1' "success increments successes"
}

# ─── Test 9: bandit_update failure increments beta ──────────────────────────────
test_update_failure() {
    setup
    bandit_init >/dev/null 2>&1
    bandit_update "model" "build:haiku" "failure"
    local arm
    arm=$(bandit_get_arm "model" "build:haiku")
    assert_json_field "$arm" '.alpha' '1' "failure does not change alpha"
    assert_json_field "$arm" '.beta' '2' "failure increments beta"
    assert_json_field "$arm" '.pulls' '1' "failure increments pulls"
}

# ─── Test 10: bandit_update creates arm on the fly ──────────────────────────────
test_update_creates_arm() {
    setup
    bandit_init >/dev/null 2>&1
    bandit_update "model" "deploy:haiku" "success"
    local arm
    arm=$(bandit_get_arm "model" "deploy:haiku")
    assert_json_field "$arm" '.alpha' '2' "auto-created arm gets alpha=2 after success"
    assert_json_field "$arm" '.pulls' '1' "auto-created arm gets pulls=1"
}

# ─── Test 11: bandit_explore_rate ────────────────────────────────────────────────
test_explore_rate() {
    setup
    bandit_init >/dev/null 2>&1
    # All arms have 0 pulls, so explore rate should be 1 (100%)
    local rate
    rate=$(bandit_explore_rate "model" "10")
    local is_one
    is_one=$(awk -v r="$rate" 'BEGIN { print (r >= 0.99) ? "1" : "0" }')
    assert_equals "1" "$is_one" "explore rate is ~1.0 when no arms have been pulled"

    # Pull all model arms above threshold
    local i
    for i in $(seq 1 11); do
        bandit_update "model" "build:haiku" "success"
        bandit_update "model" "build:sonnet" "success"
        bandit_update "model" "build:opus" "success"
        bandit_update "model" "review:haiku" "success"
        bandit_update "model" "review:sonnet" "success"
        bandit_update "model" "review:opus" "success"
    done
    rate=$(bandit_explore_rate "model" "10")
    local is_zero
    is_zero=$(awk -v r="$rate" 'BEGIN { print (r < 0.01) ? "1" : "0" }')
    assert_equals "1" "$is_zero" "explore rate is ~0.0 when all arms have >10 pulls"
}

# ─── Test 12: bandit_report produces output ──────────────────────────────────────
test_report_output() {
    setup
    bandit_init >/dev/null 2>&1
    bandit_update "model" "build:opus" "success"
    bandit_update "model" "build:opus" "success"
    bandit_update "model" "build:opus" "failure"
    local output
    output=$(bandit_report "model" 2>&1)
    if echo "$output" | grep "build:opus" >/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m bandit_report shows arm data"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m bandit_report shows arm data"
    fi
    if echo "$output" | grep "Exploration rate" >/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m bandit_report shows exploration rate"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m bandit_report shows exploration rate"
    fi
}

# ─── Test 13: bandit_reset_arm resets to Beta(1,1) ──────────────────────────────
test_reset_arm() {
    setup
    bandit_init >/dev/null 2>&1
    bandit_update "model" "build:opus" "success"
    bandit_update "model" "build:opus" "success"
    bandit_reset_arm "model" "build:opus"
    local arm
    arm=$(bandit_get_arm "model" "build:opus")
    assert_json_field "$arm" '.alpha' '1' "reset arm has alpha=1"
    assert_json_field "$arm" '.beta' '1' "reset arm has beta=1"
    assert_json_field "$arm" '.pulls' '0' "reset arm has pulls=0"
}

# ─── Test 14: auto-init when state file missing ─────────────────────────────────
test_auto_init() {
    setup
    # Don't call bandit_init — select should auto-init
    local model
    model=$(bandit_select_model "build" "haiku,sonnet,opus" 2>/dev/null)
    assert_not_empty "$model" "auto-init works when state file missing ($model)"
    assert_file_exists "$BANDIT_STATE_FILE" "state file created by auto-init"
}

# ─── Test 15: _beta_sample returns value in [0,1] ──────────────────────────────
test_beta_sample_range() {
    local all_valid=1
    local i sample
    for i in $(seq 1 20); do
        sample=$(_beta_sample 3 5)
        local in_range
        in_range=$(awk -v s="$sample" 'BEGIN { print (s >= 0 && s <= 1) ? "1" : "0" }')
        if [[ "$in_range" != "1" ]]; then
            all_valid=0
            break
        fi
    done
    assert_equals "1" "$all_valid" "_beta_sample always returns value in [0,1]"
}

# ─── Test 16: Convergence — best arm selected most often ────────────────────────
# Create 3 arms with known success rates. After enough history,
# Thompson sampling should select the best arm most frequently.
test_convergence() {
    setup
    bandit_init >/dev/null 2>&1

    # Arm A (haiku): 80% success — simulate 20 trials
    local i
    for i in $(seq 1 16); do bandit_update "model" "build:haiku" "success"; done
    for i in $(seq 1 4); do bandit_update "model" "build:haiku" "failure"; done

    # Arm B (sonnet): 50% success — simulate 20 trials
    for i in $(seq 1 10); do bandit_update "model" "build:sonnet" "success"; done
    for i in $(seq 1 10); do bandit_update "model" "build:sonnet" "failure"; done

    # Arm C (opus): 30% success — simulate 20 trials
    for i in $(seq 1 6); do bandit_update "model" "build:opus" "success"; done
    for i in $(seq 1 14); do bandit_update "model" "build:opus" "failure"; done

    # Now sample 50 times and count selections
    local haiku_count=0 sonnet_count=0 opus_count=0
    for i in $(seq 1 50); do
        local selected
        selected=$(bandit_select_model "build" "haiku,sonnet,opus")
        case "$selected" in
            haiku) haiku_count=$((haiku_count + 1)) ;;
            sonnet) sonnet_count=$((sonnet_count + 1)) ;;
            opus) opus_count=$((opus_count + 1)) ;;
        esac
    done

    # Best arm (haiku, 80%) should be selected more than either other arm
    local haiku_is_best=0
    if [[ "$haiku_count" -gt "$sonnet_count" ]] && [[ "$haiku_count" -gt "$opus_count" ]]; then
        haiku_is_best=1
    fi

    assert_equals "1" "$haiku_is_best" \
        "convergence: best arm (haiku 80%) selected most (h=$haiku_count s=$sonnet_count o=$opus_count)"
}

# ─── Test 17: atomic writes — state file not corrupted ──────────────────────────
test_atomic_writes() {
    setup
    bandit_init >/dev/null 2>&1
    # Rapid updates
    local i
    for i in $(seq 1 10); do
        bandit_update "model" "build:haiku" "success"
    done
    # Verify JSON is valid
    local valid
    valid=$(jq '.' "$BANDIT_STATE_FILE" >/dev/null 2>&1 && echo "1" || echo "0")
    assert_equals "1" "$valid" "state file is valid JSON after rapid updates"
}

# ─── Test 18: bandit_report with filter ──────────────────────────────────────────
test_report_filter() {
    setup
    bandit_init >/dev/null 2>&1
    bandit_update "model" "build:opus" "success"
    local output
    output=$(bandit_report "model" "build:" 2>&1)
    if echo "$output" | grep "build:opus" >/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m bandit_report filter includes matching arms"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m bandit_report filter includes matching arms"
    fi
    # review arms should be filtered out in the data lines
    local review_in_data
    review_in_data=$(echo "$output" | grep -c "review:" 2>/dev/null || true)
    if [[ "${review_in_data:-0}" -eq 0 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m bandit_report filter excludes non-matching arms"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m bandit_report filter excludes non-matching arms"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
echo "sw-bandit-selector-test.sh"
echo ""

test_init_creates_file
test_init_model_arms
test_init_template_arms
test_init_beta_priors
test_init_idempotent
test_select_model_valid
test_select_template_valid
test_update_success
test_update_failure
test_update_creates_arm
test_explore_rate
test_report_output
test_reset_arm
test_auto_init
test_beta_sample_range
test_convergence
test_atomic_writes
test_report_filter

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
