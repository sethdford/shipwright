# db-query.sh — Event, daemon, cost, heartbeat, memory and pipeline-run queries (for sw-db.sh)
# Source via sw-db.sh. Depends on lib/db-schema.sh (loaded on demand below).
[[ -n "${_SW_DB_QUERY_LOADED:-}" ]] && return 0
_SW_DB_QUERY_LOADED=1

# shellcheck source=db-schema.sh
[[ "$(type -t _db_exec 2>/dev/null)" == "function" ]] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/db-schema.sh"

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

# ═══════════════════════════════════════════════════════════════════════════
# Event Query Functions (dual-read: SQLite preferred, JSONL fallback)
# ═══════════════════════════════════════════════════════════════════════════

# db_query_events [filter] [limit] — Query events, SQLite when available else JSONL
# Output: JSON array of events. Uses duration_secs AS duration_s for compat.
db_query_events() {
    local filter="${1:-}"
    local limit="${2:-5000}"
    local db_file="${DB_FILE:-$HOME/.shipwright/shipwright.db}"

    if [[ -f "$db_file" ]] && command -v sqlite3 &>/dev/null; then
        local where_clause=""
        if [[ -n "$filter" ]]; then
            filter="${filter//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
            where_clause="WHERE type = '$filter'"
        fi
        local result
        result=$(sqlite3 -json "$db_file" "SELECT ts, ts_epoch, type, job_id, stage, status, duration_secs, metadata FROM events $where_clause ORDER BY ts_epoch DESC LIMIT $limit" 2>/dev/null) || true
        if [[ -n "$result" ]]; then
            echo "$result" | jq -c '
                map(. + {duration_s: (.duration_secs // 0), result: (.result // .status)} + ((.metadata | if type == "string" then (fromjson? // {}) else {} end) // {}))
                | map(del(.duration_secs, .metadata))
            ' 2>/dev/null || echo "$result"
            return 0
        fi
    fi

    # Fallback to JSONL
    local events_file="${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}"
    [[ ! -f "$events_file" ]] && echo "[]" && return 0
    if [[ -n "$filter" ]]; then
        grep -F "\"type\":\"$filter\"" "$events_file" 2>/dev/null | tail -n "$limit" | jq -s '.' 2>/dev/null || echo "[]"
    else
        tail -n "$limit" "$events_file" | jq -s '.' 2>/dev/null || echo "[]"
    fi
}

# db_query_events_since <since_epoch> [event_type] [to_epoch] — Events in time range
# Output: JSON array. SQLite when available else JSONL.
db_query_events_since() {
    local since_epoch="$1"
    local event_type="${2:-}"
    local to_epoch="${3:-}"
    # Validate numeric epoch values
    [[ ! "$since_epoch" =~ ^[0-9]+$ ]] && { echo "[]"; return 0; }
    local db_file="${DB_FILE:-$HOME/.shipwright/shipwright.db}"

    if [[ -f "$db_file" ]] && command -v sqlite3 &>/dev/null; then
        local type_filter=""
        if [[ -n "$event_type" ]]; then
            event_type="${event_type//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
            type_filter="AND type = '$event_type'"
        fi
        local to_filter=""
        # Numeric validation for epoch values
        [[ -n "$to_epoch" && "$to_epoch" =~ ^[0-9]+$ ]] && to_filter="AND ts_epoch <= $to_epoch"
        local result
        result=$(sqlite3 -json "$db_file" "SELECT ts, ts_epoch, type, job_id, stage, status, duration_secs, metadata FROM events WHERE ts_epoch >= $since_epoch $type_filter $to_filter ORDER BY ts_epoch DESC" 2>/dev/null) || true
        if [[ -n "$result" ]]; then
            echo "$result" | jq -c '
                map(. + {duration_s: (.duration_secs // 0), result: (.result // .status)} + ((.metadata | if type == "string" then (fromjson? // {}) else {} end) // {}))
                | map(del(.duration_secs, .metadata))
            ' 2>/dev/null || echo "$result"
            return 0
        fi
    fi

    # JSONL fallback (DB not available or query failed)
    local events_file="${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}"
    [[ ! -f "$events_file" ]] && echo "[]" && return 0
    local to=${to_epoch:-9999999999}
    if [[ -n "$event_type" ]]; then
        grep '^{' "$events_file" 2>/dev/null | jq -s --argjson from "$since_epoch" --argjson to "$to" --arg t "$event_type" '
            map(select(. != null and .ts_epoch != null)) |
            map(select(.ts_epoch >= $from and .ts_epoch <= $to and .type == $t))
        ' 2>/dev/null || echo "[]"
    else
        grep '^{' "$events_file" 2>/dev/null | jq -s --argjson from "$since_epoch" --argjson to "$to" '
            map(select(. != null and .ts_epoch != null)) |
            map(select(.ts_epoch >= $from and .ts_epoch <= $to))
        ' 2>/dev/null || echo "[]"
    fi
}

# db_get_consumer_offset <consumer_id> — returns last_event_id or "0"
db_get_consumer_offset() {
    local consumer_id="$1"
    consumer_id="${consumer_id//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    _db_query "SELECT last_event_id FROM event_consumers WHERE consumer_id = '${consumer_id}';" 2>/dev/null || echo "0"
}

# db_set_consumer_offset <consumer_id> <last_event_id>
db_set_consumer_offset() {
    local consumer_id="$1"
    local last_event_id="$2"
    consumer_id="${consumer_id//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    _db_exec "INSERT OR REPLACE INTO event_consumers (consumer_id, last_event_id, last_consumed_at) VALUES ('${consumer_id}', ${last_event_id}, '$(now_iso)');"
}

# db_save_checkpoint <workflow_id> <data> — durable workflow checkpoint
db_save_checkpoint() {
    local workflow_id="$1"
    local data="$2"
    workflow_id="${workflow_id//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    data="${data//$'\n'/ }"
    data="${data//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    if ! db_available; then return 1; fi
    _db_exec "INSERT OR REPLACE INTO durable_checkpoints (workflow_id, checkpoint_data, created_at) VALUES ('${workflow_id}', '${data}', '$(now_iso)');"
}

# db_load_checkpoint <workflow_id> — returns checkpoint_data or empty
db_load_checkpoint() {
    local workflow_id="$1"
    workflow_id="${workflow_id//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    if ! db_available; then return 1; fi
    _db_query "SELECT checkpoint_data FROM durable_checkpoints WHERE workflow_id = '${workflow_id}';" 2>/dev/null || echo ""
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
        if ! _db_exec "INSERT OR IGNORE INTO events (ts, ts_epoch, type, job_id, stage, status, duration_secs, metadata, created_at, synced) VALUES ('${ts}', ${ts_epoch}, '${event_type}', '${job_id}', '${stage}', '${status}', ${duration_secs}, '${metadata}', '${ts}', 0);" 2>/dev/null; then
            warn "db_add_event: SQLite insert failed for event type=${event_type}" >&2
        fi
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
    title="${title//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    goal="${goal//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"

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

    error_msg="${error_msg//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"

    _db_exec "UPDATE daemon_state SET status = 'completed', result = '${result}', duration = '${duration}', error_message = '${error_msg}', completed_at = '${ts}', updated_at = '${ts}' WHERE job_id = '${job_id}' AND status = 'active';"
}

# db_fail_job <job_id> [error_message]
db_fail_job() {
    local job_id="$1"
    local error_msg="${2:-}"
    local ts
    ts="$(now_iso)"

    if ! db_available; then return 1; fi

    error_msg="${error_msg//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"

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

# db_enqueue_issue <issue_key> — add to daemon queue
db_enqueue_issue() {
    local issue_key="$1"
    if ! db_available; then return 1; fi
    issue_key="${issue_key//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    _db_exec "INSERT OR REPLACE INTO daemon_queue (issue_key, added_at) VALUES ('${issue_key}', '$(now_iso)');"
}

# db_dequeue_next — returns first issue_key and removes it, empty if none
db_dequeue_next() {
    if ! db_available; then echo ""; return 0; fi
    local next escaped
    next=$(_db_query "SELECT issue_key FROM daemon_queue ORDER BY added_at ASC LIMIT 1;" || echo "")
    if [[ -n "$next" ]]; then
        escaped="${next//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
        if ! _db_exec "DELETE FROM daemon_queue WHERE issue_key = '${escaped}';" 2>/dev/null; then
            warn "db_dequeue_next: failed to delete queue entry for ${next}" >&2
        fi
        echo "$next"
    fi
}

# db_is_issue_queued <issue_key> — returns 0 if queued, 1 if not
db_is_issue_queued() {
    local issue_key="$1"
    if ! db_available; then return 1; fi
    issue_key="${issue_key//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    local count
    count=$(_db_query "SELECT COUNT(*) FROM daemon_queue WHERE issue_key = '${issue_key}';")
    [[ "${count:-0}" -gt 0 ]]
}

# db_remove_from_queue <issue_key> — remove specific key from queue
db_remove_from_queue() {
    local issue_key="$1"
    if ! db_available; then return 1; fi
    issue_key="${issue_key//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    _db_exec "DELETE FROM daemon_queue WHERE issue_key = '${issue_key}';"
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

# Record pipeline outcome for learning (Thompson sampling, optimize_tune_templates)
# db_record_outcome <job_id> [issue] [template] [success] [duration_secs] [retries] [cost_usd] [complexity]
db_record_outcome() {
    local job_id="$1" issue="${2:-}" template="${3:-}" success="${4:-1}"
    local duration="${5:-0}" retries="${6:-0}" cost="${7:-0}" complexity="${8:-medium}"

    if ! db_available; then return 1; fi

    job_id="${job_id//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    issue="${issue//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    template="${template//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"

    _db_exec "INSERT OR REPLACE INTO pipeline_outcomes
        (job_id, issue_number, template, success, duration_secs, retry_count, cost_usd, complexity, created_at)
        VALUES ('$job_id', '$issue', '$template', $success, $duration, $retries, $cost, '$complexity', '$(now_iso)');"
}

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

    activity="${activity//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"

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
    error_sig="${error_sig//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    root_cause="${root_cause//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    fix_desc="${fix_desc//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"

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

# Memory patterns
db_save_pattern() {
    local repo_hash="$1" pattern_type="$2" pattern_key="$3" description="${4:-}" metadata="${5:-}"
    if ! db_available; then return 1; fi
    description="${description//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    metadata="${metadata//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    _db_exec "INSERT INTO memory_patterns (repo_hash, pattern_type, pattern_key, description, last_seen_at, created_at, metadata)
              VALUES ('$repo_hash', '$pattern_type', '$pattern_key', '$description', '$(now_iso)', '$(now_iso)', '$metadata')
              ON CONFLICT(repo_hash, pattern_type, pattern_key) DO UPDATE SET
                frequency = frequency + 1, last_seen_at = '$(now_iso)', description = COALESCE(NULLIF('$description',''), description);"
}

db_query_patterns() {
    local repo_hash="$1" pattern_type="${2:-}" limit="${3:-20}"
    if ! db_available; then echo "[]"; return 0; fi
    repo_hash="${repo_hash//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    local where="WHERE repo_hash = '$repo_hash'"
    if [[ -n "$pattern_type" ]]; then
        pattern_type="${pattern_type//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
        where="$where AND pattern_type = '$pattern_type'"
    fi
    _db_query -json "SELECT * FROM memory_patterns $where ORDER BY frequency DESC, last_seen_at DESC LIMIT $limit;" || echo "[]"
}

# Memory decisions
db_save_decision() {
    local repo_hash="$1" decision_type="$2" context="$3" decision="$4" metadata="${5:-}"
    if ! db_available; then return 1; fi
    repo_hash="${repo_hash//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    decision_type="${decision_type//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    context="${context//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    decision="${decision//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    metadata="${metadata//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    _db_exec "INSERT INTO memory_decisions (repo_hash, decision_type, context, decision, created_at, updated_at, metadata)
              VALUES ('$repo_hash', '$decision_type', '$context', '$decision', '$(now_iso)', '$(now_iso)', '$metadata');"
}

db_update_decision_outcome() {
    local decision_id="$1" outcome="$2" confidence="${3:-}"
    if ! db_available; then return 1; fi
    # Validate numeric IDs to prevent injection
    [[ ! "$decision_id" =~ ^[0-9]+$ ]] && return 1
    outcome="${outcome//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    local set_clause
    set_clause="outcome = '$outcome', updated_at = '$(now_iso)'"
    [[ -n "$confidence" && "$confidence" =~ ^[0-9.]+$ ]] && set_clause="$set_clause, confidence = $confidence"
    _db_exec "UPDATE memory_decisions SET $set_clause WHERE id = $decision_id;"
}

db_query_decisions() {
    local repo_hash="$1" decision_type="${2:-}" limit="${3:-20}"
    if ! db_available; then echo "[]"; return 0; fi
    repo_hash="${repo_hash//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    local where="WHERE repo_hash = '$repo_hash'"
    if [[ -n "$decision_type" ]]; then
        decision_type="${decision_type//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
        where="$where AND decision_type = '$decision_type'"
    fi
    _db_query -json "SELECT * FROM memory_decisions $where ORDER BY updated_at DESC LIMIT $limit;" || echo "[]"
}

# Memory embeddings
db_save_embedding() {
    local content_hash="$1" source_type="$2" content_text="$3" repo_hash="${4:-}"
    if ! db_available; then return 1; fi
    content_hash="${content_hash//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    source_type="${source_type//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    content_text="${content_text//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    repo_hash="${repo_hash//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    _db_exec "INSERT OR IGNORE INTO memory_embeddings (content_hash, source_type, content_text, repo_hash, created_at)
              VALUES ('$content_hash', '$source_type', '$content_text', '$repo_hash', '$(now_iso)');"
}

db_query_embeddings() {
    local source_type="${1:-}" repo_hash="${2:-}" limit="${3:-50}"
    if ! db_available; then echo "[]"; return 0; fi
    local where="WHERE 1=1"
    if [[ -n "$source_type" ]]; then
        source_type="${source_type//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
        where="$where AND source_type = '$source_type'"
    fi
    if [[ -n "$repo_hash" ]]; then
        repo_hash="${repo_hash//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
        where="$where AND repo_hash = '$repo_hash'"
    fi
    _db_query -json "SELECT id, content_hash, source_type, content_text, repo_hash, created_at FROM memory_embeddings $where ORDER BY created_at DESC LIMIT $limit;" || echo "[]"
}

# Reasoning traces for multi-step autonomous pipelines
db_save_reasoning_trace() {
    local job_id="$1" step_name="$2" input_context="$3" reasoning="$4" output_decision="$5" confidence="${6:-0.5}"
    local escaped_input escaped_reasoning escaped_output
    escaped_input=$(echo "$input_context" | sed "s/'/''/g")
    escaped_reasoning=$(echo "$reasoning" | sed "s/'/''/g")
    escaped_output=$(echo "$output_decision" | sed "s/'/''/g")
    job_id="${job_id//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    step_name="${step_name//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    if ! db_available; then return 1; fi
    _db_exec "INSERT INTO reasoning_traces (job_id, step_name, input_context, reasoning, output_decision, confidence, created_at)
              VALUES ('$job_id', '$step_name', '$escaped_input', '$escaped_reasoning', '$escaped_output', $confidence, '$(now_iso)');"
}

db_query_reasoning_traces() {
    local job_id="$1"
    job_id="${job_id//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    if ! db_available; then echo "[]"; return 0; fi
    _db_query -json "SELECT * FROM reasoning_traces WHERE job_id = '$job_id' ORDER BY id ASC;" || echo "[]"
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
    goal="${goal//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"
    branch="${branch//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"

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
    error_msg="${error_msg//$_SQL_SQ/$_SQL_SQ$_SQL_SQ}"

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
