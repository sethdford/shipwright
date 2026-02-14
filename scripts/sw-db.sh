#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright db — SQLite Persistence Layer                                ║
# ║  Store events, runs, developers, sessions, and metrics in SQLite          ║
# ║  Backward compatible: reads JSON if SQLite unavailable                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.10.0"
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
SCHEMA_VERSION=1

# JSON fallback paths
EVENTS_FILE="${DB_DIR}/events.jsonl"
DAEMON_STATE_FILE="${DB_DIR}/daemon-state.json"
DEVELOPER_REGISTRY_FILE="${DB_DIR}/developer-registry.json"

# ─── Check Prerequisites ─────────────────────────────────────────────────────
check_sqlite3() {
    if ! command -v sqlite3 &>/dev/null; then
        warn "sqlite3 not found. Install with: brew install sqlite (macOS) or apt install sqlite3 (Ubuntu)"
        return 1
    fi
    return 0
}

# ─── Ensure Database Directory ──────────────────────────────────────────────
ensure_db_dir() {
    mkdir -p "$DB_DIR"
}

# ─── Initialize Database Schema ──────────────────────────────────────────────
init_schema() {
    ensure_db_dir

    if ! check_sqlite3; then
        warn "Skipping SQLite initialization — sqlite3 not available"
        return 0
    fi

    sqlite3 "$DB_FILE" <<'EOF'
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

-- Create indexes for common queries
CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
CREATE INDEX IF NOT EXISTS idx_events_job_id ON events(job_id);
CREATE INDEX IF NOT EXISTS idx_events_ts_epoch ON events(ts_epoch DESC);
CREATE INDEX IF NOT EXISTS idx_pipeline_runs_job_id ON pipeline_runs(job_id);
CREATE INDEX IF NOT EXISTS idx_pipeline_runs_status ON pipeline_runs(status);
CREATE INDEX IF NOT EXISTS idx_pipeline_runs_created ON pipeline_runs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pipeline_stages_job_id ON pipeline_stages(job_id);
CREATE INDEX IF NOT EXISTS idx_developers_name ON developers(name);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
CREATE INDEX IF NOT EXISTS idx_metrics_job_id ON metrics(job_id);
CREATE INDEX IF NOT EXISTS idx_metrics_type ON metrics(metric_type);
EOF
}

# ─── Migrate Database ────────────────────────────────────────────────────────
migrate_schema() {
    if ! check_sqlite3; then
        warn "Skipping migration — sqlite3 not available"
        return 0
    fi

    local current_version
    current_version=$(sqlite3 "$DB_FILE" "SELECT COALESCE(MAX(version), 0) FROM _schema;" 2>/dev/null || echo 0)

    if [[ "$current_version" -eq 0 ]]; then
        # First run: initialize schema version
        init_schema
        sqlite3 "$DB_FILE" "INSERT INTO _schema (version, created_at, applied_at) VALUES (${SCHEMA_VERSION}, '$(now_iso)', '$(now_iso)');"
        success "Database schema initialized (v${SCHEMA_VERSION})"
    else
        info "Database already at schema v${current_version}"
    fi
}

# ─── Add Event (SQLite + JSONL for backward compat) ──────────────────────────
add_event() {
    local event_type="$1"
    local job_id="${2:-}"
    local stage="${3:-}"
    local status="${4:-}"
    local duration_secs="${5:-0}"
    local metadata="${6:-}"

    local ts
    ts="$(now_iso)"
    local ts_epoch
    ts_epoch="$(now_epoch)"

    # Try SQLite first, fallback to JSONL
    if check_sqlite3; then
        sqlite3 "$DB_FILE" <<EOF || true
INSERT OR IGNORE INTO events
  (ts, ts_epoch, type, job_id, stage, status, duration_secs, metadata, created_at)
VALUES
  ('${ts}', ${ts_epoch}, '${event_type}', '${job_id}', '${stage}', '${status}', ${duration_secs}, '${metadata}', '${ts}');
EOF
    fi

    # Always write to JSONL for backward compat
    mkdir -p "$DB_DIR"
    local json_record
    json_record="{\"ts\":\"${ts}\",\"ts_epoch\":${ts_epoch},\"type\":\"${event_type}\""
    [[ -n "$job_id" ]] && json_record="${json_record},\"job_id\":\"${job_id}\""
    [[ -n "$stage" ]] && json_record="${json_record},\"stage\":\"${stage}\""
    [[ -n "$status" ]] && json_record="${json_record},\"status\":\"${status}\""
    [[ "$duration_secs" -gt 0 ]] && json_record="${json_record},\"duration_secs\":${duration_secs}"
    [[ -n "$metadata" ]] && json_record="${json_record},\"metadata\":${metadata}"
    json_record="${json_record}}"
    echo "$json_record" >> "$EVENTS_FILE"
}

# ─── Add Pipeline Run ────────────────────────────────────────────────────────
add_pipeline_run() {
    local job_id="$1"
    local issue_number="${2:-0}"
    local goal="${3:-}"
    local branch="${4:-}"
    local template="${5:-standard}"

    if ! check_sqlite3; then
        warn "Skipping pipeline run insert — sqlite3 not available"
        return 1
    fi

    local ts
    ts="$(now_iso)"

    sqlite3 "$DB_FILE" <<EOF || return 1
INSERT INTO pipeline_runs
  (job_id, issue_number, goal, branch, status, template, started_at, created_at)
VALUES
  ('${job_id}', ${issue_number}, '${goal}', '${branch}', 'pending', '${template}', '${ts}', '${ts}');
EOF
}

# ─── Update Pipeline Run Status ──────────────────────────────────────────────
update_pipeline_status() {
    local job_id="$1"
    local status="$2"
    local stage_name="${3:-}"
    local stage_status="${4:-}"
    local duration_secs="${5:-0}"

    if ! check_sqlite3; then
        return 1
    fi

    local ts
    ts="$(now_iso)"

    sqlite3 "$DB_FILE" <<EOF || return 1
UPDATE pipeline_runs
SET
  status = '${status}',
  stage_name = '${stage_name}',
  stage_status = '${stage_status}',
  duration_secs = ${duration_secs},
  completed_at = CASE WHEN '${status}' = 'completed' OR '${status}' = 'failed' THEN '${ts}' ELSE completed_at END
WHERE job_id = '${job_id}';
EOF
}

# ─── Record Pipeline Stage ──────────────────────────────────────────────────
record_stage() {
    local job_id="$1"
    local stage_name="$2"
    local status="$3"
    local duration_secs="${4:-0}"
    local error_msg="${5:-}"

    if ! check_sqlite3; then
        return 1
    fi

    local ts
    ts="$(now_iso)"

    sqlite3 "$DB_FILE" <<EOF || return 1
INSERT INTO pipeline_stages
  (job_id, stage_name, status, started_at, completed_at, duration_secs, error_message, created_at)
VALUES
  ('${job_id}', '${stage_name}', '${status}', '${ts}', '${ts}', ${duration_secs}, '${error_msg}', '${ts}');
EOF
}

# ─── Query Pipeline Runs ─────────────────────────────────────────────────────
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

# ─── Export Database to JSON ─────────────────────────────────────────────────
export_db() {
    local output_file="${1:-${DB_DIR}/shipwright-backup.json}"

    if ! check_sqlite3; then
        warn "Cannot export — sqlite3 not available"
        return 1
    fi

    info "Exporting database to ${output_file}..."

    local tmp_file
    tmp_file=$(mktemp)

    {
        echo "{"
        echo "  \"exported_at\": \"$(now_iso)\","
        echo "  \"events\": ["

        sqlite3 -json "$DB_FILE" "SELECT * FROM events ORDER BY ts_epoch DESC LIMIT 1000;" | sed '1s/\[//' | sed '$s/\]//' >> "$tmp_file"

        echo "  ],"
        echo "  \"pipeline_runs\": ["

        sqlite3 -json "$DB_FILE" "SELECT * FROM pipeline_runs ORDER BY created_at DESC LIMIT 500;" | sed '1s/\[//' | sed '$s/\]//' >> "$tmp_file"

        echo "  ],"
        echo "  \"developers\": ["

        sqlite3 -json "$DB_FILE" "SELECT * FROM developers;" | sed '1s/\[//' | sed '$s/\]//' >> "$tmp_file"

        echo "  ]"
        echo "}"
    } > "$output_file"

    success "Database exported to ${output_file}"
}

# ─── Import Data from JSON ──────────────────────────────────────────────────
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

    # This is a simplified import; a full implementation would parse JSON and insert each record
    warn "Full JSON import not yet implemented — copy database file manually or use CLI commands to rebuild"
}

# ─── Show Database Status ────────────────────────────────────────────────────
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

    local event_count pipeline_count stage_count developer_count session_count metric_count
    event_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM events;" 2>/dev/null || echo "0")
    pipeline_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM pipeline_runs;" 2>/dev/null || echo "0")
    stage_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM pipeline_stages;" 2>/dev/null || echo "0")
    developer_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM developers;" 2>/dev/null || echo "0")
    session_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "0")
    metric_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM metrics;" 2>/dev/null || echo "0")

    echo -e "${CYAN}Events${RESET}          ${event_count} records"
    echo -e "${CYAN}Pipeline Runs${RESET}   ${pipeline_count} records"
    echo -e "${CYAN}Pipeline Stages${RESET} ${stage_count} records"
    echo -e "${CYAN}Developers${RESET}      ${developer_count} records"
    echo -e "${CYAN}Sessions${RESET}        ${session_count} records"
    echo -e "${CYAN}Metrics${RESET}         ${metric_count} records"

    echo ""
    echo -e "${BOLD}Recent Runs${RESET}"
    sqlite3 -header -column "$DB_FILE" "SELECT job_id, goal, status, template, datetime(started_at) as started FROM pipeline_runs ORDER BY created_at DESC LIMIT 5;"
}

# ─── Clean Old Records ──────────────────────────────────────────────────────
cleanup_old_data() {
    local days="${1:-30}"

    if ! check_sqlite3; then
        warn "Cannot cleanup — sqlite3 not available"
        return 1
    fi

    local cutoff_date
    cutoff_date=$(date -u -d "-${days} days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                 date -u -v-${days}d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                 date -u +"%Y-%m-%dT%H:%M:%SZ")

    info "Cleaning records older than ${days} days (before ${cutoff_date})..."

    local deleted_events deleted_runs
    deleted_events=$(sqlite3 "$DB_FILE" "DELETE FROM events WHERE ts < '${cutoff_date}' RETURNING COUNT(*);" 2>/dev/null || echo "0")
    deleted_runs=$(sqlite3 "$DB_FILE" "DELETE FROM pipeline_runs WHERE created_at < '${cutoff_date}' RETURNING COUNT(*);" 2>/dev/null || echo "0")

    success "Deleted ${deleted_events} old events and ${deleted_runs} old pipeline runs"
}

# ─── Show Help ──────────────────────────────────────────────────────────────
show_help() {
    echo -e "${CYAN}${BOLD}shipwright db${RESET} — SQLite Persistence Layer"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  shipwright db <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}init${RESET}                Initialize database schema"
    echo -e "  ${CYAN}migrate${RESET}             Apply schema migrations"
    echo -e "  ${CYAN}status${RESET}              Show database stats and recent runs"
    echo -e "  ${CYAN}query${RESET} [status]      Query pipeline runs by status"
    echo -e "  ${CYAN}export${RESET} [file]       Export database to JSON backup"
    echo -e "  ${CYAN}import${RESET} <file>       Import data from JSON backup"
    echo -e "  ${CYAN}cleanup${RESET} [days]      Delete records older than N days (default 30)"
    echo -e "  ${CYAN}help${RESET}                Show this help"
    echo ""
    echo -e "${DIM}Examples:${RESET}"
    echo -e "  shipwright db init"
    echo -e "  shipwright db status"
    echo -e "  shipwright db query failed"
    echo -e "  shipwright db export ~/backups/db-backup.json"
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
            success "Database initialized at ${DB_FILE}"
            ;;
        migrate)
            migrate_schema
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
