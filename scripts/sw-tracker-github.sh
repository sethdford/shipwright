#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tracker: GitHub Provider                                     ║
# ║  Sourced by sw-tracker.sh — do not call directly                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# This file is sourced by sw-tracker.sh.
# It defines provider_* functions used by the tracker router.
# Do NOT add set -euo pipefail or a main() function here.

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
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
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
CYAN="${CYAN:-\033[38;2;0;212;255m}"
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"
BLUE="${BLUE:-\033[38;2;0;102;255m}"
GREEN="${GREEN:-\033[38;2;74;222;128m}"
YELLOW="${YELLOW:-\033[38;2;250;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
RESET="${RESET:-\033[0m}"

# ─── Discovery & CRUD Interface ────────────────────────────────────────────
# All functions output normalized JSON (or plain text where specified).
# Input: normalized arguments (label, state, issue_id, etc.)
# Output: JSON matching common schema across all providers

# Discover issues from GitHub using gh CLI
# Input: label, state, limit
# Output: JSON array of {id, title, labels[], state, body}
provider_discover_issues() {
    local label="$1"
    local state="${2:-open}"
    local limit="${3:-50}"

    # Check $NO_GITHUB env var
    [[ "${NO_GITHUB:-}" == "1" ]] && return 0

    local gh_args=()
    gh_args+=(issue list)
    gh_args+=(--state "$state")
    gh_args+=(--limit "$limit")

    if [[ -n "$label" ]]; then
        gh_args+=(--label "$label")
    fi

    # Fetch as JSON: number, title, labels, state
    gh_args+=(--json number,title,labels,state)

    local response
    response=$(gh "${gh_args[@]}" 2>/dev/null) || {
        echo "[]"
        return 0
    }

    # Normalize to {id, title, labels[], state}
    echo "$response" | jq '[.[] | {id: .number, title: .title, labels: [.labels[].name], state: .state}]' 2>/dev/null || echo "[]"
}

# Fetch single issue details
# Input: issue_id (number or identifier like "123" or "OWNER/REPO#123")
# Output: JSON {id, title, body, labels[], state}
provider_get_issue() {
    local issue_id="$1"

    [[ -z "$issue_id" ]] && return 1
    [[ "${NO_GITHUB:-}" == "1" ]] && return 0

    local response
    response=$(gh issue view "$issue_id" --json number,title,body,labels,state 2>/dev/null) || {
        return 1
    }

    # Normalize output
    echo "$response" | jq '{id: .number, title: .title, body: .body, labels: [.labels[].name], state: .state}' 2>/dev/null || return 1
}

# Fetch issue body text only
# Input: issue_id
# Output: plain text body
provider_get_issue_body() {
    local issue_id="$1"

    [[ -z "$issue_id" ]] && return 1
    [[ "${NO_GITHUB:-}" == "1" ]] && return 0

    gh issue view "$issue_id" --json body --jq '.body' 2>/dev/null || return 1
}

# Add label to issue
# Input: issue_id, label
# Output: none (stdout on success, nothing on failure)
provider_add_label() {
    local issue_id="$1"
    local label="$2"

    [[ -z "$issue_id" || -z "$label" ]] && return 1
    [[ "${NO_GITHUB:-}" == "1" ]] && return 0

    gh issue edit "$issue_id" --add-label "$label" 2>/dev/null || return 1
}

# Remove label from issue
# Input: issue_id, label
# Output: none
provider_remove_label() {
    local issue_id="$1"
    local label="$2"

    [[ -z "$issue_id" || -z "$label" ]] && return 1
    [[ "${NO_GITHUB:-}" == "1" ]] && return 0

    gh issue edit "$issue_id" --remove-label "$label" 2>/dev/null || return 1
}

# Add comment to issue
# Input: issue_id, body
# Output: none
provider_comment() {
    local issue_id="$1"
    local body="$2"

    [[ -z "$issue_id" || -z "$body" ]] && return 1
    [[ "${NO_GITHUB:-}" == "1" ]] && return 0

    gh issue comment "$issue_id" --body "$body" 2>/dev/null || return 1
}

# Close/resolve issue
# Input: issue_id
# Output: none
provider_close_issue() {
    local issue_id="$1"

    [[ -z "$issue_id" ]] && return 1
    [[ "${NO_GITHUB:-}" == "1" ]] && return 0

    gh issue close "$issue_id" 2>/dev/null || return 1
}

# Create new issue
# Input: title, body, labels (comma-separated or space-separated)
# Output: JSON {id, title}
provider_create_issue() {
    local title="$1"
    local body="$2"
    local labels="${3:-}"

    [[ -z "$title" ]] && return 1
    [[ "${NO_GITHUB:-}" == "1" ]] && return 0

    local gh_args=(issue create)
    gh_args+=(--title "$title")

    if [[ -n "$body" ]]; then
        gh_args+=(--body "$body")
    fi

    if [[ -n "$labels" ]]; then
        # Convert space-separated to gh format (--label multiple times)
        # Handle both "label1,label2" and "label1 label2"
        local label_list
        label_list=$(echo "$labels" | tr ',' '\n' | tr ' ' '\n' | grep -v '^$' || true)
        while IFS= read -r label; do
            [[ -n "$label" ]] && gh_args+=(--label "$label")
        done <<< "$label_list"
    fi

    local response
    response=$(gh "${gh_args[@]}" 2>/dev/null) || {
        return 1
    }

    # Extract issue number from response or return error
    # GitHub response is typically: "Created issue <repo>#<number>"
    local issue_num
    issue_num=$(echo "$response" | grep -oE '#[0-9]+' | head -1 | tr -d '#' || true)

    if [[ -z "$issue_num" ]]; then
        return 1
    fi

    echo "{\"id\": $issue_num, \"title\": \"$title\"}"
}

# ─── Main Provider Entry Point (Notification) ──────────────────────────────
# Called by tracker_notify() in sw-tracker.sh

provider_notify() {
    local event="$1"
    local gh_issue="${2:-}"
    local detail="${3:-}"

    # GitHub is the native provider — no external sync needed
    # This function exists for consistency with Linear/Jira but is minimal
    # Real integration happens through pipeline stages calling provider_* functions

    # For now, just log the event
    emit_event "tracker.notify" "provider=github" "event=$event" "issue=$gh_issue"
}
