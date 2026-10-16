# daemon-poll-github.sh — GitHub API polling for daemon-poll.sh
# Source from daemon-poll.sh. Requires daemon-health, state, dispatch, failure, patrol.
[[ -n "${_DAEMON_POLL_GITHUB_LOADED:-}" ]] && return 0
_DAEMON_POLL_GITHUB_LOADED=1
# shellcheck source=safety-gates.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety-gates.sh"

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

# _poll_release_claim <issue> — gives back a distributed claim (taken only when machines.json
# exists), resolving the machine name the same way the claim and the reaper do.
_poll_release_claim() {
    local issue_num="$1"
    [[ -f "$HOME/.shipwright/machines.json" ]] || return 0
    local machine_name
    machine_name=$(jq -r '.machines[] | select(.role == "primary") | .name' "$HOME/.shipwright/machines.json" 2>/dev/null || hostname -s)
    release_claim "$issue_num" "$machine_name" || true
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

    # ── Safety gates (ADR-0007): once per cycle, before any listing, claim or spawn ──
    # daemon_spawn_pipeline checks again per spawn (with the issue's retry count).
    local cycle_gate_rc=0
    safety_gates_ok 0 || cycle_gate_rc=$?
    if [[ "$cycle_gate_rc" -ne 0 ]]; then
        daemon_log WARN "Safety gates closed (rc=${cycle_gate_rc}) — skipping dispatch this poll cycle"
        emit_event "daemon.poll_gates_closed" "rc=${cycle_gate_rc}"
        update_state_field "last_poll" "$(now_iso)"
        return 0
    fi

    local issues_json
    # list_limit: --limit of the listing. A listing that reached it may be truncated, so an
    # issue missing from it is "unknown", not "gone".
    local list_limit=100 raw_count=""

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

        list_limit="${ISSUE_LIMIT:-100}"
        raw_count=$(echo "$issues_json" | jq 'length' 2>/dev/null || echo "")

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
            --limit "$list_limit" 2>/dev/null) || {
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
    issue_count=$(echo "$issues_json" | jq 'length' 2>/dev/null || echo "")
    [[ -z "$raw_count" ]] && raw_count="$issue_count"

    # Complete listing: readable, non-empty and below the limit. Only then does absence from it
    # mean an issue no longer carries the watch label.
    local listing_complete=false
    if [[ "$issue_count" =~ ^[0-9]+$ && "$raw_count" =~ ^[0-9]+$ ]] \
        && [[ "$issue_count" -gt 0 && "$raw_count" -lt "$list_limit" ]]; then
        listing_complete=true
    fi

    # Finally-failed entries (daemon-failure.sh) are also cleared once the watch label is gone,
    # so a human re-adding it makes the issue dispatchable again.
    if [[ "$listing_complete" == "true" ]]; then
        local present_json
        present_json=$(echo "$issues_json" | jq -c '[.[].number | tostring]' 2>/dev/null) || present_json=""
        if [[ -n "$present_json" ]] && \
            [[ "$(jq -r '(.final_failed // {}) | length' "$STATE_FILE" 2>/dev/null || echo 0)" != "0" ]]; then
            locked_state_update --argjson present "$present_json" \
                '.final_failed = ((.final_failed // {}) | with_entries(select(.key as $k | $present | index($k))))'
        fi
    fi

    if [[ ! "$issue_count" =~ ^[0-9]+$ ]] || [[ "$issue_count" -eq 0 ]]; then
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
                        if echo "$sorted_order" | grep >/dev/null "|${dep}|" && ! echo "$scheduled" | grep >/dev/null "|${dep}|"; then
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
    local cycle_refused=false

    # Process each issue in triage order (process substitution keeps state in current shell)
    while IFS='|' read -r score issue_num repo_name; do
        [[ -z "$issue_num" ]] && continue

        local issue_key
        issue_key="$issue_num"
        [[ -n "$repo_name" ]] && issue_key="${repo_name}:${issue_num}"

        local issue_title labels_csv
        issue_title=$(echo "$issues_json" | jq -r --argjson n "$issue_num" --arg repo "$repo_name" '.[] | select(.number == $n) | select($repo == "" or (.repository.nameWithOwner // "") == $repo) | .title')
        labels_csv=$(echo "$issues_json" | jq -r --argjson n "$issue_num" --arg repo "$repo_name" '.[] | select(.number == $n) | select($repo == "" or (.repository.nameWithOwner // "") == $repo) | [.labels[].name] | join(",")') || labels_csv=""

        # Cache title in state for dashboard visibility (use issue_key for org mode)
        if [[ -n "$issue_title" ]]; then
            locked_state_update --arg num "$issue_key" --arg title "$issue_title" \
                '.titles[$num] = $title'
        fi

        # Skip if already inflight
        if daemon_is_inflight "$issue_key"; then
            continue
        fi

        # Finally failed but the watch label could not be removed (daemon-failure.sh): skip it
        # while any label we marked it with is still on it. Once a human removed every marked
        # label, the entry is cleared and the issue is dispatchable. An entry with nothing marked
        # (or an unreadable one) stays until the watch label is gone (ADR-0007).
        if jq -e --arg n "$issue_num" '(.final_failed // {}) | has($n)' "$STATE_FILE" >/dev/null 2>&1; then
            local ff_cleared
            ff_cleared=$(jq -r --arg n "$issue_num" --arg labels "$labels_csv" '
                (.final_failed[$n].marked? // []) as $m
                | ($labels | ascii_downcase | split(",")) as $have
                | if ($m | type) == "array" and ($m | length) > 0
                     and ([$m[] | ascii_downcase | select(. as $x | $have | index($x))] | length) == 0
                  then "yes" else "no" end' "$STATE_FILE" 2>/dev/null || echo "no")
            if [[ "$ff_cleared" == "yes" && -n "$labels_csv" ]]; then
                locked_state_update --arg n "$issue_num" 'del(.final_failed[$n])'
                daemon_log INFO "Issue #${issue_num}: failure labels removed by a human — dispatchable again"
            else
                daemon_log INFO "Issue #${issue_num} failed finally — skipped until its failure labels or '${WATCH_LABEL}' are removed"
                continue
            fi
        fi

        # Auto-filed and stuck issues wait for a human to remove the label (ADR-0007).
        # Polled issues always carry the watch label, so empty or unreadable labels are skipped.
        if [[ -z "$labels_csv" ]] || ! dispatch_eligible "$labels_csv"; then
            daemon_log INFO "Issue #${issue_num} skipped: auto-filed, stuck or labels unreadable (a human removes '${PATROL_LABEL:-auto-patrol}' / 'shipwright-stuck' to opt in)"
            continue
        fi

        # Distributed claim (skip if no machines registered)
        local claimed_machine=""
        if [[ -f "$HOME/.shipwright/machines.json" ]]; then
            local machine_name
            machine_name=$(jq -r '.machines[] | select(.role == "primary") | .name' "$HOME/.shipwright/machines.json" 2>/dev/null || hostname -s)
            if ! claim_issue "$issue_num" "$machine_name"; then
                daemon_log INFO "Issue #${issue_num} claimed by another machine — skipping"
                continue
            fi
            claimed_machine="$machine_name"
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
                local priority_rc=0
                daemon_spawn_pipeline "$issue_num" "$issue_title" "$repo_name" || priority_rc=$?
                PIPELINE_TEMPLATE="$orig_template"
                if [[ "$priority_rc" -eq 0 ]]; then
                    track_priority_job "$issue_num"
                    continue
                fi
                if [[ -n "$claimed_machine" ]]; then
                    release_claim "$issue_num" "$claimed_machine"
                fi
                if [[ "$priority_rc" -eq "${DAEMON_SPAWN_REFUSED:-75}" ]]; then
                    cycle_refused=true
                    break
                fi
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
        local template=""
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
        local spawn_rc=0
        daemon_spawn_pipeline "$issue_num" "$issue_title" "$repo_name" || spawn_rc=$?
        PIPELINE_TEMPLATE="$orig_template"
        if [[ "$spawn_rc" -ne 0 ]]; then
            # Refused: give the claim back, no stagger. A system-wide refusal (gates, budget)
            # ends the cycle: nothing more is claimed, spawned or drained.
            if [[ -n "$claimed_machine" ]]; then
                release_claim "$issue_num" "$claimed_machine"
            fi
            if [[ "$spawn_rc" -eq "${DAEMON_SPAWN_REFUSED:-75}" ]]; then
                cycle_refused=true
                break
            fi
            continue
        fi

        # Stagger delay between spawns to avoid API contention
        local stagger_delay="${SPAWN_STAGGER_SECONDS:-15}"
        if [[ "$stagger_delay" -gt 0 ]]; then
            sleep "$stagger_delay"
        fi
    done <<< "$sorted_order"

    # ── Drain queue if we have capacity (prevents deadlock when queue is
    #    populated but no active jobs exist to trigger dequeue) ──
    # Each queued entry is looked at most once per cycle (re-queued entries go to the tail).
    local drain_active drain_budget=0
    drain_active=$(locked_get_active_count)
    if [[ "$cycle_refused" != "true" ]]; then
        drain_budget=$(jq -r '(.queued // []) | length' "$STATE_FILE" 2>/dev/null || echo 0)
        [[ "$drain_budget" =~ ^[0-9]+$ ]] || drain_budget=0
    fi
    while [[ "$drain_active" -lt "$MAX_PARALLEL" && "$drain_budget" -gt 0 ]]; do
        drain_budget=$((drain_budget - 1))
        local drain_issue_key
        drain_issue_key=$(dequeue_next)
        [[ -z "$drain_issue_key" ]] && break
        local drain_issue_num="$drain_issue_key" drain_repo=""
        [[ "$drain_issue_key" == *:* ]] && drain_repo="${drain_issue_key%%:*}" && drain_issue_num="${drain_issue_key##*:}"
        local drain_title
        drain_title=$(jq -r --arg n "$drain_issue_key" '.titles[$n] // ""' "$STATE_FILE" 2>/dev/null || true)

        # Is it still in the listing? 0 from a complete listing means the watch label is gone;
        # anything else unreadable or a truncated listing is unknown: keep it queued.
        local drain_present
        drain_present=$(echo "$issues_json" | jq -r --argjson n "$drain_issue_num" --arg repo "$drain_repo" \
            '[.[] | select(.number == $n) | select($repo == "" or (.repository.nameWithOwner // "") == $repo)] | length' 2>/dev/null || echo "")
        if [[ "$drain_present" == "0" && "$listing_complete" == "true" ]]; then
            daemon_log INFO "Dropping queued issue #${drain_issue_num}: no longer carries '${WATCH_LABEL}'"
            _poll_release_claim "$drain_issue_num"
            continue
        fi
        if [[ ! "$drain_present" =~ ^[1-9][0-9]*$ ]]; then
            daemon_log INFO "Queued issue #${drain_issue_num} not in this (truncated or unreadable) listing — kept queued"
            enqueue_issue "$drain_issue_key"
            continue
        fi

        local drain_labels drain_score drain_template
        drain_labels=$(echo "$issues_json" | jq -r --argjson n "$drain_issue_num" --arg repo "$drain_repo" \
            '.[] | select(.number == $n) | select($repo == "" or (.repository.nameWithOwner // "") == $repo) | [.labels[].name] | join(",")' 2>/dev/null || echo "")
        # Auto-filed, stuck or unreadable labels: drop it from the queue
        if [[ -z "$drain_labels" ]] || ! dispatch_eligible "$drain_labels"; then
            daemon_log INFO "Dropping queued issue #${drain_issue_num}: not eligible for dispatch"
            _poll_release_claim "$drain_issue_num"
            continue
        fi
        drain_score=$(echo "$sorted_order" | grep "|${drain_issue_num}|" | cut -d'|' -f1 || echo "50")
        drain_template=$(select_pipeline_template "$drain_labels" "${drain_score:-50}" 2>/dev/null | tail -1)
        drain_template=$(printf '%s' "$drain_template" | sed $'s/\x1b\\[[0-9;]*m//g' | tr -cd '[:alnum:]-_')
        [[ -z "$drain_template" ]] && drain_template="$PIPELINE_TEMPLATE"

        daemon_log INFO "Draining queue: issue #${drain_issue_num}${drain_repo:+, repo=${drain_repo}}, template=${drain_template}"
        local orig_template="$PIPELINE_TEMPLATE"
        PIPELINE_TEMPLATE="$drain_template"
        local drain_rc=0
        daemon_spawn_pipeline "$drain_issue_num" "$drain_title" "$drain_repo" || drain_rc=$?
        PIPELINE_TEMPLATE="$orig_template"
        if [[ "$drain_rc" -ne 0 ]]; then
            enqueue_issue "$drain_issue_key"
            if [[ "$drain_rc" -eq "${DAEMON_SPAWN_REFUSED:-75}" ]]; then
                daemon_log WARN "Spawn refused by gates for queued issue #${drain_issue_num} — re-queued; draining stops this cycle"
                break
            fi
            daemon_log WARN "Spawn failed for queued issue #${drain_issue_num} (rc=${drain_rc}) — re-queued at the tail"
            continue
        fi
        drain_active=$(locked_get_active_count)
    done

    # Update last poll
    update_state_field "last_poll" "$(now_iso)"
}

# ─── Health Check ─────────────────────────────────────────────────────────────
