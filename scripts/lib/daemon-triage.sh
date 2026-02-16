# daemon-triage.sh — Triage scoring and template selection (for sw-daemon.sh)
# Source from sw-daemon.sh. Requires state, helpers.
[[ -n "${_DAEMON_TRIAGE_LOADED:-}" ]] && return 0
_DAEMON_TRIAGE_LOADED=1

# Extract dependency issue numbers from issue text
extract_issue_dependencies() {
    local text="$1"

    echo "$text" | grep -oE '(depends on|blocked by|after) #[0-9]+' | grep -oE '#[0-9]+' | sort -u || true
}

# Score an issue from 0-100 based on multiple signals for intelligent prioritization.
# Combines priority labels, age, complexity, dependencies, type, and memory signals.
# When intelligence engine is enabled, uses semantic AI analysis for richer scoring.
triage_score_issue() {
    local issue_json="$1"
    local issue_num issue_title issue_body labels_csv created_at
    issue_num=$(echo "$issue_json" | jq -r '.number')
    issue_title=$(echo "$issue_json" | jq -r '.title // ""')
    issue_body=$(echo "$issue_json" | jq -r '.body // ""')

    # ── Intelligence-powered triage (if enabled) ──
    if [[ "${INTELLIGENCE_ENABLED:-false}" == "true" ]] && type intelligence_analyze_issue &>/dev/null 2>&1; then
        daemon_log INFO "Intelligence: using AI triage (intelligence enabled)" >&2
        local analysis
        analysis=$(intelligence_analyze_issue "$issue_json" 2>/dev/null || echo "")
        if [[ -n "$analysis" && "$analysis" != "{}" && "$analysis" != "null" ]]; then
            # Extract complexity (1-10) and convert to score (0-100)
            local ai_complexity ai_risk ai_success_prob
            ai_complexity=$(echo "$analysis" | jq -r '.complexity // 0' 2>/dev/null || echo "0")
            ai_risk=$(echo "$analysis" | jq -r '.risk_level // "medium"' 2>/dev/null || echo "medium")
            ai_success_prob=$(echo "$analysis" | jq -r '.success_probability // 50' 2>/dev/null || echo "50")

            # Store analysis for downstream use (composer, predictions)
            export INTELLIGENCE_ANALYSIS="$analysis"
            export INTELLIGENCE_COMPLEXITY="$ai_complexity"

            # Convert AI analysis to triage score:
            # Higher success probability + lower complexity = higher score (process sooner)
            local ai_score
            ai_score=$(( ai_success_prob - (ai_complexity * 3) ))
            # Risk adjustment
            case "$ai_risk" in
                critical) ai_score=$((ai_score + 15)) ;;  # Critical = process urgently
                high)     ai_score=$((ai_score + 10)) ;;
                low)      ai_score=$((ai_score - 5)) ;;
            esac
            # Clamp
            [[ "$ai_score" -lt 0 ]] && ai_score=0
            [[ "$ai_score" -gt 100 ]] && ai_score=100

            emit_event "intelligence.triage" \
                "issue=$issue_num" \
                "complexity=$ai_complexity" \
                "risk=$ai_risk" \
                "success_prob=$ai_success_prob" \
                "score=$ai_score"

            echo "$ai_score"
            return
        fi
        # Fall through to heuristic scoring if intelligence call failed
        daemon_log INFO "Intelligence: AI triage failed, falling back to heuristic scoring" >&2
    else
        daemon_log INFO "Intelligence: using heuristic triage (intelligence disabled, enable with intelligence.enabled=true)" >&2
    fi
    labels_csv=$(echo "$issue_json" | jq -r '[.labels[].name] | join(",")')
    created_at=$(echo "$issue_json" | jq -r '.createdAt // ""')

    local score=0

    # ── 1. Priority labels (0-30 points) ──
    local priority_score=0
    if echo "$labels_csv" | grep -qiE "urgent|p0"; then
        priority_score=30
    elif echo "$labels_csv" | grep -qiE "^high$|^high,|,high,|,high$|p1"; then
        priority_score=20
    elif echo "$labels_csv" | grep -qiE "normal|p2"; then
        priority_score=10
    elif echo "$labels_csv" | grep -qiE "^low$|^low,|,low,|,low$|p3"; then
        priority_score=5
    fi

    # ── 2. Issue age (0-15 points) — older issues boosted to prevent starvation ──
    local age_score=0
    if [[ -n "$created_at" ]]; then
        local created_epoch now_e age_secs
        created_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || \
                       date -d "$created_at" +%s 2>/dev/null || echo "0")
        now_e=$(now_epoch)
        if [[ "$created_epoch" -gt 0 ]]; then
            age_secs=$((now_e - created_epoch))
            if [[ "$age_secs" -gt 604800 ]]; then    # > 7 days
                age_score=15
            elif [[ "$age_secs" -gt 259200 ]]; then   # > 3 days
                age_score=10
            elif [[ "$age_secs" -gt 86400 ]]; then    # > 1 day
                age_score=5
            fi
        fi
    fi

    # ── 3. Complexity estimate (0-20 points, INVERTED — simpler = higher) ──
    local complexity_score=0
    local body_len=${#issue_body}
    local file_refs
    file_refs=$(echo "$issue_body" | grep -coE '[a-zA-Z0-9_/-]+\.(ts|js|py|go|rs|sh|json|yaml|yml|md)' || true)
    file_refs=${file_refs:-0}

    if [[ "$body_len" -lt 200 ]] && [[ "$file_refs" -lt 3 ]]; then
        complexity_score=20   # Short + few files = likely simple
    elif [[ "$body_len" -lt 1000 ]]; then
        complexity_score=10   # Medium
    elif [[ "$file_refs" -lt 5 ]]; then
        complexity_score=5    # Long but not many files
    fi
    # Long + many files = complex = 0 points (lower throughput)

    # ── 4. Dependencies (0-15 points / -15 for blocked) ──
    local dep_score=0
    local combined_text="${issue_title} ${issue_body}"

    # Check if this issue is blocked
    local blocked_refs
    blocked_refs=$(echo "$combined_text" | grep -oE '(blocked by|depends on) #[0-9]+' | grep -oE '#[0-9]+' || true)
    if [[ -n "$blocked_refs" ]] && [[ "$NO_GITHUB" != "true" ]]; then
        local all_closed=true
        while IFS= read -r ref; do
            local ref_num="${ref#\#}"
            local ref_state
            ref_state=$(gh issue view "$ref_num" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
            if [[ "$ref_state" != "CLOSED" ]]; then
                all_closed=false
                break
            fi
        done <<< "$blocked_refs"
        if [[ "$all_closed" == "false" ]]; then
            dep_score=-15
        fi
    fi

    # Check if this issue blocks others (search issue references)
    if [[ "$NO_GITHUB" != "true" ]]; then
        local mentions
        mentions=$(gh api "repos/{owner}/{repo}/issues/${issue_num}/timeline" --paginate -q '
            [.[] | select(.event == "cross-referenced") | .source.issue.body // ""] |
            map(select(test("blocked by #'"${issue_num}"'|depends on #'"${issue_num}"'"; "i"))) | length
        ' 2>/dev/null || echo "0")
        mentions=${mentions:-0}
        if [[ "$mentions" -gt 0 ]]; then
            dep_score=15
        fi
    fi

    # ── 5. Type bonus (0-10 points) ──
    local type_score=0
    if echo "$labels_csv" | grep -qiE "security"; then
        type_score=10
    elif echo "$labels_csv" | grep -qiE "bug"; then
        type_score=10
    elif echo "$labels_csv" | grep -qiE "feature|enhancement"; then
        type_score=5
    fi

    # ── 6. Memory bonus (0-10 points / -5 for prior failures) ──
    local memory_score=0
    if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        local memory_result
        memory_result=$("$SCRIPT_DIR/sw-memory.sh" search --issue "$issue_num" --json 2>/dev/null || true)
        if [[ -n "$memory_result" ]]; then
            local prior_result
            prior_result=$(echo "$memory_result" | jq -r '.last_result // ""' 2>/dev/null || true)
            if [[ "$prior_result" == "success" ]]; then
                memory_score=10
            elif [[ "$prior_result" == "failure" ]]; then
                memory_score=-5
            fi
        fi
    fi

    # ── Total ──
    score=$((priority_score + age_score + complexity_score + dep_score + type_score + memory_score))
    # Clamp to 0-100
    [[ "$score" -lt 0 ]] && score=0
    [[ "$score" -gt 100 ]] && score=100

    emit_event "daemon.triage" \
        "issue=$issue_num" \
        "score=$score" \
        "priority=$priority_score" \
        "age=$age_score" \
        "complexity=$complexity_score" \
        "dependency=$dep_score" \
        "type=$type_score" \
        "memory=$memory_score"

    echo "$score"
}

# Auto-select pipeline template based on issue labels
# When intelligence/composer is enabled, composes a custom pipeline instead of static selection.
select_pipeline_template() {
    local labels="$1"
    local score="${2:-50}"
    local _selected_template=""

    # When auto_template is disabled, use default pipeline template
    if [[ "${AUTO_TEMPLATE:-false}" != "true" ]]; then
        echo "$PIPELINE_TEMPLATE"
        return
    fi

    # ── Intelligence-composed pipeline (if enabled) ──
    if [[ "${COMPOSER_ENABLED:-false}" == "true" ]] && type composer_create_pipeline &>/dev/null 2>&1; then
        daemon_log INFO "Intelligence: using AI pipeline composition (composer enabled)" >&2
        local analysis="${INTELLIGENCE_ANALYSIS:-{}}"
        local repo_context=""
        if [[ -f "${REPO_DIR:-}/.claude/pipeline-state.md" ]]; then
            repo_context="has_pipeline_state"
        fi
        local budget_json="{}"
        if [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
            local remaining
            remaining=$(bash "$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
            if [[ -n "$remaining" ]]; then
                budget_json="{\"remaining_usd\": $remaining}"
            fi
        fi
        local composed_path
        composed_path=$(composer_create_pipeline "$analysis" "$repo_context" "$budget_json" 2>/dev/null || echo "")
        if [[ -n "$composed_path" && -f "$composed_path" ]]; then
            emit_event "daemon.composed_pipeline" "labels=$labels" "score=$score"
            echo "composed"
            return
        fi
        # Fall through to static selection if composition failed
        daemon_log INFO "Intelligence: AI pipeline composition failed, falling back to static template selection" >&2
    else
        daemon_log INFO "Intelligence: using static template selection (composer disabled, enable with intelligence.composer_enabled=true)" >&2
    fi

    # ── DORA-driven template escalation ──
    if [[ -f "${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}" ]]; then
        local _dora_events _dora_total _dora_failures _dora_cfr
        _dora_events=$(tail -500 "${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}" \
            | grep '"type":"pipeline.completed"' 2>/dev/null \
            | tail -5 || true)
        _dora_total=$(echo "$_dora_events" | grep -c '.' 2>/dev/null || echo "0")
        _dora_total="${_dora_total:-0}"
        if [[ "$_dora_total" -ge 3 ]]; then
            _dora_failures=$(echo "$_dora_events" | grep -c '"result":"failure"' 2>/dev/null || true)
            _dora_failures="${_dora_failures:-0}"
            _dora_cfr=$(( _dora_failures * 100 / _dora_total ))
            if [[ "$_dora_cfr" -gt 40 ]]; then
                daemon_log INFO "DORA escalation: CFR ${_dora_cfr}% > 40% — forcing enterprise template" >&2
                emit_event "daemon.dora_escalation" \
                    "cfr=$_dora_cfr" \
                    "total=$_dora_total" \
                    "failures=$_dora_failures" \
                    "template=enterprise"
                echo "enterprise"
                return
            fi
            if [[ "$_dora_cfr" -lt 10 && "$score" -ge 60 ]]; then
                daemon_log INFO "DORA: CFR ${_dora_cfr}% < 10% — fast template eligible" >&2
                # Fall through to allow other factors to also vote for fast
            fi

            # ── DORA multi-factor ──
            # Cycle time: if median > 120min, prefer faster templates
            local _dora_cycle_time=0
            _dora_cycle_time=$(echo "$_dora_events" | jq -r 'select(.duration_s) | .duration_s' 2>/dev/null \
                | sort -n | awk '{ a[NR]=$1 } END { if (NR>0) print int(a[int(NR/2)+1]/60); else print 0 }' 2>/dev/null) || _dora_cycle_time=0
            _dora_cycle_time="${_dora_cycle_time:-0}"
            if [[ "${_dora_cycle_time:-0}" -gt 120 ]]; then
                daemon_log INFO "DORA: cycle time ${_dora_cycle_time}min > 120 — preferring fast template" >&2
                if [[ "${score:-0}" -ge 60 ]]; then
                    echo "fast"
                    return
                fi
            fi

            # Deploy frequency: if < 1/week, use cost-aware
            local _dora_deploy_freq=0
            local _dora_first_epoch _dora_last_epoch _dora_span_days
            _dora_first_epoch=$(echo "$_dora_events" | head -1 | jq -r '.timestamp // empty' 2>/dev/null | xargs -I{} date -j -f "%Y-%m-%dT%H:%M:%SZ" {} +%s 2>/dev/null || echo "0")
            _dora_last_epoch=$(echo "$_dora_events" | tail -1 | jq -r '.timestamp // empty' 2>/dev/null | xargs -I{} date -j -f "%Y-%m-%dT%H:%M:%SZ" {} +%s 2>/dev/null || echo "0")
            if [[ "${_dora_first_epoch:-0}" -gt 0 && "${_dora_last_epoch:-0}" -gt 0 ]]; then
                _dora_span_days=$(( (_dora_last_epoch - _dora_first_epoch) / 86400 ))
                if [[ "${_dora_span_days:-0}" -gt 0 ]]; then
                    _dora_deploy_freq=$(awk -v t="$_dora_total" -v d="$_dora_span_days" 'BEGIN { printf "%.1f", t * 7 / d }' 2>/dev/null) || _dora_deploy_freq=0
                fi
            fi
            if [[ -n "${_dora_deploy_freq:-}" ]] && awk -v f="${_dora_deploy_freq:-0}" 'BEGIN{exit !(f > 0 && f < 1)}' 2>/dev/null; then
                daemon_log INFO "DORA: deploy freq ${_dora_deploy_freq}/week — using cost-aware" >&2
                echo "cost-aware"
                return
            fi
        fi
    fi

    # ── Branch protection escalation (highest priority) ──
    if type gh_branch_protection &>/dev/null 2>&1 && [[ "${NO_GITHUB:-false}" != "true" ]]; then
        if type _gh_detect_repo &>/dev/null 2>&1; then
            _gh_detect_repo 2>/dev/null || true
        fi
        local gh_owner="${GH_OWNER:-}" gh_repo="${GH_REPO:-}"
        if [[ -n "$gh_owner" && -n "$gh_repo" ]]; then
            local protection
            protection=$(gh_branch_protection "$gh_owner" "$gh_repo" "${BASE_BRANCH:-main}" 2>/dev/null || echo '{"protected": false}')
            local strict_protection
            strict_protection=$(echo "$protection" | jq -r '.enforce_admins.enabled // false' 2>/dev/null || echo "false")
            local required_reviews
            required_reviews=$(echo "$protection" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null || echo "0")
            if [[ "$strict_protection" == "true" ]] || [[ "${required_reviews:-0}" -gt 1 ]]; then
                daemon_log INFO "Branch has strict protection — escalating to enterprise template" >&2
                echo "enterprise"
                return
            fi
        fi
    fi

    # ── Label-based overrides ──
    if echo "$labels" | grep -qi "hotfix\|incident"; then
        echo "hotfix"
        return
    fi
    if echo "$labels" | grep -qi "security"; then
        echo "enterprise"
        return
    fi

    # ── Config-driven template_map overrides ──
    local map="${TEMPLATE_MAP:-\"{}\"}"
    # Unwrap double-encoded JSON if needed
    local decoded_map
    decoded_map=$(echo "$map" | jq -r 'if type == "string" then . else tostring end' 2>/dev/null || echo "{}")
    if [[ "$decoded_map" != "{}" ]]; then
        local matched
        matched=$(echo "$decoded_map" | jq -r --arg labels "$labels" '
            to_entries[] |
            select($labels | test(.key; "i")) |
            .value' 2>/dev/null | head -1)
        if [[ -n "$matched" ]]; then
            echo "$matched"
            return
        fi
    fi

    # ── Quality memory-driven selection ──
    local quality_scores_file="${HOME}/.shipwright/optimization/quality-scores.jsonl"
    if [[ -f "$quality_scores_file" ]]; then
        local repo_hash
        repo_hash=$(cd "${REPO_DIR:-.}" && git rev-parse --show-toplevel 2>/dev/null | shasum -a 256 | cut -c1-16 || echo "unknown")
        # Get last 5 quality scores for this repo
        local recent_scores avg_quality has_critical
        recent_scores=$(grep "\"repo\":\"$repo_hash\"" "$quality_scores_file" 2>/dev/null | tail -5 || true)
        if [[ -n "$recent_scores" ]]; then
            avg_quality=$(echo "$recent_scores" | jq -r '.quality_score // 70' 2>/dev/null | awk '{ sum += $1; count++ } END { if (count > 0) printf "%.0f", sum/count; else print 70 }')
            has_critical=$(echo "$recent_scores" | jq -r '.findings.critical // 0' 2>/dev/null | awk '{ sum += $1 } END { print (sum > 0) ? "yes" : "no" }')

            # Critical findings in recent history → force enterprise
            if [[ "$has_critical" == "yes" ]]; then
                daemon_log INFO "Quality memory: critical findings in recent runs — using enterprise template" >&2
                echo "enterprise"
                return
            fi

            # Poor quality history → use full template
            if [[ "${avg_quality:-70}" -lt 60 ]]; then
                daemon_log INFO "Quality memory: avg score ${avg_quality}/100 in recent runs — using full template" >&2
                echo "full"
                return
            fi

            # Excellent quality history → allow faster template
            if [[ "${avg_quality:-70}" -gt 80 ]]; then
                daemon_log INFO "Quality memory: avg score ${avg_quality}/100 in recent runs — eligible for fast template" >&2
                # Only upgrade if score also suggests fast
                if [[ "$score" -ge 60 ]]; then
                    echo "fast"
                    return
                fi
            fi
        fi
    fi

    # ── Learned template weights ──
    local _tw_file="${HOME}/.shipwright/optimization/template-weights.json"
    if [[ -f "$_tw_file" ]]; then
        local _best_template _best_rate
        _best_template=$(jq -r '
            .weights // {} | to_entries
            | map(select(.value.sample_size >= 3))
            | sort_by(-.value.success_rate)
            | .[0].key // ""
        ' "$_tw_file" 2>/dev/null) || true
        if [[ -n "${_best_template:-}" && "${_best_template:-}" != "null" && "${_best_template:-}" != "" ]]; then
            _best_rate=$(jq -r --arg t "$_best_template" '.weights[$t].success_rate // 0' "$_tw_file" 2>/dev/null || _best_rate=0)
            daemon_log INFO "Template weights: ${_best_template} (${_best_rate} success rate)" >&2
            echo "$_best_template"
            return
        fi
    fi

    # ── Score-based selection ──
    if [[ "$score" -ge 70 ]]; then
        echo "fast"
    elif [[ "$score" -ge 40 ]]; then
        echo "standard"
    else
        echo "full"
    fi
}

# ─── Triage Display ──────────────────────────────────────────────────────────

daemon_triage_show() {
    if [[ "$NO_GITHUB" == "true" ]]; then
        error "Triage requires GitHub access (--no-github is set)"
        exit 1
    fi

    load_config

    echo -e "${PURPLE}${BOLD}━━━ Issue Triage Scores ━━━${RESET}"
    echo ""

    local issues_json
    issues_json=$(gh issue list \
        --label "$WATCH_LABEL" \
        --state open \
        --json number,title,labels,body,createdAt \
        --limit 50 2>/dev/null) || {
        error "Failed to fetch issues from GitHub"
        exit 1
    }

    local issue_count
    issue_count=$(echo "$issues_json" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$issue_count" -eq 0 ]]; then
        echo -e "  ${DIM}No open issues with label '${WATCH_LABEL}'${RESET}"
        return 0
    fi

    # Score each issue and collect results
    local scored_lines=()
    while IFS= read -r issue; do
        local num title labels_csv score template
        num=$(echo "$issue" | jq -r '.number')
        title=$(echo "$issue" | jq -r '.title // "—"')
        labels_csv=$(echo "$issue" | jq -r '[.labels[].name] | join(", ")')
        score=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
        score=$(printf '%s' "$score" | tr -cd '[:digit:]')
        [[ -z "$score" ]] && score=50
        template=$(select_pipeline_template "$labels_csv" "$score" 2>/dev/null | tail -1)
        template=$(printf '%s' "$template" | sed $'s/\x1b\\[[0-9;]*m//g' | tr -cd '[:alnum:]-_')
        [[ -z "$template" ]] && template="$PIPELINE_TEMPLATE"

        scored_lines+=("${score}|${num}|${title}|${labels_csv}|${template}")
    done < <(echo "$issues_json" | jq -c '.[]')

    # Sort by score descending
    local sorted
    sorted=$(printf '%s\n' "${scored_lines[@]}" | sort -t'|' -k1 -rn)

    # Print header
    printf "  ${BOLD}%-6s  %-7s  %-45s  %-12s  %s${RESET}\n" "Score" "Issue" "Title" "Template" "Labels"
    echo -e "  ${DIM}$(printf '%.0s─' {1..90})${RESET}"

    while IFS='|' read -r score num title labels_csv template; do
        # Color score by tier
        local score_color="$RED"
        [[ "$score" -ge 20 ]] && score_color="$YELLOW"
        [[ "$score" -ge 40 ]] && score_color="$CYAN"
        [[ "$score" -ge 60 ]] && score_color="$GREEN"

        # Truncate title
        [[ ${#title} -gt 42 ]] && title="${title:0:39}..."

        printf "  ${score_color}%-6s${RESET}  ${CYAN}#%-6s${RESET}  %-45s  ${DIM}%-12s  %s${RESET}\n" \
            "$score" "$num" "$title" "$template" "$labels_csv"
    done <<< "$sorted"

    echo ""
    echo -e "  ${DIM}${issue_count} issue(s) scored  |  Higher score = higher processing priority${RESET}"
    echo ""
}
