#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tracker: Linear Provider                                     ║
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

# ─── Status Auto-Discovery ────────────────────────────────────────────────
# Queries Linear API for workflow states and caches the mapping.
# Only fills in STATUS_* values that are empty (config/env takes priority).
# Falls back silently if API call fails.

provider_discover_statuses() {
    # Require team ID and API key for discovery
    [[ -z "${LINEAR_TEAM_ID:-}" ]] && return 0
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 0

    local cache_dir="${HOME}/.shipwright/tracker-cache"
    local cache_file="${cache_dir}/linear-statuses.json"

    # Check cache freshness (24h TTL)
    if [[ -f "$cache_file" ]]; then
        local now cached_at cache_age
        now=$(date +%s)
        cached_at=$(jq -r '.cached_at // 0' "$cache_file" 2>/dev/null || echo "0")
        cache_age=$((now - cached_at))
        if [[ $cache_age -lt 86400 ]]; then
            # Use cached values (only fill empty slots)
            [[ -z "$STATUS_BACKLOG" ]] && STATUS_BACKLOG=$(jq -r '.statuses.backlog // empty' "$cache_file" 2>/dev/null || true)
            [[ -z "$STATUS_TODO" ]] && STATUS_TODO=$(jq -r '.statuses.todo // empty' "$cache_file" 2>/dev/null || true)
            [[ -z "$STATUS_IN_PROGRESS" ]] && STATUS_IN_PROGRESS=$(jq -r '.statuses.in_progress // empty' "$cache_file" 2>/dev/null || true)
            [[ -z "$STATUS_IN_REVIEW" ]] && STATUS_IN_REVIEW=$(jq -r '.statuses.in_review // empty' "$cache_file" 2>/dev/null || true)
            [[ -z "$STATUS_DONE" ]] && STATUS_DONE=$(jq -r '.statuses.done // empty' "$cache_file" 2>/dev/null || true)
            return 0
        fi
    fi

    # Query Linear API for workflow states
    local query='query($teamId: String!) {
        team(id: $teamId) {
            states {
                nodes { id name type }
            }
        }
    }'
    local vars
    vars=$(jq -n --arg teamId "$LINEAR_TEAM_ID" '{teamId: $teamId}')

    local response
    response=$(linear_graphql "$query" "$vars" 2>/dev/null) || {
        # API call failed — keep existing config/hardcoded values
        return 0
    }

    # Parse states
    local states_json
    states_json=$(echo "$response" | jq '.data.team.states.nodes // []' 2>/dev/null || echo "[]")

    local state_count
    state_count=$(echo "$states_json" | jq 'length' 2>/dev/null || echo "0")
    [[ "$state_count" -eq 0 ]] && return 0

    # Map by Linear state type: backlog, unstarted, started, completed, canceled
    local discovered_backlog discovered_todo discovered_in_progress discovered_in_review discovered_done

    discovered_backlog=$(echo "$states_json" | jq -r '[.[] | select(.type == "backlog")] | .[0] | .id // empty' 2>/dev/null || true)
    discovered_todo=$(echo "$states_json" | jq -r '[.[] | select(.type == "unstarted")] | .[0] | .id // empty' 2>/dev/null || true)
    discovered_in_progress=$(echo "$states_json" | jq -r '[.[] | select(.type == "started")] | .[0] | .id // empty' 2>/dev/null || true)
    discovered_done=$(echo "$states_json" | jq -r '[.[] | select(.type == "completed")] | .[0] | .id // empty' 2>/dev/null || true)

    # "In Review" is typically a custom state — match by name
    discovered_in_review=$(echo "$states_json" | jq -r '[.[] | select(.name | test("review"; "i"))] | .[0] | .id // empty' 2>/dev/null || true)

    # Apply discovered values (only fill gaps — config/env takes priority)
    [[ -z "$STATUS_BACKLOG" && -n "$discovered_backlog" ]] && STATUS_BACKLOG="$discovered_backlog"
    [[ -z "$STATUS_TODO" && -n "$discovered_todo" ]] && STATUS_TODO="$discovered_todo"
    [[ -z "$STATUS_IN_PROGRESS" && -n "$discovered_in_progress" ]] && STATUS_IN_PROGRESS="$discovered_in_progress"
    [[ -z "$STATUS_IN_REVIEW" && -n "$discovered_in_review" ]] && STATUS_IN_REVIEW="$discovered_in_review"
    [[ -z "$STATUS_DONE" && -n "$discovered_done" ]] && STATUS_DONE="$discovered_done"

    # Cache results atomically
    mkdir -p "$cache_dir"
    local tmp_cache
    tmp_cache=$(mktemp)
    jq -n \
        --arg ts "$(date +%s)" \
        --arg backlog "${discovered_backlog:-}" \
        --arg todo "${discovered_todo:-}" \
        --arg in_progress "${discovered_in_progress:-}" \
        --arg in_review "${discovered_in_review:-}" \
        --arg done "${discovered_done:-}" \
        '{
            cached_at: ($ts | tonumber),
            statuses: {
                backlog: $backlog,
                todo: $todo,
                in_progress: $in_progress,
                in_review: $in_review,
                done: $done
            }
        }' > "$tmp_cache" 2>/dev/null && mv "$tmp_cache" "$cache_file" || rm -f "$tmp_cache"
}

# ─── Load Linear-specific Config ───────────────────────────────────────────

provider_load_config() {
    local config="${HOME}/.shipwright/tracker-config.json"

    # API key: env var → tracker-config.json → linear-config.json (legacy)
    LINEAR_API_KEY="${LINEAR_API_KEY:-$(jq -r '.linear.api_key // empty' "$config" 2>/dev/null || true)}"
    if [[ -z "$LINEAR_API_KEY" ]]; then
        local legacy_config="${HOME}/.shipwright/linear-config.json"
        if [[ -f "$legacy_config" ]]; then
            LINEAR_API_KEY="${LINEAR_API_KEY:-$(jq -r '.api_key // empty' "$legacy_config" 2>/dev/null || true)}"
        fi
    fi

    LINEAR_TEAM_ID="${LINEAR_TEAM_ID:-$(jq -r '.linear.team_id // empty' "$config" 2>/dev/null || true)}"
    LINEAR_PROJECT_ID="${LINEAR_PROJECT_ID:-$(jq -r '.linear.project_id // empty' "$config" 2>/dev/null || true)}"

    # Status IDs from config (empty if not configured)
    STATUS_BACKLOG="${LINEAR_STATUS_BACKLOG:-$(jq -r '.linear.statuses.backlog // empty' "$config" 2>/dev/null || true)}"
    STATUS_TODO="${LINEAR_STATUS_TODO:-$(jq -r '.linear.statuses.todo // empty' "$config" 2>/dev/null || true)}"
    STATUS_IN_PROGRESS="${LINEAR_STATUS_IN_PROGRESS:-$(jq -r '.linear.statuses.in_progress // empty' "$config" 2>/dev/null || true)}"
    STATUS_IN_REVIEW="${LINEAR_STATUS_IN_REVIEW:-$(jq -r '.linear.statuses.in_review // empty' "$config" 2>/dev/null || true)}"
    STATUS_DONE="${LINEAR_STATUS_DONE:-$(jq -r '.linear.statuses.done // empty' "$config" 2>/dev/null || true)}"

    LINEAR_API="https://api.linear.app/graphql"

    # Auto-discover statuses from API if not explicitly configured
    provider_discover_statuses
}

# ─── Linear GraphQL Helper ────────────────────────────────────────────────

linear_graphql() {
    local query="$1"
    local variables="${2:-{}}"

    local payload
    payload=$(jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')

    local response
    response=$(curl -sf -X POST "$LINEAR_API" \
        -H "Authorization: $LINEAR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || {
        error "Linear API request failed"
        echo "$response" >&2
        return 1
    }

    # Check for GraphQL errors
    local errors
    errors=$(echo "$response" | jq -r '.errors[0].message // empty' 2>/dev/null || true)
    if [[ -n "$errors" ]]; then
        error "Linear API error: $errors"
        return 1
    fi

    echo "$response"
}

# ─── Update Linear Issue Status ────────────────────────────────────────────

linear_update_status() {
    local issue_id="$1"
    local state_id="$2"

    # Skip if no state ID provided
    [[ -z "$state_id" ]] && return 0

    local query='mutation($issueId: String!, $stateId: String!) {
        issueUpdate(id: $issueId, input: { stateId: $stateId }) {
            issue { id identifier }
        }
    }'

    local vars
    vars=$(jq -n --arg issueId "$issue_id" --arg stateId "$state_id" \
        '{issueId: $issueId, stateId: $stateId}')

    linear_graphql "$query" "$vars" >/dev/null
}

# ─── Add Comment to Linear Issue ───────────────────────────────────────────

linear_add_comment() {
    local issue_id="$1"
    local body="$2"

    local query='mutation($issueId: String!, $body: String!) {
        commentCreate(input: { issueId: $issueId, body: $body }) {
            comment { id }
        }
    }'

    local vars
    vars=$(jq -n --arg issueId "$issue_id" --arg body "$body" \
        '{issueId: $issueId, body: $body}')

    linear_graphql "$query" "$vars" >/dev/null
}

# ─── Attach PR Link to Linear Issue ───────────────────────────────────────

linear_attach_pr() {
    local issue_id="$1"
    local pr_url="$2"
    local pr_title="${3:-Pull Request}"

    local body
    body=$(printf "PR linked: [%s](%s)" "$pr_title" "$pr_url")
    linear_add_comment "$issue_id" "$body"
}

# ─── Discovery & CRUD Interface ───────────────────────────────────────────
# Implements provider interface for daemon discovery and pipeline CRUD

provider_discover_issues() {
    local label="$1"
    local state="${2:-open}"
    local limit="${3:-50}"

    provider_load_config

    # Build Linear query for issues
    local query='query($teamId: String!, $first: Int, $filter: IssueFilter) {
        team(id: $teamId) {
            issues(first: $first, filter: $filter) {
                nodes {
                    id identifier title labels {nodes {name}}
                    state {id name type}
                }
            }
        }
    }'

    # Build filter for state
    local state_filter=""
    case "$state" in
        open)
            # Open = unstarted or started
            state_filter='and: [or: [{state: {type: {eq: "unstarted"}}}, {state: {type: {eq: "started"}}}]]'
            ;;
        closed)
            state_filter='and: [{state: {type: {eq: "completed"}}}]'
            ;;
        *)
            # Custom state provided
            state_filter="and: [{state: {type: {eq: \"${state}\"}}}]"
            ;;
    esac

    # Add label filter if provided
    if [[ -n "$label" ]]; then
        state_filter="${state_filter}, {labels: {some: {name: {eq: \"${label}\"}}}}"
    fi

    local filter
    filter="{${state_filter}}"

    local vars
    vars=$(jq -n --arg teamId "$LINEAR_TEAM_ID" --arg filter "$filter" --arg limit "$limit" \
        "{teamId: \$teamId, first: (\$limit | tonumber), filter: $filter}" 2>/dev/null || \
        jq -n --arg teamId "$LINEAR_TEAM_ID" --arg limit "$limit" \
        '{teamId: $teamId, first: ($limit | tonumber)}')

    local response
    response=$(linear_graphql "$query" "$vars" 2>/dev/null) || {
        echo "[]"
        return 0
    }

    # Normalize to {id, title, labels[], state}
    echo "$response" | jq '[.data.team.issues.nodes[]? | {id: .id, title: .title, labels: [.labels.nodes[]?.name // empty], state: .state.name}]' 2>/dev/null || echo "[]"
}

provider_get_issue() {
    local issue_id="$1"

    [[ -z "$issue_id" ]] && return 1

    provider_load_config

    local query='query($id: String!) {
        issue(id: $id) {
            id title description labels {nodes {name}}
            state {id name}
        }
    }'

    local vars
    vars=$(jq -n --arg id "$issue_id" '{id: $id}')

    local response
    response=$(linear_graphql "$query" "$vars" 2>/dev/null) || {
        return 1
    }

    # Normalize output
    echo "$response" | jq '{id: .data.issue.id, title: .data.issue.title, body: .data.issue.description, labels: [.data.issue.labels.nodes[]?.name // empty], state: .data.issue.state.name}' 2>/dev/null || return 1
}

provider_get_issue_body() {
    local issue_id="$1"

    [[ -z "$issue_id" ]] && return 1

    provider_load_config

    local query='query($id: String!) {
        issue(id: $id) {
            description
        }
    }'

    local vars
    vars=$(jq -n --arg id "$issue_id" '{id: $id}')

    local response
    response=$(linear_graphql "$query" "$vars" 2>/dev/null) || {
        return 1
    }

    echo "$response" | jq -r '.data.issue.description // ""' 2>/dev/null || return 1
}

provider_add_label() {
    local issue_id="$1"
    local label="$2"

    [[ -z "$issue_id" || -z "$label" ]] && return 1

    provider_load_config

    # Linear label IDs are required — fetch them
    local query='query {
        labels(first: 100) {
            nodes {id name}
        }
    }'

    local labels_response
    labels_response=$(linear_graphql "$query" "{}" 2>/dev/null) || return 1

    local label_id
    label_id=$(echo "$labels_response" | jq -r --arg name "$label" '.data.labels.nodes[] | select(.name == $name) | .id' 2>/dev/null || true)

    if [[ -z "$label_id" ]]; then
        # Label not found — skip
        return 0
    fi

    local update_query='mutation($issueId: String!, $labelIds: [String!]) {
        issueLabelCreate(issueId: $issueId, labelIds: $labelIds) {
            success
        }
    }'

    local vars
    vars=$(jq -n --arg issueId "$issue_id" --arg labelId "$label_id" \
        '{issueId: $issueId, labelIds: [$labelId]}')

    linear_graphql "$update_query" "$vars" >/dev/null 2>&1 || return 1
}

provider_remove_label() {
    local issue_id="$1"
    local label="$2"

    [[ -z "$issue_id" || -z "$label" ]] && return 1

    provider_load_config

    # Linear requires label IDs
    local query='query {
        labels(first: 100) {
            nodes {id name}
        }
    }'

    local labels_response
    labels_response=$(linear_graphql "$query" "{}" 2>/dev/null) || return 1

    local label_id
    label_id=$(echo "$labels_response" | jq -r --arg name "$label" '.data.labels.nodes[] | select(.name == $name) | .id' 2>/dev/null || true)

    if [[ -z "$label_id" ]]; then
        return 0
    fi

    local update_query='mutation($issueId: String!, $labelIds: [String!]) {
        issueLabelDelete(issueId: $issueId, labelIds: $labelIds) {
            success
        }
    }'

    local vars
    vars=$(jq -n --arg issueId "$issue_id" --arg labelId "$label_id" \
        '{issueId: $issueId, labelIds: [$labelId]}')

    linear_graphql "$update_query" "$vars" >/dev/null 2>&1 || return 1
}

provider_comment() {
    local issue_id="$1"
    local body="$2"

    [[ -z "$issue_id" || -z "$body" ]] && return 1

    provider_load_config
    linear_add_comment "$issue_id" "$body"
}

provider_close_issue() {
    local issue_id="$1"

    [[ -z "$issue_id" ]] && return 1

    provider_load_config
    linear_update_status "$issue_id" "$STATUS_DONE"
}

provider_create_issue() {
    local title="$1"
    local body="$2"
    local labels="${3:-}"

    [[ -z "$title" ]] && return 1

    provider_load_config

    local query='mutation($title: String!, $description: String, $teamId: String!) {
        issueCreate(input: {title: $title, description: $description, teamId: $teamId}) {
            issue {id}
        }
    }'

    local vars
    vars=$(jq -n --arg title "$title" --arg description "$body" --arg teamId "$LINEAR_TEAM_ID" \
        '{title: $title, description: $description, teamId: $teamId}')

    local response
    response=$(linear_graphql "$query" "$vars" 2>/dev/null) || {
        return 1
    }

    local issue_id
    issue_id=$(echo "$response" | jq -r '.data.issueCreate.issue.id // empty' 2>/dev/null)

    if [[ -z "$issue_id" ]]; then
        return 1
    fi

    # Add labels if provided
    if [[ -n "$labels" ]]; then
        local label_list
        label_list=$(echo "$labels" | tr ',' '\n' | tr ' ' '\n' | grep -v '^$' || true)
        while IFS= read -r lbl; do
            [[ -n "$lbl" ]] && provider_add_label "$issue_id" "$lbl" || true
        done <<< "$label_list"
    fi

    echo "{\"id\": \"$issue_id\", \"title\": \"$title\"}"
}

# ─── Find Linear Issue ID from GitHub Issue Body ──────────────────────────

find_linear_id() {
    local gh_issue="$1"

    if [[ -z "$gh_issue" ]]; then
        return 0
    fi

    gh issue view "$gh_issue" --json body --jq '.body' 2>/dev/null | \
        grep -o 'Linear ID:.*' | sed 's/.*\*\*Linear ID:\*\* //' | tr -d '[:space:]' || true
}

# ─── Main Provider Entry Point ─────────────────────────────────────────────
# Called by tracker_notify() in sw-tracker.sh

provider_notify() {
    local event="$1"
    local gh_issue="${2:-}"
    local detail="${3:-}"

    provider_load_config

    # Silently skip if no API key
    [[ -z "$LINEAR_API_KEY" ]] && return 0

    # Find the linked Linear issue
    local linear_id=""
    if [[ -n "$gh_issue" ]]; then
        linear_id=$(find_linear_id "$gh_issue")
    fi
    [[ -z "$linear_id" ]] && return 0

    case "$event" in
        spawn|started)
            linear_update_status "$linear_id" "$STATUS_IN_PROGRESS" || true
            linear_add_comment "$linear_id" "Pipeline started for GitHub issue #${gh_issue}" || true
            ;;
        stage_complete)
            # detail format: "stage_id|duration|description"
            local stage_id duration stage_desc
            stage_id=$(echo "$detail" | cut -d'|' -f1)
            duration=$(echo "$detail" | cut -d'|' -f2)
            stage_desc=$(echo "$detail" | cut -d'|' -f3)
            linear_add_comment "$linear_id" "Stage **${stage_id}** complete (${duration}) — ${stage_desc}" || true
            ;;
        stage_failed)
            # detail format: "stage_id|error_context"
            local stage_id error_ctx
            stage_id=$(echo "$detail" | cut -d'|' -f1)
            error_ctx=$(echo "$detail" | cut -d'|' -f2-)
            linear_add_comment "$linear_id" "Stage **${stage_id}** failed\n\n\`\`\`\n${error_ctx}\n\`\`\`" || true
            ;;
        review|pr-created)
            linear_update_status "$linear_id" "$STATUS_IN_REVIEW" || true
            if [[ -n "$detail" ]]; then
                linear_attach_pr "$linear_id" "$detail" "PR for #${gh_issue}" || true
            fi
            ;;
        completed|done)
            linear_update_status "$linear_id" "$STATUS_DONE" || true
            linear_add_comment "$linear_id" "Pipeline completed for GitHub issue #${gh_issue}" || true
            ;;
        failed)
            local msg="Pipeline failed for GitHub issue #${gh_issue}"
            if [[ -n "$detail" ]]; then
                msg="${msg}\n\nDetails:\n${detail}"
            fi
            linear_add_comment "$linear_id" "$msg" || true
            ;;
    esac

    emit_event "tracker.notify" "provider=linear" "event=$event" "github_issue=$gh_issue"
}
