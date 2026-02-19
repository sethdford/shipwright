#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright jira — Jira ↔ GitHub Bidirectional Sync                     ║
# ║  Sync issues · Update statuses · Link PRs · Pipeline integration        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
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
# ─── Configuration ─────────────────────────────────────────────────────────
CONFIG_DIR="${HOME}/.shipwright"
TRACKER_CONFIG="${CONFIG_DIR}/tracker-config.json"

JIRA_BASE_URL=""
JIRA_EMAIL=""
JIRA_API_TOKEN=""
JIRA_PROJECT_KEY=""

load_config() {
    if [[ -f "$TRACKER_CONFIG" ]]; then
        JIRA_BASE_URL="${JIRA_BASE_URL:-$(jq -r '.jira_base_url // empty' "$TRACKER_CONFIG" 2>/dev/null || true)}"
        JIRA_EMAIL="${JIRA_EMAIL:-$(jq -r '.jira_email // empty' "$TRACKER_CONFIG" 2>/dev/null || true)}"
        JIRA_API_TOKEN="${JIRA_API_TOKEN:-$(jq -r '.jira_api_token // empty' "$TRACKER_CONFIG" 2>/dev/null || true)}"
        JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-$(jq -r '.jira_project_key // empty' "$TRACKER_CONFIG" 2>/dev/null || true)}"
    fi

    JIRA_BASE_URL="${JIRA_BASE_URL:-}"
    JIRA_EMAIL="${JIRA_EMAIL:-}"
    JIRA_API_TOKEN="${JIRA_API_TOKEN:-}"
    JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-}"
}

check_config() {
    if [[ -z "$JIRA_BASE_URL" ]] || [[ -z "$JIRA_EMAIL" ]] || [[ -z "$JIRA_API_TOKEN" ]]; then
        error "Jira not configured"
        echo ""
        echo -e "  Set via environment:  ${DIM}export JIRA_BASE_URL=https://your-org.atlassian.net${RESET}"
        echo -e "                        ${DIM}export JIRA_EMAIL=you@example.com${RESET}"
        echo -e "                        ${DIM}export JIRA_API_TOKEN=your-token${RESET}"
        echo -e "  Or run:               ${DIM}shipwright jira init${RESET}"
        exit 1
    fi
}

# ─── Jira REST API Helper ─────────────────────────────────────────────────
# Executes a REST request against the Jira API.
# Uses Basic auth (email:token base64-encoded).
jira_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local auth
    auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64)
    local args=(-sf --connect-timeout "$(_config_get_int "network.connect_timeout" 10)" --max-time "$(_config_get_int "network.max_time" 30)" -X "$method" \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${JIRA_BASE_URL}/rest/api/3/${endpoint}" 2>&1
}

# ─── Helper: Add ADF Comment to Jira Issue ─────────────────────────────────
# Jira comments use Atlassian Document Format (ADF).
jira_add_comment() {
    local issue_key="$1" body_text="$2"
    local payload
    payload=$(jq -n --arg text "$body_text" '{
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

# ─── Helper: Transition Jira Issue ─────────────────────────────────────────
# Finds the transition ID by name and applies it.
jira_transition() {
    local issue_key="$1" target_name="$2"
    local transitions
    transitions=$(jira_api "GET" "issue/${issue_key}/transitions") || return 1
    local tid
    tid=$(echo "$transitions" | jq -r --arg name "$target_name" \
        '.transitions[] | select(.name == $name) | .id' 2>/dev/null || true)
    if [[ -z "$tid" ]]; then
        return 0  # transition not available — silently skip
    fi
    local payload
    payload=$(jq -n --arg id "$tid" '{transition: {id: $id}}')
    jira_api "POST" "issue/${issue_key}/transitions" "$payload"
}

# ─── Sync: Jira Todo → GitHub Issues ──────────────────────────────────────

cmd_sync() {
    check_config
    info "Syncing Jira To Do issues → GitHub..."

    local dry_run=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            *) shift ;;
        esac
    done

    # Fetch Jira issues in "To Do" status within the project
    local jql
    jql=$(printf 'project = %s AND status = "To Do"' "$JIRA_PROJECT_KEY")
    local encoded_jql
    encoded_jql=$(printf '%s' "$jql" | jq -sRr @uri)

    local response
    response=$(jira_api "GET" "search?jql=${encoded_jql}&fields=summary,description,priority,status,labels") || {
        error "Failed to fetch Jira issues"
        return 1
    }

    local count
    count=$(echo "$response" | jq '.issues | length')
    if [[ "$count" -eq 0 ]]; then
        info "No Jira issues in To Do status"
        return 0
    fi

    info "Found ${count} Jira issue(s) in To Do"

    local synced=0
    local skipped=0

    # Process each Jira issue
    local i=0
    while [[ $i -lt $count ]]; do
        local issue
        issue=$(echo "$response" | jq ".issues[$i]")
        local jira_key title description priority_name
        jira_key=$(echo "$issue" | jq -r '.key')
        title=$(echo "$issue" | jq -r '.fields.summary')
        description=$(echo "$issue" | jq -r '.fields.description // ""')
        priority_name=$(echo "$issue" | jq -r '.fields.priority.name // ""')

        # Extract plain text from ADF description if present
        if echo "$description" | jq -e '.type' >/dev/null 2>&1; then
            description=$(echo "$description" | jq -r '
                [.. | .text? // empty] | join(" ")
            ' 2>/dev/null || echo "")
        fi

        # Check if GitHub issue already exists for this Jira issue
        local existing_gh
        existing_gh=$(gh issue list --label "$(_config_get "labels.ready_to_build" "ready-to-build")" --search "Jira: ${jira_key}" --json number --jq '.[0].number // empty' 2>/dev/null || true)

        if [[ -n "$existing_gh" ]]; then
            echo -e "  ${DIM}Skip${RESET} ${jira_key}: ${title} ${DIM}(GitHub #${existing_gh})${RESET}"
            skipped=$((skipped + 1))
            i=$((i + 1))
            continue
        fi

        # Map priority to label
        local priority_label=""
        case "$priority_name" in
            Highest|Blocker) priority_label="priority-urgent" ;;
            High)            priority_label="priority-high" ;;
            Medium)          priority_label="priority-medium" ;;
            Low|Lowest)      priority_label="priority-low" ;;
        esac

        # Build GitHub issue body with Jira back-link
        local jira_url="${JIRA_BASE_URL}/browse/${jira_key}"
        local gh_body
        gh_body=$(printf "## %s\n\n%s\n\n---\n**Jira:** [%s](%s)\n**Jira Key:** %s" \
            "$title" "$description" "$jira_key" "$jira_url" "$jira_key")

        if [[ "$dry_run" == "true" ]]; then
            echo -e "  ${CYAN}Would create${RESET} GitHub issue: ${title} ${DIM}(${jira_key})${RESET}"
            synced=$((synced + 1))
        else
            # Create GitHub issue
            local labels="$(_config_get "labels.ready_to_build" "ready-to-build")"
            if [[ -n "$priority_label" ]]; then
                labels="${labels},${priority_label}"
            fi

            local gh_num
            gh_num=$(gh issue create --title "$title" --body "$gh_body" --label "$labels" --json number --jq '.number' 2>&1) || {
                error "Failed to create GitHub issue for ${jira_key}: ${gh_num}"
                i=$((i + 1))
                continue
            }

            # Add comment on Jira issue linking back to GitHub
            local comment_body
            comment_body=$(printf "Synced to GitHub issue #%s — the daemon will pick this up for autonomous delivery." "$gh_num")
            jira_add_comment "$jira_key" "$comment_body" >/dev/null 2>&1 || true

            # Move Jira issue to In Progress
            jira_transition "$jira_key" "In Progress" >/dev/null 2>&1 || true

            success "${jira_key} → GitHub #${gh_num}: ${title}"
            emit_event "jira.sync" "jira_key=$jira_key" "github_issue=$gh_num" "title=$title"
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

# ─── Update: GitHub → Jira Status ─────────────────────────────────────────

cmd_update() {
    check_config

    if [[ $# -lt 2 ]]; then
        error "Usage: shipwright jira update <github-issue-num> <status>"
        echo ""
        echo -e "  Statuses: ${CYAN}started${RESET} | ${CYAN}review${RESET} | ${CYAN}done${RESET} | ${CYAN}failed${RESET}"
        echo ""
        echo -e "  ${DIM}shipwright jira update 42 started${RESET}    # → In Progress"
        echo -e "  ${DIM}shipwright jira update 42 review${RESET}     # → In Review"
        echo -e "  ${DIM}shipwright jira update 42 done${RESET}       # → Done"
        echo -e "  ${DIM}shipwright jira update 42 failed${RESET}     # → adds failure comment"
        exit 1
    fi

    local gh_issue="$1"
    local status="$2"
    local detail="${3:-}"

    # Find the Jira key from the GitHub issue body
    local jira_key
    jira_key=$(gh issue view "$gh_issue" --json body --jq '.body' 2>/dev/null | \
        grep -o 'Jira Key:.*' | sed 's/.*\*\*Jira Key:\*\* //' | tr -d '[:space:]' || true)

    if [[ -z "$jira_key" ]]; then
        error "No Jira Key found in GitHub issue #${gh_issue}"
        echo -e "  ${DIM}The issue body must contain: **Jira Key:** PROJECT-123${RESET}"
        return 1
    fi

    # Map status to Jira transition
    local target_name="" status_label=""
    case "$status" in
        started|in-progress|in_progress)
            target_name="In Progress"
            status_label="In Progress"
            ;;
        review|in-review|in_review|pr)
            target_name="In Review"
            status_label="In Review"
            ;;
        done|completed|merged)
            target_name="Done"
            status_label="Done"
            ;;
        failed|error)
            # Don't change status, just add a comment
            local comment="Pipeline failed for GitHub issue #${gh_issue}"
            if [[ -n "$detail" ]]; then
                comment="${comment}\n\n${detail}"
            fi
            jira_add_comment "$jira_key" "$comment" >/dev/null 2>&1 || return 1
            warn "Added failure comment to Jira issue ${jira_key}"
            emit_event "jira.update" "github_issue=$gh_issue" "status=failed"
            return 0
            ;;
        *)
            error "Unknown status: ${status}"
            echo -e "  Valid: ${CYAN}started${RESET} | ${CYAN}review${RESET} | ${CYAN}done${RESET} | ${CYAN}failed${RESET}"
            return 1
            ;;
    esac

    jira_transition "$jira_key" "$target_name" >/dev/null 2>&1 || return 1

    # Add status transition comment
    local comment="Status updated to ${status_label} (GitHub #${gh_issue})"
    if [[ -n "$detail" ]]; then
        comment="${comment}\n\n${detail}"
    fi
    jira_add_comment "$jira_key" "$comment" >/dev/null 2>&1 || true

    success "Jira ${jira_key} updated → ${status_label} (GitHub #${gh_issue})"
    emit_event "jira.update" "github_issue=$gh_issue" "jira_key=$jira_key" "status=$status"
}

# ─── Status Dashboard ──────────────────────────────────────────────────────

cmd_status() {
    check_config

    echo -e "${PURPLE}${BOLD}━━━ Jira Board Status ━━━${RESET}"
    echo ""

    # Query issues by status
    local statuses="To Do:To Do:YELLOW In Progress:In Progress:CYAN In Review:In Review:BLUE Done:Done:GREEN"

    for entry in $statuses; do
        local status_name="${entry%%:*}"
        local rest="${entry#*:}"
        local display_name="${rest%%:*}"
        local color_name="${rest#*:}"

        local color="$DIM"
        case "$color_name" in
            CYAN)   color="$CYAN" ;;
            BLUE)   color="$BLUE" ;;
            GREEN)  color="$GREEN" ;;
            YELLOW) color="$YELLOW" ;;
        esac

        # URL-encode the status name for JQL
        local jql
        jql=$(printf 'project = %s AND status = "%s"' "$JIRA_PROJECT_KEY" "$status_name")
        local encoded_jql
        encoded_jql=$(printf '%s' "$jql" | jq -sRr @uri)

        local response
        response=$(jira_api "GET" "search?jql=${encoded_jql}&fields=summary,status&maxResults=50" 2>/dev/null) || {
            echo -e "  ${RED}✗${RESET} ${display_name}: ${DIM}(API error)${RESET}"
            continue
        }

        local count
        count=$(echo "$response" | jq '.total // 0')

        echo -e "  ${color}${BOLD}${display_name}${RESET}  ${count}"

        # Show individual issues for active states
        if [[ "$count" -gt 0 ]] && [[ "$status_name" != "Done" ]]; then
            local issue_count
            issue_count=$(echo "$response" | jq '.issues | length')
            local j=0
            while [[ $j -lt $issue_count ]]; do
                local key title
                key=$(echo "$response" | jq -r ".issues[$j].key")
                title=$(echo "$response" | jq -r ".issues[$j].fields.summary")
                echo -e "    ${DIM}${key}${RESET}  ${title}"
                j=$((j + 1))
            done
        fi
    done

    echo ""

    # Show recent sync events
    if [[ -f "$EVENTS_FILE" ]]; then
        local recent_syncs
        recent_syncs=$(grep '"type":"jira\.' "$EVENTS_FILE" 2>/dev/null | tail -5 || true)
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

# ─── Init: Save Configuration ──────────────────────────────────────────────

cmd_init() {
    echo -e "${PURPLE}${BOLD}━━━ Jira Integration Setup ━━━${RESET}"
    echo ""

    mkdir -p "$CONFIG_DIR"

    # Base URL
    local base_url="${JIRA_BASE_URL:-}"
    if [[ -z "$base_url" ]]; then
        echo -e "  ${CYAN}1.${RESET} Enter your Jira base URL (e.g. ${DIM}https://your-org.atlassian.net${RESET})"
        echo ""
        read -rp "  Jira Base URL: " base_url
        if [[ -z "$base_url" ]]; then
            error "Base URL is required"
            exit 1
        fi
        # Strip trailing slash
        base_url="${base_url%/}"
    fi

    # Email
    local email="${JIRA_EMAIL:-}"
    if [[ -z "$email" ]]; then
        echo ""
        echo -e "  ${CYAN}2.${RESET} Enter your Jira account email"
        echo ""
        read -rp "  Email: " email
        if [[ -z "$email" ]]; then
            error "Email is required"
            exit 1
        fi
    fi

    # API Token
    local api_token="${JIRA_API_TOKEN:-}"
    if [[ -z "$api_token" ]]; then
        echo ""
        echo -e "  ${CYAN}3.${RESET} Create an API token at ${DIM}https://id.atlassian.com/manage-profile/security/api-tokens${RESET}"
        echo -e "     Paste it below"
        echo ""
        read -rp "  API Token: " api_token
        if [[ -z "$api_token" ]]; then
            error "API token is required"
            exit 1
        fi
    fi

    # Project Key
    local project_key="${JIRA_PROJECT_KEY:-}"
    if [[ -z "$project_key" ]]; then
        echo ""
        echo -e "  ${CYAN}4.${RESET} Enter your Jira project key (e.g. ${DIM}PROJ${RESET})"
        echo ""
        read -rp "  Project Key: " project_key
        if [[ -z "$project_key" ]]; then
            error "Project key is required"
            exit 1
        fi
    fi

    # Merge into existing tracker-config.json if present
    local tmp_config="${TRACKER_CONFIG}.tmp"
    local existing="{}"
    if [[ -f "$TRACKER_CONFIG" ]]; then
        existing=$(cat "$TRACKER_CONFIG" 2>/dev/null || echo "{}")
    fi

    echo "$existing" | jq \
        --arg base_url "$base_url" \
        --arg email "$email" \
        --arg api_token "$api_token" \
        --arg project_key "$project_key" \
        --arg provider "jira" \
        --arg updated_at "$(now_iso)" \
        '. + {
            provider: $provider,
            jira_base_url: $base_url,
            jira_email: $email,
            jira_api_token: $api_token,
            jira_project_key: $project_key,
            jira_updated_at: $updated_at
        }' > "$tmp_config"
    mv "$tmp_config" "$TRACKER_CONFIG"
    chmod 600 "$TRACKER_CONFIG"

    success "Configuration saved to ${TRACKER_CONFIG}"
    echo ""

    # Validate connection
    info "Validating Jira connection..."
    JIRA_BASE_URL="$base_url"
    JIRA_EMAIL="$email"
    JIRA_API_TOKEN="$api_token"
    JIRA_PROJECT_KEY="$project_key"

    local test_response
    test_response=$(jira_api "GET" "myself") || {
        error "Jira connection failed — check your credentials"
        exit 1
    }

    local display_name
    display_name=$(echo "$test_response" | jq -r '.displayName // "Unknown"')
    success "Authenticated as: ${display_name}"

    emit_event "jira.init" "user=$display_name" "project=$project_key"
}

# ─── Daemon Integration: Notify Jira on Pipeline Events ───────────────────
# Called by sw-daemon.sh at spawn, stage transition, completion, and failure.
# This function is designed to be sourced or called externally.

jira_notify() {
    local event="$1"
    local gh_issue="${2:-}"
    local detail="${3:-}"

    # Only proceed if Jira config exists and credentials are available
    load_config
    if [[ -z "$JIRA_BASE_URL" ]] || [[ -z "$JIRA_EMAIL" ]] || [[ -z "$JIRA_API_TOKEN" ]]; then
        return 0  # silently skip if no Jira integration
    fi

    # Find the Jira key from GitHub issue
    local jira_key=""
    if [[ -n "$gh_issue" ]]; then
        jira_key=$(gh issue view "$gh_issue" --json body --jq '.body' 2>/dev/null | \
            grep -o 'Jira Key:.*' | sed 's/.*\*\*Jira Key:\*\* //' | tr -d '[:space:]' || true)
    fi

    if [[ -z "$jira_key" ]]; then
        return 0  # no linked Jira issue
    fi

    case "$event" in
        spawn|started)
            jira_transition "$jira_key" "In Progress" >/dev/null 2>&1 || true
            jira_add_comment "$jira_key" "Pipeline started for GitHub issue #${gh_issue}" >/dev/null 2>&1 || true
            ;;
        review|pr-created)
            jira_transition "$jira_key" "In Review" >/dev/null 2>&1 || true
            if [[ -n "$detail" ]]; then
                jira_add_comment "$jira_key" "PR linked: ${detail} (GitHub #${gh_issue})" >/dev/null 2>&1 || true
            fi
            ;;
        completed|done)
            jira_transition "$jira_key" "Done" >/dev/null 2>&1 || true
            jira_add_comment "$jira_key" "Pipeline completed successfully for GitHub issue #${gh_issue}" >/dev/null 2>&1 || true
            ;;
        failed)
            local msg="Pipeline failed for GitHub issue #${gh_issue}"
            if [[ -n "$detail" ]]; then
                msg="${msg}\n\nDetails:\n${detail}"
            fi
            jira_add_comment "$jira_key" "$msg" >/dev/null 2>&1 || true
            ;;
    esac

    emit_event "jira.notify" "event=$event" "github_issue=$gh_issue" "jira_key=$jira_key"
}

# ─── Help ──────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright jira${RESET} — Jira ↔ GitHub Bidirectional Sync"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright jira${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}sync${RESET} [--dry-run]              Sync Jira To Do issues → GitHub"
    echo -e "  ${CYAN}update${RESET} <issue> <status>       Update linked Jira ticket status"
    echo -e "  ${CYAN}status${RESET}                        Show Jira board dashboard"
    echo -e "  ${CYAN}init${RESET}                          Configure Jira connection"
    echo -e "  ${CYAN}help${RESET}                          Show this help"
    echo ""
    echo -e "${BOLD}STATUS VALUES${RESET}"
    echo -e "  ${CYAN}started${RESET}     Pipeline spawned   → Jira: In Progress"
    echo -e "  ${CYAN}review${RESET}      PR created         → Jira: In Review"
    echo -e "  ${CYAN}done${RESET}        Pipeline complete   → Jira: Done"
    echo -e "  ${CYAN}failed${RESET}      Pipeline failed     → Jira: adds failure comment"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright jira init${RESET}                    # Set up Jira connection"
    echo -e "  ${DIM}shipwright jira sync${RESET}                    # Sync To Do → GitHub"
    echo -e "  ${DIM}shipwright jira sync --dry-run${RESET}          # Preview what would sync"
    echo -e "  ${DIM}shipwright jira update 42 started${RESET}       # Mark as In Progress"
    echo -e "  ${DIM}shipwright jira update 42 review${RESET}        # Mark as In Review"
    echo -e "  ${DIM}shipwright jira update 42 done${RESET}          # Mark as Done"
    echo -e "  ${DIM}shipwright jira status${RESET}                  # Show board dashboard"
    echo ""
    echo -e "${BOLD}ENVIRONMENT${RESET}"
    echo -e "  ${DIM}JIRA_BASE_URL${RESET}       Jira instance URL (or use 'jira init' to save)"
    echo -e "  ${DIM}JIRA_EMAIL${RESET}          Account email for authentication"
    echo -e "  ${DIM}JIRA_API_TOKEN${RESET}      API token from Atlassian account"
    echo -e "  ${DIM}JIRA_PROJECT_KEY${RESET}    Jira project key (e.g. PROJ)"
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
        notify)     jira_notify "$@" ;;
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
