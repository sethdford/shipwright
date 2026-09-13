# daemon-poll-github.sh — GitHub API polling for daemon-poll.sh
# Source from daemon-poll.sh. Requires daemon-health, state, dispatch, failure, patrol.
[[ -n "${_DAEMON_POLL_GITHUB_LOADED:-}" ]] && return 0
_DAEMON_POLL_GITHUB_LOADED=1

# Defaults for variables normally set by sw-daemon.sh (safe under set -u).
DAEMON_DIR="${DAEMON_DIR:-${HOME}/.shipwright}"
STATE_FILE="${STATE_FILE:-${DAEMON_DIR}/daemon-state.json}"
PAUSE_FLAG="${PAUSE_FLAG:-${DAEMON_DIR}/daemon-pause.flag}"
SHUTDOWN_FLAG="${SHUTDOWN_FLAG:-${DAEMON_DIR}/daemon.shutdown}"
EVENTS_FILE="${EVENTS_FILE:-${DAEMON_DIR}/events.jsonl}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NO_GITHUB="${NO_GITHUB:-false}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
WATCH_LABEL="${WATCH_LABEL:-shipwright}"
WATCH_MODE="${WATCH_MODE:-repo}"
PIPELINE_TEMPLATE="${PIPELINE_TEMPLATE:-autonomous}"
ISSUE_LIMIT="${ISSUE_LIMIT:-100}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
BACKOFF_SECS="${BACKOFF_SECS:-0}"
POLL_CYCLE_COUNT="${POLL_CYCLE_COUNT:-0}"

# daemon_quarantine_if_synthetic <issue_json> <issue_key> <issue_num> <score>
#   Routes an auto-generated issue into the synthetic lane.
#   exit 0 → quarantined, caller must skip the issue
#   exit 1 → real work (also the answer when the classifier is unavailable or
#            the issue JSON could not be extracted — failing open toward "real"
#            wastes a slot, failing the other way silently buries real work)
daemon_quarantine_if_synthetic() {
    local issue_json="${1:-}" issue_key="${2:-}" issue_num="${3:-}" score="${4:-0}"

    [[ -n "$issue_json" ]] || return 1
    type is_synthetic_issue >/dev/null 2>&1 || return 1

    local synthetic_pattern
    synthetic_pattern=$(is_synthetic_issue "$issue_json" 2>/dev/null || true)
    [[ -n "$synthetic_pattern" ]] || return 1

    daemon_log INFO "Issue #${issue_num} matched synthetic pattern '${synthetic_pattern}' — quarantining"
    emit_event "daemon.issue_quarantined" "issue=$issue_num" "pattern=$synthetic_pattern" "score=$score"
    enqueue_issue "$issue_key" synthetic
    return 0
}

daemon_poll_issues() {
    if [[ "$NO_GITHUB" == "true" ]]; then
        daemon_log INFO "Polling skipped (--no-github)"
        return
    fi

    # Check for pause flag (set by dashboard, disk_low, or consecutive-failure backoff)
    local pause_file="${PAUSE_FLAG:-$HOME/.shipwright/daemon-pause.flag}"
    if [[ -f "$pause_file" ]]; then
        local resume_after
        resume_after=$(jq -r '.resume_after // empty' "$pause_file" 2>/dev/null || true)
        if [[ -n "$resume_after" ]]; then
            local now_epoch resume_epoch
            now_epoch=$(date +%s)
            resume_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$resume_after" +%s 2>/dev/null || \
                date -d "$resume_after" +%s 2>/dev/null || echo 0)
            if [[ "$resume_epoch" -gt 0 ]] && [[ "$now_epoch" -ge "$resume_epoch" ]]; then
                rm -f "$pause_file"
                daemon_log INFO "Auto-resuming after backoff (resume_after passed)"
            else
                daemon_log INFO "Daemon paused until ${resume_after} — skipping poll"
                return
            fi
        else
            daemon_log INFO "Daemon paused — skipping poll"
            return
        fi
    fi

    # Circuit breaker: skip poll if in backoff window
    if gh_rate_limited; then
        daemon_log INFO "Polling skipped (rate-limit backoff until $(epoch_to_iso "$GH_BACKOFF_UNTIL"))"
        return
    fi

    local issues_json

    # Select gh command wrapper: gh_retry for critical poll calls when enabled
    local gh_cmd="gh"
    if [[ "${GH_RETRY_ENABLED:-true}" == "true" ]]; then
        gh_cmd="gh_retry gh"
    fi

    if [[ "$WATCH_MODE" == "org" && -n "$ORG" ]]; then
        # Org-wide mode: search issues across all org repos
        issues_json=$($gh_cmd search issues \
            --label "$WATCH_LABEL" \
            --owner "$ORG" \
            --state open \
            --json repository,number,title,labels,body,createdAt \
            --limit "${ISSUE_LIMIT:-100}" 2>/dev/null) || {
            # Handle rate limiting with exponential backoff
            if [[ $BACKOFF_SECS -eq 0 ]]; then
                BACKOFF_SECS=30
            elif [[ $BACKOFF_SECS -lt 300 ]]; then
                BACKOFF_SECS=$((BACKOFF_SECS * 2))
                if [[ $BACKOFF_SECS -gt 300 ]]; then
                    BACKOFF_SECS=300
                fi
            fi
            daemon_log WARN "GitHub API error (org search) — backing off ${BACKOFF_SECS}s"
            gh_record_failure
            sleep "$BACKOFF_SECS"
            return
        }

        # Filter by repo_filter regex if set
        if [[ -n "$REPO_FILTER" ]]; then
            issues_json=$(echo "$issues_json" | jq -c --arg filter "$REPO_FILTER" \
                '[.[] | select(.repository.nameWithOwner | test($filter))]')
        fi
    else
        # Standard single-repo mode
        issues_json=$($gh_cmd issue list \
            --label "$WATCH_LABEL" \
            --state open \
            --json number,title,labels,body,createdAt \
            --limit 100 2>/dev/null) || {
            # Handle rate limiting with exponential backoff
            if [[ $BACKOFF_SECS -eq 0 ]]; then
                BACKOFF_SECS=30
            elif [[ $BACKOFF_SECS -lt 300 ]]; then
                BACKOFF_SECS=$((BACKOFF_SECS * 2))
                if [[ $BACKOFF_SECS -gt 300 ]]; then
                    BACKOFF_SECS=300
                fi
            fi
            daemon_log WARN "GitHub API error — backing off ${BACKOFF_SECS}s"
            gh_record_failure
            sleep "$BACKOFF_SECS"
            return
        }
    fi

    # Reset backoff on success
    BACKOFF_SECS=0
    gh_record_success

    local issue_count
    issue_count=$(echo "$issues_json" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$issue_count" -eq 0 ]]; then
        return
    fi

    local mode_label="repo"
    [[ "$WATCH_MODE" == "org" ]] && mode_label="org:${ORG}"
    daemon_log INFO "Found ${issue_count} issue(s) with label '${WATCH_LABEL}' (${mode_label})"
    emit_event "daemon.poll" "issues_found=$issue_count" "active=$(get_active_count)" "mode=$WATCH_MODE"

    # Score each issue using intelligent triage and sort by descending score
    local scored_issues=()
    local dep_graph=""  # "issue:dep1,dep2" entries for dependency ordering
    while IFS= read -r issue; do
        local num score
        num=$(echo "$issue" | jq -r '.number')
        score=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
        score=$(printf '%s' "$score" | tr -cd '[:digit:]')
        [[ -z "$score" ]] && score=50
        # For org mode, include repo name in the scored entry
        local repo_name=""
        if [[ "$WATCH_MODE" == "org" ]]; then
            repo_name=$(echo "$issue" | jq -r '.repository.nameWithOwner // ""')
        fi
        scored_issues+=("${score}|${num}|${repo_name}")

        # Issue dependency detection (adaptive: extract "depends on #X", "blocked by #X")
        if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" == "true" ]]; then
            local issue_text
            issue_text=$(echo "$issue" | jq -r '(.title // "") + " " + (.body // "")')
            local deps
            deps=$(extract_issue_dependencies "$issue_text")
            if [[ -n "$deps" ]]; then
                local dep_nums
                dep_nums=$(echo "$deps" | tr -d '#' | tr '\n' ',' | sed 's/,$//')
                dep_graph="${dep_graph}${num}:${dep_nums}\n"
                daemon_log INFO "Issue #${num} depends on: ${deps//$'\n'/, }"
            fi
        fi
    done < <(echo "$issues_json" | jq -c '.[]')

    # Sort by score — strategy determines ascending vs descending
    local sorted_order
    if [[ "${PRIORITY_STRATEGY:-quick-wins-first}" == "complex-first" ]]; then
        # Complex-first: lower score (more complex) first
        sorted_order=$(printf '%s\n' "${scored_issues[@]}" | sort -t'|' -k1,1 -n -k2,2 -n)
    else
        # Quick-wins-first (default): higher score (simpler) first, lowest issue# first on ties
        sorted_order=$(printf '%s\n' "${scored_issues[@]}" | sort -t'|' -k1,1 -rn -k2,2 -n)
    fi

    # Dependency-aware reordering: move dependencies before dependents
    if [[ -n "$dep_graph" && "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" == "true" ]]; then
        local reordered=""
        local scheduled=""
        # Multiple passes to resolve transitive dependencies (max 3)
        local pass=0
        while [[ $pass -lt 3 ]]; do
            local changed=false
            local new_order=""
            while IFS='|' read -r s_score s_num s_repo; do
                [[ -z "$s_num" ]] && continue
                # Check if this issue has unscheduled dependencies
                local issue_deps
                issue_deps=$(echo -e "$dep_graph" | grep "^${s_num}:" | head -1 | cut -d: -f2 || true)
                if [[ -n "$issue_deps" ]]; then
                    # Check if all deps are scheduled (or not in our issue set)
                    local all_deps_ready=true
                    local IFS_SAVE="$IFS"
                    IFS=','
                    for dep in $issue_deps; do
                        dep="${dep## }"
                        dep="${dep%% }"
                        # Is this dep in our scored set and not yet scheduled?
                        if echo "$sorted_order" | grep -q "|${dep}|" && ! echo "$scheduled" | grep -q "|${dep}|"; then
                            all_deps_ready=false
                            break
                        fi
                    done
                    IFS="$IFS_SAVE"
                    if [[ "$all_deps_ready" == "false" ]]; then
                        # Defer this issue — append at end
                        new_order="${new_order}${s_score}|${s_num}|${s_repo}\n"
                        changed=true
                        continue
                    fi
                fi
                reordered="${reordered}${s_score}|${s_num}|${s_repo}\n"
                scheduled="${scheduled}|${s_num}|"
            done <<< "$sorted_order"
            # Append deferred issues
            reordered="${reordered}${new_order}"
            sorted_order=$(echo -e "$reordered" | grep -v '^$')
            reordered=""
            scheduled=""
            if [[ "$changed" == "false" ]]; then
                break
            fi
            pass=$((pass + 1))
        done
    fi

    local active_count
    active_count=$(locked_get_active_count)

    # Process each issue in triage order (process substitution keeps state in current shell)
    while IFS='|' read -r score issue_num repo_name; do
        [[ -z "$issue_num" ]] && continue

        local issue_key
        issue_key="$issue_num"
        [[ -n "$repo_name" ]] && issue_key="${repo_name}:${issue_num}"

        local issue_title labels_csv
        issue_title=$(echo "$issues_json" | jq -r --argjson n "$issue_num" --arg repo "$repo_name" '.[] | select(.number == $n) | select($repo == "" or (.repository.nameWithOwner // "") == $repo) | .title')
        labels_csv=$(echo "$issues_json" | jq -r --argjson n "$issue_num" --arg repo "$repo_name" '.[] | select(.number == $n) | select($repo == "" or (.repository.nameWithOwner // "") == $repo) | [.labels[].name] | join(",")')

        # Cache title in state for dashboard visibility (use issue_key for org mode)
        if [[ -n "$issue_title" ]]; then
            locked_state_update --arg num "$issue_key" --arg title "$issue_title" \
                '.titles[$num] = $title'
        fi

        # Skip if already inflight
        if daemon_is_inflight "$issue_key"; then
            continue
        fi

        # Quarantine auto-generated noise into the synthetic lane before it can
        # consume a MAX_PARALLEL slot, a priority-lane slot, or a machine claim.
        # It is drained by dequeue_next only once the standard queue is empty.
        local issue_full_json
        issue_full_json=$(echo "$issues_json" | jq -c --argjson n "$issue_num" --arg repo "$repo_name" \
            'map(select(.number == $n) | select($repo == "" or (.repository.nameWithOwner // "") == $repo)) | .[0] // empty' 2>/dev/null || true)
        if daemon_quarantine_if_synthetic "$issue_full_json" "$issue_key" "$issue_num" "$score"; then
            continue
        fi

        # Distributed claim (skip if no machines registered)
        if [[ -f "$HOME/.shipwright/machines.json" ]]; then
            local machine_name
            machine_name=$(jq -r '.machines[] | select(.role == "primary") | .name' "$HOME/.shipwright/machines.json" 2>/dev/null || hostname -s)
            if ! claim_issue "$issue_num" "$machine_name"; then
                daemon_log INFO "Issue #${issue_num} claimed by another machine — skipping"
                continue
            fi
        fi

        # Priority lane: bypass queue for critical issues
        if [[ "$PRIORITY_LANE" == "true" ]]; then
            local priority_active
            priority_active=$(get_priority_active_count)
            if is_priority_issue "$labels_csv" && [[ "$priority_active" -lt "$PRIORITY_LANE_MAX" ]]; then
                daemon_log WARN "PRIORITY LANE: issue #${issue_num} bypassing queue (${labels_csv})"
                emit_event "daemon.priority_lane" "issue=$issue_num" "score=$score"

                local template
                template=$(select_pipeline_template "$labels_csv" "$score" 2>/dev/null | tail -1)
                template=$(printf '%s' "$template" | sed $'s/\x1b\\[[0-9;]*m//g' | tr -cd '[:alnum:]-_')
                [[ -z "$template" ]] && template="$PIPELINE_TEMPLATE"
                daemon_log INFO "Triage: issue #${issue_num} scored ${score}, template=${template} [PRIORITY]"

                local orig_template="$PIPELINE_TEMPLATE"
                PIPELINE_TEMPLATE="$template"
                daemon_spawn_pipeline "$issue_num" "$issue_title" "$repo_name"
                PIPELINE_TEMPLATE="$orig_template"
                track_priority_job "$issue_num"
                continue
            fi
        fi

        # Check capacity
        active_count=$(locked_get_active_count)
        if [[ "$active_count" -ge "$MAX_PARALLEL" ]]; then
            enqueue_issue "$issue_key"
            continue
        fi

        # Auto-select pipeline template: PM recommendation (if available) else labels + triage score
        local template
        if [[ "$NO_GITHUB" != "true" ]] && [[ -x "$SCRIPT_DIR/sw-pm.sh" ]]; then
            local pm_rec
            pm_rec=$(bash "$SCRIPT_DIR/sw-pm.sh" recommend --json "$issue_num" 2>/dev/null) || true
            if [[ -n "$pm_rec" ]]; then
                template=$(echo "$pm_rec" | jq -r '.team_composition.template // empty' 2>/dev/null) || true
                # Capability self-assessment: low confidence → upgrade to full template
                local confidence
                confidence=$(echo "$pm_rec" | jq -r '.team_composition.confidence_percent // 100' 2>/dev/null) || true
                if [[ -n "$confidence" && "$confidence" != "null" && "$confidence" -lt 60 ]]; then
                    daemon_log INFO "Low PM confidence (${confidence}%) — upgrading to full template"
                    template="full"
                fi
            fi
        fi
        if [[ -z "$template" ]]; then
            template=$(select_pipeline_template "$labels_csv" "$score" 2>/dev/null | tail -1)
        fi
        template=$(printf '%s' "$template" | sed $'s/\x1b\\[[0-9;]*m//g' | tr -cd '[:alnum:]-_')
        [[ -z "$template" ]] && template="$PIPELINE_TEMPLATE"
        daemon_log INFO "Triage: issue #${issue_num} scored ${score}, template=${template}"

        # Spawn pipeline (template selection applied via PIPELINE_TEMPLATE override)
        local orig_template="$PIPELINE_TEMPLATE"
        PIPELINE_TEMPLATE="$template"
        daemon_spawn_pipeline "$issue_num" "$issue_title" "$repo_name"
        PIPELINE_TEMPLATE="$orig_template"

        # Stagger delay between spawns to avoid API contention
        local stagger_delay="${SPAWN_STAGGER_SECONDS:-15}"
        if [[ "$stagger_delay" -gt 0 ]]; then
            sleep "$stagger_delay"
        fi
    done <<< "$sorted_order"

    # ── Drain queue if we have capacity (prevents deadlock when queue is
    #    populated but no active jobs exist to trigger dequeue) ──
    local drain_active
    drain_active=$(locked_get_active_count)
    while [[ "$drain_active" -lt "$MAX_PARALLEL" ]]; do
        local drain_issue_key
        drain_issue_key=$(dequeue_next)
        [[ -z "$drain_issue_key" ]] && break
        local drain_issue_num="$drain_issue_key" drain_repo=""
        [[ "$drain_issue_key" == *:* ]] && drain_repo="${drain_issue_key%%:*}" && drain_issue_num="${drain_issue_key##*:}"
        local drain_title
        drain_title=$(jq -r --arg n "$drain_issue_key" '.titles[$n] // ""' "$STATE_FILE" 2>/dev/null || true)

        local drain_labels drain_score drain_template
        drain_labels=$(echo "$issues_json" | jq -r --argjson n "$drain_issue_num" --arg repo "$drain_repo" \
            '.[] | select(.number == $n) | select($repo == "" or (.repository.nameWithOwner // "") == $repo) | [.labels[].name] | join(",")' 2>/dev/null || echo "")
        drain_score=$(echo "$sorted_order" | grep "|${drain_issue_num}|" | cut -d'|' -f1 || echo "50")
        drain_template=$(select_pipeline_template "$drain_labels" "${drain_score:-50}" 2>/dev/null | tail -1)
        drain_template=$(printf '%s' "$drain_template" | sed $'s/\x1b\\[[0-9;]*m//g' | tr -cd '[:alnum:]-_')
        [[ -z "$drain_template" ]] && drain_template="$PIPELINE_TEMPLATE"

        daemon_log INFO "Draining queue: issue #${drain_issue_num}${drain_repo:+, repo=${drain_repo}}, template=${drain_template}"
        local orig_template="$PIPELINE_TEMPLATE"
        PIPELINE_TEMPLATE="$drain_template"
        daemon_spawn_pipeline "$drain_issue_num" "$drain_title" "$drain_repo"
        PIPELINE_TEMPLATE="$orig_template"
        drain_active=$(locked_get_active_count)
    done

    # Update last poll
    update_state_field "last_poll" "$(now_iso)"
}

# ─── Health Check ─────────────────────────────────────────────────────────────
