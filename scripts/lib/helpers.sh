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
    if type db_add_event >/dev/null 2>&1; then
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
            val="${val//\\/\\\\}"       # escape backslashes first
            val="${val//\"/\\\"}"       # then quotes
            val="${val//$'\n'/\\n}"     # then newlines
            val="${val//$'\t'/\\t}"     # then tabs
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.shipwright" 2>/dev/null || true
    local _event_line="{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}"
    # Use flock to prevent concurrent write corruption
    # Lock file uses TMPDIR as fallback so sandbox-restricted envs don't block event logging
    local _lock_file
    if [[ -w "$(dirname "${EVENTS_FILE}")" ]] 2>/dev/null; then
        _lock_file="${EVENTS_FILE}.lock"
    else
        _lock_file="${TMPDIR:-/tmp}/sw-events-$$.lock"
    fi
    (
        if command -v flock >/dev/null 2>&1; then
            if ! flock -w 2 200 2>/dev/null; then
                echo "WARN: emit_event lock timeout — concurrent write possible" >&2
            fi
        fi
        echo "$_event_line" >> "$EVENTS_FILE"
    ) 200>"$_lock_file" 2>/dev/null || true

    # Schema validation — auto-detect config repo from BASH_SOURCE location
    local _schema_dir="${_CONFIG_REPO_DIR:-}"
    if [[ -z "$_schema_dir" ]]; then
        local _helpers_dir
        _helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || true
        if [[ -n "$_helpers_dir" && -f "${_helpers_dir}/../../config/event-schema.json" ]]; then
            _schema_dir="$(cd "${_helpers_dir}/../.." && pwd)"
        fi
    fi
    if [[ -n "$_schema_dir" && -f "${_schema_dir}/config/event-schema.json" ]]; then
        local known_types
        known_types=$(jq -r '.event_types | keys[]' "${_schema_dir}/config/event-schema.json" 2>/dev/null || true)
        if [[ -n "$known_types" ]] && ! echo "$known_types" | grep >/dev/null -x "$event_type"; then
            # Warn-only: never reject events, just log to stderr on first unknown type per session
            if [[ -z "${_SW_SCHEMA_WARNED:-}" ]]; then
                echo "WARN: Unknown event type '$event_type' — update config/event-schema.json" >&2
                _SW_SCHEMA_WARNED=1
            fi
        fi
    fi
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
        "$@" && return 0
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
        tmp_rotate=$(mktemp "${TMPDIR:-/tmp}/sw-rotate.XXXXXX") || return 0
        tail -n "$max_lines" "$file" > "$tmp_rotate" && mv "$tmp_rotate" "$file" || rm -f "$tmp_rotate"
    fi
}

# ─── Atomic Write Helpers ────────────────────────────────────────
# atomic_write: Write data to a file atomically (write to tmp, validate, mv)
# Usage: atomic_write <target_file> <data>
atomic_write() {
    local target="$1"
    local data="$2"

    [[ -z "$target" ]] && { error "atomic_write: target file not specified"; return 1; }

    local tmp
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1

    # Write to tmp file
    echo -n "$data" > "$tmp" || { rm -f "$tmp"; return 1; }

    # Atomically move into place
    mv "$tmp" "$target" || { rm -f "$tmp"; return 1; }

    return 0
}

# atomic_append: Append a line to a JSONL file atomically
# Usage: atomic_append <target_file> <json_line>
# Thread-safe via flock; validates line before appending
atomic_append() {
    local target="$1"
    local line="$2"

    [[ -z "$target" ]] && { error "atomic_append: target file not specified"; return 1; }
    [[ -z "$line" ]] && { error "atomic_append: line not specified"; return 1; }

    # Validate JSON line
    if ! echo "$line" | jq -e . >/dev/null 2>&1; then
        error "atomic_append: invalid JSON: $line"
        return 1
    fi

    local tmp lock_file
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
    lock_file="${target}.lock"

    (
        # Acquire exclusive lock with 5s timeout
        if ! flock -w 5 200 2>/dev/null; then
            error "atomic_append: failed to acquire lock on $target"
            return 1
        fi

        # Append to tmp file
        echo "$line" > "$tmp" || { rm -f "$tmp"; return 1; }

        # Append tmp to target (atomic cat)
        cat "$tmp" >> "$target" 2>/dev/null || { rm -f "$tmp"; return 1; }

        rm -f "$tmp"
        return 0
    ) 200>"$lock_file"
}

# ─── Tmpfile Tracking & Cleanup ──────────────────────────────────
# Registers a temp file for automatic cleanup on exit
# Usage: register_tmpfile <tmpfile_path>
# Set up trap handler: trap '_cleanup_tmpfiles' EXIT
_REGISTERED_TMPFILES=()

register_tmpfile() {
    local tmpfile="$1"
    [[ -z "$tmpfile" ]] && { error "register_tmpfile: path not specified"; return 1; }
    _REGISTERED_TMPFILES+=("$tmpfile")
}

# Cleanup all registered temp files
_cleanup_tmpfiles() {
    for f in "${_REGISTERED_TMPFILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
        [[ -d "$f" ]] && rm -rf "$f"
    done
}

# ─── Disk Space Check ───────────────────────────────────────────
# Validates minimum free disk space before critical writes
# Usage: check_disk_space <path> [min_mb]
check_disk_space() {
    local target_path="${1:-.}"
    local min_mb="${2:-100}"  # Default 100MB minimum

    # Get available space in KB
    local free_kb
    free_kb=$(df -k "$target_path" 2>/dev/null | tail -1 | awk '{print $4}')

    if [[ -z "$free_kb" ]] || [[ ! "$free_kb" =~ ^[0-9]+$ ]]; then
        warn "Could not determine free disk space — proceeding anyway"
        return 0
    fi

    local free_mb=$((free_kb / 1024))
    if [[ "$free_mb" -lt "$min_mb" ]]; then
        error "Insufficient disk space: ${free_mb}MB free, need ${min_mb}MB minimum"
        return 1
    fi

    return 0
}

# ─── GitHub API Retry Helper ────────────────────────────────────
# Retries gh CLI calls with exponential backoff on 403 (rate limit)
# Usage: gh_with_retry <max_attempts> gh issue view <args>
# Returns: command output on success, empty on failure
gh_with_retry() {
    local max_attempts="${1:-4}"
    shift
    local attempt=1
    local backoff_secs=30

    while [[ "$attempt" -le "$max_attempts" ]]; do
        # Execute gh command
        local output result
        output=$("$@" 2>&1)
        result=$?

        # Success
        if [[ "$result" -eq 0 ]]; then
            echo "$output"
            return 0
        fi

        # Check for rate limit (403) or API error
        if echo "$output" | grep >/dev/null -E "HTTP 403|API rate limit|rate limited|You have exceeded"; then
            if [[ "$attempt" -lt "$max_attempts" ]]; then
                warn "GitHub API rate limit detected — backing off ${backoff_secs}s (attempt $attempt/$max_attempts)"
                emit_event "github.rate_limited" "attempt=$attempt" "backoff=$backoff_secs"
                sleep "$backoff_secs"
                backoff_secs=$((backoff_secs * 2))
                [[ "$backoff_secs" -gt 300 ]] && backoff_secs=300
            fi
        else
            # Non-rate-limit error — fail immediately
            return "$result"
        fi

        attempt=$((attempt + 1))
    done

    # Exhausted all retries
    error "GitHub API call failed after $max_attempts attempts: ${output##*$'\n'}"
    emit_event "github.api_failed" "attempts=$max_attempts"
    return 1
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

# ─── Secret Sanitization ─────────────────────────────────────────────
# Redacts sensitive data from strings before logging
# Redacts: ANTHROPIC_API_KEY, GITHUB_TOKEN, sk-* patterns, Bearer tokens
sanitize_secrets() {
    local text="$1"
    # Redact ANTHROPIC_API_KEY=... (until whitespace or quote)
    text="$(echo "$text" | sed 's/ANTHROPIC_API_KEY=[^ "]*\|ANTHROPIC_API_KEY=[^ ]*/ANTHROPIC_API_KEY=***REDACTED***/g')"
    # Redact GITHUB_TOKEN=... (until whitespace or quote)
    text="$(echo "$text" | sed 's/GITHUB_TOKEN=[^ "]*\|GITHUB_TOKEN=[^ ]*/GITHUB_TOKEN=***REDACTED***/g')"
    # Redact sk-* patterns (Anthropic API key format)
    text="$(echo "$text" | sed 's/sk-[a-zA-Z0-9_-]*/sk-***REDACTED***/g')"
    # Redact Bearer tokens
    text="$(echo "$text" | sed 's/Bearer [a-zA-Z0-9_.-]*/Bearer ***REDACTED***/g')"
    # Redact oauth tokens (gh_...)
    text="$(echo "$text" | sed 's/gh_[a-zA-Z0-9_]*/gh_***REDACTED***/g')"
    echo "$text"
}

