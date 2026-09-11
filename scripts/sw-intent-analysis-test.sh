#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   sw-intent-analysis-test.sh — Test suite for intent analysis module
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/lib/intent-analysis.sh"

VERSION="3.3.0"

# ─── Test Counters ──────────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Test utilities
test_pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    success "$1"
}

test_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    error "$1"
}

test_skip() {
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    warn "$1"
}

assert_file_exists() {
    local file="$1"
    local msg="${2:-File should exist: $file}"
    [[ -f "$file" ]] || { test_fail "$msg"; return 1; }
}

assert_json_valid() {
    local file="$1"
    local msg="${2:-JSON should be valid: $file}"
    jq empty "$file" 2>/dev/null || { test_fail "$msg"; return 1; }
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    local msg="${3:-File should contain pattern}"
    grep -q "$pattern" "$file" || { test_fail "$msg"; return 1; }
}

# ─── Setup ──────────────────────────────────────────────────────
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# ───────────────────────────────────────────────────────────────
# Test: analyze_intent generates valid JSON
# ───────────────────────────────────────────────────────────────
test_analyze_intent_generates_json() {
    local title="Fix auth module authentication flow"
    local body="Currently users cannot log in via OAuth. We need to implement OAuth provider integration."
    local labels="bug,auth"

    if analyze_intent "$title" "$body" "$labels" "$TEMP_DIR"; then
        if assert_file_exists "$TEMP_DIR/acceptance-criteria.json" "Should generate acceptance-criteria.json"; then
            if assert_json_valid "$TEMP_DIR/acceptance-criteria.json"; then
                test_pass "analyze_intent generates valid JSON"
                return 0
            fi
        fi
    fi
    test_fail "analyze_intent should generate valid JSON"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: acceptance criteria has required fields
# ───────────────────────────────────────────────────────────────
test_acceptance_criteria_schema() {
    local title="Add user profile API endpoint"
    local body="Users need a way to fetch their profile information"
    local labels="feature,api"

    analyze_intent "$title" "$body" "$labels" "$TEMP_DIR" || true

    if [[ ! -f "$TEMP_DIR/acceptance-criteria.json" ]]; then
        test_fail "acceptance-criteria.json not found"
        return 1
    fi

    # Check required top-level fields
    local version goal criteria
    version=$(jq -r '.version // empty' "$TEMP_DIR/acceptance-criteria.json" 2>/dev/null || true)
    goal=$(jq -r '.goal // empty' "$TEMP_DIR/acceptance-criteria.json" 2>/dev/null || true)
    criteria=$(jq -r '.criteria[]? // empty' "$TEMP_DIR/acceptance-criteria.json" 2>/dev/null | wc -l | tr -d ' ')

    [[ -n "$version" && -n "$goal" && "$criteria" -gt 0 ]] || {
        test_fail "Schema missing required fields (version, goal, criteria)"
        return 1
    }

    test_pass "Acceptance criteria has required schema fields"
    return 0
}

# ───────────────────────────────────────────────────────────────
# Test: criteria items have id, description, type, verifiable
# ───────────────────────────────────────────────────────────────
test_criteria_fields() {
    local title="Implement caching layer"
    local body="Add Redis caching to reduce database load"

    analyze_intent "$title" "$body" "" "$TEMP_DIR" || true

    if [[ ! -f "$TEMP_DIR/acceptance-criteria.json" ]]; then
        test_fail "acceptance-criteria.json not found"
        return 1
    fi

    # Check that all criteria have required fields
    local invalid_count
    invalid_count=$(jq '[.criteria[]? | select(.id == null or .description == null or .type == null or .verifiable == null)] | length' "$TEMP_DIR/acceptance-criteria.json" 2>/dev/null || echo "0")

    if [[ "$invalid_count" -eq 0 ]]; then
        test_pass "All criteria items have required fields"
        return 0
    fi

    test_fail "Criteria items missing required fields (count: $invalid_count)"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: failure mode validation accepts adequate plans
# ───────────────────────────────────────────────────────────────
test_failure_modes_validation_pass() {
    local plan_file="$TEMP_DIR/valid-plan.md"

    cat > "$plan_file" <<'EOF'
# Implementation Plan

## Files to Modify
- src/auth.js
- tests/auth.test.js

## Implementation Steps
1. Add authentication middleware
2. Implement JWT validation
3. Add refresh token logic

## Failure Mode Analysis

### Runtime Failures
1. Database connection unavailable: Application will retry with exponential backoff on connection pool timeout
2. Redis cache miss: System falls back to database query
3. External service timeout: Return error to client after 30s timeout

### Concurrency Risks
1. Race condition on token refresh: Use distributed lock on Redis with TTL
2. Duplicate token generation: Ensure idempotent token generation with nonce validation
3. Stale session state: Invalidate local cache on logout

### Scale Risks
1. High concurrency: Token generation becomes bottleneck; implement async queue for validations
2. Memory pressure: Limit in-memory cache size with LRU eviction
3. Database overload: Cache tokens for 5 minutes

### Rollback Story
- Revert commit: Auth routes will error until deployment rolls back
- Feature flag: Wrap new OAuth flow in feature flag to disable safely
- Data migration: No schema changes, backward-compatible

## Task Checklist
- [ ] Implement OAuth client initialization
- [ ] Add token validation middleware
- [ ] Write integration tests
EOF

    if validate_failure_modes "$plan_file"; then
        test_pass "Failure mode validation accepts adequate plans"
        return 0
    fi

    test_fail "Should accept plan with 3+ concrete failure modes"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: failure mode validation rejects missing section
# ───────────────────────────────────────────────────────────────
test_failure_modes_validation_missing_section() {
    local plan_file="$TEMP_DIR/missing-fma-plan.md"

    cat > "$plan_file" <<'EOF'
# Implementation Plan

## Files to Modify
- src/api.js

## Implementation Steps
1. Create endpoint
2. Add error handling
3. Write tests

## Task Checklist
- [ ] Implement API route
- [ ] Add tests
EOF

    if ! validate_failure_modes "$plan_file"; then
        test_pass "Failure mode validation rejects plans without failure mode section"
        return 0
    fi

    test_fail "Should reject plan without failure mode analysis section"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: failure mode validation rejects too few items
# ───────────────────────────────────────────────────────────────
test_failure_modes_validation_too_few() {
    local plan_file="$TEMP_DIR/shallow-fma-plan.md"

    cat > "$plan_file" <<'EOF'
# Implementation Plan

## Implementation Steps
1. Do the thing

## Failure Mode Analysis
This plan should handle errors gracefully.

## Task Checklist
- [ ] Implement feature
EOF

    if ! validate_failure_modes "$plan_file"; then
        test_pass "Failure mode validation rejects plans with <3 failure modes"
        return 0
    fi

    test_fail "Should reject plan with fewer than 3 failure modes"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: failure mode validation rejects generic analysis
# ───────────────────────────────────────────────────────────────
test_failure_modes_validation_generic() {
    local plan_file="$TEMP_DIR/generic-fma-plan.md"

    cat > "$plan_file" <<'EOF'
# Implementation Plan

## Failure Mode Analysis

1. Something might fail
2. Other things could break
3. More things might go wrong

This needs to be handled gracefully.
EOF

    if ! validate_failure_modes "$plan_file"; then
        test_pass "Failure mode validation rejects generic/non-specific analysis"
        return 0
    fi

    test_fail "Should reject plan with generic failure modes (no project specificity)"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: format_acceptance_criteria_for_prompt produces readable text
# ───────────────────────────────────────────────────────────────
test_format_criteria_for_prompt() {
    local title="Add logging to auth module"
    local body="Need to track auth failures for debugging"

    analyze_intent "$title" "$body" "" "$TEMP_DIR" || true

    if [[ ! -f "$TEMP_DIR/acceptance-criteria.json" ]]; then
        test_fail "acceptance-criteria.json not found"
        return 1
    fi

    local formatted
    formatted=$(format_acceptance_criteria_for_prompt "$TEMP_DIR" 2>/dev/null || true)

    if [[ -n "$formatted" ]] && echo "$formatted" | grep "Definition of Success" >/dev/null; then
        if echo "$formatted" | grep "Acceptance Criteria" >/dev/null; then
            test_pass "format_acceptance_criteria_for_prompt produces readable output"
            return 0
        fi
    fi

    test_fail "Format function should produce readable markdown"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: load_acceptance_criteria returns valid JSON
# ───────────────────────────────────────────────────────────────
test_load_acceptance_criteria() {
    local title="Test issue"
    local body="Test body"

    analyze_intent "$title" "$body" "" "$TEMP_DIR" || true

    local loaded
    loaded=$(load_acceptance_criteria "$TEMP_DIR" 2>/dev/null || true)

    if [[ -n "$loaded" && "$loaded" != "{}" ]]; then
        if jq empty <<< "$loaded" 2>/dev/null; then
            test_pass "load_acceptance_criteria returns valid JSON"
            return 0
        fi
    fi

    test_fail "load_acceptance_criteria should return valid JSON"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: analyze_intent works without Claude (fallback)
# ───────────────────────────────────────────────────────────────
test_analyze_intent_fallback() {
    local test_dir="$TEMP_DIR/fallback-test"
    mkdir -p "$test_dir"

    # Temporarily make Claude unavailable
    local old_path="$PATH"
    export PATH="/usr/bin:/bin"  # Reduced PATH without Claude

    local title="Fallback test"
    local body="Should still generate criteria without Claude"

    if analyze_intent "$title" "$body" "" "$test_dir" 2>/dev/null; then
        if [[ -f "$test_dir/acceptance-criteria.json" ]]; then
            if jq empty "$test_dir/acceptance-criteria.json" 2>/dev/null; then
                test_pass "analyze_intent falls back to defaults when Claude unavailable"
                export PATH="$old_path"
                return 0
            fi
        fi
    fi

    export PATH="$old_path"
    test_fail "Should generate default criteria without Claude"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: inject_failure_mode_analysis adds requirement to prompt
# ───────────────────────────────────────────────────────────────
test_inject_failure_mode_analysis() {
    local prompt="Initial plan prompt"

    local injected
    injected=$(inject_failure_mode_analysis "$prompt" "" 2>/dev/null || echo "$prompt")

    if [[ "$injected" != "$prompt" ]]; then
        if echo "$injected" | grep "Mandatory Failure Mode Analysis" >/dev/null; then
            if echo "$injected" | grep "at least 3 concrete failure modes" >/dev/null; then
                test_pass "inject_failure_mode_analysis adds requirement to prompt"
                return 0
            fi
        fi
    fi

    test_fail "inject_failure_mode_analysis should add failure mode requirement"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: get_failure_mode_validation_status returns correct status
# ───────────────────────────────────────────────────────────────
test_failure_mode_validation_status() {
    local valid_plan="$TEMP_DIR/status-valid.md"
    local missing_plan="$TEMP_DIR/status-missing.md"

    # Valid plan
    cat > "$valid_plan" <<'EOF'
## Failure Mode Analysis
1. Connection timeout: Retry with exponential backoff
2. Race condition: Use distributed locks
3. Database overload: Implement caching layer
EOF

    # Missing plan
    echo "No failure analysis here" > "$missing_plan"

    local valid_status
    valid_status=$(get_failure_mode_validation_status "$valid_plan" 2>/dev/null || true)

    local missing_status
    missing_status=$(get_failure_mode_validation_status "$missing_plan" 2>/dev/null || true)

    if [[ "$valid_status" == "valid" && "$missing_status" == "missing_section" ]]; then
        test_pass "get_failure_mode_validation_status returns correct status"
        return 0
    fi

    test_fail "Status function should return 'valid' or 'missing_section'"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: the `--output-format json` envelope is unwrapped
# ───────────────────────────────────────────────────────────────
# Installs a mock `claude` that answers the way the real CLI does: the model's
# text sits in .result, fenced. Without unwrapping, the envelope itself landed
# in acceptance-criteria.json and every consumer saw no version/goal/criteria.
_mock_claude() {
    local mock_dir="$1"
    local payload="$2"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/claude" <<MOCKEOF
#!/usr/bin/env bash
cat <<'PAYLOAD'
${payload}
PAYLOAD
exit 0
MOCKEOF
    chmod +x "$mock_dir/claude"
}

_criteria_fixture() {
    cat <<'EOF'
{"version":1,"goal":"Unwrap the envelope","generated_at":"2026-01-01T00:00:00Z","criteria":[{"id":"ac-1","description":"Envelope is unwrapped","type":"functional","verifiable":true}]}
EOF
}

test_envelope_unwrapped() {
    local test_dir="$TEMP_DIR/envelope-test"
    local mock_dir="$TEMP_DIR/envelope-bin"
    mkdir -p "$test_dir"

    local envelope
    envelope=$(jq -n --arg result "$(printf '```json\n%s\n```' "$(_criteria_fixture)")" \
        '{type: "result", subtype: "success", is_error: false, result: $result}')
    _mock_claude "$mock_dir" "$envelope"

    local old_path="$PATH"
    export PATH="$mock_dir:$PATH"
    analyze_intent "Unwrap the envelope" "body" "" "$test_dir" >/dev/null 2>&1 || true
    export PATH="$old_path"

    local goal criteria
    goal=$(jq -r '.goal // empty' "$test_dir/acceptance-criteria.json" 2>/dev/null || true)
    criteria=$(jq -r '.criteria | length' "$test_dir/acceptance-criteria.json" 2>/dev/null || echo 0)

    if [[ "$goal" == "Unwrap the envelope" && "${criteria:-0}" -gt 0 ]]; then
        test_pass "CLI json envelope is unwrapped into acceptance criteria"
        return 0
    fi

    test_fail "CLI json envelope should be unwrapped (goal='$goal', criteria=$criteria)"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: a bare criteria object (no envelope) is accepted as-is
# ───────────────────────────────────────────────────────────────
test_bare_criteria_accepted() {
    local test_dir="$TEMP_DIR/bare-test"
    local mock_dir="$TEMP_DIR/bare-bin"
    mkdir -p "$test_dir"

    _mock_claude "$mock_dir" "$(_criteria_fixture)"

    local old_path="$PATH"
    export PATH="$mock_dir:$PATH"
    analyze_intent "Unwrap the envelope" "body" "" "$test_dir" >/dev/null 2>&1 || true
    export PATH="$old_path"

    if [[ "$(jq -r '.goal // empty' "$test_dir/acceptance-criteria.json" 2>/dev/null || true)" == "Unwrap the envelope" ]]; then
        test_pass "bare criteria object is accepted without an envelope"
        return 0
    fi

    test_fail "bare criteria object should be accepted"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: an off-schema response falls back to defaults
# ───────────────────────────────────────────────────────────────
test_offschema_response_falls_back() {
    local test_dir="$TEMP_DIR/offschema-test"
    local mock_dir="$TEMP_DIR/offschema-bin"
    mkdir -p "$test_dir"

    _mock_claude "$mock_dir" '{"type":"result","result":"I could not produce criteria."}'

    local old_path="$PATH"
    export PATH="$mock_dir:$PATH"
    analyze_intent "Offschema title" "body" "" "$test_dir" >/dev/null 2>&1 || true
    export PATH="$old_path"

    local goal criteria
    goal=$(jq -r '.goal // empty' "$test_dir/acceptance-criteria.json" 2>/dev/null || true)
    criteria=$(jq -r '.criteria | length' "$test_dir/acceptance-criteria.json" 2>/dev/null || echo 0)

    if [[ "$goal" == "Offschema title" && "${criteria:-0}" -gt 0 ]]; then
        test_pass "off-schema response falls back to default criteria"
        return 0
    fi

    test_fail "off-schema response should fall back to defaults (goal='$goal', criteria=$criteria)"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Main test runner
# ───────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║        Intent Analysis Module Test Suite v${VERSION}        ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    test_analyze_intent_generates_json
    test_acceptance_criteria_schema
    test_criteria_fields
    test_failure_modes_validation_pass
    test_failure_modes_validation_missing_section
    test_failure_modes_validation_too_few
    test_failure_modes_validation_generic
    test_format_criteria_for_prompt
    test_load_acceptance_criteria
    test_analyze_intent_fallback
    test_envelope_unwrapped
    test_bare_criteria_accepted
    test_offschema_response_falls_back
    test_inject_failure_mode_analysis
    test_failure_mode_validation_status

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║ Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    [[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
}

main "$@"
