#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tracker: Linear Provider                                     ║
# ║  Sourced by sw-tracker.sh — do not call directly                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# This file is sourced by sw-tracker.sh.
# It defines provider_* functions used by the tracker router.
# Do NOT add set -euo pipefail or a main() function here.

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
