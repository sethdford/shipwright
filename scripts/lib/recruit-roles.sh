#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2064
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  lib/recruit-roles.sh — Role Management, Creation, Matching, Evaluation  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_RECRUIT_ROLES_LOADED:-}" ]] && return 0
_RECRUIT_ROLES_LOADED=1

SCRIPT_DIR="${SCRIPT_DIR:-.}"
RECRUIT_ROOT="${RECRUIT_ROOT:-${HOME}/.shipwright/recruitment}"
ROLES_DB="${ROLES_DB:-${RECRUIT_ROOT}/roles.json}"
PROFILES_DB="${PROFILES_DB:-${RECRUIT_ROOT}/profiles.json}"
MATCH_HISTORY="${MATCH_HISTORY:-${RECRUIT_ROOT}/match-history.jsonl}"
ROLE_USAGE_DB="${ROLE_USAGE_DB:-${RECRUIT_ROOT}/role-usage.json}"
HEURISTICS_DB="${HEURISTICS_DB:-${RECRUIT_ROOT}/heuristics.json}"

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

# ═══════════════════════════════════════════════════════════════════════════════
# BUILT-IN ROLE DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════════

initialize_builtin_roles() {
    ensure_recruit_dir

    if jq -e '.architect' "$ROLES_DB" >/dev/null 2>&1; then
        return 0
    fi

    local roles_json
    roles_json=$(cat <<'EOF'
{
  "architect": {
    "title": "Architect",
    "description": "System design, architecture decisions, scalability planning",
    "required_skills": ["system-design", "technology-evaluation", "code-review", "documentation"],
    "recommended_model": "opus",
    "context_needs": ["codebase-architecture", "system-patterns", "past-designs", "dependency-graph"],
    "success_metrics": ["design-quality", "implementation-feasibility", "team-alignment"],
    "estimated_cost_per_task_usd": 2.5,
    "origin": "builtin",
    "created_at": "2025-01-01T00:00:00Z"
  },
  "builder": {
    "title": "Builder",
    "description": "Feature implementation, core development, code generation",
    "required_skills": ["coding", "testing", "debugging", "performance-optimization"],
    "recommended_model": "sonnet",
    "context_needs": ["codebase-structure", "api-specs", "test-patterns", "build-system"],
    "success_metrics": ["tests-passing", "code-quality", "productivity", "bug-rate"],
    "estimated_cost_per_task_usd": 1.5,
    "origin": "builtin",
    "created_at": "2025-01-01T00:00:00Z"
  },
  "reviewer": {
    "title": "Code Reviewer",
    "description": "Code review, quality assurance, best practices enforcement",
    "required_skills": ["code-review", "static-analysis", "security-review", "best-practices"],
    "recommended_model": "sonnet",
    "context_needs": ["coding-standards", "previous-reviews", "common-errors", "team-patterns"],
    "success_metrics": ["review-quality", "issue-detection-rate", "feedback-clarity"],
    "estimated_cost_per_task_usd": 1.2,
    "origin": "builtin",
    "created_at": "2025-01-01T00:00:00Z"
  },
  "tester": {
    "title": "Test Specialist",
    "description": "Test strategy, test case generation, test automation, quality validation",
    "required_skills": ["testing", "coverage-analysis", "automation", "edge-case-detection"],
    "recommended_model": "sonnet",
    "context_needs": ["test-framework", "coverage-metrics", "failure-patterns", "requirements"],
    "success_metrics": ["coverage-increase", "bug-detection", "test-execution-time"],
    "estimated_cost_per_task_usd": 1.2,
    "origin": "builtin",
    "created_at": "2025-01-01T00:00:00Z"
  },
  "security-auditor": {
    "title": "Security Auditor",
    "description": "Security analysis, vulnerability detection, compliance verification",
    "required_skills": ["security-analysis", "threat-modeling", "penetration-testing", "compliance"],
    "recommended_model": "opus",
    "context_needs": ["security-policies", "vulnerability-database", "threat-models", "compliance-reqs"],
    "success_metrics": ["vulnerabilities-found", "severity-accuracy", "remediation-quality"],
    "estimated_cost_per_task_usd": 2.0,
    "origin": "builtin",
    "created_at": "2025-01-01T00:00:00Z"
  },
  "docs-writer": {
    "title": "Documentation Writer",
    "description": "Documentation creation, API docs, user guides, onboarding materials",
    "required_skills": ["documentation", "clarity", "completeness", "example-generation"],
    "recommended_model": "haiku",
    "context_needs": ["codebase-knowledge", "api-specs", "user-personas", "doc-templates"],
    "success_metrics": ["documentation-completeness", "clarity-score", "example-coverage"],
    "estimated_cost_per_task_usd": 0.8,
    "origin": "builtin",
    "created_at": "2025-01-01T00:00:00Z"
  },
  "optimizer": {
    "title": "Performance Optimizer",
    "description": "Performance analysis, optimization, profiling, efficiency improvements",
    "required_skills": ["performance-analysis", "profiling", "optimization", "metrics-analysis"],
    "recommended_model": "sonnet",
    "context_needs": ["performance-benchmarks", "profiling-tools", "optimization-history"],
    "success_metrics": ["performance-gain", "memory-efficiency", "latency-reduction"],
    "estimated_cost_per_task_usd": 1.5,
    "origin": "builtin",
    "created_at": "2025-01-01T00:00:00Z"
  },
  "devops": {
    "title": "DevOps Engineer",
    "description": "Infrastructure, deployment pipelines, CI/CD, monitoring, reliability",
    "required_skills": ["infrastructure-as-code", "deployment", "monitoring", "incident-response"],
    "recommended_model": "sonnet",
    "context_needs": ["infrastructure-config", "deployment-pipelines", "monitoring-setup", "runbooks"],
    "success_metrics": ["deployment-success-rate", "incident-response-time", "uptime"],
    "estimated_cost_per_task_usd": 1.8,
    "origin": "builtin",
    "created_at": "2025-01-01T00:00:00Z"
  },
  "pm": {
    "title": "Project Manager",
    "description": "Task decomposition, priority management, stakeholder communication, tracking",
    "required_skills": ["task-decomposition", "prioritization", "communication", "planning"],
    "recommended_model": "sonnet",
    "context_needs": ["project-state", "requirements", "team-capacity", "past-estimates"],
    "success_metrics": ["estimation-accuracy", "deadline-met", "scope-management"],
    "estimated_cost_per_task_usd": 1.0,
    "origin": "builtin",
    "created_at": "2025-01-01T00:00:00Z"
  },
  "incident-responder": {
    "title": "Incident Responder",
    "description": "Crisis management, root cause analysis, rapid issue resolution, hotfixes",
    "required_skills": ["crisis-management", "root-cause-analysis", "debugging", "communication"],
    "recommended_model": "opus",
    "context_needs": ["incident-history", "system-health", "alerting-rules", "past-incidents"],
    "success_metrics": ["incident-resolution-time", "accuracy", "escalation-prevention"],
    "estimated_cost_per_task_usd": 2.0,
    "origin": "builtin",
    "created_at": "2025-01-01T00:00:00Z"
  }
}
EOF
)
    local _tmp_roles
    _tmp_roles=$(mktemp)
    trap "rm -f '$_tmp_roles'" RETURN
    if echo "$roles_json" | jq '.' > "$_tmp_roles" 2>/dev/null && [[ -s "$_tmp_roles" ]]; then
        mv "$_tmp_roles" "$ROLES_DB"
    else
        rm -f "$_tmp_roles"
        error "Failed to initialize roles DB"
        return 1
    fi
    success "Initialized 10 built-in agent roles"
}

# ═══════════════════════════════════════════════════════════════════════════════
# LLM-POWERED SEMANTIC MATCHING (Tier 1)
# ═══════════════════════════════════════════════════════════════════════════════

_recruit_keyword_match() {
    local task_description="$1"
    local detected_skills=""

    # Always run built-in regex patterns first (most reliable)
    [[ "$task_description" =~ (architecture|design|scalability) ]] && detected_skills="${detected_skills}architect "
    [[ "$task_description" =~ (build|feature|implement|code) ]] && detected_skills="${detected_skills}builder "
    [[ "$task_description" =~ (review|quality|best.practice) ]] && detected_skills="${detected_skills}reviewer "
    [[ "$task_description" =~ (test|coverage|automation) ]] && detected_skills="${detected_skills}tester "
    [[ "$task_description" =~ (security|vulnerability|compliance) ]] && detected_skills="${detected_skills}security-auditor "
    [[ "$task_description" =~ (document|guide|readme|api.doc|write.doc) ]] && detected_skills="${detected_skills}docs-writer "
    [[ "$task_description" =~ (performance|optimization|profile|speed|latency|faster) ]] && detected_skills="${detected_skills}optimizer "
    [[ "$task_description" =~ (deploy|infra|ci.cd|monitoring|docker|kubernetes) ]] && detected_skills="${detected_skills}devops "
    [[ "$task_description" =~ (plan|decompose|estimate|priorit) ]] && detected_skills="${detected_skills}pm "
    [[ "$task_description" =~ (urgent|incident|crisis|hotfix|outage) ]] && detected_skills="${detected_skills}incident-responder "

    # Boost with learned keyword weights (override only if no regex match)
    if [[ -z "$detected_skills" && -f "$HEURISTICS_DB" ]]; then
        local learned_weights
        learned_weights=$(jq -r '.keyword_weights // {}' "$HEURISTICS_DB" 2>/dev/null || echo "{}")

        if [[ -n "$learned_weights" && "$learned_weights" != "{}" && "$learned_weights" != "null" ]]; then
            local best_role="" best_score=0
            local task_lower
            task_lower=$(echo "$task_description" | tr '[:upper:]' '[:lower:]')

            while IFS= read -r keyword; do
                [[ -z "$keyword" ]] && continue
                local kw_lower
                kw_lower=$(echo "$keyword" | tr '[:upper:]' '[:lower:]')
                if echo "$task_lower" | grep >/dev/null "$kw_lower" 2>/dev/null; then
                    local role_score
                    role_score=$(echo "$learned_weights" | jq -r --arg k "$keyword" '.[$k] | if type == "object" then .role else "" end' 2>/dev/null || echo "")
                    local weight
                    weight=$(echo "$learned_weights" | jq -r --arg k "$keyword" '.[$k] | if type == "object" then .weight else (. // 0) end' 2>/dev/null || echo "0")

                    if [[ -n "$role_score" && "$role_score" != "null" && "$role_score" != "" ]]; then
                        if awk -v w="$weight" -v b="$best_score" 'BEGIN{exit !(w > b)}' 2>/dev/null; then
                            best_role="$role_score"
                            best_score="$weight"
                        fi
                    fi
                fi
            done < <(echo "$learned_weights" | jq -r 'keys[]' 2>/dev/null || true)

            if [[ -n "$best_role" ]]; then
                detected_skills="$best_role"
            fi
        fi
    fi

    # Default to builder if no match
    if [[ -z "$detected_skills" ]]; then
        detected_skills="builder"
    fi

    echo "$detected_skills"
}

# LLM-powered semantic matching
_recruit_llm_match() {
    local task_description="$1"
    local available_roles="$2"

    local prompt
    prompt="You are an agent recruitment system. Given a task description, select the best role(s) from the available roles.

Task: ${task_description}

Available roles (JSON):
${available_roles}

Return ONLY a JSON object with:
{\"primary_role\": \"<role_key>\", \"secondary_roles\": [\"<role_key>\", ...], \"confidence\": <0.0-1.0>, \"reasoning\": \"<one line>\", \"new_role_needed\": false, \"suggested_role\": null}

If NO existing role is a good fit, set new_role_needed=true and provide:
{\"primary_role\": \"builder\", \"secondary_roles\": [], \"confidence\": 0.3, \"reasoning\": \"...\", \"new_role_needed\": true, \"suggested_role\": {\"key\": \"<kebab-case>\", \"title\": \"<Title>\", \"description\": \"<desc>\", \"required_skills\": [\"<skill>\"], \"recommended_model\": \"sonnet\", \"context_needs\": [\"<need>\"], \"success_metrics\": [\"<metric>\"], \"estimated_cost_per_task_usd\": 1.5}}

Return JSON only, no markdown fences."

    local result
    result=$(_recruit_call_claude "$prompt")

    if [[ -n "$result" ]] && echo "$result" | jq -e '.primary_role' >/dev/null 2>&1; then
        echo "$result"
        return 0
    fi

    echo ""
}

# Record a match for learning
_recruit_record_match() {
    local task="$1"
    local role="$2"
    local method="$3"
    local confidence="${4:-0.5}"
    local agent_id="${5:-}"

    mkdir -p "$RECRUIT_ROOT"
    local match_epoch
    match_epoch=$(now_epoch)
    local match_id="match-${match_epoch}-$$"

    local record
    record=$(jq -c -n \
        --arg ts "$(now_iso)" \
        --argjson epoch "$match_epoch" \
        --arg match_id "$match_id" \
        --arg task "$task" \
        --arg role "$role" \
        --arg method "$method" \
        --argjson conf "$confidence" \
        --arg agent "$agent_id" \
        '{ts: $ts, ts_epoch: $epoch, match_id: $match_id, task: $task, role: $role, method: $method, confidence: $conf, agent_id: $agent, outcome: null}')
    echo "$record" >> "$MATCH_HISTORY"

    # Enforce max match history size (from policy)
    local max_history="${RECRUIT_MAX_MATCH_HISTORY:-5000}"
    local current_lines
    current_lines=$(wc -l < "$MATCH_HISTORY" 2>/dev/null | tr -d ' ')
    if [[ "$current_lines" -gt "$max_history" ]]; then
        local tmp_trunc
        tmp_trunc=$(mktemp)
        trap "rm -f '$tmp_trunc'" RETURN
        tail -n "$max_history" "$MATCH_HISTORY" > "$tmp_trunc" && _recruit_locked_write "$MATCH_HISTORY" "$tmp_trunc" || rm -f "$tmp_trunc"
    fi

    # Update role usage stats
    _recruit_track_role_usage "$role" "match"

    # Store match_id in global for callers (avoids stdout contamination)
    LAST_MATCH_ID="$match_id"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DYNAMIC ROLE CREATION (Tier 1)
# ═══════════════════════════════════════════════════════════════════════════════

cmd_create_role() {
    local role_key="${1:-}"
    local role_title="${2:-}"
    local role_desc="${3:-}"

    if [[ -z "$role_key" ]]; then
        error "Usage: shipwright recruit create-role <key> [title] [description]"
        echo "  Or use: shipwright recruit create-role --auto \"<task description>\""
        exit 1
    fi

    ensure_recruit_dir
    initialize_builtin_roles

    # Auto-generate via LLM if --auto flag
    if [[ "$role_key" == "--auto" ]]; then
        local task_desc="${role_title:-$role_desc}"
        if [[ -z "$task_desc" ]]; then
            error "Usage: shipwright recruit create-role --auto \"<task description>\""
            exit 1
        fi

        info "Generating role definition via AI for: ${CYAN}${task_desc}${RESET}"

        local existing_roles
        existing_roles=$(jq -r 'keys | join(", ")' "$ROLES_DB" 2>/dev/null || echo "none")

        local prompt
        prompt="Create a new agent role definition for a task that doesn't fit existing roles.

Task description: ${task_desc}
Existing roles: ${existing_roles}

Return ONLY a JSON object:
{\"key\": \"<kebab-case-unique-key>\", \"title\": \"<Title>\", \"description\": \"<description>\", \"required_skills\": [\"<skill1>\", \"<skill2>\", \"<skill3>\"], \"recommended_model\": \"sonnet\", \"context_needs\": [\"<need1>\", \"<need2>\"], \"success_metrics\": [\"<metric1>\", \"<metric2>\"], \"estimated_cost_per_task_usd\": 1.5}

Return JSON only."

        local result
        result=$(_recruit_call_claude "$prompt")

        if [[ -n "$result" ]] && echo "$result" | jq -e '.key' >/dev/null 2>&1; then
            role_key=$(echo "$result" | jq -r '.key')
            role_title=$(echo "$result" | jq -r '.title')
            role_desc=$(echo "$result" | jq -r '.description')

            # Add origin and timestamp
            result=$(echo "$result" | jq --arg ts "$(now_iso)" '. + {origin: "ai-generated", created_at: $ts}')

            # Persist to roles DB
            local tmp_file
            tmp_file=$(mktemp)
            trap "rm -f '$tmp_file'" RETURN
            if jq --arg key "$role_key" --argjson role "$(echo "$result" | jq 'del(.key)')" '.[$key] = $role' "$ROLES_DB" > "$tmp_file"; then
                _recruit_locked_write "$ROLES_DB" "$tmp_file"
            else
                rm -f "$tmp_file"
                error "Failed to save role to database"
                return 1
            fi

            # Log the invention
            echo "$result" | jq -c --arg trigger "$task_desc" '. + {trigger: $trigger}' >> "$INVENTED_ROLES_LOG" 2>/dev/null || true

            success "Created AI-generated role: ${CYAN}${role_key}${RESET} — ${role_title}"
            echo "  ${role_desc}"
            emit_event "recruit_role_created" "role=${role_key}" "method=ai" "title=${role_title}"
            return 0
        else
            warn "AI generation failed, falling back to manual creation"
        fi

        # Generate a slug from the task description for the fallback key
        role_key="custom-$(echo "$task_desc" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -c1-50)"
        role_title="$task_desc"
        role_desc="Auto-created role for: ${task_desc}"
    fi

    # Manual role creation
    if [[ -z "$role_title" ]]; then
        role_title="$role_key"
    fi
    if [[ -z "$role_desc" ]]; then
        role_desc="Custom role: ${role_title}"
    fi

    local role_json
    role_json=$(jq -n \
        --arg title "$role_title" \
        --arg desc "$role_desc" \
        --arg ts "$(now_iso)" \
        '{
            title: $title,
            description: $desc,
            required_skills: ["general"],
            recommended_model: "sonnet",
            context_needs: ["codebase-structure"],
            success_metrics: ["task-completion"],
            estimated_cost_per_task_usd: 1.5,
            origin: "manual",
            created_at: $ts
        }')

    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN
    if jq --arg key "$role_key" --argjson role "$role_json" '.[$key] = $role' "$ROLES_DB" > "$tmp_file"; then
        _recruit_locked_write "$ROLES_DB" "$tmp_file"
    else
        rm -f "$tmp_file"
        error "Failed to save role to database"
        return 1
    fi

    success "Created role: ${CYAN}${role_key}${RESET} — ${role_title}"
    emit_event "recruit_role_created" "role=${role_key}" "method=manual" "title=${role_title}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ORIGINAL COMMANDS (enhanced)
# ═══════════════════════════════════════════════════════════════════════════════

cmd_roles() {
    ensure_recruit_dir
    initialize_builtin_roles

    info "Available Agent Roles ($(jq 'length' "$ROLES_DB" 2>/dev/null || echo "?") total):"
    echo ""

    jq -r 'to_entries | sort_by(.key) | .[] |
        "\(.key): \(.value.title) — \(.value.description)\n  Model: \(.value.recommended_model) | Cost: $\(.value.estimated_cost_per_task_usd)/task | Origin: \(.value.origin // "builtin")\n  Skills: \(.value.required_skills | join(", "))\n"' \
        "$ROLES_DB"
}

cmd_match() {
    local json_mode=false
    if [[ "${1:-}" == "--json" ]]; then
        json_mode=true
        shift
    fi
    local task_description="${1:-}"

    if [[ -z "$task_description" ]]; then
        error "Usage: shipwright recruit match [--json] \"<task description>\""
        exit 1
    fi

    ensure_recruit_dir
    initialize_builtin_roles

    if ! $json_mode; then
        info "Analyzing task: ${CYAN}${task_description}${RESET}"
        echo ""
    fi

    local primary_role="" secondary_roles="" confidence=0.5 method="keyword" reasoning=""

    # Try LLM-powered matching first
    if _recruit_has_claude; then
        local available_roles
        available_roles=$(jq -c '.' "$ROLES_DB" 2>/dev/null || echo "{}")

        local llm_result
        llm_result=$(_recruit_llm_match "$task_description" "$available_roles")

        if [[ -n "$llm_result" ]] && echo "$llm_result" | jq -e '.primary_role' >/dev/null 2>&1; then
            primary_role=$(echo "$llm_result" | jq -r '.primary_role')
            secondary_roles=$(echo "$llm_result" | jq -r '.secondary_roles // [] | join(", ")')
            confidence=$(echo "$llm_result" | jq -r '.confidence // 0.8')
            reasoning=$(echo "$llm_result" | jq -r '.reasoning // ""')
            method="llm"

            # Check if a new role was suggested
            local new_role_needed
            new_role_needed=$(echo "$llm_result" | jq -r '.new_role_needed // false')
            if [[ "$new_role_needed" == "true" ]]; then
                local suggested
                suggested=$(echo "$llm_result" | jq '.suggested_role // null')
                if [[ "$suggested" != "null" ]]; then
                    echo ""
                    warn "No perfect role match — AI suggests creating a new role:"
                    echo "  $(echo "$suggested" | jq -r '.title // "Unknown"'): $(echo "$suggested" | jq -r '.description // ""')"
                    echo "  Run: shipwright recruit create-role --auto \"${task_description}\""
                    echo ""
                fi
            fi
        fi
    fi

    # Fallback to keyword matching
    if [[ -z "$primary_role" ]]; then
        local detected_skills
        detected_skills=$(_recruit_keyword_match "$task_description")
        primary_role=$(echo "$detected_skills" | awk '{print $1}')
        secondary_roles=$(echo "$detected_skills" | cut -d' ' -f2- | tr ' ' ',' | sed 's/,$//')
        method="keyword"
        confidence=0.5
    fi

    # Validate role exists
    if ! jq -e ".\"${primary_role}\"" "$ROLES_DB" >/dev/null 2>&1; then
        primary_role="builder"
    fi

    # Record for learning
    _recruit_record_match "$task_description" "$primary_role" "$method" "$confidence"

    local role_info
    role_info=$(jq ".\"${primary_role}\"" "$ROLES_DB")
    local recommended_model
    recommended_model=$(echo "$role_info" | jq -r '.recommended_model // "sonnet"')

    # JSON mode: structured output for programmatic consumption
    if $json_mode; then
        jq -c -n \
            --arg role "$primary_role" \
            --arg secondary "$secondary_roles" \
            --argjson confidence "$confidence" \
            --arg method "$method" \
            --arg model "$recommended_model" \
            --arg reasoning "$reasoning" \
            '{
                primary_role: $role,
                secondary_roles: ($secondary | split(", ") | map(select(. != ""))),
                confidence: $confidence,
                method: $method,
                model: $model,
                reasoning: $reasoning
            }'
        return 0
    fi

    success "Recommended role: ${CYAN}${primary_role}${RESET} ${DIM}(confidence: $(awk -v c="$confidence" 'BEGIN{printf "%.0f", c*100}')%, method: ${method})${RESET}"
    [[ -n "$reasoning" ]] && echo -e "  ${DIM}${reasoning}${RESET}"
    echo ""

    echo "  $(echo "$role_info" | jq -r '.description')"
    echo "  Model: ${recommended_model}"
    echo "  Skills: $(echo "$role_info" | jq -r '.required_skills | join(", ")')"

    if [[ -n "$secondary_roles" && "$secondary_roles" != "null" ]]; then
        echo ""
        warn "Secondary roles: ${secondary_roles}"
    fi
}

cmd_evaluate() {
    local agent_id="${1:-}"

    if [[ -z "$agent_id" ]]; then
        error "Usage: shipwright recruit evaluate <agent-id>"
        exit 1
    fi

    ensure_recruit_dir

    info "Evaluating agent: ${CYAN}${agent_id}${RESET}"
    echo ""

    local profile
    profile=$(jq ".\"${agent_id}\"" "$PROFILES_DB" 2>/dev/null || echo "{}")

    if [[ "$profile" == "{}" || "$profile" == "null" ]]; then
        warn "No evaluation history for ${agent_id}"
        return 0
    fi

    echo "Performance Metrics:"
    echo "  Success Rate:     $(echo "$profile" | jq -r '.success_rate // "N/A"')%"
    echo "  Avg Time:         $(echo "$profile" | jq -r '.avg_time_minutes // "N/A"') minutes"
    echo "  Quality Score:    $(echo "$profile" | jq -r '.quality_score // "N/A"')/10"
    echo "  Cost Efficiency:  $(echo "$profile" | jq -r '.cost_efficiency // "N/A"')%"
    echo "  Tasks Completed:  $(echo "$profile" | jq -r '.tasks_completed // "0"')"
    echo ""

    # Use population-aware thresholds for performance evaluation
    local pop_stats
    pop_stats=$(_recruit_compute_population_stats)
    local mean_success
    mean_success=$(echo "$pop_stats" | jq -r '.mean_success')
    local stddev
    stddev=$(echo "$pop_stats" | jq -r '.stddev_success')
    local agent_count
    agent_count=$(echo "$pop_stats" | jq -r '.count')

    local success_rate
    success_rate=$(echo "$profile" | jq -r '.success_rate // 0')

    if [[ "$agent_count" -ge 3 ]]; then
        # Population-aware evaluation
        local promote_threshold demote_threshold
        promote_threshold=$(awk -v m="$mean_success" -v s="$stddev" 'BEGIN{v=m+s; if(v>95) v=95; printf "%.0f", v}')
        demote_threshold=$(awk -v m="$mean_success" -v s="$stddev" 'BEGIN{v=m-s; if(v<40) v=40; printf "%.0f", v}')

        echo -e "  ${DIM}Population thresholds (${agent_count} agents): promote ≥${promote_threshold}%, demote <${demote_threshold}%${RESET}"

        if awk -v sr="$success_rate" -v t="$demote_threshold" 'BEGIN{exit !(sr < t)}' 2>/dev/null; then
            warn "Performance below population threshold. Consider downgrading or retraining."
        elif awk -v sr="$success_rate" -v t="$promote_threshold" 'BEGIN{exit !(sr >= t)}' 2>/dev/null; then
            success "Excellent performance (top tier). Consider for promotion."
        else
            success "Acceptable performance. Continue current assignment."
        fi
    else
        # Fallback to fixed thresholds
        if (( $(echo "$success_rate < 70" | bc -l 2>/dev/null || echo "1") )); then
            warn "Performance below threshold. Consider downgrading or retraining."
        elif (( $(echo "$success_rate >= 90" | bc -l 2>/dev/null || echo "0") )); then
            success "Excellent performance. Consider for promotion."
        else
            success "Acceptable performance. Continue current assignment."
        fi
    fi
}

cmd_profiles() {
    ensure_recruit_dir

    info "Agent Performance Profiles:"
    echo ""

    if [[ ! -s "$PROFILES_DB" || "$(jq 'length' "$PROFILES_DB" 2>/dev/null || echo 0)" -eq 0 ]]; then
        warn "No performance profiles recorded yet"
        return 0
    fi

    jq -r 'to_entries | .[] |
        "\(.key):\n  Success: \(.value.success_rate // "N/A")% | Quality: \(.value.quality_score // "N/A")/10 | Tasks: \(.value.tasks_completed // 0)\n  Avg Time: \(.value.avg_time_minutes // "N/A")min | Efficiency: \(.value.cost_efficiency // "N/A")%\n  Model: \(.value.model // "unknown") | Role: \(.value.role // "unassigned")\n"' \
        "$PROFILES_DB"
}
