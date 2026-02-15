#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright feedback — Production Feedback Loop                          ║
# ║  Error collection · Auto-issue creation · Rollback trigger · Learning   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.0.0"
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

# ─── Structured Event Log ────────────────────────────────────────────────────
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

# ─── Storage Paths ──────────────────────────────────────────────────────────
INCIDENTS_FILE="${HOME}/.shipwright/incidents.jsonl"
ERROR_THRESHOLD=5          # Create issue if error count >= threshold
ERROR_LOG_DIR="${REPO_DIR}/.claude/pipeline-artifacts"
ARTIFACTS_DIR="${REPO_DIR}/.claude/pipeline-artifacts"

# ─── Initialize directories ────────────────────────────────────────────────
ensure_dirs() {
    mkdir -p "${HOME}/.shipwright"
    mkdir -p "$ARTIFACTS_DIR"
}

# ─── Detect owner/repo from git remote ─────────────────────────────────────
get_owner_repo() {
    local remote_url
    remote_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
    if [[ -z "$remote_url" ]]; then
        return 1
    fi
    echo "$remote_url" | sed -E 's#^(https?://github\.com/|git@github\.com:)##; s#\.git$##'
}

# ─── Parse log files for error patterns ──────────────────────────────────────
parse_error_patterns() {
    local log_file="$1"
    local error_count=0
    local error_types=""
    local stack_traces=""

    if [[ ! -f "$log_file" ]]; then
        return 1
    fi

    # Count errors and extract stack traces
    while IFS= read -r line; do
        if [[ "$line" =~ (Error|Exception|panic|fatal).*: ]]; then
            error_count=$((error_count + 1))
            # Extract error message
            local err_msg=$(echo "$line" | sed -E 's/^.*\[.*\] //; s/:.*//')
            error_types="${error_types}${err_msg};"
        fi
    done < "$log_file"

    # Output CSV: count|types|first_stack_trace
    local first_stack=$(head -50 "$log_file" | tail -20)
    echo "$error_count|$error_types|$first_stack"
}

# ─── Find commit that likely introduced regression ───────────────────────────
find_regression_commit() {
    local error_pattern="$1"
    local max_commits="${2:-20}"

    # Search recent commits for changes that might have introduced the error
    # Pattern: look for commits touching error-related code
    local commit_hash
    commit_hash=$(cd "$REPO_DIR" && git log --all -n "$max_commits" --pretty=format:"%H %s" | \
        while read -r hash subject; do
            # Simple heuristic: commits that touched multiple files or had large diffs
            local files_changed
            files_changed=$(cd "$REPO_DIR" && git show "$hash" --stat | tail -1 | grep -oE '[0-9]+ files? changed' | head -1)
            if [[ -n "$files_changed" ]]; then
                echo "$hash"
                break
            fi
        done)

    echo "${commit_hash:0:7}"
}

# ─── Collect errors from monitor stage output ────────────────────────────────
cmd_collect() {
    local log_path="${1:-.}"

    info "Collecting error patterns from: $log_path"
    ensure_dirs

    local error_file="${ARTIFACTS_DIR}/errors-collected.json"
    local total_errors=0
    local error_summary=""

    if [[ -f "$log_path" ]]; then
        # Single file
        local result
        result=$(parse_error_patterns "$log_path")
        IFS='|' read -r count types traces <<< "$result"
        total_errors=$((total_errors + count))
        error_summary="${types}"
    elif [[ -d "$log_path" ]]; then
        # Directory of logs
        while IFS= read -r file; do
            local result
            result=$(parse_error_patterns "$file") || continue
            IFS='|' read -r count types traces <<< "$result"
            total_errors=$((total_errors + count))
            error_summary="${error_summary}${types};"
        done < <(find "$log_path" -name "*.log" -type f 2>/dev/null)
    fi

    # Save to artifacts
    local error_json
    error_json=$(jq -n \
        --arg ts "$(now_iso)" \
        --arg summary "$error_summary" \
        --arg count "$total_errors" \
        '{timestamp: $ts, total_errors: ($count | tonumber), error_types: $summary}')

    echo "$error_json" > "$error_file"
    success "Collected $total_errors errors"
    info "Saved to: $error_file"

    emit_event "feedback_collect" "errors=$total_errors" "file=$error_file"
}

# ─── Analyze collected errors ────────────────────────────────────────────────
cmd_analyze() {
    local error_file="${1:-${ARTIFACTS_DIR}/errors-collected.json}"

    if [[ ! -f "$error_file" ]]; then
        error "Error file not found: $error_file"
        return 1
    fi

    info "Analyzing error patterns..."

    local error_count
    error_count=$(jq -r '.total_errors // 0' "$error_file")
    local error_types
    error_types=$(jq -r '.error_types // ""' "$error_file")

    echo ""
    info "Error Analysis Report"
    echo "  ${DIM}Total Errors: ${RESET}${error_count}"
    echo "  ${DIM}Error Types: ${RESET}$(echo "$error_types" | tr ';' '\n' | sort | uniq -c | head -5)"

    if [[ "$error_count" -ge "$ERROR_THRESHOLD" ]]; then
        warn "Error threshold exceeded! ($error_count >= $ERROR_THRESHOLD)"
        echo "    Recommended: Create hotfix issue"
        return 0
    fi

    success "Error count within threshold"
}

# ─── Create GitHub issue for regression ──────────────────────────────────────
cmd_create_issue() {
    local error_file="${1:-${ARTIFACTS_DIR}/errors-collected.json}"

    if [[ ! -f "$error_file" ]]; then
        error "Error file not found: $error_file"
        return 1
    fi

    ensure_dirs

    local error_count
    error_count=$(jq -r '.total_errors // 0' "$error_file")

    if [[ "$error_count" -lt "$ERROR_THRESHOLD" ]]; then
        warn "Error count ($error_count) below threshold ($ERROR_THRESHOLD) — skipping issue creation"
        return 0
    fi

    info "Creating GitHub issue for regression..."

    # Check if NO_GITHUB is set before attempting GitHub operations
    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        warn "NO_GITHUB set — skipping GitHub issue creation"
        return 0
    fi

    # Get repo info
    local owner_repo
    owner_repo=$(get_owner_repo) || {
        error "Could not detect GitHub repo"
        return 1
    }

    local error_types
    error_types=$(jq -r '.error_types // ""' "$error_file")

    # Find likely regression commit
    local regression_commit
    regression_commit=$(find_regression_commit "$error_types")

    # Build issue body
    local issue_body
    issue_body=$(cat <<EOF
## Production Regression Detected

**Total Errors**: $error_count
**Threshold**: $ERROR_THRESHOLD
**Timestamp**: $(now_iso)

### Error Types
\`\`\`
$(echo "$error_types" | tr ';' '\n' | sort | uniq -c | head -10)
\`\`\`

### Likely Regression Commit
\`$regression_commit\`

\`\`\`bash
git show $regression_commit
\`\`\`

### Suggested Fix
1. Review the commit above for problematic changes
2. Run tests: \`npm test\`
3. Check error logs: \`./.claude/pipeline-artifacts/errors-collected.json\`
4. Deploy hotfix with: \`shipwright pipeline start --issue <N> --template hotfix\`

---
**Auto-created by**: Shipwright Production Feedback Loop
**Component**: $0
EOF
    )

    if ! command -v gh &>/dev/null; then
        error "gh CLI not found — cannot create issue"
        return 1
    fi

    # Create issue via gh
    local issue_url
    issue_url=$(gh issue create \
        --repo "$owner_repo" \
        --title "Production Regression: $error_count errors detected" \
        --body "$issue_body" \
        --label "shipwright" \
        --label "hotfix" \
        2>&1 | tail -1)

    if [[ -n "$issue_url" ]]; then
        success "Created issue: $issue_url"
        emit_event "feedback_issue_created" "url=$issue_url" "errors=$error_count"
        echo "$issue_url" > "${ARTIFACTS_DIR}/last-issue.txt"
    else
        warn "Could not create issue (check gh auth)"
    fi
}

# ─── Trigger rollback via GitHub Deployments API ─────────────────────────────
cmd_rollback() {
    local environment="${1:-production}"
    local reason="${2:-Rollback due to production errors}"

    info "Triggering rollback for environment: $environment"

    # Check for sw-github-deploy.sh
    if [[ ! -f "$SCRIPT_DIR/sw-github-deploy.sh" ]]; then
        error "sw-github-deploy.sh not found"
        return 1
    fi

    ensure_dirs

    # Get current deployment
    local owner_repo
    owner_repo=$(get_owner_repo) || {
        error "Could not detect GitHub repo"
        return 1
    }

    # For now, just log the rollback intent
    # Full implementation would call sw-github-deploy.sh and update deployment status
    local rollback_entry
    rollback_entry=$(jq -n \
        --arg ts "$(now_iso)" \
        --arg env "$environment" \
        --arg reason "$reason" \
        '{timestamp: $ts, environment: $env, reason: $reason, status: "initiated"}')

    echo "$rollback_entry" >> "${ARTIFACTS_DIR}/rollbacks.jsonl"

    success "Rollback initiated for $environment"
    emit_event "feedback_rollback" "environment=$environment" "reason=$reason"
    info "Note: Full rollback requires manual GitHub Deployments API call"
}

# ─── Capture incident in memory system ───────────────────────────────────────
cmd_learn() {
    local root_cause="${1:-Unknown}"
    local fix_applied="${2:-}"

    info "Capturing incident learning..."
    ensure_dirs

    local incident_entry
    incident_entry=$(jq -c -n \
        --arg ts "$(now_iso)" \
        --arg cause "$root_cause" \
        --arg fix "$fix_applied" \
        --arg repo "$(basename "$REPO_DIR")" \
        '{
            timestamp: $ts,
            repository: $repo,
            root_cause: $cause,
            fix_applied: $fix,
            resolution_time: 0,
            tags: ["production", "feedback-loop"]
        }')

    echo "$incident_entry" >> "$INCIDENTS_FILE"
    success "Incident captured in $INCIDENTS_FILE"
    emit_event "feedback_incident_learned" "cause=$root_cause"
}

# ─── Report on recent incidents ──────────────────────────────────────────────
cmd_report() {
    local days="${1:-7}"

    if [[ ! -f "$INCIDENTS_FILE" ]]; then
        warn "No incidents recorded yet"
        return 0
    fi

    info "Incident Report (last $days days)"
    echo ""

    local incident_count=0

    while IFS= read -r line; do
        incident_count=$((incident_count + 1))

        local ts
        ts=$(echo "$line" | jq -r '.timestamp // "Unknown"')
        local cause
        cause=$(echo "$line" | jq -r '.root_cause // "Unknown"')
        local fixed
        fixed=$(echo "$line" | jq -r '.fix_applied // "Pending"')

        echo "  ${CYAN}Incident $incident_count${RESET} ${DIM}($ts)${RESET}"
        echo "    ${DIM}Cause: ${RESET}$cause"
        echo "    ${DIM}Fix: ${RESET}$fixed"
    done < "$INCIDENTS_FILE"

    echo ""
    success "Total incidents: $incident_count"
}

# ─── Show help ───────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
${BOLD}shipwright feedback${RESET} — Production Feedback Loop

${BOLD}USAGE${RESET}
  shipwright feedback <subcommand> [options]

${BOLD}SUBCOMMANDS${RESET}
  ${CYAN}collect${RESET} [path]              Collect error patterns from logs
  ${CYAN}analyze${RESET} [error-file]        Analyze collected errors
  ${CYAN}create-issue${RESET} [error-file]   Create GitHub issue for regression
  ${CYAN}rollback${RESET} [env] [reason]     Trigger rollback via Deployments API
  ${CYAN}learn${RESET} [cause] [fix]         Capture incident in memory system
  ${CYAN}report${RESET} [days]               Show recent incidents (default: 7 days)
  ${CYAN}help${RESET}                        Show this help message

${BOLD}EXAMPLES${RESET}
  ${DIM}shipwright feedback collect ./logs${RESET}
  ${DIM}shipwright feedback analyze${RESET}
  ${DIM}shipwright feedback create-issue${RESET}
  ${DIM}shipwright feedback rollback production "Hotfix v1.2.3 regression"${RESET}
  ${DIM}shipwright feedback learn "Off-by-one error in pagination" "Fixed in PR #456"${RESET}
  ${DIM}shipwright feedback report 30${RESET}

${BOLD}STORAGE${RESET}
  Incidents: $INCIDENTS_FILE
  Errors:    ${ARTIFACTS_DIR}/errors-collected.json
  Rollbacks: ${ARTIFACTS_DIR}/rollbacks.jsonl

${BOLD}VERSION${RESET}
  $VERSION
EOF
}

# ─── Main entry point ────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        collect)
            cmd_collect "$@"
            ;;
        analyze)
            cmd_analyze "$@"
            ;;
        create-issue)
            cmd_create_issue "$@"
            ;;
        rollback)
            cmd_rollback "$@"
            ;;
        learn)
            cmd_learn "$@"
            ;;
        report)
            cmd_report "$@"
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            error "Unknown subcommand: $cmd"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
