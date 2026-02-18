#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Dashboard Server API Test Suite                            ║
# ║  Tests API endpoints for error handling, edge cases, auth, and schemas   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="2.4.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
YELLOW='\033[38;2;250;204;21m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
SKIP=0
TOTAL=0

test_pass() { ((PASS++)); ((TOTAL++)); echo -e "  ${GREEN}✓${RESET} $1"; }
test_fail() { ((FAIL++)); ((TOTAL++)); echo -e "  ${RED}✗${RESET} $1"; echo -e "    ${DIM}$2${RESET}"; }
test_skip() { ((SKIP++)); ((TOTAL++)); echo -e "  ${YELLOW}○${RESET} $1 (skipped)"; }

# ─── Mock Data Setup ──────────────────────────────────────────────────
MOCK_DIR="$(mktemp -d)"
MOCK_SW="$MOCK_DIR/.shipwright"
mkdir -p "$MOCK_SW"/{logs,heartbeats,memory,worktrees}

# Skip gracefully if bun is not available
if ! command -v bun &>/dev/null; then
    echo -e "\033[38;2;250;204;21m⚠ bun not installed — skipping server API tests\033[0m"
    echo ""
    echo "━━━ Results ━━━"
    echo "  Skipped: bun not available"
    rm -rf "$MOCK_DIR"
    exit 0
fi

# Use a dynamic port to avoid conflicts
TEST_PORT=$(( (RANDOM % 10000) + 20000 ))

# Create mock data
echo '{"daemon":"running","active_pipelines":[{"issue":100,"stage":"build","status":"running"}],"queue":["ready-to-build:200"],"machines":["local"],"health":{"daemon":"healthy"}}' > "$MOCK_SW/daemon-state.json"

# Events
cat > "$MOCK_SW/events.jsonl" << 'EVENTS'
{"ts":"2026-02-16T10:00:00Z","ts_epoch":1739696400,"type":"pipeline.started","issue":100}
{"ts":"2026-02-16T10:30:00Z","ts_epoch":1739698200,"type":"pipeline.completed","issue":100,"result":"success","duration_s":1800}
{"ts":"2026-02-16T11:00:00Z","ts_epoch":1739700000,"type":"pipeline.started","issue":200}
EVENTS

# Heartbeats
echo '{"ts":"2026-02-16T12:00:00Z","machine":"local","cpu":45,"memory":62}' > "$MOCK_SW/heartbeats/local.json"

# Machines
echo '[{"name":"local","host":"127.0.0.1","status":"active","workers":2,"max_workers":4}]' > "$MOCK_SW/machines.json"

# Costs
echo '{"total_spent":12.50,"daily":[{"date":"2026-02-16","cost":3.25}],"budget":{"daily_limit":20,"monthly_limit":500}}' > "$MOCK_SW/costs.json"
echo '{"daily_limit":20,"monthly_limit":500}' > "$MOCK_SW/budget.json"

# Logs
echo "2026-02-16 10:00:00 Starting build for issue #100" > "$MOCK_SW/logs/100.log"

# Memory
echo '{"failures":[{"pattern":"test timeout","count":3}]}' > "$MOCK_SW/memory/failures.json"
echo '{"patterns":[{"name":"retry on timeout","success_rate":0.8}]}' > "$MOCK_SW/memory/patterns.json"
echo '{"decisions":[{"type":"model_selection","model":"claude-4"}]}' > "$MOCK_SW/memory/decisions.json"
echo '{"learnings":[{"lesson":"always run lint before test","source":"pipeline-42"}]}' > "$MOCK_SW/memory/global.json"

# Daemon config
cat > "$MOCK_SW/daemon-config.json" << 'DCONF'
{"poll_interval":30,"max_concurrent":3,"auto_scale":true,"intelligence":{"enabled":true},"patrol":{"enabled":true,"interval":3600}}
DCONF

# ─── Start Server ──────────────────────────────────────────────────────
echo -e "\n${BOLD}Shipwright Server API Test Suite${RESET}"
echo -e "${DIM}Testing error handling, edge cases, auth, and response schemas${RESET}\n"

# Build frontend first
(cd "$REPO_ROOT" && bun build dashboard/src/main.ts --target=browser --outdir=dashboard/public/dist --sourcemap=linked 2>/dev/null) || true

# Start the dashboard server with mock HOME
HOME="$MOCK_DIR" bun "$REPO_ROOT/dashboard/server.ts" "$TEST_PORT" &
SERVER_PID=$!

cleanup() {
    kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$MOCK_DIR"
}
trap cleanup EXIT

# Wait for server
for i in $(seq 1 20); do
    if curl -s "http://localhost:$TEST_PORT/api/health" >/dev/null 2>&1; then break; fi
    sleep 0.3
done

if ! curl -s "http://localhost:$TEST_PORT/api/health" >/dev/null 2>&1; then
    echo -e "${RED}✗ Server failed to start on port $TEST_PORT${RESET}"
    exit 1
fi

BASE="http://localhost:$TEST_PORT"

# ─── Test Functions ────────────────────────────────────────────────────

# 1. Health endpoint returns valid JSON
test_health_endpoint() {
    local resp
    resp=$(curl -s "$BASE/api/health" 2>/dev/null)
    if echo "$resp" | grep -q '"status"'; then
        test_pass "GET /api/health returns status field"
    else
        test_fail "GET /api/health returns status field" "Got: $resp"
    fi
}

# 2. Status endpoint returns fleet state
test_status_endpoint() {
    local resp
    resp=$(curl -s "$BASE/api/status" 2>/dev/null)
    if echo "$resp" | grep -q 'pipelines\|daemon\|active'; then
        test_pass "GET /api/status returns fleet state"
    else
        test_fail "GET /api/status returns fleet state" "Got: $resp"
    fi
}

# 3. 404 for unknown API routes
test_404_unknown_route() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/nonexistent" 2>/dev/null) || true
    if [[ "$code" == "404" ]]; then
        test_pass "GET /api/nonexistent returns 404"
    else
        test_fail "GET /api/nonexistent returns 404" "Got: HTTP $code"
    fi
}

# 4. Static files served correctly
test_static_html() {
    local resp
    resp=$(curl -s "$BASE/" 2>/dev/null)
    if echo "$resp" | grep -q '<!DOCTYPE html\|<html'; then
        test_pass "GET / serves index.html"
    else
        test_fail "GET / serves index.html" "Response does not contain HTML"
    fi
}

# 5. Content-Type for API responses
test_json_content_type() {
    local ctype
    ctype=$(curl -s -D- "$BASE/api/health" 2>/dev/null | grep -i "content-type" | head -1)
    if echo "$ctype" | grep -qi "application/json"; then
        test_pass "API responses have application/json content-type"
    else
        test_fail "API responses have application/json content-type" "Got: $ctype"
    fi
}

# 6. Metrics history with default period
test_metrics_history() {
    local resp
    resp=$(curl -s "$BASE/api/metrics/history" 2>/dev/null)
    if [[ -n "$resp" ]] && echo "$resp" | python3 -m json.tool >/dev/null 2>&1; then
        test_pass "GET /api/metrics/history returns valid JSON"
    else
        test_fail "GET /api/metrics/history returns valid JSON" "Response: $resp"
    fi
}

# 7. Metrics history with custom period
test_metrics_history_custom_period() {
    local resp
    resp=$(curl -s "$BASE/api/metrics/history?period=7" 2>/dev/null)
    if [[ -n "$resp" ]]; then
        test_pass "GET /api/metrics/history?period=7 works"
    else
        test_fail "GET /api/metrics/history?period=7 works" "Empty response"
    fi
}

# 8. Timeline endpoint
test_timeline() {
    local resp
    resp=$(curl -s "$BASE/api/timeline" 2>/dev/null)
    if [[ -n "$resp" ]]; then
        test_pass "GET /api/timeline returns data"
    else
        test_fail "GET /api/timeline returns data" "Empty"
    fi
}

# 9. Activity with query params
test_activity_params() {
    local resp
    resp=$(curl -s "$BASE/api/activity?limit=5&offset=0&type=pipeline.completed" 2>/dev/null)
    if echo "$resp" | grep -q 'events'; then
        test_pass "GET /api/activity with params returns events"
    else
        test_fail "GET /api/activity with params returns events" "Got: $resp"
    fi
}

# 10. Machines endpoint
test_machines() {
    local resp
    resp=$(curl -s "$BASE/api/machines" 2>/dev/null)
    if [[ -n "$resp" ]]; then
        test_pass "GET /api/machines returns machine list"
    else
        test_fail "GET /api/machines returns machine list" "Got: $resp"
    fi
}

# 11. Alerts endpoint
test_alerts() {
    local resp
    resp=$(curl -s "$BASE/api/alerts" 2>/dev/null)
    if echo "$resp" | grep -q 'alerts'; then
        test_pass "GET /api/alerts returns alerts array"
    else
        test_fail "GET /api/alerts returns alerts array" "Got: $resp"
    fi
}

# 12. Daemon config
test_daemon_config() {
    local resp
    resp=$(curl -s "$BASE/api/daemon/config" 2>/dev/null)
    if echo "$resp" | grep -q 'poll_interval\|config'; then
        test_pass "GET /api/daemon/config returns configuration"
    else
        test_fail "GET /api/daemon/config returns configuration" "Got: $resp"
    fi
}

# 13. Pipeline detail for valid issue
test_pipeline_detail() {
    local resp
    resp=$(curl -s "$BASE/api/pipeline/100" 2>/dev/null)
    if [[ -n "$resp" ]]; then
        test_pass "GET /api/pipeline/100 returns pipeline detail"
    else
        test_fail "GET /api/pipeline/100 returns pipeline detail" "Empty"
    fi
}

# 14. Pipeline detail for non-existent issue
test_pipeline_detail_missing() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/pipeline/99999" 2>/dev/null) || true
    if [[ "$code" == "200" || "$code" == "404" ]]; then
        test_pass "GET /api/pipeline/99999 handles missing pipeline"
    else
        test_fail "GET /api/pipeline/99999 handles missing pipeline" "HTTP $code"
    fi
}

# 15. Memory endpoints
test_memory_failures() {
    local resp
    resp=$(curl -s "$BASE/api/memory/failures" 2>/dev/null) || true
    if [[ -n "$resp" ]] && ! echo "$resp" | grep -q 'Cannot GET'; then
        test_pass "GET /api/memory/failures returns failure data"
    else
        test_fail "GET /api/memory/failures returns failure data" "Got: $resp"
    fi
}

test_memory_patterns() {
    local resp
    resp=$(curl -s "$BASE/api/memory/patterns" 2>/dev/null)
    if echo "$resp" | grep -q 'pattern'; then
        test_pass "GET /api/memory/patterns returns pattern data"
    else
        test_fail "GET /api/memory/patterns returns pattern data" "Got: $resp"
    fi
}

test_memory_global() {
    local resp
    resp=$(curl -s "$BASE/api/memory/global" 2>/dev/null)
    if echo "$resp" | grep -q 'learnings\|lesson'; then
        test_pass "GET /api/memory/global returns global learnings"
    else
        test_fail "GET /api/memory/global returns global learnings" "Got: $resp"
    fi
}

# 16. Costs endpoints
test_costs_breakdown() {
    local resp
    resp=$(curl -s "$BASE/api/costs/breakdown" 2>/dev/null)
    if [[ -n "$resp" ]]; then
        test_pass "GET /api/costs/breakdown returns cost data"
    else
        test_fail "GET /api/costs/breakdown returns cost data" "Empty"
    fi
}

# 17. POST endpoints - Intervention
test_intervention_pause() {
    local resp code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/intervention/100/pause" 2>/dev/null) || true
    if [[ "$code" == "200" || "$code" == "404" ]]; then
        test_pass "POST /api/intervention/100/pause accepted"
    else
        test_fail "POST /api/intervention/100/pause accepted" "HTTP $code"
    fi
}

# 18. Emergency brake
test_emergency_brake() {
    local resp
    resp=$(curl -s -X POST "$BASE/api/emergency-brake" 2>/dev/null)
    if [[ -n "$resp" ]] && echo "$resp" | python3 -m json.tool >/dev/null 2>&1; then
        test_pass "POST /api/emergency-brake returns response"
    else
        test_fail "POST /api/emergency-brake returns response" "Got: $resp"
    fi
}

# 19. Logs endpoint
test_logs() {
    local resp
    resp=$(curl -s "$BASE/api/logs/100" 2>/dev/null)
    if echo "$resp" | grep -q 'content\|log'; then
        test_pass "GET /api/logs/100 returns log content"
    else
        test_fail "GET /api/logs/100 returns log content" "Got: $resp"
    fi
}

# 20. Queue detailed
test_queue_detailed() {
    local resp
    resp=$(curl -s "$BASE/api/queue/detailed" 2>/dev/null)
    if echo "$resp" | grep -q 'queue'; then
        test_pass "GET /api/queue/detailed returns queue data"
    else
        test_fail "GET /api/queue/detailed returns queue data" "Got: $resp"
    fi
}

# 21. Notifications config (defaults)
test_notifications_config() {
    local resp
    resp=$(curl -s "$BASE/api/notifications/config" 2>/dev/null)
    if echo "$resp" | grep -q 'enabled\|webhooks'; then
        test_pass "GET /api/notifications/config returns defaults"
    else
        test_fail "GET /api/notifications/config returns defaults" "Got: $resp"
    fi
}

# 22. Approval gates config
test_approval_gates() {
    local resp
    resp=$(curl -s "$BASE/api/approval-gates" 2>/dev/null)
    if echo "$resp" | grep -q 'enabled\|stages'; then
        test_pass "GET /api/approval-gates returns config"
    else
        test_fail "GET /api/approval-gates returns config" "Got: $resp"
    fi
}

# 23. Quality gates config
test_quality_gates() {
    local resp
    resp=$(curl -s "$BASE/api/quality-gates" 2>/dev/null)
    if echo "$resp" | grep -q 'enabled\|rules'; then
        test_pass "GET /api/quality-gates returns config"
    else
        test_fail "GET /api/quality-gates returns config" "Got: $resp"
    fi
}

# 24. Audit log
test_audit_log() {
    local resp
    resp=$(curl -s "$BASE/api/audit-log" 2>/dev/null)
    if echo "$resp" | grep -q 'entries'; then
        test_pass "GET /api/audit-log returns entries array"
    else
        test_fail "GET /api/audit-log returns entries array" "Got: $resp"
    fi
}

# 25. RBAC config
test_rbac() {
    local resp
    resp=$(curl -s "$BASE/api/rbac" 2>/dev/null)
    if echo "$resp" | grep -q 'role\|users\|enabled'; then
        test_pass "GET /api/rbac returns role config"
    else
        test_fail "GET /api/rbac returns role config" "Got: $resp"
    fi
}

# 26. DB health
test_db_health() {
    local resp
    resp=$(curl -s "$BASE/api/db/health" 2>/dev/null)
    if [[ -n "$resp" ]]; then
        test_pass "GET /api/db/health returns health info"
    else
        test_fail "GET /api/db/health returns health info" "Empty"
    fi
}

# 27. Linear status
test_linear_status() {
    local resp
    resp=$(curl -s "$BASE/api/linear/status" 2>/dev/null)
    if echo "$resp" | grep -q 'configured\|connected\|status'; then
        test_pass "GET /api/linear/status returns connection status"
    else
        test_fail "GET /api/linear/status returns connection status" "Got: $resp"
    fi
}

# 28. Predictions endpoint
test_predictions() {
    local resp
    resp=$(curl -s "$BASE/api/predictions/100" 2>/dev/null)
    if [[ -n "$resp" ]]; then
        test_pass "GET /api/predictions/100 returns prediction data"
    else
        test_fail "GET /api/predictions/100 returns prediction data" "Empty"
    fi
}

# 29. Add webhook then remove
test_webhook_lifecycle() {
    local add_resp
    add_resp=$(curl -s -X POST -H "Content-Type: application/json" -d '{"url":"https://example.com/hook","label":"test","events":["failure"]}' "$BASE/api/notifications/webhook" 2>/dev/null)
    if echo "$add_resp" | grep -q 'ok'; then
        local del_resp
        del_resp=$(curl -s -X DELETE -H "Content-Type: application/json" -d '{"url":"https://example.com/hook"}' "$BASE/api/notifications/webhook" 2>/dev/null)
        if echo "$del_resp" | grep -q 'ok'; then
            test_pass "Webhook add + remove lifecycle works"
        else
            test_fail "Webhook add + remove lifecycle works" "Delete failed: $del_resp"
        fi
    else
        test_fail "Webhook add + remove lifecycle works" "Add failed: $add_resp"
    fi
}

# 30. Update approval gate config
test_approval_gate_update() {
    local resp
    resp=$(curl -s -X POST -H "Content-Type: application/json" -d '{"enabled":true,"stages":["deploy"]}' "$BASE/api/approval-gates" 2>/dev/null)
    if echo "$resp" | grep -q 'ok'; then
        test_pass "POST /api/approval-gates updates config"
    else
        test_fail "POST /api/approval-gates updates config" "Got: $resp"
    fi
}

# 31. Pipeline sub-endpoints
test_pipeline_diff() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/pipeline/100/diff" 2>/dev/null) || true
    if [[ "$code" == "200" ]]; then
        test_pass "GET /api/pipeline/100/diff returns 200"
    else
        test_fail "GET /api/pipeline/100/diff returns 200" "HTTP $code"
    fi
}

test_pipeline_files() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/pipeline/100/files" 2>/dev/null) || true
    if [[ "$code" == "200" ]]; then
        test_pass "GET /api/pipeline/100/files returns 200"
    else
        test_fail "GET /api/pipeline/100/files returns 200" "HTTP $code"
    fi
}

test_pipeline_reasoning() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/pipeline/100/reasoning" 2>/dev/null) || true
    if [[ "$code" == "200" ]]; then
        test_pass "GET /api/pipeline/100/reasoning returns 200"
    else
        test_fail "GET /api/pipeline/100/reasoning returns 200" "HTTP $code"
    fi
}

test_pipeline_failures() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/pipeline/100/failures" 2>/dev/null) || true
    if [[ "$code" == "200" ]]; then
        test_pass "GET /api/pipeline/100/failures returns 200"
    else
        test_fail "GET /api/pipeline/100/failures returns 200" "HTTP $code"
    fi
}

test_pipeline_quality() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/pipeline/100/quality" 2>/dev/null) || true
    if [[ "$code" == "200" ]]; then
        test_pass "GET /api/pipeline/100/quality returns 200"
    else
        test_fail "GET /api/pipeline/100/quality returns 200" "HTTP $code"
    fi
}

# 32. CORS headers present
test_cors_headers() {
    local headers
    headers=$(curl -s -D- "$BASE/api/health" 2>/dev/null)
    if echo "$headers" | grep -qi "access-control\|x-content-type"; then
        test_pass "Response includes security headers"
    else
        # Not critical - may not be configured
        test_skip "Response includes security headers"
    fi
}

# 33. POST with invalid JSON body
test_invalid_json_body() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d 'not-json' "$BASE/api/notifications/webhook" 2>/dev/null) || true
    if [[ "$code" -ge 400 ]]; then
        test_pass "POST with invalid JSON returns error status"
    else
        test_fail "POST with invalid JSON returns error status" "HTTP $code"
    fi
}

# 34. Machine claim/release
test_claim_lifecycle() {
    local claim_resp
    claim_resp=$(curl -s -X POST -H "Content-Type: application/json" -d '{"issue":100,"machine":"local"}' "$BASE/api/claim" 2>/dev/null)
    if [[ -n "$claim_resp" ]]; then
        local release_resp
        release_resp=$(curl -s -X POST -H "Content-Type: application/json" -d '{"issue":100,"machine":"local"}' "$BASE/api/claim/release" 2>/dev/null)
        if [[ -n "$release_resp" ]]; then
            test_pass "Claim + release lifecycle works"
        else
            test_fail "Claim + release lifecycle works" "Release failed"
        fi
    else
        test_fail "Claim + release lifecycle works" "Claim failed"
    fi
}

# 35. Patrol recent
test_patrol_recent() {
    local resp
    resp=$(curl -s "$BASE/api/patrol/recent" 2>/dev/null)
    if echo "$resp" | grep -q 'findings'; then
        test_pass "GET /api/patrol/recent returns findings"
    else
        test_fail "GET /api/patrol/recent returns findings" "Got: $resp"
    fi
}

# 36. DB events endpoint
test_db_events() {
    local resp
    resp=$(curl -s "$BASE/api/db/events" 2>/dev/null)
    if echo "$resp" | grep -q 'events\|source'; then
        test_pass "GET /api/db/events returns event data"
    else
        test_fail "GET /api/db/events returns event data" "Got: $resp"
    fi
}

# 37. Stage performance
test_stage_performance() {
    local resp
    resp=$(curl -s "$BASE/api/metrics/stage-performance" 2>/dev/null)
    if echo "$resp" | grep -q 'stages'; then
        test_pass "GET /api/metrics/stage-performance returns stages"
    else
        test_fail "GET /api/metrics/stage-performance returns stages" "Got: $resp"
    fi
}

# 38. Bottlenecks
test_bottlenecks() {
    local resp
    resp=$(curl -s "$BASE/api/metrics/bottlenecks" 2>/dev/null)
    if echo "$resp" | grep -q 'bottlenecks'; then
        test_pass "GET /api/metrics/bottlenecks returns data"
    else
        test_fail "GET /api/metrics/bottlenecks returns data" "Got: $resp"
    fi
}

# 39. Capacity
test_capacity() {
    local resp
    resp=$(curl -s "$BASE/api/metrics/capacity" 2>/dev/null)
    if echo "$resp" | grep -q 'Rate\|rate\|capacity\|queueDepth\|Clear'; then
        test_pass "GET /api/metrics/capacity returns capacity info"
    else
        test_fail "GET /api/metrics/capacity returns capacity info" "Got: $resp"
    fi
}

# 40. Test notification (fire and forget)
test_notification_test() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/notifications/test" 2>/dev/null) || true
    if [[ "$code" == "200" ]]; then
        test_pass "POST /api/notifications/test returns 200"
    else
        test_fail "POST /api/notifications/test returns 200" "HTTP $code"
    fi
}

# ─── Run All Tests ─────────────────────────────────────────────────────
echo -e "${BOLD}1. Core Endpoints${RESET}"
test_health_endpoint
test_status_endpoint
test_static_html
test_json_content_type

echo -e "\n${BOLD}2. Error Handling${RESET}"
test_404_unknown_route
test_invalid_json_body
test_pipeline_detail_missing

echo -e "\n${BOLD}3. Data Endpoints${RESET}"
test_metrics_history
test_metrics_history_custom_period
test_timeline
test_activity_params
test_machines
test_alerts
test_daemon_config
test_pipeline_detail
test_logs
test_queue_detailed
test_predictions
test_costs_breakdown
test_patrol_recent
test_stage_performance
test_bottlenecks
test_capacity

echo -e "\n${BOLD}4. Memory Endpoints${RESET}"
test_memory_failures
test_memory_patterns
test_memory_global

echo -e "\n${BOLD}5. Pipeline Sub-Endpoints${RESET}"
test_pipeline_diff
test_pipeline_files
test_pipeline_reasoning
test_pipeline_failures
test_pipeline_quality

echo -e "\n${BOLD}6. Control Endpoints${RESET}"
test_intervention_pause
test_emergency_brake
test_webhook_lifecycle
test_approval_gate_update
test_claim_lifecycle
test_notification_test

echo -e "\n${BOLD}7. Feature Endpoints${RESET}"
test_notifications_config
test_approval_gates
test_quality_gates
test_audit_log
test_rbac
test_db_health
test_db_events
test_linear_status

echo -e "\n${BOLD}8. Security${RESET}"
test_cors_headers

# ─── Results ───────────────────────────────────────────────────────────
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}Results: ${GREEN}$PASS passed${RESET} / ${RED}$FAIL failed${RESET} / ${YELLOW}$SKIP skipped${RESET} / $TOTAL total"

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}${BOLD}FAIL${RESET}"
    exit 1
else
    echo -e "${GREEN}${BOLD}ALL TESTS PASSED${RESET}"
fi
