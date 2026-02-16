#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   shipwright shared helpers — Colors, output, events, timestamps
#   Source this from any script: source "$SCRIPT_DIR/lib/helpers.sh"
# ═══════════════════════════════════════════════════════════════════
#
# Exit code convention:
#   0 — success / nothing to do
#   1 — error (invalid args, missing deps, runtime failure)
#   2 — check condition failed (regressions found, quality below threshold, etc.)
#         Callers should distinguish: exit 1 = broken, exit 2 = check negative
#
# This is the canonical reference for common boilerplate that was
# previously duplicated across 18+ scripts. Existing scripts are NOT
# being modified to source this (too risky for a sweep), but all NEW
# scripts should source this instead of copy-pasting the boilerplate.
#
# Provides:
#   - Color definitions (respects NO_COLOR)
#   - Output helpers: info(), success(), warn(), error()
#   - Timestamp helpers: now_iso(), now_epoch()
#   - Event logging: emit_event()
#
# Usage in new scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/helpers.sh"
#   # Optional: source "$SCRIPT_DIR/lib/compat.sh" for platform helpers

# ─── Double-source guard ─────────────────────────────────────────
[[ -n "${_SW_HELPERS_LOADED:-}" ]] && return 0
_SW_HELPERS_LOADED=1

# ─── Colors (matches Seth's tmux theme) ──────────────────────────
if [[ -z "${NO_COLOR:-}" ]]; then
    CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
    PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
    BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
    GREEN='\033[38;2;74;222;128m'   # success
    YELLOW='\033[38;2;250;204;21m'  # warning
    RED='\033[38;2;248;113;113m'    # error
    DIM='\033[2m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    CYAN='' PURPLE='' BLUE='' GREEN='' YELLOW='' RED='' DIM='' BOLD='' RESET=''
fi

# ─── Output Helpers ──────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

# ─── Timestamp Helpers ───────────────────────────────────────────
now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Structured Event Log ────────────────────────────────────────
# Appends JSON events to ~/.shipwright/events.jsonl for metrics/traceability
EVENTS_FILE="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"

emit_event() {
    local event_type="$1"
    shift

    # Try SQLite first (via sw-db.sh's db_add_event)
    if type db_add_event &>/dev/null; then
        db_add_event "$event_type" "$@" 2>/dev/null || true
    fi

    # Always write to JSONL (dual-write period for backward compat)
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            val="${val//\"/\\\"}"
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    local _event_line="{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}"
    # Use flock to prevent concurrent write corruption
    local _lock_file="${EVENTS_FILE}.lock"
    (
        if command -v flock &>/dev/null; then
            flock -w 2 200 2>/dev/null || true
        fi
        echo "$_event_line" >> "$EVENTS_FILE"
    ) 200>"$_lock_file"
}

# Rotate a JSONL file to keep it within max_lines.
# Usage: rotate_jsonl <file> <max_lines>
# ─── Retry Helper ─────────────────────────────────────────────────
# Retries a command with exponential backoff for transient failures.
# Usage: with_retry <max_attempts> <command> [args...]
with_retry() {
    local max_attempts="${1:-3}"
    shift
    local attempt=1
    local delay=1
    while [[ "$attempt" -le "$max_attempts" ]]; do
        if "$@"; then
            return 0
        fi
        local exit_code=$?
        if [[ "$attempt" -lt "$max_attempts" ]]; then
            warn "Attempt $attempt/$max_attempts failed (exit $exit_code), retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
            [[ "$delay" -gt 30 ]] && delay=30
        fi
        attempt=$((attempt + 1))
    done
    error "All $max_attempts attempts failed"
    return 1
}

# ─── JSON Validation + Recovery ───────────────────────────────────
# Validates a JSON file and recovers from backup if corrupt.
# Usage: validate_json <file> [backup_suffix]
validate_json() {
    local file="$1"
    local backup_suffix="${2:-.bak}"
    [[ ! -f "$file" ]] && return 0

    if jq '.' "$file" >/dev/null 2>&1; then
        # Valid — create backup
        cp "$file" "${file}${backup_suffix}" 2>/dev/null || true
        return 0
    fi

    # Corrupt — try to recover from backup
    warn "Corrupt JSON detected: $file"
    if [[ -f "${file}${backup_suffix}" ]] && jq '.' "${file}${backup_suffix}" >/dev/null 2>&1; then
        cp "${file}${backup_suffix}" "$file"
        warn "Recovered from backup: ${file}${backup_suffix}"
        return 0
    fi

    error "No valid backup for $file — manual intervention needed"
    return 1
}

rotate_jsonl() {
    local file="$1"
    local max_lines="${2:-10000}"
    [[ ! -f "$file" ]] && return 0
    local current_lines
    current_lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    if [[ "$current_lines" -gt "$max_lines" ]]; then
        local tmp_rotate
        tmp_rotate=$(mktemp)
        tail -n "$max_lines" "$file" > "$tmp_rotate" && mv "$tmp_rotate" "$file" || rm -f "$tmp_rotate"
    fi
}

# ─── Project Identity ────────────────────────────────────────────
# Auto-detect GitHub owner/repo from git remote, with fallbacks
_sw_github_repo() {
    local remote_url
    remote_url="$(git remote get-url origin 2>/dev/null || echo "")"
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        echo "${SHIPWRIGHT_GITHUB_REPO:-sethdford/shipwright}"
    fi
}

_sw_github_owner() {
    local repo
    repo="$(_sw_github_repo)"
    echo "${repo%%/*}"
}

_sw_docs_url() {
    local owner
    owner="$(_sw_github_owner)"
    echo "${SHIPWRIGHT_DOCS_URL:-https://${owner}.github.io/shipwright}"
}

_sw_github_url() {
    local repo
    repo="$(_sw_github_repo)"
    echo "https://github.com/${repo}"
}
