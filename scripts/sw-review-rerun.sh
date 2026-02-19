#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright review-rerun — Canonical Rerun Comment Writer               ║
# ║  SHA-deduped rerun requests · Single writer · No duplicate bot comments ║
# ║  Part of the Code Factory pattern for deterministic agent review loops  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# Load marker from policy or use default
get_rerun_marker() {
    local policy="${REPO_DIR}/config/policy.json"
    if [[ -f "$policy" ]]; then
        jq -r '.codeReviewAgent.rerunMarker // "<!-- shipwright-review-rerun -->"' "$policy" 2>/dev/null
    else
        echo "<!-- shipwright-review-rerun -->"
    fi
}

# Check if a rerun was already requested for this SHA on this PR
rerun_already_requested() {
    local pr_number="$1"
    local head_sha="$2"
    local marker
    marker=$(get_rerun_marker)
    local trigger="sha:${head_sha}"

    local comments
    comments=$(gh pr view "$pr_number" --json comments --jq '.comments[].body' 2>/dev/null || echo "")

    if echo "$comments" | grep -qF "$marker" && echo "$comments" | grep -qF "$trigger"; then
        return 0
    fi
    return 1
}

# Post a SHA-deduped rerun comment to a PR
request_rerun() {
    local pr_number="$1"
    local head_sha="$2"
    local review_agent="${3:-shipwright}"

    if [[ -z "$pr_number" || -z "$head_sha" ]]; then
        error "Usage: sw-review-rerun.sh request <pr_number> <head_sha> [review_agent]"
        return 1
    fi

    local marker
    marker=$(get_rerun_marker)
    local trigger="sha:${head_sha}"
    local short_sha="${head_sha:0:7}"

    if rerun_already_requested "$pr_number" "$head_sha"; then
        info "Rerun already requested for PR #${pr_number} at SHA ${short_sha} — skipping"
        return 0
    fi

    local body="${marker}
**Review Rerun Requested** (${short_sha})

@${review_agent} please re-review this PR at the current head.

${trigger}
---
*Canonical rerun request by Shipwright Code Factory. One writer, SHA-deduped.*"

    if gh pr comment "$pr_number" --body "$body" 2>/dev/null; then
        success "Rerun requested for PR #${pr_number} at SHA ${short_sha}"
        emit_event "review.rerun_requested" "pr=${pr_number}" "head_sha=${short_sha}" "agent=${review_agent}"
        return 0
    else
        error "Failed to post rerun comment on PR #${pr_number}"
        return 1
    fi
}

# Check current rerun state for a PR
check_rerun_state() {
    local pr_number="$1"

    local head_sha
    head_sha=$(gh pr view "$pr_number" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")

    if [[ -z "$head_sha" ]]; then
        error "Could not get head SHA for PR #${pr_number}"
        return 1
    fi

    local short_sha="${head_sha:0:7}"

    if rerun_already_requested "$pr_number" "$head_sha"; then
        info "Rerun already requested for current head ${short_sha}"
    else
        info "No rerun requested for current head ${short_sha}"
    fi

    echo "head_sha=${head_sha}"
}

# Wait for a review agent check to complete on the current head
wait_for_review() {
    local pr_number="$1"
    local head_sha="$2"
    local timeout_minutes="${3:-20}"

    local policy="${REPO_DIR}/config/policy.json"
    if [[ -f "$policy" ]]; then
        timeout_minutes=$(jq -r ".codeReviewAgent.timeoutMinutes // ${timeout_minutes}" "$policy" 2>/dev/null || echo "$timeout_minutes")
    fi

    local short_sha="${head_sha:0:7}"
    local deadline=$(($(date +%s) + timeout_minutes * 60))

    info "Waiting for review completion on ${short_sha} (timeout: ${timeout_minutes}m)..."

    while [[ $(date +%s) -lt "$deadline" ]]; do
        local owner_repo
        owner_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
        [[ -z "$owner_repo" ]] && { warn "Cannot detect repo"; return 1; }

        local review_checks
        review_checks=$(gh api "repos/${owner_repo}/commits/${head_sha}/check-runs" \
            --jq '.check_runs[] | select(.name | test("review|code.review"; "i")) | {name: .name, status: .status, conclusion: .conclusion}' 2>/dev/null || echo "")

        if [[ -n "$review_checks" ]]; then
            local all_complete="true"
            local any_failure="false"
            while IFS= read -r check; do
                [[ -z "$check" ]] && continue
                local status conclusion
                status=$(echo "$check" | jq -r '.status' 2>/dev/null || echo "")
                conclusion=$(echo "$check" | jq -r '.conclusion' 2>/dev/null || echo "")
                if [[ "$status" != "completed" ]]; then
                    all_complete="false"
                fi
                if [[ "$conclusion" == "failure" || "$conclusion" == "action_required" ]]; then
                    any_failure="true"
                fi
            done <<< "$review_checks"

            if [[ "$all_complete" == "true" ]]; then
                if [[ "$any_failure" == "true" ]]; then
                    error "Review check failed for SHA ${short_sha}"
                    return 1
                fi
                success "Review check passed for SHA ${short_sha}"
                return 0
            fi
        fi

        sleep 30
    done

    error "Review timed out after ${timeout_minutes}m for SHA ${short_sha}"
    return 1
}

show_help() {
    cat << 'EOF'
Usage: shipwright review-rerun <command> [args]

Commands:
  request <pr#> <sha> [agent]   Post SHA-deduped rerun comment
  check <pr#>                   Check rerun state for current head
  wait <pr#> <sha> [timeout]    Wait for review completion on SHA

Part of the Code Factory pattern — single canonical rerun writer
with SHA deduplication to prevent duplicate bot comments.
EOF
}

main() {
    local subcommand="${1:-help}"
    shift || true

    case "$subcommand" in
        request)
            request_rerun "$@"
            ;;
        check)
            check_rerun_state "$@"
            ;;
        wait)
            wait_for_review "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown subcommand: $subcommand"
            show_help
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
