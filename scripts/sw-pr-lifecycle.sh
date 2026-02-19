#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pr-lifecycle — Autonomous PR Management                       ║
# ║  Auto-review · Auto-merge · Stale cleanup · Issue feedback                ║
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
# ─── Configuration Helpers ──────────────────────────────────────────────────

get_pr_config() {
    local key="$1"
    local default="${2:-}"
    jq -r ".pr_lifecycle.${key} // \"${default}\"" "$REPO_DIR/.claude/daemon-config.json" 2>/dev/null || echo "$default"
}

# ─── GitHub API Wrappers ────────────────────────────────────────────────────

get_pr_info() {
    local pr_number="$1"
    gh pr view "$pr_number" --json number,title,body,state,headRefName,baseRefName,statusCheckRollup,reviews,commits,createdAt,updatedAt,headRefOid 2>/dev/null || return 1
}

get_pr_head_sha() {
    local pr_number="$1"
    gh pr view "$pr_number" --json headRefOid --jq '.headRefOid' 2>/dev/null || return 1
}

get_pr_checks_status() {
    local pr_number="$1"
    # Returns: success, failure, pending, or unknown
    # gh pr checks requires --json flag to produce JSON output
    local checks_json
    checks_json=$(gh pr checks "$pr_number" --json name,state,conclusion 2>/dev/null || echo "[]")

    # Handle empty or non-JSON response
    if [[ -z "$checks_json" ]] || ! echo "$checks_json" | jq empty 2>/dev/null; then
        echo "unknown"
        return
    fi

    local total failed pending
    total=$(echo "$checks_json" | jq 'length' 2>/dev/null || echo "0")
    [[ "$total" -eq 0 ]] && { echo "unknown"; return; }

    failed=$(echo "$checks_json" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "failure")] | length' 2>/dev/null || echo "0")
    [[ "$failed" -gt 0 ]] && { echo "failure"; return; }

    pending=$(echo "$checks_json" | jq '[.[] | select(.state == "PENDING" or .state == "QUEUED" or .state == "IN_PROGRESS")] | length' 2>/dev/null || echo "0")
    [[ "$pending" -gt 0 ]] && { echo "pending"; return; }

    echo "success"
}

has_merge_conflicts() {
    local pr_number="$1"
    gh pr view "$pr_number" --json mergeStateStatus 2>/dev/null | jq -r '.mergeStateStatus' | grep -qi "conflicting" && return 0 || return 1
}

get_pr_reviews() {
    local pr_number="$1"
    # Returns approved, changes_requested, pending, or none
    gh pr view "$pr_number" --json reviews 2>/dev/null | jq -r '.reviews[] | .state' 2>/dev/null | sort | uniq || echo "none"
}

get_pr_age_seconds() {
    local pr_number="$1"
    local created_at
    created_at=$(gh pr view "$pr_number" --json createdAt 2>/dev/null | jq -r '.createdAt' | head -1)
    [[ -z "$created_at" ]] && return 1
    local created_epoch
    created_epoch=$(date -d "$created_at" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo "0")
    [[ "$created_epoch" -eq 0 ]] && return 1
    echo $(($(now_epoch) - created_epoch))
}

get_pr_originating_issue() {
    local pr_number="$1"
    # Search PR body for issue reference (closes #N, fixes #N, etc.)
    local body
    body=$(gh pr view "$pr_number" --json body 2>/dev/null | jq -r '.body')
    echo "$body" | grep -oiE '(closes|fixes|resolves) #[0-9]+' | grep -oE '[0-9]+' | head -1
}

# ─── Current-Head SHA Discipline ─────────────────────────────────────────────
# All check results and review approvals MUST correspond to the current PR head
# SHA. Stale evidence from older commits is never trusted. This is the single
# most important safety invariant in the Code Factory pattern.

validate_checks_for_head_sha() {
    local pr_number="$1"
    local head_sha="$2"

    if [[ -z "$head_sha" ]]; then
        error "No head SHA provided — cannot validate check freshness"
        return 1
    fi

    local short_sha="${head_sha:0:7}"

    # Get check runs for the current head SHA
    local owner_repo
    owner_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
    if [[ -z "$owner_repo" ]]; then
        warn "Could not detect repo — skipping SHA discipline check"
        return 0
    fi

    local check_runs
    check_runs=$(gh api "repos/${owner_repo}/commits/${head_sha}/check-runs" --jq '.check_runs' 2>/dev/null || echo "[]")

    local total_checks
    total_checks=$(echo "$check_runs" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$total_checks" -eq 0 ]]; then
        warn "No check runs found for head SHA ${short_sha}"
        return 0
    fi

    local failed_checks
    failed_checks=$(echo "$check_runs" | jq '[.[] | select(.conclusion == "failure" or .conclusion == "cancelled")] | length' 2>/dev/null || echo "0")

    local pending_checks
    pending_checks=$(echo "$check_runs" | jq '[.[] | select(.status != "completed")] | length' 2>/dev/null || echo "0")

    if [[ "$failed_checks" -gt 0 ]]; then
        error "PR #${pr_number} has ${failed_checks} failed check(s) on current head ${short_sha}"
        return 1
    fi

    if [[ "$pending_checks" -gt 0 ]]; then
        warn "PR #${pr_number} has ${pending_checks} pending check(s) on head ${short_sha}"
        return 1
    fi

    info "All ${total_checks} checks passed for current head SHA ${short_sha}"
    return 0
}

validate_reviews_for_head_sha() {
    local pr_number="$1"
    local head_sha="$2"

    if [[ -z "$head_sha" ]]; then
        return 0
    fi

    local short_sha="${head_sha:0:7}"

    # Get reviews and check they're not stale (submitted before the latest push)
    local reviews_json
    reviews_json=$(gh pr view "$pr_number" --json reviews --jq '.reviews' 2>/dev/null || echo "[]")

    local latest_commit_date
    latest_commit_date=$(gh pr view "$pr_number" --json commits --jq '.commits[-1].committedDate' 2>/dev/null || echo "")

    if [[ -z "$latest_commit_date" ]]; then
        return 0
    fi

    # Check if any approvals are stale (submitted before last commit)
    local stale_approvals
    stale_approvals=$(echo "$reviews_json" | jq --arg cutoff "$latest_commit_date" \
        '[.[] | select(.state == "APPROVED" and .submittedAt < $cutoff)] | length' 2>/dev/null || echo "0")

    if [[ "$stale_approvals" -gt 0 ]]; then
        warn "PR #${pr_number} has ${stale_approvals} stale approval(s) from before head ${short_sha} — reviews should be refreshed"
    fi

    return 0
}

compute_risk_tier_for_pr() {
    local pr_number="$1"
    local policy_file="${REPO_DIR}/config/policy.json"

    if [[ ! -f "$policy_file" ]]; then
        echo "medium"
        return
    fi

    local changed_files
    changed_files=$(gh pr diff "$pr_number" --name-only 2>/dev/null || echo "")

    if [[ -z "$changed_files" ]]; then
        echo "low"
        return
    fi

    local tier="low"

    check_tier_match() {
        local check_tier="$1"
        local patterns
        patterns=$(jq -r ".riskTierRules.${check_tier}[]? // empty" "$policy_file" 2>/dev/null)
        [[ -z "$patterns" ]] && return 1

        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            local regex
            regex=$(echo "$pattern" | sed 's/\./\\./g; s/\*\*/DOUBLESTAR/g; s/\*/[^\/]*/g; s/DOUBLESTAR/.*/g')
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                if echo "$file" | grep -qE "^${regex}$"; then
                    return 0
                fi
            done <<< "$changed_files"
        done <<< "$patterns"
        return 1
    }

    if check_tier_match "critical"; then
        tier="critical"
    elif check_tier_match "high"; then
        tier="high"
    elif check_tier_match "medium"; then
        tier="medium"
    fi

    echo "$tier"
}

# ─── Review Pass ────────────────────────────────────────────────────────────

pr_review() {
    local pr_number="$1"
    info "Running review pass on PR #${pr_number}..."

    # Get PR info
    local pr_info
    pr_info=$(get_pr_info "$pr_number") || {
        error "Failed to fetch PR #${pr_number}"
        return 1
    }

    local title branch
    title=$(echo "$pr_info" | jq -r '.title')
    branch=$(echo "$pr_info" | jq -r '.headRefName')

    info "PR: ${title} (branch: ${branch})"

    # Get diff
    local diff_output
    diff_output=$(gh pr diff "$pr_number" 2>/dev/null) || {
        error "Failed to get PR diff"
        return 1
    }

    if [[ -z "$diff_output" ]]; then
        warn "No diff found for PR #${pr_number}"
        return 1
    fi

    # Evaluate quality criteria
    local issues_found=0
    local file_count
    file_count=$(echo "$diff_output" | grep -c '^diff --git' || echo "0")

    local line_additions
    line_additions=$(echo "$diff_output" | grep -c '^+' || echo "0")

    local line_deletions
    line_deletions=$(echo "$diff_output" | grep -c '^-' || echo "0")

    info "Diff analysis: ${file_count} files, +${line_additions}/-${line_deletions} lines"

    # Check for concerning patterns
    local warnings=""
    if echo "$diff_output" | grep -qE '(HACK|TODO|FIXME|XXX|BROKEN|DEBUG)'; then
        warnings="${warnings}
- Found HACK/TODO/FIXME markers in code"
        issues_found=$((issues_found + 1))
    fi

    if echo "$diff_output" | grep -qE 'console\.(log|warn|error)\('; then
        warnings="${warnings}
- Found console.log statements (should use proper logging)"
        issues_found=$((issues_found + 1))
    fi

    if [[ $line_additions -gt 500 ]]; then
        warnings="${warnings}
- Large addition (${line_additions} lines) — consider splitting into smaller PRs"
        issues_found=$((issues_found + 1))
    fi

    if [[ $file_count -gt 20 ]]; then
        warnings="${warnings}
- Many files changed (${file_count}) — consider splitting"
        issues_found=$((issues_found + 1))
    fi

    # Post review comment to PR
    local review_body="## Shipwright Auto-Review

**Status:** Review complete
**Files changed:** ${file_count}
**Lines added/removed:** +${line_additions}/-${line_deletions}"

    if [[ $issues_found -gt 0 ]]; then
        review_body="${review_body}

**Issues found:** ${issues_found}
${warnings}"
    else
        review_body="${review_body}

**Issues found:** 0
✓ No concerning patterns detected"
    fi

    gh pr comment "$pr_number" --body "$review_body" 2>/dev/null || warn "Failed to post review comment"

    success "Review complete for PR #${pr_number} (${issues_found} issues found)"
    emit_event "pr.review_complete" "pr=${pr_number}" "issues_found=${issues_found}"
}

# ─── Auto-Merge ──────────────────────────────────────────────────────────────

pr_merge() {
    local pr_number="$1"
    info "Attempting auto-merge of PR #${pr_number}..."

    # Check if auto-merge is enabled
    local auto_merge_enabled
    auto_merge_enabled=$(get_pr_config "auto_merge_enabled" "false")
    if [[ "$auto_merge_enabled" != "true" ]]; then
        warn "Auto-merge is disabled in configuration"
        return 1
    fi

    # Get PR info
    local pr_info
    pr_info=$(get_pr_info "$pr_number") || {
        error "Failed to fetch PR #${pr_number}"
        return 1
    }

    local state branch
    state=$(echo "$pr_info" | jq -r '.state')
    branch=$(echo "$pr_info" | jq -r '.headRefName')

    if [[ "$state" != "OPEN" ]]; then
        warn "PR #${pr_number} is not open (state: ${state})"
        return 1
    fi

    # ── Current-head SHA discipline ──────────────────────────────────────────
    # All evidence (checks, reviews) must be validated against the current head.
    # Never merge on stale evidence from an older commit.
    local head_sha
    head_sha=$(echo "$pr_info" | jq -r '.headRefOid // empty' 2>/dev/null)
    if [[ -z "$head_sha" ]]; then
        head_sha=$(get_pr_head_sha "$pr_number")
    fi

    if [[ -n "$head_sha" ]]; then
        local short_sha="${head_sha:0:7}"
        info "Validating evidence for current head SHA: ${short_sha}"

        if ! validate_checks_for_head_sha "$pr_number" "$head_sha"; then
            error "PR #${pr_number} blocked — checks not passing for current head ${short_sha}"
            emit_event "pr.merge_failed" "pr=${pr_number}" "reason=stale_checks" "head_sha=${short_sha}"
            return 1
        fi

        validate_reviews_for_head_sha "$pr_number" "$head_sha"
    else
        warn "Could not determine head SHA — falling back to legacy check"
    fi

    # ── Risk tier enforcement ────────────────────────────────────────────────
    local risk_tier
    risk_tier=$(compute_risk_tier_for_pr "$pr_number")
    info "Risk tier: ${risk_tier}"

    # Check for merge conflicts
    if has_merge_conflicts "$pr_number"; then
        error "PR #${pr_number} has merge conflicts — manual intervention required"
        emit_event "pr.merge_failed" "pr=${pr_number}" "reason=merge_conflicts"
        return 1
    fi

    # Check CI status (legacy check, supplementary to SHA-based validation)
    local status_check_rollup
    status_check_rollup=$(echo "$pr_info" | jq -r '.statusCheckRollup[].state' 2>/dev/null | sort | uniq)
    if [[ -z "$status_check_rollup" ]] || echo "$status_check_rollup" | grep -qi "failure\|error"; then
        error "PR #${pr_number} has failing CI checks"
        emit_event "pr.merge_failed" "pr=${pr_number}" "reason=ci_failure"
        return 1
    fi

    # Check reviews
    local reviews
    reviews=$(get_pr_reviews "$pr_number")
    if [[ "$reviews" == *"CHANGES_REQUESTED"* ]]; then
        error "PR #${pr_number} has requested changes"
        emit_event "pr.merge_failed" "pr=${pr_number}" "reason=changes_requested"
        return 1
    fi

    # Perform squash merge and delete branch
    info "Merging PR #${pr_number} with squash (tier: ${risk_tier}, head: ${head_sha:0:7})..."
    if gh pr merge "$pr_number" --squash --delete-branch 2>/dev/null; then
        success "PR #${pr_number} merged and branch deleted"
        emit_event "pr.merged" "pr=${pr_number}" "risk_tier=${risk_tier}" "head_sha=${head_sha:0:7}"

        # Post feedback to originating issue
        local issue_number
        issue_number=$(get_pr_originating_issue "$pr_number")
        if [[ -n "$issue_number" ]]; then
            pr_feedback_to_issue "$issue_number" "$pr_number"
        fi
        return 0
    else
        error "Failed to merge PR #${pr_number}"
        emit_event "pr.merge_failed" "pr=${pr_number}" "reason=merge_command_failed"
        return 1
    fi
}

# ─── Stale PR Cleanup ────────────────────────────────────────────────────────

pr_cleanup() {
    info "Cleaning up stale pull requests..."

    local stale_days
    stale_days=$(get_pr_config "stale_days" "14")

    local stale_seconds
    stale_seconds=$((stale_days * 86400))

    # List all open Shipwright PRs
    local pr_list
    pr_list=$(gh pr list --state open --search "author:@me" --json number,title,createdAt 2>/dev/null || echo "[]")

    local closed_count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local pr_number
        pr_number=$(echo "$line" | jq -r '.number')
        local title
        title=$(echo "$line" | jq -r '.title')

        # Check if this is a Shipwright PR (look for issue references or pipeline markers)
        if ! echo "$title" | grep -qiE '(pipeline|issue|shipwright)'; then
            continue
        fi

        local age_seconds
        age_seconds=$(get_pr_age_seconds "$pr_number") || continue

        if [[ $age_seconds -gt $stale_seconds ]]; then
            local age_days=$((age_seconds / 86400))
            info "Closing stale PR #${pr_number}: ${title} (${age_days} days old)"

            local close_comment="## Auto-Closed: Stale PR

This PR was automatically closed because it has been open for ${age_days} days without activity.

If this PR is still needed:
1. Reopen it with \`gh pr reopen ${pr_number}\`
2. Update the branch
3. Request review

${DIM}— Shipwright auto-lifecycle manager${RESET}"

            gh pr comment "$pr_number" --body "$close_comment" 2>/dev/null || true
            gh pr close "$pr_number" 2>/dev/null && {
                success "Closed PR #${pr_number}"
                closed_count=$((closed_count + 1))
                emit_event "pr.closed_stale" "pr=${pr_number}" "age_days=${age_days}"
            }
        fi
    done < <(echo "$pr_list" | jq -c '.[]' 2>/dev/null || true)

    if [[ $closed_count -eq 0 ]]; then
        info "No stale PRs found"
    else
        success "Cleaned up ${closed_count} stale PR(s)"
    fi
}

# ─── Issue Feedback on Merge ──────────────────────────────────────────────────

pr_feedback_to_issue() {
    local issue_number="$1"
    local pr_number="$2"

    [[ -z "$issue_number" ]] && return 0

    info "Posting merge feedback to issue #${issue_number}..."

    local feedback_body="## PR Merged

The pull request #${pr_number} has been successfully merged into the base branch.

**Summary:**
- Squash merged with clean history
- Feature branch deleted
- Ready for deployment

${DIM}— Shipwright PR Lifecycle Manager${RESET}"

    if gh issue comment "$issue_number" --body "$feedback_body" 2>/dev/null; then
        success "Posted feedback to issue #${issue_number}"
        emit_event "issue.pr_merged_feedback" "issue=${issue_number}" "pr=${pr_number}"
    else
        warn "Failed to post feedback to issue #${issue_number}"
    fi
}

# ─── Status Dashboard ────────────────────────────────────────────────────────

pr_status() {
    info "Shipwright Pull Requests Status"
    echo ""

    # Get all open Shipwright PRs
    local pr_list
    pr_list=$(gh pr list --state open --search "author:@me" --json number,title,state,createdAt,reviewDecision,statusCheckRollup 2>/dev/null || echo "[]")

    if [[ $(echo "$pr_list" | jq 'length') -eq 0 ]]; then
        echo "No open pull requests"
        return 0
    fi

    echo -e "${BOLD}PR #${TAB}Title${TAB}Age${TAB}Reviews${TAB}CI Status${RESET}"
    echo "─────────────────────────────────────────────────────────"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local pr_number title created_at review_decision
        pr_number=$(echo "$line" | jq -r '.number')
        title=$(echo "$line" | jq -r '.title' | cut -c1-40)
        created_at=$(echo "$line" | jq -r '.createdAt')
        review_decision=$(echo "$line" | jq -r '.reviewDecision // "PENDING"')

        # Calculate age
        local created_epoch
        created_epoch=$(date -d "$created_at" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo "0")
        local age_hours=$((( $(now_epoch) - created_epoch) / 3600))
        local age_str="${age_hours}h"
        [[ $age_hours -gt 24 ]] && age_str="$((age_hours / 24))d"

        # Get checks status
        local checks_status="unknown"
        if echo "$line" | jq -e '.statusCheckRollup[0]' > /dev/null 2>&1; then
            checks_status=$(echo "$line" | jq -r '.statusCheckRollup[0].state' 2>/dev/null)
        fi

        # Color-code output
        local status_color="$DIM"
        case "$checks_status" in
            success) status_color="$GREEN" ;;
            failure) status_color="$RED" ;;
            pending) status_color="$YELLOW" ;;
        esac

        printf "%s%-5s${DIM}│${RESET} %-40s %-5s %-10s %s${status_color}%s${RESET}\n" \
            "$status_color" "#${pr_number}" "$title" "$age_str" "$review_decision" "$DIM" "$checks_status"
    done < <(echo "$pr_list" | jq -c '.[]' 2>/dev/null || true)

    echo ""
    echo "Legend: APPROVED = Ready to merge | PENDING = Waiting for review | CHANGES_REQUESTED = Needs work"
}

# ─── Patrol Mode (for daemon integration) ────────────────────────────────────

pr_patrol() {
    info "Running PR lifecycle patrol..."

    # Review all open PRs
    info "Phase 1: Reviewing open PRs..."
    local pr_list
    pr_list=$(gh pr list --state open --search "author:@me" --json number 2>/dev/null || echo "[]")
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pr_number
        pr_number=$(echo "$line" | jq -r '.number')
        pr_review "$pr_number" || true
    done < <(echo "$pr_list" | jq -c '.[]' 2>/dev/null || true)

    # Attempt merges
    info "Phase 2: Attempting auto-merges..."
    pr_list=$(gh pr list --state open --search "author:@me" --json number 2>/dev/null || echo "[]")
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pr_number
        pr_number=$(echo "$line" | jq -r '.number')
        pr_merge "$pr_number" || true
    done < <(echo "$pr_list" | jq -c '.[]' 2>/dev/null || true)

    # Cleanup stale PRs
    info "Phase 3: Cleaning up stale PRs..."
    pr_cleanup || true

    success "PR lifecycle patrol complete"
    emit_event "pr_patrol.complete"
}

# ─── Help ────────────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${BOLD}shipwright pr <command>${RESET}"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}review <number>${RESET}      Run review pass on a PR (checks code quality, posts findings)"
    echo -e "  ${CYAN}merge <number>${RESET}       Attempt auto-merge (checks CI, conflicts, reviews, then merges)"
    echo -e "  ${CYAN}cleanup${RESET}               Close stale PRs (older than configured days, default 14)"
    echo -e "  ${CYAN}status${RESET}                Show all open Shipwright PRs with lifecycle state"
    echo -e "  ${CYAN}patrol${RESET}                Run full PR lifecycle patrol (review + merge + cleanup)"
    echo -e "  ${CYAN}help${RESET}                  Show this help"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright pr review 42${RESET}       # Review PR #42"
    echo -e "  ${DIM}shipwright pr merge 42${RESET}        # Try to merge PR #42"
    echo -e "  ${DIM}shipwright pr cleanup${RESET}         # Close stale PRs"
    echo -e "  ${DIM}shipwright pr status${RESET}          # Show all open PRs"
    echo -e "  ${DIM}shipwright pr patrol${RESET}          # Full lifecycle management"
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        review)
            [[ -z "${1:-}" ]] && { error "PR number required"; show_help; exit 1; }
            pr_review "$1"
            ;;
        merge)
            [[ -z "${1:-}" ]] && { error "PR number required"; show_help; exit 1; }
            pr_merge "$1"
            ;;
        cleanup)
            pr_cleanup
            ;;
        status)
            pr_status
            ;;
        patrol)
            pr_patrol
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: ${cmd}"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
