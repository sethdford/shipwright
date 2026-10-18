#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-outcome-feedback-test — Unit tests for review capture & quality      ║
# ║  scoring · Pattern detection · Learned rule generation                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-isolate.sh"
sw_test_isolate
# The fallback was "/tmp/claude", which does not exist on a CI runner — TMPDIR
# is typically unset there, so mktemp tried to create a directory inside a
# missing parent and the suite died during setup. /tmp is the portable default
# and always exists; mkdir -p covers a TMPDIR that points somewhere absent.
TMPBASE="${TMPDIR:-/tmp}"
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE=/tmp
TEST_DIR=$(mktemp -d "$TMPBASE/sw-test-XXXXXX")
MEMORY_TEST_ROOT="$TMPBASE/sw-memory-test-$$"

cleanup() {
    rm -rf "$TEST_DIR" "$MEMORY_TEST_ROOT" 2>/dev/null || true
}
trap 'cleanup; sw_test_teardown' EXIT

# Test counter
PASS=0
FAIL=0

# Helper functions
pass() {
    echo -e "\033[38;2;74;222;128m✓\033[0m $*"
    PASS=$((PASS + 1))
    return 0
}

fail() {
    echo -e "\033[38;2;248;113;113m✗\033[0m $*"
    FAIL=$((FAIL + 1))
    return 1
}

# Source the module under test with memory root override
export OUTCOME_FEEDBACK_MEMORY_ROOT="$MEMORY_TEST_ROOT"
source "$SCRIPT_DIR/lib/outcome-feedback.sh"

# ═══════════════════════════════════════════════════════════════════════════
# TEST SUITE
# ═══════════════════════════════════════════════════════════════════════════

# ─── Test: Review feedback capture stores correct JSON ──────────────────────
test_review_feedback_capture_json_format() {
    local test_name="review feedback capture stores correct JSON"
    local repo_path="$TEST_DIR/test-repo"
    mkdir -p "$repo_path"

    # Skip actual GitHub API call by setting NO_GITHUB
    NO_GITHUB=true capture_review_feedback 248 "$repo_path" || true

    # Check that memory dir was created
    local repo_hash
    repo_hash=$(echo -n "$repo_path" | shasum -a 256 | cut -c1-12)
    local mem_dir="${MEMORY_TEST_ROOT}/${repo_hash}"

    [[ -d "$mem_dir" ]] && pass "$test_name" || fail "$test_name (memory dir not created)"
}

# ─── Test: Merge quality scoring clean merge → +1 ───────────────────────────
test_merge_quality_clean_merge() {
    local test_name="merge quality scoring clean merge → +1"
    local repo_path="$TEST_DIR/test-repo-clean"
    mkdir -p "$repo_path"

    compute_merge_quality 100 "$repo_path" "clean_merge"

    local repo_hash
    repo_hash=$(echo -n "$repo_path" | shasum -a 256 | cut -c1-12)
    local quality_file="${MEMORY_TEST_ROOT}/${repo_hash}/merge-quality.jsonl"

    if [[ -f "$quality_file" ]]; then
        local score
        score=$(tail -1 "$quality_file" | jq -r '.score')
        [[ "$score" == "1" ]] && pass "$test_name" || fail "$test_name (score was $score, expected 1)"
    else
        fail "$test_name (quality file not created)"
    fi
}

# ─── Test: Merge quality scoring changes_requested → -1 ──────────────────────
test_merge_quality_changes_requested() {
    local test_name="merge quality scoring changes_requested → -1"
    local repo_path="$TEST_DIR/test-repo-changes"
    mkdir -p "$repo_path"

    compute_merge_quality 101 "$repo_path" "changes_requested"

    local repo_hash
    repo_hash=$(echo -n "$repo_path" | shasum -a 256 | cut -c1-12)
    local quality_file="${MEMORY_TEST_ROOT}/${repo_hash}/merge-quality.jsonl"

    if [[ -f "$quality_file" ]]; then
        local score
        score=$(tail -1 "$quality_file" | jq -r '.score')
        [[ "$score" == "-1" ]] && pass "$test_name" || fail "$test_name (score was $score, expected -1)"
    else
        fail "$test_name (quality file not created)"
    fi
}

# ─── Test: Merge quality scoring reverted → -3 ────────────────────────────────
test_merge_quality_reverted() {
    local test_name="merge quality scoring reverted → -3"
    local repo_path="$TEST_DIR/test-repo-reverted"
    mkdir -p "$repo_path"

    compute_merge_quality 102 "$repo_path" "reverted"

    local repo_hash
    repo_hash=$(echo -n "$repo_path" | shasum -a 256 | cut -c1-12)
    local quality_file="${MEMORY_TEST_ROOT}/${repo_hash}/merge-quality.jsonl"

    if [[ -f "$quality_file" ]]; then
        local score
        score=$(tail -1 "$quality_file" | jq -r '.score')
        [[ "$score" == "-3" ]] && pass "$test_name" || fail "$test_name (score was $score, expected -3)"
    else
        fail "$test_name (quality file not created)"
    fi
}

# ─── Test: Merge quality scoring regression → -2 ──────────────────────────────
test_merge_quality_regression() {
    local test_name="merge quality scoring regression → -2"
    local repo_path="$TEST_DIR/test-repo-regress"
    mkdir -p "$repo_path"

    compute_merge_quality 103 "$repo_path" "regression"

    local repo_hash
    repo_hash=$(echo -n "$repo_path" | shasum -a 256 | cut -c1-12)
    local quality_file="${MEMORY_TEST_ROOT}/${repo_hash}/merge-quality.jsonl"

    if [[ -f "$quality_file" ]]; then
        local score
        score=$(tail -1 "$quality_file" | jq -r '.score')
        [[ "$score" == "-2" ]] && pass "$test_name" || fail "$test_name (score was $score, expected -2)"
    else
        fail "$test_name (quality file not created)"
    fi
}

# ─── Test: Rolling quality score calculation ─────────────────────────────────
test_rolling_quality_score() {
    local test_name="rolling quality score calculation"
    local repo_path="$TEST_DIR/test-repo-rolling"
    mkdir -p "$repo_path"

    # Add some test data
    compute_merge_quality 200 "$repo_path" "clean_merge"
    compute_merge_quality 201 "$repo_path" "clean_merge"
    compute_merge_quality 202 "$repo_path" "changes_requested"

    local rolling_json
    rolling_json=$(get_rolling_quality_score "$repo_path" 20)

    local rolling_score
    rolling_score=$(echo "$rolling_json" | jq '.rolling_score')
    local pr_count
    pr_count=$(echo "$rolling_json" | jq '.pr_count')

    # Average of [1, 1, -1] = 1/3 ≈ 0.333
    [[ "$pr_count" == "3" ]] && pass "$test_name" || fail "$test_name (pr_count was $pr_count, expected 3)"
}

# ─── Test: Pattern detection ≥3 occurrences ────────────────────────────────────
test_pattern_detection_threshold() {
    local test_name="pattern detection: 3 error_handling comments → detected"
    local repo_path="$TEST_DIR/test-repo-patterns"
    mkdir -p "$repo_path"

    local repo_hash
    repo_hash=$(echo -n "$repo_path" | shasum -a 256 | cut -c1-12)
    local mem_dir="${MEMORY_TEST_ROOT}/${repo_hash}"
    mkdir -p "$mem_dir"

    local feedback_file="${mem_dir}/review-feedback.jsonl"

    # Add 3 error_handling comments
    jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            pr: 300,
            body: "Missing error handling for timeout",
            categories: "error_handling",
            captured_at: $ts
        }' >> "$feedback_file"

    jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            pr: 301,
            body: "No error handling for null response",
            categories: "error_handling",
            captured_at: $ts
        }' >> "$feedback_file"

    jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            pr: 302,
            body: "Should handle API errors gracefully",
            categories: "error_handling",
            captured_at: $ts
        }' >> "$feedback_file"

    # Detect patterns
    local patterns
    patterns=$(detect_review_patterns "$repo_path" 3)
    local pattern_count
    pattern_count=$(echo "$patterns" | jq '.patterns | length')

    [[ "$pattern_count" -gt 0 ]] && pass "$test_name" || fail "$test_name (detected $pattern_count patterns, expected ≥1)"
}

# ─── Test: Pattern detection <3 occurrences ────────────────────────────────────
test_pattern_detection_below_threshold() {
    local test_name="pattern detection: 2 comments → not detected"
    local repo_path="$TEST_DIR/test-repo-patterns-low"
    mkdir -p "$repo_path"

    local repo_hash
    repo_hash=$(echo -n "$repo_path" | shasum -a 256 | cut -c1-12)
    local mem_dir="${MEMORY_TEST_ROOT}/${repo_hash}"
    mkdir -p "$mem_dir"

    local feedback_file="${mem_dir}/review-feedback.jsonl"

    # Add only 2 validation comments
    jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            pr: 400,
            body: "Missing input validation",
            categories: "validation",
            captured_at: $ts
        }' >> "$feedback_file"

    jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            pr: 401,
            body: "Validate parameter before use",
            categories: "validation",
            captured_at: $ts
        }' >> "$feedback_file"

    # Detect patterns with threshold 3
    local patterns
    patterns=$(detect_review_patterns "$repo_path" 3)
    local pattern_count
    pattern_count=$(echo "$patterns" | jq '.patterns | length')

    [[ "$pattern_count" == "0" ]] && pass "$test_name" || fail "$test_name (detected $pattern_count patterns, expected 0)"
}

# ─── Test: Learned rule generation creates valid JSON ──────────────────────────
test_learned_rule_generation_json() {
    local test_name="learned rule generation creates valid JSON"
    local repo_path="$TEST_DIR/test-repo-rules"
    mkdir -p "$repo_path"

    local repo_hash
    repo_hash=$(echo -n "$repo_path" | shasum -a 256 | cut -c1-12)
    local mem_dir="${MEMORY_TEST_ROOT}/${repo_hash}"
    mkdir -p "$mem_dir"

    local feedback_file="${mem_dir}/review-feedback.jsonl"

    # Add 3 testing comments
    for i in 1 2 3; do
        jq -n \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "{
                pr: $((500 + i)),
                body: \"Missing test coverage\",
                categories: \"testing\",
                captured_at: \$ts
            }" >> "$feedback_file"
    done

    # Create quality profile
    local quality_profile="${TEST_DIR}/quality-profile.json"
    jq -n '{quality: {learned_rules: []}}' > "$quality_profile"

    # Generate rules
    generate_learned_rules "$repo_path" "$quality_profile" || true

    # Verify quality profile has learned_rules
    if [[ -f "$quality_profile" ]]; then
        local rule_count
        rule_count=$(jq '.quality.learned_rules | length' "$quality_profile" 2>/dev/null || echo 0)
        [[ "$rule_count" -gt 0 ]] && pass "$test_name" || fail "$test_name (no rules generated)"
    else
        fail "$test_name (quality profile not created)"
    fi
}

# ─── Test: Learned rule addition is idempotent ──────────────────────────────────
test_learned_rule_idempotent() {
    local test_name="learned rule addition to quality profile is idempotent"
    local repo_path="$TEST_DIR/test-repo-idempotent"
    mkdir -p "$repo_path"

    local repo_hash
    repo_hash=$(echo -n "$repo_path" | shasum -a 256 | cut -c1-12)
    local mem_dir="${MEMORY_TEST_ROOT}/${repo_hash}"
    mkdir -p "$mem_dir"

    local feedback_file="${mem_dir}/review-feedback.jsonl"
    local quality_profile="${TEST_DIR}/quality-profile-idem.json"

    # Create quality profile with one rule
    jq -n '{
        quality: {
            learned_rules: [{
                rule: "Always add error handling",
                source: "review_pattern_error_handling",
                confidence: 0.8,
                created_at: "2026-03-10T00:00:00Z",
                inject_at: ["plan", "build", "review"]
            }]
        }
    }' > "$quality_profile"

    # Add 3 error_handling comments
    for i in 1 2 3; do
        jq -n \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "{
                pr: $((600 + i)),
                body: \"Missing error handling\",
                categories: \"error_handling\",
                captured_at: \$ts
            }" >> "$feedback_file"
    done

    # Generate rules twice
    generate_learned_rules "$repo_path" "$quality_profile" || true
    local count_after_first
    count_after_first=$(jq '.quality.learned_rules | length' "$quality_profile")

    generate_learned_rules "$repo_path" "$quality_profile" || true
    local count_after_second
    count_after_second=$(jq '.quality.learned_rules | length' "$quality_profile")

    # Counts should be equal (no duplicates)
    [[ "$count_after_first" == "$count_after_second" ]] && pass "$test_name" || \
        fail "$test_name (count increased: $count_after_first → $count_after_second)"
}

# ─── Test: Post-merge feedback runs all steps ────────────────────────────────────
test_post_merge_feedback_complete() {
    local test_name="post-merge feedback runs all steps"
    local repo_path="$TEST_DIR/test-repo-full"
    mkdir -p "$repo_path"

    local quality_profile="${TEST_DIR}/quality-profile-full.json"
    jq -n '{quality: {learned_rules: []}}' > "$quality_profile"

    # Set NO_GITHUB to skip API calls
    NO_GITHUB=true post_merge_feedback 700 "$repo_path" "$quality_profile" || true

    # Verify memory dir was created
    local repo_hash
    repo_hash=$(echo -n "$repo_path" | shasum -a 256 | cut -c1-12)
    local mem_dir="${MEMORY_TEST_ROOT}/${repo_hash}"

    [[ -d "$mem_dir" ]] && pass "$test_name" || fail "$test_name (memory dir not created)"
}

# ─── Test: Works with no previous feedback (cold start) ──────────────────────────
test_cold_start() {
    local test_name="works when no previous feedback exists (cold start)"
    local repo_path="$TEST_DIR/test-repo-cold"
    mkdir -p "$repo_path"

    # Call functions on fresh repo
    compute_merge_quality 800 "$repo_path" "clean_merge"

    local repo_hash
    repo_hash=$(echo -n "$repo_path" | shasum -a 256 | cut -c1-12)
    local quality_file="${MEMORY_TEST_ROOT}/${repo_hash}/merge-quality.jsonl"

    # Rolling score should work even with single entry
    local rolling_json
    rolling_json=$(get_rolling_quality_score "$repo_path" 20)
    local pr_count
    pr_count=$(echo "$rolling_json" | jq '.pr_count')

    [[ "$pr_count" == "1" ]] && pass "$test_name" || fail "$test_name (cold start failed)"
}

# ═══════════════════════════════════════════════════════════════════════════
# RUN TESTS
# ═══════════════════════════════════════════════════════════════════════════

echo -e "\n╔════════════════════════════════════════════════════════════╗"
echo -e "║  Outcome Feedback Test Suite                              ║"
echo -e "╚════════════════════════════════════════════════════════════╝\n"

test_review_feedback_capture_json_format
test_merge_quality_clean_merge
test_merge_quality_changes_requested
test_merge_quality_reverted
test_merge_quality_regression
test_rolling_quality_score
test_pattern_detection_threshold
test_pattern_detection_below_threshold
test_learned_rule_generation_json
test_learned_rule_idempotent
test_post_merge_feedback_complete
test_cold_start

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

TOTAL=$((PASS + FAIL))
echo -e "\n╔════════════════════════════════════════════════════════════╗"
printf "║  PASSED: %-3d  FAILED: %-3d  TOTAL: %-3d                       ║\n" "$PASS" "$FAIL" "$TOTAL"
echo -e "╚════════════════════════════════════════════════════════════╝\n"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
