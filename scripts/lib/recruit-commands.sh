#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2064
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  lib/recruit-commands.sh — High-Level Commands (Team, Mind, Decompose)   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_RECRUIT_COMMANDS_LOADED:-}" ]] && return 0
_RECRUIT_COMMANDS_LOADED=1

SCRIPT_DIR="${SCRIPT_DIR:-.}"
RECRUIT_ROOT="${RECRUIT_ROOT:-${HOME}/.shipwright/recruitment}"
PROFILES_DB="${PROFILES_DB:-${RECRUIT_ROOT}/profiles.json}"
ROLES_DB="${ROLES_DB:-${RECRUIT_ROOT}/roles.json}"
AGENT_MINDS_DB="${AGENT_MINDS_DB:-${RECRUIT_ROOT}/agent-minds.json}"
ONBOARDING_DB="${ONBOARDING_DB:-${RECRUIT_ROOT}/onboarding.json}"

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
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"

# Smart routing: given a task, find the best available agent
cmd_route() {
    local task_description="${1:-}"

    if [[ -z "$task_description" ]]; then
        error "Usage: shipwright recruit route \"<task description>\""
        exit 1
    fi

    ensure_recruit_dir
    initialize_builtin_roles

    info "Smart routing for: ${CYAN}${task_description}${RESET}"
    echo ""

    # Step 1: Determine best role
    local role_match
    role_match=$(_recruit_keyword_match "$task_description")
    local primary_role
    primary_role=$(echo "$role_match" | awk '{print $1}')

    # Step 2: Find best agent for that role
    if [[ -f "$PROFILES_DB" && "$(jq 'length' "$PROFILES_DB" 2>/dev/null || echo 0)" -gt 0 ]]; then
        local best_agent
        best_agent=$(jq -r --arg role "$primary_role" '
            to_entries |
            map(select(.value.role == $role and (.value.tasks_completed // 0) >= 3)) |
            sort_by(-(.value.success_rate // 0)) |
            .[0] // null |
            if . then "\(.key) (\(.value.success_rate)% success over \(.value.tasks_completed) tasks)"
            else null end
        ' "$PROFILES_DB" 2>/dev/null || echo "")

        if [[ -n "$best_agent" && "$best_agent" != "null" ]]; then
            success "Best agent: ${CYAN}${best_agent}${RESET}"
        else
            info "No experienced agent for ${primary_role} role — assign any available agent"
        fi
    fi

    # Step 3: Get recommended model
    local recommended_model
    recommended_model=$(jq -r --arg role "$primary_role" '.[$role].recommended_model // "sonnet"' "$ROLES_DB" 2>/dev/null || echo "sonnet")

    echo "  Role: ${primary_role}"
    echo "  Model: ${recommended_model}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONTEXT-AWARE TEAM COMPOSITION (Tier 2)
# ═══════════════════════════════════════════════════════════════════════════════

cmd_team() {
    local json_mode=false
    if [[ "${1:-}" == "--json" ]]; then
        json_mode=true
        shift
    fi
    local issue_or_project="${1:-}"

    if [[ -z "$issue_or_project" ]]; then
        error "Usage: shipwright recruit team [--json] <issue|project>"
        exit 1
    fi

    ensure_recruit_dir
    initialize_builtin_roles

    if ! $json_mode; then
        info "Recommending team composition for: ${CYAN}${issue_or_project}${RESET}"
        echo ""
    fi

    local recommended_team=()
    local team_method="heuristic"

    # Try LLM-powered team composition first
    if _recruit_has_claude; then
        local available_roles
        available_roles=$(jq -r 'to_entries | map({key: .key, title: .value.title, cost: .value.estimated_cost_per_task_usd}) | tojson' "$ROLES_DB" 2>/dev/null || echo "[]")

        # Gather codebase context if in a git repo
        local codebase_context=""
        if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
            local file_count lang_summary
            file_count=$(git ls-files 2>/dev/null | wc -l | tr -d ' ')
            lang_summary=$(git ls-files 2>/dev/null | grep -oE '\.[^.]+$' | sort | uniq -c | sort -rn | head -5 | tr '\n' ';' || echo "unknown")
            codebase_context="Files: ${file_count}, Languages: ${lang_summary}"
        fi

        local prompt
        prompt="You are a team composition optimizer. Given a task and available roles, recommend the optimal team.

Task/Issue: ${issue_or_project}
Codebase context: ${codebase_context:-unknown}
Available roles: ${available_roles}

Consider:
- Task complexity (simple tasks need fewer roles)
- Risk areas (security-sensitive = add security-auditor)
- Cost efficiency (minimize cost while covering all needs)

Return ONLY a JSON object:
{\"team\": [\"<role_key>\", ...], \"reasoning\": \"<brief explanation>\", \"estimated_cost\": <total_usd>, \"risk_level\": \"low|medium|high\"}

Return JSON only."

        local result
        result=$(_recruit_call_claude "$prompt")

        if [[ -n "$result" ]] && echo "$result" | jq -e '.team' >/dev/null 2>&1; then
            while IFS= read -r role; do
                [[ -z "$role" || "$role" == "null" ]] && continue
                recommended_team+=("$role")
            done < <(echo "$result" | jq -r '.team[]' 2>/dev/null)

            team_method="ai"
            local reasoning
            reasoning=$(echo "$result" | jq -r '.reasoning // ""')
            local risk_level
            risk_level=$(echo "$result" | jq -r '.risk_level // "medium"')

            if [[ -n "$reasoning" ]]; then
                echo -e "  ${DIM}AI reasoning: ${reasoning}${RESET}"
                echo -e "  ${DIM}Risk level: ${risk_level}${RESET}"
                echo ""
            fi
        fi
    fi

    # Fallback: heuristic team composition
    if [[ ${#recommended_team[@]} -eq 0 ]]; then
        recommended_team=("builder" "reviewer" "tester")

        if echo "$issue_or_project" | grep >/dev/null -iE "security|vulnerability|compliance"; then
            recommended_team+=("security-auditor")
        fi
        if echo "$issue_or_project" | grep >/dev/null -iE "architecture|design|refactor"; then
            recommended_team+=("architect")
        fi
        if echo "$issue_or_project" | grep >/dev/null -iE "deploy|infra|ci.cd|pipeline"; then
            recommended_team+=("devops")
        fi
        if echo "$issue_or_project" | grep >/dev/null -iE "performance|speed|latency|optimization"; then
            recommended_team+=("optimizer")
        fi
    fi

    # Compute total cost and model list
    local total_cost
    total_cost=$(printf "%.2f" "$(
        for role in "${recommended_team[@]}"; do
            jq ".\"${role}\".estimated_cost_per_task_usd // 1.5" "$ROLES_DB" 2>/dev/null || echo "1.5"
        done | awk '{sum+=$1} END {print sum}'
    )")

    # Determine primary model (highest-tier model on the team)
    local team_model="sonnet"
    for role in "${recommended_team[@]}"; do
        local rm
        rm=$(jq -r ".\"${role}\".recommended_model // \"sonnet\"" "$ROLES_DB" 2>/dev/null || echo "sonnet")
        if [[ "$rm" == "opus" ]]; then team_model="opus"; break; fi
    done

    emit_event "recruit_team" "size=${#recommended_team[@]}" "method=${team_method}" "cost=${total_cost}"

    # JSON mode: structured output for programmatic consumption
    if $json_mode; then
        local roles_json
        roles_json=$(printf '%s\n' "${recommended_team[@]}" | jq -R . | jq -s .)

        # Derive template and max_iterations from team size/composition (triage needs these)
        local team_template="full"
        local team_max_iterations=10
        local team_size=${#recommended_team[@]}
        if [[ $team_size -le 2 ]]; then
            team_template="quick-fix"
            team_max_iterations=5
        elif [[ $team_size -ge 5 ]]; then
            team_template="careful"
            team_max_iterations=20
        fi
        # Security tasks get more iterations
        if printf '%s\n' "${recommended_team[@]}" | grep >/dev/null "security-auditor"; then
            team_template="careful"
            [[ $team_max_iterations -lt 15 ]] && team_max_iterations=15
        fi

        jq -c -n \
            --argjson team "$roles_json" \
            --arg method "$team_method" \
            --argjson cost "$total_cost" \
            --arg model "$team_model" \
            --argjson agents "$team_size" \
            --arg template "$team_template" \
            --argjson max_iterations "$team_max_iterations" \
            '{
                team: $team,
                method: $method,
                estimated_cost: $cost,
                model: $model,
                agents: $agents,
                template: $template,
                max_iterations: $max_iterations
            }'
        return 0
    fi

    success "Recommended Team (${#recommended_team[@]} members, via ${team_method}):"
    echo ""

    for role in "${recommended_team[@]}"; do
        local role_info
        role_info=$(jq ".\"${role}\"" "$ROLES_DB" 2>/dev/null || echo "null")
        if [[ "$role_info" != "null" ]]; then
            printf "  • ${CYAN}%-20s${RESET} (${PURPLE}%s${RESET}) — %s\n" \
                "$role" \
                "$(echo "$role_info" | jq -r '.recommended_model')" \
                "$(echo "$role_info" | jq -r '.title')"
        else
            printf "  • ${CYAN}%-20s${RESET} (${PURPLE}%s${RESET}) — %s\n" \
                "$role" "sonnet" "Custom role"
        fi
    done

    echo ""
    echo "Estimated Team Cost: \$${total_cost}/task"
}

# ═══════════════════════════════════════════════════════════════════════════════
# AUTONOMOUS ROLE INVENTION (Tier 3)
# ═══════════════════════════════════════════════════════════════════════════════

cmd_invent() {
    ensure_recruit_dir
    initialize_builtin_roles

    info "Scanning for unmatched task patterns to invent new roles..."
    echo ""

    if [[ ! -f "$MATCH_HISTORY" ]]; then
        warn "No match history — run more tasks first"
        return 0
    fi

    # Find tasks that defaulted to builder (low confidence or no keyword match)
    local unmatched_tasks
    unmatched_tasks=$(jq -s -r '
        [.[] | select(
            (.role == "builder" and (.confidence // 0.5) < 0.6) or
            (.method == "keyword" and (.confidence // 0.5) < 0.4)
        ) | .task] | unique | .[:20][]
    ' "$MATCH_HISTORY" 2>/dev/null || true)

    if [[ -z "$unmatched_tasks" ]]; then
        success "No unmatched patterns detected — all tasks well-covered"
        return 0
    fi

    local task_count
    task_count=$(echo "$unmatched_tasks" | wc -l | tr -d ' ')
    info "Found ${task_count} poorly-matched tasks"

    if ! _recruit_has_claude; then
        warn "Claude not available for role invention. Unmatched tasks:"
        echo "$unmatched_tasks" | sed 's/^/    - /'
        return 0
    fi

    local existing_roles
    existing_roles=$(jq -r 'to_entries | map("\(.key): \(.value.description)") | join("\n")' "$ROLES_DB" 2>/dev/null || echo "none")

    local prompt
    prompt="Analyze these tasks that weren't well-matched to existing agent roles. Identify recurring patterns and suggest new roles.

Poorly-matched tasks:
${unmatched_tasks}

Existing roles:
${existing_roles}

If you identify a clear pattern (2+ tasks that share a theme), propose a new role:
{\"roles\": [{\"key\": \"<kebab-case>\", \"title\": \"<Title>\", \"description\": \"<desc>\", \"required_skills\": [\"<skill>\"], \"trigger_keywords\": [\"<keyword>\"], \"recommended_model\": \"sonnet\", \"estimated_cost_per_task_usd\": 1.5}]}

If no new role is needed, return: {\"roles\": [], \"reasoning\": \"existing roles are sufficient\"}

Return JSON only."

    local result
    result=$(_recruit_call_claude "$prompt")

    if [[ -n "$result" ]] && echo "$result" | jq -e '.roles | length > 0' >/dev/null 2>&1; then
        local new_count
        new_count=$(echo "$result" | jq '.roles | length')

        echo ""
        success "Invented ${new_count} new role(s):"
        echo ""

        local i=0
        while [[ "$i" -lt "$new_count" ]]; do
            local role_key role_title role_desc
            role_key=$(echo "$result" | jq -r ".roles[$i].key")
            role_title=$(echo "$result" | jq -r ".roles[$i].title")
            role_desc=$(echo "$result" | jq -r ".roles[$i].description")

            echo -e "  ${CYAN}${BOLD}${role_key}${RESET}: ${role_title}"
            echo -e "  ${DIM}${role_desc}${RESET}"
            echo ""

            # Auto-create the role
            local role_json
            role_json=$(echo "$result" | jq ".roles[$i] | del(.key) + {origin: \"invented\", created_at: \"$(now_iso)\"}")

            local tmp_file
            tmp_file=$(mktemp)
            trap "rm -f '$tmp_file'" RETURN
            jq --arg key "$role_key" --argjson role "$role_json" '.[$key] = $role' "$ROLES_DB" > "$tmp_file" && _recruit_locked_write "$ROLES_DB" "$tmp_file" || rm -f "$tmp_file"

            # Update heuristics with trigger keywords
            local keywords
            keywords=$(echo "$result" | jq -r ".roles[$i].trigger_keywords // [] | .[]" 2>/dev/null || true)
            if [[ -n "$keywords" ]]; then
                local heur_tmp
                heur_tmp=$(mktemp)
                trap "rm -f '$heur_tmp'" RETURN
                while IFS= read -r kw; do
                    [[ -z "$kw" ]] && continue
                    jq --arg kw "$kw" --arg role "$role_key" \
                        '.keyword_weights[$kw] = {role: $role, weight: 10, source: "invented"}' \
                        "$HEURISTICS_DB" > "$heur_tmp" && mv "$heur_tmp" "$HEURISTICS_DB" || true
                done <<< "$keywords"
            fi

            # Log invention
            echo "$role_json" | jq -c --arg key "$role_key" '. + {key: $key}' >> "$INVENTED_ROLES_LOG" 2>/dev/null || true

            emit_event "recruit_role_invented" "role=${role_key}" "title=${role_title}"
            i=$((i + 1))
        done
    else
        local reasoning
        reasoning=$(echo "$result" | jq -r '.reasoning // "no analysis available"' 2>/dev/null || echo "no analysis available")
        info "No new roles needed: ${reasoning}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# THEORY OF MIND: PER-AGENT WORKING STYLE PROFILES (Tier 3)
# ═══════════════════════════════════════════════════════════════════════════════

cmd_mind() {
    local agent_id="${1:-}"

    if [[ -z "$agent_id" ]]; then
        # Show all agent minds
        ensure_recruit_dir

        info "Agent Theory of Mind Profiles:"
        echo ""

        if [[ ! -f "$AGENT_MINDS_DB" || "$(jq 'length' "$AGENT_MINDS_DB" 2>/dev/null || echo 0)" -eq 0 ]]; then
            warn "No agent mind profiles yet. Use 'shipwright recruit mind <agent-id>' after recording outcomes."
            return 0
        fi

        jq -r 'to_entries[] |
            "\(.key):" +
            "\n  Style: \(.value.working_style // "unknown")" +
            "\n  Strengths: \(.value.strengths // [] | join(", "))" +
            "\n  Weaknesses: \(.value.weaknesses // [] | join(", "))" +
            "\n  Best with: \(.value.ideal_task_type // "general")" +
            "\n  Onboarding: \(.value.onboarding_preference // "standard")\n"
        ' "$AGENT_MINDS_DB" 2>/dev/null || warn "Could not read mind profiles"
        return 0
    fi

    ensure_recruit_dir

    info "Building theory of mind for: ${CYAN}${agent_id}${RESET}"
    echo ""

    # Gather agent's task history
    local profile
    profile=$(jq ".\"${agent_id}\" // {}" "$PROFILES_DB" 2>/dev/null || echo "{}")

    if [[ "$profile" == "{}" ]]; then
        warn "No profile data for ${agent_id}"
        return 1
    fi

    local task_history
    task_history=$(echo "$profile" | jq -c '.task_history // []')
    local success_rate
    success_rate=$(echo "$profile" | jq -r '.success_rate // 0')
    local avg_time
    avg_time=$(echo "$profile" | jq -r '.avg_time_minutes // 0')
    local tasks_completed
    tasks_completed=$(echo "$profile" | jq -r '.tasks_completed // 0')

    # Heuristic mind model
    local working_style="balanced"
    local strengths=()
    local weaknesses=()
    local ideal_task_type="general"
    local onboarding_pref="standard"

    # Analyze speed
    if awk -v t="$avg_time" 'BEGIN{exit !(t < 10)}' 2>/dev/null; then
        working_style="fast-iterative"
        strengths+=("speed")
        onboarding_pref="minimal-context"
    elif awk -v t="$avg_time" 'BEGIN{exit !(t > 30)}' 2>/dev/null; then
        working_style="thorough-methodical"
        strengths+=("thoroughness")
        onboarding_pref="detailed-specs"
    fi

    # Analyze success rate
    if awk -v s="$success_rate" 'BEGIN{exit !(s >= 90)}' 2>/dev/null; then
        strengths+=("reliability")
    elif awk -v s="$success_rate" 'BEGIN{exit !(s < 60)}' 2>/dev/null; then
        weaknesses+=("consistency")
    fi

    # LLM-powered mind profile
    if _recruit_has_claude && [[ "$tasks_completed" -ge 5 ]]; then
        local prompt
        prompt="Build a psychological profile for an AI agent based on its performance history.

Agent: ${agent_id}
Tasks completed: ${tasks_completed}
Success rate: ${success_rate}%
Avg time per task: ${avg_time} minutes
Recent task history: ${task_history}

Create a working style profile:
{\"working_style\": \"<fast-iterative|thorough-methodical|balanced|creative-exploratory>\",
 \"strengths\": [\"<strength1>\", \"<strength2>\"],
 \"weaknesses\": [\"<weakness1>\"],
 \"ideal_task_type\": \"<description of best-fit tasks>\",
 \"onboarding_preference\": \"<minimal-context|detailed-specs|example-driven|standard>\",
 \"collaboration_style\": \"<independent|pair-oriented|team-player>\"}

Return JSON only."

        local result
        result=$(_recruit_call_claude "$prompt")

        if [[ -n "$result" ]] && echo "$result" | jq -e '.working_style' >/dev/null 2>&1; then
            # Save the LLM-generated mind profile
            local tmp_file
            tmp_file=$(mktemp)
            trap "rm -f '$tmp_file'" RETURN
            jq --arg id "$agent_id" --argjson mind "$result" '.[$id] = ($mind + {updated: (now | todate)})' "$AGENT_MINDS_DB" > "$tmp_file" && _recruit_locked_write "$AGENT_MINDS_DB" "$tmp_file" || rm -f "$tmp_file"

            success "Mind profile generated:"
            echo "$result" | jq -r '
                "  Working style: \(.working_style)" +
                "\n  Strengths: \(.strengths | join(", "))" +
                "\n  Weaknesses: \(.weaknesses | join(", "))" +
                "\n  Ideal tasks: \(.ideal_task_type)" +
                "\n  Onboarding: \(.onboarding_preference)" +
                "\n  Collaboration: \(.collaboration_style // "standard")"
            '
            emit_event "recruit_mind" "agent_id=${agent_id}"
            return 0
        fi
    fi

    # Fallback: save heuristic profile
    local strengths_json weaknesses_json
    if [[ ${#strengths[@]} -gt 0 ]]; then
        strengths_json=$(printf '%s\n' "${strengths[@]}" | jq -R . | jq -s .)
    else
        strengths_json='[]'
    fi
    if [[ ${#weaknesses[@]} -gt 0 ]]; then
        weaknesses_json=$(printf '%s\n' "${weaknesses[@]}" | jq -R . | jq -s .)
    else
        weaknesses_json='[]'
    fi

    local mind_json
    mind_json=$(jq -n \
        --arg style "$working_style" \
        --argjson strengths "$strengths_json" \
        --argjson weaknesses "$weaknesses_json" \
        --arg ideal "$ideal_task_type" \
        --arg onboard "$onboarding_pref" \
        --arg ts "$(now_iso)" \
        '{working_style: $style, strengths: $strengths, weaknesses: $weaknesses, ideal_task_type: $ideal, onboarding_preference: $onboard, updated: $ts}')

    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN
    jq --arg id "$agent_id" --argjson mind "$mind_json" '.[$id] = $mind' "$AGENT_MINDS_DB" > "$tmp_file" && _recruit_locked_write "$AGENT_MINDS_DB" "$tmp_file" || rm -f "$tmp_file"

    local strengths_display="none detected"
    [[ ${#strengths[@]} -gt 0 ]] && strengths_display="${strengths[*]}"

    success "Mind profile (heuristic):"
    echo "  Working style: ${working_style}"
    echo "  Strengths: ${strengths_display}"
    echo "  Onboarding: ${onboarding_pref}"
    emit_event "recruit_mind" "agent_id=${agent_id}" "method=heuristic"
}

# ═══════════════════════════════════════════════════════════════════════════════
# GOAL DECOMPOSITION (Tier 3)
# ═══════════════════════════════════════════════════════════════════════════════

cmd_decompose() {
    local goal="${1:-}"

    if [[ -z "$goal" ]]; then
        error "Usage: shipwright recruit decompose \"<vague goal or intent>\""
        exit 1
    fi

    ensure_recruit_dir
    initialize_builtin_roles

    info "Decomposing goal: ${CYAN}${goal}${RESET}"
    echo ""

    local available_roles
    available_roles=$(jq -r 'to_entries | map("\(.key): \(.value.title) — \(.value.description)") | join("\n")' "$ROLES_DB" 2>/dev/null || echo "none")

    if _recruit_has_claude; then
        local prompt
        prompt="Decompose this high-level goal into specific sub-tasks, and assign the best agent role for each.

Goal: ${goal}

Available agent roles:
${available_roles}

Return a JSON object:
{\"goal\": \"<restated goal>\",
 \"sub_tasks\": [
   {\"task\": \"<specific task>\", \"role\": \"<role_key>\", \"priority\": \"high|medium|low\", \"depends_on\": [], \"estimated_time_min\": 30},
   ...
 ],
 \"capability_gaps\": [\"<any capabilities not covered by existing roles>\"],
 \"total_estimated_time_min\": 120,
 \"risk_assessment\": \"<brief risk summary>\"}

Return JSON only."

        local result
        result=$(_recruit_call_claude "$prompt")

        if [[ -n "$result" ]] && echo "$result" | jq -e '.sub_tasks' >/dev/null 2>&1; then
            local restated_goal
            restated_goal=$(echo "$result" | jq -r '.goal // ""')
            [[ -n "$restated_goal" ]] && echo -e "  ${DIM}Interpreted as: ${restated_goal}${RESET}"
            echo ""

            local task_count
            task_count=$(echo "$result" | jq '.sub_tasks | length')
            success "Decomposed into ${task_count} sub-tasks:"
            echo ""

            echo "$result" | jq -r '.sub_tasks | to_entries[] |
                "  \(.key + 1). [\(.value.priority // "medium")] \(.value.task)" +
                "\n     Role: \(.value.role) | Est: \(.value.estimated_time_min // "?")min" +
                (if (.value.depends_on | length) > 0 then "\n     Depends on: \(.value.depends_on | join(", "))" else "" end)
            '

            # Show capability gaps
            local gaps
            gaps=$(echo "$result" | jq -r '.capability_gaps // [] | .[]' 2>/dev/null || true)
            if [[ -n "$gaps" ]]; then
                echo ""
                warn "Capability gaps detected:"
                echo "$gaps" | sed 's/^/    - /'
                echo "  Consider: shipwright recruit create-role --auto \"<gap description>\""
            fi

            # Show totals
            local total_time
            total_time=$(echo "$result" | jq -r '.total_estimated_time_min // 0')
            local risk
            risk=$(echo "$result" | jq -r '.risk_assessment // "unknown"')
            echo ""
            echo "  Total estimated time: ${total_time} minutes"
            echo "  Risk: ${risk}"

            emit_event "recruit_decompose" "goal_length=${#goal}" "tasks=${task_count}" "gaps=$(echo "$gaps" | wc -l | tr -d ' ')"
            return 0
        fi
    fi

    # Fallback: simple decomposition
    warn "AI decomposition unavailable — showing default breakdown"
    echo ""
    echo "  1. [high] Plan and design the approach"
    echo "     Role: architect"
    echo "  2. [high] Implement the solution"
    echo "     Role: builder"
    echo "  3. [medium] Write tests"
    echo "     Role: tester"
    echo "  4. [medium] Code review"
    echo "     Role: reviewer"
    echo "  5. [low] Update documentation"
    echo "     Role: docs-writer"
}

# ═══════════════════════════════════════════════════════════════════════════════
# AGENT PROMOTION (Tier 2)
# ═══════════════════════════════════════════════════════════════════════════════

cmd_promote() {
    local agent_id="${1:-}"

    if [[ -z "$agent_id" ]]; then
        error "Usage: shipwright recruit promote <agent-id>"
        exit 1
    fi

    ensure_recruit_dir

    info "Evaluating promotion eligibility for: ${CYAN}${agent_id}${RESET}"
    echo ""

    local profile
    profile=$(jq ".\"${agent_id}\"" "$PROFILES_DB" 2>/dev/null || echo "{}")

    if [[ "$profile" == "{}" || "$profile" == "null" ]]; then
        warn "No profile found for ${agent_id}"
        return 1
    fi

    local success_rate quality_score
    success_rate=$(echo "$profile" | jq -r '.success_rate // 0')
    quality_score=$(echo "$profile" | jq -r '.quality_score // 0')

    local current_model
    current_model=$(echo "$profile" | jq -r '.model // "haiku"')

    # Use population-aware thresholds
    local pop_stats
    pop_stats=$(_recruit_compute_population_stats)
    local mean_success
    mean_success=$(echo "$pop_stats" | jq -r '.mean_success')
    local agent_count
    agent_count=$(echo "$pop_stats" | jq -r '.count')

    local promote_sr_threshold="${RECRUIT_PROMOTE_SUCCESS:-85}"
    local promote_q_threshold=9
    local demote_sr_threshold=60
    local demote_q_threshold=5

    if [[ "$agent_count" -ge 3 ]]; then
        local stddev
        stddev=$(echo "$pop_stats" | jq -r '.stddev_success')
        promote_sr_threshold=$(awk -v m="$mean_success" -v s="$stddev" 'BEGIN{v=m+s; if(v>98) v=98; printf "%.0f", v}')
        demote_sr_threshold=$(awk -v m="$mean_success" -v s="$stddev" 'BEGIN{v=m-1.5*s; if(v<30) v=30; printf "%.0f", v}')
    fi

    local recommended_model="$current_model"
    local promotion_reason=""

    if awk -v sr="$success_rate" -v st="$promote_sr_threshold" -v qs="$quality_score" -v qt="$promote_q_threshold" \
       'BEGIN{exit !(sr >= st && qs >= qt)}' 2>/dev/null; then
        case "$current_model" in
            haiku)    recommended_model="sonnet"; promotion_reason="Excellent performance on Haiku" ;;
            sonnet)   recommended_model="opus"; promotion_reason="Outstanding results on Sonnet" ;;
            opus)     promotion_reason="Already on best model"; recommended_model="opus" ;;
        esac
    elif awk -v sr="$success_rate" -v st="$demote_sr_threshold" -v qs="$quality_score" -v qt="$demote_q_threshold" \
         'BEGIN{exit !(sr < st || qs < qt)}' 2>/dev/null; then
        case "$current_model" in
            opus)     recommended_model="sonnet"; promotion_reason="Struggling on Opus, try Sonnet" ;;
            sonnet)   recommended_model="haiku"; promotion_reason="Poor performance, reduce cost" ;;
            haiku)    promotion_reason="Consider retraining"; recommended_model="haiku" ;;
        esac
    fi

    if [[ "$recommended_model" != "$current_model" ]]; then
        success "Recommend upgrading from ${CYAN}${current_model}${RESET} to ${PURPLE}${recommended_model}${RESET}"
        echo "  Reason: $promotion_reason"
        echo -e "  ${DIM}Thresholds: promote ≥${promote_sr_threshold}%, demote <${demote_sr_threshold}% (${agent_count} agents in population)${RESET}"
        emit_event "recruit_promotion" "agent_id=${agent_id}" "from=${current_model}" "to=${recommended_model}" "reason=${promotion_reason}"
    else
        info "No model change recommended for ${agent_id}"
        echo "  Current: ${current_model} | Success: ${success_rate}% | Quality: ${quality_score}/10"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# ONBOARDING CONTEXT GENERATION
# ═══════════════════════════════════════════════════════════════════════════════

cmd_onboard() {
    local agent_role="${1:-builder}"
    local agent_id="${2:-}"

    ensure_recruit_dir
    initialize_builtin_roles

    info "Generating onboarding context for: ${CYAN}${agent_role}${RESET}"
    echo ""

    local role_info
    role_info=$(jq --arg role "$agent_role" '.[$role]' "$ROLES_DB" 2>/dev/null)

    if [[ -z "$role_info" || "$role_info" == "null" ]]; then
        error "Unknown role: ${agent_role}"
        exit 1
    fi

    # Build adaptive onboarding based on theory-of-mind if available
    local onboarding_style="standard"
    if [[ -n "$agent_id" && -f "$AGENT_MINDS_DB" ]]; then
        local mind_profile
        mind_profile=$(jq ".\"${agent_id}\"" "$AGENT_MINDS_DB" 2>/dev/null || echo "null")
        if [[ "$mind_profile" != "null" ]]; then
            onboarding_style=$(echo "$mind_profile" | jq -r '.onboarding_preference // "standard"')
            info "Adapting onboarding to agent preference: ${PURPLE}${onboarding_style}${RESET}"
        fi
    fi

    # Build onboarding style description outside the heredoc
    local style_desc="Standard onboarding. Review the role profile and codebase structure."
    case "$onboarding_style" in
        minimal-context) style_desc="This agent works best with minimal upfront context. Provide the core task and let them explore." ;;
        detailed-specs) style_desc="This agent prefers detailed specifications. Provide full requirements, edge cases, and examples." ;;
        example-driven) style_desc="This agent learns best from examples. Provide sample inputs/outputs and reference implementations." ;;
    esac

    local role_title_val role_desc_val role_model_val role_origin_val role_cost_val
    role_title_val=$(echo "$role_info" | jq -r '.title')
    role_desc_val=$(echo "$role_info" | jq -r '.description')
    role_model_val=$(echo "$role_info" | jq -r '.recommended_model')
    role_origin_val=$(echo "$role_info" | jq -r '.origin // "builtin"')
    role_cost_val=$(echo "$role_info" | jq -r '.estimated_cost_per_task_usd')
    local role_skills_val role_context_val role_metrics_val
    role_skills_val=$(echo "$role_info" | jq -r '.required_skills[]' | sed 's/^/- /')
    role_context_val=$(echo "$role_info" | jq -r '.context_needs[]' | sed 's/^/- /')
    role_metrics_val=$(echo "$role_info" | jq -r '.success_metrics[]' | sed 's/^/- /')

    local onboarding_doc
    onboarding_doc="# Onboarding Context: ${agent_role}

## Role Profile
**Title:** ${role_title_val}
**Description:** ${role_desc_val}
**Recommended Model:** ${role_model_val}
**Origin:** ${role_origin_val}

## Required Skills
${role_skills_val}

## Context Needs
${role_context_val}

## Success Metrics
${role_metrics_val}

## Cost Profile
Estimated cost per task: \$${role_cost_val}

## Onboarding Style: ${onboarding_style}
${style_desc}

## Getting Started
1. Review the role profile above
2. Study the codebase architecture
3. Familiarize yourself with coding standards
4. Review past pipeline runs for patterns
5. Ask questions about unclear requirements

## Resources
- Codebase: /path/to/repo
- Documentation: See .claude/ directory
- Team patterns: Reviewed in memory system
- Past learnings: Available in ~/.shipwright/memory/"

    local onboarding_key
    onboarding_key=$(date +%s)
    jq --arg key "$onboarding_key" --arg doc "$onboarding_doc" '.[$key] = $doc' "$ONBOARDING_DB" > "${ONBOARDING_DB}.tmp"
    mv "${ONBOARDING_DB}.tmp" "$ONBOARDING_DB"

    success "Onboarding context generated for ${agent_role}"
    echo ""
    echo "$onboarding_doc"
    emit_event "recruit_onboarding" "role=${agent_role}" "style=${onboarding_style}" "timestamp=$(now_epoch)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STATISTICS REPORTING
# ═══════════════════════════════════════════════════════════════════════════════

cmd_stats() {
    ensure_recruit_dir

    info "Recruitment Statistics & Talent Trends:"
    echo ""

    local role_count profile_count talent_count
    role_count=$(jq 'length' "$ROLES_DB" 2>/dev/null || echo 0)
    profile_count=$(jq 'length' "$PROFILES_DB" 2>/dev/null || echo 0)
    talent_count=$(jq 'length' "$TALENT_DB" 2>/dev/null || echo 0)

    local builtin_count custom_count invented_count
    builtin_count=$(jq '[.[] | select(.origin == "builtin" or .origin == null)] | length' "$ROLES_DB" 2>/dev/null || echo 0)
    custom_count=$(jq '[.[] | select(.origin == "manual" or .origin == "ai-generated")] | length' "$ROLES_DB" 2>/dev/null || echo 0)
    invented_count=$(jq '[.[] | select(.origin == "invented")] | length' "$ROLES_DB" 2>/dev/null || echo 0)

    echo "  Roles Defined:        $role_count (builtin: ${builtin_count}, custom: ${custom_count}, invented: ${invented_count})"
    echo "  Agents Profiled:      $profile_count"
    echo "  Talent Records:       $talent_count"

    if [[ -f "$MATCH_HISTORY" ]]; then
        local match_count
        match_count=$(wc -l < "$MATCH_HISTORY" 2>/dev/null | tr -d ' ')
        echo "  Match History:        ${match_count} records"
    fi

    if [[ -f "$HEURISTICS_DB" ]]; then
        local keyword_count last_tuned
        keyword_count=$(jq '.keyword_weights | length' "$HEURISTICS_DB" 2>/dev/null || echo 0)
        last_tuned=$(jq -r '.last_tuned // "never"' "$HEURISTICS_DB" 2>/dev/null || echo "never")
        echo "  Learned Keywords:     ${keyword_count}"
        echo "  Last Self-Tuned:      ${last_tuned}"
    fi

    if [[ -f "$META_LEARNING_DB" ]]; then
        local corrections accuracy_points
        corrections=$(jq '.corrections | length' "$META_LEARNING_DB" 2>/dev/null || echo 0)
        accuracy_points=$(jq '.accuracy_trend | length' "$META_LEARNING_DB" 2>/dev/null || echo 0)
        echo "  Meta-Learning Corrections: ${corrections}"
        echo "  Accuracy Data Points: ${accuracy_points}"
    fi

    echo ""

    if [[ "$profile_count" -gt 0 ]]; then
        local pop_stats
        pop_stats=$(_recruit_compute_population_stats)
        echo "  Population Stats:"
        echo "    Mean Success Rate:  $(echo "$pop_stats" | jq -r '.mean_success')%"
        echo "    Std Dev:            $(echo "$pop_stats" | jq -r '.stddev_success')%"
        echo "    P90/P10 Spread:     $(echo "$pop_stats" | jq -r '.p90_success')% / $(echo "$pop_stats" | jq -r '.p10_success')%"
        echo ""
    fi

    success "Use 'shipwright recruit profiles' for detailed breakdown"
}
