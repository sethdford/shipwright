# db-migrate.sh — Schema migrations and JSON → SQLite import (for sw-db.sh)
# Source via sw-db.sh. Depends on lib/db-schema.sh (loaded on demand below).
[[ -n "${_SW_DB_MIGRATE_LOADED:-}" ]] && return 0
_SW_DB_MIGRATE_LOADED=1

# shellcheck source=db-schema.sh
[[ "$(type -t _db_exec 2>/dev/null)" == "function" ]] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/db-schema.sh"

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

    # Migration from v2 → v3: add memory_patterns, memory_decisions, memory_embeddings
    if [[ "$current_version" -lt 3 ]]; then
        info "Migrating schema v${current_version} → v3..."
        sqlite3 "$DB_FILE" "
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
CREATE INDEX IF NOT EXISTS idx_memory_patterns_repo ON memory_patterns(repo_hash);
CREATE INDEX IF NOT EXISTS idx_memory_patterns_type ON memory_patterns(pattern_type);
CREATE INDEX IF NOT EXISTS idx_memory_decisions_repo ON memory_decisions(repo_hash);
CREATE INDEX IF NOT EXISTS idx_memory_decisions_type ON memory_decisions(decision_type);
CREATE INDEX IF NOT EXISTS idx_memory_embeddings_hash ON memory_embeddings(content_hash);
CREATE INDEX IF NOT EXISTS idx_memory_embeddings_source ON memory_embeddings(source_type);
CREATE INDEX IF NOT EXISTS idx_memory_embeddings_repo ON memory_embeddings(repo_hash);
"
        _db_exec "INSERT OR REPLACE INTO _schema (version, created_at, applied_at) VALUES (3, '$(now_iso)', '$(now_iso)');"
        success "Migrated to schema v3"
    fi

    # Migration from v3 → v4: event_consumers, durable_checkpoints
    if [[ "$current_version" -lt 4 ]]; then
        info "Migrating schema v${current_version} → v4..."
        sqlite3 "$DB_FILE" "
CREATE TABLE IF NOT EXISTS event_consumers (
    consumer_id TEXT PRIMARY KEY,
    last_event_id INTEGER NOT NULL DEFAULT 0,
    last_consumed_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_event_consumers_id ON event_consumers(consumer_id);
CREATE TABLE IF NOT EXISTS durable_checkpoints (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workflow_id TEXT NOT NULL,
    checkpoint_data TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(workflow_id)
);
"
        _db_exec "INSERT OR REPLACE INTO _schema (version, created_at, applied_at) VALUES (4, '$(now_iso)', '$(now_iso)');"
        success "Migrated to schema v4"
    fi

    # Migration from v4 → v5: pipeline_outcomes, model_outcomes for outcome-based learning
    if [[ "$current_version" -lt 5 ]]; then
        info "Migrating schema v${current_version} → v5..."
        sqlite3 "$DB_FILE" "
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
"
        _db_exec "INSERT OR REPLACE INTO _schema (version, created_at, applied_at) VALUES (5, '$(now_iso)', '$(now_iso)');"
        success "Migrated to schema v5"
    fi

    # Migration from v5 → v6: reasoning_traces for multi-step autonomous reasoning
    if [[ "$current_version" -lt 6 ]]; then
        info "Migrating schema v${current_version} → v6..."
        sqlite3 "$DB_FILE" "
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
"
        _db_exec "INSERT OR REPLACE INTO _schema (version, created_at, applied_at) VALUES (6, '$(now_iso)', '$(now_iso)');"
        success "Migrated to schema v6"
    fi
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
        # shellcheck disable=SC2106
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
            local j_id
            j_id="migrated-${j_issue}-$(echo "$j_at" | tr -dc '0-9' | tail -c 10)"
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

            hb_activity="${hb_activity//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
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
