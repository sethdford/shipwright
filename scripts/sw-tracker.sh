#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tracker — Provider Router for Issue Tracker Integration      ║
# ║  Route notifications · Configure providers · Linear & Jira support      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.7.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

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
    if type provider_notify &>/dev/null; then
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
        mv "$tmp_config" "$TRACKER_CONFIG"
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
    mv "$tmp_config" "$TRACKER_CONFIG"
    chmod 600 "$TRACKER_CONFIG"

    success "Linear tracker configured"
    echo ""

    # Validate connection
    info "Validating API key..."
    local payload
    payload=$(jq -n --arg q 'query { viewer { id name } }' '{query: $q}')
    local response
    response=$(curl -sf -X POST "https://api.linear.app/graphql" \
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
    mv "$tmp_config" "$TRACKER_CONFIG"
    chmod 600 "$TRACKER_CONFIG"

    success "Jira tracker configured"
    echo ""

    # Validate connection
    info "Validating connection..."
    local auth
    auth=$(printf '%s:%s' "$email" "$api_token" | base64)
    local response
    response=$(curl -sf -X GET "${base_url}/rest/api/3/myself" \
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
    echo -e "  ${CYAN}linear${RESET}     Linear.app (GraphQL API)"
    echo -e "  ${CYAN}jira${RESET}       Atlassian Jira (REST API v3)"
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
    echo -e "  Env override: ${DIM}TRACKER_PROVIDER_OVERRIDE=linear|jira|none${RESET}"
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
