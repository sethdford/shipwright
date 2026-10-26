#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright feedback — Production Feedback Loop                          ║
# ║  Error collection · Auto-issue creation · Rollback trigger · Learning   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="4.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Issue intake caps for automated filings (ADR-0007); path is relative to this file
# shellcheck source=lib/safety-gates.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/safety-gates.sh"
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
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
# ─── Storage Paths ──────────────────────────────────────────────────────────
INCIDENTS_FILE="${HOME}/.shipwright/incidents.jsonl"
MERGE_OUTCOMES_FILE="${HOME}/.shipwright/optimization/merge-outcomes.jsonl"
ERROR_THRESHOLD=5          # Create issue if error count >= threshold
# shellcheck disable=SC2034
ERROR_LOG_DIR="${REPO_DIR}/.claude/pipeline-artifacts"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${REPO_DIR}/.claude/pipeline-artifacts}"
POST_MERGE_MONITORING_FILE="${ARTIFACTS_DIR}/post-merge-monitoring.json"

# ─── Initialize directories ────────────────────────────────────────────────
ensure_dirs() {
    mkdir -p "${HOME}/.shipwright"
    mkdir -p "${HOME}/.shipwright/optimization"
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
    # shellcheck disable=SC2034
    local stack_traces=""

    if [[ ! -f "$log_file" ]]; then
        return 1
    fi

    # Count errors and extract stack traces
    while IFS= read -r line; do
        if [[ "$line" =~ (Error|Exception|panic|fatal).*: ]]; then
            error_count=$((error_count + 1))
            # Extract error message
            local err_msg
            err_msg=$(echo "$line" | sed -E 's/^.*\[.*\] //; s/:.*//')
            error_types="${error_types}${err_msg};"
        fi
    done < "$log_file"

    # Output CSV: count|types|first_stack_trace
    local first_stack
    first_stack=$(head -50 "$log_file" | tail -20)
    echo "$error_count|$error_types|$first_stack"
}

# ─── Find commit that likely introduced regression ───────────────────────────
find_regression_commit() {
    # shellcheck disable=SC2034
    local error_pattern="$1"
    local max_commits="${2:-20}"

    # Search recent commits for changes that might have introduced the error
    # Pattern: look for commits touching error-related code
    local commit_hash
    # shellcheck disable=SC2034
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

# ═══════════════════════════════════════════════════════════════════════════════
# POST-MERGE FEEDBACK FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Monitor production after merge ─────────────────────────────────────────────
feedback_post_merge_monitor() {
    local merge_sha="${1:-}"
    local environment="${2:-production}"
    local monitoring_window="${3:-1800}"  # 30 minutes default
    local poll_interval="${4:-60}"        # 60 seconds
    local owner_repo="${5:-}"

    if [[ -z "$merge_sha" ]]; then
        error "Usage: feedback_post_merge_monitor <merge_sha> [environment] [window_secs] [poll_interval]"
        return 1
    fi

    info "Starting post-merge production monitoring for: $merge_sha"
    info "Environment: $environment | Window: $((monitoring_window / 60))m | Poll: ${poll_interval}s"

    ensure_dirs

    # Initialize monitoring data
    local monitoring_data
    local start_epoch
    start_epoch=$(now_epoch)
    monitoring_data=$(jq -n \
        --arg ts "$(now_iso)" \
        --arg merge_sha "$merge_sha" \
        --arg env "$environment" \
        --arg window "$monitoring_window" \
        --arg start_ep "$start_epoch" \
        '{
            timestamp: $ts,
            merge_sha: $merge_sha,
            environment: $env,
            monitoring_window_secs: ($window | tonumber),
            start_epoch: ($start_ep | tonumber),
            checks: [],
            errors_detected: 0,
            deployment_status: null,
            monitoring_complete: false
        }')

    local start_time
    start_time=$(now_epoch)
    local elapsed=0
    local iteration=0

    # Poll for monitoring window duration
    while [[ "$elapsed" -lt "$monitoring_window" ]]; do
        iteration=$((iteration + 1))
        local current_check

        # Check GitHub deployment status (if NO_GITHUB not set)
        local deploy_status="unknown"
        local deploy_errors=0
        if [[ "${NO_GITHUB:-}" != "true" && "${NO_GITHUB:-}" != "1" ]]; then
            if [[ -z "$owner_repo" ]]; then
                owner_repo=$(get_owner_repo) || true
            fi
            if [[ -n "$owner_repo" ]]; then
                deploy_status=$(gh api "repos/${owner_repo}/deployments" \
                    --jq '.[] | select(.ref == "'$merge_sha'") | .statuses[0].state // "unknown"' \
                    2>/dev/null || echo "unknown")
            fi
        fi

        # Simulate or check for error spikes (look at error log if available)
        if [[ -f "${ARTIFACTS_DIR}/error-log.jsonl" ]]; then
            deploy_errors=$(wc -l < "${ARTIFACTS_DIR}/error-log.jsonl" 2>/dev/null || echo "0")
        fi

        current_check=$(jq -n \
            --arg ts "$(now_iso)" \
            --argjson iter "$iteration" \
            --arg deploy_st "$deploy_status" \
            --argjson err_count "$deploy_errors" \
            '{
                timestamp: $ts,
                iteration: $iter,
                deployment_status: $deploy_st,
                error_count: $err_count
            }')

        monitoring_data=$(echo "$monitoring_data" | jq \
            --argjson check "$current_check" \
            --argjson err_count "$deploy_errors" \
            '.checks += [$check] | .errors_detected += ($err_count | tonumber)')

        # Check for immediate failure
        if [[ "$deploy_status" == "failure" || "$deploy_status" == "error" ]]; then
            warn "Deployment failed detected at iteration $iteration!"
            monitoring_data=$(echo "$monitoring_data" | jq '.deployment_status = "failed"')
            break
        fi

        elapsed=$(($(now_epoch) - start_time))
        if [[ "$elapsed" -lt "$monitoring_window" ]]; then
            sleep "$poll_interval"
        fi
    done

    # Mark monitoring complete
    local end_epoch
    end_epoch=$(now_epoch)
    monitoring_data=$(echo "$monitoring_data" | jq \
        --arg ts "$(now_iso)" \
        --arg end_ep "$end_epoch" \
        '.monitoring_complete = true | .end_timestamp = $ts | .end_epoch = ($end_ep | tonumber)')

    # Write monitoring data atomically
    local tmp_file
    tmp_file=$(mktemp)
    echo "$monitoring_data" > "$tmp_file"
    mv "$tmp_file" "$POST_MERGE_MONITORING_FILE"

    success "Post-merge monitoring complete: $POST_MERGE_MONITORING_FILE"
    emit_event "feedback_post_merge_monitor" "merge_sha=$merge_sha" "environment=$environment" "errors=$( echo "$monitoring_data" | jq -r '.errors_detected')"
}

# ─── Detect regressions from monitoring data ────────────────────────────────────
feedback_detect_regression() {
    local monitoring_file="${1:-$POST_MERGE_MONITORING_FILE}"

    if [[ ! -f "$monitoring_file" ]]; then
        error "Monitoring file not found: $monitoring_file"
        return 1
    fi

    local merge_sha
    merge_sha=$(jq -r '.merge_sha' "$monitoring_file")
    local errors_detected
    errors_detected=$(jq -r '.errors_detected // 0' "$monitoring_file")
    local deploy_status
    deploy_status=$(jq -r '.deployment_status // "unknown"' "$monitoring_file")
    local error_count_threshold=5

    local regression="false"
    local regression_type="none"
    local severity="P3"
    local evidence=""

    # P0: Deployment failed
    if [[ "$deploy_status" == "failed" ]]; then
        regression="true"
        regression_type="deploy_failure"
        severity="P0"
        evidence="Deployment failed after merge"
    # P1: Error spike
    elif [[ "$errors_detected" -ge "$error_count_threshold" ]]; then
        regression="true"
        regression_type="error_spike"
        severity="P1"
        evidence="Error count: $errors_detected (threshold: $error_count_threshold)"
    # P2: Minor errors (below threshold but present)
    elif [[ "$errors_detected" -gt 0 ]]; then
        regression="true"
        regression_type="minor_errors"
        severity="P2"
        evidence="Error count: $errors_detected"
    fi

    local regression_result
    regression_result=$(jq -n \
        --arg ts "$(now_iso)" \
        --arg sha "$merge_sha" \
        --arg regr "$regression" \
        --arg type "$regression_type" \
        --arg sev "$severity" \
        --arg evid "$evidence" \
        '{
            timestamp: $ts,
            merge_sha: $sha,
            regression: ($regr == "true"),
            type: $type,
            severity: $sev,
            evidence: $evid
        }')

    echo "$regression_result"
    emit_event "feedback_detect_regression" "merge_sha=$merge_sha" "regression=$regression" "severity=$severity"
}

# ─── Correlate regressions with changed files ───────────────────────────────────
feedback_correlate_with_changes() {
    local pr_number="${1:-}"
    local regression_json="${2:-}"

    if [[ -z "$pr_number" ]]; then
        error "Usage: feedback_correlate_with_changes <pr_number> [regression_json]"
        return 1
    fi

    # Get PR's changed files from git log (if available)
    local changed_files=""
    local culprit_files=""
    local confidence=0

    # Try to get files from recent commits
    if [[ "${NO_GITHUB:-}" != "true" && "${NO_GITHUB:-}" != "1" ]]; then
        changed_files=$(git log --oneline --all -n 50 --pretty=format:%B 2>/dev/null | \
            grep -i "pr #$pr_number\|merge.*$pr_number" | head -1 || echo "")
    fi

    # If no GitHub data, fall back to git history
    if [[ -z "$changed_files" ]]; then
        changed_files=$(cd "$REPO_DIR" && git diff HEAD~1..HEAD --name-only 2>/dev/null | head -10 || echo "")
    fi

    # Score likelihood of files being culprits (common patterns)
    if [[ -n "$changed_files" ]]; then
        # Files commonly correlated with regressions
        while IFS= read -r file; do
            if [[ "$file" =~ (auth|login|session|permission|access) ]]; then
                culprit_files="${culprit_files}${file}:auth "
                confidence=$((confidence + 25))
            elif [[ "$file" =~ (api|endpoint|route|handler|request) ]]; then
                culprit_files="${culprit_files}${file}:api "
                confidence=$((confidence + 20))
            elif [[ "$file" =~ (database|migration|schema|sql) ]]; then
                culprit_files="${culprit_files}${file}:db "
                confidence=$((confidence + 20))
            elif [[ "$file" =~ (util|helper|core|lib) ]]; then
                culprit_files="${culprit_files}${file}:shared "
                confidence=$((confidence + 15))
            fi
        done <<< "$changed_files"
    fi

    # Cap confidence at 100
    if [[ "$confidence" -gt 100 ]]; then
        confidence=100
    fi

    local correlation_result
    correlation_result=$(jq -n \
        --arg pr "$pr_number" \
        --arg files "$changed_files" \
        --arg culprits "$culprit_files" \
        --arg conf "$confidence" \
        '{
            pr_number: $pr,
            changed_files: $files,
            culprit_files: $culprits,
            confidence_percent: ($conf | tonumber)
        }')

    echo "$correlation_result"
    emit_event "feedback_correlate" "pr=$pr_number" "confidence=$confidence"
}

# ─── Auto-respond to regressions based on severity ──────────────────────────────
feedback_auto_respond() {
    local regression_json="${1:-}"
    local pr_number="${2:-}"

    if [[ -z "$regression_json" ]]; then
        error "Usage: feedback_auto_respond <regression_json> [pr_number]"
        return 1
    fi

    local severity
    severity=$(echo "$regression_json" | jq -r '.severity // "P3"')
    local regression_type
    regression_type=$(echo "$regression_json" | jq -r '.type // "unknown"')
    local evidence
    evidence=$(echo "$regression_json" | jq -r '.evidence // ""')

    info "Auto-responding to regression: $severity / $regression_type"

    ensure_dirs

    case "$severity" in
        P0)
            # Deploy failed: trigger rollback + create incident
            info "P0 SEVERITY: Deployment failed — triggering rollback"
            cmd_rollback "production" "Post-merge regression detected: $regression_type"

            # Create incident issue if GitHub available
            if [[ "${NO_GITHUB:-}" != "true" && "${NO_GITHUB:-}" != "1" ]]; then
                local owner_repo
                owner_repo=$(get_owner_repo) || true
                if [[ -n "$owner_repo" && -n "$pr_number" ]]; then
                    if command -v gh >/dev/null 2>&1; then
                        gh issue create \
                            --repo "$owner_repo" \
                            --title "CRITICAL: Post-Merge Deployment Failed - PR #$pr_number" \
                            --body "**Severity**: P0 - CRITICAL

**Issue**: Deployment failed immediately after PR merge

**Type**: $regression_type
**Evidence**: $evidence

**Action Taken**: Rollback initiated

**Related PR**: #$pr_number

---
Auto-created by Shipwright Post-Merge Feedback System" \
                            --label "shipwright" \
                            --label "incident" \
                            --label "p0" \
                            2>&1 | grep -oE 'https://github.com/[^ ]+' | head -1 || true
                    fi
                fi
            fi
            ;;
        P1)
            # Error spike: create hotfix issue
            info "P1 SEVERITY: Error spike detected — creating hotfix issue"
            if [[ "${NO_GITHUB:-}" != "true" && "${NO_GITHUB:-}" != "1" ]]; then
                local owner_repo
                owner_repo=$(get_owner_repo) || true
                if [[ -n "$owner_repo" && -n "$pr_number" ]]; then
                    if command -v gh >/dev/null 2>&1; then
                        gh issue create \
                            --repo "$owner_repo" \
                            --title "Hotfix Needed: Post-Merge Error Spike - PR #$pr_number" \
                            --body "**Severity**: P1 - HIGH

**Issue**: Error spike detected in production after PR merge

**Type**: $regression_type
**Evidence**: $evidence

**Action Required**: Investigate and create hotfix

**Related PR**: #$pr_number

---
Auto-created by Shipwright Post-Merge Feedback System" \
                            --label "shipwright" \
                            --label "hotfix" \
                            --label "p1" \
                            2>&1 | grep -oE 'https://github.com/[^ ]+' | head -1 || true
                    fi
                fi
            fi
            ;;
        P2)
            # Performance or minor regression: schedule for next sprint
            info "P2 SEVERITY: Performance degradation — scheduling for next sprint"
            ;;
        P3|*)
            # Minor: just record in memory
            info "P3 SEVERITY: Minor regression — recorded for awareness"
            ;;
    esac

    emit_event "feedback_auto_respond" "severity=$severity" "type=$regression_type"
}

# ─── Learn from post-merge outcomes ─────────────────────────────────────────────
feedback_learn_from_outcome() {
    local pr_number="${1:-}"
    local merge_result="${2:-success}"
    local deploy_result="${3:-unknown}"
    local regression="${4:-false}"
    local regression_type="${5:-none}"

    if [[ -z "$pr_number" ]]; then
        error "Usage: feedback_learn_from_outcome <pr_number> [merge_result] [deploy_result] [regression] [type]"
        return 1
    fi

    info "Recording merge outcome for learning: PR #$pr_number"

    ensure_dirs

    # Calculate time-to-detect (from merge timestamp if available)
    local time_to_detect=0
    if [[ -f "$POST_MERGE_MONITORING_FILE" ]]; then
        local start_epoch
        start_epoch=$(jq -r '.start_epoch // 0' "$POST_MERGE_MONITORING_FILE")
        local end_epoch
        end_epoch=$(jq -r '.end_epoch // 0' "$POST_MERGE_MONITORING_FILE")
        if [[ "$end_epoch" -gt 0 && "$start_epoch" -gt 0 ]]; then
            time_to_detect=$((end_epoch - start_epoch))
        fi
    fi

    local outcome_entry
    outcome_entry=$(jq -c -n \
        --arg ts "$(now_iso)" \
        --arg pr "$pr_number" \
        --arg merge_res "$merge_result" \
        --arg deploy_res "$deploy_result" \
        --arg regr "$regression" \
        --arg regr_type "$regression_type" \
        --arg ttd "$time_to_detect" \
        --arg repo "$(basename "$REPO_DIR")" \
        '{
            timestamp: $ts,
            pr_number: $pr,
            repository: $repo,
            merge_result: $merge_res,
            deploy_result: $deploy_res,
            regression_detected: ($regr == "true"),
            regression_type: $regr_type,
            time_to_detect_secs: ($ttd | tonumber)
        }')

    # Atomic write
    local tmp_file
    tmp_file=$(mktemp)
    echo "$outcome_entry" >> "$tmp_file"
    cat "$MERGE_OUTCOMES_FILE" >> "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$MERGE_OUTCOMES_FILE"

    success "Learned outcome: PR #$pr_number ($merge_result / $deploy_result / regression=$regression)"
    emit_event "feedback_learn_from_outcome" "pr=$pr_number" "merge_result=$merge_result" "regression=$regression"
}

# ─── Generate post-merge health report ──────────────────────────────────────────
feedback_report() {
    local days="${1:-30}"

    info "Post-Merge Health Report (last $days days)"
    echo ""

    if [[ ! -f "$MERGE_OUTCOMES_FILE" ]]; then
        warn "No merge outcomes recorded yet"
        return 0
    fi

    # Calculate metrics
    local total_merges=0
    local successful_merges=0
    local regressions=0
    local p0_count=0
    local p1_count=0
    local p2_count=0
    local total_detect_time=0
    local avg_detect_time=0
    local common_types=""

    while IFS= read -r line; do
        local merge_res
        merge_res=$(echo "$line" | jq -r '.merge_result // "unknown"')
        local regression
        regression=$(echo "$line" | jq -r '.regression_detected // false')
        local regr_type
        regr_type=$(echo "$line" | jq -r '.regression_type // "none"')
        local ttd
        ttd=$(echo "$line" | jq -r '.time_to_detect_secs // 0')

        total_merges=$((total_merges + 1))
        [[ "$merge_res" == "success" ]] && successful_merges=$((successful_merges + 1))
        [[ "$regression" == "true" ]] && regressions=$((regressions + 1))

        total_detect_time=$((total_detect_time + ttd))

        # Count severity (inferred from time-to-detect for now)
        if [[ "$ttd" -lt 300 ]]; then
            p0_count=$((p0_count + 1))
        elif [[ "$ttd" -lt 900 ]]; then
            p1_count=$((p1_count + 1))
        else
            p2_count=$((p2_count + 1))
        fi

        # Track common regression types
        if [[ "$regr_type" != "none" ]]; then
            common_types="${common_types}${regr_type};"
        fi
    done < "$MERGE_OUTCOMES_FILE"

    if [[ "$total_merges" -gt 0 ]]; then
        avg_detect_time=$((total_detect_time / total_merges))
    fi

    # Output report
    echo "  ${CYAN}Merge Statistics${RESET}"
    echo "    Total Merges:        $total_merges"
    echo "    Success Rate:        $((successful_merges * 100 / total_merges))% ($successful_merges/$total_merges)"
    echo "    Regressions:         $regressions ($((regressions * 100 / total_merges))%)"
    echo ""
    echo "  ${CYAN}Detection Metrics${RESET}"
    echo "    Avg Detection Time:  ${avg_detect_time}s ($((avg_detect_time / 60))m)"
    echo "    P0 Incidents:        $p0_count"
    echo "    P1 Issues:           $p1_count"
    echo "    P2 Items:            $p2_count"
    echo ""
    echo "  ${CYAN}Common Regression Types${RESET}"
    if [[ -n "$common_types" ]]; then
        echo "$common_types" | tr ';' '\n' | sort | uniq -c | sort -rn | head -5 | while read -r count type; do
            [[ -n "$type" ]] && echo "    $type:         $count occurrences"
        done
    else
        echo "    (None recorded)"
    fi
    echo ""
    success "Report generated"
    return 0
}

# ─── Collect errors from monitor stage output ────────────────────────────────────
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
            # shellcheck disable=SC2034
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

    if ! command -v gh >/dev/null 2>&1; then
        error "gh CLI not found — cannot create issue"
        return 1
    fi

    # Create issue via gh
    local issue_url
    # Intake caps (ADR-0007): the cap counts open hotfix issues in $owner_repo
    issue_url=$(patrol_issue_create --intake-label "hotfix" \
        --repo "$owner_repo" \
        --title "Production Regression: $error_count errors detected" \
        --body "$issue_body" \
        --label "shipwright" \
        --label "hotfix" \
        2>&1 | tail -1) || true

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

    # Trigger real rollback via sw-github-deploy.sh (GitHub Deployments API)
    local rollback_status="initiated"
    local rollback_rc=0
    bash "$SCRIPT_DIR/sw-github-deploy.sh" rollback "$environment" 2>&1 | tee -a "${ARTIFACTS_DIR}/rollback-output.log"
    rollback_rc=${PIPESTATUS[0]:-$?}
    if [[ "$rollback_rc" -eq 0 ]]; then
        rollback_status="executed"
        success "Rollback executed for $environment via GitHub Deployments API"
    else
        warn "GitHub Deployments rollback failed or unavailable (exit $rollback_rc, see rollback-output.log)"
    fi

    local rollback_entry
    rollback_entry=$(jq -n \
        --arg ts "$(now_iso)" \
        --arg env "$environment" \
        --arg reason "$reason" \
        --arg status "$rollback_status" \
        '{timestamp: $ts, environment: $env, reason: $reason, status: $status}')

    echo "$rollback_entry" >> "${ARTIFACTS_DIR}/rollbacks.jsonl"
    emit_event "feedback_rollback" "environment=$environment" "reason=$reason" "status=$rollback_status"
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

  ${CYAN}post-merge${RESET} [sha] [env]     Monitor production after merge
  ${CYAN}regressions${RESET} [file]          Detect regressions from monitoring data
  ${CYAN}correlate${RESET} [pr] [json]       Link regressions to changed files
  ${CYAN}outcomes${RESET} [pr] [...]         Record merge outcome for learning
  ${CYAN}health${RESET} [days]               Post-merge health report

  ${CYAN}help${RESET}                        Show this help message

${BOLD}EXAMPLES${RESET}
  ${DIM}# Traditional flow${RESET}
  ${DIM}shipwright feedback collect ./logs${RESET}
  ${DIM}shipwright feedback analyze${RESET}
  ${DIM}shipwright feedback create-issue${RESET}
  ${DIM}shipwright feedback rollback production "Hotfix v1.2.3 regression"${RESET}
  ${DIM}shipwright feedback learn "Off-by-one error" "Fixed in PR #456"${RESET}
  ${DIM}shipwright feedback report 30${RESET}

  ${DIM}# Post-merge monitoring flow${RESET}
  ${DIM}shipwright feedback post-merge abc1234 production${RESET}
  ${DIM}shipwright feedback regressions${RESET}
  ${DIM}shipwright feedback correlate 42${RESET}
  ${DIM}shipwright feedback outcomes 42 success deployed true error_spike${RESET}
  ${DIM}shipwright feedback health 30${RESET}

${BOLD}STORAGE${RESET}
  Incidents:       $INCIDENTS_FILE
  Errors:          ${ARTIFACTS_DIR}/errors-collected.json
  Rollbacks:       ${ARTIFACTS_DIR}/rollbacks.jsonl
  Merge Outcomes:  $MERGE_OUTCOMES_FILE
  Monitoring:      $POST_MERGE_MONITORING_FILE

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
        post-merge)
            feedback_post_merge_monitor "$@"
            ;;
        regressions)
            feedback_detect_regression "$@"
            ;;
        correlate)
            feedback_correlate_with_changes "$@"
            ;;
        outcomes)
            feedback_learn_from_outcome "$@"
            ;;
        health)
            feedback_report "$@"
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
