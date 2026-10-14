#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright decide test — Unit tests for the Autonomous Decision Engine ║
# ║  Tests: help, tiers, signals, scoring, autonomy, dedup, dry-run,        ║
# ║         decision log, outcome learning, candidates, cycle integration   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "sw-decide Tests"

setup_test_env "sw-decide-test"
trap cleanup_test_env EXIT

# ─── Build test repo ──────────────────────────────────────────────────────────
TEST_REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$TEST_REPO/scripts/lib" "$TEST_REPO/config" "$TEST_REPO/.claude/decision-drafts"

# Copy required scripts
cp "$SCRIPT_DIR/sw-decide.sh" "$TEST_REPO/scripts/"
cp "$SCRIPT_DIR/lib/helpers.sh" "$TEST_REPO/scripts/lib/"
cp "$SCRIPT_DIR/lib/decide-signals.sh" "$TEST_REPO/scripts/lib/"
cp "$SCRIPT_DIR/lib/decide-scoring.sh" "$TEST_REPO/scripts/lib/"
cp "$SCRIPT_DIR/lib/decide-autonomy.sh" "$TEST_REPO/scripts/lib/"
cp "$SCRIPT_DIR/lib/safety-gates.sh" "$TEST_REPO/scripts/lib/"
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && cp "$SCRIPT_DIR/lib/compat.sh" "$TEST_REPO/scripts/lib/"
[[ -f "$SCRIPT_DIR/lib/policy.sh" ]] && cp "$SCRIPT_DIR/lib/policy.sh" "$TEST_REPO/scripts/lib/"

# Copy tiers config
cp "$SCRIPT_DIR/../config/decision-tiers.json" "$TEST_REPO/config/"

# Policy with decision enabled
cat > "$TEST_REPO/config/policy.json" <<'POLICY'
{
  "decision": {
    "enabled": true,
    "cycle_interval_seconds": 1800,
    "tiers_file": "config/decision-tiers.json",
    "outcome_learning_enabled": true,
    "outcome_min_samples": 3,
    "dedup_window_days": 7
  }
}
POLICY

mock_git
mock_gh

run_decide() {
    cd "$TEST_REPO" && bash "$TEST_REPO/scripts/sw-decide.sh" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════════
# help
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "help"

help_out=$(run_decide help 2>&1) || true
assert_contains "help shows usage" "$help_out" "Usage:"
assert_contains "help mentions run" "$help_out" "run"
assert_contains "help mentions status" "$help_out" "status"
assert_contains "help mentions tiers" "$help_out" "tiers"
assert_contains "help mentions candidates" "$help_out" "candidates"
assert_contains "help mentions halt" "$help_out" "halt"
assert_contains "help mentions resume" "$help_out" "resume"
assert_contains "help mentions dry-run" "$help_out" "dry-run"

help_h=$(run_decide --help 2>&1) || true
assert_contains "--help shows usage" "$help_h" "shipwright decide"

# ═══════════════════════════════════════════════════════════════════════════════
# tiers
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "tiers"

tiers_out=$(run_decide tiers 2>&1) || true
assert_contains "tiers shows auto" "$tiers_out" "auto"
assert_contains "tiers shows propose" "$tiers_out" "propose"
assert_contains "tiers shows draft" "$tiers_out" "draft"
assert_contains "tiers shows category rules" "$tiers_out" "deps_patch"
assert_contains "tiers shows limits" "$tiers_out" "max_issues_per_day"

# ═══════════════════════════════════════════════════════════════════════════════
# signals — mock signal data, verify collection and normalization
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "signals"

# Source the signals lib directly to test functions
(
    source "$TEST_REPO/scripts/lib/helpers.sh"
    source "$TEST_REPO/scripts/lib/decide-signals.sh"

    # Test _build_candidate
    candidate=$(_build_candidate "test-1" "security" "security_patch" "Test vuln" "Fix it" 60 "0.90" "sec:test:1")
    assert_contains "candidate has id" "$candidate" '"id"'
    assert_contains "candidate has signal" "$candidate" '"signal"'
    assert_contains "candidate has category" "$candidate" '"category"'
    assert_contains "candidate has risk_score" "$candidate" '"risk_score"'
    assert_contains "candidate has dedup_key" "$candidate" '"dedup_key"'
    assert_contains "candidate has collected_at" "$candidate" '"collected_at"'

    # Verify JSON validity
    if echo "$candidate" | jq empty 2>/dev/null; then
        assert_pass "candidate is valid JSON"
    else
        assert_fail "candidate is valid JSON"
    fi
)

# Test pending signals
(
    source "$TEST_REPO/scripts/lib/helpers.sh"
    source "$TEST_REPO/scripts/lib/decide-signals.sh"

    mkdir -p "$SIGNALS_DIR"
    echo '{"id":"pending-1","signal":"test","category":"test_coverage","title":"Add tests"}' > "$SIGNALS_PENDING_FILE"

    pending=$(signals_read_pending)
    assert_contains "read_pending returns data" "$pending" "pending-1"

    signals_clear_pending
    if [[ ! -s "$SIGNALS_PENDING_FILE" ]]; then
        assert_pass "clear_pending empties file"
    else
        assert_fail "clear_pending empties file"
    fi
)

# ═══════════════════════════════════════════════════════════════════════════════
# scoring — verify formula correctness with known inputs
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "scoring"

(
    source "$TEST_REPO/scripts/lib/helpers.sh"
    source "$TEST_REPO/scripts/lib/decide-scoring.sh"

    # Reset weights to defaults
    _W_IMPACT=30 _W_URGENCY=25 _W_EFFORT=20 _W_CONFIDENCE=15 _W_RISK=10

    # Test with a security candidate
    candidate='{"id":"test-sec","signal":"security","category":"security_patch","title":"Fix CVE","description":"test","evidence":{"severity":"critical"},"risk_score":30,"confidence":"0.95","dedup_key":"test"}'

    scored=$(score_candidate "$candidate")

    # Verify scored output has value_score
    assert_contains "scored has value_score" "$scored" '"value_score"'
    assert_contains "scored has scores object" "$scored" '"scores"'

    # Verify score is reasonable for a critical security issue
    value=$(echo "$scored" | jq '.value_score')
    if [[ "$value" -gt 30 ]]; then
        assert_pass "critical security scores well (${value})"
    else
        assert_fail "critical security scores well" "expected >30, got: $value"
    fi

    # Test with a low-priority candidate (dead code)
    low_candidate='{"id":"test-dc","signal":"dead_code","category":"dead_code","title":"Clean dead code","description":"test","evidence":{},"risk_score":25,"confidence":"0.70","dedup_key":"test2"}'

    low_scored=$(score_candidate "$low_candidate")
    low_value=$(echo "$low_scored" | jq '.value_score')

    if [[ "$value" -gt "$low_value" ]]; then
        assert_pass "security scores higher than dead_code ($value > $low_value)"
    else
        assert_fail "security scores higher than dead_code" "sec=$value, dc=$low_value"
    fi
)

# Test weight loading from tiers config
(
    source "$TEST_REPO/scripts/lib/helpers.sh"
    source "$TEST_REPO/scripts/lib/decide-scoring.sh"

    TIERS_FILE="$TEST_REPO/config/decision-tiers.json"
    scoring_load_weights

    # Weights should be loaded from config (0.30 * 100 = 30)
    assert_eq "impact weight loaded" "30" "$_W_IMPACT"
    assert_eq "urgency weight loaded" "25" "$_W_URGENCY"
)

# ═══════════════════════════════════════════════════════════════════════════════
# autonomy — tier resolution, budget, rate limiting, halt/resume
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "autonomy"

(
    source "$TEST_REPO/scripts/lib/helpers.sh"
    source "$TEST_REPO/scripts/lib/policy.sh"
    source "$TEST_REPO/scripts/lib/decide-autonomy.sh"

    cd "$TEST_REPO"
    autonomy_load_tiers

    # Tier resolution
    tier=$(autonomy_resolve_tier "deps_patch")
    assert_eq "deps_patch -> auto" "auto" "$tier"

    tier=$(autonomy_resolve_tier "refactor_hotspot")
    assert_eq "refactor_hotspot -> propose" "propose" "$tier"

    tier=$(autonomy_resolve_tier "new_feature")
    assert_eq "new_feature -> draft" "draft" "$tier"

    tier=$(autonomy_resolve_tier "unknown_category")
    assert_eq "unknown -> draft" "draft" "$tier"

    # Labels
    labels=$(autonomy_get_labels "auto")
    assert_contains "auto labels include shipwright" "$labels" "shipwright"
    assert_contains "auto labels include ready-to-build" "$labels" "ready-to-build"

    labels=$(autonomy_get_labels "propose")
    assert_contains "propose labels include proposed" "$labels" "proposed"
)

# Budget enforcement
(
    source "$TEST_REPO/scripts/lib/helpers.sh"
    source "$TEST_REPO/scripts/lib/policy.sh"
    source "$TEST_REPO/scripts/lib/decide-autonomy.sh"

    cd "$TEST_REPO"
    autonomy_load_tiers

    # Fresh state — budget should be available
    if autonomy_check_budget "auto"; then
        assert_pass "budget available with no decisions"
    else
        assert_fail "budget available with no decisions"
    fi

    # Exhaust budget
    log_file=$(_daily_log_file)
    mkdir -p "$(dirname "$log_file")"
    # shellcheck disable=SC2034
    for i in $(seq 1 16); do
        echo '{"action":"issue_created","estimated_cost_usd":0.01}' >> "$log_file"
    done

    if ! autonomy_check_budget "auto"; then
        assert_pass "budget exhausted after 16 issues"
    else
        assert_fail "budget exhausted after 16 issues"
    fi
)

# Rate limiting
(
    source "$TEST_REPO/scripts/lib/helpers.sh"
    source "$TEST_REPO/scripts/lib/policy.sh"
    source "$TEST_REPO/scripts/lib/decide-autonomy.sh"

    cd "$TEST_REPO"
    autonomy_load_tiers

    # No last decision — should pass
    if autonomy_check_rate_limit; then
        assert_pass "rate limit passes with no history"
    else
        assert_fail "rate limit passes with no history"
    fi

    # Set last decision to now
    mkdir -p "$DECISIONS_DIR"
    jq -n --argjson epoch "$(date +%s)" '{epoch: $epoch}' > "$LAST_DECISION_FILE"

    if ! autonomy_check_rate_limit; then
        assert_pass "rate limit blocks recent decision"
    else
        assert_fail "rate limit blocks recent decision"
    fi
)

# Halt / Resume
(
    source "$TEST_REPO/scripts/lib/helpers.sh"
    source "$TEST_REPO/scripts/lib/decide-autonomy.sh"

    if autonomy_check_halt; then
        assert_pass "not halted initially"
    else
        assert_fail "not halted initially"
    fi

    autonomy_halt "test halt"

    if ! autonomy_check_halt; then
        assert_pass "halted after halt()"
    else
        assert_fail "halted after halt()"
    fi

    assert_file_exists "halt file created" "$HALT_FILE"

    autonomy_resume

    if autonomy_check_halt; then
        assert_pass "resumed after resume()"
    else
        assert_fail "resumed after resume()"
    fi
)

# ═══════════════════════════════════════════════════════════════════════════════
# risk ceiling
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "risk ceiling"

(
    source "$TEST_REPO/scripts/lib/helpers.sh"
    source "$TEST_REPO/scripts/lib/policy.sh"
    source "$TEST_REPO/scripts/lib/decide-autonomy.sh"

    cd "$TEST_REPO"
    autonomy_load_tiers

    # deps_patch ceiling = 30
    if autonomy_check_risk_ceiling "deps_patch" 20; then
        assert_pass "risk 20 below ceiling 30"
    else
        assert_fail "risk 20 below ceiling 30"
    fi

    if ! autonomy_check_risk_ceiling "deps_patch" 35; then
        assert_pass "risk 35 above ceiling 30"
    else
        assert_fail "risk 35 above ceiling 30"
    fi
)

# ═══════════════════════════════════════════════════════════════════════════════
# dry-run — verify no side effects
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "dry-run"

# Clean state
rm -rf "$HOME/.shipwright/decisions"
rm -rf "$TEST_REPO/.claude/decision-drafts"
mkdir -p "$TEST_REPO/.claude/decision-drafts"

# Write a pending signal so there's something to process
mkdir -p "$HOME/.shipwright/signals"
echo '{"id":"dry-test-1","signal":"docs","category":"doc_sync","title":"Sync docs","description":"test","evidence":{},"risk_score":15,"confidence":"0.85","dedup_key":"docs:stale"}' > "$HOME/.shipwright/signals/pending.jsonl"

dry_out=$(run_decide run --dry-run --once 2>&1) || true
assert_contains "dry-run shows DRY RUN" "$dry_out" "DRY RUN"

# Verify no daily log created (or empty)
daily_log="$HOME/.shipwright/decisions/daily-log-$(date -u +%Y-%m-%d).jsonl"
if [[ ! -f "$daily_log" ]]; then
    assert_pass "no daily log created in dry-run"
else
    line_count=$(wc -l < "$daily_log" 2>/dev/null | tr -d ' ')
    assert_eq "no entries in daily log" "0" "${line_count:-0}"
fi

# Verify no drafts created
draft_count=$(find "$TEST_REPO/.claude/decision-drafts" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no drafts in dry-run" "0" "$draft_count"

# ═══════════════════════════════════════════════════════════════════════════════
# decision log — verify JSONL format
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "decision log"

(
    source "$TEST_REPO/scripts/lib/helpers.sh"
    source "$TEST_REPO/scripts/lib/policy.sh"
    source "$TEST_REPO/scripts/lib/decide-autonomy.sh"

    cd "$TEST_REPO"
    autonomy_load_tiers

    # Record a mock decision
    record=$(jq -n '{"id":"log-test-1","title":"Test","category":"doc_sync","tier":"auto","action":"issue_created","value_score":42,"dedup_key":"test:log","decided_at":"2026-02-22T00:00:00Z","epoch":1740182400,"estimated_cost_usd":0.01}')
    autonomy_record_decision "$record"

    # Verify daily log has the entry
    log_file=$(_daily_log_file)
    assert_file_exists "daily log exists" "$log_file"

    content=$(cat "$log_file")
    assert_contains "log has decision id" "$content" "log-test-1"
    assert_contains "log has value_score" "$content" "42"

    # Verify last-decision file
    assert_file_exists "last-decision written" "$LAST_DECISION_FILE"
)

# ═══════════════════════════════════════════════════════════════════════════════
# outcome learning
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "outcome learning"

(
    source "$TEST_REPO/scripts/lib/helpers.sh"
    source "$TEST_REPO/scripts/lib/decide-scoring.sh"

    _W_IMPACT=30 _W_URGENCY=25 _W_EFFORT=20 _W_CONFIDENCE=15 _W_RISK=10

    # Apply a success outcome for security signal
    outcome='{"decision_id":"test","result":"success","signal":"security"}'
    scoring_update_weights "$outcome"

    # Urgency should have been nudged toward 30 for security success
    # The EMA formula: new = old * 0.8 + target * 0.2
    # 25 * 0.8 + 30 * 0.2 = 20 + 6 = 26, then normalized
    if [[ "$_W_URGENCY" -ge 25 ]]; then
        assert_pass "urgency weight adjusted on security success ($_W_URGENCY)"
    else
        assert_fail "urgency weight adjusted" "expected >= 25, got: $_W_URGENCY"
    fi

    # Apply a failure outcome
    old_risk=$_W_RISK
    failure_outcome='{"decision_id":"test2","result":"failure","signal":"deps"}'
    scoring_update_weights "$failure_outcome"

    # Risk weight should have increased
    if [[ "$_W_RISK" -ge "$old_risk" ]]; then
        assert_pass "risk weight increased on failure ($_W_RISK >= $old_risk)"
    else
        assert_fail "risk weight increased on failure" "expected >= $old_risk, got: $_W_RISK"
    fi

    # Verify normalization — weights should sum to 100
    total=$(( _W_IMPACT + _W_URGENCY + _W_EFFORT + _W_CONFIDENCE + _W_RISK ))
    assert_eq "weights sum to 100" "100" "$total"

    # Verify weights file written
    assert_file_exists "weights file written" "$WEIGHTS_FILE"
)

# ═══════════════════════════════════════════════════════════════════════════════
# candidates — listing without action
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "candidates"

# Place a pending signal
mkdir -p "$HOME/.shipwright/signals"
echo '{"id":"cand-1","signal":"coverage","category":"test_coverage","title":"Add tests for utils","description":"test","evidence":{},"risk_score":20,"confidence":"0.85","dedup_key":"cov:test"}' > "$HOME/.shipwright/signals/pending.jsonl"

cand_out=$(run_decide candidates 2>&1) || true
assert_contains "candidates shows title" "$cand_out" "Add tests for utils"
assert_contains "candidates shows signal" "$cand_out" "coverage"

# ═══════════════════════════════════════════════════════════════════════════════
# halt and resume via CLI
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "halt/resume CLI"

halt_out=$(run_decide halt 2>&1) || true
assert_contains "halt succeeds" "$halt_out" "halted"

# Verify run fails when halted
run_halted=$(run_decide run --once 2>&1) || true
assert_contains "run blocked when halted" "$run_halted" "halted"

resume_out=$(run_decide resume 2>&1) || true
assert_contains "resume succeeds" "$resume_out" "resumed"

# ═══════════════════════════════════════════════════════════════════════════════
# status
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "status"

status_out=$(run_decide status 2>&1) || true
assert_contains "status shows active" "$status_out" "active"
assert_contains "status shows decisions" "$status_out" "Decisions"
assert_contains "status shows budget" "$status_out" "Budget"
assert_contains "status shows weights" "$status_out" "Scoring Weights"

# ═══════════════════════════════════════════════════════════════════════════════
# cycle integration — full cycle with mock signals
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cycle integration"

# Clean state
rm -rf "$HOME/.shipwright/decisions"
rm -rf "$TEST_REPO/.claude/decision-drafts"
mkdir -p "$TEST_REPO/.claude/decision-drafts"
mkdir -p "$HOME/.shipwright/signals"

# Write multiple pending signals of different tiers
cat > "$HOME/.shipwright/signals/pending.jsonl" <<'SIGNALS'
{"id":"int-sec-1","signal":"security","category":"security_patch","title":"Fix CVE-2024-1234","description":"Critical security fix","evidence":{"severity":"high"},"risk_score":30,"confidence":"0.95","dedup_key":"int:sec:1"}
{"id":"int-dep-1","signal":"deps","category":"deps_patch","title":"Update lodash","description":"Patch update","evidence":{"major_versions_behind":0},"risk_score":10,"confidence":"0.90","dedup_key":"int:dep:1"}
{"id":"int-feat-1","signal":"intelligence","category":"new_feature","title":"Add auth module","description":"New feature","evidence":{},"risk_score":80,"confidence":"0.70","dedup_key":"int:feat:1"}
SIGNALS

cycle_out=$(run_decide run --dry-run --once 2>&1) || true
assert_contains "cycle shows Decision Engine" "$cycle_out" "Decision Engine"
assert_contains "cycle shows Cycle Complete" "$cycle_out" "Cycle Complete"
assert_contains "cycle processes candidates" "$cycle_out" "candidate"

# Verify different tiers in output
assert_contains "cycle shows AUTO tier" "$cycle_out" "AUTO"
assert_contains "cycle shows DRAFT tier" "$cycle_out" "DRAFT"

# ═══════════════════════════════════════════════════════════════════════════════
# log command
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "log command"

# Create a decision entry for today
mkdir -p "$HOME/.shipwright/decisions"
daily_log="$HOME/.shipwright/decisions/daily-log-$(date -u +%Y-%m-%d).jsonl"
echo '{"id":"log-cmd-1","title":"Test issue","tier":"auto","action":"issue_created","value_score":55,"outcome":"-","decided_at":"2026-02-22T12:00:00Z"}' > "$daily_log"

log_out=$(run_decide log --days 1 2>&1) || true
assert_contains "log shows today's date" "$log_out" "$(date -u +%Y-%m-%d)"
assert_contains "log shows entry" "$log_out" "Test issue"

print_test_results
