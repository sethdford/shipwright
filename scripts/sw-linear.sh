#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright linear — Linear ↔ GitHub Bidirectional Sync                 ║
# ║  Sync issues · Update statuses · Link PRs · Pipeline integration        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.2.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ─── Configuration ─────────────────────────────────────────────────────────
CONFIG_DIR="${HOME}/.shipwright"
LINEAR_CONFIG="${CONFIG_DIR}/linear-config.json"

# Linear Status IDs — loaded from config, with env var overrides
# Configure via: shipwright tracker init --provider linear
# Or set env vars: LINEAR_STATUS_BACKLOG, LINEAR_STATUS_TODO, etc.
STATUS_BACKLOG="${LINEAR_STATUS_BACKLOG:-}"
STATUS_TODO="${LINEAR_STATUS_TODO:-}"
STATUS_IN_PROGRESS="${LINEAR_STATUS_IN_PROGRESS:-}"
STATUS_IN_REVIEW="${LINEAR_STATUS_IN_REVIEW:-}"
STATUS_DONE="${LINEAR_STATUS_DONE:-}"

LINEAR_API="https://api.linear.app/graphql"

load_config() {
    if [[ -f "$LINEAR_CONFIG" ]]; then
        LINEAR_API_KEY="${LINEAR_API_KEY:-$(jq -r '.api_key // empty' "$LINEAR_CONFIG" 2>/dev/null || true)}"
        LINEAR_TEAM_ID="${LINEAR_TEAM_ID:-$(jq -r '.team_id // empty' "$LINEAR_CONFIG" 2>/dev/null || true)}"
        LINEAR_PROJECT_ID="${LINEAR_PROJECT_ID:-$(jq -r '.project_id // empty' "$LINEAR_CONFIG" 2>/dev/null || true)}"
    fi

    LINEAR_API_KEY="${LINEAR_API_KEY:-}"
    LINEAR_TEAM_ID="${LINEAR_TEAM_ID:-$(jq -r '.team_id // empty' "$LINEAR_CONFIG" 2>/dev/null || true)}"
    LINEAR_PROJECT_ID="${LINEAR_PROJECT_ID:-$(jq -r '.project_id // empty' "$LINEAR_CONFIG" 2>/dev/null || true)}"

    # Load status IDs from config if not set via env
    if [[ -f "$LINEAR_CONFIG" ]]; then
        STATUS_BACKLOG="${STATUS_BACKLOG:-$(jq -r '.status_ids.backlog // empty' "$LINEAR_CONFIG" 2>/dev/null || true)}"
        STATUS_TODO="${STATUS_TODO:-$(jq -r '.status_ids.todo // empty' "$LINEAR_CONFIG" 2>/dev/null || true)}"
        STATUS_IN_PROGRESS="${STATUS_IN_PROGRESS:-$(jq -r '.status_ids.in_progress // empty' "$LINEAR_CONFIG" 2>/dev/null || true)}"
        STATUS_IN_REVIEW="${STATUS_IN_REVIEW:-$(jq -r '.status_ids.in_review // empty' "$LINEAR_CONFIG" 2>/dev/null || true)}"
        STATUS_DONE="${STATUS_DONE:-$(jq -r '.status_ids.done // empty' "$LINEAR_CONFIG" 2>/dev/null || true)}"
    fi
}

check_api_key() {
    if [[ -z "$LINEAR_API_KEY" ]]; then
        error "LINEAR_API_KEY not set"
        echo ""
        echo -e "  Set via environment:  ${DIM}export LINEAR_API_KEY=lin_api_...${RESET}"
        echo -e "  Or run:               ${DIM}shipwright linear init${RESET}"
        exit 1
    fi
}

# ─── Linear GraphQL Helper ────────────────────────────────────────────────
# Executes a GraphQL query/mutation against the Linear API.
# Uses jq --arg for safe JSON escaping (never string interpolation).
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

# ─── Sync: Linear Todo → GitHub Issues ─────────────────────────────────────

cmd_sync() {
    check_api_key
    info "Syncing Linear Todo issues → GitHub..."

    local dry_run=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            *) shift ;;
        esac
    done

    # Fetch Linear issues in Todo status within the project
    local query='query($teamId: String!, $projectId: String!, $stateId: String!) {
        issues(filter: {
            team: { id: { eq: $teamId } }
            project: { id: { eq: $projectId } }
            state: { id: { eq: $stateId } }
        }) {
            nodes {
                id
                identifier
                title
                description
                url
                priority
                labels { nodes { name } }
            }
        }
    }'

    local vars
    vars=$(jq -n \
        --arg teamId "$LINEAR_TEAM_ID" \
        --arg projectId "$LINEAR_PROJECT_ID" \
        --arg stateId "$STATUS_TODO" \
        '{teamId: $teamId, projectId: $projectId, stateId: $stateId}')

    local response
    response=$(linear_graphql "$query" "$vars") || return 1

    local count
    count=$(echo "$response" | jq '.data.issues.nodes | length')
    if [[ "$count" -eq 0 ]]; then
        info "No Linear issues in Todo status"
        return 0
    fi

    info "Found ${count} Linear issue(s) in Todo"

    local synced=0
    local skipped=0

    # Process each Linear issue
    local i=0
    while [[ $i -lt $count ]]; do
        local issue
        issue=$(echo "$response" | jq ".data.issues.nodes[$i]")
        local linear_id linear_identifier title description url priority
        linear_id=$(echo "$issue" | jq -r '.id')
        linear_identifier=$(echo "$issue" | jq -r '.identifier')
        title=$(echo "$issue" | jq -r '.title')
        description=$(echo "$issue" | jq -r '.description // ""')
        url=$(echo "$issue" | jq -r '.url')
        priority=$(echo "$issue" | jq -r '.priority // 0')

        # Check if GitHub issue already exists for this Linear issue
        local existing_gh
        existing_gh=$(gh issue list --label "ready-to-build" --search "Linear: ${linear_identifier}" --json number --jq '.[0].number // empty' 2>/dev/null || true)

        if [[ -n "$existing_gh" ]]; then
            echo -e "  ${DIM}Skip${RESET} ${linear_identifier}: ${title} ${DIM}(GitHub #${existing_gh})${RESET}"
            skipped=$((skipped + 1))
            i=$((i + 1))
            continue
        fi

        # Map priority to label
        local priority_label=""
        case "$priority" in
            1) priority_label="priority-urgent" ;;
            2) priority_label="priority-high" ;;
            3) priority_label="priority-medium" ;;
            4) priority_label="priority-low" ;;
        esac

        # Build GitHub issue body with Linear back-link
        local gh_body
        gh_body=$(printf "## %s\n\n%s\n\n---\n**Linear:** [%s](%s)\n**Linear ID:** %s" \
            "$title" "$description" "$linear_identifier" "$url" "$linear_id")

        if [[ "$dry_run" == "true" ]]; then
            echo -e "  ${CYAN}Would create${RESET} GitHub issue: ${title} ${DIM}(${linear_identifier})${RESET}"
        else
            # Create GitHub issue
            local labels="ready-to-build"
            if [[ -n "$priority_label" ]]; then
                labels="${labels},${priority_label}"
            fi

            local gh_num
            gh_num=$(gh issue create --title "$title" --body "$gh_body" --label "$labels" --json number --jq '.number' 2>&1) || {
                error "Failed to create GitHub issue for ${linear_identifier}: ${gh_num}"
                i=$((i + 1))
                continue
            }

            # Add comment on Linear issue linking back to GitHub
            local comment_body
            comment_body=$(printf "Synced to GitHub issue #%s\n\nThe daemon will pick this up for autonomous delivery." "$gh_num")
            linear_add_comment "$linear_id" "$comment_body" || true

            # Move Linear issue to In Progress
            linear_update_status "$linear_id" "$STATUS_IN_PROGRESS" || true

            success "${linear_identifier} → GitHub #${gh_num}: ${title}"
            emit_event "linear.sync" "linear_id=$linear_identifier" "github_issue=$gh_num" "title=$title"
            synced=$((synced + 1))
        fi

        i=$((i + 1))
    done

    echo ""
    if [[ "$dry_run" == "true" ]]; then
        info "Dry run: ${synced} would be created, ${skipped} already synced"
    else
        success "Synced ${synced} issue(s), ${skipped} already linked"
    fi
}

# ─── Update: GitHub → Linear Status ──────────────────────────────────────

cmd_update() {
    check_api_key

    if [[ $# -lt 2 ]]; then
        error "Usage: shipwright linear update <github-issue-num> <status>"
        echo ""
        echo -e "  Statuses: ${CYAN}started${RESET} | ${CYAN}review${RESET} | ${CYAN}done${RESET} | ${CYAN}failed${RESET}"
        echo ""
        echo -e "  ${DIM}shipwright linear update 42 started${RESET}    # → In Progress"
        echo -e "  ${DIM}shipwright linear update 42 review${RESET}     # → In Review"
        echo -e "  ${DIM}shipwright linear update 42 done${RESET}       # → Done"
        echo -e "  ${DIM}shipwright linear update 42 failed${RESET}     # → adds failure comment"
        exit 1
    fi

    local gh_issue="$1"
    local status="$2"
    local detail="${3:-}"

    # Find the Linear issue ID from the GitHub issue body
    local linear_id
    linear_id=$(gh issue view "$gh_issue" --json body --jq '.body' 2>/dev/null | \
        grep -o 'Linear ID:.*' | sed 's/.*\*\*Linear ID:\*\* //' | tr -d '[:space:]' || true)

    if [[ -z "$linear_id" ]]; then
        error "No Linear ID found in GitHub issue #${gh_issue}"
        echo -e "  ${DIM}The issue body must contain: **Linear ID:** <uuid>${RESET}"
        return 1
    fi

    # Map status to Linear state
    local target_state="" status_name=""
    case "$status" in
        started|in-progress|in_progress)
            target_state="$STATUS_IN_PROGRESS"
            status_name="In Progress"
            ;;
        review|in-review|in_review|pr)
            target_state="$STATUS_IN_REVIEW"
            status_name="In Review"
            ;;
        done|completed|merged)
            target_state="$STATUS_DONE"
            status_name="Done"
            ;;
        failed|error)
            # Don't change status, just add a comment
            local comment="Pipeline failed for GitHub issue #${gh_issue}"
            if [[ -n "$detail" ]]; then
                comment="${comment}\n\n${detail}"
            fi
            linear_add_comment "$linear_id" "$comment" || return 1
            warn "Added failure comment to Linear issue"
            emit_event "linear.update" "github_issue=$gh_issue" "status=failed"
            return 0
            ;;
        *)
            error "Unknown status: ${status}"
            echo -e "  Valid: ${CYAN}started${RESET} | ${CYAN}review${RESET} | ${CYAN}done${RESET} | ${CYAN}failed${RESET}"
            return 1
            ;;
    esac

    linear_update_status "$linear_id" "$target_state" || return 1

    # Add status transition comment
    local comment="Status updated to **${status_name}** (GitHub #${gh_issue})"
    if [[ -n "$detail" ]]; then
        comment="${comment}\n\n${detail}"
    fi
    linear_add_comment "$linear_id" "$comment" || true

    success "Linear issue updated → ${status_name} (GitHub #${gh_issue})"
    emit_event "linear.update" "github_issue=$gh_issue" "status=$status"
}

# ─── Status Dashboard ────────────────────────────────────────────────────

cmd_status() {
    check_api_key

    echo -e "${PURPLE}${BOLD}━━━ Linear Sync Status ━━━${RESET}"
    echo ""

    # Count issues by status
    local statuses=("$STATUS_BACKLOG:Backlog" "$STATUS_TODO:Todo" "$STATUS_IN_PROGRESS:In Progress" "$STATUS_IN_REVIEW:In Review" "$STATUS_DONE:Done")

    for entry in "${statuses[@]}"; do
        local state_id="${entry%%:*}"
        local state_name="${entry#*:}"

        local query='query($teamId: String!, $projectId: String!, $stateId: String!) {
            issues(filter: {
                team: { id: { eq: $teamId } }
                project: { id: { eq: $projectId } }
                state: { id: { eq: $stateId } }
            }) {
                nodes { id identifier title url }
            }
        }'

        local vars
        vars=$(jq -n \
            --arg teamId "$LINEAR_TEAM_ID" \
            --arg projectId "$LINEAR_PROJECT_ID" \
            --arg stateId "$state_id" \
            '{teamId: $teamId, projectId: $projectId, stateId: $stateId}')

        local response
        response=$(linear_graphql "$query" "$vars" 2>/dev/null) || {
            echo -e "  ${RED}✗${RESET} ${state_name}: ${DIM}(API error)${RESET}"
            continue
        }

        local count
        count=$(echo "$response" | jq '.data.issues.nodes | length')

        local color="$DIM"
        case "$state_name" in
            "In Progress") color="$CYAN" ;;
            "In Review")   color="$BLUE" ;;
            "Done")        color="$GREEN" ;;
            "Todo")        color="$YELLOW" ;;
        esac

        echo -e "  ${color}${BOLD}${state_name}${RESET}  ${count}"

        # Show individual issues for active states
        if [[ "$count" -gt 0 ]] && [[ "$state_name" != "Done" ]] && [[ "$state_name" != "Backlog" ]]; then
            local j=0
            while [[ $j -lt $count ]]; do
                local id title
                id=$(echo "$response" | jq -r ".data.issues.nodes[$j].identifier")
                title=$(echo "$response" | jq -r ".data.issues.nodes[$j].title")
                echo -e "    ${DIM}${id}${RESET}  ${title}"
                j=$((j + 1))
            done
        fi
    done

    echo ""

    # Show recent sync events
    if [[ -f "$EVENTS_FILE" ]]; then
        local recent_syncs
        recent_syncs=$(grep '"type":"linear\.' "$EVENTS_FILE" 2>/dev/null | tail -5 || true)
        if [[ -n "$recent_syncs" ]]; then
            echo -e "${BOLD}Recent Activity${RESET}"
            echo "$recent_syncs" | while IFS= read -r line; do
                local ts type
                ts=$(echo "$line" | jq -r '.ts' 2>/dev/null || true)
                type=$(echo "$line" | jq -r '.type' 2>/dev/null || true)
                local short_ts="${ts:-unknown}"
                echo -e "  ${DIM}${short_ts}${RESET}  ${type}"
            done
            echo ""
        fi
    fi
}

# ─── Init: Save Configuration ────────────────────────────────────────────

cmd_init() {
    echo -e "${PURPLE}${BOLD}━━━ Linear Integration Setup ━━━${RESET}"
    echo ""

    mkdir -p "$CONFIG_DIR"

    # API Key
    local api_key="${LINEAR_API_KEY:-}"
    if [[ -z "$api_key" ]]; then
        echo -e "  ${CYAN}1.${RESET} Go to ${DIM}https://linear.app/settings/api${RESET}"
        echo -e "  ${CYAN}2.${RESET} Create a personal API key"
        echo -e "  ${CYAN}3.${RESET} Paste it below"
        echo ""
        read -rp "  Linear API Key: " api_key
        if [[ -z "$api_key" ]]; then
            error "API key is required"
            exit 1
        fi
    fi

    local team_id="${LINEAR_TEAM_ID:-83deb533-69d2-43ef-bc58-eadb6e72a8f2}"
    local project_id="${LINEAR_PROJECT_ID:-b262d625-5bbe-47bd-9f89-df27c45eba8b}"

    # Write config atomically
    local tmp_config="${LINEAR_CONFIG}.tmp"
    jq -n \
        --arg api_key "$api_key" \
        --arg team_id "$team_id" \
        --arg project_id "$project_id" \
        --arg created_at "$(now_iso)" \
        '{
            api_key: $api_key,
            team_id: $team_id,
            project_id: $project_id,
            created_at: $created_at
        }' > "$tmp_config"
    mv "$tmp_config" "$LINEAR_CONFIG"
    chmod 600 "$LINEAR_CONFIG"

    success "Configuration saved to ${LINEAR_CONFIG}"
    echo ""

    # Validate the key works
    info "Validating API key..."
    LINEAR_API_KEY="$api_key"
    local test_query='query { viewer { id name email } }'
    local test_response
    test_response=$(linear_graphql "$test_query") || {
        error "API key validation failed — check your key"
        exit 1
    }

    local viewer_name
    viewer_name=$(echo "$test_response" | jq -r '.data.viewer.name // "Unknown"')
    success "Authenticated as: ${viewer_name}"

    emit_event "linear.init" "user=$viewer_name"
}

# ─── Helper: Update Linear Issue Status ──────────────────────────────────

linear_update_status() {
    local issue_id="$1"
    local state_id="$2"

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

# ─── Helper: Add Comment to Linear Issue ─────────────────────────────────

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

# ─── Helper: Attach PR link to Linear Issue ──────────────────────────────

linear_attach_pr() {
    local issue_id="$1"
    local pr_url="$2"
    local pr_title="${3:-Pull Request}"

    local body
    body=$(printf "PR linked: [%s](%s)" "$pr_title" "$pr_url")
    linear_add_comment "$issue_id" "$body"
}

# ─── Daemon Integration: Notify Linear on Pipeline Events ────────────────
# Called by sw-daemon.sh at spawn, stage transition, completion, and failure.
# This function is designed to be sourced or called externally.

linear_notify() {
    local event="$1"
    local gh_issue="${2:-}"
    local detail="${3:-}"

    # Delegate to tracker router if available (preferred path)
    if [[ -f "$SCRIPT_DIR/sw-tracker.sh" ]]; then
        "$SCRIPT_DIR/sw-tracker.sh" notify "$event" "$gh_issue" "$detail" 2>/dev/null || true
        return 0
    fi

    # Fallback: direct Linear notification (backward compatibility)
    load_config
    if [[ -z "$LINEAR_API_KEY" ]]; then
        return 0  # silently skip if no Linear integration
    fi

    # Find the Linear issue ID from GitHub issue
    local linear_id=""
    if [[ -n "$gh_issue" ]]; then
        linear_id=$(gh issue view "$gh_issue" --json body --jq '.body' 2>/dev/null | \
            grep -o 'Linear ID:.*' | sed 's/.*\*\*Linear ID:\*\* //' | tr -d '[:space:]' || true)
    fi

    if [[ -z "$linear_id" ]]; then
        return 0  # no linked Linear issue
    fi

    case "$event" in
        spawn|started)
            linear_update_status "$linear_id" "$STATUS_IN_PROGRESS" || true
            linear_add_comment "$linear_id" "Pipeline started for GitHub issue #${gh_issue}" || true
            ;;
        review|pr-created)
            linear_update_status "$linear_id" "$STATUS_IN_REVIEW" || true
            if [[ -n "$detail" ]]; then
                linear_attach_pr "$linear_id" "$detail" "PR for #${gh_issue}" || true
            fi
            ;;
        completed|done)
            linear_update_status "$linear_id" "$STATUS_DONE" || true
            linear_add_comment "$linear_id" "Pipeline completed successfully for GitHub issue #${gh_issue}" || true
            ;;
        failed)
            local msg="Pipeline failed for GitHub issue #${gh_issue}"
            if [[ -n "$detail" ]]; then
                msg="${msg}\n\nDetails:\n${detail}"
            fi
            linear_add_comment "$linear_id" "$msg" || true
            ;;
    esac

    emit_event "linear.notify" "event=$event" "github_issue=$gh_issue"
}

# ─── Help ────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright linear${RESET} — Linear ↔ GitHub Bidirectional Sync"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright linear${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}sync${RESET} [--dry-run]              Sync Linear Todo issues → GitHub"
    echo -e "  ${CYAN}update${RESET} <issue> <status>       Update linked Linear ticket status"
    echo -e "  ${CYAN}status${RESET}                        Show sync dashboard"
    echo -e "  ${CYAN}init${RESET}                          Configure Linear API key"
    echo -e "  ${CYAN}help${RESET}                          Show this help"
    echo ""
    echo -e "${BOLD}STATUS VALUES${RESET}"
    echo -e "  ${CYAN}started${RESET}     Pipeline spawned   → Linear: In Progress"
    echo -e "  ${CYAN}review${RESET}      PR created         → Linear: In Review"
    echo -e "  ${CYAN}done${RESET}        Pipeline complete   → Linear: Done"
    echo -e "  ${CYAN}failed${RESET}      Pipeline failed     → Linear: adds failure comment"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright linear init${RESET}                    # Set up API key"
    echo -e "  ${DIM}shipwright linear sync${RESET}                    # Sync Todo → GitHub"
    echo -e "  ${DIM}shipwright linear sync --dry-run${RESET}          # Preview what would sync"
    echo -e "  ${DIM}shipwright linear update 42 started${RESET}       # Mark as In Progress"
    echo -e "  ${DIM}shipwright linear update 42 review${RESET}        # Mark as In Review"
    echo -e "  ${DIM}shipwright linear update 42 done${RESET}          # Mark as Done"
    echo -e "  ${DIM}shipwright linear status${RESET}                  # Show dashboard"
    echo ""
    echo -e "${BOLD}ENVIRONMENT${RESET}"
    echo -e "  ${DIM}LINEAR_API_KEY${RESET}      API key (or use 'linear init' to save)"
    echo -e "  ${DIM}LINEAR_TEAM_ID${RESET}      Override team ID"
    echo -e "  ${DIM}LINEAR_PROJECT_ID${RESET}   Override project ID"
}

# ─── Command Router ─────────────────────────────────────────────────────

main() {
    load_config

    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        sync)       cmd_sync "$@" ;;
        update)     cmd_update "$@" ;;
        status)     cmd_status "$@" ;;
        init)       cmd_init "$@" ;;
        notify)     linear_notify "$@" ;;
        help|--help|-h) show_help ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
