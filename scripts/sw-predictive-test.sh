#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright predictive test — Unit tests for predictive intelligence     ║
# ║  Risk · Anomaly · AI patrol · Prevention · Baselines · Degradation      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (matches shipwright theme) ──────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-predictive-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/baselines"
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/scripts"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/src"
    mkdir -p "$TEMP_DIR/repo/tests"

    # Copy script under test and lib directory
    cp "$SCRIPT_DIR/sw-predictive.sh" "$TEMP_DIR/scripts/"
    if [[ -d "$SCRIPT_DIR/lib" ]]; then
        cp -r "$SCRIPT_DIR/lib" "$TEMP_DIR/scripts/lib"
    fi

    # Create mock intelligence engine (claude unavailable by default)
    cat > "$TEMP_DIR/scripts/sw-intelligence.sh" <<'INTEOF'
#!/usr/bin/env bash
# Mock intelligence engine — _intelligence_call_claude returns nothing by default
_intelligence_call_claude() {
    echo ""
}
INTEOF

    # Create mock memory script
    cat > "$TEMP_DIR/scripts/sw-memory.sh" <<'MEMEOF'
#!/usr/bin/env bash
# Mock memory — inject returns known patterns
if [[ "${1:-}" == "inject" ]]; then
    echo "# Shipwright Memory Context"
    echo "## Failure Patterns to Avoid"
    echo "- [build] Missing dependency in package.json (seen 3x)"
    echo "  Fix: Run npm install before build"
fi
MEMEOF
    chmod +x "$TEMP_DIR/scripts/sw-memory.sh"

    # Create sample source files for patrol tests
    cat > "$TEMP_DIR/repo/src/app.js" <<'SRCEOF'
const express = require('express');
const app = express();
// TODO: add input validation
app.get('/api/users', (req, res) => {
    const query = req.query.search;
    res.send(db.query(`SELECT * FROM users WHERE name = '${query}'`));
});
SRCEOF

    cat > "$TEMP_DIR/repo/tests/app.test.js" <<'TSTEOF'
describe('app', () => {
    it('should respond', () => {
        expect(true).toBe(true);
    });
});
TSTEOF

    # Create mock compat.sh (minimal — must include compute_md5 for predictive)
    mkdir -p "$TEMP_DIR/scripts/lib"
    cat > "$TEMP_DIR/scripts/lib/compat.sh" <<'COMPATEOF'
#!/usr/bin/env bash
# Mock compat
compute_md5() {
    if [[ "${1:-}" == "--string" ]]; then
        shift
        printf '%s' "$1" | md5 2>/dev/null || printf '%s' "$1" | md5sum 2>/dev/null | cut -d' ' -f1
    else
        local file="$1"
        md5 -q "$file" 2>/dev/null || md5sum "$file" 2>/dev/null | awk '{print $1}'
    fi
}
COMPATEOF

    export ORIG_HOME="$HOME"
    export HOME="$TEMP_DIR/home"
    export EVENTS_FILE="$TEMP_DIR/home/.shipwright/events.jsonl"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    if [[ -n "${ORIG_HOME:-}" ]]; then
        export HOME="$ORIG_HOME"
    fi
}
trap cleanup_env EXIT

# Reset between tests
reset_test() {
    rm -f "$EVENTS_FILE"
    rm -f "$TEMP_DIR/home/.shipwright/baselines/default.json"
    rm -f "$TEMP_DIR/home/.shipwright/baselines/test.json"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "

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

# ═══════════════════════════════════════════════════════════════════════════════
# RISK ASSESSMENT TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Risk assessment returns valid schema with probabilities (0-100)
# ──────────────────────────────────────────────────────────────────────────────
test_risk_valid_schema() {
    reset_test

    local output
    output=$(bash "$TEMP_DIR/scripts/sw-predictive.sh" risk '{"title":"Add login page"}' 2>/dev/null)

    # Must be valid JSON
    if ! echo "$output" | jq -e '.' &>/dev/null; then
        echo -e "    ${RED}✗${RESET} Output is not valid JSON: $output"
        return 1
    fi

    # Must have overall_risk in 0-100 range
    local risk
    risk=$(echo "$output" | jq '.overall_risk')
    if [[ -z "$risk" || "$risk" == "null" ]]; then
        echo -e "    ${RED}✗${RESET} Missing overall_risk field"
        return 1
    fi
    if [[ "$risk" -lt 0 || "$risk" -gt 100 ]]; then
        echo -e "    ${RED}✗${RESET} Risk $risk out of 0-100 range"
        return 1
    fi

    # Must have failure_stages array
    local has_stages
    has_stages=$(echo "$output" | jq 'has("failure_stages")' 2>/dev/null)
    if [[ "$has_stages" != "true" ]]; then
        echo -e "    ${RED}✗${RESET} Missing failure_stages array"
        return 1
    fi

    # Must have preventative_actions array
    local has_actions
    has_actions=$(echo "$output" | jq 'has("preventative_actions")' 2>/dev/null)
    if [[ "$has_actions" != "true" ]]; then
        echo -e "    ${RED}✗${RESET} Missing preventative_actions array"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Risk assessment elevates risk for complex keywords
# ──────────────────────────────────────────────────────────────────────────────
test_risk_elevated_keywords() {
    reset_test

    local output_normal output_complex
    output_normal=$(bash "$TEMP_DIR/scripts/sw-predictive.sh" risk '{"title":"Fix typo"}' 2>/dev/null)
    output_complex=$(bash "$TEMP_DIR/scripts/sw-predictive.sh" risk '{"title":"Refactor authentication with breaking changes"}' 2>/dev/null)

    local risk_normal risk_complex
    risk_normal=$(echo "$output_normal" | jq '.overall_risk')
    risk_complex=$(echo "$output_complex" | jq '.overall_risk')

    if [[ "$risk_complex" -le "$risk_normal" ]]; then
        echo -e "    ${RED}✗${RESET} Complex issue risk ($risk_complex) should be > normal ($risk_normal)"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# ANOMALY DETECTION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 3. Anomaly detection triggers critical at 3x threshold (180s vs 60s baseline)
# ──────────────────────────────────────────────────────────────────────────────
test_anomaly_critical_at_3x() {
    reset_test

    local baseline_file="$TEMP_DIR/home/.shipwright/baselines/test.json"
    # Create baseline: build.duration = 60
    echo '{"build.duration": {"value": 60, "count": 10, "updated": "2026-01-01T00:00:00Z"}}' > "$baseline_file"

    # 180s = exactly 3x baseline → should trigger critical (> 3x check)
    # Use 181 to be safely above threshold
    local result
    result=$(bash "$TEMP_DIR/scripts/sw-predictive.sh" anomaly "build" "duration" "181" "$baseline_file" 2>/dev/null)

    if [[ "$result" != "critical" ]]; then
        echo -e "    ${RED}✗${RESET} Expected 'critical' for 181s vs 60s baseline (3x=180), got: $result"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Anomaly detection does NOT trigger critical at 2x (within tolerance)
# ──────────────────────────────────────────────────────────────────────────────
test_anomaly_normal_at_2x() {
    reset_test

    local baseline_file="$TEMP_DIR/home/.shipwright/baselines/test.json"
    echo '{"build.duration": {"value": 60, "count": 10, "updated": "2026-01-01T00:00:00Z"}}' > "$baseline_file"

    # 119s = just under 2x baseline (120) → should be normal
    local result
    result=$(bash "$TEMP_DIR/scripts/sw-predictive.sh" anomaly "build" "duration" "119" "$baseline_file" 2>/dev/null)

    if [[ "$result" != "normal" ]]; then
        echo -e "    ${RED}✗${RESET} Expected 'normal' for 119s vs 60s baseline, got: $result"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Anomaly detection returns warning between 2x and 3x
# ──────────────────────────────────────────────────────────────────────────────
test_anomaly_warning_between() {
    reset_test

    local baseline_file="$TEMP_DIR/home/.shipwright/baselines/test.json"
    echo '{"build.duration": {"value": 60, "count": 10, "updated": "2026-01-01T00:00:00Z"}}' > "$baseline_file"

    # 150s = 2.5x baseline → should be warning (> 2x but <= 3x)
    local result
    result=$(bash "$TEMP_DIR/scripts/sw-predictive.sh" anomaly "build" "duration" "150" "$baseline_file" 2>/dev/null)

    if [[ "$result" != "warning" ]]; then
        echo -e "    ${RED}✗${RESET} Expected 'warning' for 150s vs 60s baseline, got: $result"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Anomaly detection returns normal when no baseline exists
# ──────────────────────────────────────────────────────────────────────────────
test_anomaly_no_baseline() {
    reset_test

    local baseline_file="$TEMP_DIR/home/.shipwright/baselines/empty.json"
    echo '{}' > "$baseline_file"

    local result
    result=$(bash "$TEMP_DIR/scripts/sw-predictive.sh" anomaly "build" "duration" "999" "$baseline_file" 2>/dev/null)

    if [[ "$result" != "normal" ]]; then
        echo -e "    ${RED}✗${RESET} Expected 'normal' with no baseline, got: $result"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Anomaly emits event for critical/warning
# ──────────────────────────────────────────────────────────────────────────────
test_anomaly_emits_event() {
    reset_test

    local baseline_file="$TEMP_DIR/home/.shipwright/baselines/test.json"
    echo '{"test.failures": {"value": 5, "count": 10, "updated": "2026-01-01T00:00:00Z"}}' > "$baseline_file"

    # 16 = > 3x of 5 → critical
    bash "$TEMP_DIR/scripts/sw-predictive.sh" anomaly "test" "failures" "16" "$baseline_file" >/dev/null 2>&1

    if [[ ! -f "$EVENTS_FILE" ]]; then
        echo -e "    ${RED}✗${RESET} No events file created"
        return 1
    fi

    local event_count
    event_count=$(grep -c "prediction.anomaly" "$EVENTS_FILE" 2>/dev/null || true)
    event_count="${event_count:-0}"

    if [[ "$event_count" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} Expected prediction.anomaly event, found $event_count"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# BASELINE UPDATE TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 8. Baseline update with first data point uses raw value
# ──────────────────────────────────────────────────────────────────────────────
test_baseline_first_value() {
    reset_test

    local baseline_file="$TEMP_DIR/home/.shipwright/baselines/test.json"
    echo '{}' > "$baseline_file"

    bash "$TEMP_DIR/scripts/sw-predictive.sh" baseline "build" "duration" "60" "$baseline_file" 2>/dev/null

    local stored_value
    stored_value=$(jq -r '.["build.duration"].value' "$baseline_file" 2>/dev/null)

    # First data point should be raw value (60)
    if [[ "$stored_value" != "60" ]]; then
        echo -e "    ${RED}✗${RESET} Expected 60 for first data point, got: $stored_value"
        return 1
    fi

    local count
    count=$(jq -r '.["build.duration"].count' "$baseline_file" 2>/dev/null)
    if [[ "$count" != "1" ]]; then
        echo -e "    ${RED}✗${RESET} Expected count=1, got: $count"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Baseline update uses EMA correctly
# ──────────────────────────────────────────────────────────────────────────────
test_baseline_ema_calculation() {
    reset_test

    local baseline_file="$TEMP_DIR/home/.shipwright/baselines/test.json"
    # Start with known baseline
    echo '{"build.duration": {"value": 100, "count": 5, "updated": "2026-01-01T00:00:00Z"}}' > "$baseline_file"

    # Update with value 200 → EMA: 0.9 * 100 + 0.1 * 200 = 90 + 20 = 110
    bash "$TEMP_DIR/scripts/sw-predictive.sh" baseline "build" "duration" "200" "$baseline_file" 2>/dev/null

    local stored_value
    stored_value=$(jq -r '.["build.duration"].value' "$baseline_file" 2>/dev/null)

    # Should be 110 (EMA result)
    if [[ "$stored_value" != "110" && "$stored_value" != "110.00" ]]; then
        echo -e "    ${RED}✗${RESET} Expected EMA result 110, got: $stored_value"
        return 1
    fi

    local count
    count=$(jq -r '.["build.duration"].count' "$baseline_file" 2>/dev/null)
    if [[ "$count" != "6" ]]; then
        echo -e "    ${RED}✗${RESET} Expected count=6, got: $count"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Baseline update creates file if missing
# ──────────────────────────────────────────────────────────────────────────────
test_baseline_creates_file() {
    reset_test

    local baseline_file="$TEMP_DIR/home/.shipwright/baselines/new.json"
    rm -f "$baseline_file"

    bash "$TEMP_DIR/scripts/sw-predictive.sh" baseline "deploy" "time" "300" "$baseline_file" 2>/dev/null

    if [[ ! -f "$baseline_file" ]]; then
        echo -e "    ${RED}✗${RESET} Baseline file not created"
        return 1
    fi

    local val
    val=$(jq -r '.["deploy.time"].value' "$baseline_file" 2>/dev/null)
    if [[ "$val" != "300" ]]; then
        echo -e "    ${RED}✗${RESET} Expected value 300, got: $val"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# PREVENTATIVE INJECTION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 11. Prevention injection adds context from memory patterns
# ──────────────────────────────────────────────────────────────────────────────
test_prevention_with_patterns() {
    reset_test

    local memory_context="## Failure Patterns to Avoid
- [build] Missing dependency (seen 3x)
  Fix: Run npm install
- [test] Flaky timeout in CI (seen 2x)
  Fix: Increase timeout"

    local output
    output=$(bash "$TEMP_DIR/scripts/sw-predictive.sh" risk '{}' >/dev/null 2>&1; true)

    # Test the prevention function directly via sourcing
    # Use a subshell to avoid polluting our environment
    output=$(
        export HOME="$TEMP_DIR/home"
        export SCRIPT_DIR="$TEMP_DIR/scripts"
        source "$TEMP_DIR/scripts/sw-predictive.sh" 2>/dev/null
        predict_inject_prevention "build" '{}' "$memory_context"
    )

    if [[ -z "$output" ]]; then
        echo -e "    ${RED}✗${RESET} Prevention injection returned empty for stage with known patterns"
        return 1
    fi

    if ! echo "$output" | grep -qi "WARNING"; then
        echo -e "    ${RED}✗${RESET} Prevention text missing WARNING prefix"
        return 1
    fi

    if ! echo "$output" | grep -qi "build"; then
        echo -e "    ${RED}✗${RESET} Prevention text doesn't mention the stage"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Prevention injection returns empty when no patterns match
# ──────────────────────────────────────────────────────────────────────────────
test_prevention_empty_no_match() {
    reset_test

    # Remove mock memory script so fallback path also finds nothing
    local mem_backup="$TEMP_DIR/scripts/sw-memory.sh.bak"
    mv "$TEMP_DIR/scripts/sw-memory.sh" "$mem_backup"

    local memory_context="## Failure Patterns to Avoid
- [deploy] Server timeout (seen 1x)"

    local output
    output=$(
        export HOME="$TEMP_DIR/home"
        export SCRIPT_DIR="$TEMP_DIR/scripts"
        source "$TEMP_DIR/scripts/sw-predictive.sh" 2>/dev/null
        predict_inject_prevention "build" '{}' "$memory_context"
    )

    # Restore mock memory
    mv "$mem_backup" "$TEMP_DIR/scripts/sw-memory.sh"

    # Should be empty since no [build] patterns exist in context and no memory script
    if [[ -n "$output" ]]; then
        echo -e "    ${RED}✗${RESET} Expected empty output for non-matching stage, got: $output"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# GRACEFUL DEGRADATION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 13. Graceful degradation when claude unavailable
# ──────────────────────────────────────────────────────────────────────────────
test_graceful_degradation() {
    reset_test

    # Remove intelligence engine to simulate unavailability
    rm -f "$TEMP_DIR/scripts/sw-intelligence.sh"

    # Risk assessment should still work (heuristic fallback)
    local output
    output=$(bash "$TEMP_DIR/scripts/sw-predictive.sh" risk '{"title":"Simple fix"}' 2>/dev/null)

    if ! echo "$output" | jq -e '.overall_risk' &>/dev/null; then
        echo -e "    ${RED}✗${RESET} Risk assessment failed without intelligence engine"
        return 1
    fi

    # Patrol should return empty array
    local patrol_output
    patrol_output=$(bash "$TEMP_DIR/scripts/sw-predictive.sh" patrol "$TEMP_DIR/repo/src/app.js" 2>/dev/null)

    if [[ "$patrol_output" != "[]" ]]; then
        echo -e "    ${RED}✗${RESET} Expected empty patrol results without AI, got: $patrol_output"
        return 1
    fi

    # Restore for other tests
    cat > "$TEMP_DIR/scripts/sw-intelligence.sh" <<'INTEOF'
#!/usr/bin/env bash
_intelligence_call_claude() { echo ""; }
INTEOF

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Risk emits event
# ──────────────────────────────────────────────────────────────────────────────
test_risk_emits_event() {
    reset_test

    bash "$TEMP_DIR/scripts/sw-predictive.sh" risk '{"title":"test"}' >/dev/null 2>&1

    if [[ ! -f "$EVENTS_FILE" ]]; then
        echo -e "    ${RED}✗${RESET} No events file created"
        return 1
    fi

    local event_count
    event_count=$(grep -c "prediction.risk_assessed" "$EVENTS_FILE" 2>/dev/null || true)
    event_count="${event_count:-0}"

    if [[ "$event_count" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} Expected prediction.risk_assessed event"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. AI patrol with valid intelligence returns structured findings
# ──────────────────────────────────────────────────────────────────────────────
test_patrol_with_ai() {
    reset_test

    # Create an intelligence engine that returns findings
    cat > "$TEMP_DIR/scripts/sw-intelligence.sh" <<'INTEOF'
#!/usr/bin/env bash
_intelligence_call_claude() {
    echo '[{"severity":"high","category":"security","finding":"SQL injection in query","recommendation":"Use parameterized queries"}]'
}
INTEOF

    local output
    output=$(bash "$TEMP_DIR/scripts/sw-predictive.sh" patrol "$TEMP_DIR/repo/src/app.js" 2>/dev/null)

    if ! echo "$output" | jq -e 'type == "array"' &>/dev/null; then
        echo -e "    ${RED}✗${RESET} Output is not a JSON array: $output"
        return 1
    fi

    local count
    count=$(echo "$output" | jq 'length')
    if [[ "$count" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} Expected at least 1 finding, got $count"
        return 1
    fi

    local sev
    sev=$(echo "$output" | jq -r '.[0].severity')
    if [[ "$sev" != "high" && "$sev" != "critical" ]]; then
        echo -e "    ${RED}✗${RESET} Expected high/critical severity, got: $sev"
        return 1
    fi

    # Check event was emitted
    if [[ -f "$EVENTS_FILE" ]]; then
        local patrol_events
        patrol_events=$(grep -c "patrol.ai_finding" "$EVENTS_FILE" 2>/dev/null || true)
        patrol_events="${patrol_events:-0}"
        if [[ "$patrol_events" -lt 1 ]]; then
            echo -e "    ${RED}✗${RESET} Expected patrol.ai_finding event"
            return 1
        fi
    fi

    # Restore default mock
    cat > "$TEMP_DIR/scripts/sw-intelligence.sh" <<'INTEOF'
#!/usr/bin/env bash
_intelligence_call_claude() { echo ""; }
INTEOF

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright predictive test                              ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════╝${RESET}"
echo ""

setup_env
echo ""

# Risk tests
echo -e "${PURPLE}${BOLD}Risk Assessment${RESET}"
run_test "Risk returns valid schema with 0-100 range" test_risk_valid_schema
run_test "Risk elevates for complex keywords" test_risk_elevated_keywords
run_test "Risk emits event" test_risk_emits_event
echo ""

# Anomaly tests
echo -e "${PURPLE}${BOLD}Anomaly Detection${RESET}"
run_test "Critical at 3x threshold (181 vs 60 baseline)" test_anomaly_critical_at_3x
run_test "Normal at 2x (119 vs 60 baseline)" test_anomaly_normal_at_2x
run_test "Warning between 2x and 3x (150 vs 60)" test_anomaly_warning_between
run_test "Normal when no baseline exists" test_anomaly_no_baseline
run_test "Emits event for critical anomaly" test_anomaly_emits_event
echo ""

# Baseline tests
echo -e "${PURPLE}${BOLD}Baseline Management${RESET}"
run_test "First data point uses raw value" test_baseline_first_value
run_test "EMA calculation (0.9*100 + 0.1*200 = 110)" test_baseline_ema_calculation
run_test "Creates baseline file if missing" test_baseline_creates_file
echo ""

# Prevention tests
echo -e "${PURPLE}${BOLD}Preventative Injection${RESET}"
run_test "Injects context from matching patterns" test_prevention_with_patterns
run_test "Returns empty for non-matching stage" test_prevention_empty_no_match
echo ""

# Degradation tests
echo -e "${PURPLE}${BOLD}Graceful Degradation${RESET}"
run_test "Works without intelligence engine" test_graceful_degradation
echo ""

# AI patrol tests
echo -e "${PURPLE}${BOLD}AI Patrol${RESET}"
run_test "AI patrol returns structured findings" test_patrol_with_ai
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All ${TOTAL} tests passed ✓${RESET}"
else
    echo -e "${RED}${BOLD}  ${FAIL}/${TOTAL} tests failed${RESET}"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
fi
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
echo ""

exit "$FAIL"
