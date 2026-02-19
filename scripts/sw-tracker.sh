#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tracker — Provider Router for Issue Tracker Integration      ║
# ║  Route notifications · Configure providers · Linear & Jira support      ║
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
# ─── Configuration ─────────────────────────────────────────────────────────
CONFIG_DIR="${HOME}/.shipwright"
TRACKER_CONFIG="${CONFIG_DIR}/tracker-config.json"
TRACKER_PROVIDER=""

# Load tracker config: reads provider, then sources the right provider script
load_tracker_config() {
    # Already loaded?
    if [[ -n "$TRACKER_PROVIDER" ]]; then
        return 0
    fi

    # Check env var first
    local provider="${TRACKER_PROVIDER_OVERRIDE:-}"

    # Fall back to tracker-config.json
    if [[ -z "$provider" && -f "$TRACKER_CONFIG" ]]; then
        provider=$(jq -r '.provider // "none"' "$TRACKER_CONFIG" 2>/dev/null || echo "none")
    fi

    # Fall back to daemon-config.json tracker block
    if [[ -z "$provider" || "$provider" == "none" ]]; then
        local daemon_cfg=".claude/daemon-config.json"
        if [[ -f "$daemon_cfg" ]]; then
            provider=$(jq -r '.tracker.provider // "none"' "$daemon_cfg" 2>/dev/null || echo "none")
        fi
    fi

    TRACKER_PROVIDER="${provider:-none}"

    case "$TRACKER_PROVIDER" in
        linear)
            if [[ -f "$SCRIPT_DIR/sw-tracker-linear.sh" ]]; then
                source "$SCRIPT_DIR/sw-tracker-linear.sh"
                return 0
            else
                warn "Linear provider script not found: $SCRIPT_DIR/sw-tracker-linear.sh"
            fi
            ;;
        jira)
            if [[ -f "$SCRIPT_DIR/sw-tracker-jira.sh" ]]; then
                source "$SCRIPT_DIR/sw-tracker-jira.sh"
                return 0
            else
                warn "Jira provider script not found: $SCRIPT_DIR/sw-tracker-jira.sh"
            fi
            ;;
        github)
            if [[ -f "$SCRIPT_DIR/sw-tracker-github.sh" ]]; then
                source "$SCRIPT_DIR/sw-tracker-github.sh"
                return 0
            else
                warn "GitHub provider script not found: $SCRIPT_DIR/sw-tracker-github.sh"
            fi
            ;;
        none|"") return 0 ;;
        *)
            warn "Unknown tracker provider: $TRACKER_PROVIDER"
            TRACKER_PROVIDER="none"
            ;;
    esac
    return 0
}

# Check if a tracker is configured and available
tracker_available() {
    load_tracker_config
    [[ "$TRACKER_PROVIDER" != "none" && -n "$TRACKER_PROVIDER" ]]
}

# ─── Internal Dispatcher ──────────────────────────────────────────────────
# Routes a provider function call to the loaded provider, with fallback to GitHub

_dispatch_provider() {
    local func="$1"
    shift

    load_tracker_config

    # Build the function name
    local provider_func="provider_${func}"

    # Provider scripts define provider_* functions
    if type "$provider_func" >/dev/null 2>&1; then
        "$provider_func" "$@"
        return $?
    else
        # Fall back to GitHub if provider doesn't define the function
        # (for backward compatibility with minimal providers like Jira/Linear notify-only)
        if [[ "$TRACKER_PROVIDER" != "github" && "$TRACKER_PROVIDER" != "none" ]]; then
            # Try GitHub provider
            if [[ -f "$SCRIPT_DIR/sw-tracker-github.sh" ]]; then
                source "$SCRIPT_DIR/sw-tracker-github.sh"
                if type "$provider_func" >/dev/null 2>&1; then
                    "$provider_func" "$@"
                    return $?
                fi
            fi
        fi
        return 1
    fi
}

# ─── Discovery Interface ────────────────────────────────────────────────────
# Used by daemon to discover issues from the configured tracker

# Discover issues matching criteria
# Usage: tracker_discover_issues <label> [state] [limit]
# Output: JSON array of {id, title, labels[], state}
tracker_discover_issues() {
    _dispatch_provider "discover_issues" "$@"
}

# Fetch single issue details
# Usage: tracker_get_issue <issue_id>
# Output: JSON {id, title, body, labels[], state}
tracker_get_issue() {
    _dispatch_provider "get_issue" "$@"
}

# Fetch issue body text only
# Usage: tracker_get_issue_body <issue_id>
# Output: plain text body
tracker_get_issue_body() {
    _dispatch_provider "get_issue_body" "$@"
}

# ─── CRUD Interface ───────────────────────────────────────────────────────
# Used by pipeline to modify issues

# Add label to issue
# Usage: tracker_add_label <issue_id> <label>
tracker_add_label() {
    _dispatch_provider "add_label" "$@"
}

# Remove label from issue
# Usage: tracker_remove_label <issue_id> <label>
tracker_remove_label() {
    _dispatch_provider "remove_label" "$@"
}

# Add comment to issue
# Usage: tracker_comment <issue_id> <body>
tracker_comment() {
    _dispatch_provider "comment" "$@"
}

# Close/resolve issue
# Usage: tracker_close_issue <issue_id>
tracker_close_issue() {
    _dispatch_provider "close_issue" "$@"
}

# Create new issue
# Usage: tracker_create_issue <title> <body> [labels]
# Output: JSON {id, title}
tracker_create_issue() {
    _dispatch_provider "create_issue" "$@"
}

# ─── Notification Interface (Legacy) ───────────────────────────────────────
# Route notification to the active provider
# Usage: tracker_notify <event> <gh_issue> [detail]
# Events: spawn, started, stage_complete, stage_failed, review, pr-created, completed, done, failed
tracker_notify() {
    local event="$1"
    local gh_issue="${2:-}"
    local detail="${3:-}"

    load_tracker_config

    if [[ "$TRACKER_PROVIDER" == "none" || -z "$TRACKER_PROVIDER" ]]; then
        return 0  # silently skip when no provider configured
    fi

    # Provider scripts define provider_notify()
    if type provider_notify >/dev/null 2>&1; then
        provider_notify "$event" "$gh_issue" "$detail"
    else
        warn "Provider '$TRACKER_PROVIDER' loaded but provider_notify() not defined"
    fi
}

# ─── Interactive Init ──────────────────────────────────────────────────────

cmd_init() {
    echo -e "${PURPLE}${BOLD}━━━ Tracker Integration Setup ━━━${RESET}"
    echo ""

    mkdir -p "$CONFIG_DIR"

    echo -e "  ${BOLD}Select a tracker provider:${RESET}"
    echo ""
    echo -e "  ${CYAN}1${RESET}) Linear"
    echo -e "  ${CYAN}2${RESET}) Jira"
    echo -e "  ${CYAN}3${RESET}) None (disable)"
    echo ""
    read -rp "  Choice [1-3]: " choice

    local provider="none"
    case "$choice" in
        1) provider="linear" ;;
        2) provider="jira" ;;
        3) provider="none" ;;
        *)
            error "Invalid choice"
            exit 1
            ;;
    esac

    if [[ "$provider" == "none" ]]; then
        # Write minimal config
        local tmp_config="${TRACKER_CONFIG}.tmp"
        jq -n --arg provider "none" --arg updated "$(now_iso)" \
            '{provider: $provider, updated_at: $updated}' > "$tmp_config"
        if [[ -s "$tmp_config" ]]; then
            mv "$tmp_config" "$TRACKER_CONFIG"
        else
            rm -f "$tmp_config"
            error "Failed to write tracker config"
            return 1
        fi
        success "Tracker disabled"
        return 0
    fi

    if [[ "$provider" == "linear" ]]; then
        _init_linear
    elif [[ "$provider" == "jira" ]]; then
        _init_jira
    fi

    emit_event "tracker.init" "provider=$provider"
}

_init_linear() {
    echo ""
    echo -e "  ${CYAN}1.${RESET} Go to ${DIM}https://linear.app/settings/api${RESET}"
    echo -e "  ${CYAN}2.${RESET} Create a personal API key"
    echo -e "  ${CYAN}3.${RESET} Paste it below"
    echo ""
    read -rp "  Linear API Key: " api_key
    if [[ -z "$api_key" ]]; then
        error "API key is required"
        exit 1
    fi

    read -rp "  Team ID [press Enter for default]: " team_id
    team_id="${team_id:-}"
    read -rp "  Project ID [press Enter for default]: " project_id
    project_id="${project_id:-}"

    local tmp_config="${TRACKER_CONFIG}.tmp"
    jq -n \
        --arg provider "linear" \
        --arg api_key "$api_key" \
        --arg team_id "$team_id" \
        --arg project_id "$project_id" \
        --arg updated "$(now_iso)" \
        '{
            provider: $provider,
            linear: {
                api_key: $api_key,
                team_id: $team_id,
                project_id: $project_id
            },
            updated_at: $updated
        }' > "$tmp_config"
    if [[ -s "$tmp_config" ]]; then
        mv "$tmp_config" "$TRACKER_CONFIG"
        chmod 600 "$TRACKER_CONFIG"
    else
        rm -f "$tmp_config"
        error "Failed to write tracker config"
        return 1
    fi

    success "Linear tracker configured"
    echo ""

    # Validate connection
    info "Validating API key..."
    local payload
    payload=$(jq -n --arg q 'query { viewer { id name } }' '{query: $q}')
    local response
    response=$(curl -sf --connect-timeout "$(_config_get_int "network.connect_timeout" 10)" --max-time "$(_config_get_int "network.max_time" 30)" -X POST "$(_config_get "urls.linear_api" "https://api.linear.app/graphql")" \
        -H "Authorization: $api_key" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || {
        warn "Could not validate API key — check your key"
        return 0
    }
    local viewer_name
    viewer_name=$(echo "$response" | jq -r '.data.viewer.name // "Unknown"' 2>/dev/null || echo "Unknown")
    success "Authenticated as: ${viewer_name}"
}

_init_jira() {
    echo ""
    echo -e "  ${CYAN}1.${RESET} Enter your Jira instance URL (e.g. https://myteam.atlassian.net)"
    echo -e "  ${CYAN}2.${RESET} Create an API token at ${DIM}https://id.atlassian.com/manage-profile/security/api-tokens${RESET}"
    echo ""
    read -rp "  Jira Base URL: " base_url
    if [[ -z "$base_url" ]]; then
        error "Base URL is required"
        exit 1
    fi
    # Strip trailing slash
    base_url="${base_url%/}"

    read -rp "  Jira Email: " email
    if [[ -z "$email" ]]; then
        error "Email is required"
        exit 1
    fi

    read -rp "  Jira API Token: " api_token
    if [[ -z "$api_token" ]]; then
        error "API token is required"
        exit 1
    fi

    read -rp "  Project Key (e.g. PROJ): " project_key
    project_key="${project_key:-}"

    local tmp_config="${TRACKER_CONFIG}.tmp"
    jq -n \
        --arg provider "jira" \
        --arg base_url "$base_url" \
        --arg email "$email" \
        --arg api_token "$api_token" \
        --arg project_key "$project_key" \
        --arg updated "$(now_iso)" \
        '{
            provider: $provider,
            jira: {
                base_url: $base_url,
                email: $email,
                api_token: $api_token,
                project_key: $project_key
            },
            updated_at: $updated
        }' > "$tmp_config"
    if [[ -s "$tmp_config" ]]; then
        mv "$tmp_config" "$TRACKER_CONFIG"
        chmod 600 "$TRACKER_CONFIG"
    else
        rm -f "$tmp_config"
        error "Failed to write tracker config"
        return 1
    fi

    success "Jira tracker configured"
    echo ""

    # Validate connection
    info "Validating connection..."
    local auth
    auth=$(printf '%s:%s' "$email" "$api_token" | base64)
    local response
    response=$(curl -sf --connect-timeout "$(_config_get_int "network.connect_timeout" 10)" --max-time "$(_config_get_int "network.max_time" 30)" -X GET "${base_url}/rest/api/3/myself" \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json" 2>&1) || {
        warn "Could not validate connection — check your credentials"
        return 0
    }
    local display_name
    display_name=$(echo "$response" | jq -r '.displayName // "Unknown"' 2>/dev/null || echo "Unknown")
    success "Authenticated as: ${display_name}"
}

# ─── Status ────────────────────────────────────────────────────────────────

cmd_status() {
    load_tracker_config

    echo -e "${PURPLE}${BOLD}━━━ Tracker Status ━━━${RESET}"
    echo ""
    echo -e "  ${BOLD}Provider:${RESET}  ${CYAN}${TRACKER_PROVIDER}${RESET}"

    if [[ -f "$TRACKER_CONFIG" ]]; then
        local updated
        updated=$(jq -r '.updated_at // "unknown"' "$TRACKER_CONFIG" 2>/dev/null || echo "unknown")
        echo -e "  ${BOLD}Config:${RESET}    ${DIM}${TRACKER_CONFIG}${RESET}"
        echo -e "  ${BOLD}Updated:${RESET}   ${DIM}${updated}${RESET}"
    else
        echo -e "  ${BOLD}Config:${RESET}    ${DIM}(not configured — run 'shipwright tracker init')${RESET}"
    fi

    echo ""

    # Show recent tracker events
    if [[ -f "$EVENTS_FILE" ]]; then
        local recent
        recent=$(grep '"type":"tracker\.' "$EVENTS_FILE" 2>/dev/null | tail -5 || true)
        if [[ -n "$recent" ]]; then
            echo -e "${BOLD}Recent Tracker Activity${RESET}"
            echo "$recent" | while IFS= read -r line; do
                local ts type
                ts=$(echo "$line" | jq -r '.ts' 2>/dev/null || true)
                type=$(echo "$line" | jq -r '.type' 2>/dev/null || true)
                echo -e "  ${DIM}${ts}${RESET}  ${type}"
            done
            echo ""
        fi
    fi
}

# ─── Help ──────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright tracker${RESET} — Issue Tracker Provider Router"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright tracker${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}init${RESET}                          Configure tracker provider"
    echo -e "  ${CYAN}status${RESET}                        Show tracker configuration"
    echo -e "  ${CYAN}available${RESET}                     Check if a tracker is configured"
    echo -e "  ${CYAN}notify${RESET} <event> <issue> [detail]  Send notification to tracker"
    echo -e "  ${CYAN}help${RESET}                          Show this help"
    echo ""
    echo -e "${BOLD}PROVIDERS${RESET}"
    echo -e "  ${CYAN}github${RESET}     GitHub (native, gh CLI)"
    echo -e "  ${CYAN}linear${RESET}     Linear.app (GraphQL API)"
    echo -e "  ${CYAN}jira${RESET}       Atlassian Jira (REST API v3)"
    echo ""
    echo -e "${BOLD}DISCOVERY INTERFACE${RESET} (for daemon)"
    echo -e "  Provider-agnostic issue discovery and metadata:"
    echo -e "  ${CYAN}tracker_discover_issues${RESET} <label> [state] [limit]"
    echo -e "  ${CYAN}tracker_get_issue${RESET} <issue_id>"
    echo -e "  ${CYAN}tracker_get_issue_body${RESET} <issue_id>"
    echo ""
    echo -e "${BOLD}CRUD INTERFACE${RESET} (for pipeline)"
    echo -e "  Provider-agnostic issue modification:"
    echo -e "  ${CYAN}tracker_add_label${RESET} <issue_id> <label>"
    echo -e "  ${CYAN}tracker_remove_label${RESET} <issue_id> <label>"
    echo -e "  ${CYAN}tracker_comment${RESET} <issue_id> <body>"
    echo -e "  ${CYAN}tracker_close_issue${RESET} <issue_id>"
    echo -e "  ${CYAN}tracker_create_issue${RESET} <title> <body> [labels]"
    echo ""
    echo -e "${BOLD}NOTIFICATION EVENTS${RESET}"
    echo -e "  ${CYAN}spawn${RESET}           Pipeline started"
    echo -e "  ${CYAN}stage_complete${RESET}  Stage finished (detail: stage_id|duration|description)"
    echo -e "  ${CYAN}stage_failed${RESET}   Stage failed   (detail: stage_id|error_context)"
    echo -e "  ${CYAN}review${RESET}          PR created     (detail: pr_url)"
    echo -e "  ${CYAN}completed${RESET}       Pipeline done"
    echo -e "  ${CYAN}failed${RESET}          Pipeline failed (detail: error_message)"
    echo ""
    echo -e "${BOLD}CONFIGURATION${RESET}"
    echo -e "  Config file:  ${DIM}~/.shipwright/tracker-config.json${RESET}"
    echo -e "  Env override: ${DIM}TRACKER_PROVIDER_OVERRIDE=github|linear|jira|none${RESET}"
    echo -e "  Daemon block: ${DIM}.claude/daemon-config.json → .tracker.provider${RESET}"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright tracker init${RESET}                           # Configure provider"
    echo -e "  ${DIM}shipwright tracker status${RESET}                         # Show config"
    echo -e "  ${DIM}shipwright tracker notify spawn 42${RESET}                # Notify pipeline started"
    echo -e "  ${DIM}shipwright tracker notify completed 42${RESET}            # Notify pipeline done"
    echo -e "  ${DIM}shipwright tracker notify review 42 'https://...'${RESET} # Notify PR created"
}

# ─── Command Router ─────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        notify)     tracker_notify "$@" ;;
        available)  tracker_available && echo "true" || echo "false" ;;
        init)       cmd_init "$@" ;;
        status)     cmd_status "$@" ;;
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
