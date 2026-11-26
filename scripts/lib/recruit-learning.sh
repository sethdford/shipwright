#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2064
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  lib/recruit-learning.sh — Learning, Evolution, Meta-Learning, Tuning    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_RECRUIT_LEARNING_LOADED:-}" ]] && return 0
_RECRUIT_LEARNING_LOADED=1

SCRIPT_DIR="${SCRIPT_DIR:-.}"
RECRUIT_ROOT="${RECRUIT_ROOT:-${HOME}/.shipwright/recruitment}"
PROFILES_DB="${PROFILES_DB:-${RECRUIT_ROOT}/profiles.json}"
MATCH_HISTORY="${MATCH_HISTORY:-${RECRUIT_ROOT}/match-history.jsonl}"
ROLE_USAGE_DB="${ROLE_USAGE_DB:-${RECRUIT_ROOT}/role-usage.json}"
HEURISTICS_DB="${HEURISTICS_DB:-${RECRUIT_ROOT}/heuristics.json}"
META_LEARNING_DB="${META_LEARNING_DB:-${RECRUIT_ROOT}/meta-learning.json}"
EVENTS_FILE="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"

# Fallback color/output helpers
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi

# Fallback for color codes
CYAN="${CYAN:-\033[38;2;0;212;255m}"
RESET="${RESET:-\033[0m}"
BOLD="${BOLD:-\033[1m}"
DIM="${DIM:-\033[2m}"
YELLOW="${YELLOW:-\033[38;2;251;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"

# ═══════════════════════════════════════════════════════════════════════════════
# CLOSED-LOOP FEEDBACK INTEGRATION (Tier 1)
# ═══════════════════════════════════════════════════════════════════════════════

cmd_record_outcome() {
    local agent_id="${1:-}"
    local task_id="${2:-}"
    local outcome="${3:-}"
    local quality="${4:-}"
    local duration_min="${5:-}"

    if [[ -z "$agent_id" || -z "$outcome" ]]; then
        error "Usage: shipwright recruit record-outcome <agent-id> <task-id> <success|failure> [quality:0-10] [duration_min]"
        exit 1
    fi

    ensure_recruit_dir

    # Get or create profile
    local profile
    profile=$(jq ".\"${agent_id}\" // {}" "$PROFILES_DB" 2>/dev/null || echo "{}")

    local tasks_completed success_count total_time total_quality
    tasks_completed=$(echo "$profile" | jq -r '.tasks_completed // 0')
    success_count=$(echo "$profile" | jq -r '.success_count // 0')
    total_time=$(echo "$profile" | jq -r '.total_time_minutes // 0')
    total_quality=$(echo "$profile" | jq -r '.total_quality // 0')
    local current_model
    current_model=$(echo "$profile" | jq -r '.model // "sonnet"')

    tasks_completed=$((tasks_completed + 1))
    [[ "$outcome" == "success" ]] && success_count=$((success_count + 1))

    if [[ -n "$duration_min" && "$duration_min" != "0" ]]; then
        total_time=$(awk -v t="$total_time" -v d="$duration_min" 'BEGIN{printf "%.1f", t + d}')
    fi
    if [[ -n "$quality" && "$quality" != "0" ]]; then
        total_quality=$(awk -v tq="$total_quality" -v q="$quality" 'BEGIN{printf "%.1f", tq + q}')
    fi

    local success_rate avg_time avg_quality cost_efficiency
    success_rate=$(awk -v s="$success_count" -v t="$tasks_completed" 'BEGIN{if(t>0) printf "%.1f", (s/t)*100; else print "0"}')
    avg_time=$(awk -v t="$total_time" -v n="$tasks_completed" 'BEGIN{if(n>0) printf "%.1f", t/n; else print "0"}')
    avg_quality=$(awk -v tq="$total_quality" -v n="$tasks_completed" 'BEGIN{if(n>0) printf "%.1f", tq/n; else print "0"}')
    cost_efficiency=$(awk -v sr="$success_rate" 'BEGIN{printf "%.0f", sr * 0.9}')

    # Build updated profile with specialization tracking
    local role_assigned
    role_assigned=$(echo "$profile" | jq -r '.role // "builder"')

    local task_history
    task_history=$(echo "$profile" | jq -r '.task_history // []')

    # Append to task history (keep last 50)
    local new_entry
    new_entry=$(jq -c -n \
        --arg ts "$(now_iso)" \
        --arg task "$task_id" \
        --arg outcome "$outcome" \
        --argjson quality "${quality:-0}" \
        --argjson duration "${duration_min:-0}" \
        '{ts: $ts, task: $task, outcome: $outcome, quality: $quality, duration: $duration}')

    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'; trap - RETURN" RETURN
    jq --arg id "$agent_id" \
       --argjson tc "$tasks_completed" \
       --argjson sc "$success_count" \
       --argjson sr "$success_rate" \
       --argjson at "$avg_time" \
       --argjson aq "$avg_quality" \
       --argjson ce "$cost_efficiency" \
       --argjson tt "$total_time" \
       --argjson tq "$total_quality" \
       --arg model "$current_model" \
       --arg role "$role_assigned" \
       --argjson entry "$new_entry" \
       '.[$id] = {
           tasks_completed: $tc,
           success_count: $sc,
           success_rate: $sr,
           avg_time_minutes: $at,
           quality_score: $aq,
           cost_efficiency: $ce,
           total_time_minutes: $tt,
           total_quality: $tq,
           model: $model,
           role: $role,
           task_history: ((.[$id].task_history // []) + [$entry] | .[-50:]),
           last_updated: (now | todate)
       }' "$PROFILES_DB" > "$tmp_file" && _recruit_locked_write "$PROFILES_DB" "$tmp_file" || { rm -f "$tmp_file"; error "Failed to update profile"; return 1; }

    success "Recorded ${outcome} for ${CYAN}${agent_id}${RESET} (${tasks_completed} tasks, ${success_rate}% success)"
    emit_event "recruit_outcome" "agent_id=${agent_id}" "outcome=${outcome}" "success_rate=${success_rate}"

    # Track role usage with outcome (closes the role-usage feedback loop)
    _recruit_track_role_usage "$role_assigned" "$outcome"

    # Backfill match history with outcome (closes the match→outcome linkage gap)
    if [[ -f "$MATCH_HISTORY" ]]; then
        local tmp_mh
        tmp_mh=$(mktemp)
        trap "rm -f '$tmp_mh'; trap - RETURN" RETURN
        # Find the most recent match for this agent_id with null outcome, and backfill
        awk -v agent="$agent_id" -v outcome="$outcome" '
        BEGIN { found = 0 }
        { lines[NR] = $0; count = NR }
        END {
            # Walk backwards to find the last unresolved match for this agent
            for (i = count; i >= 1; i--) {
                if (!found && index(lines[i], "\"agent_id\":\"" agent "\"") > 0 && index(lines[i], "\"outcome\":null") > 0) {
                    gsub(/"outcome":null/, "\"outcome\":\"" outcome "\"", lines[i])
                    found = 1
                }
            }
            for (i = 1; i <= count; i++) print lines[i]
        }' "$MATCH_HISTORY" > "$tmp_mh" && _recruit_locked_write "$MATCH_HISTORY" "$tmp_mh" || rm -f "$tmp_mh"
    fi

    # Trigger meta-learning check (warn on failure instead of silencing)
    if ! _recruit_meta_learning_check "$agent_id" "$outcome" 2>&1; then
        warn "Meta-learning check failed for ${agent_id} (non-fatal)" >&2
    fi
}

# Ingest outcomes from pipeline events.jsonl automatically
cmd_ingest_pipeline() {
    local days="${1:-7}"

    ensure_recruit_dir
    info "Ingesting pipeline outcomes from last ${days} days..."

    if [[ ! -f "$EVENTS_FILE" ]]; then
        warn "No events file found"
        return 0
    fi

    local now_e
    now_e=$(now_epoch)
    local cutoff=$((now_e - days * 86400))
    local ingested=0

    while IFS= read -r line; do
        local event_type ts_epoch result agent_id duration
        event_type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null) || continue
        ts_epoch=$(echo "$line" | jq -r '.ts_epoch // 0' 2>/dev/null) || continue

        [[ "$ts_epoch" -lt "$cutoff" ]] && continue

        case "$event_type" in
            pipeline.completed)
                result=$(echo "$line" | jq -r '.result // "unknown"' 2>/dev/null || echo "unknown")
                agent_id=$(echo "$line" | jq -r '.agent_id // "default-agent"' 2>/dev/null || echo "default-agent")
                duration=$(echo "$line" | jq -r '.duration_s // 0' 2>/dev/null || echo "0")
                local dur_min
                dur_min=$(awk -v d="$duration" 'BEGIN{printf "%.1f", d/60}')

                local outcome="failure"
                [[ "$result" == "success" ]] && outcome="success"

                cmd_record_outcome "$agent_id" "pipeline-$(echo "$line" | jq -r '.ts_epoch // 0')" "$outcome" "5" "$dur_min" 2>/dev/null || true
                ingested=$((ingested + 1))
                ;;
        esac
    done < "$EVENTS_FILE"

    success "Ingested ${ingested} pipeline outcomes"
    emit_event "recruit_ingest" "count=${ingested}" "days=${days}"

    # Auto-trigger self-tune when new outcomes are ingested (closes the learning loop)
    if [[ "$ingested" -gt 0 ]]; then
        info "Auto-running self-tune after ingesting ${ingested} outcomes..."
        cmd_self_tune 2>/dev/null || warn "Auto self-tune failed (non-fatal)" >&2

        # Auto-trigger evolve when enough outcomes accumulate (policy-driven)
        local total_outcomes
        total_outcomes=$(jq -r '[.[] | .tasks_completed // 0] | add // 0' "$PROFILES_DB" 2>/dev/null || echo "0")
        local evolve_threshold="${RECRUIT_AUTO_EVOLVE_AFTER:-20}"
        if [[ "$total_outcomes" -ge "$evolve_threshold" ]]; then
            info "Auto-running evolve (${total_outcomes} total outcomes >= ${evolve_threshold} threshold)..."
            cmd_evolve 2>/dev/null || warn "Auto evolve failed (non-fatal)" >&2
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# ROLE USAGE TRACKING & EVOLUTION (Tier 2)
# ═══════════════════════════════════════════════════════════════════════════════

_recruit_track_role_usage() {
    local role="$1"
    local event="${2:-match}"

    [[ ! -f "$ROLE_USAGE_DB" ]] && echo '{}' > "$ROLE_USAGE_DB"

    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'; trap - RETURN" RETURN
    jq --arg role "$role" --arg event "$event" --arg ts "$(now_iso)" '
        .[$role] = (.[$role] // {matches: 0, successes: 0, failures: 0, last_used: ""}) |
        .[$role].last_used = $ts |
        if $event == "match" then .[$role].matches += 1
        elif $event == "success" then .[$role].successes += 1
        elif $event == "failure" then .[$role].failures += 1
        else . end
    ' "$ROLE_USAGE_DB" > "$tmp_file" && _recruit_locked_write "$ROLE_USAGE_DB" "$tmp_file" || rm -f "$tmp_file"
}

cmd_evolve() {
    ensure_recruit_dir
    initialize_builtin_roles

    info "Analyzing role evolution opportunities..."
    echo ""

    if [[ ! -f "$ROLE_USAGE_DB" || "$(jq 'length' "$ROLE_USAGE_DB" 2>/dev/null || echo 0)" -eq 0 ]]; then
        warn "Not enough usage data for evolution analysis"
        echo "  Run more pipelines and use 'shipwright recruit ingest-pipeline' first"
        return 0
    fi

    local analysis=""

    # Detect underused roles (no matches in 30+ days)
    local stale_roles
    stale_roles=$(jq -r --argjson cutoff "$(($(now_epoch) - 2592000))" '
        to_entries[] | select(
            (.value.last_used == "") or
            (.value.matches == 0) or
            ((.value.last_used | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) < $cutoff)
        ) | .key
    ' "$ROLE_USAGE_DB" 2>/dev/null || true)

    if [[ -n "$stale_roles" ]]; then
        echo -e "  ${YELLOW}${BOLD}Underused Roles (candidates for retirement):${RESET}"
        while IFS= read -r role; do
            [[ -z "$role" ]] && continue
            local matches
            matches=$(jq -r --arg r "$role" '.[$r].matches // 0' "$ROLE_USAGE_DB" 2>/dev/null || echo "0")
            echo -e "    ${DIM}•${RESET} ${role} (${matches} total matches)"
            analysis="${analysis}retire:${role},"
        done <<< "$stale_roles"
        echo ""
    fi

    # Detect high-failure roles (>40% failure rate with 5+ tasks)
    local struggling_roles
    struggling_roles=$(jq -r '
        to_entries[] | select(
            (.value.matches >= 5) and
            ((.value.failures / .value.matches) > 0.4)
        ) | "\(.key):\(.value.failures)/\(.value.matches)"
    ' "$ROLE_USAGE_DB" 2>/dev/null || true)

    if [[ -n "$struggling_roles" ]]; then
        echo -e "  ${RED}${BOLD}Struggling Roles (need specialization or split):${RESET}"
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            local role="${entry%%:*}"
            local ratio="${entry#*:}"
            echo -e "    ${DIM}•${RESET} ${role} — ${ratio} failures"
            analysis="${analysis}split:${role},"
        done <<< "$struggling_roles"
        echo ""
    fi

    # Detect overloaded roles (>60% of all matches go to one role)
    local total_matches
    total_matches=$(jq '[.[].matches] | add // 0' "$ROLE_USAGE_DB" 2>/dev/null || echo "0")

    if [[ "$total_matches" -gt 10 ]]; then
        local overloaded_roles
        overloaded_roles=$(jq -r --argjson total "$total_matches" '
            to_entries[] | select((.value.matches / $total) > 0.6) |
            "\(.key):\(.value.matches)"
        ' "$ROLE_USAGE_DB" 2>/dev/null || true)

        if [[ -n "$overloaded_roles" ]]; then
            echo -e "  ${PURPLE}${BOLD}Overloaded Roles (candidates for splitting):${RESET}"
            while IFS= read -r entry; do
                [[ -z "$entry" ]] && continue
                local role="${entry%%:*}"
                local count="${entry#*:}"
                echo -e "    ${DIM}•${RESET} ${role} — ${count}/${total_matches} matches ($(awk -v c="$count" -v t="$total_matches" 'BEGIN{printf "%.0f", (c/t)*100}')%)"
            done <<< "$overloaded_roles"
            echo ""
        fi
    fi

    # LLM-powered evolution suggestions
    if [[ -n "$analysis" ]] && _recruit_has_claude; then
        info "Generating AI evolution recommendations..."
        local roles_summary
        roles_summary=$(jq -c '.' "$ROLE_USAGE_DB" 2>/dev/null || echo "{}")

        local prompt
        prompt="Analyze agent role usage data and suggest evolution:

Usage data: ${roles_summary}
Analysis flags: ${analysis}

Suggest specific actions:
1. Which roles to retire (unused)
2. Which roles to split into specializations (high failure or overloaded)
3. Which roles to merge (overlapping low-use roles)
4. New hybrid roles to create

Return a brief text summary (3-5 bullet points). Be specific with role names."

        local suggestions
        suggestions=$(_recruit_call_claude "$prompt")
        if [[ -n "$suggestions" ]]; then
            echo -e "  ${CYAN}${BOLD}AI Evolution Recommendations:${RESET}"
            echo "$suggestions" | sed 's/^/    /'
        fi
    fi

    emit_event "recruit_evolve" "analysis=${analysis:0:100}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SELF-TUNING THRESHOLDS (Tier 2)
# ═══════════════════════════════════════════════════════════════════════════════

_recruit_compute_population_stats() {
    if [[ ! -f "$PROFILES_DB" || "$(jq 'length' "$PROFILES_DB" 2>/dev/null || echo 0)" -lt 2 ]]; then
        echo '{"mean_success":0,"stddev_success":0,"p90_success":0,"p10_success":0,"count":0}'
        return
    fi

    jq '
        [.[].success_rate] as $rates |
        ($rates | length) as $n |
        ($rates | add / $n) as $mean |
        ($rates | map(. - $mean | . * .) | add / $n | sqrt) as $stddev |
        ($rates | sort) as $sorted |
        {
            mean_success: ($mean * 10 | floor / 10),
            stddev_success: ($stddev * 10 | floor / 10),
            p90_success: ($sorted[($n * 0.9 | floor)] // 0),
            p10_success: ($sorted[($n * 0.1 | floor)] // 0),
            count: $n
        }
    ' "$PROFILES_DB" 2>/dev/null || echo '{"mean_success":0,"stddev_success":0,"p90_success":0,"p10_success":0,"count":0}'
}

# ═══════════════════════════════════════════════════════════════════════════════
# CROSS-AGENT LEARNING (Tier 2)
# ═══════════════════════════════════════════════════════════════════════════════

cmd_specializations() {
    ensure_recruit_dir

    info "Agent Specialization Analysis:"
    echo ""

    if [[ ! -f "$PROFILES_DB" || "$(jq 'length' "$PROFILES_DB" 2>/dev/null || echo 0)" -eq 0 ]]; then
        warn "No agent profiles to analyze"
        return 0
    fi

    # Analyze per-agent task history for patterns
    jq -r 'to_entries[] |
        .key as $agent |
        .value |
        "  \($agent):" +
        "\n    Role: \(.role // "unassigned")" +
        "\n    Success: \(.success_rate // 0)% over \(.tasks_completed // 0) tasks" +
        "\n    Model: \(.model // "unknown")" +
        "\n    Strength: " + (
            if (.success_rate // 0) >= 90 then "excellent"
            elif (.success_rate // 0) >= 75 then "good"
            elif (.success_rate // 0) >= 60 then "developing"
            else "needs improvement"
            end
        ) + "\n"
    ' "$PROFILES_DB" 2>/dev/null || warn "Could not analyze specializations"

    # Suggest smart routing
    local pop_stats
    pop_stats=$(_recruit_compute_population_stats)
    local mean_success
    mean_success=$(echo "$pop_stats" | jq -r '.mean_success')
    local agent_count
    agent_count=$(echo "$pop_stats" | jq -r '.count')

    if [[ "$agent_count" -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Population Statistics:${RESET}"
        echo -e "    Mean success rate: ${mean_success}%"
        echo -e "    Agents tracked: ${agent_count}"
        echo -e "    P90/P10 spread: $(echo "$pop_stats" | jq -r '.p90_success')% / $(echo "$pop_stats" | jq -r '.p10_success')%"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# META-LEARNING: REFLECT ON MATCHING ACCURACY (Tier 3)
# ═══════════════════════════════════════════════════════════════════════════════

_recruit_meta_learning_check() {
    local agent_id="${1:-}"
    local outcome="${2:-}"

    [[ ! -f "$MATCH_HISTORY" ]] && return 0
    [[ ! -f "$META_LEARNING_DB" ]] && return 0

    # Find most recent match for this agent (by agent_id if set, else last match)
    local last_match
    last_match=$(tail -50 "$MATCH_HISTORY" | jq -s -r --arg agent "$agent_id" '
        [.[] | select(.role != null) |
         select(.agent_id == $agent or .agent_id == "" or .agent_id == null)] |
        last // null
    ' 2>/dev/null || echo "")

    [[ -z "$last_match" || "$last_match" == "null" ]] && return 0

    local matched_role method
    matched_role=$(echo "$last_match" | jq -r '.role // ""')
    method=$(echo "$last_match" | jq -r '.method // "keyword"')

    [[ -z "$matched_role" ]] && return 0

    # Record correction if failure
    if [[ "$outcome" == "failure" ]]; then
        local correction
        correction=$(jq -c -n \
            --arg ts "$(now_iso)" \
            --arg agent "$agent_id" \
            --arg role "$matched_role" \
            --arg method "$method" \
            --arg outcome "$outcome" \
            '{ts: $ts, agent: $agent, role: $role, method: $method, outcome: $outcome}')

        local tmp_file
        tmp_file=$(mktemp)
        trap "rm -f '$tmp_file'; trap - RETURN" RETURN
        jq --argjson corr "$correction" '
            .corrections = ((.corrections // []) + [$corr] | .[-100:])
        ' "$META_LEARNING_DB" > "$tmp_file" && _recruit_locked_write "$META_LEARNING_DB" "$tmp_file" || rm -f "$tmp_file"
    fi

    # Every 20 outcomes, reflect on accuracy
    local total_corrections
    total_corrections=$(jq '.corrections | length' "$META_LEARNING_DB" 2>/dev/null || echo "0")

    if [[ "$((total_corrections % 20))" -eq 0 && "$total_corrections" -gt 0 ]]; then
        _recruit_reflect || warn "Auto-reflection failed (non-fatal)" >&2
    fi
}

cmd_reflect() {
    ensure_recruit_dir

    info "Running meta-learning reflection..."
    echo ""

    _recruit_reflect
}

_recruit_reflect() {
    [[ ! -f "$META_LEARNING_DB" ]] && return 0
    [[ ! -f "$MATCH_HISTORY" ]] && return 0

    local total_matches
    total_matches=$(wc -l < "$MATCH_HISTORY" 2>/dev/null | tr -d ' ')
    local total_corrections
    total_corrections=$(jq '.corrections | length' "$META_LEARNING_DB" 2>/dev/null || echo "0")

    if [[ "$total_matches" -eq 0 ]]; then
        info "No match history to reflect on"
        return 0
    fi

    local accuracy
    accuracy=$(awk -v m="$total_matches" -v c="$total_corrections" 'BEGIN{if(m>0) printf "%.1f", ((m-c)/m)*100; else print "0"}')

    echo -e "  ${BOLD}Matching Accuracy:${RESET} ${accuracy}% (${total_matches} matches, ${total_corrections} corrections)"

    # Track accuracy trend
    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'; trap - RETURN" RETURN
    jq --argjson acc "$accuracy" --arg ts "$(now_iso)" '
        .accuracy_trend = ((.accuracy_trend // []) + [{accuracy: $acc, ts: $ts}] | .[-50:]) |
        .last_reflection = $ts
    ' "$META_LEARNING_DB" > "$tmp_file" && _recruit_locked_write "$META_LEARNING_DB" "$tmp_file" || rm -f "$tmp_file"

    # Identify most-failed role assignments
    local failure_patterns
    failure_patterns=$(jq -r '
        .corrections | group_by(.role) |
        map({role: .[0].role, failures: length}) |
        sort_by(-.failures) | .[:3][] |
        "    \(.role): \(.failures) failures"
    ' "$META_LEARNING_DB" 2>/dev/null || true)

    if [[ -n "$failure_patterns" ]]; then
        echo ""
        echo -e "  ${BOLD}Most Mismatched Roles:${RESET}"
        echo "$failure_patterns"
    fi

    # LLM-powered reflection
    if _recruit_has_claude && [[ "$total_corrections" -ge 5 ]]; then
        local corrections_json
        corrections_json=$(jq -c '.corrections[-20:]' "$META_LEARNING_DB" 2>/dev/null || echo "[]")

        local prompt
        prompt="Analyze these role matching failures and suggest improvements to the matching heuristics.

Recent failures: ${corrections_json}
Current accuracy: ${accuracy}%

For each failed pattern, suggest:
1. What keyword or pattern should have triggered a different role
2. Whether a new role should be created for this type of task

Return a brief text summary (3-5 bullet points). Be specific about which keywords map to which roles."

        local suggestions
        suggestions=$(_recruit_call_claude "$prompt")
        if [[ -n "$suggestions" ]]; then
            echo ""
            echo -e "  ${CYAN}${BOLD}AI Reflection:${RESET}"
            echo "$suggestions" | sed 's/^/    /'
        fi
    fi

    emit_event "recruit_reflect" "accuracy=${accuracy}" "corrections=${total_corrections}"

    # Meta-loop: validate self-tune effectiveness by comparing accuracy trend
    _recruit_meta_validate_self_tune "$accuracy"
}

_recruit_meta_validate_self_tune() {
    local current_accuracy="${1:-0}"
    [[ ! -f "$META_LEARNING_DB" ]] && return 0
    [[ ! -f "$HEURISTICS_DB" ]] && return 0

    local accuracy_floor="${RECRUIT_META_ACCURACY_FLOOR:-50}"

    # Get accuracy trend (last 10 data points)
    local trend_data
    trend_data=$(jq -r '.accuracy_trend // [] | .[-10:]' "$META_LEARNING_DB" 2>/dev/null) || return 0

    local trend_count
    trend_count=$(echo "$trend_data" | jq 'length' 2>/dev/null) || return 0
    [[ "$trend_count" -lt 3 ]] && return 0

    # Compute moving average of first half vs second half
    local first_half_avg second_half_avg
    first_half_avg=$(echo "$trend_data" | jq '[.[:length/2 | floor][].accuracy] | add / length' 2>/dev/null) || return 0
    second_half_avg=$(echo "$trend_data" | jq '[.[length/2 | floor:][].accuracy] | add / length' 2>/dev/null) || return 0

    local is_declining
    is_declining=$(awk -v f="$first_half_avg" -v s="$second_half_avg" 'BEGIN{print (s < f - 5) ? 1 : 0}')

    local is_below_floor
    is_below_floor=$(awk -v c="$current_accuracy" -v f="$accuracy_floor" 'BEGIN{print (c < f) ? 1 : 0}')

    if [[ "$is_declining" == "1" ]]; then
        warn "META-LOOP: Accuracy DECLINING after self-tune (${first_half_avg}% -> ${second_half_avg}%)"

        if [[ "$is_below_floor" == "1" ]]; then
            warn "META-LOOP: Accuracy ${current_accuracy}% below floor ${accuracy_floor}% — reverting heuristics to defaults"
            # Reset heuristics to empty (forces fallback to keyword_match defaults)
            local tmp_heur
            tmp_heur=$(mktemp)
            trap "rm -f '$tmp_heur'; trap - RETURN" RETURN
            echo '{"keyword_weights": {}, "meta_reverted_at": "'"$(now_iso)"'", "revert_reason": "accuracy_below_floor"}' > "$tmp_heur"
            _recruit_locked_write "$HEURISTICS_DB" "$tmp_heur" || rm -f "$tmp_heur"
            emit_event "recruit_meta_revert" "accuracy=${current_accuracy}" "floor=${accuracy_floor}" "reason=declining_below_floor"
        else
            emit_event "recruit_meta_warning" "accuracy=${current_accuracy}" "trend=declining" "first_half=${first_half_avg}" "second_half=${second_half_avg}"
        fi
    elif [[ "$is_below_floor" == "1" ]]; then
        warn "META-LOOP: Accuracy ${current_accuracy}% below floor ${accuracy_floor}%"
        emit_event "recruit_meta_warning" "accuracy=${current_accuracy}" "floor=${accuracy_floor}" "trend=low"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# SELF-MODIFICATION: REWRITE OWN HEURISTICS (Tier 3)
# ═══════════════════════════════════════════════════════════════════════════════

cmd_self_tune() {
    ensure_recruit_dir

    info "Self-tuning matching heuristics..."
    echo ""

    if [[ ! -f "$MATCH_HISTORY" ]]; then
        warn "No match history to learn from"
        return 0
    fi

    local total_matches
    total_matches=$(wc -l < "$MATCH_HISTORY" 2>/dev/null | tr -d ' ')

    local min_matches="${RECRUIT_SELF_TUNE_MIN_MATCHES:-5}"
    if [[ "$total_matches" -lt "$min_matches" ]]; then
        warn "Need at least ${min_matches} matches to self-tune (have ${total_matches})"
        return 0
    fi

    # Analyze which keywords correctly predicted roles
    info "Analyzing ${total_matches} match records..."

    # Build keyword frequency map from successful matches
    local keyword_updates=0

    # Extract task descriptions grouped by role
    local match_data
    match_data=$(jq -s '
        [.[] | select(.role != null and .role != "")] |
        group_by(.role) |
        map({
            role: .[0].role,
            tasks: [.[] | .task],
            count: length
        })
    ' "$MATCH_HISTORY" 2>/dev/null || echo "[]")

    # Filter to roles with positive success ratios from role-usage DB
    if [[ -f "$ROLE_USAGE_DB" ]]; then
        local good_roles
        good_roles=$(jq -r '
            to_entries[] |
            select((.value.successes // 0) > (.value.failures // 0)) |
            .key
        ' "$ROLE_USAGE_DB" 2>/dev/null || true)

        if [[ -n "$good_roles" ]]; then
            local good_roles_json
            good_roles_json=$(echo "$good_roles" | jq -R . | jq -s .)
            match_data=$(echo "$match_data" | jq --argjson good "$good_roles_json" '
                [.[] | select(.role as $r | $good | index($r) // false)]
            ' 2>/dev/null || echo "$match_data")
        fi
    fi

    if [[ "$match_data" == "[]" ]]; then
        info "No successful outcomes recorded yet"
        return 0
    fi

    # Extract common words per role (simple TF approach)
    local role_count
    role_count=$(echo "$match_data" | jq 'length')

    local tmp_heuristics
    tmp_heuristics=$(mktemp)
    trap "rm -f '$tmp_heuristics'; trap - RETURN" RETURN
    cp "$HEURISTICS_DB" "$tmp_heuristics"

    local i=0
    while [[ "$i" -lt "$role_count" ]]; do
        local role
        role=$(echo "$match_data" | jq -r ".[$i].role")
        local tasks
        tasks=$(echo "$match_data" | jq -r ".[$i].tasks | join(\" \")" | tr '[:upper:]' '[:lower:]')

        # Find frequent words (>= 2 occurrences, >= 4 chars)
        local frequent_words
        frequent_words=$(echo "$tasks" | tr -cs '[:alpha:]' '\n' | sort | uniq -c | sort -rn | \
            awk '$1 >= 2 && length($2) >= 4 {print $2}' | head -5)

        while IFS= read -r word; do
            [[ -z "$word" ]] && continue
            # Skip common stop words
            case "$word" in
                this|that|with|from|have|will|should|would|could|been|some|more|than|into) continue ;;
            esac

            jq --arg kw "$word" --arg role "$role" \
                '.keyword_weights[$kw] = {role: $role, weight: 5, source: "self-tuned"}' \
                "$tmp_heuristics" > "${tmp_heuristics}.new" && mv "${tmp_heuristics}.new" "$tmp_heuristics"
            keyword_updates=$((keyword_updates + 1))
        done <<< "$frequent_words"

        i=$((i + 1))
    done

    # Persist updated heuristics
    jq --arg ts "$(now_iso)" '.last_tuned = $ts' "$tmp_heuristics" > "${tmp_heuristics}.final"
    mv "${tmp_heuristics}.final" "$HEURISTICS_DB"
    rm -f "$tmp_heuristics"

    success "Self-tuned ${keyword_updates} keyword→role mappings"

    # Show what changed
    if [[ "$keyword_updates" -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Updated Keyword Weights:${RESET}"
        jq -r '.keyword_weights | to_entries | sort_by(-.value.weight) | .[:10][] |
            "    \(.key) → \(.value.role) (weight: \(.value.weight), source: \(.value.source))"
        ' "$HEURISTICS_DB" 2>/dev/null || true
    fi

    emit_event "recruit_self_tune" "keywords_updated=${keyword_updates}" "total_matches=${total_matches}"
}
