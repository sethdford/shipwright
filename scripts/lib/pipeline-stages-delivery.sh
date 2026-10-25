# pipeline-stages-delivery.sh — pr, merge, deploy stages
# Source from pipeline-stages.sh. Requires all pipeline globals and dependencies.
[[ -n "${_PIPELINE_STAGES_DELIVERY_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_DELIVERY_LOADED=1

stage_pr() {
    CURRENT_STAGE_ID="pr"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-pr.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _pr_retry_hints
        _pr_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi
    # Load PR quality skills (used as guidance for hygiene checks)
    local _pr_skills=""
    if type skill_load_prompts >/dev/null 2>&1; then
        _pr_skills=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "pr" 2>/dev/null || true)
        if [[ -n "$_pr_skills" ]]; then
            echo "$_pr_skills" > "${ARTIFACTS_DIR}/.pr-quality-skills.md" 2>/dev/null || true
        fi
    fi
    local plan_file="$ARTIFACTS_DIR/plan.md"
    local test_log="$ARTIFACTS_DIR/test-results.log"
    local review_file="$ARTIFACTS_DIR/review.md"

    # ── Skip PR in local/no-github mode ──
    if [[ "${NO_GITHUB:-false}" == "true" || "${SHIPWRIGHT_LOCAL:-}" == "1" || "${LOCAL_MODE:-false}" == "true" ]]; then
        info "Skipping PR stage — running in local/no-github mode"
        # Save a PR draft locally for reference
        local branch_name
        branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        local commit_count
        commit_count=$(_safe_base_log --oneline | wc -l | xargs)
        {
            echo "# PR Draft (local mode)"
            echo ""
            echo "**Branch:** ${branch_name}"
            echo "**Commits:** ${commit_count:-0}"
            echo "**Goal:** ${GOAL:-N/A}"
            echo ""
            echo "## Changes"
            _safe_base_diff --stat || true
        } > ".claude/pr-draft.md" 2>/dev/null || true
        emit_event "pr.skipped" "issue=${ISSUE_NUMBER:-0}" "reason=local_mode"
        return 0
    fi

    # ── PR Hygiene Checks (informational) ──
    local hygiene_commit_count
    hygiene_commit_count=$(_safe_base_log --oneline | wc -l | xargs)
    hygiene_commit_count="${hygiene_commit_count:-0}"

    if [[ "$hygiene_commit_count" -gt 20 ]]; then
        warn "PR has ${hygiene_commit_count} commits — consider squashing before merge"
    fi

    # Check for WIP/fixup/squash commits (expanded patterns)
    local wip_commits
    wip_commits=$(_safe_base_log --oneline | grep -ciE '^[0-9a-f]+ (WIP|fixup!|squash!|TODO|HACK|TEMP|BROKEN|wip[:-]|temp[:-]|broken[:-]|do not merge)' || true)
    wip_commits="${wip_commits:-0}"
    if [[ "$wip_commits" -gt 0 ]]; then
        warn "Branch has ${wip_commits} WIP/fixup/squash/temp commit(s) — consider cleaning up"
    fi

    # ── PR Quality Gate: reject PRs with no real code changes ──
    local real_files
    real_files=$(_safe_base_diff --name-only | grep -v '^\.claude/' | grep -v '^\.github/' || true)
    if [[ -z "$real_files" ]]; then
        error "No real code changes detected — only pipeline artifacts (.claude/ logs)."
        error "The build agent did not produce meaningful changes. Skipping PR creation."
        emit_event "pr.rejected" "issue=${ISSUE_NUMBER:-0}" "reason=no_real_changes"
        # Mark issue so auto-retry knows not to retry empty builds
        if [[ -n "${ISSUE_NUMBER:-}" && "${ISSUE_NUMBER:-0}" != "0" ]]; then
            gh issue comment "$ISSUE_NUMBER" --body "<!-- SHIPWRIGHT-NO-CHANGES: true -->" 2>/dev/null || true
        fi
        return 1
    fi
    local real_file_count
    real_file_count=$(echo "$real_files" | wc -l | xargs)
    info "PR quality gate: ${real_file_count} real file(s) changed"

    # Commit any uncommitted changes left by the build agent
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        info "Committing remaining uncommitted changes..."
        git add -A 2>/dev/null || true
        git commit -m "chore: pipeline cleanup — commit remaining build changes" --no-verify 2>/dev/null || true
    fi

    # Blast-radius guard, final check (#8644): judge base..HEAD, including the commit above, before the
    # push. Fail closed: without the pipeline base, or on any violation, nothing is pushed.
    if ! type scope_final_check >/dev/null 2>&1 \
        || ! scope_final_check "$PWD" "${SW_PIPELINE_BASE_SHA:-}" "${ARTIFACTS_DIR:-}" "${GOAL:-}" "${ISSUE_LABELS:-}"; then
        error "Blast-radius guard blocked the push: the branch changes are outside the declared scope or the pipeline base is unknown"
        return 1
    fi

    # Auto-rebase onto latest base branch before PR
    auto_rebase || {
        warn "Rebase/merge failed — pushing as-is"
    }

    # Push branch
    info "Pushing branch: $GIT_BRANCH"
    git push -u origin "$GIT_BRANCH" --force-with-lease 2>/dev/null || {
        # Retry with regular push if force-with-lease fails (first push)
        git push -u origin "$GIT_BRANCH" 2>/dev/null || {
            error "Failed to push branch"
            return 1
        }
    }

    # ── Developer Simulation (pre-PR review) ──
    local simulation_summary=""
    if type simulation_review >/dev/null 2>&1; then
        local sim_enabled
        sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
        # Also check daemon-config
        local daemon_cfg=".claude/daemon-config.json"
        if [[ "$sim_enabled" != "true" && -f "$daemon_cfg" ]]; then
            sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
        fi
        if [[ "$sim_enabled" == "true" ]]; then
            info "Running developer simulation review..."
            local diff_for_sim
            diff_for_sim=$(_safe_base_diff || true)
            if [[ -n "$diff_for_sim" ]]; then
                local sim_result
                sim_result=$(simulation_review "$diff_for_sim" "${GOAL:-}" 2>/dev/null || echo "")
                if [[ -n "$sim_result" && "$sim_result" != *'"error"'* ]]; then
                    echo "$sim_result" > "$ARTIFACTS_DIR/simulation-review.json"
                    local sim_count
                    sim_count=$(echo "$sim_result" | jq 'length' 2>/dev/null || echo "0")
                    simulation_summary="**Developer simulation:** ${sim_count} reviewer concerns pre-addressed"
                    success "Simulation complete: ${sim_count} concerns found and addressed"
                    emit_event "simulation.complete" "issue=${ISSUE_NUMBER:-0}" "concerns=${sim_count}"
                else
                    info "Simulation returned no actionable concerns"
                fi
            fi
        fi
    fi

    # ── Architecture Validation (pre-PR check) ──
    local arch_summary=""
    if type architecture_validate_changes >/dev/null 2>&1; then
        local arch_enabled
        arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
        local daemon_cfg=".claude/daemon-config.json"
        if [[ "$arch_enabled" != "true" && -f "$daemon_cfg" ]]; then
            arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
        fi
        if [[ "$arch_enabled" == "true" ]]; then
            info "Validating architecture..."
            local diff_for_arch
            diff_for_arch=$(_safe_base_diff || true)
            if [[ -n "$diff_for_arch" ]]; then
                local arch_result
                arch_result=$(architecture_validate_changes "$diff_for_arch" "" 2>/dev/null || echo "")
                if [[ -n "$arch_result" && "$arch_result" != *'"error"'* ]]; then
                    echo "$arch_result" > "$ARTIFACTS_DIR/architecture-validation.json"
                    local violation_count
                    violation_count=$(echo "$arch_result" | jq '[.violations[]? | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")
                    arch_summary="**Architecture validation:** ${violation_count} violations"
                    if [[ "$violation_count" -gt 0 ]]; then
                        warn "Architecture: ${violation_count} high/critical violations found"
                    else
                        success "Architecture validation passed"
                    fi
                    emit_event "architecture.validated" "issue=${ISSUE_NUMBER:-0}" "violations=${violation_count}"
                else
                    info "Architecture validation returned no results"
                fi
            fi
        fi
    fi

    # Pre-PR diff gate — verify meaningful code changes exist (not just bookkeeping)
    local real_changes
    real_changes=$(_safe_base_diff --name-only \
        -- . ':!.claude/loop-state.md' ':!.claude/pipeline-state.md' \
        ':!.claude/pipeline-artifacts/*' ':!**/progress.md' \
        ':!**/error-summary.json' | wc -l | xargs || true)
    real_changes="${real_changes:-0}"
    if [[ "${real_changes:-0}" -eq 0 ]]; then
        error "No meaningful code changes detected — only bookkeeping files modified"
        error "Refusing to create PR with zero real changes"
        return 1
    fi
    info "Pre-PR diff check: ${real_changes} real files changed"

    # Build PR title — prefer GOAL over plan file first line
    # (plan file first line often contains Claude analysis text, not a clean title)
    local pr_title=""
    if [[ -n "${GOAL:-}" ]]; then
        pr_title=$(echo "$GOAL" | cut -c1-70)
    fi
    if [[ -z "$pr_title" ]] && [[ -s "$plan_file" ]]; then
        pr_title=$(head -1 "$plan_file" 2>/dev/null | sed 's/^#* *//' | cut -c1-70)
    fi
    [[ -z "$pr_title" ]] && pr_title="Pipeline changes for issue ${ISSUE_NUMBER:-unknown}"

    # Sanitize: reject PR titles that look like error messages
    if echo "$pr_title" | grep >/dev/null -iE 'Invalid API|API key|authentication_error|rate_limit|CLI error|no useful output'; then
        warn "PR title looks like an error message: $pr_title"
        pr_title="Pipeline changes for issue ${ISSUE_NUMBER:-unknown}"
    fi

    # Build comprehensive PR body
    local plan_summary=""
    if [[ -s "$plan_file" ]]; then
        plan_summary=$(head -20 "$plan_file" 2>/dev/null | tail -15)
    fi

    local test_summary=""
    if [[ -s "$test_log" ]]; then
        test_summary=$(tail -10 "$test_log" | sed 's/\x1b\[[0-9;]*m//g')
    fi

    local review_summary=""
    if [[ -s "$review_file" ]]; then
        local total_issues=0
        # Try JSON structured output first
        if head -1 "$review_file" 2>/dev/null | grep >/dev/null '^{' 2>/dev/null; then
            total_issues=$(jq -r '.issues | length' "$review_file" 2>/dev/null || echo "0")
        fi
        # Grep fallback for markdown
        if [[ "${total_issues:-0}" -eq 0 ]]; then
            total_issues=$(grep -ciE '\*\*\[?(Critical|Bug|Security|Warning|Suggestion)\]?\*\*' "$review_file" 2>/dev/null || true)
            total_issues="${total_issues:-0}"
        fi
        review_summary="**Code review:** $total_issues issues found"
    fi

    local closes_line=""
    [[ -n "${GITHUB_ISSUE:-}" ]] && closes_line="Closes ${GITHUB_ISSUE}"

    local diff_stats
    diff_stats=$(_safe_base_diff --stat | tail -1 || echo "")

    local commit_count
    commit_count=$(_safe_base_log --oneline | wc -l | xargs)

    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    local pr_body
    pr_body="$(cat <<EOF
## Summary
${plan_summary:-$GOAL}

## Changes
${diff_stats}
${commit_count} commit(s) via \`shipwright pipeline\` (${PIPELINE_NAME})

## Test Results
\`\`\`
${test_summary:-No test output}
\`\`\`

${review_summary}
${simulation_summary}
${arch_summary}

${closes_line}

---

| Metric | Value |
|--------|-------|
| Pipeline | \`${PIPELINE_NAME}\` |
| Duration | ${total_dur:-—} |
| Model | ${MODEL:-opus} |
| Agents | ${AGENTS:-1} |

Generated by \`shipwright pipeline\`
EOF
)"

    # Verify required evidence before PR (merge policy enforcement)
    local risk_tier
    risk_tier="low"
    if [[ -f "$REPO_DIR/config/policy.json" ]]; then
        local changed_files
        changed_files=$(_safe_base_diff --name-only || true)
        if [[ -n "$changed_files" ]]; then
            local policy_file="$REPO_DIR/config/policy.json"
            check_tier_match() {
                local tier="$1"
                local patterns
                patterns=$(jq -r ".riskTierRules.${tier}[]? // empty" "$policy_file" 2>/dev/null)
                [[ -z "$patterns" ]] && return 1
                while IFS= read -r pattern; do
                    [[ -z "$pattern" ]] && continue
                    local regex
                    regex=$(echo "$pattern" | sed 's/\./\\./g; s/\*\*/DOUBLESTAR/g; s/\*/[^\/]*/g; s/DOUBLESTAR/.*/g')
                    while IFS= read -r file; do
                        [[ -z "$file" ]] && continue
                        if echo "$file" | grep >/dev/null -E "^${regex}$"; then
                            return 0
                        fi
                    done <<< "$changed_files"
                done <<< "$patterns"
                return 1
            }
            check_tier_match "critical" && risk_tier="critical"
            check_tier_match "high" && [[ "$risk_tier" != "critical" ]] && risk_tier="high"
            check_tier_match "medium" && [[ "$risk_tier" != "critical" && "$risk_tier" != "high" ]] && risk_tier="medium"
        fi
    fi

    local required_evidence
    required_evidence=$(jq -r ".mergePolicy.\"$risk_tier\".requiredEvidence // [] | .[]" "$REPO_DIR/config/policy.json" 2>/dev/null)

    if [[ -n "$required_evidence" ]]; then
        local evidence_dir="$REPO_DIR/.claude/evidence"
        local missing_evidence=()
        while IFS= read -r etype; do
            [[ -z "$etype" ]] && continue
            local has_evidence=false
            for f in "$evidence_dir"/*"$etype"*; do
                [[ -f "$f" ]] && has_evidence=true && break
            done
            [[ "$has_evidence" != "true" ]] && missing_evidence+=("$etype")
        done <<< "$required_evidence"

        if [[ ${#missing_evidence[@]} -gt 0 ]]; then
            warn "Missing required evidence for $risk_tier tier: ${missing_evidence[*]}"
            emit_event "evidence.missing" "{\"tier\":\"$risk_tier\",\"missing\":\"${missing_evidence[*]}\"}"
            # Collect missing evidence
            if [[ -x "$SCRIPT_DIR/sw-evidence.sh" ]]; then
                for etype in "${missing_evidence[@]}"; do
                    (cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-evidence.sh" capture "$etype" 2>/dev/null) || warn "Failed to collect $etype evidence"
                done
            fi
        fi
    fi

    # ── PR Size Gate: Check against limits from quality profile ──
    if type check_pr_size >/dev/null 2>&1; then
        local quality_profile=".claude/quality-profile.json"
        local max_pr_lines=500

        if [[ -f "$quality_profile" ]]; then
            max_pr_lines=$(jq -r '.quality.max_pr_lines // 500' "$quality_profile" 2>/dev/null || echo "500")
        fi

        if ! check_pr_size "origin/$BASE_BRANCH" "$max_pr_lines"; then
            # Get actual PR stats for error message
            local stats pr_stats insertions deletions files_changed total_lines
            stats=$(get_pr_stats "origin/$BASE_BRANCH" 2>/dev/null || echo "{}")
            insertions=$(echo "$stats" | jq '.insertions // 0' 2>/dev/null || echo "0")
            deletions=$(echo "$stats" | jq '.deletions // 0' 2>/dev/null || echo "0")
            files_changed=$(echo "$stats" | jq '.files_changed // 0' 2>/dev/null || echo "0")
            total_lines=$((insertions + deletions))

            error "PR size gate failed: ${total_lines} lines of change (max: ${max_pr_lines})"
            error "Files changed: ${files_changed} | Insertions: +${insertions} | Deletions: -${deletions}"

            # Check if scope enforcement is blocking
            local scope_enforcement_blocks=false
            if [[ -f "$quality_profile" ]]; then
                scope_enforcement_blocks=$(jq -r '.scope.unplanned_files_block // false' "$quality_profile" 2>/dev/null)
            fi

            if [[ "$scope_enforcement_blocks" == "true" ]]; then
                error "Scope enforcement is enabled — decompose into smaller PRs"
                emit_event "pr.rejected" "issue=${ISSUE_NUMBER:-0}" "reason=oversized_pr" "lines=${total_lines}" "max=${max_pr_lines}"
                return 1
            else
                warn "PR size exceeds limit (enforcing disabled) — consider splitting into smaller PRs"
                emit_event "pr.warning" "issue=${ISSUE_NUMBER:-0}" "reason=oversized_pr" "lines=${total_lines}" "max=${max_pr_lines}"
            fi
        fi
    fi

    # Build gh pr create args
    local pr_args=(--title "$pr_title" --body "$pr_body" --base "$BASE_BRANCH")

    # Propagate labels from issue + CLI
    local all_labels="${LABELS}"
    if [[ -n "$ISSUE_LABELS" ]]; then
        if [[ -n "$all_labels" ]]; then
            all_labels="${all_labels},${ISSUE_LABELS}"
        else
            all_labels="$ISSUE_LABELS"
        fi
    fi
    if [[ -n "$all_labels" ]]; then
        pr_args+=(--label "$all_labels")
    fi

    # Auto-detect or use provided reviewers
    local reviewers="${REVIEWERS}"
    if [[ -z "$reviewers" ]]; then
        reviewers=$(detect_reviewers)
    fi
    if [[ -n "$reviewers" ]]; then
        pr_args+=(--reviewer "$reviewers")
        info "Reviewers: ${DIM}$reviewers${RESET}"
    fi

    # Propagate milestone
    if [[ -n "$ISSUE_MILESTONE" ]]; then
        pr_args+=(--milestone "$ISSUE_MILESTONE")
        info "Milestone: ${DIM}$ISSUE_MILESTONE${RESET}"
    fi

    # Check for existing open PR on this branch to avoid duplicates (issue #12)
    local pr_url=""
    local existing_pr
    existing_pr=$(gh pr list --head "$GIT_BRANCH" --state open --json number,url --jq '.[0]' 2>/dev/null || echo "")
    if [[ -n "$existing_pr" && "$existing_pr" != "null" ]]; then
        local existing_pr_number existing_pr_url
        existing_pr_number=$(echo "$existing_pr" | jq -r '.number' 2>/dev/null || echo "")
        existing_pr_url=$(echo "$existing_pr" | jq -r '.url' 2>/dev/null || echo "")
        info "Updating existing PR #$existing_pr_number instead of creating duplicate"
        gh pr edit "$existing_pr_number" --title "$pr_title" --body "$pr_body" 2>/dev/null || true
        pr_url="$existing_pr_url"
    else
        info "Creating PR..."
        local pr_stderr pr_exit=0
        pr_url=$(gh pr create "${pr_args[@]}" 2>/tmp/shipwright-pr-stderr.txt) || pr_exit=$?
        pr_stderr=$(cat /tmp/shipwright-pr-stderr.txt 2>/dev/null || true)
        rm -f /tmp/shipwright-pr-stderr.txt

        # gh pr create may return non-zero for reviewer issues but still create the PR
        if [[ "$pr_exit" -ne 0 ]]; then
            if [[ "$pr_url" == *"github.com"* ]]; then
                # PR was created but something non-fatal failed (e.g., reviewer not found)
                warn "PR created with warnings: ${pr_stderr:-unknown}"
            else
                error "PR creation failed: ${pr_stderr:-$pr_url}"
                return 1
            fi
        fi
    fi

    success "PR created: ${BOLD}$pr_url${RESET}"
    echo "$pr_url" > "$ARTIFACTS_DIR/pr-url.txt"

    # Extract PR number
    PR_NUMBER=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)

    # ── Intelligent Reviewer Selection (GraphQL-enhanced) ──
    if [[ "${NO_GITHUB:-false}" != "true" && -n "$PR_NUMBER" && -z "$reviewers" ]]; then
        local reviewer_assigned=false

        # Try CODEOWNERS-based routing via GraphQL API
        if type gh_codeowners >/dev/null 2>&1 && [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            local codeowners_json
            codeowners_json=$(gh_codeowners "$REPO_OWNER" "$REPO_NAME" 2>/dev/null || echo "[]")
            if [[ "$codeowners_json" != "[]" && -n "$codeowners_json" ]]; then
                local changed_files
                changed_files=$(_safe_base_diff --name-only || true)
                if [[ -n "$changed_files" ]]; then
                    local co_reviewers
                    co_reviewers=$(echo "$codeowners_json" | jq -r '.[].owners[]' 2>/dev/null | sort -u | head -3 || true)
                    if [[ -n "$co_reviewers" ]]; then
                        local rev
                        while IFS= read -r rev; do
                            rev="${rev#@}"
                            [[ -n "$rev" ]] && gh pr edit "$PR_NUMBER" --add-reviewer "$rev" 2>/dev/null || true
                        done <<< "$co_reviewers"
                        info "Requested review from CODEOWNERS: $(echo "$co_reviewers" | tr '\n' ',' | sed 's/,$//')"
                        reviewer_assigned=true
                    fi
                fi
            fi
        fi

        # Fallback: contributor-based routing via GraphQL API
        if [[ "$reviewer_assigned" != "true" ]] && type gh_contributors >/dev/null 2>&1 && [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            local contributors_json
            contributors_json=$(gh_contributors "$REPO_OWNER" "$REPO_NAME" 2>/dev/null || echo "[]")
            local top_contributor
            top_contributor=$(echo "$contributors_json" | jq -r '.[0].login // ""' 2>/dev/null || echo "")
            local current_user
            current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
            if [[ -n "$top_contributor" && "$top_contributor" != "$current_user" ]]; then
                gh pr edit "$PR_NUMBER" --add-reviewer "$top_contributor" 2>/dev/null || true
                info "Requested review from top contributor: $top_contributor"
                reviewer_assigned=true
            fi
        fi

        # Final fallback: auto-approve if no reviewers assigned
        if [[ "$reviewer_assigned" != "true" ]]; then
            gh pr review "$PR_NUMBER" --approve 2>/dev/null || warn "Could not auto-approve PR"
        fi
    fi

    # Update issue with PR link
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_remove_label "$ISSUE_NUMBER" "pipeline/in-progress"
        gh_add_labels "$ISSUE_NUMBER" "pipeline/pr-created"
        gh_comment_issue "$ISSUE_NUMBER" "🎉 **PR created:** ${pr_url}

Pipeline duration so far: ${total_dur:-unknown}"

        # Notify tracker of review/PR creation
        "$SCRIPT_DIR/sw-tracker.sh" notify "review" "$ISSUE_NUMBER" "$pr_url" 2>/dev/null || true
    fi

    # Wait for CI if configured
    local wait_ci
    wait_ci=$(jq -r --arg id "pr" '(.stages[] | select(.id == $id) | .config.wait_ci) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    if [[ "$wait_ci" == "true" ]]; then
        info "Waiting for CI checks..."
        gh pr checks --watch 2>/dev/null || warn "CI checks did not all pass"
    fi

    log_stage "pr" "PR created: $pr_url (${reviewers:+reviewers: $reviewers})"
}

stage_merge() {
    CURRENT_STAGE_ID="merge"

    if [[ "$NO_GITHUB" == "true" ]]; then
        info "Merge stage skipped (--no-github)"
        return 0
    fi

    # ── Oversight gate: merge block on verdict (diff + review criticals + goal) ──
    if [[ -x "$SCRIPT_DIR/sw-oversight.sh" ]] && [[ "${SKIP_GATES:-false}" != "true" ]]; then
        local merge_diff_file="${ARTIFACTS_DIR}/review-diff.patch"
        local merge_review_file="${ARTIFACTS_DIR}/review.md"
        if [[ ! -s "$merge_diff_file" ]]; then
            _safe_base_diff > "$merge_diff_file" 2>/dev/null || true
        fi
        if [[ -s "$merge_diff_file" ]]; then
            local _merge_critical _merge_sec _merge_blocking _merge_reject
            _merge_critical=$(grep -ciE '\*\*\[?Critical\]?\*\*' "$merge_review_file" 2>/dev/null || true)
            _merge_critical="${_merge_critical:-0}"
            _merge_sec=$(grep -ciE '\*\*\[?Security\]?\*\*' "$merge_review_file" 2>/dev/null || true)
            _merge_sec="${_merge_sec:-0}"
            _merge_blocking=$((${_merge_critical:-0} + ${_merge_sec:-0}))
            [[ "$_merge_blocking" -gt 0 ]] && _merge_reject="Review found ${_merge_blocking} critical/security issue(s)"
            if ! bash "$SCRIPT_DIR/sw-oversight.sh" gate --diff "$merge_diff_file" --description "${GOAL:-Pipeline merge}" --reject-if "${_merge_reject:-}" >/dev/null 2>&1; then
                error "Oversight gate rejected — blocking merge"
                emit_event "merge.oversight_blocked" "issue=${ISSUE_NUMBER:-0}"
                log_stage "merge" "BLOCKED: oversight gate rejected"
                return 1
            fi
        fi
    fi

    # ── Approval gates: block if merge requires approval and pending for this issue ──
    local ag_file="${HOME}/.shipwright/approval-gates.json"
    if [[ -f "$ag_file" ]] && [[ "${SKIP_GATES:-false}" != "true" ]]; then
        local ag_enabled ag_stages ag_pending_merge ag_issue_num
        ag_enabled=$(jq -r '.enabled // false' "$ag_file" 2>/dev/null || echo "false")
        ag_stages=$(jq -r '.stages // [] | if type == "array" then .[] else empty end' "$ag_file" 2>/dev/null || true)
        ag_issue_num=$(echo "${ISSUE_NUMBER:-0}" | awk '{print $1+0}')
        if [[ "$ag_enabled" == "true" ]] && echo "$ag_stages" | grep >/dev/null -x "merge" 2>/dev/null; then
            local ha_file="${ARTIFACTS_DIR}/human-approval.txt"
            local ha_approved="false"
            if [[ -f "$ha_file" ]]; then
                ha_approved=$(jq -r --arg stage "merge" 'select(.stage == $stage) | .approved // false' "$ha_file" 2>/dev/null || echo "false")
            fi
            if [[ "$ha_approved" != "true" ]]; then
                ag_pending_merge=$(jq -r --argjson issue "$ag_issue_num" --arg stage "merge" \
                    '[.pending[]? | select(.issue == $issue and .stage == $stage)] | length' "$ag_file" 2>/dev/null || echo "0")
                if [[ "${ag_pending_merge:-0}" -eq 0 ]]; then
                    local req_at tmp_ag
                    req_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)
                    tmp_ag=$(mktemp "${HOME}/.shipwright/approval-gates.json.XXXXXX" 2>/dev/null || mktemp)
                    jq --argjson issue "$ag_issue_num" --arg stage "merge" --arg requested "${req_at}" \
                        '.pending += [{"issue": $issue, "stage": $stage, "requested_at": $requested}]' "$ag_file" > "$tmp_ag" 2>/dev/null && mv "$tmp_ag" "$ag_file" || rm -f "$tmp_ag"
                fi
                info "Merge requires approval — awaiting human approval via dashboard"
                emit_event "merge.approval_pending" "issue=${ISSUE_NUMBER:-0}"
                log_stage "merge" "BLOCKED: approval gate pending"
                return 1
            fi
        fi
    fi

    # ── Branch Protection Check ──
    if type gh_branch_protection >/dev/null 2>&1 && [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
        local protection_json
        protection_json=$(gh_branch_protection "$REPO_OWNER" "$REPO_NAME" "${BASE_BRANCH:-main}" 2>/dev/null || echo '{"protected": false}')
        local is_protected
        is_protected=$(echo "$protection_json" | jq -r '.protected // false' 2>/dev/null || echo "false")
        if [[ "$is_protected" == "true" ]]; then
            local required_reviews
            required_reviews=$(echo "$protection_json" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null || echo "0")
            local required_checks
            required_checks=$(echo "$protection_json" | jq -r '[.required_status_checks.contexts // [] | .[]] | length' 2>/dev/null || echo "0")

            info "Branch protection: ${required_reviews} required review(s), ${required_checks} required check(s)"

            if [[ "$required_reviews" -gt 0 ]]; then
                # Check if PR has enough approvals
                local prot_pr_number
                prot_pr_number=$(gh pr list --head "$GIT_BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")
                if [[ -n "$prot_pr_number" ]]; then
                    local approvals
                    approvals=$(gh pr view "$prot_pr_number" --json reviews --jq '[.reviews[] | select(.state == "APPROVED")] | length' 2>/dev/null || echo "0")
                    if [[ "$approvals" -lt "$required_reviews" ]]; then
                        warn "PR has $approvals approval(s), needs $required_reviews — skipping auto-merge"
                        info "PR is ready for manual merge after required reviews"
                        emit_event "merge.blocked" "issue=${ISSUE_NUMBER:-0}" "reason=insufficient_reviews" "have=$approvals" "need=$required_reviews"
                        return 0
                    fi
                fi
            fi
        fi
    fi

    local merge_method wait_ci_timeout auto_delete_branch auto_merge auto_approve merge_strategy
    merge_method=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.merge_method) // "squash"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$merge_method" || "$merge_method" == "null" ]] && merge_method="squash"
    wait_ci_timeout=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.wait_ci_timeout_s) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$wait_ci_timeout" || "$wait_ci_timeout" == "null" ]] && wait_ci_timeout=0

    # Adaptive CI timeout: 90th percentile of historical times × 1.5 safety margin
    if [[ "$wait_ci_timeout" -eq 0 ]] 2>/dev/null; then
        local repo_hash_ci
        repo_hash_ci=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
        local ci_times_file="${HOME}/.shipwright/baselines/${repo_hash_ci}/ci-times.json"
        if [[ -f "$ci_times_file" ]]; then
            local p90_time
            p90_time=$(jq '
                .times | sort |
                (length * 0.9 | floor) as $idx |
                .[$idx] // 600
            ' "$ci_times_file" 2>/dev/null || echo "0")
            if [[ -n "$p90_time" ]] && awk -v t="$p90_time" 'BEGIN{exit !(t > 0)}' 2>/dev/null; then
                # 1.5x safety margin, clamped to [120, 1800]
                wait_ci_timeout=$(awk -v p90="$p90_time" 'BEGIN{
                    t = p90 * 1.5;
                    if (t < 120) t = 120;
                    if (t > 1800) t = 1800;
                    printf "%d", t
                }')
            fi
        fi
        # Default fallback if no history
        [[ "$wait_ci_timeout" -eq 0 ]] && wait_ci_timeout=600
    fi
    auto_delete_branch=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.auto_delete_branch) // "true"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_delete_branch" || "$auto_delete_branch" == "null" ]] && auto_delete_branch="true"
    auto_merge=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.auto_merge) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_merge" || "$auto_merge" == "null" ]] && auto_merge="false"
    auto_approve=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.auto_approve) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_approve" || "$auto_approve" == "null" ]] && auto_approve="false"
    merge_strategy=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.merge_strategy) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$merge_strategy" || "$merge_strategy" == "null" ]] && merge_strategy=""
    # merge_strategy overrides merge_method if set (squash/merge/rebase)
    if [[ -n "$merge_strategy" ]]; then
        merge_method="$merge_strategy"
    fi

    # Find PR for current branch
    local pr_number
    pr_number=$(gh pr list --head "$GIT_BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")

    if [[ -z "$pr_number" ]]; then
        warn "No PR found for branch $GIT_BRANCH — skipping merge"
        return 0
    fi

    info "Found PR #${pr_number} for branch ${GIT_BRANCH}"

    # Wait for CI checks to pass
    info "Waiting for CI checks (timeout: ${wait_ci_timeout}s)..."
    local elapsed=0
    local check_interval=15

    while [[ "$elapsed" -lt "$wait_ci_timeout" ]]; do
        local check_status
        check_status=$(gh pr checks "$pr_number" --json 'bucket,name' --jq '[.[] | .bucket] | unique | sort' 2>/dev/null || echo '["pending"]')

        # If all checks passed (only "pass" in buckets)
        if echo "$check_status" | jq -e '. == ["pass"]' >/dev/null 2>&1; then
            success "All CI checks passed"
            break
        fi

        # If any check failed
        if echo "$check_status" | jq -e 'any(. == "fail")' >/dev/null 2>&1; then
            error "CI checks failed — aborting merge"
            return 1
        fi

        sleep "$check_interval"
        elapsed=$((elapsed + check_interval))
    done

    # Record CI wait time for adaptive timeout calculation
    if [[ "$elapsed" -gt 0 ]]; then
        local repo_hash_ci_rec
        repo_hash_ci_rec=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
        local ci_times_dir="${HOME}/.shipwright/baselines/${repo_hash_ci_rec}"
        local ci_times_rec_file="${ci_times_dir}/ci-times.json"
        mkdir -p "$ci_times_dir"
        local ci_history="[]"
        if [[ -f "$ci_times_rec_file" ]]; then
            ci_history=$(jq '.times // []' "$ci_times_rec_file" 2>/dev/null || echo "[]")
        fi
        local updated_ci
        updated_ci=$(echo "$ci_history" | jq --arg t "$elapsed" '. + [($t | tonumber)] | .[-20:]' 2>/dev/null || echo "[$elapsed]")
        local tmp_ci
        tmp_ci=$(mktemp "${ci_times_dir}/ci-times.json.XXXXXX")
        jq -n --argjson times "$updated_ci" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{times: $times, updated: $updated}' > "$tmp_ci" 2>/dev/null
        mv "$tmp_ci" "$ci_times_rec_file" 2>/dev/null || true
    fi

    if [[ "$elapsed" -ge "$wait_ci_timeout" ]]; then
        warn "CI check timeout (${wait_ci_timeout}s) — proceeding with merge anyway"
    fi

    # Auto-approve if configured (for branch protection requiring reviews)
    if [[ "$auto_approve" == "true" ]]; then
        info "Auto-approving PR #${pr_number}..."
        gh pr review "$pr_number" --approve 2>/dev/null || warn "Auto-approve failed (may need different permissions)"
    fi

    # Merge the PR
    if [[ "$auto_merge" == "true" ]]; then
        info "Enabling auto-merge for PR #${pr_number} (strategy: ${merge_method})..."
        local auto_merge_args=("pr" "merge" "$pr_number" "--auto" "--${merge_method}")
        if [[ "$auto_delete_branch" == "true" ]]; then
            auto_merge_args+=("--delete-branch")
        fi

        if gh "${auto_merge_args[@]}" 2>/dev/null; then
            success "Auto-merge enabled for PR #${pr_number} (strategy: ${merge_method})"
            emit_event "merge.auto_enabled" \
                "issue=${ISSUE_NUMBER:-0}" \
                "pr=$pr_number" \
                "strategy=$merge_method"
        else
            warn "Auto-merge not available — falling back to direct merge"
            # Fall through to direct merge below
            auto_merge="false"
        fi
    fi

    if [[ "$auto_merge" != "true" ]]; then
        info "Merging PR #${pr_number} (method: ${merge_method})..."
        local merge_args=("pr" "merge" "$pr_number" "--${merge_method}")
        if [[ "$auto_delete_branch" == "true" ]]; then
            merge_args+=("--delete-branch")
        fi

        if gh "${merge_args[@]}" 2>/dev/null; then
            success "PR #${pr_number} merged successfully"
        else
            error "Failed to merge PR #${pr_number}"
            return 1
        fi
    fi

    log_stage "merge" "PR #${pr_number} merged (strategy: ${merge_method}, auto_merge: ${auto_merge})"
}

stage_deploy() {
    CURRENT_STAGE_ID="deploy"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-deploy.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _deploy_retry_hints
        _deploy_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi
    # Load deploy safety skills
    if type skill_load_prompts >/dev/null 2>&1; then
        local _deploy_skills
        _deploy_skills=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "deploy" 2>/dev/null || true)
        if [[ -n "$_deploy_skills" ]]; then
            echo "$_deploy_skills" > "${ARTIFACTS_DIR}/.deploy-safety-skills.md" 2>/dev/null || true
        fi
    fi
    local staging_cmd
    staging_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.staging_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$staging_cmd" == "null" ]] && staging_cmd=""

    local prod_cmd
    prod_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.production_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$prod_cmd" == "null" ]] && prod_cmd=""

    local rollback_cmd
    rollback_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.rollback_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$rollback_cmd" == "null" ]] && rollback_cmd=""

    if [[ -z "$staging_cmd" && -z "$prod_cmd" ]]; then
        warn "No deploy commands configured — skipping"
        return 0
    fi

    # Create GitHub deployment tracking
    local gh_deploy_env="production"
    [[ -n "$staging_cmd" && -z "$prod_cmd" ]] && gh_deploy_env="staging"
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_start >/dev/null 2>&1; then
        if [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            gh_deploy_pipeline_start "$REPO_OWNER" "$REPO_NAME" "${GIT_BRANCH:-HEAD}" "$gh_deploy_env" 2>/dev/null || true
            info "GitHub Deployment: tracking as $gh_deploy_env"
        fi
    fi

    # ── Pre-deploy gates ──
    local pre_deploy_ci
    pre_deploy_ci=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.pre_deploy_ci_status) // "true"' "$PIPELINE_CONFIG" 2>/dev/null) || true

    if [[ "${pre_deploy_ci:-true}" == "true" && "${NO_GITHUB:-false}" != "true" && -n "${REPO_OWNER:-}" && -n "${REPO_NAME:-}" ]]; then
        info "Pre-deploy gate: checking CI status..."
        local ci_failures
        ci_failures=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/commits/${GIT_BRANCH:-HEAD}/check-runs" \
            --jq '[.check_runs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped")] | length' 2>/dev/null || echo "0")
        if [[ "${ci_failures:-0}" -gt 0 ]]; then
            error "Pre-deploy gate FAILED: ${ci_failures} CI check(s) not passing"
            [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Pre-deploy gate: ${ci_failures} CI checks failing" 2>/dev/null || true
            return 1
        fi
        success "Pre-deploy gate: all CI checks passing"
    fi

    local pre_deploy_min_cov
    pre_deploy_min_cov=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.pre_deploy_min_coverage) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    if [[ -n "${pre_deploy_min_cov:-}" && "${pre_deploy_min_cov}" != "null" && -f "$ARTIFACTS_DIR/test-coverage.json" ]]; then
        local actual_cov
        actual_cov=$(jq -r '.coverage_pct // 0' "$ARTIFACTS_DIR/test-coverage.json" 2>/dev/null || echo "0")
        if [[ "${actual_cov:-0}" -lt "$pre_deploy_min_cov" ]]; then
            error "Pre-deploy gate FAILED: coverage ${actual_cov}% < required ${pre_deploy_min_cov}%"
            [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Pre-deploy gate: coverage ${actual_cov}% below minimum ${pre_deploy_min_cov}%" 2>/dev/null || true
            return 1
        fi
        success "Pre-deploy gate: coverage ${actual_cov}% >= ${pre_deploy_min_cov}%"
    fi

    # Post deploy start to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "Deploy started"
    fi

    # ── Deploy strategy ──
    local deploy_strategy
    deploy_strategy=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.deploy_strategy) // "direct"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$deploy_strategy" == "null" ]] && deploy_strategy="direct"

    local canary_cmd promote_cmd switch_cmd health_url deploy_log
    canary_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.canary_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$canary_cmd" == "null" ]] && canary_cmd=""
    promote_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.promote_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$promote_cmd" == "null" ]] && promote_cmd=""
    switch_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.switch_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$switch_cmd" == "null" ]] && switch_cmd=""
    health_url=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.health_url) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$health_url" == "null" ]] && health_url=""
    deploy_log="$ARTIFACTS_DIR/deploy.log"

    case "$deploy_strategy" in
        canary)
            info "Canary deployment strategy..."
            if [[ -z "$canary_cmd" ]]; then
                warn "No canary_cmd configured — falling back to direct"
                deploy_strategy="direct"
            else
                info "Deploying canary..."
                bash -c "$canary_cmd" >> "$deploy_log" 2>&1 || { error "Canary deploy failed"; return 1; }

                if [[ -n "$health_url" ]]; then
                    local canary_healthy=0
                    local _chk
                    for _chk in 1 2 3; do
                        sleep "$(_exponential_backoff "$_chk" 5 30)"
                        local _status
                        _status=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "0")
                        if [[ "$_status" -ge 200 && "$_status" -lt 400 ]]; then
                            canary_healthy=$((canary_healthy + 1))
                        fi
                    done
                    if [[ "$canary_healthy" -lt 2 ]]; then
                        error "Canary health check failed ($canary_healthy/3 passed) — rolling back"
                        [[ -n "$rollback_cmd" ]] && bash -c "$rollback_cmd" 2>/dev/null || true
                        return 1
                    fi
                    success "Canary healthy ($canary_healthy/3 checks passed)"
                fi

                info "Promoting canary to full deployment..."
                if [[ -n "$promote_cmd" ]]; then
                    bash -c "$promote_cmd" >> "$deploy_log" 2>&1 || { error "Promote failed"; return 1; }
                fi
                success "Canary promoted"
            fi
            ;;
        blue-green)
            info "Blue-green deployment strategy..."
            if [[ -z "$staging_cmd" || -z "$switch_cmd" ]]; then
                warn "Blue-green requires staging_cmd + switch_cmd — falling back to direct"
                deploy_strategy="direct"
            else
                info "Deploying to inactive environment..."
                bash -c "$staging_cmd" >> "$deploy_log" 2>&1 || { error "Blue-green staging failed"; return 1; }

                if [[ -n "$health_url" ]]; then
                    local bg_healthy=0
                    local _chk
                    for _chk in 1 2 3; do
                        sleep "$(_exponential_backoff "$_chk" 3 20)"
                        local _status
                        _status=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "0")
                        [[ "$_status" -ge 200 && "$_status" -lt 400 ]] && bg_healthy=$((bg_healthy + 1))
                    done
                    if [[ "$bg_healthy" -lt 2 ]]; then
                        error "Blue-green health check failed — not switching"
                        return 1
                    fi
                fi

                info "Switching traffic..."
                bash -c "$switch_cmd" >> "$deploy_log" 2>&1 || { error "Traffic switch failed"; return 1; }
                success "Blue-green switch complete"
            fi
            ;;
    esac

    # ── Direct deployment (default or fallback) ──
    if [[ "$deploy_strategy" == "direct" ]]; then
        if [[ -n "$staging_cmd" ]]; then
            info "Deploying to staging..."
            bash -c "$staging_cmd" > "$ARTIFACTS_DIR/deploy-staging.log" 2>&1 || {
                error "Staging deploy failed"
                [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Staging deploy failed"
                # Mark GitHub deployment as failed
                if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_complete >/dev/null 2>&1; then
                    gh_deploy_pipeline_complete "$REPO_OWNER" "$REPO_NAME" "$gh_deploy_env" false "Staging deploy failed" 2>/dev/null || true
                fi
                return 1
            }
            success "Staging deploy complete"
        fi

        if [[ -n "$prod_cmd" ]]; then
            info "Deploying to production..."
            bash -c "$prod_cmd" > "$ARTIFACTS_DIR/deploy-prod.log" 2>&1 || {
                error "Production deploy failed"
                if [[ -n "$rollback_cmd" ]]; then
                    warn "Rolling back..."
                    bash -c "$rollback_cmd" 2>&1 || error "Rollback also failed!"
                fi
                [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Production deploy failed — rollback ${rollback_cmd:+attempted}"
                # Mark GitHub deployment as failed
                if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_complete >/dev/null 2>&1; then
                    gh_deploy_pipeline_complete "$REPO_OWNER" "$REPO_NAME" "$gh_deploy_env" false "Production deploy failed" 2>/dev/null || true
                fi
                return 1
            }
            success "Production deploy complete"
        fi
    fi

    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "✅ **Deploy complete**"
        gh_add_labels "$ISSUE_NUMBER" "deployed"
    fi

    # Mark GitHub deployment as successful
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_complete >/dev/null 2>&1; then
        if [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            gh_deploy_pipeline_complete "$REPO_OWNER" "$REPO_NAME" "$gh_deploy_env" true "" 2>/dev/null || true
        fi
    fi

    log_stage "deploy" "Deploy complete"
}

