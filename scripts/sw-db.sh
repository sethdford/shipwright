#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright db — SQLite Persistence Layer                                ║
# ║  Façade + CLI; implementation in lib/db-{schema,migrate,query}.sh        ║
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

# shellcheck disable=SC2034
VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
# ─── Modules ─────────────────────────────────────────────────────────────────
# lib/db-schema.sh   config, connection helpers, init_schema
# lib/db-migrate.sh  migrate_schema, migrate_json_data
# lib/db-query.sh    db_* query functions, add_event, pipeline-run functions
# Module guards are cleared so a re-source (after _SW_DB_LOADED="") reloads
# config against the current HOME.
_SW_DB_SCHEMA_LOADED=""
_SW_DB_MIGRATE_LOADED=""
_SW_DB_QUERY_LOADED=""
_sw_db_missing=""
# shellcheck source=lib/db-schema.sh
if [[ -f "$SCRIPT_DIR/lib/db-schema.sh" ]]; then source "$SCRIPT_DIR/lib/db-schema.sh"; else _sw_db_missing="${_sw_db_missing} db-schema.sh"; fi
# shellcheck source=lib/db-migrate.sh
if [[ -f "$SCRIPT_DIR/lib/db-migrate.sh" ]]; then source "$SCRIPT_DIR/lib/db-migrate.sh"; else _sw_db_missing="${_sw_db_missing} db-migrate.sh"; fi
# shellcheck source=lib/db-query.sh
if [[ -f "$SCRIPT_DIR/lib/db-query.sh" ]]; then source "$SCRIPT_DIR/lib/db-query.sh"; else _sw_db_missing="${_sw_db_missing} db-query.sh"; fi

# Missing module: degrade to "no database" instead of failing callers under set -e.
# Readers that some callers invoke unchecked return an empty JSON array.
if [[ -n "$_sw_db_missing" ]]; then
    error "sw-db: missing module(s) in $SCRIPT_DIR/lib:${_sw_db_missing} — database disabled"
    unset _sw_db_missing
    db_available() { return 1; }
    check_sqlite3() { return 1; }
    [[ "$(type -t db_query_events 2>/dev/null)" == "function" ]]       || db_query_events() { echo "[]"; }
    [[ "$(type -t db_query_events_since 2>/dev/null)" == "function" ]] || db_query_events_since() { echo "[]"; }
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
        exit 1
    fi
    return 0 2>/dev/null || true
fi
unset _sw_db_missing

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
    # shellcheck disable=SC2089
    [[ -n "${SYNC_TOKEN:-}" ]] && auth_header="-H 'Authorization: Bearer ${SYNC_TOKEN}'"

    # shellcheck disable=SC2090
    response=$(curl -s --connect-timeout 10 --max-time 30 -w "%{http_code}" -o /dev/null \
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
    # shellcheck disable=SC2089
    [[ -n "${SYNC_TOKEN:-}" ]] && auth_header="-H 'Authorization: Bearer ${SYNC_TOKEN}'"

    local response_body
    # shellcheck disable=SC2090
    response_body=$(curl -s --connect-timeout 10 --max-time 30 \
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
    tmp_file=$(mktemp "${output_file}.tmp.XXXXXX") || { error "mktemp failed for db export"; return 1; }
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
    # shellcheck disable=SC2034
    last_push=$(_db_query "SELECT value FROM _sync_metadata WHERE key = 'last_push_epoch';" || echo "never")
    # shellcheck disable=SC2034
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
            if ! _db_exec "INSERT OR REPLACE INTO _schema (version, created_at, applied_at) VALUES (${SCHEMA_VERSION}, '$(now_iso)', '$(now_iso)');" 2>/dev/null; then
                warn "db init: failed to write schema version ${SCHEMA_VERSION}" >&2
            fi
            if ! _db_exec "INSERT OR IGNORE INTO _sync_metadata (key, value, updated_at) VALUES ('device_id', '$(uname -n)-$$-$(now_epoch)', '$(now_iso)');" 2>/dev/null; then
                warn "db init: failed to write device_id metadata" >&2
            fi
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
