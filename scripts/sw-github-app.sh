#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright github-app — GitHub App Management & Webhook Receiver       ║
# ║  JWT generation · Installation tokens · Webhook validation · Events     ║
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

# ─── Config File Locations ────────────────────────────────────────────────
CONFIG_DIR="${HOME}/.shipwright"
CONFIG_FILE="${CONFIG_DIR}/github-app.json"
TOKENS_FILE="${CONFIG_DIR}/github-app-tokens.json"
WEBHOOK_LOG="${CONFIG_DIR}/webhook-events.jsonl"

# ─── Ensure config directory exists ───────────────────────────────────────
_ensure_config_dir() {
    mkdir -p "$CONFIG_DIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# APP CONFIG FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Setup: Interactive configuration ──────────────────────────────────────
cmd_setup() {
    _ensure_config_dir

    if [[ -f "$CONFIG_FILE" ]]; then
        warn "GitHub App config already exists at ${CONFIG_FILE}"
        read -p "Overwrite? (y/n) " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Skipped setup"
            return 0
        fi
    fi

    echo ""
    info "GitHub App Configuration"
    echo ""

    read -p "App ID: " app_id
    read -p "Private key file path: " key_path

    if [[ ! -f "$key_path" ]]; then
        error "Private key file not found: $key_path"
        return 1
    fi

    read -p "Installation ID: " installation_id
    read -p "Webhook secret (optional, press Enter to skip): " webhook_secret

    # Create config atomically
    local tmp_config
    tmp_config=$(mktemp)
    jq -n \
        --arg app_id "$app_id" \
        --arg key_path "$key_path" \
        --arg install_id "$installation_id" \
        --arg webhook_secret "$webhook_secret" \
        '{
            app_id: ($app_id | tonumber),
            private_key_path: $key_path,
            installation_id: ($install_id | tonumber),
            webhook_secret: $webhook_secret,
            created_at: "'$(now_iso)'"
        }' > "$tmp_config"

    mv "$tmp_config" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    success "GitHub App config saved to ${CONFIG_FILE}"
    emit_event "github_app.setup" "app_id=$app_id" "install_id=$installation_id"
}

# ─── Load config from file ────────────────────────────────────────────────
_load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "GitHub App config not found. Run 'shipwright github-app setup' first."
        return 1
    fi
    cat "$CONFIG_FILE"
}

# ─── Get config value ────────────────────────────────────────────────────
_get_config_value() {
    local key="$1"
    _load_config | jq -r ".$key // empty" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════════
# JWT & TOKEN FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Generate JWT from private key ────────────────────────────────────────
_generate_jwt() {
    local app_id="$1"
    local key_path="$2"

    if [[ ! -f "$key_path" ]]; then
        error "Private key not found: $key_path"
        return 1
    fi

    # JWT header (alg: RS256, typ: JWT)
    local header
    header=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '+/' '-_')

    # JWT payload (iss: app_id, iat: now, exp: now + 10 min)
    local now
    now=$(date +%s)
    local exp=$((now + 600))

    local payload
    payload=$(echo -n '{"iss":'$app_id',"iat":'$now',"exp":'$exp'}' | base64 | tr -d '=' | tr '+/' '-_')

    # Sign with private key
    local signature_input="${header}.${payload}"
    local signature
    signature=$(echo -n "$signature_input" | openssl dgst -sha256 -sign "$key_path" | base64 | tr -d '=' | tr '+/' '-_')

    echo "${signature_input}.${signature}"
}

# ─── Exchange JWT for installation token ─────────────────────────────────
_get_installation_token() {
    local jwt="$1"
    local installation_id="$2"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        echo ""
        return 0
    fi

    local response
    response=$(curl -s -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${installation_id}/access_tokens" \
        -d '{}' -X POST 2>/dev/null) || true

    if echo "$response" | jq -e '.token' >/dev/null 2>&1; then
        echo "$response" | jq -r '.token'
    else
        error "Failed to get installation token"
        echo "$response" | jq -r '.message // "Unknown error"' >&2
        return 1
    fi
}

# ─── Cache token with expiry ──────────────────────────────────────────────
_cache_token() {
    local installation_id="$1"
    local token="$2"
    local expires_at="$3"

    _ensure_config_dir

    local tmp_tokens
    tmp_tokens=$(mktemp)

    if [[ -f "$TOKENS_FILE" ]]; then
        jq ".tokens += [{\"installation_id\":$installation_id,\"token\":\"$token\",\"expires_at\":\"$expires_at\"}]" \
            "$TOKENS_FILE" > "$tmp_tokens"
    else
        jq -n ".tokens = [{\"installation_id\":$installation_id,\"token\":\"$token\",\"expires_at\":\"$expires_at\"}]" \
            > "$tmp_tokens"
    fi

    mv "$tmp_tokens" "$TOKENS_FILE"
    chmod 600 "$TOKENS_FILE"
}

# ─── Get cached token if still valid ──────────────────────────────────────
_get_cached_token() {
    local installation_id="$1"

    if [[ ! -f "$TOKENS_FILE" ]]; then
        echo ""
        return 1
    fi

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local token
    token=$(jq -r ".tokens[] | select(.installation_id==$installation_id and .expires_at > \"$now\") | .token" \
        "$TOKENS_FILE" 2>/dev/null | head -1 || true)

    if [[ -n "$token" ]]; then
        echo "$token"
        return 0
    fi

    echo ""
    return 1
}

# ─── Get installation token (cached or fresh) ─────────────────────────────
cmd_token() {
    local app_id
    app_id=$(_get_config_value "app_id") || {
        error "GitHub App not configured. Run 'shipwright github-app setup' first."
        return 1
    }

    local key_path
    key_path=$(_get_config_value "private_key_path") || {
        error "Missing private_key_path in config"
        return 1
    }

    local installation_id
    installation_id=$(_get_config_value "installation_id") || {
        error "Missing installation_id in config"
        return 1
    }

    # Try cached token first
    local cached_token
    cached_token=$(_get_cached_token "$installation_id" 2>/dev/null) || true
    if [[ -n "$cached_token" ]]; then
        echo "$cached_token"
        return 0
    fi

    # Generate JWT and exchange for token
    info "Generating JWT and requesting installation token..."
    local jwt
    jwt=$(_generate_jwt "$app_id" "$key_path") || return 1

    local token
    token=$(_get_installation_token "$jwt" "$installation_id") || return 1

    # Cache token (valid for 1 hour)
    local expires_at
    expires_at=$(date -u -d "+1 hour" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v+1H +"%Y-%m-%dT%H:%M:%SZ")
    _cache_token "$installation_id" "$token" "$expires_at"

    success "Got installation token (cached for 1 hour)"
    emit_event "github_app.token_acquired" "installation_id=$installation_id"
    echo "$token"
}

# ═══════════════════════════════════════════════════════════════════════════════
# WEBHOOK FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Verify webhook signature (HMAC-SHA256) ───────────────────────────────
cmd_verify() {
    local webhook_secret
    webhook_secret=$(_get_config_value "webhook_secret") || true

    if [[ -z "$webhook_secret" ]]; then
        error "Webhook secret not configured"
        return 1
    fi

    # Read payload from stdin
    local payload
    payload=$(cat)

    # Get signature from header (passed as argument or env var)
    local signature="${1:-${X_HUB_SIGNATURE_256:-}}"

    if [[ -z "$signature" ]]; then
        error "No signature provided. Pass as argument or X_HUB_SIGNATURE_256 env var."
        return 1
    fi

    # Compute expected signature
    local expected_sig
    expected_sig=$(echo -n "$payload" | openssl dgst -sha256 -mac HMAC -macopt "key:${webhook_secret}" | sed 's/^.* /sha256=/')

    if [[ "$expected_sig" == "$signature" ]]; then
        success "Webhook signature verified"
        echo "$payload"
        return 0
    else
        error "Webhook signature verification failed"
        error "Expected: $expected_sig"
        error "Got:      $signature"
        return 1
    fi
}

# ─── Log webhook event ────────────────────────────────────────────────────
_log_webhook_event() {
    local event_type="$1"
    local payload="$2"

    _ensure_config_dir

    local event
    event=$(jq -n \
        --arg ts "$(now_iso)" \
        --arg type "$event_type" \
        --argjson payload "$payload" \
        '{timestamp: $ts, event_type: $type, payload: $payload}')

    echo "$event" >> "$WEBHOOK_LOG"
}

# ─── Handle GitHub webhook events ─────────────────────────────────────────
_handle_webhook_event() {
    local event_type="$1"
    local payload="$2"

    case "$event_type" in
        issues)
            local action
            action=$(echo "$payload" | jq -r '.action // empty')
            if [[ "$action" == "labeled" ]]; then
                local label
                label=$(echo "$payload" | jq -r '.label.name // empty')
                info "Issue labeled with: $label"
                emit_event "webhook.issue_labeled" "label=$label"
            fi
            ;;
        pull_request)
            local action
            action=$(echo "$payload" | jq -r '.action // empty')
            if [[ "$action" == "opened" ]]; then
                info "Pull request opened"
                emit_event "webhook.pr_opened"
            elif [[ "$action" == "review_requested" ]]; then
                info "Review requested on PR"
                emit_event "webhook.pr_review_requested"
            fi
            ;;
        check_suite)
            local action
            action=$(echo "$payload" | jq -r '.action // empty')
            if [[ "$action" == "requested" ]]; then
                info "Check suite requested"
                emit_event "webhook.check_suite_requested"
            fi
            ;;
        push)
            local ref
            ref=$(echo "$payload" | jq -r '.ref // empty')
            info "Push to: $ref"
            emit_event "webhook.push" "ref=$ref"
            ;;
        *)
            info "Webhook event: $event_type"
            ;;
    esac

    _log_webhook_event "$event_type" "$payload"
}

# ═══════════════════════════════════════════════════════════════════════════════
# APP MANIFEST & STATUS FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Generate GitHub App manifest for easy setup ────────────────────────
cmd_manifest() {
    local app_name="${1:-shipwright-app}"
    local webhook_url="${2:-https://webhook.example.com}"

    local manifest
    manifest=$(jq -n \
        --arg name "$app_name" \
        --arg webhook_url "$webhook_url" \
        '{
            name: $name,
            url: "https://github.com/sethdford/shipwright",
            hook_attributes: {
                url: $webhook_url
            },
            redirect_url: "https://github.com/apps/'$app_name'/installations/new",
            description: "Autonomous pipeline delivery with Shipwright",
            public: true,
            default_events: [
                "issues",
                "pull_request",
                "pull_request_review",
                "pull_request_review_comment",
                "check_suite",
                "check_run",
                "push"
            ],
            default_permissions: {
                contents: "write",
                checks: "write",
                pull_requests: "write",
                issues: "write",
                deployments: "write"
            }
        }')

    echo "$manifest" | jq .
    success "Manifest generated. Visit: https://github.com/settings/apps/new to create your app."
}

# ─── Show app status and config ─────────────────────────────────────────
cmd_status() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        warn "GitHub App not configured"
        echo ""
        echo "Run '${CYAN}shipwright github-app setup${RESET}' to configure"
        return 0
    fi

    info "GitHub App Status"
    echo ""

    local config
    config=$(cat "$CONFIG_FILE")

    local app_id
    app_id=$(echo "$config" | jq -r '.app_id')
    local install_id
    install_id=$(echo "$config" | jq -r '.installation_id')
    local webhook_secret
    webhook_secret=$(echo "$config" | jq -r '.webhook_secret // empty')

    echo -e "${BOLD}Configuration:${RESET}"
    echo "  App ID:          $app_id"
    echo "  Installation ID: $install_id"
    echo "  Webhook Secret:  ${webhook_secret:-${DIM}(none)${RESET}}"
    echo ""

    # Show recent webhook events
    if [[ -f "$WEBHOOK_LOG" ]]; then
        local count
        count=$(wc -l < "$WEBHOOK_LOG" 2>/dev/null || echo 0)
        if [[ "$count" -gt 0 ]]; then
            echo -e "${BOLD}Recent Webhook Events (last 10):${RESET}"
            tail -10 "$WEBHOOK_LOG" | jq '{timestamp, event_type}' -c
            echo ""
        fi
    fi

    # Show cached tokens
    if [[ -f "$TOKENS_FILE" ]]; then
        echo -e "${BOLD}Cached Tokens:${RESET}"
        jq '.tokens[] | {installation_id, expires_at}' "$TOKENS_FILE" 2>/dev/null || echo "  (none)"
        echo ""
    fi

    success "Status retrieved"
}

# ─── List recent webhook events ────────────────────────────────────────
cmd_events() {
    local limit="${1:-20}"

    if [[ ! -f "$WEBHOOK_LOG" ]]; then
        warn "No webhook events logged yet"
        return 0
    fi

    info "Recent Webhook Events"
    echo ""

    tail -"$limit" "$WEBHOOK_LOG" | jq '{timestamp, event_type, payload: (.payload | keys)}' -c
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELP & MAIN
# ═══════════════════════════════════════════════════════════════════════════════

show_help() {
    cat <<EOF
${CYAN}${BOLD}shipwright github-app${RESET} — GitHub App Management & Webhook Receiver

${BOLD}USAGE${RESET}
  shipwright github-app <command> [options]

${BOLD}COMMANDS${RESET}
  ${CYAN}setup${RESET}                 Interactive configuration (app ID, private key, installation ID)
  ${CYAN}token${RESET}                 Get/refresh installation access token (with caching)
  ${CYAN}manifest${RESET}              Generate GitHub App manifest JSON for setup at github.com/settings/apps/new
  ${CYAN}verify${RESET}                Verify webhook signature (read payload from stdin)
  ${CYAN}events${RESET} [limit]        List recent webhook events (default: 20)
  ${CYAN}status${RESET}                Show current app config, installation status, cached tokens
  ${CYAN}help${RESET}                  Show this help message

${BOLD}EXAMPLES${RESET}
  ${DIM}# Initial setup${RESET}
  shipwright github-app setup

  ${DIM}# Get installation token${RESET}
  shipwright github-app token

  ${DIM}# Generate manifest for app creation${RESET}
  shipwright github-app manifest "my-app" "https://my-webhook.com"

  ${DIM}# Verify webhook signature${RESET}
  cat webhook-payload.json | shipwright github-app verify "sha256=..."

  ${DIM}# Check app status${RESET}
  shipwright github-app status

  ${DIM}# View recent webhook events${RESET}
  shipwright github-app events 50

${BOLD}CONFIG LOCATION${RESET}
  ${DIM}${CONFIG_FILE}${RESET}

${BOLD}WEBHOOK LOG${RESET}
  ${DIM}${WEBHOOK_LOG}${RESET}

${BOLD}TOKEN CACHE${RESET}
  ${DIM}${TOKENS_FILE}${RESET}

EOF
}

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        setup)
            cmd_setup "$@"
            ;;
        token)
            cmd_token "$@"
            ;;
        manifest)
            cmd_manifest "$@"
            ;;
        verify)
            cmd_verify "$@"
            ;;
        events)
            cmd_events "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
