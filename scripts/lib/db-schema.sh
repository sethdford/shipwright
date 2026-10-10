# db-schema.sh — Configuration, connection primitives and DDL (for sw-db.sh)
# Source via sw-db.sh. Depends on nothing; defines helper fallbacks when
# lib/helpers.sh is not loaded. Used by lib/db-migrate.sh and lib/db-query.sh.
[[ -n "${_SW_DB_SCHEMA_LOADED:-}" ]] && return 0
_SW_DB_SCHEMA_LOADED=1

# Fallbacks when neither helpers.sh nor sw-db.sh defined these (module sourced directly)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi

# ─── Database Configuration ──────────────────────────────────────────────────
DB_DIR="${HOME}/.shipwright"
DB_FILE="${DB_DIR}/shipwright.db"
SCHEMA_VERSION=6

# JSON fallback paths
EVENTS_FILE="${DB_DIR}/events.jsonl"
DAEMON_STATE_FILE="${DB_DIR}/daemon-state.json"
# shellcheck disable=SC2034
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
        if command -v sqlite3 >/dev/null 2>&1; then
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

# ─── SQL Escaping ──────────────────────────────────────────────────────────
# Bash 3.2 (macOS default) breaks ${var//$_SQL_SQ/$_SQL_SQ$_SQL_SQ} — backslashes leak into output.
# This helper uses a variable to hold the single quote for reliable escaping.
_SQL_SQ="'"
_sql_escape() { local _v="$1"; echo "${_v//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"; }

# ─── Ensure Database Directory ──────────────────────────────────────────────
ensure_db_dir() {
    mkdir -p "$DB_DIR"
}

# ─── SQL Execution Helper ──────────────────────────────────────────────────
# Runs SQL with proper error handling. Silent on success.
_db_exec() {
    sqlite3 -cmd ".timeout 5000" "$DB_FILE" "$@" 2>/dev/null
}

# Runs SQL and returns output. Returns 1 on failure.
_db_query() {
    sqlite3 -cmd ".timeout 5000" "$DB_FILE" "$@" 2>/dev/null || return 1
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

-- Daemon queue (issue keys waiting for a slot)
CREATE TABLE IF NOT EXISTS daemon_queue (
    issue_key TEXT PRIMARY KEY,
    added_at TEXT NOT NULL
);

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

-- Memory: patterns (replaces memory/*/patterns.json)
CREATE TABLE IF NOT EXISTS memory_patterns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    repo_hash TEXT NOT NULL,
    pattern_type TEXT NOT NULL,
    pattern_key TEXT NOT NULL,
    description TEXT,
    frequency INTEGER DEFAULT 1,
    confidence REAL DEFAULT 0.5,
    last_seen_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    metadata TEXT,
    synced INTEGER DEFAULT 0,
    UNIQUE(repo_hash, pattern_type, pattern_key)
);

-- Memory: decisions (replaces memory/*/decisions.json)
CREATE TABLE IF NOT EXISTS memory_decisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    repo_hash TEXT NOT NULL,
    decision_type TEXT NOT NULL,
    context TEXT NOT NULL,
    decision TEXT NOT NULL,
    outcome TEXT,
    confidence REAL DEFAULT 0.5,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    metadata TEXT,
    synced INTEGER DEFAULT 0
);

-- Memory: embeddings for semantic search
CREATE TABLE IF NOT EXISTS memory_embeddings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content_hash TEXT UNIQUE NOT NULL,
    source_type TEXT NOT NULL,
    source_id INTEGER,
    content_text TEXT NOT NULL,
    embedding BLOB,
    repo_hash TEXT,
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
CREATE INDEX IF NOT EXISTS idx_daemon_queue_added ON daemon_queue(added_at);
CREATE INDEX IF NOT EXISTS idx_daemon_state_status ON daemon_state(status);
CREATE INDEX IF NOT EXISTS idx_daemon_state_job ON daemon_state(job_id);
CREATE INDEX IF NOT EXISTS idx_cost_entries_epoch ON cost_entries(ts_epoch DESC);
CREATE INDEX IF NOT EXISTS idx_cost_entries_synced ON cost_entries(synced) WHERE synced = 0;
CREATE INDEX IF NOT EXISTS idx_heartbeats_job ON heartbeats(job_id);
CREATE INDEX IF NOT EXISTS idx_memory_failures_repo ON memory_failures(repo_hash);
CREATE INDEX IF NOT EXISTS idx_memory_failures_class ON memory_failures(failure_class);
CREATE INDEX IF NOT EXISTS idx_memory_patterns_repo ON memory_patterns(repo_hash);
CREATE INDEX IF NOT EXISTS idx_memory_patterns_type ON memory_patterns(pattern_type);
CREATE INDEX IF NOT EXISTS idx_memory_decisions_repo ON memory_decisions(repo_hash);
CREATE INDEX IF NOT EXISTS idx_memory_decisions_type ON memory_decisions(decision_type);
CREATE INDEX IF NOT EXISTS idx_memory_embeddings_hash ON memory_embeddings(content_hash);
CREATE INDEX IF NOT EXISTS idx_memory_embeddings_source ON memory_embeddings(source_type);
CREATE INDEX IF NOT EXISTS idx_memory_embeddings_repo ON memory_embeddings(repo_hash);
CREATE INDEX IF NOT EXISTS idx_sync_log_unsynced ON _sync_log(synced) WHERE synced = 0;

-- Event consumer offset tracking
CREATE TABLE IF NOT EXISTS event_consumers (
    consumer_id TEXT PRIMARY KEY,
    last_event_id INTEGER NOT NULL DEFAULT 0,
    last_consumed_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_event_consumers_id ON event_consumers(consumer_id);

-- Outcome-based learning (Thompson sampling, UCB1)
CREATE TABLE IF NOT EXISTS pipeline_outcomes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id TEXT UNIQUE NOT NULL,
    issue_number TEXT,
    template TEXT,
    success INTEGER NOT NULL DEFAULT 0,
    duration_secs INTEGER DEFAULT 0,
    retry_count INTEGER DEFAULT 0,
    cost_usd REAL DEFAULT 0,
    complexity TEXT DEFAULT 'medium',
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS model_outcomes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    model TEXT NOT NULL,
    stage TEXT NOT NULL,
    success INTEGER NOT NULL DEFAULT 0,
    duration_secs INTEGER DEFAULT 0,
    cost_usd REAL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pipeline_outcomes_template ON pipeline_outcomes(template);
CREATE INDEX IF NOT EXISTS idx_pipeline_outcomes_complexity ON pipeline_outcomes(complexity);
CREATE INDEX IF NOT EXISTS idx_model_outcomes_model_stage ON model_outcomes(model, stage);

-- Durable workflow checkpoints
CREATE TABLE IF NOT EXISTS durable_checkpoints (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workflow_id TEXT NOT NULL,
    checkpoint_data TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(workflow_id)
);

-- Reasoning traces for multi-step autonomous pipelines
CREATE TABLE IF NOT EXISTS reasoning_traces (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id TEXT NOT NULL,
    step_name TEXT NOT NULL,
    input_context TEXT,
    reasoning TEXT,
    output_decision TEXT,
    confidence REAL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (job_id) REFERENCES pipeline_runs(job_id)
);
CREATE INDEX IF NOT EXISTS idx_reasoning_traces_job ON reasoning_traces(job_id);
SCHEMA
}
