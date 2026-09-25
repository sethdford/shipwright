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

    # Isolate from the real ~/.shipwright memory so results are deterministic
    CIRCUIT_BREAKER_MEMORY_FILE="$TEST_DIR/no-memory.json"

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

    # ─── Test: Memory Signature Lookup ──────────────────────────────────────────

    echo ""
    echo "Testing: query_memory_signature_match()"

    cat > "$TEST_DIR/failures.json" <<'JSON'
{"failures":[
  {"stage":"test","pattern":"ModuleNotFoundError: No module named 'requests'","fix":"pip install requests","seen_count":4,"times_fix_applied":3,"times_fix_resolved":3,"fix_effectiveness_rate":100},
  {"stage":"build","pattern":"Segmentation fault in native extension","fix":"rebuild","seen_count":5,"times_fix_applied":4,"times_fix_resolved":0,"fix_effectiveness_rate":0},
  {"stage":"build","pattern":"Flaky socket timeout on port 8080","fix":"","seen_count":1,"times_fix_applied":1,"times_fix_resolved":0,"fix_effectiveness_rate":0},
  {"stage":"test","pattern":"error","seen_count":9,"times_fix_applied":5,"times_fix_resolved":0,"fix_effectiveness_rate":0}
]}
JSON

    assert_eq() {
        local desc="$1" expected="$2" actual="$3"
        if [[ "$actual" == "$expected" ]]; then
            echo "  ✓ $desc"
            PASS=$((PASS + 1))
        else
            echo "  ✗ $desc (expected: $expected, got: $actual)"
            FAIL=$((FAIL + 1))
        fi
    }

    assert_eq "no match returns none" "none" \
        "$(query_memory_signature_match "$TEST_DIR/failures.json" "TypeError: x is not a function")"
    assert_eq "resolved match (effective past fix) returns resolved" "resolved" \
        "$(query_memory_signature_match "$TEST_DIR/failures.json" "Traceback: ModuleNotFoundError: No module named 'requests'")"
    assert_eq "matching is case-insensitive" "resolved" \
        "$(query_memory_signature_match "$TEST_DIR/failures.json" "MODULENOTFOUNDERROR: NO MODULE NAMED 'REQUESTS'")"
    assert_eq "unrecoverable match (fixes kept failing) returns unrecoverable" "unrecoverable" \
        "$(query_memory_signature_match "$TEST_DIR/failures.json" "Segmentation fault in native extension (core dumped)")"
    assert_eq "low-confidence match (seen once) returns none" "none" \
        "$(query_memory_signature_match "$TEST_DIR/failures.json" "Flaky socket timeout on port 8080")"
    assert_eq "short patterns are ignored (no match on 'error')" "none" \
        "$(query_memory_signature_match "$TEST_DIR/failures.json" "some unrelated error happened")"
    assert_eq "missing memory file returns none" "none" \
        "$(query_memory_signature_match "$TEST_DIR/missing.json" "Segmentation fault in native extension")"
    echo "{not json" > "$TEST_DIR/malformed.json"
    assert_eq "malformed memory file returns none" "none" \
        "$(query_memory_signature_match "$TEST_DIR/malformed.json" "Segmentation fault in native extension")"
    assert_eq "empty error message returns none" "none" \
        "$(query_memory_signature_match "$TEST_DIR/failures.json" "")"

    cat > "$TEST_DIR/both.json" <<'JSON'
{"failures":[
  {"pattern":"Segmentation fault in native extension","seen_count":5,"times_fix_applied":4,"times_fix_resolved":0,"fix_effectiveness_rate":0},
  {"pattern":"Segmentation fault in native","seen_count":2,"times_fix_applied":2,"times_fix_resolved":2,"fix_effectiveness_rate":100}
]}
JSON
    assert_eq "resolved match wins over unrecoverable match" "resolved" \
        "$(query_memory_signature_match "$TEST_DIR/both.json" "Segmentation fault in native extension")"

    CIRCUIT_BREAKER_MEMORY_FILE="" MEMORY_ROOT="$TEST_DIR/memroot" \
        SHIPWRIGHT_LOOP_ADAPTIVE_CIRCUIT_BREAKER_MEMORY_ENABLED=false \
        bash -c 'source "$1"; [[ -z "$(resolve_memory_failures_file)" ]]' _ "$SCRIPT_DIR/sw-circuit-breaker.sh"
    assert_eq "memory lookup disabled via config returns no file" "0" "$?"

    result=$(CIRCUIT_BREAKER_MEMORY_FILE="" MEMORY_ROOT="$TEST_DIR/memroot" \
        bash -c 'source "$1"; resolve_memory_failures_file' _ "$SCRIPT_DIR/sw-circuit-breaker.sh")
    if [[ "$result" == "$TEST_DIR/memroot/"*"/failures.json" ]]; then
        echo "  ✓ memory file resolves under MEMORY_ROOT/<repo_hash>/"
        PASS=$((PASS + 1))
    else
        echo "  ✗ memory file resolves under MEMORY_ROOT/<repo_hash>/ (got: $result)"
        FAIL=$((FAIL + 1))
    fi

    # ─── Test: Memory-Informed Threshold ────────────────────────────────────────

    echo ""
    echo "Testing: compute_adaptive_threshold() with memory"

    ADAPTIVE_ENABLED=1
    CIRCUIT_BREAKER_MEMORY_FILE="$TEST_DIR/failures.json"

    cat > "$TEST_DIR/mem_single_resolved.jsonl" <<'JSONL'
{"error":"ModuleNotFoundError: No module named 'requests'","type":"test","stage":"test"}
JSONL
    assert_eq "resolved memory match raises threshold with a single failure" "5" \
        "$(compute_adaptive_threshold "$TEST_DIR/mem_single_resolved.jsonl" 3)"

    cat > "$TEST_DIR/mem_diverse_resolved.jsonl" <<'JSONL'
{"error":"ENOENT: file missing","type":"io","stage":"build","timestamp":"2026-09-25T10:00:00Z"}
{"error":"ModuleNotFoundError: No module named 'requests'","type":"test","stage":"test","timestamp":"2026-09-25T11:00:00Z"}
JSONL
    assert_eq "resolved memory match overrides diverse-signature decrease" "5" \
        "$(compute_adaptive_threshold "$TEST_DIR/mem_diverse_resolved.jsonl" 3)"

    cat > "$TEST_DIR/mem_similar_unrec.jsonl" <<'JSONL'
{"error":"Segmentation fault in native extension","type":"crash","stage":"build","timestamp":"2026-09-25T10:00:00Z"}
{"error":"Segmentation fault in native extension","type":"crash","stage":"build","timestamp":"2026-09-25T10:01:00Z"}
JSONL
    assert_eq "unrecoverable memory match lowers threshold despite similar signatures" "2" \
        "$(compute_adaptive_threshold "$TEST_DIR/mem_similar_unrec.jsonl" 3)"

    assert_eq "unrecoverable match still respects minimum bound" "2" \
        "$(compute_adaptive_threshold "$TEST_DIR/mem_similar_unrec.jsonl" 2)"

    assert_eq "resolved match still respects maximum bound" "8" \
        "$(compute_adaptive_threshold "$TEST_DIR/mem_single_resolved.jsonl" 7)"

    assert_eq "no memory match falls back to similarity result (similar → +2)" "5" \
        "$(compute_adaptive_threshold "$TEST_DIR/similar.jsonl" 3)"

    assert_eq "no memory match and single failure falls back to static base" "3" \
        "$(compute_adaptive_threshold "$TEST_DIR/single.jsonl" 3)"

    CIRCUIT_BREAKER_MEMORY_FILE="$TEST_DIR/missing.json"
    assert_eq "missing memory file falls back to static base" "3" \
        "$(compute_adaptive_threshold "$TEST_DIR/mem_single_resolved.jsonl" 3)"
    CIRCUIT_BREAKER_MEMORY_FILE="$TEST_DIR/failures.json"

    assert_eq "pinned threshold is never overridden" "3" \
        "$(SHIPWRIGHT_LOOP_CIRCUIT_BREAKER_THRESHOLD_PINNED=true compute_adaptive_threshold "$TEST_DIR/mem_similar_unrec.jsonl" 3)"

    ADAPTIVE_ENABLED=0
    assert_eq "disabled feature ignores memory entirely" "3" \
        "$(compute_adaptive_threshold "$TEST_DIR/mem_single_resolved.jsonl" 3)"
    ADAPTIVE_ENABLED=1
    CIRCUIT_BREAKER_MEMORY_FILE="$TEST_DIR/missing.json"

    # ─── Test: Config & Sourcing Safety ─────────────────────────────────────────

    echo ""
    echo "Testing: configuration and sourcing"

    result=$(SHIPWRIGHT_LOOP_ADAPTIVE_CIRCUIT_BREAKER_ENABLED=true \
        bash -c 'source "$1"; echo "$ADAPTIVE_ENABLED"' _ "$SCRIPT_DIR/sw-circuit-breaker.sh")
    assert_eq "enabled flag accepts boolean 'true'" "1" "$result"

    result=$(SHIPWRIGHT_LOOP_ADAPTIVE_CIRCUIT_BREAKER_ENABLED=0 \
        bash -c 'source "$1"; echo "$ADAPTIVE_ENABLED"' _ "$SCRIPT_DIR/sw-circuit-breaker.sh")
    assert_eq "enabled flag accepts '0' as disabled" "0" "$result"

    result=$(bash -c 'SCRIPT_DIR=/caller/dir; source "$1"; echo "$SCRIPT_DIR"' _ "$SCRIPT_DIR/sw-circuit-breaker.sh")
    assert_eq "sourcing does not clobber caller's SCRIPT_DIR" "/caller/dir" "$result"

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
