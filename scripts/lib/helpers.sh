#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   shipwright shared helpers — Colors, output, events, timestamps
#   Source this from any script: source "$SCRIPT_DIR/lib/helpers.sh"
# ═══════════════════════════════════════════════════════════════════
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
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}
