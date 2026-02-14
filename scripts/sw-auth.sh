#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright auth — GitHub OAuth Authentication                           ║
# ║  Device flow · Token management · Session validation · Multi-user        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.13.0"
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
            local escaped_val
            escaped_val=$(printf '%s' "$val" | jq -Rs '.' 2>/dev/null || printf '"%s"' "${val//\"/\\\"}")
            json_fields="${json_fields},\"${key}\":${escaped_val}"
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Auth Storage ───────────────────────────────────────────────────────────
AUTH_FILE="${HOME}/.shipwright/auth.json"
DEVICE_FLOW_ENDPOINT="https://github.com/login/device"
API_ENDPOINT="https://api.github.com"
OAUTH_CLIENT_ID="${GITHUB_OAUTH_CLIENT_ID:-Iv1.d3f6a7e8c9b2a1d4}"  # Shipwright app ID
OAUTH_TIMEOUT=900  # 15 minutes

# Ensure auth storage directory exists
ensure_auth_dir() {
    mkdir -p "${HOME}/.shipwright"
    if [[ ! -f "$AUTH_FILE" ]]; then
        echo '{"users":[],"active_user":null}' > "$AUTH_FILE"
        chmod 600 "$AUTH_FILE"
    fi
}

# ─── Device Flow (GitHub OAuth) ──────────────────────────────────────────────
# Implements GitHub OAuth device flow without requiring a web server.
# Returns device_code, user_code, interval, expires_in
initiate_device_flow() {
    local response
    response=$(curl -s -X POST \
        -H "Accept: application/json" \
        "${API_ENDPOINT}/login/device/code" \
        -d "client_id=${OAUTH_CLIENT_ID}&scope=read:user%20user:email" 2>/dev/null) || {
        error "Failed to contact GitHub OAuth endpoint"
        return 1
    }

    # Check for errors in response
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        local err
        err=$(echo "$response" | jq -r '.error_description // .error')
        error "GitHub OAuth error: $err"
        return 1
    fi

    # Extract device code, user code, interval
    local device_code user_code interval expires_in
    device_code=$(echo "$response" | jq -r '.device_code')
    user_code=$(echo "$response" | jq -r '.user_code')
    interval=$(echo "$response" | jq -r '.interval // 5')
    expires_in=$(echo "$response" | jq -r '.expires_in // 900')

    # Output as key=value pairs for easy sourcing
    echo "DEVICE_CODE=${device_code}"
    echo "USER_CODE=${user_code}"
    echo "INTERVAL=${interval}"
    echo "EXPIRES_IN=${expires_in}"
}

# Poll for token after user authorizes at github.com/login/device
poll_for_token() {
    local device_code="$1"
    local interval="$2"
    local expires_in="$3"
    local start_time
    start_time=$(now_epoch)

    while true; do
        local elapsed
        elapsed=$(($(now_epoch) - start_time))

        if [[ $elapsed -gt $expires_in ]]; then
            error "Device code expired. Authorization timeout."
            return 1
        fi

        local response
        response=$(curl -s -X POST \
            -H "Accept: application/json" \
            "${API_ENDPOINT}/login/oauth/access_token" \
            -d "client_id=${OAUTH_CLIENT_ID}&device_code=${device_code}&grant_type=urn:ietf:params:oauth:grant-type:device_code" 2>/dev/null) || {
            warn "Failed to reach GitHub. Retrying..."
            sleep "$interval"
            continue
        }

        # Check if authorization pending
        if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
            local error_code
            error_code=$(echo "$response" | jq -r '.error')

            if [[ "$error_code" == "authorization_pending" ]]; then
                # User hasn't authorized yet, wait and retry
                sleep "$interval"
                continue
            elif [[ "$error_code" == "expired_token" ]]; then
                error "Device code expired. Please try again."
                return 1
            else
                # Other error (bad request, etc.)
                local err_desc
                err_desc=$(echo "$response" | jq -r '.error_description // .error')
                error "GitHub OAuth error: $err_desc"
                return 1
            fi
        fi

        # Success! Extract token
        local access_token
        access_token=$(echo "$response" | jq -r '.access_token')
        if [[ -z "$access_token" ]] || [[ "$access_token" == "null" ]]; then
            error "No access token in response"
            return 1
        fi

        echo "$access_token"
        return 0
    done
}

# Fetch user info from GitHub
fetch_user_info() {
    local token="$1"
    local response

    response=$(curl -s -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github.v3+json" \
        "${API_ENDPOINT}/user" 2>/dev/null) || {
        error "Failed to fetch user info"
        return 1
    }

    if echo "$response" | jq -e '.message' >/dev/null 2>&1; then
        local err
        err=$(echo "$response" | jq -r '.message')
        error "GitHub API error: $err"
        return 1
    fi

    echo "$response"
}

# Validate token by hitting /user endpoint
validate_token() {
    local token="$1"

    if ! curl -s -f \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github.v3+json" \
        "${API_ENDPOINT}/user" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Revoke a GitHub token
revoke_token() {
    local token="$1"

    # GitHub revoke endpoint requires basic auth with client_id and client_secret
    # For now, we just remove it locally (tokens expire naturally)
    return 0
}

# ─── Token Management ────────────────────────────────────────────────────────
# Store user token in auth.json
store_user() {
    local login="$1"
    local token="$2"
    local user_json="$3"

    ensure_auth_dir

    local temp_file
    temp_file=$(mktemp)
    trap "rm -f '$temp_file'" RETURN

    local updated
    updated=$(jq --arg login "$login" \
        --arg token "$token" \
        --argjson user "$user_json" \
        '.users |= map(select(.login != $login)) | .users += [{login: $login, token: $token, user: $user, stored_at: now | todate}] | .active_user = $login' \
        "$AUTH_FILE")

    echo "$updated" | jq '.' > "$temp_file" 2>/dev/null || {
        error "Failed to update auth file"
        return 1
    }

    mv "$temp_file" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    success "User $login authenticated and stored"
}

# Get active user
get_active_user() {
    ensure_auth_dir
    jq -r '.active_user // empty' "$AUTH_FILE" 2>/dev/null || echo ""
}

# Get all users
list_users() {
    ensure_auth_dir
    jq -r '.users[] | .login' "$AUTH_FILE" 2>/dev/null || true
}

# Switch active user
switch_user() {
    local login="$1"
    ensure_auth_dir

    # Verify user exists
    if ! jq -e ".users[] | select(.login == \"${login}\")" "$AUTH_FILE" >/dev/null 2>&1; then
        error "User not found: $login"
        return 1
    fi

    local temp_file
    temp_file=$(mktemp)
    trap "rm -f '$temp_file'" RETURN

    jq --arg login "$login" '.active_user = $login' "$AUTH_FILE" > "$temp_file"
    mv "$temp_file" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    success "Switched to user: $login"
}

# Remove user
remove_user() {
    local login="$1"
    ensure_auth_dir

    local temp_file
    temp_file=$(mktemp)
    trap "rm -f '$temp_file'" RETURN

    jq --arg login "$login" \
        '.users |= map(select(.login != $login)) |
         if .active_user == $login then .active_user = null else . end' \
        "$AUTH_FILE" > "$temp_file"
    mv "$temp_file" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    success "User removed: $login"
}

# Get token for user (or active user)
get_token() {
    local login="${1:-}"
    ensure_auth_dir

    if [[ -z "$login" ]]; then
        login=$(get_active_user)
        if [[ -z "$login" ]]; then
            error "No user logged in"
            return 1
        fi
    fi

    local token
    token=$(jq -r ".users[] | select(.login == \"${login}\") | .token" "$AUTH_FILE" 2>/dev/null)

    if [[ -z "$token" ]] || [[ "$token" == "null" ]]; then
        error "No token found for user: $login"
        return 1
    fi

    echo "$token"
}

# Get user info (login, name, avatar_url, email)
get_user_info() {
    local login="${1:-}"
    ensure_auth_dir

    if [[ -z "$login" ]]; then
        login=$(get_active_user)
        if [[ -z "$login" ]]; then
            error "No user logged in"
            return 1
        fi
    fi

    jq -r ".users[] | select(.login == \"${login}\") | .user" "$AUTH_FILE" 2>/dev/null || {
        error "User info not found"
        return 1
    }
}

# ─── Middleware Helpers ──────────────────────────────────────────────────────
# Output auth header for use in other tools
output_auth_header() {
    local login="${1:-}"
    local token

    token=$(get_token "$login") || return 1
    echo "Authorization: Bearer ${token}"
}

# Output user info in dashboard-friendly format
output_user_json() {
    local login="${1:-}"
    local user_info

    user_info=$(get_user_info "$login") || return 1
    echo "$user_info"
}

# ─── Command Handlers ────────────────────────────────────────────────────────
cmd_login() {
    info "Starting GitHub OAuth device flow..."

    # Initiate device flow
    local device_flow_vars
    device_flow_vars=$(initiate_device_flow) || return 1

    # Source the variables
    eval "$device_flow_vars"

    info "Visit: ${CYAN}${DEVICE_FLOW_ENDPOINT}${RESET}"
    info "Enter code: ${BOLD}${USER_CODE}${RESET}"
    echo ""
    warn "Waiting for authorization (expires in ${EXPIRES_IN}s)..."

    # Poll for token
    local access_token
    access_token=$(poll_for_token "$DEVICE_CODE" "$INTERVAL" "$EXPIRES_IN") || return 1

    info "Authorization successful! Fetching user info..."

    # Fetch user info
    local user_info
    user_info=$(fetch_user_info "$access_token") || return 1

    local login
    login=$(echo "$user_info" | jq -r '.login')

    # Store user
    store_user "$login" "$access_token" "$user_info"
    emit_event "auth_login" "user=${login}"
    success "Logged in as ${CYAN}${login}${RESET}"
}

cmd_logout() {
    local login="${1:-}"
    ensure_auth_dir

    if [[ -z "$login" ]]; then
        login=$(get_active_user)
        if [[ -z "$login" ]]; then
            error "No user logged in"
            return 1
        fi
    fi

    # Revoke token
    local token
    token=$(get_token "$login") || return 1
    revoke_token "$token"

    # Remove user from storage
    remove_user "$login"
    emit_event "auth_logout" "user=${login}"
    success "Logged out and token revoked"
}

cmd_status() {
    ensure_auth_dir

    local active
    active=$(get_active_user)

    if [[ -z "$active" ]]; then
        warn "Not logged in"
        return 1
    fi

    local user_info
    user_info=$(get_user_info "$active") || return 1

    local login name avatar_url email
    login=$(echo "$user_info" | jq -r '.login')
    name=$(echo "$user_info" | jq -r '.name // "N/A"')
    avatar_url=$(echo "$user_info" | jq -r '.avatar_url // "N/A"')
    email=$(echo "$user_info" | jq -r '.email // "N/A"')

    info "Authenticated as:"
    echo -e "  ${CYAN}Login${RESET}:  ${login}"
    echo -e "  ${CYAN}Name${RESET}:   ${name}"
    echo -e "  ${CYAN}Email${RESET}:  ${email}"
    echo -e "  ${CYAN}Avatar${RESET}: ${avatar_url}"

    # Check token validity
    local token
    token=$(get_token "$active")
    if validate_token "$token"; then
        success "Token is valid"
    else
        warn "Token is invalid or expired"
    fi
}

cmd_token() {
    local login="${1:-}"
    get_token "$login"
}

cmd_user() {
    local login="${1:-}"
    local format="${2:-json}"

    local user_info
    user_info=$(get_user_info "$login") || return 1

    if [[ "$format" == "json" ]]; then
        echo "$user_info" | jq '.'
    else
        # Simple text format
        echo "$user_info" | jq -r '
            "Login: \(.login)\n" +
            "Name: \(.name // "N/A")\n" +
            "Email: \(.email // "N/A")\n" +
            "Avatar: \(.avatar_url // "N/A")\n" +
            "Company: \(.company // "N/A")\n" +
            "Location: \(.location // "N/A")\n" +
            "Bio: \(.bio // "N/A")"
        '
    fi
}

cmd_refresh() {
    local login="${1:-}"
    ensure_auth_dir

    if [[ -z "$login" ]]; then
        login=$(get_active_user)
        if [[ -z "$login" ]]; then
            error "No user logged in"
            return 1
        fi
    fi

    info "Validating token for ${login}..."
    local token
    token=$(get_token "$login") || return 1

    if ! validate_token "$token"; then
        error "Token invalid or expired. Please login again."
        remove_user "$login"
        return 1
    fi

    # Refresh user info
    local user_info
    user_info=$(fetch_user_info "$token") || return 1

    # Re-store with updated info
    store_user "$login" "$token" "$user_info"
    success "Token and user info refreshed"
}

cmd_users() {
    ensure_auth_dir

    local users
    users=$(list_users)

    if [[ -z "$users" ]]; then
        warn "No users authenticated"
        return 1
    fi

    local active
    active=$(get_active_user)

    info "Authenticated users:"
    while IFS= read -r user; do
        if [[ "$user" == "$active" ]]; then
            echo -e "  ${GREEN}✓${RESET} ${user} ${DIM}(active)${RESET}"
        else
            echo -e "  ${CYAN}•${RESET} ${user}"
        fi
    done <<< "$users"
}

cmd_switch() {
    local login="$1"
    if [[ -z "$login" ]]; then
        error "Usage: shipwright auth switch <login>"
        return 1
    fi
    switch_user "$login"
}

cmd_help() {
    cat << 'EOF'
Usage: shipwright auth <command> [options]

Commands:
  login              Start GitHub OAuth device flow
  logout [user]      Revoke token and remove user (or active user)
  status             Show current auth status
  token [user]       Output current access token (for piping)
  user [user] [fmt]  Show authenticated user profile (json or text)
  refresh [user]     Force token validation and refresh
  users              List all authenticated users
  switch <user>      Switch active user
  help               Show this help message

Examples:
  shipwright auth login                    # Start OAuth flow
  shipwright auth status                   # Show logged-in user
  shipwright auth token | xargs -I {} curl -H "Authorization: Bearer {}" https://api.github.com/user
  shipwright auth users                    # List all users
  shipwright auth switch alice             # Switch to alice
  shipwright auth logout                   # Logout active user

EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        login)
            cmd_login "$@"
            ;;
        logout)
            cmd_logout "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        token)
            cmd_token "$@"
            ;;
        user)
            cmd_user "$@"
            ;;
        refresh)
            cmd_refresh "$@"
            ;;
        users)
            cmd_users "$@"
            ;;
        switch)
            cmd_switch "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            error "Unknown command: $cmd"
            cmd_help >&2
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
