#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright github-deploy — Native GitHub Deployments API Integration  ║
# ║  Environment tracking · Rollbacks · Pipeline deploy integration        ║
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
# ─── Artifacts Directory ─────────────────────────────────────────────────────
ARTIFACTS_DIR="${REPO_DIR}/.claude/pipeline-artifacts"

# ─── Auto-detect owner/repo from git remote ──────────────────────────────────
_gh_detect_repo() {
    local remote_url
    remote_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
    if [[ -z "$remote_url" ]]; then
        echo ""
        return 1
    fi
    local owner_repo
    owner_repo=$(echo "$remote_url" | sed -E 's#^(https?://github\.com/|git@github\.com:)##; s#\.git$##')
    echo "$owner_repo"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DEPLOYMENTS API FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Create a deployment ──────────────────────────────────────────────────────
gh_deploy_create() {
    local owner="${1:-}"
    local repo="${2:-}"
    local ref="${3:-}"
    local environment="${4:-production}"
    local description="${5:-}"
    local auto_merge="${6:-false}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        return 0
    fi

    if [[ -z "$owner" || -z "$repo" || -z "$ref" ]]; then
        error "Usage: gh_deploy_create <owner> <repo> <ref> [environment] [description] [auto_merge]"
        return 1
    fi

    local body
    body=$(jq -n \
        --arg ref "$ref" \
        --arg env "$environment" \
        --arg desc "$description" \
        --argjson auto_merge "${auto_merge}" \
        '{
            ref: $ref,
            environment: $env,
            description: $desc,
            auto_merge: $auto_merge,
            required_contexts: []
        }')

    local response=""
    local result=0
    response=$(gh api "repos/${owner}/${repo}/deployments" \
        --method POST \
        --input - <<< "$body" 2>/dev/null) || result=$?

    if [[ "$result" -ne 0 ]]; then
        warn "Failed to create deployment for ref '${ref}' to '${environment}' (API returned ${result})" >&2
        echo ""
        return 0
    fi

    local deploy_id
    deploy_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null || true)

    if [[ -n "$deploy_id" && "$deploy_id" != "null" ]]; then
        emit_event "deploy.create" "deploy_id=$deploy_id" "ref=$ref" "environment=$environment"
        echo "$deploy_id"
    else
        warn "Deployment created but no ID returned" >&2
        echo ""
    fi
}

# ─── Update deployment status ─────────────────────────────────────────────────
gh_deploy_update_status() {
    local owner="${1:-}"
    local repo="${2:-}"
    local deploy_id="${3:-}"
    local state="${4:-}"
    local environment_url="${5:-}"
    local description="${6:-}"
    local log_url="${7:-}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        return 0
    fi

    # Skip silently if deploy_id is empty
    if [[ -z "$deploy_id" ]]; then
        return 0
    fi

    if [[ -z "$owner" || -z "$repo" || -z "$state" ]]; then
        error "Usage: gh_deploy_update_status <owner> <repo> <deploy_id> <state> [env_url] [description] [log_url]"
        return 1
    fi

    local body
    body=$(jq -n \
        --arg state "$state" \
        --arg env_url "$environment_url" \
        --arg desc "$description" \
        --arg log_url "$log_url" \
        '{state: $state}
        + (if $env_url != "" then {environment_url: $env_url} else {} end)
        + (if $desc != "" then {description: $desc} else {} end)
        + (if $log_url != "" then {log_url: $log_url} else {} end)')

    local result=0
    gh api "repos/${owner}/${repo}/deployments/${deploy_id}/statuses" \
        --method POST \
        --input - <<< "$body" --silent 2>/dev/null || result=$?

    if [[ "$result" -ne 0 ]]; then
        warn "Failed to update deployment status for ${deploy_id}"
    else
        emit_event "deploy.status" "deploy_id=$deploy_id" "state=$state"
    fi
}

# ─── List deployments ─────────────────────────────────────────────────────────
gh_deploy_list() {
    local owner="${1:-}"
    local repo="${2:-}"
    local environment="${3:-}"
    local limit="${4:-10}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        echo "[]"
        return 0
    fi

    if [[ -z "$owner" || -z "$repo" ]]; then
        error "Usage: gh_deploy_list <owner> <repo> [environment] [limit]"
        return 1
    fi

    local endpoint="repos/${owner}/${repo}/deployments?per_page=${limit}"
    if [[ -n "$environment" ]]; then
        endpoint="${endpoint}&environment=${environment}"
    fi

    local response=""
    local result=0
    response=$(gh api "$endpoint" 2>/dev/null) || result=$?

    if [[ "$result" -ne 0 ]]; then
        warn "Failed to list deployments" >&2
        echo "[]"
        return 0
    fi

    echo "$response" | jq '[.[] | {id, ref, environment, description, created_at}]' 2>/dev/null || echo "[]"
}

# ─── Get latest deployment ────────────────────────────────────────────────────
gh_deploy_latest() {
    local owner="${1:-}"
    local repo="${2:-}"
    local environment="${3:-production}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        echo "{}"
        return 0
    fi

    if [[ -z "$owner" || -z "$repo" ]]; then
        error "Usage: gh_deploy_latest <owner> <repo> [environment]"
        return 1
    fi

    local response=""
    local result=0
    response=$(gh api "repos/${owner}/${repo}/deployments?environment=${environment}&per_page=1" 2>/dev/null) || result=$?

    if [[ "$result" -ne 0 ]]; then
        warn "Failed to get latest deployment" >&2
        echo "{}"
        return 0
    fi

    local first
    first=$(echo "$response" | jq '.[0] // {}' 2>/dev/null || echo "{}")
    echo "$first"
}

# ─── Rollback to previous deployment ──────────────────────────────────────────
gh_deploy_rollback() {
    local owner="${1:-}"
    local repo="${2:-}"
    local environment="${3:-production}"
    local description="${4:-Rollback via Shipwright}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        return 0
    fi

    if [[ -z "$owner" || -z "$repo" ]]; then
        error "Usage: gh_deploy_rollback <owner> <repo> [environment] [description]"
        return 1
    fi

    # Get the two most recent deployments
    local deployments=""
    local result=0
    deployments=$(gh api "repos/${owner}/${repo}/deployments?environment=${environment}&per_page=2" 2>/dev/null) || result=$?

    if [[ "$result" -ne 0 ]]; then
        error "Failed to fetch deployments for rollback"
        return 1
    fi

    local count
    count=$(echo "$deployments" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -lt 2 ]]; then
        error "Not enough deployments to rollback (found ${count}, need at least 2)"
        return 1
    fi

    # Get the previous (second) deployment's ref
    local prev_ref
    prev_ref=$(echo "$deployments" | jq -r '.[1].ref // empty' 2>/dev/null || true)

    if [[ -z "$prev_ref" || "$prev_ref" == "null" ]]; then
        error "Could not determine previous deployment ref"
        return 1
    fi

    info "Rolling back to ref: ${prev_ref}" >&2

    # Mark current deployment as inactive
    local current_id
    current_id=$(echo "$deployments" | jq -r '.[0].id // empty' 2>/dev/null || true)
    if [[ -n "$current_id" && "$current_id" != "null" ]]; then
        gh_deploy_update_status "$owner" "$repo" "$current_id" "inactive" "" "Superseded by rollback"
    fi

    # Create new deployment with previous ref
    local new_id
    new_id=$(gh_deploy_create "$owner" "$repo" "$prev_ref" "$environment" "$description")

    if [[ -n "$new_id" ]]; then
        gh_deploy_update_status "$owner" "$repo" "$new_id" "success" "" "$description"
        emit_event "deploy.rollback" "new_id=$new_id" "prev_ref=$prev_ref" "environment=$environment"
        success "Rolled back to ${prev_ref} (deployment ${new_id})" >&2
        echo "$new_id"
    else
        error "Failed to create rollback deployment"
        return 1
    fi
}

# ─── Start pipeline deployment ────────────────────────────────────────────────
gh_deploy_pipeline_start() {
    local owner="${1:-}"
    local repo="${2:-}"
    local ref="${3:-}"
    local environment="${4:-production}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        echo ""
        return 0
    fi

    if [[ -z "$owner" || -z "$repo" || -z "$ref" ]]; then
        error "Usage: gh_deploy_pipeline_start <owner> <repo> <ref> [environment]"
        return 1
    fi

    local deploy_id
    deploy_id=$(gh_deploy_create "$owner" "$repo" "$ref" "$environment" "Shipwright pipeline deployment")

    if [[ -z "$deploy_id" ]]; then
        warn "Could not create pipeline deployment" >&2
        echo ""
        return 0
    fi

    # Set status to in_progress
    gh_deploy_update_status "$owner" "$repo" "$deploy_id" "in_progress" "" "Pipeline running"

    # Store deployment ID atomically
    mkdir -p "$ARTIFACTS_DIR"
    local tmp_file
    tmp_file=$(mktemp "${ARTIFACTS_DIR}/deployment.XXXXXX")
    jq -n \
        --arg id "$deploy_id" \
        --arg env "$environment" \
        --arg ref "$ref" \
        --arg started_at "$(now_iso)" \
        '{deploy_id: $id, environment: $env, ref: $ref, started_at: $started_at}' > "$tmp_file"
    mv "$tmp_file" "${ARTIFACTS_DIR}/deployment.json"

    emit_event "deploy.pipeline_start" "deploy_id=$deploy_id" "ref=$ref" "environment=$environment"
    echo "$deploy_id"
}

# ─── Complete pipeline deployment ─────────────────────────────────────────────
gh_deploy_pipeline_complete() {
    local owner="${1:-}"
    local repo="${2:-}"
    local environment="${3:-production}"
    local is_success="${4:-true}"
    local env_url="${5:-}"

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        return 0
    fi

    local deploy_file="${ARTIFACTS_DIR}/deployment.json"
    if [[ ! -f "$deploy_file" ]]; then
        warn "No deployment.json found — skipping pipeline complete"
        return 0
    fi

    local deploy_id
    deploy_id=$(jq -r '.deploy_id // empty' "$deploy_file" 2>/dev/null || true)

    if [[ -z "$deploy_id" || "$deploy_id" == "null" ]]; then
        warn "No deployment ID in deployment.json"
        return 0
    fi

    if [[ -z "$owner" || -z "$repo" ]]; then
        local detected
        detected=$(_gh_detect_repo || true)
        if [[ -n "$detected" ]]; then
            owner="${detected%%/*}"
            repo="${detected##*/}"
        fi
    fi

    if [[ -z "$owner" || -z "$repo" ]]; then
        warn "Could not detect owner/repo — skipping pipeline complete"
        return 0
    fi

    local state="success"
    local desc="Pipeline completed successfully"
    if [[ "$is_success" != "true" && "$is_success" != "1" ]]; then
        state="failure"
        desc="Pipeline failed"
    fi

    gh_deploy_update_status "$owner" "$repo" "$deploy_id" "$state" "$env_url" "$desc"

    emit_event "deploy.pipeline_complete" "deploy_id=$deploy_id" "state=$state" "environment=$environment"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLI INTERFACE
# ═══════════════════════════════════════════════════════════════════════════════

show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright github-deploy${RESET} — Native GitHub Deployments API Integration"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  shipwright deploy <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}list${RESET} [environment]          List deployments"
    echo -e "  ${CYAN}create${RESET} <ref> [environment]  Create a new deployment"
    echo -e "  ${CYAN}rollback${RESET} [environment]      Rollback to previous deployment"
    echo -e "  ${CYAN}help${RESET}                        Show this help"
    echo ""
    echo -e "${BOLD}FUNCTIONS (for sourcing)${RESET}"
    echo -e "  ${DIM}gh_deploy_create            Create a deployment${RESET}"
    echo -e "  ${DIM}gh_deploy_update_status      Update deployment status${RESET}"
    echo -e "  ${DIM}gh_deploy_list               List deployments${RESET}"
    echo -e "  ${DIM}gh_deploy_latest             Get latest deployment${RESET}"
    echo -e "  ${DIM}gh_deploy_rollback           Rollback to previous ref${RESET}"
    echo -e "  ${DIM}gh_deploy_pipeline_start     Start pipeline deployment${RESET}"
    echo -e "  ${DIM}gh_deploy_pipeline_complete  Complete pipeline deployment${RESET}"
    echo ""
    echo -e "${DIM}Version ${VERSION}${RESET}"
}

_deploy_list_cli() {
    local environment="${1:-}"

    local detected
    detected=$(_gh_detect_repo || true)
    if [[ -z "$detected" ]]; then
        error "Could not detect owner/repo from git remote"
        exit 1
    fi

    local owner="${detected%%/*}"
    local repo="${detected##*/}"

    info "Listing deployments${environment:+ for ${environment}}..."
    local deploys
    deploys=$(gh_deploy_list "$owner" "$repo" "$environment" 10)

    local count
    count=$(echo "$deploys" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        info "No deployments found"
        return 0
    fi

    echo ""
    echo -e "${BOLD}Deployments (${count})${RESET}"
    echo ""

    echo "$deploys" | jq -r '.[] | "  \(.id)\t\(.ref)\t\(.environment)\t\(.created_at)"' 2>/dev/null || true
    echo ""
}

_deploy_create_cli() {
    local ref="${1:-}"
    local environment="${2:-production}"

    if [[ -z "$ref" ]]; then
        error "Usage: shipwright deploy create <ref> [environment]"
        exit 1
    fi

    local detected
    detected=$(_gh_detect_repo || true)
    if [[ -z "$detected" ]]; then
        error "Could not detect owner/repo from git remote"
        exit 1
    fi

    local owner="${detected%%/*}"
    local repo="${detected##*/}"

    info "Creating deployment for '${ref}' to '${environment}'..."
    local deploy_id
    deploy_id=$(gh_deploy_create "$owner" "$repo" "$ref" "$environment" "Manual deployment")

    if [[ -n "$deploy_id" ]]; then
        success "Created deployment: ${deploy_id}"
    else
        error "Failed to create deployment"
        exit 1
    fi
}

_deploy_rollback_cli() {
    local environment="${1:-production}"

    local detected
    detected=$(_gh_detect_repo || true)
    if [[ -z "$detected" ]]; then
        error "Could not detect owner/repo from git remote"
        exit 1
    fi

    local owner="${detected%%/*}"
    local repo="${detected##*/}"

    gh_deploy_rollback "$owner" "$repo" "$environment"
}

main() {
    case "${1:-help}" in
        list)     shift; _deploy_list_cli "$@" ;;
        create)   shift; _deploy_create_cli "$@" ;;
        rollback) shift; _deploy_rollback_cli "$@" ;;
        help|--help|-h) show_help ;;
        *)        error "Unknown command: $1"; show_help; exit 1 ;;
    esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
