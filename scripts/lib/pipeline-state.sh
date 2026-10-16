# pipeline-state.sh — Pipeline state management (for sw-pipeline.sh)
# Source from sw-pipeline.sh. Requires SCRIPT_DIR, ARTIFACTS_DIR, and helpers.
[[ -n "${_PIPELINE_STATE_LOADED:-}" ]] && return 0
_PIPELINE_STATE_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
STAGE_STATUSES="${STAGE_STATUSES:-}"
STAGE_TIMINGS="${STAGE_TIMINGS:-}"
LOG_ENTRIES="${LOG_ENTRIES:-}"
ISSUE_NUMBER="${ISSUE_NUMBER:-}"
GOAL="${GOAL:-}"
PIPELINE_NAME="${PIPELINE_NAME:-pipeline}"
PIPELINE_STATUS="${PIPELINE_STATUS:-pending}"

save_artifact() {
    local name="$1" content="$2"
    mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
    echo "$content" > "$ARTIFACTS_DIR/$name"
}

get_stage_status() {
    local stage_id="$1"
    echo "$STAGE_STATUSES" | grep "^${stage_id}:" | cut -d: -f2 | tail -1 || true
}

set_stage_status() {
    local stage_id="$1" status="$2"
    STAGE_STATUSES=$(echo "$STAGE_STATUSES" | grep -v "^${stage_id}:" || true)
    STAGE_STATUSES="${STAGE_STATUSES}
${stage_id}:${status}"
}

# Per-stage timing
record_stage_start() {
    local stage_id="$1"
    STAGE_TIMINGS="${STAGE_TIMINGS}
${stage_id}_start:$(now_epoch)"
}

record_stage_end() {
    local stage_id="$1"
    STAGE_TIMINGS="${STAGE_TIMINGS}
${stage_id}_end:$(now_epoch)"
}

get_stage_timing() {
    local stage_id="$1"
    local start_e end_e
    start_e=$(echo "$STAGE_TIMINGS" | grep "^${stage_id}_start:" | cut -d: -f2 | tail -1 || true)
    end_e=$(echo "$STAGE_TIMINGS" | grep "^${stage_id}_end:" | cut -d: -f2 | tail -1 || true)
    if [[ -n "$start_e" && -n "$end_e" ]]; then
        format_duration $(( end_e - start_e ))
    elif [[ -n "$start_e" ]]; then
        format_duration $(( $(now_epoch) - start_e ))
    else
        echo ""
    fi
}

# Raw seconds for a stage (for memory baseline updates)
get_stage_timing_seconds() {
    local stage_id="$1"
    local start_e end_e
    start_e=$(echo "$STAGE_TIMINGS" | grep "^${stage_id}_start:" | cut -d: -f2 | tail -1 || true)
    end_e=$(echo "$STAGE_TIMINGS" | grep "^${stage_id}_end:" | cut -d: -f2 | tail -1 || true)
    if [[ -n "$start_e" && -n "$end_e" ]]; then
        echo $(( end_e - start_e ))
    elif [[ -n "$start_e" ]]; then
        echo $(( $(now_epoch) - start_e ))
    else
        echo "0"
    fi
}

# Name of the slowest completed stage (for pipeline.completed event)
get_slowest_stage() {
    local slowest="" max_sec=0
    local stage_ids
    stage_ids=$(echo "$STAGE_TIMINGS" | grep "_start:" | sed 's/_start:.*//' | sort -u)
    for sid in $stage_ids; do
        [[ -z "$sid" ]] && continue
        local sec
        sec=$(get_stage_timing_seconds "$sid")
        if [[ -n "$sec" && "$sec" =~ ^[0-9]+$ && "$sec" -gt "$max_sec" ]]; then
            max_sec="$sec"
            slowest="$sid"
        fi
    done
    echo "${slowest:-}"
}

get_stage_description() {
    local stage_id="$1"

    # Try to generate dynamic description from pipeline config
    if [[ -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-/dev/null}" ]]; then
        local stage_cfg
        stage_cfg=$(jq -c --arg id "$stage_id" '.stages[] | select(.id == $id) | .config // {}' "$PIPELINE_CONFIG" 2>/dev/null || echo "{}")
        case "$stage_id" in
            test)
                local cfg_test_cmd cfg_cov_min
                cfg_test_cmd=$(echo "$stage_cfg" | jq -r '.test_cmd // empty' 2>/dev/null || true)
                cfg_cov_min=$(echo "$stage_cfg" | jq -r '.coverage_min // empty' 2>/dev/null || true)
                if [[ -n "$cfg_test_cmd" ]]; then
                    echo "Running ${cfg_test_cmd}${cfg_cov_min:+ with ${cfg_cov_min}% coverage gate}"
                    return
                fi
                ;;
            build)
                local cfg_max_iter cfg_model
                cfg_max_iter=$(echo "$stage_cfg" | jq -r '.max_iterations // empty' 2>/dev/null || true)
                cfg_model=$(jq -r '.defaults.model // empty' "$PIPELINE_CONFIG" 2>/dev/null || true)
                if [[ -n "$cfg_max_iter" ]]; then
                    echo "Building with ${cfg_max_iter} max iterations${cfg_model:+ using ${cfg_model}}"
                    return
                fi
                ;;
            monitor)
                local cfg_dur cfg_thresh
                cfg_dur=$(echo "$stage_cfg" | jq -r '.duration_minutes // empty' 2>/dev/null || true)
                cfg_thresh=$(echo "$stage_cfg" | jq -r '.error_threshold // empty' 2>/dev/null || true)
                if [[ -n "$cfg_dur" ]]; then
                    echo "Monitoring for ${cfg_dur}m${cfg_thresh:+ (threshold: ${cfg_thresh} errors)}"
                    return
                fi
                ;;
        esac
    fi

    # Static fallback descriptions
    case "$stage_id" in
        intake)           echo "Extracting requirements and auto-detecting project setup" ;;
        plan)             echo "Creating implementation plan with architecture decisions" ;;
        design)           echo "Designing interfaces, data models, and API contracts" ;;
        build)            echo "Writing production code with self-healing iteration" ;;
        test)             echo "Running test suite and validating coverage" ;;
        review)           echo "Code quality, security audit, performance review" ;;
        compound_quality) echo "Adversarial testing, E2E validation, DoD checklist" ;;
        pr)               echo "Creating pull request with CI integration" ;;
        merge)            echo "Merging PR with branch cleanup" ;;
        deploy)           echo "Deploying to staging/production" ;;
        validate)         echo "Smoke tests and health checks post-deploy" ;;
        monitor)          echo "Production monitoring with auto-rollback" ;;
        *)                echo "" ;;
    esac
}

# Build inline stage progress string (e.g. "intake:complete plan:running test:pending")
build_stage_progress() {
    local progress=""
    local stages
    stages=$(jq -c '.stages[]' "$PIPELINE_CONFIG" 2>/dev/null) || return 0
    while IFS= read -r -u 3 stage; do
        local id enabled
        id=$(echo "$stage" | jq -r '.id' 2>/dev/null) || id=""
        enabled=$(echo "$stage" | jq -r '.enabled' 2>/dev/null) || enabled="false"
        [[ "$enabled" != "true" ]] && continue
        local sstatus
        sstatus=$(get_stage_status "$id")
        sstatus="${sstatus:-pending}"
        if [[ -n "$progress" ]]; then
            progress="${progress} ${id}:${sstatus}"
        else
            progress="${id}:${sstatus}"
        fi
    done 3<<< "$stages"
    echo "$progress"
}

update_status() {
    local status="$1" stage="$2"
    PIPELINE_STATUS="$status"
    CURRENT_STAGE="$stage"
    UPDATED_AT="$(now_iso)"
    write_state
}

mark_stage_complete() {
    local stage_id="$1"
    record_stage_end "$stage_id"
    set_stage_status "$stage_id" "complete"
    local timing
    timing=$(get_stage_timing "$stage_id")
    log_stage "$stage_id" "complete (${timing})"
    write_state

    record_stage_effectiveness "$stage_id" "complete"

    # Record stage completion in SQLite pipeline_stages table
    if type record_stage >/dev/null 2>&1; then
        local _stage_secs
        _stage_secs=$(get_stage_timing_seconds "$stage_id")
        record_stage "${SHIPWRIGHT_PIPELINE_ID:-}" "$stage_id" "complete" "${_stage_secs:-0}" "" 2>/dev/null || true
    fi

    # Record skill outcome for learning system
    if type skill_memory_record >/dev/null 2>&1; then
        local _used_skills
        _used_skills=$(skill_get_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "$stage_id" 2>/dev/null | xargs -I{} basename {} .md | tr '\n' ',' | sed 's/,$//')
        [[ -n "$_used_skills" ]] && skill_memory_record "${INTELLIGENCE_ISSUE_TYPE:-backend}" "$stage_id" "$_used_skills" "success" "1" 2>/dev/null || true
    fi

    # Update memory baselines and predictive baselines for stage durations
    if [[ "$stage_id" == "test" || "$stage_id" == "build" ]]; then
        local secs
        secs=$(get_stage_timing_seconds "$stage_id")
        if [[ -n "$secs" && "$secs" != "0" ]]; then
            [[ -x "$SCRIPT_DIR/sw-memory.sh" ]] && bash "$SCRIPT_DIR/sw-memory.sh" metric "${stage_id}_duration_s" "$secs" 2>/dev/null || true
            if [[ -x "$SCRIPT_DIR/sw-predictive.sh" ]]; then
                local anomaly_sev
                anomaly_sev=$(bash "$SCRIPT_DIR/sw-predictive.sh" anomaly "$stage_id" "duration_s" "$secs" 2>/dev/null || echo "normal")
                [[ "$anomaly_sev" == "critical" || "$anomaly_sev" == "warning" ]] && emit_event "pipeline.anomaly" "stage=$stage_id" "metric=duration_s" "value=$secs" "severity=$anomaly_sev" 2>/dev/null || true
                bash "$SCRIPT_DIR/sw-predictive.sh" baseline "$stage_id" "duration_s" "$secs" 2>/dev/null || true
            fi
        fi
    fi

    # Update GitHub progress comment
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_update_progress "$body"

        # Notify tracker (Linear/Jira) of stage completion
        local stage_desc
        stage_desc=$(get_stage_description "$stage_id")
        "$SCRIPT_DIR/sw-tracker.sh" notify "stage_complete" "$ISSUE_NUMBER" \
            "${stage_id}|${timing}|${stage_desc}" 2>/dev/null || true

        # Post structured stage event for CI sweep/retry intelligence
        ci_post_stage_event "$stage_id" "complete" "$timing"
    fi

    # Update GitHub Check Run for this stage
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_stage_update >/dev/null 2>&1; then
        gh_checks_stage_update "$stage_id" "completed" "success" "Stage $stage_id: ${timing}" 2>/dev/null || true
    fi

    # Persist artifacts to feature branch after expensive stages
    case "$stage_id" in
        plan)   persist_artifacts "plan" "plan.md" "dod.md" "context-bundle.md" ;;
        design) persist_artifacts "design" "design.md" ;;
    esac

    # Automatic checkpoint at every stage boundary (for crash recovery)
    if [[ -x "$SCRIPT_DIR/sw-checkpoint.sh" ]]; then
        local _cp_sha _cp_files
        _cp_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        _cp_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null | head -20 | tr '\n' ',' || true)
        bash "$SCRIPT_DIR/sw-checkpoint.sh" save \
            --stage "$stage_id" \
            --iteration "${SELF_HEAL_COUNT:-0}" \
            --git-sha "$_cp_sha" \
            --files-modified "${_cp_files:-}" \
            --tests-passing "${TEST_PASSED:-false}" 2>/dev/null || true
    fi

    # Durable WAL: publish stage completion event
    if type publish_event >/dev/null 2>&1; then
        publish_event "stage.complete" "{\"stage\":\"${stage_id}\",\"issue\":\"${ISSUE_NUMBER:-0}\",\"timing\":\"${timing}\"}" 2>/dev/null || true
    fi

    # Durable checkpoint: save to DB for pipeline resume
    if type db_save_checkpoint >/dev/null 2>&1; then
        local checkpoint_data
        checkpoint_data=$(jq -nc --arg stage "$stage_id" --arg status "${PIPELINE_STATUS:-running}" \
            --arg issue "${ISSUE_NUMBER:-}" --arg goal "${GOAL:-}" --arg template "${PIPELINE_TEMPLATE:-}" \
            '{stage: $stage, status: $status, issue: $issue, goal: $goal, template: $template, ts: "'"$(now_iso)"'"}')
        db_save_checkpoint "pipeline-${SHIPWRIGHT_PIPELINE_ID:-$$}" "$checkpoint_data" 2>/dev/null || true
    fi
}

persist_artifacts() {
    # Commit and push pipeline artifacts to the feature branch mid-pipeline.
    # Only runs in CI — local runs skip. Non-fatal: logs failure but never crashes.
    [[ "${CI_MODE:-false}" != "true" ]] && return 0
    [[ -z "${ISSUE_NUMBER:-}" ]] && return 0
    [[ -z "${ARTIFACTS_DIR:-}" ]] && return 0

    local stage="${1:-unknown}"
    shift
    local files=("$@")

    # Collect files that actually exist
    local to_add=()
    for f in "${files[@]}"; do
        local path="${ARTIFACTS_DIR}/${f}"
        if [[ -f "$path" && -s "$path" ]]; then
            to_add+=("$path")
        fi
    done

    if [[ ${#to_add[@]} -eq 0 ]]; then
        warn "persist_artifacts($stage): no artifact files found — skipping"
        return 0
    fi

    info "Persisting ${#to_add[@]} artifact(s) after stage ${stage}..."

    (
        git add "${to_add[@]}" 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "chore: persist ${stage} artifacts for #${ISSUE_NUMBER} [skip ci]" --no-verify 2>/dev/null || true
            local branch="shipwright/issue-${ISSUE_NUMBER}"
            git push origin "HEAD:refs/heads/$branch" --force 2>/dev/null || true
            emit_event "artifacts.persisted" "issue=${ISSUE_NUMBER}" "stage=$stage" "file_count=${#to_add[@]}"
        fi
    ) 2>/dev/null || {
        warn "persist_artifacts($stage): push failed — non-fatal, continuing"
        emit_event "artifacts.persist_failed" "issue=${ISSUE_NUMBER}" "stage=$stage"
    }

    return 0
}

verify_stage_artifacts() {
    # Check that required artifacts exist and are non-empty for a given stage.
    # Returns 0 if all artifacts are present, 1 if any are missing.
    local stage_id="$1"
    [[ -z "${ARTIFACTS_DIR:-}" ]] && return 0

    local required=()
    case "$stage_id" in
        plan)   required=("plan.md") ;;
        design) required=("design.md" "plan.md") ;;
        *)      return 0 ;;  # No artifact check needed
    esac

    local missing=0
    for f in "${required[@]}"; do
        local path="${ARTIFACTS_DIR}/${f}"
        if [[ ! -f "$path" || ! -s "$path" ]]; then
            warn "verify_stage_artifacts($stage_id): missing or empty: $f"
            missing=1
        fi
    done

    return "$missing"
}

# Self-aware pipeline: record stage effectiveness for meta-cognition
STAGE_EFFECTIVENESS_FILE="${HOME}/.shipwright/stage-effectiveness.jsonl"
record_stage_effectiveness() {
    local stage_id="$1" outcome="${2:-failed}"
    mkdir -p "${HOME}/.shipwright" 2>/dev/null || true
    { echo "{\"stage\":\"$stage_id\",\"outcome\":\"$outcome\",\"ts\":\"$(now_iso)\"}" >> "${STAGE_EFFECTIVENESS_FILE}"; } 2>/dev/null || true
    # Keep last 100 entries
    { tail -100 "${STAGE_EFFECTIVENESS_FILE}" > "${STAGE_EFFECTIVENESS_FILE}.tmp" && mv "${STAGE_EFFECTIVENESS_FILE}.tmp" "${STAGE_EFFECTIVENESS_FILE}"; } 2>/dev/null || true
}
get_stage_self_awareness_hint() {
    local stage_id="$1"
    [[ ! -f "$STAGE_EFFECTIVENESS_FILE" ]] && return 0
    local recent
    recent=$(grep "\"stage\":\"$stage_id\"" "$STAGE_EFFECTIVENESS_FILE" 2>/dev/null | tail -10 || true)
    [[ -z "$recent" ]] && return 0
    local failures=0 total=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        total=$((total + 1))
        echo "$line" | grep >/dev/null '"outcome":"failed"' && failures=$((failures + 1)) || true
    done <<< "$recent"
    if [[ "$total" -ge 3 ]] && [[ $((failures * 100 / total)) -ge 50 ]]; then
        case "$stage_id" in
            plan)  echo "Recent plan stage failures: consider adding more context or breaking the goal into smaller steps." ;;
            build) echo "Recent build stage failures: consider adding test expectations or simplifying the change." ;;
            *)     echo "Recent $stage_id failures: review past logs and adjust approach." ;;
        esac
    fi
}

mark_stage_failed() {
    local stage_id="$1"
    record_stage_end "$stage_id"
    record_stage_effectiveness "$stage_id" "failed"
    set_stage_status "$stage_id" "failed"
    local timing
    timing=$(get_stage_timing "$stage_id")
    log_stage "$stage_id" "failed (${timing})"
    write_state

    # Record stage failure in SQLite pipeline_stages table
    if type record_stage >/dev/null 2>&1; then
        local _stage_secs
        _stage_secs=$(get_stage_timing_seconds "$stage_id")
        record_stage "${SHIPWRIGHT_PIPELINE_ID:-}" "$stage_id" "failed" "${_stage_secs:-0}" "" 2>/dev/null || true
    fi

    # Record skill failure for learning system
    if type skill_memory_record >/dev/null 2>&1; then
        local _used_skills
        _used_skills=$(skill_get_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "$stage_id" 2>/dev/null | xargs -I{} basename {} .md | tr '\n' ',' | sed 's/,$//')
        [[ -n "$_used_skills" ]] && skill_memory_record "${INTELLIGENCE_ISSUE_TYPE:-backend}" "$stage_id" "$_used_skills" "failure" "1" 2>/dev/null || true
    fi

    # Update GitHub progress + comment failure
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_update_progress "$body"
        gh_comment_issue "$ISSUE_NUMBER" "❌ Pipeline failed at stage **${stage_id}** after ${timing}.

\`\`\`
$(tail -5 "$ARTIFACTS_DIR/${stage_id}"*.log 2>/dev/null || echo 'No log available')
\`\`\`"

        # Notify tracker (Linear/Jira) of stage failure
        local error_context
        error_context=$(tail -5 "$ARTIFACTS_DIR/${stage_id}"*.log 2>/dev/null || echo "No log")
        "$SCRIPT_DIR/sw-tracker.sh" notify "stage_failed" "$ISSUE_NUMBER" \
            "${stage_id}|${error_context}" 2>/dev/null || true

        # Post structured stage event for CI sweep/retry intelligence
        ci_post_stage_event "$stage_id" "failed" "$timing"
    fi

    # Update GitHub Check Run for this stage
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_stage_update >/dev/null 2>&1; then
        local fail_summary
        fail_summary=$(tail -3 "$ARTIFACTS_DIR/${stage_id}"*.log 2>/dev/null | head -c 500 || echo "Stage $stage_id failed")
        gh_checks_stage_update "$stage_id" "completed" "failure" "$fail_summary" 2>/dev/null || true
    fi

    # Save checkpoint on failure too (for crash recovery / resume)
    if [[ -x "$SCRIPT_DIR/sw-checkpoint.sh" ]]; then
        local _cp_sha
        _cp_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        bash "$SCRIPT_DIR/sw-checkpoint.sh" save \
            --stage "$stage_id" \
            --iteration "${SELF_HEAL_COUNT:-0}" \
            --git-sha "$_cp_sha" \
            --tests-passing "false" 2>/dev/null || true
    fi

    # Durable WAL: publish stage failure event
    if type publish_event >/dev/null 2>&1; then
        publish_event "stage.failed" "{\"stage\":\"${stage_id}\",\"issue\":\"${ISSUE_NUMBER:-0}\",\"timing\":\"${timing}\"}" 2>/dev/null || true
    fi
}

log_stage() {
    local stage_id="$1" message="$2"
    local timestamp
    timestamp=$(date +"%H:%M:%S")
    LOG_ENTRIES="${LOG_ENTRIES}
### ${stage_id} (${timestamp})
${message}
"
}

initialize_state() {
    PIPELINE_STATUS="running"
    PIPELINE_START_EPOCH="$(now_epoch)"
    STARTED_AT="$(now_iso)"
    UPDATED_AT="$(now_iso)"
    STAGE_STATUSES=""
    STAGE_TIMINGS=""
    LOG_ENTRIES=""
    # Clear per-run tracking files
    rm -f "$ARTIFACTS_DIR/model-routing.log" "$ARTIFACTS_DIR/.plan-failure-sig.txt"
    write_state
}

write_state() {
    [[ -z "${STATE_FILE:-}" || -z "${ARTIFACTS_DIR:-}" ]] && return 0
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

    # Check disk space before write (100MB minimum)
    if ! check_disk_space "$(dirname "$STATE_FILE")" 100; then
        error "Cannot write state: insufficient disk space"
        return 1
    fi
    local stages_yaml=""
    while IFS=: read -r sid sstatus; do
        [[ -z "$sid" ]] && continue
        stages_yaml="${stages_yaml}  ${sid}: ${sstatus}
"
    done <<< "$STAGE_STATUSES"

    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    # Stage description and progress for dashboard enrichment
    local cur_stage_desc=""
    if [[ -n "${CURRENT_STAGE:-}" ]]; then
        cur_stage_desc=$(get_stage_description "$CURRENT_STAGE")
    fi
    local stage_progress=""
    if [[ -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-/dev/null}" ]]; then
        stage_progress=$(build_stage_progress)
    fi

    cat > "$STATE_FILE" <<'_SW_STATE_END_'
---
_SW_STATE_END_
    # Write state with printf to avoid heredoc delimiter injection
    {
        printf 'pipeline: %s\n' "$PIPELINE_NAME"
        printf 'goal: "%s"\n' "$GOAL"
        printf 'status: %s\n' "$PIPELINE_STATUS"
        printf 'issue: "%s"\n' "${GITHUB_ISSUE:-}"
        printf 'branch: "%s"\n' "${GIT_BRANCH:-}"
        printf 'template: "%s"\n' "${TASK_TYPE:+$(template_for_type "$TASK_TYPE")}"
        printf 'current_stage: %s\n' "$CURRENT_STAGE"
        printf 'current_stage_description: "%s"\n' "${cur_stage_desc}"
        printf 'stage_progress: "%s"\n' "${stage_progress}"
        printf 'started_at: %s\n' "${STARTED_AT:-$(now_iso)}"
        printf 'updated_at: %s\n' "$(now_iso)"
        printf 'elapsed: %s\n' "${total_dur:-0s}"
        printf 'pr_number: %s\n' "${PR_NUMBER:-}"
        printf 'progress_comment_id: %s\n' "${PROGRESS_COMMENT_ID:-}"
        printf 'stages:\n'
        printf '%s' "${stages_yaml}"
        printf -- '---\n\n'
        printf '## Log\n'
        printf '%s\n' "$LOG_ENTRIES"
    } >> "$STATE_FILE"

    # Update pipeline_runs in DB
    if type update_pipeline_status >/dev/null 2>&1 && db_available 2>/dev/null; then
        local _job_id="${SHIPWRIGHT_PIPELINE_ID:-pipeline-$$-${ISSUE_NUMBER:-0}}"
        local _dur_secs=0
        if [[ -n "$PIPELINE_START_EPOCH" ]]; then
            _dur_secs=$(( $(now_epoch) - PIPELINE_START_EPOCH ))
        fi
        update_pipeline_status "$_job_id" "$PIPELINE_STATUS" "$CURRENT_STAGE" "" "$_dur_secs" 2>/dev/null || true
    fi
}

resume_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        error "No pipeline state found at $STATE_FILE"
        echo -e "  Start a new pipeline: ${DIM}shipwright pipeline start --goal \"...\"${RESET}"
        exit 1
    fi

    info "Resuming pipeline from $STATE_FILE"

    local in_frontmatter=false
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if $in_frontmatter; then break; else in_frontmatter=true; continue; fi
        fi
        if $in_frontmatter; then
            case "$line" in
                pipeline:*)            PIPELINE_NAME="$(echo "${line#pipeline:}" | xargs)" ;;
                goal:*)                GOAL="$(echo "${line#goal:}" | sed 's/^ *"//;s/" *$//')" ;;
                status:*)              PIPELINE_STATUS="$(echo "${line#status:}" | xargs)" ;;
                issue:*)               GITHUB_ISSUE="$(echo "${line#issue:}" | sed 's/^ *"//;s/" *$//')" ;;
                branch:*)              GIT_BRANCH="$(echo "${line#branch:}" | sed 's/^ *"//;s/" *$//')" ;;
                current_stage:*)       CURRENT_STAGE="$(echo "${line#current_stage:}" | xargs)" ;;
                current_stage_description:*) ;; # computed field — skip on resume
                stage_progress:*)      ;; # computed field — skip on resume
                started_at:*)          STARTED_AT="$(echo "${line#started_at:}" | xargs)" ;;
                pr_number:*)           PR_NUMBER="$(echo "${line#pr_number:}" | xargs)" ;;
                progress_comment_id:*) PROGRESS_COMMENT_ID="$(echo "${line#progress_comment_id:}" | xargs)" ;;
                "  "*)
                    local trimmed
                    trimmed="$(echo "$line" | xargs)"
                    if [[ "$trimmed" == *":"* ]]; then
                        local sid="${trimmed%%:*}"
                        local sst="${trimmed#*: }"
                        [[ -n "$sid" && "$sid" != "stages" ]] && STAGE_STATUSES="${STAGE_STATUSES}
${sid}:${sst}"
                    fi
                    ;;
            esac
        fi
    done < "$STATE_FILE"

    LOG_ENTRIES="$(sed -n '/^## Log$/,$ { /^## Log$/d; p; }' "$STATE_FILE" 2>/dev/null || true)"

    if [[ -n "$GITHUB_ISSUE" && "$GITHUB_ISSUE" =~ ^#([0-9]+)$ ]]; then
        ISSUE_NUMBER="${BASH_REMATCH[1]}"
    fi

    if [[ -z "$GOAL" ]]; then
        error "Could not parse goal from state file."
        exit 1
    fi

    if [[ "$PIPELINE_STATUS" == "complete" ]]; then
        warn "Pipeline already completed. Start a new one."
        exit 0
    fi

    if [[ "$PIPELINE_STATUS" == "aborted" ]]; then
        warn "Pipeline was aborted. Start a new one or edit the state file."
        exit 0
    fi

    if [[ "$PIPELINE_STATUS" == "interrupted" ]]; then
        info "Resuming from interruption..."
    fi

    if [[ -n "$GIT_BRANCH" ]]; then
        git checkout "$GIT_BRANCH" 2>/dev/null || true
    fi

    PIPELINE_START_EPOCH="$(now_epoch)"
    gh_init
    load_pipeline_config
    PIPELINE_STATUS="running"
    success "Resumed pipeline: ${BOLD}$PIPELINE_NAME${RESET} — stage: $CURRENT_STAGE"
}

# ─── Task Type Detection ───────────────────────────────────────────────────

