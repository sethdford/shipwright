#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright trace — E2E Traceability (Issue → Commit → PR → Deploy)       ║
# ║  Query and link the full chain from GitHub issue to production            ║
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
# ─── Data Paths ─────────────────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"
SHIPWRIGHT_DIR="${REPO_DIR}/.claude/pipeline-artifacts"

# ─── Helper: Extract GitHub repo owner/name ──────────────────────────────────
get_gh_repo() {
    gh repo view --json nameWithOwner -q 2>/dev/null || echo ""
}

# ─── Helper: Extract issue number from branch name ──────────────────────────
issue_from_branch() {
    local branch="$1"
    # Handle feat/...-N, fix/...-N, issue-N patterns
    if [[ "$branch" =~ -([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# ─── trace_show: Full chain for a single issue ──────────────────────────────
trace_show() {
    local issue="$1"

    if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
        error "Issue must be a number"
        return 1
    fi

    info "Tracing issue #${issue}..."
    echo ""

    # Get issue details from GitHub
    local issue_data
    if ! issue_data=$(gh issue view "$issue" --json "title,state,assignees,labels,url,createdAt,closedAt" 2>/dev/null); then
        error "Could not fetch issue #${issue}. Check permissions or issue number."
        return 1
    fi

    local title state url
    title=$(echo "$issue_data" | jq -r '.title')
    state=$(echo "$issue_data" | jq -r '.state')
    url=$(echo "$issue_data" | jq -r '.url')

    # ─── Issue Section ─────────────────────────────────────────────────────
    echo -e "${BOLD}ISSUE${RESET}"
    echo -e "  ${CYAN}#${issue}${RESET}  ${BOLD}${title}${RESET}"
    echo -e "  State: ${CYAN}${state}${RESET}  •  URL: ${BLUE}${url}${RESET}"
    echo ""

    # ─── Pipeline Section ──────────────────────────────────────────────────
    echo -e "${BOLD}PIPELINE${RESET}"

    # Find pipeline events for this issue
    if [[ ! -f "$EVENTS_FILE" ]]; then
        warn "No events log found at $EVENTS_FILE"
    else
        local pipeline_started
        pipeline_started=$(grep "\"issue\":${issue}" "$EVENTS_FILE" | head -1)

        if [[ -z "$pipeline_started" ]]; then
            echo -e "  ${DIM}No pipeline run found for this issue${RESET}"
        else
            local ts job_id stage
            ts=$(echo "$pipeline_started" | jq -r '.ts // "unknown"')
            job_id=$(echo "$pipeline_started" | jq -r '.job_id // "unknown"')
            stage=$(echo "$pipeline_started" | jq -r '.stage // "intake"')

            echo -e "  Job ID: ${CYAN}${job_id}${RESET}"
            echo -e "  Started: ${DIM}${ts}${RESET}"

            # Find max stage reached
            local max_stage
            max_stage=$(grep "\"job_id\":\"${job_id}\"" "$EVENTS_FILE" \
                | jq -r '.stage // ""' 2>/dev/null \
                | grep -v '^$' | tail -1)

            if [[ -n "$max_stage" ]]; then
                echo -e "  Last Stage: ${GREEN}${max_stage}${RESET}"
            fi
        fi
    fi
    echo ""

    # ─── Feature Branch Section ────────────────────────────────────────────
    echo -e "${BOLD}FEATURE BRANCH${RESET}"

    local feature_branch
    feature_branch="feat/issue-${issue}"

    # Check if worktree exists
    local worktree_path="${REPO_DIR}/.worktrees/issue-${issue}"
    if [[ -d "$worktree_path" ]]; then
        echo -e "  Worktree: ${GREEN}${worktree_path}${RESET}"

        # Get commits from worktree
        cd "$worktree_path" 2>/dev/null || true
        local commit_count
        commit_count=$(git rev-list --count main..HEAD 2>/dev/null || echo "0")
        echo -e "  Commits: ${CYAN}${commit_count}${RESET}"

        # Show recent commits
        if [[ "$commit_count" -gt 0 ]]; then
            echo -e "  ${DIM}Recent commits:${RESET}"
            git log --oneline -5 main..HEAD 2>/dev/null | while read -r sha msg; do
                echo -e "    ${CYAN}${sha:0:7}${RESET} ${DIM}${msg}${RESET}"
            done
        fi
        cd - >/dev/null 2>&1 || true
    else
        # Try to find any branch matching the issue
        local branches
        branches=$(git branch -r --list "*issue-${issue}*" 2>/dev/null || echo "")
        if [[ -z "$branches" ]]; then
            echo -e "  ${DIM}No branch found${RESET}"
        else
            echo "$branches" | while read -r branch; do
                branch=$(echo "$branch" | xargs)
                echo -e "  ${CYAN}${branch}${RESET}"
            done
        fi
    fi
    echo ""

    # ─── Pull Request Section ──────────────────────────────────────────────
    echo -e "${BOLD}PULL REQUEST${RESET}"

    # Search for PR linked to this issue
    local pr_data
    pr_data=$(gh pr list --state all --search "issue:${issue}" --json "number,title,state,mergedAt,url" -L 1 2>/dev/null || echo "")

    if [[ -z "$pr_data" ]] || [[ "$pr_data" == "[]" ]]; then
        # Fallback: look for PR with matching branch
        pr_data=$(gh pr list --state all --search "head:feat/issue-${issue}" --json "number,title,state,mergedAt,url" -L 1 2>/dev/null || echo "")
    fi

    if [[ -z "$pr_data" ]] || [[ "$pr_data" == "[]" ]]; then
        echo -e "  ${DIM}No PR found${RESET}"
    else
        local pr_num pr_title pr_state merged_at pr_url
        pr_num=$(echo "$pr_data" | jq -r '.[0].number // "unknown"')
        pr_title=$(echo "$pr_data" | jq -r '.[0].title // "unknown"')
        pr_state=$(echo "$pr_data" | jq -r '.[0].state // "unknown"')
        merged_at=$(echo "$pr_data" | jq -r '.[0].mergedAt // ""')
        pr_url=$(echo "$pr_data" | jq -r '.[0].url // ""')

        echo -e "  ${CYAN}#${pr_num}${RESET}  ${pr_title}"
        echo -e "  State: ${CYAN}${pr_state}${RESET}  •  URL: ${BLUE}${pr_url}${RESET}"

        if [[ -n "$merged_at" && "$merged_at" != "null" ]]; then
            echo -e "  Merged: ${GREEN}${merged_at}${RESET}"
        fi
    fi
    echo ""

    # ─── Deployment Section ────────────────────────────────────────────────
    echo -e "${BOLD}DEPLOYMENT${RESET}"

    # Check if deployment tracking exists
    if [[ -f "${SHIPWRIGHT_DIR}/deployment.json" ]]; then
        local deploy_env deploy_status
        deploy_env=$(jq -r '.environment // "unknown"' "${SHIPWRIGHT_DIR}/deployment.json" 2>/dev/null || echo "")
        deploy_status=$(jq -r '.status // "unknown"' "${SHIPWRIGHT_DIR}/deployment.json" 2>/dev/null || echo "")

        if [[ -n "$deploy_env" ]] && [[ "$deploy_env" != "null" ]]; then
            echo -e "  Environment: ${CYAN}${deploy_env}${RESET}"
            echo -e "  Status: ${GREEN}${deploy_status}${RESET}"
        else
            echo -e "  ${DIM}No deployment tracked${RESET}"
        fi
    else
        echo -e "  ${DIM}No deployment tracked${RESET}"
    fi
    echo ""
}

# ─── trace_list: Recent pipeline activity ──────────────────────────────────
trace_list() {
    local limit="${1:-10}"

    if [[ ! -f "$EVENTS_FILE" ]]; then
        warn "No events log found"
        return 1
    fi

    info "Recent pipeline runs (last ${limit})..."
    echo ""

    # Extract unique job_ids with their issues
    local jobs
    jobs=$(grep '"job_id"' "$EVENTS_FILE" | jq -r '.job_id' | sort -u | tail -n "$limit")

    if [[ -z "$jobs" ]]; then
        echo "  ${DIM}No pipeline runs found${RESET}"
        return 0
    fi

    local count=0
    echo -e "${BOLD}JOB_ID                          ISSUE  STAGE           STATUS      DURATION${RESET}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────────${RESET}"

    while read -r job_id; do
        ((count++ <= limit)) || break

        # Get first and last event for this job
        local first_event last_event issue stage status duration_s
        first_event=$(grep "\"job_id\":\"${job_id}\"" "$EVENTS_FILE" | head -1)
        last_event=$(grep "\"job_id\":\"${job_id}\"" "$EVENTS_FILE" | tail -1)

        issue=$(echo "$first_event" | jq -r '.issue // ""')
        stage=$(echo "$last_event" | jq -r '.stage // "?"')
        status=$(echo "$last_event" | jq -r '.status // "?"')
        duration_s=$(echo "$last_event" | jq -r '.duration_secs // 0')

        # Format duration
        local duration_fmt
        if [[ "$duration_s" -gt 3600 ]]; then
            duration_fmt="$(( duration_s / 3600 ))h $(( (duration_s % 3600) / 60 ))m"
        elif [[ "$duration_s" -gt 60 ]]; then
            duration_fmt="$(( duration_s / 60 ))m"
        else
            duration_fmt="${duration_s}s"
        fi

        # Color status
        local status_color
        case "$status" in
            completed|success) status_color="${GREEN}${status}${RESET}" ;;
            failed|error) status_color="${RED}${status}${RESET}" ;;
            running|in_progress) status_color="${CYAN}${status}${RESET}" ;;
            *) status_color="$status" ;;
        esac

        printf "%-32s  #%-4s  %-15s  %-12s  %s\n" \
            "${job_id:0:30}" \
            "${issue:-?}" \
            "$stage" \
            "$status_color" \
            "$duration_fmt"
    done <<< "$jobs"

    echo ""
}

# ─── trace_search: Find issue/pipeline by commit ─────────────────────────────
trace_search() {
    local commit_sha="$1"

    if [[ ! "$commit_sha" =~ ^[a-f0-9]{6,40}$ ]]; then
        error "Commit SHA must be 6-40 hex characters"
        return 1
    fi

    info "Searching for commit ${CYAN}${commit_sha:0:8}${RESET}..."
    echo ""

    # Find which branch contains this commit
    local branch
    branch=$(git branch -r --contains "$commit_sha" 2>/dev/null | head -1 | xargs || echo "")

    if [[ -z "$branch" ]]; then
        warn "Commit not found in any tracked branch"
        return 1
    fi

    # Try to extract issue number from branch name
    local issue
    issue=$(issue_from_branch "$branch")

    echo -e "${BOLD}COMMIT${RESET}"
    echo -e "  SHA: ${CYAN}${commit_sha:0:8}${RESET}"
    echo -e "  Branch: ${CYAN}${branch}${RESET}"
    echo ""

    if [[ -n "$issue" ]]; then
        echo -e "${BOLD}LINKED ISSUE${RESET}"
        echo -e "  Issue: ${CYAN}#${issue}${RESET}"
        echo ""

        # Show full trace for this issue
        trace_show "$issue" || true
    else
        warn "Could not extract issue number from branch name"
        echo "  Branch: ${CYAN}${branch}${RESET}"
        echo ""
    fi
}

# ─── trace_export: Generate markdown report ──────────────────────────────────
trace_export() {
    local issue="$1"
    local output_file="${2:-trace-issue-${issue}.md}"

    if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
        error "Issue must be a number"
        return 1
    fi

    info "Exporting trace for issue #${issue} to ${CYAN}${output_file}${RESET}..."

    # Get issue details
    local issue_data title state url created_at
    if ! issue_data=$(gh issue view "$issue" --json "title,state,url,createdAt,closedAt" 2>/dev/null); then
        error "Could not fetch issue #${issue}"
        return 1
    fi

    title=$(echo "$issue_data" | jq -r '.title')
    state=$(echo "$issue_data" | jq -r '.state')
    url=$(echo "$issue_data" | jq -r '.url')
    created_at=$(echo "$issue_data" | jq -r '.createdAt')

    # Build markdown report
    local report=""
    report+="# Traceability Report: Issue #${issue}\n\n"
    report+="## Issue\n\n"
    report+="- **Title**: ${title}\n"
    report+="- **State**: ${state}\n"
    report+="- **URL**: [${url}](${url})\n"
    report+="- **Created**: ${created_at}\n"
    report+="- **Report Generated**: $(now_iso)\n\n"

    # Pipeline section
    report+="## Pipeline\n\n"
    if [[ -f "$EVENTS_FILE" ]]; then
        local job_data job_id ts stage max_stage
        job_data=$(grep "\"issue\":${issue}" "$EVENTS_FILE" 2>/dev/null | head -1)

        if [[ -n "$job_data" ]]; then
            job_id=$(echo "$job_data" | jq -r '.job_id // "unknown"')
            ts=$(echo "$job_data" | jq -r '.ts // "unknown"')
            stage=$(echo "$job_data" | jq -r '.stage // "unknown"')

            report+="- **Job ID**: \`${job_id}\`\n"
            report+="- **Started**: ${ts}\n"

            # Find final stage
            max_stage=$(grep "\"job_id\":\"${job_id}\"" "$EVENTS_FILE" 2>/dev/null \
                | jq -r '.stage // ""' | tail -1)
            report+="- **Final Stage**: ${max_stage}\n\n"
        else
            report+="No pipeline run found.\n\n"
        fi
    else
        report+="No events log available.\n\n"
    fi

    # Commits section
    report+="## Commits\n\n"
    local commit_count
    commit_count=$(git rev-list --count main..feat/issue-"${issue}" 2>/dev/null || echo "0")

    if [[ "$commit_count" -gt 0 ]]; then
        report+="Found ${commit_count} commits on feature branch:\n\n"
        report+="\`\`\`\n"
        report+=$(git log --oneline main..feat/issue-"${issue}" 2>/dev/null || echo "(no commits)")
        report+="\n\`\`\`\n\n"
    else
        report+="No commits on feature branch.\n\n"
    fi

    # PR section
    report+="## Pull Request\n\n"
    local pr_data
    pr_data=$(gh pr list --state all --search "issue:${issue}" --json "number,title,state,url" -L 1 2>/dev/null || echo "")

    if [[ -n "$pr_data" ]] && [[ "$pr_data" != "[]" ]]; then
        local pr_num pr_title pr_state pr_url
        pr_num=$(echo "$pr_data" | jq -r '.[0].number // "unknown"')
        pr_title=$(echo "$pr_data" | jq -r '.[0].title // "unknown"')
        pr_state=$(echo "$pr_data" | jq -r '.[0].state // "unknown"')
        pr_url=$(echo "$pr_data" | jq -r '.[0].url // "unknown"')

        report+="- **Number**: [#${pr_num}](${pr_url})\n"
        report+="- **Title**: ${pr_title}\n"
        report+="- **State**: ${pr_state}\n"
    else
        report+="No PR found.\n"
    fi
    report+="\n"

    # Write report
    echo -e "$report" > "$output_file"
    success "Exported to ${CYAN}${output_file}${RESET}"
    echo ""
}

# ─── Show help ──────────────────────────────────────────────────────────────
show_help() {
    echo -e "${BOLD}shipwright trace${RESET} — E2E Traceability (Issue → Commit → PR → Deploy)"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright trace${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}show <issue>${RESET}          Show full traceability chain for an issue"
    echo -e "  ${CYAN}list [limit]${RESET}          Show recent pipeline runs (default: 10)"
    echo -e "  ${CYAN}search --commit <sha>${RESET} Find issue/pipeline for a commit"
    echo -e "  ${CYAN}export <issue> [file]${RESET} Export traceability as markdown"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright trace show 42${RESET}"
    echo -e "  ${DIM}shipwright trace list 20${RESET}"
    echo -e "  ${DIM}shipwright trace search --commit abc1234${RESET}"
    echo -e "  ${DIM}shipwright trace export 42 trace-issue-42.md${RESET}"
    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        show)
            if [[ -z "${1:-}" ]]; then
                error "Issue number required"
                return 1
            fi
            trace_show "$1"
            ;;
        list)
            trace_list "${1:-10}"
            ;;
        search)
            if [[ "${1:-}" != "--commit" ]] || [[ -z "${2:-}" ]]; then
                error "Usage: shipwright trace search --commit <sha>"
                return 1
            fi
            trace_search "$2"
            ;;
        export)
            if [[ -z "${1:-}" ]]; then
                error "Issue number required"
                return 1
            fi
            trace_export "$1" "${2:-}"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: ${cmd}"
            show_help
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
