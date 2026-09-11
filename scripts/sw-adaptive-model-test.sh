#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-adaptive-model-test.sh — Test Suite for Adaptive Model Selection       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Test Infrastructure ──────────────────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo "✓ $1"
    ((TESTS_PASSED++)) || true
}
fail() {
    echo "✗ $1"
    ((TESTS_FAILED++)) || true
}
# ─── Load Module ──────────────────────────────────────────────────────────────
test_1() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    if [[ -f "$history_path" ]] && [[ "$(cat "$history_path")" == "[]" ]]; then
        pass "adaptive_model_init creates history file"
    else
        fail "adaptive_model_init creates history file"
    fi

    rm -rf "$tmpdir"
}
test_2() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 0 "pass" 0 50 "opus")
    if [[  "$result" == "opus"  ]]; then
        pass "first iteration returns current model unchanged"
    else
        fail "first iteration returns current model unchanged (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_3() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 1 "fail" 2 30 "haiku")
    if [[  "$result" == "sonnet"  ]]; then
        pass "escalate haiku to sonnet on repeated error"
    else
        fail "escalate haiku to sonnet on repeated error (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_4() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 2 "fail" 1 25 "sonnet")
    if [[  "$result" == "opus"  ]]; then
        pass "escalate sonnet to opus on low convergence"
    else
        fail "escalate sonnet to opus on low convergence (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_5() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 3 "pass" 0 80 "opus")
    if [[  "$result" == "sonnet"  ]]; then
        pass "downgrade opus to sonnet on high convergence"
    else
        fail "downgrade opus to sonnet on high convergence (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_6() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 4 "pass" 0 85 "sonnet")
    if [[  "$result" == "haiku"  ]]; then
        pass "downgrade sonnet to haiku on high convergence"
    else
        fail "downgrade sonnet to haiku on high convergence (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_7() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 5 "pass" 0 90 "haiku")
    if [[  "$result" == "haiku"  ]]; then
        pass "haiku stays at haiku when passing and converging"
    else
        fail "haiku stays at haiku when passing and converging (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_8() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 6 "fail" 3 20 "opus")
    if [[  "$result" == "opus"  ]]; then
        pass "opus stays at opus when failing with repeated error"
    else
        fail "opus stays at opus when failing with repeated error (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_9() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_record 0 "opus" "pass" 0 50 "first_iteration" false false
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    if grep -q '"model".*"opus"' "$history_path"; then
        pass "record writes to history file"
    else
        fail "record writes to history file"
    fi
    rm -rf "$tmpdir"
}
test_10() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_record 1 "sonnet" "fail" 1 40 "escalation_test" true false
    adaptive_model_record 2 "opus" "pass" 0 75 "downgrade_test" false true
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    count=$(grep -c '"model"' "$history_path" || echo "0")
    if [[  "$count" -eq 2  ]]; then
        pass "multiple records accumulate in history"
    else
        fail "multiple records accumulate in history (got $count records)"
    fi
    rm -rf "$tmpdir"
}
test_11() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    cat > "$history_path" <<'EOF'
[
  {"iteration": 0, "model": "haiku", "test_result": "pass", "escalated": false, "downgraded": false},
  {"iteration": 1, "model": "sonnet", "test_result": "pass", "escalated": true, "downgraded": false},
  {"iteration": 2, "model": "opus", "test_result": "pass", "escalated": true, "downgraded": false}
]
EOF

    prefs_file="${HOME}/.shipwright/optimization/model-preferences.json"
    mkdir -p "$(dirname "$prefs_file")"
    cat > "$prefs_file" <<'EOF'
{
  "version": "1.0",
  "stage_priors": {},
  "learned_escalations": {},
  "learned_downgrades": {},
  "last_updated": ""
}
EOF

    adaptive_model_learn

    if command -v jq >/dev/null 2>&1; then
        if jq empty "$prefs_file" 2>/dev/null && jq -e '.learned_escalations.success_rate >= 0' "$prefs_file" >/dev/null 2>&1; then
            pass "adaptive_model_learn writes valid JSON"
        else
            fail "adaptive_model_learn writes valid JSON"
        fi
    else
        pass "adaptive_model_learn writes valid JSON (jq not available, skipping validation)"
    fi
    rm -rf "$tmpdir"
}
test_12() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    cat > "$history_path" <<'EOF'
[
  {"iteration": 0, "model": "haiku", "test_result": "pass", "reason": "first_iteration"},
  {"iteration": 1, "model": "sonnet", "test_result": "pass", "reason": "escalation", "escalated": true},
  {"iteration": 2, "model": "opus", "test_result": "fail", "reason": "no_change"}
]
EOF

    if adaptive_model_report >/dev/null 2>&1; then
        pass "adaptive_model_report runs without error"
    else
        fail "adaptive_model_report runs without error"
    fi
    rm -rf "$tmpdir"
}
test_13() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    if adaptive_model_learn 2>/dev/null; then
        pass "learn handles missing history gracefully"
    else
        fail "learn handles missing history gracefully"
    fi
    rm -rf "$tmpdir"
}
test_14() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    if adaptive_model_report 2>/dev/null | grep "No adaptive model history" >/dev/null; then
        pass "report handles missing history gracefully"
    else
        fail "report handles missing history gracefully"
    fi
    rm -rf "$tmpdir"
}
test_15() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 5 "pass" 0 50 "sonnet")
    if [[  "$result" == "sonnet"  ]]; then
        pass "stable conditions return current model unchanged"
    else
        fail "stable conditions return current model unchanged (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_16() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_record 0 "opus" "pass" 0 50 "test" false false
    adaptive_model_record 1 "opus" "fail" 1 40 "test" false false
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    if grep -q '"test_result".*"pass"' "$history_path"; then
        pass "record accepts valid test results"
    else
        fail "record accepts valid test results"
    fi
    rm -rf "$tmpdir"
}
test_17() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 3 "fail" 0 0 "haiku")
    if [[  "$result" == "sonnet"  ]]; then
        pass "escalate on very low convergence"
    else
        fail "escalate on very low convergence (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_18() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_record 0 "opus" "fail" 3 20 "test_failure_with_reason" true false
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"

    if command -v jq >/dev/null 2>&1; then
        if grep -q '"reason".*"test_failure_with_reason"' "$history_path"; then
            pass "record preserves adaptation reason"
        else
            fail "record preserves adaptation reason"
        fi
    else
        pass "record preserves adaptation reason (jq not available, skipping)"
    fi
    rm -rf "$tmpdir"
}
test_19() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 2 "fail" 1 30 "haiku")
    if [[  "$result" == "haiku"  ]]; then
        pass "no escalation when error_count < threshold"
    else
        fail "no escalation when error_count < threshold (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_20() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_select "build" 0 "pass" 0 50 "opus" > /dev/null
    adaptive_model_select "build" 1 "fail" 2 30 "opus" > /dev/null
    adaptive_model_learn 2>/dev/null

    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    prefs="${HOME}/.shipwright/optimization/model-preferences.json"
    if [[  -f "$history_path" && -f "$prefs"  ]]; then
        pass "full integration: select -> record -> learn"
    else
        fail "full integration: select -> record -> learn"
    fi
    rm -rf "$tmpdir"
}
# ─── Run all tests ─────────────────────────────────────────────────────────────
for i in {1..20}; do
    test_$i
done

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────────────────"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "─────────────────────────────────────────────────────────"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "✓ All tests passed"
    exit 0
else
    echo "✗ Some tests failed"
    exit 1
fi
