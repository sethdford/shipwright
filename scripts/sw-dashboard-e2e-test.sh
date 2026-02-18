#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright dashboard e2e test — full live validation                    ║
# ║  Starts server with mock data, validates all endpoints + WebSocket,     ║
# ║  then cleans up. No external deps required (no daemon/GitHub/Claude).   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DASHBOARD_DIR="$REPO_DIR/dashboard"

# ─── Colors ──────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
SERVER_PID=""
MOCK_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# SETUP: Create isolated mock data directory
# ═══════════════════════════════════════════════════════════════════════════════

setup_mock_data() {
    MOCK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-e2e-mock.XXXXXX")

    local now_epoch
    now_epoch=$(date +%s)
    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local today
    today=$(date -u +"%Y-%m-%d")
    local yesterday
    yesterday=$(date -u -v-1d +"%Y-%m-%d" 2>/dev/null || date -u -d "yesterday" +"%Y-%m-%d" 2>/dev/null || echo "2026-02-15")

    mkdir -p "$MOCK_DIR/heartbeats"
    mkdir -p "$MOCK_DIR/logs"

    # Daemon state with active pipelines and queue
    cat > "$MOCK_DIR/daemon-state.json" << DEOF
{
  "pid": 99999,
  "started_at": "$(date -u -v-2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "2 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "2026-02-16T21:00:00Z")",
  "max_parallel": 4,
  "poll_interval": 30,
  "active_jobs": [
    {"issue": 142, "title": "Add user authentication flow", "stage": "build", "started_at": "$(date -u -v-25M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "2026-02-16T23:00:00Z")", "started_epoch": $((now_epoch - 1500)), "repo": "/tmp/mock-repo", "worktree": "daemon-issue-142"},
    {"issue": 87, "title": "Fix memory leak in worker pool", "stage": "test", "started_at": "$(date -u -v-45M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "2026-02-16T22:40:00Z")", "started_epoch": $((now_epoch - 2700)), "repo": "/tmp/mock-repo", "worktree": "daemon-issue-87"},
    {"issue": 201, "title": "Upgrade dependencies to latest", "stage": "intake", "started_at": "$(date -u -v-5M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "2026-02-16T23:20:00Z")", "started_epoch": $((now_epoch - 300)), "repo": "/tmp/mock-repo", "worktree": "daemon-issue-201"}
  ],
  "queued": [
    {"issue": 55, "title": "Refactor database connection pooling", "score": 82},
    {"issue": 78, "title": "Add dark mode support to settings page", "score": 67},
    {"issue": 103, "title": "Implement webhook retry logic", "score": 54}
  ]
}
DEOF

    # Events with stage completions, pipeline completions, scale events
    cat > "$MOCK_DIR/events.jsonl" << 'EEOF'
EEOF

    # Generate realistic events
    for i in $(seq 1 8); do
        local offset=$((i * 3600 + RANDOM % 3600))
        local ev_epoch=$((now_epoch - offset))
        local ev_iso
        ev_iso=$(date -u -r "$ev_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$now_iso")
        local issue=$((100 + RANDOM % 200))
        local stages=("intake" "plan" "design" "build" "test" "review" "merge")
        local stage="${stages[$((RANDOM % ${#stages[@]}))]}"
        local dur=$((60 + RANDOM % 600))
        echo "{\"type\":\"stage.completed\",\"ts\":\"$ev_iso\",\"ts_epoch\":$ev_epoch,\"issue\":$issue,\"stage\":\"$stage\",\"duration_s\":$dur}" >> "$MOCK_DIR/events.jsonl"
    done

    # Pipeline completions (successes and failures)
    for i in $(seq 1 5); do
        local offset=$((i * 7200 + RANDOM % 7200))
        local ev_epoch=$((now_epoch - offset))
        local ev_iso
        ev_iso=$(date -u -r "$ev_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$now_iso")
        local issue=$((100 + RANDOM % 200))
        local dur=$((300 + RANDOM % 3600))
        local result="success"
        if [[ $i -eq 3 ]]; then result="failure"; fi
        echo "{\"type\":\"pipeline.completed\",\"ts\":\"$ev_iso\",\"ts_epoch\":$ev_epoch,\"issue\":$issue,\"result\":\"$result\",\"duration_s\":$dur}" >> "$MOCK_DIR/events.jsonl"
    done

    # Stage started events for active pipelines
    echo "{\"type\":\"stage.started\",\"ts\":\"$now_iso\",\"ts_epoch\":$now_epoch,\"issue\":142,\"stage\":\"build\"}" >> "$MOCK_DIR/events.jsonl"
    echo "{\"type\":\"stage.started\",\"ts\":\"$now_iso\",\"ts_epoch\":$now_epoch,\"issue\":87,\"stage\":\"test\"}" >> "$MOCK_DIR/events.jsonl"
    echo "{\"type\":\"stage.started\",\"ts\":\"$now_iso\",\"ts_epoch\":$now_epoch,\"issue\":201,\"stage\":\"intake\"}" >> "$MOCK_DIR/events.jsonl"

    # Completed stages for active issues
    echo "{\"type\":\"stage.completed\",\"ts\":\"$now_iso\",\"ts_epoch\":$((now_epoch - 900)),\"issue\":142,\"stage\":\"intake\",\"duration_s\":120}" >> "$MOCK_DIR/events.jsonl"
    echo "{\"type\":\"stage.completed\",\"ts\":\"$now_iso\",\"ts_epoch\":$((now_epoch - 600)),\"issue\":142,\"stage\":\"plan\",\"duration_s\":180}" >> "$MOCK_DIR/events.jsonl"
    echo "{\"type\":\"stage.completed\",\"ts\":\"$now_iso\",\"ts_epoch\":$((now_epoch - 300)),\"issue\":142,\"stage\":\"design\",\"duration_s\":240}" >> "$MOCK_DIR/events.jsonl"

    echo "{\"type\":\"stage.completed\",\"ts\":\"$now_iso\",\"ts_epoch\":$((now_epoch - 1800)),\"issue\":87,\"stage\":\"intake\",\"duration_s\":90}" >> "$MOCK_DIR/events.jsonl"
    echo "{\"type\":\"stage.completed\",\"ts\":\"$now_iso\",\"ts_epoch\":$((now_epoch - 1200)),\"issue\":87,\"stage\":\"plan\",\"duration_s\":150}" >> "$MOCK_DIR/events.jsonl"
    echo "{\"type\":\"stage.completed\",\"ts\":\"$now_iso\",\"ts_epoch\":$((now_epoch - 900)),\"issue\":87,\"stage\":\"design\",\"duration_s\":210}" >> "$MOCK_DIR/events.jsonl"
    echo "{\"type\":\"stage.completed\",\"ts\":\"$now_iso\",\"ts_epoch\":$((now_epoch - 600)),\"issue\":87,\"stage\":\"build\",\"duration_s\":300}" >> "$MOCK_DIR/events.jsonl"

    # Scale event
    echo "{\"type\":\"daemon.scale\",\"ts\":\"$now_iso\",\"ts_epoch\":$now_epoch,\"from\":2,\"to\":4,\"max_by_cpu\":8,\"max_by_mem\":6,\"max_by_budget\":10,\"cpu_cores\":16,\"avail_mem_gb\":32}" >> "$MOCK_DIR/events.jsonl"

    # Stage failure events for heatmap
    echo "{\"type\":\"stage.failed\",\"ts\":\"$now_iso\",\"ts_epoch\":$now_epoch,\"issue\":99,\"stage\":\"test\"}" >> "$MOCK_DIR/events.jsonl"
    echo "{\"type\":\"stage.failed\",\"ts\":\"${yesterday}T10:00:00Z\",\"ts_epoch\":$((now_epoch - 86400)),\"issue\":88,\"stage\":\"build\"}" >> "$MOCK_DIR/events.jsonl"
    echo "{\"type\":\"stage.failed\",\"ts\":\"${yesterday}T14:00:00Z\",\"ts_epoch\":$((now_epoch - 72000)),\"issue\":77,\"stage\":\"test\"}" >> "$MOCK_DIR/events.jsonl"

    # Agent heartbeats
    cat > "$MOCK_DIR/heartbeats/agent-142.json" << HEOF
{"issue": 142, "stage": "build", "iteration": 2, "last_activity": "Writing implementation code", "memory_mb": 512, "cpu_pct": 45, "updated_at": "$now_iso", "machine": "localhost"}
HEOF
    cat > "$MOCK_DIR/heartbeats/agent-87.json" << HEOF
{"issue": 87, "stage": "test", "iteration": 3, "last_activity": "Running test suite", "memory_mb": 384, "cpu_pct": 30, "updated_at": "$now_iso", "machine": "localhost"}
HEOF
    cat > "$MOCK_DIR/heartbeats/agent-201.json" << HEOF
{"issue": 201, "stage": "intake", "iteration": 1, "last_activity": "Analyzing issue requirements", "memory_mb": 256, "cpu_pct": 15, "updated_at": "$now_iso", "machine": "dev-server-01"}
HEOF

    # Machines
    cat > "$MOCK_DIR/machines.json" << MEOF
{
  "machines": [
    {"name": "localhost", "host": "127.0.0.1", "role": "primary", "max_workers": 4, "registered_at": "$now_iso"},
    {"name": "dev-server-01", "host": "10.0.1.50", "role": "worker", "max_workers": 8, "registered_at": "$now_iso"}
  ]
}
MEOF

    # Costs
    cat > "$MOCK_DIR/costs.json" << CEOF
{
  "entries": [
    {"ts_epoch": $now_epoch, "cost_usd": 0.42, "model": "claude-4-sonnet", "issue": 142},
    {"ts_epoch": $((now_epoch - 300)), "cost_usd": 0.31, "model": "claude-4-sonnet", "issue": 87},
    {"ts_epoch": $((now_epoch - 600)), "cost_usd": 0.15, "model": "claude-4-haiku", "issue": 201},
    {"ts_epoch": $((now_epoch - 86400)), "cost_usd": 1.20, "model": "claude-4-sonnet", "issue": 99}
  ]
}
CEOF

    # Budget
    cat > "$MOCK_DIR/budget.json" << BEOF
{"daily_budget_usd": 25, "enabled": true}
BEOF

    # Log files for SSE streaming
    echo "[$(date)] Starting build for issue #142..." > "$MOCK_DIR/logs/issue-142.log"
    echo "[$(date)] Running npm install..." >> "$MOCK_DIR/logs/issue-142.log"
    echo "[$(date)] Building project..." >> "$MOCK_DIR/logs/issue-142.log"
    echo "[$(date)] Compilation successful, 0 errors." >> "$MOCK_DIR/logs/issue-142.log"

    echo "[$(date)] Starting tests for issue #87..." > "$MOCK_DIR/logs/issue-87.log"
    echo "[$(date)] Running test suite..." >> "$MOCK_DIR/logs/issue-87.log"
    echo "[$(date)] 42 tests passed, 1 failing." >> "$MOCK_DIR/logs/issue-87.log"

    echo -e "${DIM}Mock data written to $MOCK_DIR${RESET}"
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
# START SERVER WITH MOCK DATA
# ═══════════════════════════════════════════════════════════════════════════════

start_server() {
    if ! command -v bun &>/dev/null; then
        echo -e "\033[38;2;250;204;21m⚠ bun not installed — skipping dashboard e2e tests\033[0m"
        echo ""
        echo "━━━ Results ━━━"
        echo "  Skipped: bun not available"
        exit 0
    fi

    # Build frontend first
    bun build "$DASHBOARD_DIR/src/main.ts" --target=browser --outdir="$DASHBOARD_DIR/public/dist" --sourcemap=linked &>/dev/null

    # Copy mock data into the expected .shipwright directory under the mock HOME
    mkdir -p "$MOCK_DIR/.shipwright/heartbeats"
    mkdir -p "$MOCK_DIR/.shipwright/logs"
    cp "$MOCK_DIR/daemon-state.json" "$MOCK_DIR/.shipwright/daemon-state.json"
    cp "$MOCK_DIR/events.jsonl" "$MOCK_DIR/.shipwright/events.jsonl"
    cp "$MOCK_DIR/machines.json" "$MOCK_DIR/.shipwright/machines.json"
    cp "$MOCK_DIR/costs.json" "$MOCK_DIR/.shipwright/costs.json"
    cp "$MOCK_DIR/budget.json" "$MOCK_DIR/.shipwright/budget.json"
    cp "$MOCK_DIR/heartbeats/"*.json "$MOCK_DIR/.shipwright/heartbeats/" 2>/dev/null || true
    cp "$MOCK_DIR/logs/"*.log "$MOCK_DIR/.shipwright/logs/" 2>/dev/null || true

    # Pick a port: use 18767 for e2e to avoid clashing with a real dashboard
    local test_port="${SHIPWRIGHT_E2E_PORT:-18767}"

    # Kill anything on that port
    lsof -nP -iTCP:"$test_port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $2}' | xargs kill 2>/dev/null || true
    sleep 0.5

    # Start server with HOME pointing to mock data, using the test port
    HOME="$MOCK_DIR" SHIPWRIGHT_DASHBOARD_PORT="$test_port" bun "$DASHBOARD_DIR/server.ts" &>/dev/null &
    SERVER_PID=$!

    # Wait for server to be ready
    local retries=0
    while ! curl -sf "http://localhost:${test_port}/api/health" &>/dev/null; do
        retries=$((retries + 1))
        if [[ $retries -gt 20 ]]; then
            echo -e "${RED}Server failed to start after 10s${RESET}"
            kill "$SERVER_PID" 2>/dev/null || true
            exit 1
        fi
        sleep 0.5
    done

    BASE_URL="http://localhost:${test_port}"
    WS_URL="ws://localhost:${test_port}/ws"
    echo -e "${DIM}Server running on ${BASE_URL} (PID: $SERVER_PID)${RESET}"
}

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [[ -n "$MOCK_DIR" ]]; then
        rm -rf "$MOCK_DIR"
    fi
    # Restore HOME
    export HOME="$ORIGINAL_HOME"
}

ORIGINAL_HOME="$HOME"
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: API Endpoints
# ═══════════════════════════════════════════════════════════════════════════════

test_health() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/health" 2>/dev/null)
    echo "$resp" | grep -q '"status":"ok"'
}

test_status_shape() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/status" 2>/dev/null)
    echo "$resp" | grep -q '"daemon"' &&
    echo "$resp" | grep -q '"pipelines"' &&
    echo "$resp" | grep -q '"agents"' &&
    echo "$resp" | grep -q '"machines"' &&
    echo "$resp" | grep -q '"cost"' &&
    echo "$resp" | grep -q '"dora"'
}

test_status_has_active_pipelines() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/status" 2>/dev/null)
    echo "$resp" | grep -q '"issue":142'
}

test_status_daemon_running() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/status" 2>/dev/null)
    echo "$resp" | grep -q '"running":true'
}

test_status_has_agents() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/status" 2>/dev/null)
    echo "$resp" | grep -q '"heartbeat_age_s"'
}

test_status_has_cost() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/status" 2>/dev/null)
    echo "$resp" | grep -q '"today_spent"' &&
    echo "$resp" | grep -q '"daily_budget"'
}

test_status_has_queue() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/status" 2>/dev/null)
    echo "$resp" | grep -q '"issue":55'
}

test_me_endpoint() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/me" 2>/dev/null)
    echo "$resp" | grep -q '"username":"local"'
}

test_metrics_history() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/metrics/history" 2>/dev/null)
    echo "$resp" | grep -q '"success_rate"' &&
    echo "$resp" | grep -q '"stage_durations"' &&
    echo "$resp" | grep -q '"dora_grades"'
}

test_timeline() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/timeline?range=24" 2>/dev/null)
    # Should return an array
    [[ "$resp" =~ ^\[ ]]
}

test_activity() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/activity" 2>/dev/null)
    echo "$resp" | grep -q '"events"'
}

test_machines() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/machines" 2>/dev/null)
    echo "$resp" | grep -q '"localhost"' &&
    echo "$resp" | grep -q '"dev-server-01"'
}

test_alerts() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/alerts" 2>/dev/null)
    echo "$resp" | grep -q '"alerts"'
}

test_daemon_config() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/daemon/config" 2>/dev/null)
    # Should return JSON (may be empty config)
    [[ "$resp" =~ ^\{ ]]
}

test_heatmap() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/metrics/failure-heatmap" 2>/dev/null)
    echo "$resp" | grep -q '"heatmap"'
}

test_bottlenecks() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/metrics/bottlenecks" 2>/dev/null)
    echo "$resp" | grep -q '"bottlenecks"'
}

test_stage_performance() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/metrics/stage-performance" 2>/dev/null)
    echo "$resp" | grep -q '"stages"'
}

test_predictions() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/predictions/142" 2>/dev/null)
    echo "$resp" | grep -q '"eta_s"'
}

test_logs() {
    local resp
    resp=$(curl -sf "$BASE_URL/api/logs/142" 2>/dev/null)
    echo "$resp" | grep -q '"content"'
}

# WebSocket test
test_websocket() {
    if ! command -v bun &>/dev/null; then return 0; fi
    local result
    result=$(bun -e "
const ws = new WebSocket('$WS_URL');
let ok = false;
ws.onopen = () => { ok = true; };
ws.onmessage = (e) => {
  const d = JSON.parse(e.data);
  if (d.daemon && d.pipelines) {
    console.log('WS_OK');
    ws.close();
    process.exit(0);
  }
};
ws.onerror = () => process.exit(1);
setTimeout(() => process.exit(ok ? 0 : 1), 4000);
" 2>/dev/null)
    echo "$result" | grep -q "WS_OK"
}

test_index_html_loads() {
    local resp
    resp=$(curl -sf "$BASE_URL/" 2>/dev/null)
    echo "$resp" | grep -q "Fleet Command" &&
    echo "$resp" | grep -q 'dist/main.js'
}

test_bundle_loads() {
    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE_URL/dist/main.js" 2>/dev/null)
    [[ "$status" == "200" ]]
}

# ─── New endpoint tests (Phase 3-5) ───────────────────────────────────────

test_linear_status() {
    local body
    body=$(curl -sf "$BASE_URL/api/linear/status" 2>/dev/null)
    echo "$body" | grep -q '"' 2>/dev/null
}

test_queue_detailed() {
    local body
    body=$(curl -sf "$BASE_URL/api/queue/detailed" 2>/dev/null)
    echo "$body" | grep -q 'queue' 2>/dev/null
}

test_memory_global() {
    local body
    body=$(curl -sf "$BASE_URL/api/memory/global" 2>/dev/null)
    echo "$body" | grep -q 'learnings' 2>/dev/null
}

test_notification_config() {
    local body
    body=$(curl -sf "$BASE_URL/api/notifications/config" 2>/dev/null)
    echo "$body" | grep -q 'enabled' 2>/dev/null
}

test_approval_gates() {
    local body
    body=$(curl -sf "$BASE_URL/api/approval-gates" 2>/dev/null)
    echo "$body" | grep -q 'enabled' 2>/dev/null
}

test_quality_gates() {
    local body
    body=$(curl -sf "$BASE_URL/api/quality-gates" 2>/dev/null)
    echo "$body" | grep -q 'rules' 2>/dev/null
}

test_pipeline_diff() {
    local body
    body=$(curl -sf "$BASE_URL/api/pipeline/142/diff" 2>/dev/null)
    echo "$body" | grep -q 'diff' 2>/dev/null
}

test_pipeline_files() {
    local body
    body=$(curl -sf "$BASE_URL/api/pipeline/142/files" 2>/dev/null)
    echo "$body" | grep -q 'files' 2>/dev/null
}

test_pipeline_reasoning() {
    local body
    body=$(curl -sf "$BASE_URL/api/pipeline/142/reasoning" 2>/dev/null)
    echo "$body" | grep -q 'reasoning' 2>/dev/null
}

test_pipeline_failures() {
    local body
    body=$(curl -sf "$BASE_URL/api/pipeline/142/failures" 2>/dev/null)
    echo "$body" | grep -q 'failures' 2>/dev/null
}

test_pipeline_quality() {
    local body
    body=$(curl -sf "$BASE_URL/api/pipeline/142/quality" 2>/dev/null)
    echo "$body" | grep -q 'quality' 2>/dev/null
}

test_audit_log() {
    local body
    body=$(curl -sf "$BASE_URL/api/audit-log" 2>/dev/null)
    echo "$body" | grep -q 'entries' 2>/dev/null
}

test_rbac() {
    local body
    body=$(curl -sf "$BASE_URL/api/rbac" 2>/dev/null)
    echo "$body" | grep -q 'default_role' 2>/dev/null
}

test_db_health() {
    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE_URL/api/db/health" 2>/dev/null)
    [[ "$status" == "200" ]]
}

test_db_events() {
    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE_URL/api/db/events" 2>/dev/null)
    [[ "$status" == "200" ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${PURPLE}${BOLD}Dashboard E2E Tests${RESET}"
echo ""

echo -e "${DIM}Setting up mock data...${RESET}"
setup_mock_data

echo -e "${DIM}Starting dashboard server...${RESET}"
start_server
echo ""

echo -e "${PURPLE}${BOLD}Page Loading${RESET}"
run_test "index.html serves Fleet Command page" test_index_html_loads
run_test "JavaScript bundle loads (dist/main.js)" test_bundle_loads
echo ""

echo -e "${PURPLE}${BOLD}API Endpoints${RESET}"
run_test "GET /api/health returns ok" test_health
run_test "GET /api/status returns full FleetState shape" test_status_shape
run_test "FleetState has active pipelines (issue 142)" test_status_has_active_pipelines
run_test "FleetState daemon shows running" test_status_daemon_running
run_test "FleetState has agent heartbeats" test_status_has_agents
run_test "FleetState has cost data (today_spent, daily_budget)" test_status_has_cost
run_test "FleetState has queued items" test_status_has_queue
run_test "GET /api/me returns user info" test_me_endpoint
run_test "GET /api/metrics/history returns metrics + dora_grades" test_metrics_history
run_test "GET /api/timeline returns array" test_timeline
run_test "GET /api/activity returns events" test_activity
run_test "GET /api/machines returns registered machines" test_machines
run_test "GET /api/alerts returns alerts array" test_alerts
run_test "GET /api/daemon/config returns JSON" test_daemon_config
run_test "GET /api/metrics/failure-heatmap returns heatmap" test_heatmap
run_test "GET /api/metrics/bottlenecks returns bottlenecks" test_bottlenecks
run_test "GET /api/metrics/stage-performance returns stages" test_stage_performance
run_test "GET /api/predictions/142 returns ETA" test_predictions
run_test "GET /api/logs/142 returns log content" test_logs
echo ""

echo -e "${PURPLE}${BOLD}New Endpoints (Phase 3-5)${RESET}"
run_test "GET /api/linear/status returns JSON" test_linear_status
run_test "GET /api/queue/detailed returns items" test_queue_detailed
run_test "GET /api/memory/global returns learnings" test_memory_global
run_test "GET /api/notifications/config returns config" test_notification_config
run_test "GET /api/approval-gates returns config" test_approval_gates
run_test "GET /api/quality-gates returns rules" test_quality_gates
run_test "GET /api/pipeline/142/diff returns diff" test_pipeline_diff
run_test "GET /api/pipeline/142/files returns files" test_pipeline_files
run_test "GET /api/pipeline/142/reasoning returns reasoning" test_pipeline_reasoning
run_test "GET /api/pipeline/142/failures returns failures" test_pipeline_failures
run_test "GET /api/pipeline/142/quality returns quality" test_pipeline_quality
run_test "GET /api/audit-log returns entries" test_audit_log
run_test "GET /api/rbac returns config" test_rbac
run_test "GET /api/db/health returns status" test_db_health
run_test "GET /api/db/events returns status" test_db_events
echo ""

echo -e "${PURPLE}${BOLD}WebSocket${RESET}"
run_test "WebSocket connects and receives FleetState" test_websocket
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
