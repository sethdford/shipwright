#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright db — SQLite Persistence Layer Test Suite                     ║
# ║  Validate schema creation, CRUD operations, daemon state, costs,          ║
# ║  heartbeats, memory, migration, health checks, and concurrent writes.     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches shipwright theme) ──────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
BLUE='\033[38;2;0;102;255m'
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-db-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/heartbeats"
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/project"

    # Copy sw-db.sh under test
    cp "$SCRIPT_DIR/sw-db.sh" "$TEMP_DIR/"

    # Set up mock environment
    export HOME="$TEMP_DIR/home"
    export DB_DIR="$TEMP_DIR/home/.shipwright"
    export DB_FILE="$DB_DIR/shipwright.db"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

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
# HELPER: Source db.sh in test context
# ═══════════════════════════════════════════════════════════════════════════════

source_db() {
    # Reset the double-source guard so we can re-source
    _SW_DB_LOADED=""
    source "$TEMP_DIR/sw-db.sh"
}

# Clean all data from tables (but keep schema) for test isolation
reset_db_data() {
    if [[ -f "$DB_FILE" ]]; then
        sqlite3 "$DB_FILE" "DELETE FROM daemon_state; DELETE FROM cost_entries; DELETE FROM budgets; DELETE FROM heartbeats; DELETE FROM memory_failures; DELETE FROM events; DELETE FROM pipeline_runs; DELETE FROM pipeline_stages;" 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# SCHEMA TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. init_schema creates all tables
# ──────────────────────────────────────────────────────────────────────────────
test_schema_creation() {
    source_db
    init_schema

    if [[ ! -f "$DB_FILE" ]]; then
        echo -e "    ${RED}✗${RESET} Database file not created"
        return 1
    fi

    # Check that key tables exist
    local tables
    tables=$(sqlite3 "$DB_FILE" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    if [[ "$tables" -lt 10 ]]; then
        echo -e "    ${RED}✗${RESET} Expected at least 10 tables, got $tables"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Schema includes all required tables
# ──────────────────────────────────────────────────────────────────────────────
test_schema_tables() {
    source_db
    init_schema

    local required_tables=(
        "events" "pipeline_runs" "pipeline_stages" "developers"
        "sessions" "metrics" "daemon_state" "cost_entries"
        "budgets" "heartbeats" "memory_failures"
    )

    for tbl in "${required_tables[@]}"; do
        local exists
        exists=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$tbl';" 2>/dev/null || echo 0)
        if [[ "$exists" -ne 1 ]]; then
            echo -e "    ${RED}✗${RESET} Table '$tbl' not found"
            return 1
        fi
    done

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. WAL mode is enabled
# ──────────────────────────────────────────────────────────────────────────────
test_wal_mode() {
    source_db
    init_schema

    local journal_mode
    journal_mode=$(sqlite3 "$DB_FILE" "PRAGMA journal_mode;" 2>/dev/null || echo "unknown")
    if [[ "$journal_mode" != "wal" ]]; then
        echo -e "    ${RED}✗${RESET} Expected WAL mode, got: $journal_mode"
        return 1
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. check_sqlite3 caches result
# ──────────────────────────────────────────────────────────────────────────────
test_check_sqlite3_caching() {
    source_db

    # First call should cache
    check_sqlite3
    local first_checked="$_SQLITE3_CHECKED"

    # Second call should use cache
    check_sqlite3
    local second_checked="$_SQLITE3_CHECKED"

    if [[ "$first_checked" != "1" || "$second_checked" != "1" ]]; then
        echo -e "    ${RED}✗${RESET} Caching not working"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# DATABASE AVAILABILITY TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 5. db_available returns true when ready
# ──────────────────────────────────────────────────────────────────────────────
test_db_available() {
    source_db
    init_schema

    if ! db_available; then
        echo -e "    ${RED}✗${RESET} db_available returned false when DB ready"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. db_available returns false when sqlite3 missing
# ──────────────────────────────────────────────────────────────────────────────
test_db_available_fallback() {
    # Create an empty directory to use as PATH (no sqlite3)
    local empty_bin="$TEMP_DIR/empty_bin"
    mkdir -p "$empty_bin"

    local old_path="$PATH"
    export PATH="$empty_bin"
    # Reset the sqlite3 check cache
    _SQLITE3_CHECKED=""
    _SQLITE3_AVAILABLE=""

    source_db

    local result=0
    if db_available; then
        result=1  # Should have failed — no sqlite3 on PATH
    fi

    export PATH="$old_path"
    _SQLITE3_CHECKED=""
    _SQLITE3_AVAILABLE=""
    return $result
}

# ═══════════════════════════════════════════════════════════════════════════════
# EVENT CRUD TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 7. db_add_event inserts event
# ──────────────────────────────────────────────────────────────────────────────
test_add_event() {
    source_db
    init_schema

    db_add_event "test_event" "job_id=test-1" "stage=build" "status=running"

    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM events WHERE type='test_event' AND job_id='test-1';" 2>/dev/null || echo 0)
    if [[ "$count" -ne 1 ]]; then
        echo -e "    ${RED}✗${RESET} Event not inserted (count=$count)"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. add_event dual-writes to SQLite and JSONL
# ──────────────────────────────────────────────────────────────────────────────
test_add_event_dual_write() {
    source_db
    init_schema

    add_event "legacy_event" "job-123" "test" "passed"

    # Check SQLite
    local db_count
    db_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM events WHERE job_id='job-123';" 2>/dev/null || echo 0)

    # Check JSONL
    local jsonl_count=0
    [[ -f "$EVENTS_FILE" ]] && jsonl_count=$(grep -c "job-123" "$EVENTS_FILE" || echo 0)

    if [[ "$db_count" -ne 1 || "$jsonl_count" -ne 1 ]]; then
        echo -e "    ${RED}✗${RESET} Dual-write failed (db=$db_count, jsonl=$jsonl_count)"
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# DAEMON STATE TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 9. db_save_job saves active job
# ──────────────────────────────────────────────────────────────────────────────
test_save_job() {
    source_db
    init_schema

    db_save_job "job-1" 42 "Fix auth bug" 1234 "/tmp/wt1" "feat/auth" "standard" "Add OAuth support"

    local job_id
    job_id=$(sqlite3 "$DB_FILE" "SELECT job_id FROM daemon_state WHERE issue_number=42 AND status='active';" 2>/dev/null || echo "")
    if [[ "$job_id" != "job-1" ]]; then
        echo -e "    ${RED}✗${RESET} Job not saved correctly"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. db_complete_job marks job as completed
# ──────────────────────────────────────────────────────────────────────────────
test_complete_job() {
    source_db
    init_schema

    db_save_job "job-2" 43 "Test" 0 "" "" "standard"
    db_complete_job "job-2" "success" "120" ""

    local status
    status=$(sqlite3 "$DB_FILE" "SELECT status FROM daemon_state WHERE job_id='job-2';" 2>/dev/null || echo "")
    if [[ "$status" != "completed" ]]; then
        echo -e "    ${RED}✗${RESET} Job not marked as completed (status=$status)"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. db_fail_job marks job as failed
# ──────────────────────────────────────────────────────────────────────────────
test_fail_job() {
    source_db
    init_schema

    db_save_job "job-3" 44 "Test" 0 "" "" "standard"
    db_fail_job "job-3" "Build failed"

    local status
    status=$(sqlite3 "$DB_FILE" "SELECT status FROM daemon_state WHERE job_id='job-3';" 2>/dev/null || echo "")
    if [[ "$status" != "failed" ]]; then
        echo -e "    ${RED}✗${RESET} Job not marked as failed (status=$status)"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. db_list_active_jobs returns JSON array
# ──────────────────────────────────────────────────────────────────────────────
test_list_active_jobs() {
    source_db
    init_schema
    reset_db_data

    db_save_job "active-1" 50 "Job1" 0 "" "" "standard"
    db_save_job "active-2" 51 "Job2" 0 "" "" "standard"
    db_complete_job "active-1" "success"

    local output
    output=$(db_list_active_jobs)

    # Should return JSON with only 1 active job
    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$count" -ne 1 ]]; then
        echo -e "    ${RED}✗${RESET} Expected 1 active job, got $count"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. db_active_job_count returns correct count
# ──────────────────────────────────────────────────────────────────────────────
test_active_job_count() {
    source_db
    init_schema
    reset_db_data

    db_save_job "count-1" 60 "Test" 0 "" "" "standard"
    db_save_job "count-2" 61 "Test" 0 "" "" "standard"

    local count
    count=$(db_active_job_count)
    if [[ "$count" != "2" ]]; then
        echo -e "    ${RED}✗${RESET} Expected count 2, got $count"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. db_is_issue_active returns correct status
# ──────────────────────────────────────────────────────────────────────────────
test_is_issue_active() {
    source_db
    init_schema

    db_save_job "issue-check" 70 "Test" 0 "" "" "standard"

    if ! db_is_issue_active 70; then
        echo -e "    ${RED}✗${RESET} Issue 70 should be active"
        return 1
    fi

    if db_is_issue_active 9999; then
        echo -e "    ${RED}✗${RESET} Issue 9999 should not be active"
        return 1
    fi

    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# COST TRACKING TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 15. db_record_cost saves cost entry
# ──────────────────────────────────────────────────────────────────────────────
test_record_cost() {
    source_db
    init_schema

    db_record_cost 1000 500 "sonnet" "0.15" "build" "100"

    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM cost_entries WHERE stage='build';" 2>/dev/null || echo 0)
    if [[ "$count" -ne 1 ]]; then
        echo -e "    ${RED}✗${RESET} Cost entry not recorded"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. db_cost_today calculates daily total
# ──────────────────────────────────────────────────────────────────────────────
test_cost_today() {
    source_db
    init_schema
    reset_db_data

    db_record_cost 1000 500 "sonnet" "0.10" "build"
    db_record_cost 2000 1000 "opus" "0.20" "review"

    local total
    total=$(db_cost_today)
    # Should be approximately 0.30 (0.10 + 0.20)
    if ! echo "$total" | grep -qE '^0\.2[89]|^0\.3'; then
        echo -e "    ${RED}✗${RESET} Cost total wrong (got $total)"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. db_set_budget and db_get_budget
# ──────────────────────────────────────────────────────────────────────────────
test_budget() {
    source_db
    init_schema
    reset_db_data

    db_set_budget "10.00"
    local budget
    budget=$(db_get_budget)

    # SQLite may format as 10.0 or 10.00 — match either
    if ! echo "$budget" | grep -qE "10\.0"; then
        echo -e "    ${RED}✗${RESET} Budget not set correctly (got $budget)"
        return 1
    fi

    return 0
}

# ════════════════════════════════════════════════════════════════════════════════
# HEARTBEAT TESTS
# ═════════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 18. db_record_heartbeat saves heartbeat
# ──────────────────────────────────────────────────────────────────────────────
test_record_heartbeat() {
    source_db
    init_schema

    db_record_heartbeat "hb-job-1" 1234 42 "build" 3 "Running tests" 256

    local job_id
    job_id=$(sqlite3 "$DB_FILE" "SELECT job_id FROM heartbeats WHERE job_id='hb-job-1';" 2>/dev/null || echo "")
    if [[ "$job_id" != "hb-job-1" ]]; then
        echo -e "    ${RED}✗${RESET} Heartbeat not recorded"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 19. db_list_heartbeats returns JSON array
# ──────────────────────────────────────────────────────────────────────────────
test_list_heartbeats() {
    source_db
    init_schema
    reset_db_data

    db_record_heartbeat "hb-1" 1000 10 "build" 1
    db_record_heartbeat "hb-2" 2000 20 "test" 2

    local output
    output=$(db_list_heartbeats)

    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$count" -ne 2 ]]; then
        echo -e "    ${RED}✗${RESET} Expected 2 heartbeats, got $count"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 20. db_clear_heartbeat deletes heartbeat
# ──────────────────────────────────────────────────────────────────────────────
test_clear_heartbeat() {
    source_db
    init_schema

    db_record_heartbeat "hb-clear" 1000 10 "build" 1
    db_clear_heartbeat "hb-clear"

    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM heartbeats WHERE job_id='hb-clear';" 2>/dev/null || echo 0)
    if [[ "$count" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Heartbeat not cleared"
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# MEMORY / FAILURE TESTS
# ═════════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 21. db_record_failure saves failure pattern
# ──────────────────────────────────────────────────────────────────────────────
test_record_failure() {
    source_db
    init_schema

    db_record_failure "repo-abc123" "auth_error" "unauthorized 401" "JWT expired" "Refresh token" "auth.go" "build"

    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM memory_failures WHERE failure_class='auth_error';" 2>/dev/null || echo 0)
    if [[ "$count" -ne 1 ]]; then
        echo -e "    ${RED}✗${RESET} Failure not recorded"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 22. db_query_similar_failures returns matching failures
# ──────────────────────────────────────────────────────────────────────────────
test_query_similar_failures() {
    source_db
    init_schema
    reset_db_data

    db_record_failure "repo-abc123" "auth_error" "sig1" "cause1" "fix1"
    db_record_failure "repo-abc123" "api_error" "sig2" "cause2" "fix2"

    local output
    output=$(db_query_similar_failures "repo-abc123" "auth_error")

    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$count" -ne 1 ]]; then
        echo -e "    ${RED}✗${RESET} Expected 1 auth_error, got $count"
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# MIGRATION TESTS
# ═════════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 23. migrate_json_data imports events.jsonl
# ──────────────────────────────────────────────────────────────────────────────
test_migrate_events() {
    source_db

    # Create sample events.jsonl
    mkdir -p "$DB_DIR"
    cat > "$EVENTS_FILE" <<'EOF'
{"ts":"2024-01-01T12:00:00Z","ts_epoch":1704110400,"type":"pipeline_start","job_id":"j1","stage":"build","status":"running"}
{"ts":"2024-01-01T12:01:00Z","ts_epoch":1704110460,"type":"pipeline_end","job_id":"j1","stage":"build","status":"passed"}
EOF

    migrate_json_data

    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM events WHERE type='pipeline_start';" 2>/dev/null || echo 0)
    if [[ "$count" -ne 1 ]]; then
        echo -e "    ${RED}✗${RESET} Events not migrated (count=$count)"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 24. migrate_json_data imports costs.json
# ──────────────────────────────────────────────────────────────────────────────
test_migrate_costs() {
    source_db
    init_schema
    reset_db_data

    # Create sample costs.json
    mkdir -p "$DB_DIR"
    cat > "$COST_FILE_JSON" <<'EOF'
{
  "entries": [
    {"input_tokens":1000,"output_tokens":500,"model":"sonnet","stage":"build","cost_usd":0.10,"ts":"2024-01-01T12:00:00Z","ts_epoch":1704110400},
    {"input_tokens":2000,"output_tokens":1000,"model":"opus","stage":"review","cost_usd":0.20,"ts":"2024-01-01T12:01:00Z","ts_epoch":1704110460}
  ]
}
EOF

    migrate_json_data

    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM cost_entries;" 2>/dev/null || echo 0)
    if [[ "$count" -ne 2 ]]; then
        echo -e "    ${RED}✗${RESET} Costs not migrated (count=$count)"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 25. migrate_json_data imports budget.json
# ──────────────────────────────────────────────────────────────────────────────
test_migrate_budget() {
    source_db
    init_schema
    reset_db_data

    mkdir -p "$DB_DIR"
    cat > "$BUDGET_FILE_JSON" <<'EOF'
{
  "daily_budget_usd": 50.00,
  "enabled": true
}
EOF

    migrate_json_data

    local budget
    budget=$(sqlite3 "$DB_FILE" "SELECT daily_budget_usd FROM budgets WHERE id=1;" 2>/dev/null || echo "0")
    # SQLite may format as 50, 50.0, or 50.00
    if ! echo "$budget" | grep -qE '^50'; then
        echo -e "    ${RED}✗${RESET} Budget not migrated (got $budget)"
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# HEALTH CHECK TESTS
# ═════════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 26. db_health_check validates database
# ──────────────────────────────────────────────────────────────────────────────
test_health_check() {
    source_db
    init_schema

    local output
    output=$(db_health_check 2>&1 || true)

    if ! echo "$output" | grep -q "passed"; then
        echo -e "    ${RED}✗${RESET} Health check failed"
        return 1
    fi

    return 0
}

# ══════════════════════════════════════════════════════════════════════════════════
# EXPORT TESTS
# ══════════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 27. export_db creates JSON backup
# ──────────────────────────────────────────────────────────────────────────────
test_export_db() {
    source_db
    init_schema

    db_add_event "test_export" "job-exp" "build"

    local export_file="$DB_DIR/test-backup.json"
    export_db "$export_file"

    if [[ ! -f "$export_file" ]]; then
        echo -e "    ${RED}✗${RESET} Backup file not created"
        return 1
    fi

    # Verify valid JSON
    if ! jq empty "$export_file" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} Backup is not valid JSON"
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# CLEANUP TESTS
# ═════════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 28. cleanup_old_data removes old entries
# ──────────────────────────────────────────────────────────────────────────────
test_cleanup_old_data() {
    source_db
    init_schema

    # Insert old event (using direct SQL with old date)
    sqlite3 "$DB_FILE" "INSERT INTO events (ts, ts_epoch, type, job_id, stage, status, created_at, synced) VALUES ('2020-01-01T00:00:00Z', 1577836800, 'old_event', 'old', 'build', 'passed', '2020-01-01T00:00:00Z', 0);"

    # Insert recent event
    sqlite3 "$DB_FILE" "INSERT INTO events (ts, ts_epoch, type, job_id, stage, status, created_at, synced) VALUES ('$(date -u +%Y-%m-%dT%H:%M:%SZ)', $(date +%s), 'recent_event', 'new', 'build', 'passed', '$(date -u +%Y-%m-%dT%H:%M:%SZ)', 0);"

    cleanup_old_data 30

    local old_count recent_count
    old_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM events WHERE type='old_event';" 2>/dev/null || echo 0)
    recent_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM events WHERE type='recent_event';" 2>/dev/null || echo 0)

    if [[ "$old_count" -ne 0 || "$recent_count" -ne 1 ]]; then
        echo -e "    ${RED}✗${RESET} Cleanup failed (old=$old_count, recent=$recent_count)"
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# CONCURRENT WRITE TESTS
# ═════════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 29. Concurrent writes don't corrupt database
# ──────────────────────────────────────────────────────────────────────────────
test_concurrent_writes() {
    source_db
    init_schema
    reset_db_data

    # Set busy timeout so concurrent writers wait instead of failing
    sqlite3 "$DB_FILE" "PRAGMA busy_timeout = 5000;" 2>/dev/null || true

    # Start 5 concurrent writers (each inserts 10 events via sqlite3 CLI)
    for w in {1..5}; do
        (
            for i in $(seq 1 10); do
                sqlite3 "$DB_FILE" "PRAGMA busy_timeout = 5000; INSERT OR IGNORE INTO events (ts, ts_epoch, type, job_id, stage, status, duration_secs, metadata, created_at, synced) VALUES ('$(date -u +%Y-%m-%dT%H:%M:%SZ)', $(date +%s), 'concurrent_test', 'worker-${w}-${i}', 'build', 'running', 0, '', '$(date -u +%Y-%m-%dT%H:%M:%SZ)', 0);" 2>/dev/null || true
            done
        ) &
    done
    wait

    # Verify most writes succeeded (some may be dropped due to UNIQUE constraint on same-second events)
    local total_count
    total_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM events WHERE type='concurrent_test';" 2>/dev/null || echo 0)
    if [[ "$total_count" -lt 25 ]]; then
        echo -e "    ${RED}✗${RESET} Not enough concurrent writes succeeded (got $total_count, expected >= 25)"
        return 1
    fi

    # Verify no corruption
    local integrity
    integrity=$(sqlite3 "$DB_FILE" "PRAGMA integrity_check;" 2>/dev/null || echo "error")
    if [[ "$integrity" != "ok" ]]; then
        echo -e "    ${RED}✗${RESET} Database corrupted after concurrent writes"
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# PIPELINE RUN TESTS
# ═════════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 30. add_pipeline_run creates run entry
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_run() {
    source_db
    init_schema

    add_pipeline_run "pr-1" 100 "Add feature" "main" "standard"

    local job_id
    job_id=$(sqlite3 "$DB_FILE" "SELECT job_id FROM pipeline_runs WHERE issue_number=100;" 2>/dev/null || echo "")
    if [[ "$job_id" != "pr-1" ]]; then
        echo -e "    ${RED}✗${RESET} Pipeline run not created"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 31. update_pipeline_status updates run
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_run_update() {
    source_db
    init_schema

    add_pipeline_run "pr-2" 101 "Test" "main" "standard"
    update_pipeline_status "pr-2" "running" "build" "in_progress"

    local status
    status=$(sqlite3 "$DB_FILE" "SELECT status FROM pipeline_runs WHERE job_id='pr-2';" 2>/dev/null || echo "")
    if [[ "$status" != "running" ]]; then
        echo -e "    ${RED}✗${RESET} Pipeline status not updated"
        return 1
    fi

    return 0
}

# ════════════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ════════════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright db — SQLite Persistence Test Suite        ║${RESET}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} jq is required for db tests"
    exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} sqlite3 is required for db tests"
    exit 1
fi

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# Schema tests
echo -e "${PURPLE}${BOLD}Schema Creation${RESET}"
run_test "init_schema creates all tables" test_schema_creation
run_test "Schema includes required tables" test_schema_tables
run_test "WAL mode is enabled" test_wal_mode
run_test "check_sqlite3 caches result" test_check_sqlite3_caching
echo ""

# Availability tests
echo -e "${PURPLE}${BOLD}Database Availability${RESET}"
run_test "db_available returns true when ready" test_db_available
run_test "db_available returns false without sqlite3" test_db_available_fallback
echo ""

# Event CRUD tests
echo -e "${PURPLE}${BOLD}Event CRUD Operations${RESET}"
run_test "db_add_event inserts event" test_add_event
run_test "add_event dual-writes to SQLite + JSONL" test_add_event_dual_write
echo ""

# Daemon state tests
echo -e "${PURPLE}${BOLD}Daemon State Management${RESET}"
run_test "db_save_job saves active job" test_save_job
run_test "db_complete_job marks completed" test_complete_job
run_test "db_fail_job marks failed" test_fail_job
run_test "db_list_active_jobs returns JSON array" test_list_active_jobs
run_test "db_active_job_count returns count" test_active_job_count
run_test "db_is_issue_active checks status" test_is_issue_active
echo ""

# Cost tracking tests
echo -e "${PURPLE}${BOLD}Cost Tracking${RESET}"
run_test "db_record_cost saves entry" test_record_cost
run_test "db_cost_today calculates total" test_cost_today
run_test "db_set_budget and db_get_budget" test_budget
echo ""

# Heartbeat tests
echo -e "${PURPLE}${BOLD}Heartbeat Management${RESET}"
run_test "db_record_heartbeat saves heartbeat" test_record_heartbeat
run_test "db_list_heartbeats returns array" test_list_heartbeats
run_test "db_clear_heartbeat deletes entry" test_clear_heartbeat
echo ""

# Memory/failure tests
echo -e "${PURPLE}${BOLD}Memory & Failure Tracking${RESET}"
run_test "db_record_failure saves pattern" test_record_failure
run_test "db_query_similar_failures finds matches" test_query_similar_failures
echo ""

# Migration tests
echo -e "${PURPLE}${BOLD}JSON Data Migration${RESET}"
run_test "migrate_json_data imports events" test_migrate_events
run_test "migrate_json_data imports costs" test_migrate_costs
run_test "migrate_json_data imports budget" test_migrate_budget
echo ""

# Health check tests
echo -e "${PURPLE}${BOLD}Health Checks${RESET}"
run_test "db_health_check validates database" test_health_check
echo ""

# Export tests
echo -e "${PURPLE}${BOLD}Export & Backup${RESET}"
run_test "export_db creates JSON backup" test_export_db
echo ""

# Cleanup tests
echo -e "${PURPLE}${BOLD}Data Cleanup${RESET}"
run_test "cleanup_old_data removes old entries" test_cleanup_old_data
echo ""

# Concurrent write tests
echo -e "${PURPLE}${BOLD}Concurrent Operations${RESET}"
run_test "Concurrent writes don't corrupt DB" test_concurrent_writes
echo ""

# Pipeline run tests
echo -e "${PURPLE}${BOLD}Pipeline Run Tracking${RESET}"
run_test "add_pipeline_run creates entry" test_pipeline_run
run_test "update_pipeline_status updates run" test_pipeline_run_update
echo ""

# ═════════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${RESET}"
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All ${TOTAL} tests passed ✓${RESET}"
else
    echo -e "${RED}${BOLD}  ${FAIL}/${TOTAL} tests failed${RESET}"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
fi
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo ""

exit "$FAIL"
