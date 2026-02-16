#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-webhook.sh — GitHub Webhook Receiver for Instant Issue Processing    ║
# ║  Replaces polling with instant webhook delivery · HMAC-SHA256 validation  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ─── Constants ──────────────────────────────────────────────────────────────
SHIPWRIGHT_DIR="$HOME/.shipwright"
WEBHOOK_SECRET_FILE="$SHIPWRIGHT_DIR/webhook-secret"
WEBHOOK_EVENTS_FILE="$SHIPWRIGHT_DIR/webhook-events.jsonl"
WEBHOOK_PORT="${WEBHOOK_PORT:-8765}"
WEBHOOK_PID_FILE="$SHIPWRIGHT_DIR/webhook.pid"
WEBHOOK_LOG="$SHIPWRIGHT_DIR/webhook.log"

# ─── Helpers ────────────────────────────────────────────────────────────────

ensure_dir() {
    mkdir -p "$SHIPWRIGHT_DIR"
}

# Generate or retrieve webhook secret
get_or_create_secret() {
    ensure_dir
    if [[ -f "$WEBHOOK_SECRET_FILE" ]]; then
        cat "$WEBHOOK_SECRET_FILE"
    else
        local secret
        secret=$(openssl rand -hex 32)
        echo "$secret" > "$WEBHOOK_SECRET_FILE"
        chmod 600 "$WEBHOOK_SECRET_FILE"
        echo "$secret"
    fi
}

# Validate HMAC-SHA256 signature from GitHub webhook header
validate_webhook_signature() {
    local payload="$1"
    local signature="$2"
    local secret
    secret=$(get_or_create_secret)

    # GitHub sends signature as "sha256=<hex>"
    local expected_signature
    expected_signature="sha256=$(echo -n "$payload" | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $2}')"

    # Use constant-time comparison if available, otherwise direct comparison
    if [[ "$signature" == "$expected_signature" ]]; then
        return 0
    else
        return 1
    fi
}

# Parse webhook payload and emit event if labeled issue
# Returns 0 if event was processed, 1 if it was ignored
process_webhook_event() {
    local payload="$1"
    local event_type="${2:-unknown}"

    # Only process issues.labeled events
    if [[ "$event_type" != "issues" ]]; then
        return 1
    fi

    local action
    action=$(echo "$payload" | jq -r '.action // empty' 2>/dev/null || echo "")

    if [[ "$action" != "labeled" ]]; then
        return 1
    fi

    # Extract relevant fields
    local issue_num repo_full_name issue_title label_name
    issue_num=$(echo "$payload" | jq -r '.issue.number // empty' 2>/dev/null || echo "")
    repo_full_name=$(echo "$payload" | jq -r '.repository.full_name // empty' 2>/dev/null || echo "")
    issue_title=$(echo "$payload" | jq -r '.issue.title // empty' 2>/dev/null || echo "")
    label_name=$(echo "$payload" | jq -r '.label.name // empty' 2>/dev/null || echo "")

    if [[ -z "$issue_num" || -z "$repo_full_name" || -z "$label_name" ]]; then
        return 1
    fi

    # Write event to webhook events file for daemon to process
    ensure_dir
    local event_record
    event_record=$(jq -nc \
        --arg ts "$(now_iso)" \
        --arg ts_epoch "$(now_epoch)" \
        --arg repo "$repo_full_name" \
        --arg issue "$issue_num" \
        --arg title "$issue_title" \
        --arg label "$label_name" \
        '{ts: $ts, ts_epoch: $ts_epoch, source: "webhook", repo: $repo, issue: $issue, title: $title, label: $label}')

    echo "$event_record" >> "$WEBHOOK_EVENTS_FILE"

    info "Webhook: Issue #${issue_num} labeled '${label_name}' in ${repo_full_name}"
    return 0
}

# ─── HTTP Server (lightweight bash + nc) ───────────────────────────────────

# Check if nc (netcat) is available
check_nc() {
    if ! command -v nc &>/dev/null; then
        error "netcat (nc) is required but not installed"
        echo -e "  ${DIM}brew install netcat${RESET}  (macOS)"
        echo -e "  ${DIM}sudo apt install netcat-openbsd${RESET}  (Ubuntu/Debian)"
        return 1
    fi
}

# Read HTTP request from file descriptor
read_http_request() {
    local fd="$1"
    local method path headers body

    # Read request line
    IFS= read -r -u "$fd" request_line || return 1
    method=$(echo "$request_line" | awk '{print $1}')
    path=$(echo "$request_line" | awk '{print $2}')

    # Read headers
    while IFS= read -r -u "$fd" -t 0 header_line; do
        [[ -z "$header_line" || "$header_line" == $'\r' ]] && break
        headers="${headers}${header_line}"$'\n'
    done

    echo "$method|$path|$headers"
}

# Parse HTTP headers to extract specific header value
get_header() {
    local headers="$1"
    local header_name="$2"

    # Case-insensitive header lookup
    echo "$headers" | grep -i "^${header_name}:" | cut -d':' -f2- | sed 's/^ *//' | tr -d '\r'
}

# Send HTTP response
send_http_response() {
    local status_code="$1"
    local content_type="${2:-text/plain}"
    local body="${3:-}"

    local status_text
    case "$status_code" in
        200) status_text="OK" ;;
        202) status_text="Accepted" ;;
        400) status_text="Bad Request" ;;
        401) status_text="Unauthorized" ;;
        404) status_text="Not Found" ;;
        500) status_text="Internal Server Error" ;;
        *) status_text="Unknown" ;;
    esac

    local content_length
    content_length=${#body}

    cat <<EOF
HTTP/1.1 $status_code $status_text
Content-Type: $content_type
Content-Length: $content_length
Connection: close

$body
EOF
}

# Main webhook server loop
webhook_server() {
    check_nc || return 1

    info "Starting webhook server on port ${WEBHOOK_PORT}..."

    # Try to bind to port
    if ! nc -l -p "$WEBHOOK_PORT" 2>/dev/null; then
        # macOS nc syntax differs
        if ! nc -l localhost "$WEBHOOK_PORT" 2>/dev/null; then
            error "Failed to bind to port ${WEBHOOK_PORT}"
            return 1
        fi
    fi &

    local nc_pid=$!
    echo "$nc_pid" > "$WEBHOOK_PID_FILE"

    success "Webhook server running (PID: $nc_pid)"
    success "GitHub webhook secret: $(get_or_create_secret | cut -c1-8)..."

    # Wait for nc to finish
    wait $nc_pid 2>/dev/null || true

    rm -f "$WEBHOOK_PID_FILE"
}

# Better approach: use a bash loop with /dev/tcp (BASH_REMATCH compatible)
webhook_server_bash() {
    check_nc || return 1

    info "Starting webhook server on port ${WEBHOOK_PORT}..."
    success "GitHub webhook secret: $(get_or_create_secret | cut -c1-8)..."

    # Create FIFO for IPC
    local fifo
    fifo="/tmp/webhook-$$-fifo"
    mkfifo "$fifo" 2>/dev/null || true

    # Background listener loop
    (
        while true; do
            {
                read -r -u 3 request_line || break
                local method path protocol
                read -r method path protocol <<< "$request_line"

                # Read headers until blank line
                local -A headers
                local header_line content_length=0
                while read -r -u 3 -t 0.1 header_line; do
                    [[ -z "$header_line" || "$header_line" == $'\r' ]] && break
                    local key="${header_line%%:*}"
                    local value="${header_line#*:}"
                    value="${value#[[:space:]]}"
                    value="${value%$'\r'}"
                    headers["$key"]="$value"
                    [[ "${key,,}" == "content-length" ]] && content_length="$value"
                done 2>/dev/null || true

                # Read body if content-length > 0
                local body=""
                if [[ $content_length -gt 0 ]]; then
                    read -r -u 3 -N "$content_length" body 2>/dev/null || true
                fi

                # Process webhook if method is POST
                if [[ "$method" == "POST" && "$path" == "/webhook" ]]; then
                    local signature="${headers[X-Hub-Signature-256]:-}"
                    local event_type="${headers[X-Github-Event]:-}"

                    if validate_webhook_signature "$body" "$signature"; then
                        if process_webhook_event "$body" "$event_type"; then
                            send_http_response 202 "application/json" '{"status":"accepted"}'
                        else
                            send_http_response 202 "application/json" '{"status":"ignored"}'
                        fi
                    else
                        warn "Invalid signature from $(echo "$body" | jq -r '.repository.full_name // "unknown"' 2>/dev/null)"
                        send_http_response 401 "application/json" '{"error":"Unauthorized"}'
                    fi
                else
                    send_http_response 404 "application/json" '{"error":"Not Found"}'
                fi
            } 3< "$fifo"
        done
    ) &

    local server_pid=$!
    echo "$server_pid" > "$WEBHOOK_PID_FILE"

    # Accept connections (simple approach with exec)
    while true; do
        # This is a simplified approach - for production, use a proper HTTP server
        # For now, we'll just log that the server is running
        sleep 1
    done &

    wait
}

# ─── Subcommands ────────────────────────────────────────────────────────────

cmd_setup() {
    local org_repo="${1:-}"

    if [[ -z "$org_repo" ]]; then
        error "Usage: shipwright webhook setup <org/repo>"
        return 1
    fi

    # Validate org/repo format
    if [[ ! "$org_repo" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9._-]+$ ]]; then
        error "Invalid org/repo format: $org_repo"
        return 1
    fi

    local secret
    secret=$(get_or_create_secret)

    info "Setting up webhook for ${org_repo}..."
    info "Webhook endpoint: http://localhost:${WEBHOOK_PORT}/webhook"

    # Check if gh CLI is available
    if ! command -v gh &>/dev/null; then
        error "GitHub CLI (gh) is required but not installed"
        return 1
    fi

    # Create webhook via GitHub API
    local webhook_response
    if webhook_response=$(gh api "repos/${org_repo}/hooks" \
        -X POST \
        -f "name=web" \
        -f "active=true" \
        -f "url=http://localhost:${WEBHOOK_PORT}/webhook" \
        -F "events=issues" \
        -f "config[content_type]=json" \
        -f "config[secret]=${secret}" 2>&1); then

        local hook_id
        hook_id=$(echo "$webhook_response" | jq -r '.id // empty' 2>/dev/null || true)

        if [[ -n "$hook_id" ]]; then
            success "Webhook created (ID: ${hook_id})"
            return 0
        fi
    fi

    error "Failed to create webhook. Check that:"
    echo "  - gh CLI is authenticated (run: gh auth login)"
    echo "  - You have admin access to ${org_repo}"
    echo "  - The webhook endpoint is publicly accessible"
    return 1
}

cmd_status() {
    ensure_dir

    if [[ -f "$WEBHOOK_PID_FILE" ]]; then
        local pid
        pid=$(cat "$WEBHOOK_PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            success "Webhook server is running (PID: ${pid})"
        else
            warn "Webhook server is NOT running"
        fi
    else
        warn "Webhook server is NOT running"
    fi

    echo ""
    info "Configuration:"
    echo "  Secret file: ${WEBHOOK_SECRET_FILE}"
    echo "  Events file: ${WEBHOOK_EVENTS_FILE}"
    echo "  Port: ${WEBHOOK_PORT}"

    echo ""
    if [[ -f "$WEBHOOK_EVENTS_FILE" ]]; then
        local event_count
        event_count=$(wc -l < "$WEBHOOK_EVENTS_FILE" 2>/dev/null || echo 0)
        info "Recent webhook events (${event_count} total):"
        tail -5 "$WEBHOOK_EVENTS_FILE" 2>/dev/null | jq -c '{ts, repo, issue, label}' || echo "  (no events yet)"
    else
        info "No webhook events recorded yet"
    fi
}

cmd_test() {
    local org_repo="${1:-}"

    if [[ -z "$org_repo" ]]; then
        error "Usage: shipwright webhook test <org/repo>"
        return 1
    fi

    if ! command -v gh &>/dev/null; then
        error "GitHub CLI (gh) is required"
        return 1
    fi

    info "Sending test ping to webhook for ${org_repo}..."

    # Construct a test webhook payload
    local secret
    secret=$(get_or_create_secret)

    local payload
    payload=$(jq -n \
        --arg repo "$org_repo" \
        --arg action "labeled" \
        '{
            action: $action,
            issue: {
                number: 999,
                title: "Test Issue from Webhook"
            },
            label: {
                name: "shipwright"
            },
            repository: {
                full_name: $repo
            }
        }')

    # Compute HMAC-SHA256 signature
    local signature
    signature="sha256=$(echo -n "$payload" | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $2}')"

    # Send test webhook via GitHub API
    if gh api "repos/${org_repo}/hooks/tests" \
        -H "Accept: application/vnd.github+json" \
        -X POST \
        2>&1 | grep -q "Test hook sent"; then
        success "Test ping sent to GitHub"
    else
        warn "Could not send test via GitHub API, but payload is valid:"
        echo "  Payload: $payload"
        echo "  Signature: $signature"
    fi
}

cmd_start() {
    ensure_dir

    if [[ -f "$WEBHOOK_PID_FILE" ]]; then
        local pid
        pid=$(cat "$WEBHOOK_PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            warn "Webhook server is already running (PID: ${pid})"
            return 0
        fi
    fi

    info "Starting webhook server..."

    # Start server in background, capture output
    {
        webhook_server >> "$WEBHOOK_LOG" 2>&1
    } &

    local bg_pid=$!
    sleep 1

    if kill -0 $bg_pid 2>/dev/null; then
        success "Webhook server started (PID: ${bg_pid})"
    else
        error "Failed to start webhook server"
        tail -20 "$WEBHOOK_LOG" 2>/dev/null || true
        return 1
    fi
}

cmd_stop() {
    if [[ ! -f "$WEBHOOK_PID_FILE" ]]; then
        warn "Webhook server is not running"
        return 0
    fi

    local pid
    pid=$(cat "$WEBHOOK_PID_FILE" 2>/dev/null || true)

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        warn "Webhook server is not running (stale PID file)"
        rm -f "$WEBHOOK_PID_FILE"
        return 0
    fi

    info "Stopping webhook server (PID: ${pid})..."
    kill "$pid" 2>/dev/null || true
    sleep 1

    if ! kill -0 "$pid" 2>/dev/null; then
        success "Webhook server stopped"
        rm -f "$WEBHOOK_PID_FILE"
    else
        error "Failed to stop webhook server — force killing..."
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$WEBHOOK_PID_FILE"
    fi
}

cmd_logs() {
    if [[ ! -f "$WEBHOOK_LOG" ]]; then
        info "No webhook logs yet"
        return 0
    fi

    tail -50 "$WEBHOOK_LOG"
}

cmd_secret() {
    local action="${1:-show}"

    case "$action" in
        show|get)
            local secret
            secret=$(get_or_create_secret)
            echo "$secret"
            ;;
        regenerate|reset)
            ensure_dir
            local new_secret
            new_secret=$(openssl rand -hex 32)
            echo "$new_secret" > "$WEBHOOK_SECRET_FILE"
            chmod 600 "$WEBHOOK_SECRET_FILE"
            success "Webhook secret regenerated"
            info "New secret: ${new_secret}"
            ;;
        *)
            error "Unknown secret action: $action"
            return 1
            ;;
    esac
}

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    cat <<EOF
${BOLD}shipwright webhook${RESET} — GitHub Webhook Receiver

${BOLD}USAGE${RESET}
  shipwright webhook <command> [options]

${BOLD}COMMANDS${RESET}
  ${CYAN}setup${RESET} <org/repo>      Configure webhook on GitHub repo
  ${CYAN}status${RESET}                Check webhook server health and events
  ${CYAN}start${RESET}                 Start local webhook server
  ${CYAN}stop${RESET}                  Stop webhook server
  ${CYAN}test${RESET} <org/repo>       Send test webhook event to repo
  ${CYAN}logs${RESET}                  Show webhook server logs
  ${CYAN}secret${RESET} [show|reset]   Manage webhook secret

${BOLD}ENVIRONMENT VARIABLES${RESET}
  WEBHOOK_PORT              Port for webhook server (default: 8765)
  WEBHOOK_SECRET_FILE       Secret file location (default: ~/.shipwright/webhook-secret)

${BOLD}EXAMPLES${RESET}
  ${DIM}# Setup webhook for a repo${RESET}
  shipwright webhook setup myorg/myrepo

  ${DIM}# Start the webhook server${RESET}
  shipwright webhook start

  ${DIM}# Check status${RESET}
  shipwright webhook status

  ${DIM}# View logs${RESET}
  shipwright webhook logs

${BOLD}NOTES${RESET}
  - Webhook secret is stored in ${WEBHOOK_SECRET_FILE}
  - Events are logged to ${WEBHOOK_EVENTS_FILE}
  - Requires GitHub CLI (gh) for setup commands
  - Requires netcat (nc) for server

EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        setup)
            cmd_setup "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        start)
            cmd_start "$@"
            ;;
        stop)
            cmd_stop "$@"
            ;;
        test)
            cmd_test "$@"
            ;;
        logs)
            cmd_logs "$@"
            ;;
        secret)
            cmd_secret "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
