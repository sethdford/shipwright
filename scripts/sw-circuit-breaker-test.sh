#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-circuit-breaker-test.sh — Test Suite for Adaptive Circuit Breaker   ║
# ║                                                                         ║
# ║  Tests for signature extraction, similarity scoring, and threshold      ║
# ║  computation based on failure signature similarity.                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"

# Function to run a test and handle cleanup
run_tests() {
    # Source the circuit breaker module (with pipefail enabled)
    source "$SCRIPT_DIR/sw-circuit-breaker.sh" || return 1

    # Test result tracking
    local PASS=0
    local FAIL=0

    # ─── Test: Extract Error Signatures ──────────────────────────────────────────

    echo "Testing: extract_error_signatures()"

    # Test 1: Empty file returns empty array
    result=$(extract_error_signatures "$TEST_DIR/nonexistent.jsonl" 2>/dev/null || echo "null")
    if [[ "$result" == "[]" ]]; then
        echo "  ✓ empty file returns empty array"
        PASS=$((PASS + 1))
    else
        echo "  ✗ empty file returns empty array (got: $result)"
        FAIL=$((FAIL + 1))
    fi

    # Test 2: Single error extracted correctly
    cat > "$TEST_DIR/errors.jsonl" <<'EOF'
{"error":"TypeError: Cannot read property 'foo' of undefined","type":"test","stage":"build"}
EOF
    result=$(extract_error_signatures "$TEST_DIR/errors.jsonl" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    if [[ "$result" -eq "1" ]]; then
        echo "  ✓ single error extracted correctly"
        PASS=$((PASS + 1))
    else
        echo "  ✗ single error extracted correctly (got: $result)"
        FAIL=$((FAIL + 1))
    fi

    # Test 3: Multiple errors extracted
    cat > "$TEST_DIR/multi_errors.jsonl" <<'EOF'
{"error":"Error 1","type":"test","stage":"build","timestamp":"2026-09-25T10:00:00Z"}
{"error":"Error 2","type":"test","stage":"build","timestamp":"2026-09-25T10:01:00Z"}
{"error":"Error 3","type":"test","stage":"build","timestamp":"2026-09-25T10:02:00Z"}
EOF
    result=$(extract_error_signatures "$TEST_DIR/multi_errors.jsonl" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    if [[ "$result" -eq "3" ]]; then
        echo "  ✓ multiple errors extracted"
        PASS=$((PASS + 1))
    else
        echo "  ✗ multiple errors extracted (expected 3, got $result)"
        FAIL=$((FAIL + 1))
    fi

    # ─── Test: Similarity Scoring ────────────────────────────────────────────────

    echo ""
    echo "Testing: score_signature_similarity()"

    # Test 1: Identical signatures score high
    sig1='{"error":"TypeError: foo","type":"test","stage":"build","timestamp":"2026-09-25T10:00:00Z"}'
    sig2='{"error":"TypeError: foo","type":"test","stage":"build","timestamp":"2026-09-25T10:00:10Z"}'
    score=$(score_signature_similarity "$sig1" "$sig2" 2>/dev/null || echo "0")
    if [[ "$score" -ge 90 ]]; then
        echo "  ✓ identical signatures score high (${score}%)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ identical signatures score high (expected >= 90, got $score)"
        FAIL=$((FAIL + 1))
    fi

    # Test 2: Different signatures score low
    sig1='{"error":"TypeError: foo","type":"test","stage":"build","timestamp":"2026-09-25T10:00:00Z"}'
    sig2='{"error":"ENOENT: file not found","type":"fs","stage":"deploy","timestamp":"2026-09-25T10:05:00Z"}'
    score=$(score_signature_similarity "$sig1" "$sig2" 2>/dev/null || echo "0")
    if [[ "$score" -le 20 ]]; then
        echo "  ✓ different signatures score low (${score}%)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ different signatures score low (expected <= 20, got $score)"
        FAIL=$((FAIL + 1))
    fi

    # Test 3: Same type/stage scores medium
    sig1='{"error":"Error 1","type":"test","stage":"build","timestamp":"2026-09-25T10:00:00Z"}'
    sig2='{"error":"Error 2","type":"test","stage":"build","timestamp":"2026-09-25T10:00:00Z"}'
    score=$(score_signature_similarity "$sig1" "$sig2" 2>/dev/null || echo "0")
    if [[ "$score" -ge 40 && "$score" -le 60 ]]; then
        echo "  ✓ same type/stage scores medium (${score}%)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ same type/stage scores medium (expected 40-60, got $score)"
        FAIL=$((FAIL + 1))
    fi

    # Test 4: Empty signatures return 0
    score=$(score_signature_similarity "" "" 2>/dev/null || echo "0")
    if [[ "$score" == "0" ]]; then
        echo "  ✓ empty signatures return 0"
        PASS=$((PASS + 1))
    else
        echo "  ✗ empty signatures return 0 (got $score)"
        FAIL=$((FAIL + 1))
    fi

    # ─── Test: Adaptive Threshold Computation ───────────────────────────────────

    echo ""
    echo "Testing: compute_adaptive_threshold()"

    # Test 1: No error log returns base threshold
    ADAPTIVE_ENABLED=1
    result=$(compute_adaptive_threshold "$TEST_DIR/nonexistent.jsonl" "3" 2>/dev/null || echo "")
    if [[ "$result" == "3" ]]; then
        echo "  ✓ no error log returns base threshold"
        PASS=$((PASS + 1))
    else
        echo "  ✗ no error log returns base threshold (got $result)"
        FAIL=$((FAIL + 1))
    fi

    # Test 2: Single error returns base threshold
    cat > "$TEST_DIR/single.jsonl" <<'EOF'
{"error":"Error 1","type":"test","stage":"build"}
EOF
    result=$(compute_adaptive_threshold "$TEST_DIR/single.jsonl" "3" 2>/dev/null || echo "")
    if [[ "$result" == "3" ]]; then
        echo "  ✓ single error returns base threshold"
        PASS=$((PASS + 1))
    else
        echo "  ✗ single error returns base threshold (got $result)"
        FAIL=$((FAIL + 1))
    fi

    # Test 3: Similar consecutive errors increase threshold
    cat > "$TEST_DIR/similar.jsonl" <<'EOF'
{"error":"TypeError: Cannot read property 'foo'","type":"test","stage":"build","timestamp":"2026-09-25T10:00:00Z"}
{"error":"TypeError: Cannot read property 'foo'","type":"test","stage":"build","timestamp":"2026-09-25T10:00:30Z"}
EOF
    ADAPTIVE_ENABLED=1
    result=$(compute_adaptive_threshold "$TEST_DIR/similar.jsonl" "3" 2>/dev/null || echo "")
    if [[ "$result" -gt "3" ]]; then
        echo "  ✓ similar errors increase threshold (got ${result})"
        PASS=$((PASS + 1))
    else
        echo "  ✗ similar errors increase threshold (expected > 3, got $result)"
        FAIL=$((FAIL + 1))
    fi

    # Test 4: Diverse consecutive errors decrease threshold
    cat > "$TEST_DIR/diverse.jsonl" <<'EOF'
{"error":"TypeError: Cannot read property 'foo'","type":"test","stage":"build","timestamp":"2026-09-25T10:00:00Z"}
{"error":"ENOENT: no such file or directory","type":"fs","stage":"test","timestamp":"2026-09-25T10:01:00Z"}
EOF
    ADAPTIVE_ENABLED=1
    result=$(compute_adaptive_threshold "$TEST_DIR/diverse.jsonl" "3" 2>/dev/null || echo "")
    if [[ "$result" -lt "3" ]]; then
        echo "  ✓ diverse errors decrease threshold (got ${result})"
        PASS=$((PASS + 1))
    else
        echo "  ✗ diverse errors decrease threshold (expected < 3, got $result)"
        FAIL=$((FAIL + 1))
    fi

    # Test 5: Disabled adaptive returns base
    ADAPTIVE_ENABLED=0
    result=$(compute_adaptive_threshold "$TEST_DIR/similar.jsonl" "3" 2>/dev/null || echo "")
    if [[ "$result" == "3" ]]; then
        echo "  ✓ disabled adaptive returns base threshold"
        PASS=$((PASS + 1))
    else
        echo "  ✗ disabled adaptive returns base threshold (got $result)"
        FAIL=$((FAIL + 1))
    fi

    # Test 6: Threshold respects min bound
    cat > "$TEST_DIR/very_diverse.jsonl" <<'EOF'
{"error":"Error 1","type":"a","stage":"x","timestamp":"2026-09-25T10:00:00Z"}
{"error":"Error 2","type":"b","stage":"y","timestamp":"2026-09-25T10:01:00Z"}
EOF
    ADAPTIVE_ENABLED=1
    THRESHOLD_MIN=2
    result=$(compute_adaptive_threshold "$TEST_DIR/very_diverse.jsonl" "2" 2>/dev/null || echo "")
    if [[ "$result" -ge "2" ]]; then
        echo "  ✓ respects minimum threshold (got ${result})"
        PASS=$((PASS + 1))
    else
        echo "  ✗ respects minimum threshold (expected >= 2, got $result)"
        FAIL=$((FAIL + 1))
    fi

    # Test 7: Threshold respects max bound
    THRESHOLD_MAX=8
    result=$(compute_adaptive_threshold "$TEST_DIR/similar.jsonl" "7" 2>/dev/null || echo "")
    if [[ "$result" -le "8" ]]; then
        echo "  ✓ respects maximum threshold (got ${result})"
        PASS=$((PASS + 1))
    else
        echo "  ✗ respects maximum threshold (expected <= 8, got $result)"
        FAIL=$((FAIL + 1))
    fi

    # ─── Test: Diagnostic Functions ─────────────────────────────────────────────

    echo ""
    echo "Testing: diagnose_failure_signatures()"

    # Test 1: Works with valid error log
    output=$(diagnose_failure_signatures "$TEST_DIR/similar.jsonl" 2>/dev/null || true)
    if echo "$output" | grep -q "Failure Signature Analysis"; then
        echo "  ✓ diagnose works with valid log"
        PASS=$((PASS + 1))
    else
        echo "  ✗ diagnose works with valid log"
        FAIL=$((FAIL + 1))
    fi

    # Test 2: Handles missing file gracefully
    output=$(diagnose_failure_signatures "$TEST_DIR/nonexistent.jsonl" 2>/dev/null || true)
    if echo "$output" | grep -q "No error log"; then
        echo "  ✓ diagnose handles missing file"
        PASS=$((PASS + 1))
    else
        echo "  ✗ diagnose handles missing file"
        FAIL=$((FAIL + 1))
    fi

    # ─── Summary ──────────────────────────────────────────────────────────────────

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  Test Results                                                  ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    printf "║  PASS: %-58s║\n" "$PASS"
    printf "║  FAIL: %-58s║\n" "$FAIL"
    echo "╚════════════════════════════════════════════════════════════════╝"

    if [[ $FAIL -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Run tests and cleanup
run_tests
EXIT_CODE=$?
rm -rf "$TEST_DIR"
exit $EXIT_CODE
