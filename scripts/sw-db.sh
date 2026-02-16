#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright db — SQLite Persistence Layer                                ║
# ║  Unified state store: events, runs, daemon state, costs, heartbeats      ║
# ║  Backward compatible: falls back to JSON if SQLite unavailable           ║
# ║  Cross-device sync via HTTP (Turso/sqld/any REST endpoint)               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# ─── Double-source guard ─────────────────────────────────────────
if [[ -n "${_SW_DB_LOADED:-}" ]] && [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0 2>/dev/null || true
fi
_SW_DB_LOADED=1

VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Database Configuration ──────────────────────────────────────────────────
DB_DIR="${HOME}/.shipwright"
DB_FILE="${DB_DIR}/shipwright.db"
SCHEMA_VERSION=2

# JSON fallback paths
EVENTS_FILE="${DB_DIR}/events.jsonl"
DAEMON_STATE_FILE="${DB_DIR}/daemon-state.json"
DEVELOPER_REGISTRY_FILE="${DB_DIR}/developer-registry.json"
COST_FILE_JSON="${DB_DIR}/costs.json"
BUDGET_FILE_JSON="${DB_DIR}/budget.json"
HEARTBEAT_DIR="${DB_DIR}/heartbeats"

# Sync config
SYNC_CONFIG_FILE="${DB_DIR}/sync-config.json"

# ─── Feature Flag ─────────────────────────────────────────────────────────────
# Check if DB is enabled in daemon config (default: true)
_db_feature_enabled() {
    local config_file=".claude/daemon-config.json"
    if [[ -f "$config_file" ]]; then
        local enabled
        enabled=$(jq -r '.db.enabled // true' "$config_file" 2>/dev/null || echo "true")
        [[ "$enabled" == "true" ]]
        return $?
    fi
    return 0
}

# ─── Check Prerequisites ─────────────────────────────────────────────────────
_SQLITE3_CHECKED=""
_SQLITE3_AVAILABLE=""

check_sqlite3() {
    # Cache the result to avoid repeated command lookups
    if [[ -z "$_SQLITE3_CHECKED" ]]; then
        _SQLITE3_CHECKED=1
        if command -v sqlite3 &>/dev/null; then
            _SQLITE3_AVAILABLE=1
        else
            _SQLITE3_AVAILABLE=""
        fi
    fi
    [[ -n "$_SQLITE3_AVAILABLE" ]]
}

# Check if DB is ready (sqlite3 available + file exists + feature enabled)
db_available() {
    check_sqlite3 && [[ -f "$DB_FILE" ]] && _db_feature_enabled
}

# ─── Ensure Database Directory ──────────────────────────────────────────────
ensure_db_dir() {
    mkdir -p "$DB_DIR"
}

# ─── SQL Execution Helper ──────────────────────────────────────────────────
# Runs SQL with proper error handling. Silent on success.
_db_exec() {
    sqlite3 "$DB_FILE" "$@" 2>/dev/null
}

# Runs SQL and returns output. Returns 1 on failure.
_db_query() {
    sqlite3 "$DB_FILE" "$@" 2>/dev/null || return 1
}

# ─── Initialize Database Schema ──────────────────────────────────────────────
init_schema() {
    ensure_db_dir

    if ! check_sqlite3; then
        warn "Skipping SQLite initialization — sqlite3 not available"
        return 0
    fi

    # Enable WAL mode for crash safety + concurrent readers
    sqlite3 "$DB_FILE" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || true

    sqlite3 "$DB_FILE" <<'SCHEMA'
-- Schema version tracking
CREATE TABLE IF NOT EXISTS _schema (
    version INTEGER PRIMARY KEY,
    created_at TEXT NOT NULL,
    applied_at TEXT NOT NULL
);

-- Events log (replaces events.jsonl)
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    ts_epoch INTEGER NOT NULL,
    type TEXT NOT NULL,
    job_id TEXT,
    stage TEXT,
    status TEXT,
    repo TEXT,
    branch TEXT,
    error TEXT,
    duration_secs INTEGER,
    metadata TEXT,
    created_at TEXT NOT NULL,
    synced INTEGER DEFAULT 0,
    UNIQUE(ts_epoch, type, job_id)
);

-- Pipeline runs tracking
CREATE TABLE IF NOT EXISTS pipeline_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id TEXT UNIQUE NOT NULL,
    issue_number INTEGER,
    goal TEXT,
    branch TEXT,
    status TEXT NOT NULL,
    template TEXT,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    duration_secs INTEGER,
    stage_name TEXT,
    stage_status TEXT,
    error_message TEXT,
    commit_hash TEXT,
    pr_number INTEGER,
    metadata TEXT,
    created_at TEXT NOT NULL
);

-- Stage history per pipeline run
CREATE TABLE IF NOT EXISTS pipeline_stages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id TEXT NOT NULL,
    stage_name TEXT NOT NULL,
    status TEXT NOT NULL,
    started_at TEXT,
    completed_at TEXT,
    duration_secs INTEGER,
    error_message TEXT,
    metadata TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (job_id) REFERENCES pipeline_runs(job_id)
);

-- Developer registry
CREATE TABLE IF NOT EXISTS developers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    github_login TEXT,
    email TEXT,
    role TEXT,
    avatar_url TEXT,
    bio TEXT,
    expertise TEXT,
    contributed_repos TEXT,
    last_active_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

-- Sessions tracking (teams/agents)
CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    template TEXT,
    status TEXT NOT NULL,
    team_members TEXT,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    duration_secs INTEGER,
    goal TEXT,
    metadata TEXT,
    created_at TEXT NOT NULL
);

-- Metrics (DORA, cost, performance)
CREATE TABLE IF NOT EXISTS metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id TEXT,
    metric_type TEXT NOT NULL,
    metric_name TEXT NOT NULL,
    value REAL NOT NULL,
    period TEXT,
    unit TEXT,
    tags TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (job_id) REFERENCES pipeline_runs(job_id)
);

-- ═══════════════════════════════════════════════════════════════════════
-- Phase 1: New tables for state migration
-- ═══════════════════════════════════════════════════════════════════════

-- Daemon state (replaces daemon-state.json)
CREATE TABLE IF NOT EXISTS daemon_state (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id TEXT NOT NULL,
    issue_number INTEGER NOT NULL,
    title TEXT,
    goal TEXT,
    pid INTEGER,
    worktree TEXT,
    branch TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    template TEXT,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    result TEXT,
    duration TEXT,
    error_message TEXT,
    retry_count INTEGER DEFAULT 0,
    updated_at TEXT NOT NULL,
    UNIQUE(job_id, status)
);

-- Cost entries (replaces costs.json)
CREATE TABLE IF NOT EXISTS cost_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    model TEXT NOT NULL DEFAULT 'sonnet',
    stage TEXT,
    issue TEXT,
    cost_usd REAL NOT NULL DEFAULT 0,
    ts TEXT NOT NULL,
    ts_epoch INTEGER NOT NULL,
    synced INTEGER DEFAULT 0
);

-- Budgets (replaces budget.json)
CREATE TABLE IF NOT EXISTS budgets (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    daily_budget_usd REAL NOT NULL DEFAULT 0,
    enabled INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

-- Heartbeats (replaces heartbeats/*.json)
CREATE TABLE IF NOT EXISTS heartbeats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id TEXT UNIQUE NOT NULL,
    pid INTEGER,
    issue INTEGER,
    stage TEXT,
    iteration INTEGER DEFAULT 0,
    last_activity TEXT,
    memory_mb INTEGER DEFAULT 0,
    updated_at TEXT NOT NULL
);

-- Memory: failure patterns (replaces memory/*/failures.json)
CREATE TABLE IF NOT EXISTS memory_failures (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    repo_hash TEXT NOT NULL,
    failure_class TEXT NOT NULL,
    error_signature TEXT,
    root_cause TEXT,
    fix_description TEXT,
    file_path TEXT,
    stage TEXT,
    occurrences INTEGER DEFAULT 1,
    last_seen_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    synced INTEGER DEFAULT 0
);

-- ═══════════════════════════════════════════════════════════════════════
-- Sync tables
-- ═══════════════════════════════════════════════════════════════════════

-- Track unsynced local changes
CREATE TABLE IF NOT EXISTS _sync_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    table_name TEXT NOT NULL,
    row_id INTEGER NOT NULL,
    operation TEXT NOT NULL,
    ts_epoch INTEGER NOT NULL,
    synced INTEGER DEFAULT 0
);

-- Replication state
CREATE TABLE IF NOT EXISTS _sync_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

-- ═══════════════════════════════════════════════════════════════════════
-- Indexes
-- ═══════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
CREATE INDEX IF NOT EXISTS idx_events_job_id ON events(job_id);
CREATE INDEX IF NOT EXISTS idx_events_ts_epoch ON events(ts_epoch DESC);
CREATE INDEX IF NOT EXISTS idx_events_synced ON events(synced) WHERE synced = 0;
CREATE INDEX IF NOT EXISTS idx_pipeline_runs_job_id ON pipeline_runs(job_id);
CREATE INDEX IF NOT EXISTS idx_pipeline_runs_status ON pipeline_runs(status);
CREATE INDEX IF NOT EXISTS idx_pipeline_runs_created ON pipeline_runs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pipeline_stages_job_id ON pipeline_stages(job_id);
CREATE INDEX IF NOT EXISTS idx_developers_name ON developers(name);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
CREATE INDEX IF NOT EXISTS idx_metrics_job_id ON metrics(job_id);
CREATE INDEX IF NOT EXISTS idx_metrics_type ON metrics(metric_type);
CREATE INDEX IF NOT EXISTS idx_daemon_state_status ON daemon_state(status);
CREATE INDEX IF NOT EXISTS idx_daemon_state_job ON daemon_state(job_id);
CREATE INDEX IF NOT EXISTS idx_cost_entries_epoch ON cost_entries(ts_epoch DESC);
CREATE INDEX IF NOT EXISTS idx_cost_entries_synced ON cost_entries(synced) WHERE synced = 0;
CREATE INDEX IF NOT EXISTS idx_heartbeats_job ON heartbeats(job_id);
CREATE INDEX IF NOT EXISTS idx_memory_failures_repo ON memory_failures(repo_hash);
CREATE INDEX IF NOT EXISTS idx_memory_failures_class ON memory_failures(failure_class);
CREATE INDEX IF NOT EXISTS idx_sync_log_unsynced ON _sync_log(synced) WHERE synced = 0;
SCHEMA
}

# ─── Schema Migration ───────────────────────────────────────────────────────
migrate_schema() {
    if ! check_sqlite3; then
        warn "Skipping migration — sqlite3 not available"
        return 0
    fi

    ensure_db_dir

    # If DB doesn't exist, initialize fresh
    if [[ ! -f "$DB_FILE" ]]; then
        init_schema
        _db_exec "INSERT OR REPLACE INTO _schema (version, created_at, applied_at) VALUES (${SCHEMA_VERSION}, '$(now_iso)', '$(now_iso)');"
        # Initialize device_id for sync
        _db_exec "INSERT OR REPLACE INTO _sync_metadata (key, value, updated_at) VALUES ('device_id', '$(uname -n)-$$-$(now_epoch)', '$(now_iso)');"
        success "Database schema initialized (v${SCHEMA_VERSION})"
        return 0
    fi

    local current_version
    current_version=$(_db_query "SELECT COALESCE(MAX(version), 0) FROM _schema;" || echo 0)

    if [[ "$current_version" -ge "$SCHEMA_VERSION" ]]; then
        info "Database already at schema v${current_version}"
        return 0
    fi

    # Migration from v1 → v2: add new tables
    if [[ "$current_version" -lt 2 ]]; then
        info "Migrating schema v${current_version} → v2..."
        init_schema  # CREATE IF NOT EXISTS is idempotent
        # Enable WAL if not already
        sqlite3 "$DB_FILE" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || true
        _db_exec "INSERT OR REPLACE INTO _schema (version, created_at, applied_at) VALUES (2, '$(now_iso)', '$(now_iso)');"
        # Initialize device_id if missing
        _db_exec "INSERT OR IGNORE INTO _sync_metadata (key, value, updated_at) VALUES ('device_id', '$(uname -n)-$$-$(now_epoch)', '$(now_iso)');"
        success "Migrated to schema v2"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Event Functions (dual-write: SQLite + JSONL)
# ═══════════════════════════════════════════════════════════════════════════

# db_add_event <type> [key=value ...]
# Parameterized event insert. Used by emit_event() in helpers.sh.
db_add_event() {
    local event_type="$1"
    shift

    local ts ts_epoch job_id="" stage="" status="" duration_secs="0" metadata=""
    ts="$(now_iso)"
    ts_epoch="$(now_epoch)"

    # Parse key=value pairs
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        case "$key" in
            job_id)        job_id="$val" ;;
            stage)         stage="$val" ;;
            status)        status="$val" ;;
            duration_secs) duration_secs="$val" ;;
            *)             metadata="${metadata:+${metadata},}\"${key}\":\"${val}\"" ;;
        esac
    done

    [[ -n "$metadata" ]] && metadata="{${metadata}}"

    if ! db_available; then
        return 1
    fi

    _db_exec "INSERT OR IGNORE INTO events (ts, ts_epoch, type, job_id, stage, status, duration_secs, metadata, created_at, synced) VALUES ('${ts}', ${ts_epoch}, '${event_type}', '${job_id}', '${stage}', '${status}', ${duration_secs}, '${metadata}', '${ts}', 0);" || return 1
}

# Legacy positional API (backward compat with existing add_event calls)
add_event() {
    local event_type="$1"
    local job_id="${2:-}"
    local stage="${3:-}"
    local status="${4:-}"
    local duration_secs="${5:-0}"
    local metadata="${6:-}"

    local ts ts_epoch
    ts="$(now_iso)"
    ts_epoch="$(now_epoch)"

    # Try SQLite first
    if db_available; then
        _db_exec "INSERT OR IGNORE INTO events (ts, ts_epoch, type, job_id, stage, status, duration_secs, metadata, created_at, synced) VALUES ('${ts}', ${ts_epoch}, '${event_type}', '${job_id}', '${stage}', '${status}', ${duration_secs}, '${metadata}', '${ts}', 0);" || true
    fi

    # Always write to JSONL for backward compat (dual-write period)
    mkdir -p "$DB_DIR"
    local json_record
    json_record="{\"ts\":\"${ts}\",\"ts_epoch\":${ts_epoch},\"type\":\"${event_type}\""
    [[ -n "$job_id" ]] && json_record="${json_record},\"job_id\":\"${job_id}\""
    [[ -n "$stage" ]] && json_record="${json_record},\"stage\":\"${stage}\""
    [[ -n "$status" ]] && json_record="${json_record},\"status\":\"${status}\""
    [[ "$duration_secs" -gt 0 ]] 2>/dev/null && json_record="${json_record},\"duration_secs\":${duration_secs}"
    [[ -n "$metadata" ]] && json_record="${json_record},\"metadata\":${metadata}"
    json_record="${json_record}}"
    echo "$json_record" >> "$EVENTS_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════
# Daemon State Functions (replaces daemon-state.json operations)
# ═══════════════════════════════════════════════════════════════════════════

# db_save_job <job_id> <issue_number> <title> <pid> <worktree> [branch] [template] [goal]
db_save_job() {
    local job_id="$1"
    local issue_num="$2"
    local title="${3:-}"
    local pid="${4:-0}"
    local worktree="${5:-}"
    local branch="${6:-}"
    local template="${7:-autonomous}"
    local goal="${8:-}"
    local ts
    ts="$(now_iso)"

    if ! db_available; then return 1; fi

    # Escape single quotes in title/goal
    title="${title//\'/\'\'}"
    goal="${goal//\'/\'\'}"

    _db_exec "INSERT OR REPLACE INTO daemon_state (job_id, issue_number, title, goal, pid, worktree, branch, status, template, started_at, updated_at) VALUES ('${job_id}', ${issue_num}, '${title}', '${goal}', ${pid}, '${worktree}', '${branch}', 'active', '${template}', '${ts}', '${ts}');"
}

# db_complete_job <job_id> <result> [duration] [error_message]
db_complete_job() {
    local job_id="$1"
    local result="$2"
    local duration="${3:-}"
    local error_msg="${4:-}"
    local ts
    ts="$(now_iso)"

    if ! db_available; then return 1; fi

    error_msg="${error_msg//\'/\'\'}"

    _db_exec "UPDATE daemon_state SET status = 'completed', result = '${result}', duration = '${duration}', error_message = '${error_msg}', completed_at = '${ts}', updated_at = '${ts}' WHERE job_id = '${job_id}' AND status = 'active';"
}

# db_fail_job <job_id> [error_message]
db_fail_job() {
    local job_id="$1"
    local error_msg="${2:-}"
    local ts
    ts="$(now_iso)"

    if ! db_available; then return 1; fi

    error_msg="${error_msg//\'/\'\'}"

    _db_exec "UPDATE daemon_state SET status = 'failed', result = 'failure', error_message = '${error_msg}', completed_at = '${ts}', updated_at = '${ts}' WHERE job_id = '${job_id}' AND status = 'active';"
}

# db_list_active_jobs — outputs JSON array of active daemon jobs
db_list_active_jobs() {
    if ! db_available; then echo "[]"; return 0; fi
    _db_query "SELECT json_group_array(json_object('job_id', job_id, 'issue', issue_number, 'title', title, 'pid', pid, 'worktree', worktree, 'branch', branch, 'started_at', started_at, 'template', template, 'goal', goal)) FROM daemon_state WHERE status = 'active';" || echo "[]"
}

# db_list_completed_jobs [limit] — outputs JSON array
db_list_completed_jobs() {
    local limit="${1:-20}"
    if ! db_available; then echo "[]"; return 0; fi
    _db_query "SELECT json_group_array(json_object('job_id', job_id, 'issue', issue_number, 'title', title, 'result', result, 'duration', duration, 'completed_at', completed_at)) FROM (SELECT * FROM daemon_state WHERE status IN ('completed', 'failed') ORDER BY completed_at DESC LIMIT ${limit});" || echo "[]"
}

# db_active_job_count — returns integer
db_active_job_count() {
    if ! db_available; then echo "0"; return 0; fi
    _db_query "SELECT COUNT(*) FROM daemon_state WHERE status = 'active';" || echo "0"
}

# db_is_issue_active <issue_number> — returns 0 if active, 1 if not
db_is_issue_active() {
    local issue_num="$1"
    if ! db_available; then return 1; fi
    local count
    count=$(_db_query "SELECT COUNT(*) FROM daemon_state WHERE issue_number = ${issue_num} AND status = 'active';")
    [[ "${count:-0}" -gt 0 ]]
}

# db_remove_active_job <job_id> — delete from active (for cleanup)
db_remove_active_job() {
    local job_id="$1"
    if ! db_available; then return 1; fi
    _db_exec "DELETE FROM daemon_state WHERE job_id = '${job_id}' AND status = 'active';"
}

# db_daemon_summary — outputs JSON summary for status dashboard
db_daemon_summary() {
    if ! db_available; then echo "{}"; return 0; fi
    _db_query "SELECT json_object(
        'active_count', (SELECT COUNT(*) FROM daemon_state WHERE status = 'active'),
        'completed_count', (SELECT COUNT(*) FROM daemon_state WHERE status IN ('completed', 'failed')),
        'success_count', (SELECT COUNT(*) FROM daemon_state WHERE result = 'success'),
        'failure_count', (SELECT COUNT(*) FROM daemon_state WHERE result = 'failure')
    );" || echo "{}"
}

# ═══════════════════════════════════════════════════════════════════════════
# Cost Functions (replaces costs.json)
# ═══════════════════════════════════════════════════════════════════════════

# db_record_cost <input_tokens> <output_tokens> <model> <cost_usd> <stage> [issue]
db_record_cost() {
    local input_tokens="${1:-0}"
    local output_tokens="${2:-0}"
    local model="${3:-sonnet}"
    local cost_usd="${4:-0}"
    local stage="${5:-unknown}"
    local issue="${6:-}"
    local ts ts_epoch
    ts="$(now_iso)"
    ts_epoch="$(now_epoch)"

    if ! db_available; then return 1; fi

    _db_exec "INSERT INTO cost_entries (input_tokens, output_tokens, model, stage, issue, cost_usd, ts, ts_epoch, synced) VALUES (${input_tokens}, ${output_tokens}, '${model}', '${stage}', '${issue}', ${cost_usd}, '${ts}', ${ts_epoch}, 0);"
}

# db_cost_today — returns total cost for today as a number
db_cost_today() {
    if ! db_available; then echo "0"; return 0; fi
    local today_start
    today_start=$(date -u +"%Y-%m-%dT00:00:00Z")
    local today_epoch
    today_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$today_start" +%s 2>/dev/null || date -u -d "$today_start" +%s 2>/dev/null || echo "0")
    _db_query "SELECT COALESCE(ROUND(SUM(cost_usd), 4), 0) FROM cost_entries WHERE ts_epoch >= ${today_epoch};" || echo "0"
}

# db_cost_by_period <days> — returns JSON breakdown
db_cost_by_period() {
    local days="${1:-7}"
    if ! db_available; then echo "{}"; return 0; fi
    local cutoff_epoch
    cutoff_epoch=$(( $(now_epoch) - (days * 86400) ))
    _db_query "SELECT json_object(
        'total', COALESCE(ROUND(SUM(cost_usd), 4), 0),
        'count', COUNT(*),
        'avg', COALESCE(ROUND(AVG(cost_usd), 4), 0),
        'max', COALESCE(ROUND(MAX(cost_usd), 4), 0),
        'input_tokens', COALESCE(SUM(input_tokens), 0),
        'output_tokens', COALESCE(SUM(output_tokens), 0)
    ) FROM cost_entries WHERE ts_epoch >= ${cutoff_epoch};" || echo "{}"
}

# db_cost_by_stage <days> — returns JSON array grouped by stage
db_cost_by_stage() {
    local days="${1:-7}"
    if ! db_available; then echo "[]"; return 0; fi
    local cutoff_epoch
    cutoff_epoch=$(( $(now_epoch) - (days * 86400) ))
    _db_query "SELECT json_group_array(json_object('stage', stage, 'cost', ROUND(total_cost, 4), 'count', cnt)) FROM (SELECT stage, SUM(cost_usd) as total_cost, COUNT(*) as cnt FROM cost_entries WHERE ts_epoch >= ${cutoff_epoch} GROUP BY stage ORDER BY total_cost DESC);" || echo "[]"
}

# db_remaining_budget — returns remaining budget or "unlimited"
db_remaining_budget() {
    if ! db_available; then echo "unlimited"; return 0; fi
    local row
    row=$(_db_query "SELECT daily_budget_usd, enabled FROM budgets WHERE id = 1;" || echo "")
    if [[ -z "$row" ]]; then
        echo "unlimited"
        return 0
    fi
    local budget_usd enabled
    budget_usd=$(echo "$row" | cut -d'|' -f1)
    enabled=$(echo "$row" | cut -d'|' -f2)
    if [[ "${enabled:-0}" -ne 1 ]] || [[ "${budget_usd:-0}" == "0" ]]; then
        echo "unlimited"
        return 0
    fi
    local today_spent
    today_spent=$(db_cost_today)
    awk -v budget="$budget_usd" -v spent="$today_spent" 'BEGIN { printf "%.2f", budget - spent }'
}

# db_set_budget <amount_usd>
db_set_budget() {
    local amount="$1"
    if ! db_available; then return 1; fi
    _db_exec "INSERT OR REPLACE INTO budgets (id, daily_budget_usd, enabled, updated_at) VALUES (1, ${amount}, 1, '$(now_iso)');"
}

# db_get_budget — returns "amount|enabled" or empty
db_get_budget() {
    if ! db_available; then echo ""; return 0; fi
    _db_query "SELECT daily_budget_usd || '|' || enabled FROM budgets WHERE id = 1;" || echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# Heartbeat Functions (replaces heartbeats/*.json)
# ═══════════════════════════════════════════════════════════════════════════

# db_record_heartbeat <job_id> <pid> <issue> <stage> <iteration> [activity] [memory_mb]
db_record_heartbeat() {
    local job_id="$1"
    local pid="${2:-0}"
    local issue="${3:-0}"
    local stage="${4:-}"
    local iteration="${5:-0}"
    local activity="${6:-}"
    local memory_mb="${7:-0}"
    local ts
    ts="$(now_iso)"

    if ! db_available; then return 1; fi

    activity="${activity//\'/\'\'}"

    _db_exec "INSERT OR REPLACE INTO heartbeats (job_id, pid, issue, stage, iteration, last_activity, memory_mb, updated_at) VALUES ('${job_id}', ${pid}, ${issue}, '${stage}', ${iteration}, '${activity}', ${memory_mb}, '${ts}');"
}

# db_stale_heartbeats [threshold_secs] — returns JSON array of stale heartbeats
db_stale_heartbeats() {
    local threshold="${1:-120}"
    if ! db_available; then echo "[]"; return 0; fi
    local cutoff_epoch
    cutoff_epoch=$(( $(now_epoch) - threshold ))
    local cutoff_ts
    cutoff_ts=$(date -u -r "$cutoff_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@${cutoff_epoch}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "2000-01-01T00:00:00Z")
    _db_query "SELECT json_group_array(json_object('job_id', job_id, 'pid', pid, 'stage', stage, 'updated_at', updated_at)) FROM heartbeats WHERE updated_at < '${cutoff_ts}';" || echo "[]"
}

# db_clear_heartbeat <job_id>
db_clear_heartbeat() {
    local job_id="$1"
    if ! db_available; then return 1; fi
    _db_exec "DELETE FROM heartbeats WHERE job_id = '${job_id}';"
}

# db_list_heartbeats — returns JSON array
db_list_heartbeats() {
    if ! db_available; then echo "[]"; return 0; fi
    _db_query "SELECT json_group_array(json_object('job_id', job_id, 'pid', pid, 'issue', issue, 'stage', stage, 'iteration', iteration, 'last_activity', last_activity, 'memory_mb', memory_mb, 'updated_at', updated_at)) FROM heartbeats;" || echo "[]"
}

# ═══════════════════════════════════════════════════════════════════════════
# Memory Failure Functions (replaces memory/*/failures.json)
# ═══════════════════════════════════════════════════════════════════════════

# db_record_failure <repo_hash> <failure_class> <error_sig> [root_cause] [fix_desc] [file_path] [stage]
db_record_failure() {
    local repo_hash="$1"
    local failure_class="$2"
    local error_sig="${3:-}"
    local root_cause="${4:-}"
    local fix_desc="${5:-}"
    local file_path="${6:-}"
    local stage="${7:-}"
    local ts
    ts="$(now_iso)"

    if ! db_available; then return 1; fi

    # Escape quotes
    error_sig="${error_sig//\'/\'\'}"
    root_cause="${root_cause//\'/\'\'}"
    fix_desc="${fix_desc//\'/\'\'}"

    # Upsert: increment occurrences if same signature exists
    _db_exec "INSERT INTO memory_failures (repo_hash, failure_class, error_signature, root_cause, fix_description, file_path, stage, occurrences, last_seen_at, created_at, synced) VALUES ('${repo_hash}', '${failure_class}', '${error_sig}', '${root_cause}', '${fix_desc}', '${file_path}', '${stage}', 1, '${ts}', '${ts}', 0) ON CONFLICT(id) DO UPDATE SET occurrences = occurrences + 1, last_seen_at = '${ts}';"
}

# db_query_similar_failures <repo_hash> [failure_class] [limit]
db_query_similar_failures() {
    local repo_hash="$1"
    local failure_class="${2:-}"
    local limit="${3:-10}"

    if ! db_available; then echo "[]"; return 0; fi

    local where_clause="WHERE repo_hash = '${repo_hash}'"
    [[ -n "$failure_class" ]] && where_clause="${where_clause} AND failure_class = '${failure_class}'"

    _db_query "SELECT json_group_array(json_object('failure_class', failure_class, 'error_signature', error_signature, 'root_cause', root_cause, 'fix_description', fix_description, 'file_path', file_path, 'occurrences', occurrences, 'last_seen_at', last_seen_at)) FROM (SELECT * FROM memory_failures ${where_clause} ORDER BY occurrences DESC, last_seen_at DESC LIMIT ${limit});" || echo "[]"
}

# ═══════════════════════════════════════════════════════════════════════════
# Pipeline Run Functions (enhanced from existing)
# ═══════════════════════════════════════════════════════════════════════════

add_pipeline_run() {
    local job_id="$1"
    local issue_number="${2:-0}"
    local goal="${3:-}"
    local branch="${4:-}"
    local template="${5:-standard}"

    if ! check_sqlite3; then
        return 1
    fi

    local ts
    ts="$(now_iso)"
    goal="${goal//\'/\'\'}"

    _db_exec "INSERT OR IGNORE INTO pipeline_runs (job_id, issue_number, goal, branch, status, template, started_at, created_at) VALUES ('${job_id}', ${issue_number}, '${goal}', '${branch}', 'pending', '${template}', '${ts}', '${ts}');" || return 1
}

update_pipeline_status() {
    local job_id="$1"
    local status="$2"
    local stage_name="${3:-}"
    local stage_status="${4:-}"
    local duration_secs="${5:-0}"

    if ! check_sqlite3; then return 1; fi

    local ts
    ts="$(now_iso)"

    _db_exec "UPDATE pipeline_runs SET status = '${status}', stage_name = '${stage_name}', stage_status = '${stage_status}', duration_secs = ${duration_secs}, completed_at = CASE WHEN '${status}' IN ('completed', 'failed') THEN '${ts}' ELSE completed_at END WHERE job_id = '${job_id}';" || return 1
}

record_stage() {
    local job_id="$1"
    local stage_name="$2"
    local status="$3"
    local duration_secs="${4:-0}"
    local error_msg="${5:-}"

    if ! check_sqlite3; then return 1; fi

    local ts
    ts="$(now_iso)"
    error_msg="${error_msg//\'/\'\'}"

    _db_exec "INSERT INTO pipeline_stages (job_id, stage_name, status, started_at, completed_at, duration_secs, error_message, created_at) VALUES ('${job_id}', '${stage_name}', '${status}', '${ts}', '${ts}', ${duration_secs}, '${error_msg}', '${ts}');" || return 1
}

query_runs() {
    local status="${1:-}"
    local limit="${2:-50}"

    if ! check_sqlite3; then
        warn "Cannot query — sqlite3 not available"
        return 1
    fi

    local query="SELECT job_id, goal, status, template, started_at, duration_secs FROM pipeline_runs"
    [[ -n "$status" ]] && query="${query} WHERE status = '${status}'"
    query="${query} ORDER BY created_at DESC LIMIT ${limit};"

    sqlite3 -header -column "$DB_FILE" "$query"
}

# ═══════════════════════════════════════════════════════════════════════════
# Sync Functions (HTTP-based, vendor-neutral)
# ═══════════════════════════════════════════════════════════════════════════

# Load sync configuration
_sync_load_config() {
    if [[ ! -f "$SYNC_CONFIG_FILE" ]]; then
        return 1
    fi
    SYNC_URL=$(jq -r '.url // empty' "$SYNC_CONFIG_FILE" 2>/dev/null || true)
    SYNC_TOKEN=$(jq -r '.token // empty' "$SYNC_CONFIG_FILE" 2>/dev/null || true)
    [[ -n "$SYNC_URL" ]]
}

# db_sync_push — push unsynced rows to remote endpoint
db_sync_push() {
    if ! db_available; then return 1; fi
    if ! _sync_load_config; then
        warn "Sync not configured. Set up ${SYNC_CONFIG_FILE}"
        return 1
    fi

    local device_id
    device_id=$(_db_query "SELECT value FROM _sync_metadata WHERE key = 'device_id';" || echo "unknown")

    # Collect unsynced events
    local unsynced_events
    unsynced_events=$(_db_query "SELECT json_group_array(json_object('ts', ts, 'ts_epoch', ts_epoch, 'type', type, 'job_id', job_id, 'stage', stage, 'status', status, 'metadata', metadata)) FROM events WHERE synced = 0 LIMIT 500;" || echo "[]")

    # Collect unsynced cost entries
    local unsynced_costs
    unsynced_costs=$(_db_query "SELECT json_group_array(json_object('input_tokens', input_tokens, 'output_tokens', output_tokens, 'model', model, 'stage', stage, 'cost_usd', cost_usd, 'ts', ts, 'ts_epoch', ts_epoch)) FROM cost_entries WHERE synced = 0 LIMIT 500;" || echo "[]")

    # Build payload
    local payload
    payload=$(jq -n \
        --arg device "$device_id" \
        --argjson events "$unsynced_events" \
        --argjson costs "$unsynced_costs" \
        '{device_id: $device, events: $events, costs: $costs}')

    # Push via HTTP
    local response
    local auth_header=""
    [[ -n "${SYNC_TOKEN:-}" ]] && auth_header="-H 'Authorization: Bearer ${SYNC_TOKEN}'"

    response=$(curl -s -w "%{http_code}" -o /dev/null \
        -X POST "${SYNC_URL}/api/sync/push" \
        -H "Content-Type: application/json" \
        ${auth_header} \
        -d "$payload" 2>/dev/null || echo "000")

    if [[ "$response" == "200" || "$response" == "201" ]]; then
        # Mark as synced
        _db_exec "UPDATE events SET synced = 1 WHERE synced = 0;"
        _db_exec "UPDATE cost_entries SET synced = 1 WHERE synced = 0;"
        success "Pushed unsynced data to ${SYNC_URL}"
        return 0
    else
        warn "Sync push failed (HTTP ${response})"
        return 1
    fi
}

# db_sync_pull — pull new rows from remote endpoint
db_sync_pull() {
    if ! db_available; then return 1; fi
    if ! _sync_load_config; then
        warn "Sync not configured. Set up ${SYNC_CONFIG_FILE}"
        return 1
    fi

    local last_sync
    last_sync=$(_db_query "SELECT value FROM _sync_metadata WHERE key = 'last_pull_epoch';" || echo "0")

    local auth_header=""
    [[ -n "${SYNC_TOKEN:-}" ]] && auth_header="-H 'Authorization: Bearer ${SYNC_TOKEN}'"

    local response_body
    response_body=$(curl -s \
        "${SYNC_URL}/api/sync/pull?since=${last_sync}" \
        -H "Accept: application/json" \
        ${auth_header} 2>/dev/null || echo "{}")

    if ! echo "$response_body" | jq empty 2>/dev/null; then
        warn "Sync pull returned invalid JSON"
        return 1
    fi

    # Import events
    local event_count=0
    while IFS= read -r evt; do
        [[ -z "$evt" || "$evt" == "null" ]] && continue
        local e_ts e_epoch e_type e_job
        e_ts=$(echo "$evt" | jq -r '.ts // ""')
        e_epoch=$(echo "$evt" | jq -r '.ts_epoch // 0')
        e_type=$(echo "$evt" | jq -r '.type // ""')
        e_job=$(echo "$evt" | jq -r '.job_id // ""')
        _db_exec "INSERT OR IGNORE INTO events (ts, ts_epoch, type, job_id, created_at, synced) VALUES ('${e_ts}', ${e_epoch}, '${e_type}', '${e_job}', '${e_ts}', 1);" 2>/dev/null && event_count=$((event_count + 1))
    done < <(echo "$response_body" | jq -c '.events[]' 2>/dev/null)

    # Update last pull timestamp
    _db_exec "INSERT OR REPLACE INTO _sync_metadata (key, value, updated_at) VALUES ('last_pull_epoch', '$(now_epoch)', '$(now_iso)');"

    success "Pulled ${event_count} new events from ${SYNC_URL}"
}

# ═══════════════════════════════════════════════════════════════════════════
# JSON Migration (import existing state files into SQLite)
# ═══════════════════════════════════════════════════════════════════════════

migrate_json_data() {
    if ! check_sqlite3; then
        error "sqlite3 required for migration"
        return 1
    fi

    ensure_db_dir
    migrate_schema

    local total_imported=0

    # 1. Import events.jsonl
    if [[ -f "$EVENTS_FILE" ]]; then
        info "Importing events from ${EVENTS_FILE}..."
        local evt_count=0
        local evt_skipped=0
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local e_ts e_epoch e_type e_job e_stage e_status
            e_ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null || continue)
            e_epoch=$(echo "$line" | jq -r '.ts_epoch // 0' 2>/dev/null || continue)
            e_type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null || continue)
            e_job=$(echo "$line" | jq -r '.job_id // ""' 2>/dev/null || true)
            e_stage=$(echo "$line" | jq -r '.stage // ""' 2>/dev/null || true)
            e_status=$(echo "$line" | jq -r '.status // ""' 2>/dev/null || true)

            if _db_exec "INSERT OR IGNORE INTO events (ts, ts_epoch, type, job_id, stage, status, created_at, synced) VALUES ('${e_ts}', ${e_epoch}, '${e_type}', '${e_job}', '${e_stage}', '${e_status}', '${e_ts}', 0);" 2>/dev/null; then
                evt_count=$((evt_count + 1))
            else
                evt_skipped=$((evt_skipped + 1))
            fi
        done < "$EVENTS_FILE"
        success "Events: ${evt_count} imported, ${evt_skipped} skipped (duplicates)"
        total_imported=$((total_imported + evt_count))
    fi

    # 2. Import daemon-state.json
    if [[ -f "$DAEMON_STATE_FILE" ]]; then
        info "Importing daemon state from ${DAEMON_STATE_FILE}..."
        local job_count=0

        # Import completed jobs
        while IFS= read -r job; do
            [[ -z "$job" || "$job" == "null" ]] && continue
            local j_issue j_result j_dur j_at
            j_issue=$(echo "$job" | jq -r '.issue // 0')
            j_result=$(echo "$job" | jq -r '.result // ""')
            j_dur=$(echo "$job" | jq -r '.duration // ""')
            j_at=$(echo "$job" | jq -r '.completed_at // ""')
            local j_id="migrated-${j_issue}-$(echo "$j_at" | tr -dc '0-9' | tail -c 10)"
            _db_exec "INSERT OR IGNORE INTO daemon_state (job_id, issue_number, status, result, duration, completed_at, started_at, updated_at) VALUES ('${j_id}', ${j_issue}, 'completed', '${j_result}', '${j_dur}', '${j_at}', '${j_at}', '$(now_iso)');" 2>/dev/null && job_count=$((job_count + 1))
        done < <(jq -c '.completed[]' "$DAEMON_STATE_FILE" 2>/dev/null)

        success "Daemon state: ${job_count} completed jobs imported"
        total_imported=$((total_imported + job_count))
    fi

    # 3. Import costs.json
    if [[ -f "$COST_FILE_JSON" ]]; then
        info "Importing costs from ${COST_FILE_JSON}..."
        local cost_count=0
        while IFS= read -r entry; do
            [[ -z "$entry" || "$entry" == "null" ]] && continue
            local c_input c_output c_model c_stage c_issue c_cost c_ts c_epoch
            c_input=$(echo "$entry" | jq -r '.input_tokens // 0')
            c_output=$(echo "$entry" | jq -r '.output_tokens // 0')
            c_model=$(echo "$entry" | jq -r '.model // "sonnet"')
            c_stage=$(echo "$entry" | jq -r '.stage // "unknown"')
            c_issue=$(echo "$entry" | jq -r '.issue // ""')
            c_cost=$(echo "$entry" | jq -r '.cost_usd // 0')
            c_ts=$(echo "$entry" | jq -r '.ts // ""')
            c_epoch=$(echo "$entry" | jq -r '.ts_epoch // 0')
            _db_exec "INSERT INTO cost_entries (input_tokens, output_tokens, model, stage, issue, cost_usd, ts, ts_epoch, synced) VALUES (${c_input}, ${c_output}, '${c_model}', '${c_stage}', '${c_issue}', ${c_cost}, '${c_ts}', ${c_epoch}, 0);" 2>/dev/null && cost_count=$((cost_count + 1))
        done < <(jq -c '.entries[]' "$COST_FILE_JSON" 2>/dev/null)

        success "Costs: ${cost_count} entries imported"
        total_imported=$((total_imported + cost_count))
    fi

    # 4. Import budget.json
    if [[ -f "$BUDGET_FILE_JSON" ]]; then
        info "Importing budget from ${BUDGET_FILE_JSON}..."
        local b_amount b_enabled
        b_amount=$(jq -r '.daily_budget_usd // 0' "$BUDGET_FILE_JSON" 2>/dev/null || echo "0")
        b_enabled=$(jq -r '.enabled // false' "$BUDGET_FILE_JSON" 2>/dev/null || echo "false")
        local b_flag=0
        [[ "$b_enabled" == "true" ]] && b_flag=1
        _db_exec "INSERT OR REPLACE INTO budgets (id, daily_budget_usd, enabled, updated_at) VALUES (1, ${b_amount}, ${b_flag}, '$(now_iso)');" && success "Budget: imported (\$${b_amount}, enabled=${b_enabled})"
    fi

    # 5. Import heartbeats/*.json
    if [[ -d "$HEARTBEAT_DIR" ]]; then
        info "Importing heartbeats..."
        local hb_count=0
        for hb_file in "${HEARTBEAT_DIR}"/*.json; do
            [[ -f "$hb_file" ]] || continue
            local hb_job hb_pid hb_issue hb_stage hb_iter hb_activity hb_mem hb_updated
            hb_job="$(basename "$hb_file" .json)"
            hb_pid=$(jq -r '.pid // 0' "$hb_file" 2>/dev/null || echo "0")
            hb_issue=$(jq -r '.issue // 0' "$hb_file" 2>/dev/null || echo "0")
            hb_stage=$(jq -r '.stage // ""' "$hb_file" 2>/dev/null || echo "")
            hb_iter=$(jq -r '.iteration // 0' "$hb_file" 2>/dev/null || echo "0")
            hb_activity=$(jq -r '.last_activity // ""' "$hb_file" 2>/dev/null || echo "")
            hb_mem=$(jq -r '.memory_mb // 0' "$hb_file" 2>/dev/null || echo "0")
            hb_updated=$(jq -r '.updated_at // ""' "$hb_file" 2>/dev/null || echo "$(now_iso)")

            hb_activity="${hb_activity//\'/\'\'}"
            _db_exec "INSERT OR REPLACE INTO heartbeats (job_id, pid, issue, stage, iteration, last_activity, memory_mb, updated_at) VALUES ('${hb_job}', ${hb_pid}, ${hb_issue}, '${hb_stage}', ${hb_iter}, '${hb_activity}', ${hb_mem}, '${hb_updated}');" 2>/dev/null && hb_count=$((hb_count + 1))
        done
        success "Heartbeats: ${hb_count} imported"
        total_imported=$((total_imported + hb_count))
    fi

    echo ""
    success "Migration complete: ${total_imported} total records imported"

    # Verify counts
    echo ""
    info "Verification:"
    local db_events db_costs db_hb
    db_events=$(_db_query "SELECT COUNT(*) FROM events;" || echo "0")
    db_costs=$(_db_query "SELECT COUNT(*) FROM cost_entries;" || echo "0")
    db_hb=$(_db_query "SELECT COUNT(*) FROM heartbeats;" || echo "0")
    echo "  Events in DB:     ${db_events}"
    echo "  Cost entries:     ${db_costs}"
    echo "  Heartbeats:       ${db_hb}"
}

# ═══════════════════════════════════════════════════════════════════════════
# Export / Status / Cleanup
# ═══════════════════════════════════════════════════════════════════════════

export_db() {
    local output_file="${1:-${DB_DIR}/shipwright-backup.json}"

    if ! check_sqlite3; then
        warn "Cannot export — sqlite3 not available"
        return 1
    fi

    info "Exporting database to ${output_file}..."

    local events_json runs_json costs_json
    events_json=$(_db_query "SELECT json_group_array(json_object('ts', ts, 'type', type, 'job_id', job_id, 'stage', stage, 'status', status)) FROM (SELECT * FROM events ORDER BY ts_epoch DESC LIMIT 1000);" || echo "[]")
    runs_json=$(_db_query "SELECT json_group_array(json_object('job_id', job_id, 'goal', goal, 'status', status, 'template', template, 'started_at', started_at)) FROM (SELECT * FROM pipeline_runs ORDER BY created_at DESC LIMIT 500);" || echo "[]")
    costs_json=$(_db_query "SELECT json_group_array(json_object('model', model, 'stage', stage, 'cost_usd', cost_usd, 'ts', ts)) FROM (SELECT * FROM cost_entries ORDER BY ts_epoch DESC LIMIT 1000);" || echo "[]")

    local tmp_file
    tmp_file=$(mktemp "${output_file}.tmp.XXXXXX")
    jq -n \
        --arg exported_at "$(now_iso)" \
        --argjson events "$events_json" \
        --argjson pipeline_runs "$runs_json" \
        --argjson cost_entries "$costs_json" \
        '{exported_at: $exported_at, events: $events, pipeline_runs: $pipeline_runs, cost_entries: $cost_entries}' \
        > "$tmp_file" && mv "$tmp_file" "$output_file" || { rm -f "$tmp_file"; return 1; }

    success "Database exported to ${output_file}"
}

import_db() {
    local input_file="$1"

    if [[ ! -f "$input_file" ]]; then
        error "File not found: ${input_file}"
        return 1
    fi

    if ! check_sqlite3; then
        warn "Cannot import — sqlite3 not available"
        return 1
    fi

    info "Importing data from ${input_file}..."
    warn "Full JSON import not yet implemented — use 'shipwright db migrate' to import from state files"
}

show_status() {
    if ! check_sqlite3; then
        warn "sqlite3 not available"
        echo ""
        echo "Fallback: Reading from JSON files..."
        [[ -f "$EVENTS_FILE" ]] && echo "  Events: $(wc -l < "$EVENTS_FILE") records"
        [[ -f "$DAEMON_STATE_FILE" ]] && echo "  Pipeline state: $(jq '.active_jobs | length' "$DAEMON_STATE_FILE" 2>/dev/null || echo '?')"
        return 0
    fi

    if [[ ! -f "$DB_FILE" ]]; then
        warn "Database not initialized. Run: shipwright db init"
        return 1
    fi

    echo ""
    echo -e "${BOLD}SQLite Database Status${RESET}"
    echo -e "${DIM}Database: ${DB_FILE}${RESET}"
    echo ""

    # WAL mode check
    local journal_mode
    journal_mode=$(_db_query "PRAGMA journal_mode;" || echo "unknown")
    echo -e "${DIM}Journal mode: ${journal_mode}${RESET}"

    # Schema version
    local schema_v
    schema_v=$(_db_query "SELECT COALESCE(MAX(version), 0) FROM _schema;" || echo "0")
    echo -e "${DIM}Schema version: ${schema_v}${RESET}"

    # DB file size
    local db_size
    if [[ -f "$DB_FILE" ]]; then
        db_size=$(ls -lh "$DB_FILE" 2>/dev/null | awk '{print $5}')
        echo -e "${DIM}File size: ${db_size}${RESET}"
    fi
    echo ""

    local event_count pipeline_count stage_count daemon_count cost_count hb_count failure_count
    event_count=$(_db_query "SELECT COUNT(*) FROM events;" || echo "0")
    pipeline_count=$(_db_query "SELECT COUNT(*) FROM pipeline_runs;" || echo "0")
    stage_count=$(_db_query "SELECT COUNT(*) FROM pipeline_stages;" || echo "0")
    daemon_count=$(_db_query "SELECT COUNT(*) FROM daemon_state;" || echo "0")
    cost_count=$(_db_query "SELECT COUNT(*) FROM cost_entries;" || echo "0")
    hb_count=$(_db_query "SELECT COUNT(*) FROM heartbeats;" || echo "0")
    failure_count=$(_db_query "SELECT COUNT(*) FROM memory_failures;" || echo "0")

    echo -e "${CYAN}Events${RESET}            ${event_count} records"
    echo -e "${CYAN}Pipeline Runs${RESET}     ${pipeline_count} records"
    echo -e "${CYAN}Pipeline Stages${RESET}   ${stage_count} records"
    echo -e "${CYAN}Daemon Jobs${RESET}       ${daemon_count} records"
    echo -e "${CYAN}Cost Entries${RESET}      ${cost_count} records"
    echo -e "${CYAN}Heartbeats${RESET}        ${hb_count} records"
    echo -e "${CYAN}Failure Patterns${RESET}  ${failure_count} records"

    # Sync status
    local device_id last_push last_pull
    device_id=$(_db_query "SELECT value FROM _sync_metadata WHERE key = 'device_id';" || echo "not set")
    last_push=$(_db_query "SELECT value FROM _sync_metadata WHERE key = 'last_push_epoch';" || echo "never")
    last_pull=$(_db_query "SELECT value FROM _sync_metadata WHERE key = 'last_pull_epoch';" || echo "never")
    local unsynced_events unsynced_costs
    unsynced_events=$(_db_query "SELECT COUNT(*) FROM events WHERE synced = 0;" || echo "0")
    unsynced_costs=$(_db_query "SELECT COUNT(*) FROM cost_entries WHERE synced = 0;" || echo "0")

    echo ""
    echo -e "${BOLD}Sync${RESET}"
    echo -e "  Device:           ${DIM}${device_id}${RESET}"
    echo -e "  Unsynced events:  ${unsynced_events}"
    echo -e "  Unsynced costs:   ${unsynced_costs}"
    if [[ -f "$SYNC_CONFIG_FILE" ]]; then
        local sync_url
        sync_url=$(jq -r '.url // "not configured"' "$SYNC_CONFIG_FILE" 2>/dev/null || echo "not configured")
        echo -e "  Remote:           ${DIM}${sync_url}${RESET}"
    else
        echo -e "  Remote:           ${DIM}not configured${RESET}"
    fi

    echo ""
    echo -e "${BOLD}Recent Runs${RESET}"
    sqlite3 -header -column "$DB_FILE" "SELECT job_id, goal, status, template, datetime(started_at) as started FROM pipeline_runs ORDER BY created_at DESC LIMIT 5;" 2>/dev/null || echo "  (none)"
}

cleanup_old_data() {
    local days="${1:-30}"

    if ! check_sqlite3; then
        warn "Cannot cleanup — sqlite3 not available"
        return 1
    fi

    local cutoff_epoch
    cutoff_epoch=$(( $(now_epoch) - (days * 86400) ))
    local cutoff_date
    cutoff_date=$(date -u -r "$cutoff_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                 date -u -d "@${cutoff_epoch}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                 date -u +"%Y-%m-%dT%H:%M:%SZ")

    info "Cleaning records older than ${days} days (before ${cutoff_date})..."

    local d_events d_costs d_daemon d_stages
    _db_exec "DELETE FROM events WHERE ts < '${cutoff_date}';"
    d_events=$(_db_query "SELECT changes();" || echo "0")
    _db_exec "DELETE FROM cost_entries WHERE ts < '${cutoff_date}';"
    d_costs=$(_db_query "SELECT changes();" || echo "0")
    _db_exec "DELETE FROM daemon_state WHERE updated_at < '${cutoff_date}' AND status != 'active';"
    d_daemon=$(_db_query "SELECT changes();" || echo "0")
    _db_exec "DELETE FROM pipeline_stages WHERE created_at < '${cutoff_date}';"
    d_stages=$(_db_query "SELECT changes();" || echo "0")

    success "Deleted: ${d_events} events, ${d_costs} costs, ${d_daemon} daemon jobs, ${d_stages} stages"

    # VACUUM to reclaim space
    _db_exec "VACUUM;" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# Health Check (used by sw-doctor.sh)
# ═══════════════════════════════════════════════════════════════════════════

db_health_check() {
    local pass=0 fail=0

    # sqlite3 binary
    if check_sqlite3; then
        echo -e "  ${GREEN}${BOLD}✓${RESET} sqlite3 available"
        pass=$((pass + 1))
    else
        echo -e "  ${RED}${BOLD}✗${RESET} sqlite3 not installed"
        fail=$((fail + 1))
        echo "    ${pass} passed, ${fail} failed"
        return $fail
    fi

    # DB file exists
    if [[ -f "$DB_FILE" ]]; then
        echo -e "  ${GREEN}${BOLD}✓${RESET} Database file exists: ${DB_FILE}"
        pass=$((pass + 1))
    else
        echo -e "  ${YELLOW}${BOLD}⚠${RESET} Database not initialized — run: shipwright db init"
        fail=$((fail + 1))
        echo "    ${pass} passed, ${fail} failed"
        return $fail
    fi

    # Schema version
    local sv
    sv=$(_db_query "SELECT COALESCE(MAX(version), 0) FROM _schema;" || echo "0")
    if [[ "$sv" -ge "$SCHEMA_VERSION" ]]; then
        echo -e "  ${GREEN}${BOLD}✓${RESET} Schema version: v${sv}"
        pass=$((pass + 1))
    else
        echo -e "  ${YELLOW}${BOLD}⚠${RESET} Schema version: v${sv} (expected v${SCHEMA_VERSION}) — run: shipwright db migrate"
        fail=$((fail + 1))
    fi

    # WAL mode
    local jm
    jm=$(_db_query "PRAGMA journal_mode;" || echo "unknown")
    if [[ "$jm" == "wal" ]]; then
        echo -e "  ${GREEN}${BOLD}✓${RESET} WAL mode enabled"
        pass=$((pass + 1))
    else
        echo -e "  ${YELLOW}${BOLD}⚠${RESET} Journal mode: ${jm} (WAL recommended) — run: shipwright db init"
        fail=$((fail + 1))
    fi

    # Integrity check
    local integrity
    integrity=$(_db_query "PRAGMA integrity_check;" || echo "error")
    if [[ "$integrity" == "ok" ]]; then
        echo -e "  ${GREEN}${BOLD}✓${RESET} Integrity check passed"
        pass=$((pass + 1))
    else
        echo -e "  ${RED}${BOLD}✗${RESET} Integrity check failed: ${integrity}"
        fail=$((fail + 1))
    fi

    echo "    ${pass} passed, ${fail} failed"
    return $fail
}

# ─── Show Help ──────────────────────────────────────────────────────────────
show_help() {
    echo -e "${CYAN}${BOLD}shipwright db${RESET} — SQLite Persistence Layer"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  shipwright db <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}init${RESET}                Initialize database schema (creates DB, enables WAL)"
    echo -e "  ${CYAN}migrate${RESET}             Apply schema migrations + import JSON state files"
    echo -e "  ${CYAN}status${RESET}              Show database stats, sync status, recent runs"
    echo -e "  ${CYAN}query${RESET} [status]      Query pipeline runs by status"
    echo -e "  ${CYAN}export${RESET} [file]       Export database to JSON backup"
    echo -e "  ${CYAN}import${RESET} <file>       Import data from JSON backup"
    echo -e "  ${CYAN}cleanup${RESET} [days]      Delete records older than N days (default 30)"
    echo -e "  ${CYAN}health${RESET}              Run database health checks"
    echo -e "  ${CYAN}sync push${RESET}           Push unsynced data to remote"
    echo -e "  ${CYAN}sync pull${RESET}           Pull new data from remote"
    echo -e "  ${CYAN}help${RESET}                Show this help"
    echo ""
    echo -e "${DIM}Examples:${RESET}"
    echo -e "  shipwright db init"
    echo -e "  shipwright db migrate       # Import events.jsonl, costs.json, etc."
    echo -e "  shipwright db status"
    echo -e "  shipwright db query failed"
    echo -e "  shipwright db health"
    echo -e "  shipwright db sync push"
    echo -e "  shipwright db cleanup 60"
}

# ─── Main Router ────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        init)
            ensure_db_dir
            init_schema
            # Set schema version
            _db_exec "INSERT OR REPLACE INTO _schema (version, created_at, applied_at) VALUES (${SCHEMA_VERSION}, '$(now_iso)', '$(now_iso)');" 2>/dev/null || true
            _db_exec "INSERT OR IGNORE INTO _sync_metadata (key, value, updated_at) VALUES ('device_id', '$(uname -n)-$$-$(now_epoch)', '$(now_iso)');" 2>/dev/null || true
            success "Database initialized at ${DB_FILE} (WAL mode, schema v${SCHEMA_VERSION})"
            ;;
        migrate)
            migrate_json_data
            ;;
        status)
            show_status
            ;;
        query)
            local status="${1:-}"
            query_runs "$status"
            ;;
        export)
            local file="${1:-${DB_DIR}/shipwright-backup.json}"
            export_db "$file"
            ;;
        import)
            local file="${1:-}"
            if [[ -z "$file" ]]; then
                error "Please provide a file to import"
                exit 1
            fi
            import_db "$file"
            ;;
        cleanup)
            local days="${1:-30}"
            cleanup_old_data "$days"
            ;;
        health)
            db_health_check
            ;;
        sync)
            local sync_cmd="${1:-help}"
            shift 2>/dev/null || true
            case "$sync_cmd" in
                push) db_sync_push ;;
                pull) db_sync_pull ;;
                *)    echo "Usage: shipwright db sync {push|pull}"; exit 1 ;;
            esac
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
