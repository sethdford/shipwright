#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tracker: Jira Provider                                       ║
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
# Queries Jira API for project statuses and caches the transition name mapping.
# Only fills in JIRA_TRANSITION_* values that are empty (config/env takes priority).
# Falls back silently if API call fails.

provider_discover_statuses() {
    # Require base URL, API token, and project key for discovery
    [[ -z "${JIRA_BASE_URL:-}" || -z "${JIRA_API_TOKEN:-}" || -z "${JIRA_PROJECT_KEY:-}" ]] && return 0

    local cache_dir="${HOME}/.shipwright/tracker-cache"
    local cache_file="${cache_dir}/jira-statuses.json"

    # Check cache freshness (24h TTL)
    if [[ -f "$cache_file" ]]; then
        local now cached_at cache_age
        now=$(date +%s)
        cached_at=$(jq -r '.cached_at // 0' "$cache_file" 2>/dev/null || echo "0")
        cache_age=$((now - cached_at))
        if [[ $cache_age -lt 86400 ]]; then
            # Use cached transition names (only fill empty slots)
            local cached_val
            cached_val=$(jq -r '.transitions.in_progress // empty' "$cache_file" 2>/dev/null || true)
            [[ -z "$JIRA_TRANSITION_IN_PROGRESS" && -n "$cached_val" ]] && JIRA_TRANSITION_IN_PROGRESS="$cached_val"
            cached_val=$(jq -r '.transitions.in_review // empty' "$cache_file" 2>/dev/null || true)
            [[ -z "$JIRA_TRANSITION_IN_REVIEW" && -n "$cached_val" ]] && JIRA_TRANSITION_IN_REVIEW="$cached_val"
            cached_val=$(jq -r '.transitions.done // empty' "$cache_file" 2>/dev/null || true)
            [[ -z "$JIRA_TRANSITION_DONE" && -n "$cached_val" ]] && JIRA_TRANSITION_DONE="$cached_val"
            return 0
        fi
    fi

    # Query Jira API for project statuses
    local response
    response=$(jira_api "GET" "project/${JIRA_PROJECT_KEY}/statuses" 2>/dev/null) || return 0

    # Parse all unique statuses across issue types
    local all_statuses
    all_statuses=$(echo "$response" | jq '[.[].statuses[]] | unique_by(.name)' 2>/dev/null || echo "[]")

    local status_count
    status_count=$(echo "$all_statuses" | jq 'length' 2>/dev/null || echo "0")
    [[ "$status_count" -eq 0 ]] && return 0

    # Map by Jira status category: new, indeterminate, done
    local discovered_in_progress discovered_in_review discovered_done

    # "indeterminate" category = in progress states
    discovered_in_progress=$(echo "$all_statuses" | jq -r \
        '[.[] | select(.statusCategory.key == "indeterminate")] | .[0] | .name // empty' 2>/dev/null || true)

    # Look for a review state (name contains "review")
    discovered_in_review=$(echo "$all_statuses" | jq -r \
        '[.[] | select(.name | test("review"; "i"))] | .[0] | .name // empty' 2>/dev/null || true)

    # "done" category
    discovered_done=$(echo "$all_statuses" | jq -r \
        '[.[] | select(.statusCategory.key == "done")] | .[0] | .name // empty' 2>/dev/null || true)

    # Apply discovered values (only fill gaps — config/env takes priority)
    [[ -z "$JIRA_TRANSITION_IN_PROGRESS" && -n "$discovered_in_progress" ]] && JIRA_TRANSITION_IN_PROGRESS="$discovered_in_progress"
    [[ -z "$JIRA_TRANSITION_IN_REVIEW" && -n "$discovered_in_review" ]] && JIRA_TRANSITION_IN_REVIEW="$discovered_in_review"
    [[ -z "$JIRA_TRANSITION_DONE" && -n "$discovered_done" ]] && JIRA_TRANSITION_DONE="$discovered_done"

    # Cache results atomically
    mkdir -p "$cache_dir"
    local tmp_cache
    tmp_cache=$(mktemp)
    jq -n \
        --arg ts "$(date +%s)" \
        --arg in_progress "${discovered_in_progress:-}" \
        --arg in_review "${discovered_in_review:-}" \
        --arg done "${discovered_done:-}" \
        '{
            cached_at: ($ts | tonumber),
            transitions: {
                in_progress: $in_progress,
                in_review: $in_review,
                done: $done
            }
        }' > "$tmp_cache" 2>/dev/null && mv "$tmp_cache" "$cache_file" || rm -f "$tmp_cache"
}

# ─── Load Jira-specific Config ─────────────────────────────────────────────

provider_load_config() {
    local config="${HOME}/.shipwright/tracker-config.json"

    JIRA_BASE_URL="${JIRA_BASE_URL:-$(jq -r '.jira.base_url // empty' "$config" 2>/dev/null || true)}"
    JIRA_EMAIL="${JIRA_EMAIL:-$(jq -r '.jira.email // empty' "$config" 2>/dev/null || true)}"
    JIRA_API_TOKEN="${JIRA_API_TOKEN:-$(jq -r '.jira.api_token // empty' "$config" 2>/dev/null || true)}"
    JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-$(jq -r '.jira.project_key // empty' "$config" 2>/dev/null || true)}"

    # Transition names from config (empty if not explicitly configured)
    JIRA_TRANSITION_IN_PROGRESS="${JIRA_TRANSITION_IN_PROGRESS:-$(jq -r '.jira.transitions.in_progress // empty' "$config" 2>/dev/null || true)}"
    JIRA_TRANSITION_IN_REVIEW="${JIRA_TRANSITION_IN_REVIEW:-$(jq -r '.jira.transitions.in_review // empty' "$config" 2>/dev/null || true)}"
    JIRA_TRANSITION_DONE="${JIRA_TRANSITION_DONE:-$(jq -r '.jira.transitions.done // empty' "$config" 2>/dev/null || true)}"

    # Strip trailing slash from base URL
    JIRA_BASE_URL="${JIRA_BASE_URL%/}"

    # Auto-discover statuses from API if not explicitly configured
    provider_discover_statuses

    # Final fallback defaults
    JIRA_TRANSITION_IN_PROGRESS="${JIRA_TRANSITION_IN_PROGRESS:-In Progress}"
    JIRA_TRANSITION_IN_REVIEW="${JIRA_TRANSITION_IN_REVIEW:-In Review}"
    JIRA_TRANSITION_DONE="${JIRA_TRANSITION_DONE:-Done}"
}

# ─── Jira REST API Helper ─────────────────────────────────────────────────

jira_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local auth
    auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64)

    local args=(-sf -X "$method" \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json")

    if [[ -n "$data" ]]; then
        args+=(-d "$data")
    fi

    curl "${args[@]}" "${JIRA_BASE_URL}/rest/api/3/${endpoint}" 2>&1
}

# ─── Discovery & CRUD Interface ───────────────────────────────────────────
# Implements provider interface for daemon discovery and pipeline CRUD

provider_discover_issues() {
    local label="$1"
    local state="${2:-open}"
    local limit="${3:-50}"

    provider_load_config

    # Build JQL query
    local jql="project = \"${JIRA_PROJECT_KEY}\""

    if [[ -n "$label" ]]; then
        jql="${jql} AND labels = \"${label}\""
    fi

    # Map state parameter to Jira status
    case "$state" in
        open)
            jql="${jql} AND status IN (${JIRA_TRANSITION_IN_PROGRESS:-\"In Progress\"},${JIRA_TRANSITION_IN_REVIEW:-\"In Review\"})"
            ;;
        closed)
            jql="${jql} AND status = ${JIRA_TRANSITION_DONE:-\"Done\"}"
            ;;
        *)
            # Custom status provided
            jql="${jql} AND status = \"${state}\""
            ;;
    esac

    jql="${jql} ORDER BY created DESC"

    # Fetch issues
    local response
    response=$(jira_api "GET" "search?jql=$(printf '%s' "$jql" | jq -sRr @uri)&maxResults=${limit}&fields=key,summary,labels,status" 2>/dev/null) || {
        echo "[]"
        return 0
    }

    # Normalize to {id, title, labels[], state}
    echo "$response" | jq '[.issues[]? | {id: .key, title: .fields.summary, labels: [.fields.labels[]?.name // empty], state: .fields.status.name}]' 2>/dev/null || echo "[]"
}

provider_get_issue() {
    local issue_id="$1"

    [[ -z "$issue_id" ]] && return 1

    provider_load_config

    local response
    response=$(jira_api "GET" "issue/${issue_id}?fields=key,summary,description,labels,status" 2>/dev/null) || {
        return 1
    }

    # Normalize output
    echo "$response" | jq '{id: .key, title: .fields.summary, body: .fields.description, labels: [.fields.labels[]?.name // empty], state: .fields.status.name}' 2>/dev/null || return 1
}

provider_get_issue_body() {
    local issue_id="$1"

    [[ -z "$issue_id" ]] && return 1

    provider_load_config

    local response
    response=$(jira_api "GET" "issue/${issue_id}?fields=description" 2>/dev/null) || {
        return 1
    }

    echo "$response" | jq -r '.fields.description // ""' 2>/dev/null || return 1
}

provider_add_label() {
    local issue_id="$1"
    local label="$2"

    [[ -z "$issue_id" || -z "$label" ]] && return 1

    provider_load_config

    # Get current labels
    local current_labels
    current_labels=$(jira_api "GET" "issue/${issue_id}?fields=labels" 2>/dev/null | jq '.fields.labels[]?.name' 2>/dev/null || echo "[]")

    # Add new label
    local payload
    payload=$(jq -n --arg label "$label" --argjson labels "$current_labels" '{fields: {labels: ($labels | map(select(. != $label)) + [$label])}}' 2>/dev/null)

    jira_api "PUT" "issue/${issue_id}" "$payload" 2>/dev/null || return 1
}

provider_remove_label() {
    local issue_id="$1"
    local label="$2"

    [[ -z "$issue_id" || -z "$label" ]] && return 1

    provider_load_config

    # Get current labels and remove the specified one
    local payload
    payload=$(jq -n --arg label "$label" '{fields: {labels: [{name: ""}]}}')

    jira_api "PUT" "issue/${issue_id}" "$payload" 2>/dev/null || return 1
}

provider_comment() {
    local issue_id="$1"
    local body="$2"

    [[ -z "$issue_id" || -z "$body" ]] && return 1

    provider_load_config
    jira_add_comment "$issue_id" "$body"
}

provider_close_issue() {
    local issue_id="$1"

    [[ -z "$issue_id" ]] && return 1

    provider_load_config
    jira_transition "$issue_id" "$JIRA_TRANSITION_DONE"
}

provider_create_issue() {
    local title="$1"
    local body="$2"
    local labels="${3:-}"

    [[ -z "$title" ]] && return 1

    provider_load_config

    # Build payload
    local payload
    payload=$(jq -n --arg summary "$title" --arg description "$body" --arg project "$JIRA_PROJECT_KEY" \
        '{
            fields: {
                project: {key: $project},
                summary: $summary,
                description: $description,
                issuetype: {name: "Task"}
            }
        }')

    # Add labels if provided
    if [[ -n "$labels" ]]; then
        local label_array
        label_array=$(echo "$labels" | jq -R 'split("[, ]"; "x") | map(select(length > 0))' 2>/dev/null || echo '[]')
        payload=$(echo "$payload" | jq --argjson labels "$label_array" '.fields.labels = $labels' 2>/dev/null)
    fi

    local response
    response=$(jira_api "POST" "issue" "$payload" 2>/dev/null) || {
        return 1
    }

    # Extract issue key from response
    local issue_key
    issue_key=$(echo "$response" | jq -r '.key // empty' 2>/dev/null)

    if [[ -z "$issue_key" ]]; then
        return 1
    fi

    echo "{\"id\": \"$issue_key\", \"title\": \"$title\"}"
}

# ─── Find Jira Issue Key from GitHub Issue Body ───────────────────────────

find_jira_key() {
    local gh_issue="$1"

    if [[ -z "$gh_issue" ]]; then
        return 0
    fi

    gh issue view "$gh_issue" --json body --jq '.body' 2>/dev/null | \
        grep -oE 'Jira:.*[A-Z]+-[0-9]+' | grep -oE '[A-Z]+-[0-9]+' | head -1 || true
}

# ─── Add Comment to Jira Issue ─────────────────────────────────────────────
# Uses Atlassian Document Format (ADF) for the comment body.

jira_add_comment() {
    local issue_key="$1"
    local body="$2"

    local payload
    payload=$(jq -n --arg text "$body" '{
        body: {
            type: "doc",
            version: 1,
            content: [{
                type: "paragraph",
                content: [{type: "text", text: $text}]
            }]
        }
    }')

    jira_api "POST" "issue/${issue_key}/comment" "$payload"
}

# ─── Transition Jira Issue ─────────────────────────────────────────────────
# Finds the transition ID by name and applies it.

jira_transition() {
    local issue_key="$1"
    local transition_name="$2"

    # Get available transitions
    local transitions
    transitions=$(jira_api "GET" "issue/${issue_key}/transitions") || return 0

    # Find transition ID by name
    local transition_id
    transition_id=$(echo "$transitions" | jq -r --arg name "$transition_name" \
        '.transitions[] | select(.name == $name) | .id' 2>/dev/null || true)

    if [[ -z "$transition_id" ]]; then
        # Transition not available — silently skip
        return 0
    fi

    local payload
    payload=$(jq -n --arg id "$transition_id" '{transition: {id: $id}}')

    jira_api "POST" "issue/${issue_key}/transitions" "$payload"
}

# ─── Add Remote Link (PR) to Jira Issue ───────────────────────────────────

jira_attach_pr() {
    local issue_key="$1"
    local pr_url="$2"
    local pr_title="${3:-Pull Request}"

    local payload
    payload=$(jq -n --arg url "$pr_url" --arg title "$pr_title" '{
        object: {url: $url, title: $title}
    }')

    jira_api "POST" "issue/${issue_key}/remotelink" "$payload"
}

# ─── Main Provider Entry Point ─────────────────────────────────────────────
# Called by tracker_notify() in sw-tracker.sh

provider_notify() {
    local event="$1"
    local gh_issue="${2:-}"
    local detail="${3:-}"

    provider_load_config

    # Silently skip if not configured
    [[ -z "$JIRA_BASE_URL" || -z "$JIRA_API_TOKEN" ]] && return 0

    # Find the linked Jira issue
    local jira_key=""
    if [[ -n "$gh_issue" ]]; then
        jira_key=$(find_jira_key "$gh_issue")
    fi
    [[ -z "$jira_key" ]] && return 0

    case "$event" in
        spawn|started)
            jira_transition "$jira_key" "$JIRA_TRANSITION_IN_PROGRESS" || true
            jira_add_comment "$jira_key" "Pipeline started for GitHub issue #${gh_issue}" || true
            ;;
        stage_complete)
            # detail format: "stage_id|duration|description"
            local stage_id duration stage_desc
            stage_id=$(echo "$detail" | cut -d'|' -f1)
            duration=$(echo "$detail" | cut -d'|' -f2)
            stage_desc=$(echo "$detail" | cut -d'|' -f3)
            jira_add_comment "$jira_key" "Stage ${stage_id} complete (${duration}) — ${stage_desc}" || true
            ;;
        stage_failed)
            # detail format: "stage_id|error_context"
            local stage_id error_ctx
            stage_id=$(echo "$detail" | cut -d'|' -f1)
            error_ctx=$(echo "$detail" | cut -d'|' -f2-)
            jira_add_comment "$jira_key" "Stage ${stage_id} failed: ${error_ctx}" || true
            ;;
        review|pr-created)
            jira_transition "$jira_key" "$JIRA_TRANSITION_IN_REVIEW" || true
            if [[ -n "$detail" ]]; then
                jira_attach_pr "$jira_key" "$detail" "PR for #${gh_issue}" || true
            fi
            ;;
        completed|done)
            jira_transition "$jira_key" "$JIRA_TRANSITION_DONE" || true
            jira_add_comment "$jira_key" "Pipeline completed for GitHub issue #${gh_issue}" || true
            ;;
        failed)
            local msg="Pipeline failed for GitHub issue #${gh_issue}"
            if [[ -n "$detail" ]]; then
                msg="${msg}. ${detail}"
            fi
            jira_add_comment "$jira_key" "$msg" || true
            ;;
    esac

    emit_event "tracker.notify" "provider=jira" "event=$event" "github_issue=$gh_issue"
}
