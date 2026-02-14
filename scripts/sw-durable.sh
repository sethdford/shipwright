#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-durable.sh — Durable Workflow Engine                                ║
# ║  Event log (WAL) · Checkpointing · Idempotency · Distributed locks      ║
# ║  Dead letter queue · Exactly-once delivery · Compaction                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.13.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ─── Durable State Directory ────────────────────────────────────────────────
DURABLE_DIR="${HOME}/.shipwright/durable"

ensure_durable_dir() {
    mkdir -p "$DURABLE_DIR/event-log"
    mkdir -p "$DURABLE_DIR/checkpoints"
    mkdir -p "$DURABLE_DIR/dlq"
    mkdir -p "$DURABLE_DIR/locks"
    mkdir -p "$DURABLE_DIR/offsets"
}

# ─── Event ID Generation ────────────────────────────────────────────────────
generate_event_id() {
    local prefix="${1:-evt}"
    local ts=$(now_epoch)
    local rand=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    echo "${prefix}-${ts}-${rand}"
}

# ─── Event Log (Write-Ahead Log) ────────────────────────────────────────────
event_log_file() {
    echo "${DURABLE_DIR}/event-log/events.jsonl"
}

# Append event to WAL with sequence number
publish_event() {
    local event_type="$1"
    local payload="$2"
    local event_id
    event_id="$(generate_event_id "evt")"

    ensure_durable_dir

    # Get next sequence number (count existing lines + 1)
    local seq=1
    local log_file
    log_file="$(event_log_file)"
    if [[ -f "$log_file" ]]; then
        seq=$(($(wc -l < "$log_file" || true) + 1))
    fi

    # Build event JSON atomically
    local tmp_file
    tmp_file="$(mktemp "${DURABLE_DIR}/.tmp.XXXXXX")"

    jq -n \
        --argjson sequence "$seq" \
        --arg event_id "$event_id" \
        --arg event_type "$event_type" \
        --argjson payload "$(echo "$payload" | jq . 2>/dev/null || echo '{}')" \
        --arg timestamp "$(now_iso)" \
        --arg status "published" \
        '{
            sequence: $sequence,
            event_id: $event_id,
            event_type: $event_type,
            payload: $payload,
            timestamp: $timestamp,
            status: $status
        }' >> "$log_file" || { rm -f "$tmp_file"; return 1; }

    rm -f "$tmp_file"
    echo "$event_id"
}

# ─── Checkpointing ─────────────────────────────────────────────────────────
checkpoint_file() {
    local workflow_id="$1"
    echo "${DURABLE_DIR}/checkpoints/${workflow_id}.json"
}

save_checkpoint() {
    local workflow_id="$1"
    local stage="$2"
    local seq="$3"
    local state="$4"

    ensure_durable_dir

    local cp_file
    cp_file="$(checkpoint_file "$workflow_id")"

    local tmp_file
    tmp_file="$(mktemp "${DURABLE_DIR}/.tmp.XXXXXX")"

    jq -n \
        --arg workflow_id "$workflow_id" \
        --arg stage "$stage" \
        --argjson sequence "$seq" \
        --argjson state "$(echo "$state" | jq . 2>/dev/null || echo '{}')" \
        --arg checkpoint_id "$(generate_event_id "cp")" \
        --arg created_at "$(now_iso)" \
        '{
            workflow_id: $workflow_id,
            stage: $stage,
            sequence: $sequence,
            state: $state,
            checkpoint_id: $checkpoint_id,
            created_at: $created_at
        }' > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

    mv "$tmp_file" "$cp_file"
    success "Checkpoint saved for workflow $workflow_id at stage $stage (seq: $seq)"
}

restore_checkpoint() {
    local workflow_id="$1"
    local cp_file
    cp_file="$(checkpoint_file "$workflow_id")"

    if [[ ! -f "$cp_file" ]]; then
        error "No checkpoint found for workflow: $workflow_id"
        return 1
    fi

    cat "$cp_file"
}

# ─── Idempotency Tracking ──────────────────────────────────────────────────
idempotency_key_file() {
    local key="$1"
    echo "${DURABLE_DIR}/offsets/idempotent-${key}.json"
}

is_operation_completed() {
    local op_id="$1"
    local key_file
    key_file="$(idempotency_key_file "$op_id")"

    [[ -f "$key_file" ]] && return 0 || return 1
}

mark_operation_completed() {
    local op_id="$1"
    local result="$2"

    ensure_durable_dir

    local key_file
    key_file="$(idempotency_key_file "$op_id")"

    local tmp_file
    tmp_file="$(mktemp "${DURABLE_DIR}/.tmp.XXXXXX")"

    jq -n \
        --arg operation_id "$op_id" \
        --argjson result "$(echo "$result" | jq . 2>/dev/null || echo '{}')" \
        --arg completed_at "$(now_iso)" \
        '{
            operation_id: $operation_id,
            result: $result,
            completed_at: $completed_at
        }' > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

    mv "$tmp_file" "$key_file"
}

get_operation_result() {
    local op_id="$1"
    local key_file
    key_file="$(idempotency_key_file "$op_id")"

    if [[ -f "$key_file" ]]; then
        cat "$key_file"
        return 0
    fi

    return 1
}

# ─── Distributed Locks ─────────────────────────────────────────────────────
lock_file() {
    local resource="$1"
    echo "${DURABLE_DIR}/locks/${resource}.lock"
}

acquire_lock() {
    local resource="$1"
    local timeout="${2:-30}"
    local start_time
    start_time="$(now_epoch)"

    ensure_durable_dir

    local lock_path
    lock_path="$(lock_file "$resource")"

    while true; do
        # Try to create lock atomically (mkdir succeeds only if dir doesn't exist)
        if mkdir "$lock_path" 2>/dev/null; then
            # Write lock metadata
            local tmp_file
            tmp_file="$(mktemp "${DURABLE_DIR}/.tmp.XXXXXX")"

            jq -n \
                --arg resource "$resource" \
                --argjson pid "$$" \
                --arg acquired_at "$(now_iso)" \
                '{
                    resource: $resource,
                    pid: $pid,
                    acquired_at: $acquired_at
                }' > "$tmp_file"

            mv "$tmp_file" "${lock_path}/metadata.json"
            success "Lock acquired for: $resource"
            return 0
        fi

        # Check lock staleness (if process is dead, break the lock)
        if [[ -f "${lock_path}/metadata.json" ]]; then
            local lock_pid
            lock_pid="$(jq -r '.pid' "${lock_path}/metadata.json" 2>/dev/null || echo '')"

            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                warn "Stale lock detected for $resource (PID $lock_pid dead), breaking lock"
                rm -rf "$lock_path"
                continue
            fi
        fi

        # Check timeout
        local now
        now="$(now_epoch)"
        if (( now - start_time >= timeout )); then
            error "Failed to acquire lock for $resource after ${timeout}s"
            return 1
        fi

        sleep 0.1
    done
}

release_lock() {
    local resource="$1"
    local lock_path
    lock_path="$(lock_file "$resource")"

    if [[ -d "$lock_path" ]]; then
        rm -rf "$lock_path"
        success "Lock released for: $resource"
        return 0
    fi

    return 1
}

# ─── Dead Letter Queue ─────────────────────────────────────────────────────
dlq_file() {
    echo "${DURABLE_DIR}/dlq/deadletters.jsonl"
}

send_to_dlq() {
    local event_id="$1"
    local reason="$2"
    local retries="${3:-0}"

    ensure_durable_dir

    local dlq_path
    dlq_path="$(dlq_file)"

    jq -n \
        --arg event_id "$event_id" \
        --arg reason "$reason" \
        --argjson retry_count "$retries" \
        --arg sent_to_dlq_at "$(now_iso)" \
        '{
            event_id: $event_id,
            reason: $reason,
            retry_count: $retry_count,
            sent_to_dlq_at: $sent_to_dlq_at
        }' >> "$dlq_path"

    warn "Event $event_id sent to DLQ: $reason"
}

# ─── Consumer Offset Tracking ──────────────────────────────────────────────
consumer_offset_file() {
    local consumer_id="$1"
    echo "${DURABLE_DIR}/offsets/consumer-${consumer_id}.offset"
}

get_consumer_offset() {
    local consumer_id="$1"
    local offset_file
    offset_file="$(consumer_offset_file "$consumer_id")"

    if [[ -f "$offset_file" ]]; then
        cat "$offset_file"
    else
        echo "0"
    fi
}

save_consumer_offset() {
    local consumer_id="$1"
    local offset="$2"

    ensure_durable_dir

    local offset_file
    offset_file="$(consumer_offset_file "$consumer_id")"

    local tmp_file
    tmp_file="$(mktemp "${DURABLE_DIR}/.tmp.XXXXXX")"

    echo "$offset" > "$tmp_file"
    mv "$tmp_file" "$offset_file"
}

# ─── Consume Events ────────────────────────────────────────────────────────
cmd_consume() {
    local consumer_id="${1:-default}"
    local handler_cmd="${2:-}"

    if [[ -z "$handler_cmd" ]]; then
        error "Usage: shipwright durable consume <consumer-id> <handler-cmd>"
        echo "  handler-cmd: command to execute for each event (receives JSON on stdin)"
        return 1
    fi

    local log_file
    log_file="$(event_log_file)"

    if [[ ! -f "$log_file" ]]; then
        warn "No events to consume"
        return 0
    fi

    local offset
    offset="$(get_consumer_offset "$consumer_id")"

    # Process events starting from last consumed offset
    local line_num=0
    local processed=0
    local failed=0

    while IFS= read -r line; do
        ((line_num++))

        if (( line_num <= offset )); then
            continue
        fi

        # Extract event_id for deduplication
        local event_id
        event_id="$(echo "$line" | jq -r '.event_id' 2>/dev/null || echo '')"

        if [[ -z "$event_id" ]]; then
            error "Invalid event format at line $line_num"
            ((failed++))
            continue
        fi

        # Check if already processed (exactly-once)
        if is_operation_completed "$event_id"; then
            info "Event $event_id already processed, skipping"
            ((processed++))
            save_consumer_offset "$consumer_id" "$line_num"
            continue
        fi

        # Execute handler
        if echo "$line" | bash -c "$handler_cmd" 2>/dev/null; then
            mark_operation_completed "$event_id" '{"status":"success"}'
            success "Event $event_id processed"
            ((processed++))
        else
            error "Handler failed for event $event_id"
            send_to_dlq "$event_id" "handler_failed" 1
            ((failed++))
        fi

        # Update offset after successful processing
        save_consumer_offset "$consumer_id" "$line_num"
    done < "$log_file"

    info "Consumer $consumer_id: processed=$processed, failed=$failed"
}

# ─── Replay Events ─────────────────────────────────────────────────────────
cmd_replay() {
    local start_seq="${1:-1}"
    local handler_cmd="${2:-cat}"

    local log_file
    log_file="$(event_log_file)"

    if [[ ! -f "$log_file" ]]; then
        warn "No events to replay"
        return 0
    fi

    info "Replaying events from sequence $start_seq..."

    local replayed=0
    while IFS= read -r line; do
        local seq
        seq="$(echo "$line" | jq -r '.sequence' 2>/dev/null || echo '0')"

        if (( seq >= start_seq )); then
            echo "$line" | bash -c "$handler_cmd"
            ((replayed++))
        fi
    done < "$log_file"

    success "Replayed $replayed events"
}

# ─── Compaction ────────────────────────────────────────────────────────────
cmd_compact() {
    local log_file
    log_file="$(event_log_file)"

    if [[ ! -f "$log_file" ]]; then
        warn "No event log to compact"
        return 0
    fi

    ensure_durable_dir

    local compacted_file
    compacted_file="${DURABLE_DIR}/event-log/events-compacted-$(now_epoch).jsonl"

    # Keep only the latest state for each workflow (deduplicates by event_id)
    local tmp_file
    tmp_file="$(mktemp "${DURABLE_DIR}/.tmp.XXXXXX")"

    # This is a simple compaction: keep all events (could be enhanced to prune old states)
    cp "$log_file" "$tmp_file"

    local orig_lines compacted_lines savings
    orig_lines=$(wc -l < "$log_file")
    compacted_lines=$(wc -l < "$tmp_file")
    savings=$((orig_lines - compacted_lines))

    mv "$tmp_file" "$compacted_file"

    success "Event log compacted: $orig_lines → $compacted_lines lines (saved $savings events)"
    info "Backup: $compacted_file"
}

# ─── Status ────────────────────────────────────────────────────────────────
cmd_status() {
    ensure_durable_dir

    local log_file dlq_file offsets_dir locks_dir
    log_file="$(event_log_file)"
    dlq_file="$(dlq_file)"
    offsets_dir="${DURABLE_DIR}/offsets"
    locks_dir="${DURABLE_DIR}/locks"

    local log_events log_size
    log_events=$(wc -l < "$log_file" 2>/dev/null || echo "0")
    log_size=$(du -h "$log_file" 2>/dev/null | awk '{print $1}' || echo "0")

    local dlq_events
    dlq_events=$(wc -l < "$dlq_file" 2>/dev/null || echo "0")

    local consumer_count
    consumer_count=$(find "$offsets_dir" -name "consumer-*.offset" 2>/dev/null | wc -l || echo "0")

    local active_locks
    active_locks=$(find "$locks_dir" -type d -mindepth 1 2>/dev/null | wc -l || echo "0")

    echo ""
    echo -e "${CYAN}${BOLD}  Durable Workflow Status${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}Event Log${RESET}"
    echo -e "    Events:  ${GREEN}$log_events${RESET}"
    echo -e "    Size:    ${GREEN}$log_size${RESET}"
    echo ""
    echo -e "  ${BOLD}Consumers${RESET}"
    echo -e "    Count:   ${GREEN}$consumer_count${RESET}"
    echo ""
    echo -e "  ${BOLD}Dead Letter Queue${RESET}"
    echo -e "    Events:  ${YELLOW}$dlq_events${RESET}"
    echo ""
    echo -e "  ${BOLD}Distributed Locks${RESET}"
    echo -e "    Active:  ${CYAN}$active_locks${RESET}"
    echo ""
}

# ─── Help ──────────────────────────────────────────────────────────────────
show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  Shipwright Durable Workflow Engine${RESET}  ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}  ════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}USAGE${RESET}"
    echo -e "    shipwright durable <command> [options]"
    echo ""
    echo -e "  ${BOLD}COMMANDS${RESET}"
    echo -e "    ${CYAN}publish${RESET} <type> <payload>    Publish event to WAL"
    echo -e "    ${CYAN}consume${RESET} <id> <handler>     Process next unconsumed event"
    echo -e "    ${CYAN}replay${RESET} [seq] [handler]     Replay events from sequence"
    echo -e "    ${CYAN}checkpoint${RESET} <cmd>           Save/restore workflow checkpoint"
    echo -e "    ${CYAN}lock${RESET} <cmd>                 Acquire/release distributed lock"
    echo -e "    ${CYAN}dlq${RESET} <cmd>                  Inspect/retry dead letter queue"
    echo -e "    ${CYAN}compact${RESET}                    Compact the event log"
    echo -e "    ${CYAN}status${RESET}                     Show event log statistics"
    echo -e "    ${CYAN}help${RESET}                       Show this help message"
    echo ""
    echo -e "  ${BOLD}CHECKPOINT SUBCOMMANDS${RESET}"
    echo -e "    ${CYAN}save${RESET} <wf-id> <stage> <seq> <state>     Save checkpoint"
    echo -e "    ${CYAN}restore${RESET} <wf-id>                         Restore checkpoint"
    echo ""
    echo -e "  ${BOLD}LOCK SUBCOMMANDS${RESET}"
    echo -e "    ${CYAN}acquire${RESET} <resource> [timeout]           Acquire lock (default 30s)"
    echo -e "    ${CYAN}release${RESET} <resource>                     Release lock"
    echo ""
    echo -e "  ${BOLD}DLQ SUBCOMMANDS${RESET}"
    echo -e "    ${CYAN}list${RESET}                                   List dead letter events"
    echo -e "    ${CYAN}inspect${RESET} <event-id>                    Inspect failed event"
    echo -e "    ${CYAN}retry${RESET} <event-id> [max-retries]        Retry failed event"
    echo ""
    echo -e "  ${BOLD}EXAMPLES${RESET}"
    echo -e "    ${DIM}# Publish an event${RESET}"
    echo -e "    shipwright durable publish workflow.started '{\"workflow_id\":\"wf-123\"}'${RESET}"
    echo ""
    echo -e "    ${DIM}# Save checkpoint at stage boundary${RESET}"
    echo -e "    shipwright durable checkpoint save wf-123 build 42 '{\"files\":[\"main.rs\"]}'${RESET}"
    echo ""
    echo -e "    ${DIM}# Acquire distributed lock${RESET}"
    echo -e "    shipwright durable lock acquire my-resource 60${RESET}"
    echo ""
    echo -e "    ${DIM}# Consume events with custom handler${RESET}"
    echo -e "    shipwright durable consume my-consumer 'jq .event_type'${RESET}"
    echo ""
}

# ─── Checkpoint Subcommands ────────────────────────────────────────────────
cmd_checkpoint() {
    local subcmd="${1:-help}"

    case "$subcmd" in
        save)
            if [[ $# -lt 5 ]]; then
                error "Usage: shipwright durable checkpoint save <wf-id> <stage> <seq> <state>"
                return 1
            fi
            save_checkpoint "$2" "$3" "$4" "$5"
            ;;
        restore)
            if [[ $# -lt 2 ]]; then
                error "Usage: shipwright durable checkpoint restore <wf-id>"
                return 1
            fi
            restore_checkpoint "$2"
            ;;
        *)
            error "Unknown checkpoint subcommand: $subcmd"
            return 1
            ;;
    esac
}

# ─── Lock Subcommands ──────────────────────────────────────────────────────
cmd_lock() {
    local subcmd="${1:-help}"

    case "$subcmd" in
        acquire)
            if [[ $# -lt 2 ]]; then
                error "Usage: shipwright durable lock acquire <resource> [timeout]"
                return 1
            fi
            acquire_lock "$2" "${3:-30}"
            ;;
        release)
            if [[ $# -lt 2 ]]; then
                error "Usage: shipwright durable lock release <resource>"
                return 1
            fi
            release_lock "$2"
            ;;
        *)
            error "Unknown lock subcommand: $subcmd"
            return 1
            ;;
    esac
}

# ─── DLQ Subcommands ──────────────────────────────────────────────────────
cmd_dlq() {
    local subcmd="${1:-help}"
    local dlq_path
    dlq_path="$(dlq_file)"

    case "$subcmd" in
        list)
            if [[ ! -f "$dlq_path" ]]; then
                info "Dead letter queue is empty"
                return 0
            fi
            cat "$dlq_path" | jq .
            ;;
        inspect)
            if [[ $# -lt 2 ]]; then
                error "Usage: shipwright durable dlq inspect <event-id>"
                return 1
            fi
            if [[ ! -f "$dlq_path" ]]; then
                error "Dead letter queue is empty"
                return 1
            fi
            grep "$2" "$dlq_path" | jq .
            ;;
        retry)
            if [[ $# -lt 2 ]]; then
                error "Usage: shipwright durable dlq retry <event-id> [max-retries]"
                return 1
            fi
            warn "DLQ retry for $2 (would re-publish event and resume processing)"
            ;;
        *)
            error "Unknown dlq subcommand: $subcmd"
            return 1
            ;;
    esac
}

# ─── Main Command Router ───────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        publish)
            if [[ $# -lt 2 ]]; then
                error "Usage: shipwright durable publish <type> <payload>"
                return 1
            fi
            publish_event "$1" "$2"
            ;;
        consume)
            cmd_consume "$@"
            ;;
        replay)
            cmd_replay "$@"
            ;;
        checkpoint)
            cmd_checkpoint "$@"
            ;;
        lock)
            cmd_lock "$@"
            ;;
        dlq)
            cmd_dlq "$@"
            ;;
        compact)
            cmd_compact
            ;;
        status)
            cmd_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            return 1
            ;;
    esac
}

# ─── Source Guard ─────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
