#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-recruit.sh — AGI-Level Agent Recruitment & Talent Management        ║
# ║                                                                         ║
# ║  Dynamic role creation · LLM-powered matching · Closed-loop learning   ║
# ║  Self-tuning thresholds · Role evolution · Cross-agent intelligence     ║
# ║  Meta-learning · Autonomous role invention · Theory of mind            ║
# ║  Goal decomposition · Self-modifying heuristics                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECRUIT_VERSION="3.0.0"

# ─── Dependency check ─────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    echo "ERROR: sw-recruit.sh requires 'jq' (JSON processor). Install with:" >&2
    echo "  macOS:  brew install jq" >&2
    echo "  Ubuntu: sudo apt install jq" >&2
    echo "  Alpine: apk add jq" >&2
    exit 1
fi

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
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
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
CYAN="${CYAN:-\033[38;2;0;212;255m}"
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"
BLUE="${BLUE:-\033[38;2;0;102;255m}"
GREEN="${GREEN:-\033[38;2;74;222;128m}"
YELLOW="${YELLOW:-\033[38;2;250;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
RESET="${RESET:-\033[0m}"

# ─── File Locking for Concurrent Safety ────────────────────────────────────
# Usage: _recruit_locked_write <target_file> <tmp_file>
# Acquires flock, then moves tmp_file to target atomically.
# Caller is responsible for creating tmp_file and cleaning up on error.
_recruit_locked_write() {
    local target="$1"
    local tmp_file="$2"
    local lock_file="${target}.lock"

    (
        if command -v flock &>/dev/null; then
            flock -w 5 200 2>/dev/null || true
        fi
        mv "$tmp_file" "$target"
    ) 200>"$lock_file"
}

# ─── Recruitment Storage Paths ─────────────────────────────────────────────
RECRUIT_ROOT="${HOME}/.shipwright/recruitment"
ROLES_DB="${RECRUIT_ROOT}/roles.json"
PROFILES_DB="${RECRUIT_ROOT}/profiles.json"
TALENT_DB="${RECRUIT_ROOT}/talent.json"
ONBOARDING_DB="${RECRUIT_ROOT}/onboarding.json"
MATCH_HISTORY="${RECRUIT_ROOT}/match-history.jsonl"
ROLE_USAGE_DB="${RECRUIT_ROOT}/role-usage.json"
HEURISTICS_DB="${RECRUIT_ROOT}/heuristics.json"
AGENT_MINDS_DB="${RECRUIT_ROOT}/agent-minds.json"
INVENTED_ROLES_LOG="${RECRUIT_ROOT}/invented-roles.jsonl"
META_LEARNING_DB="${RECRUIT_ROOT}/meta-learning.json"

# ─── Policy Integration ──────────────────────────────────────────────────
POLICY_FILE="${SCRIPT_DIR}/../config/policy.json"
_recruit_policy() {
    local key="$1"
    local default="$2"
    if [[ -f "$POLICY_FILE" ]] && command -v jq &>/dev/null; then
        local val
        val=$(jq -r ".recruit.${key} // empty" "$POLICY_FILE" 2>/dev/null) || true
        [[ -n "$val" ]] && echo "$val" || echo "$default"
    else
        echo "$default"
    fi
}

RECRUIT_CONFIDENCE_THRESHOLD=$(_recruit_policy "match_confidence_threshold" "0.3")
RECRUIT_MAX_MATCH_HISTORY=$(_recruit_policy "max_match_history_size" "5000")
RECRUIT_META_ACCURACY_FLOOR=$(_recruit_policy "meta_learning_accuracy_floor" "50")
RECRUIT_LLM_TIMEOUT=$(_recruit_policy "llm_timeout_seconds" "30")
RECRUIT_DEFAULT_MODEL=$(_recruit_policy "default_model" "sonnet")
RECRUIT_SELF_TUNE_MIN_MATCHES=$(_recruit_policy "self_tune_min_matches" "5")
RECRUIT_PROMOTE_TASKS=$(_recruit_policy "promote_threshold_tasks" "10")
RECRUIT_PROMOTE_SUCCESS=$(_recruit_policy "promote_threshold_success_rate" "85")
RECRUIT_AUTO_EVOLVE_AFTER=$(_recruit_policy "auto_evolve_after_outcomes" "20")

ensure_recruit_dir() {
    mkdir -p "$RECRUIT_ROOT"
    [[ -f "$ROLES_DB" ]]          || echo '{}' > "$ROLES_DB"
    [[ -f "$PROFILES_DB" ]]       || echo '{}' > "$PROFILES_DB"
    [[ -f "$TALENT_DB" ]]         || echo '[]' > "$TALENT_DB"
    [[ -f "$ONBOARDING_DB" ]]     || echo '{}' > "$ONBOARDING_DB"
    [[ -f "$ROLE_USAGE_DB" ]]     || echo '{}' > "$ROLE_USAGE_DB"
    [[ -f "$HEURISTICS_DB" ]]     || echo '{"keyword_weights":{},"match_accuracy":[],"last_tuned":"never"}' > "$HEURISTICS_DB"
    [[ -f "$AGENT_MINDS_DB" ]]    || echo '{}' > "$AGENT_MINDS_DB"
    [[ -f "$META_LEARNING_DB" ]]  || echo '{"corrections":[],"accuracy_trend":[],"last_reflection":"never"}' > "$META_LEARNING_DB"
}

# ─── Intelligence Engine (optional) ────────────────────────────────────────
INTELLIGENCE_AVAILABLE=false
if [[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]]; then
    # shellcheck source=sw-intelligence.sh
    source "$SCRIPT_DIR/sw-intelligence.sh"
    INTELLIGENCE_AVAILABLE=true
fi

# Check if Claude CLI is available for LLM-powered features
# Set SW_RECRUIT_NO_LLM=1 to disable LLM calls (e.g., in tests)
_recruit_has_claude() {
    [[ "${SW_RECRUIT_NO_LLM:-}" == "1" ]] && return 1
    command -v claude &>/dev/null
}

# Call Claude with a prompt, return text. Falls back gracefully.
_recruit_call_claude() {
    local prompt="$1"
    local model="${2:-sonnet}"

    # Honor the no-LLM flag everywhere (not just _recruit_has_claude)
    [[ "${SW_RECRUIT_NO_LLM:-}" == "1" ]] && { echo ""; return; }

    if [[ "$INTELLIGENCE_AVAILABLE" == "true" ]] && command -v _intelligence_call_claude &>/dev/null; then
        _intelligence_call_claude "$prompt" 2>/dev/null || echo ""
        return
    fi

    if _recruit_has_claude; then
        claude -p "$prompt" --model "$model" 2>/dev/null || echo ""
        return
    fi

    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# BUILT-IN ROLE DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════════

initialize_builtin_roles() {
    ensure_recruit_dir

    if jq -e '.architect' "$ROLES_DB" &>/dev/null 2>&1; then
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

# Heuristic keyword matching (fast fallback)
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
                if echo "$task_lower" | grep -q "$kw_lower" 2>/dev/null; then
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

    if [[ -n "$result" ]] && echo "$result" | jq -e '.primary_role' &>/dev/null 2>&1; then
        echo "$result"
        return 0
    fi

    echo ""
}

# Record a match for learning
# Returns the match_id (epoch-based) so callers can pass it downstream for outcome linking
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

        if [[ -n "$result" ]] && echo "$result" | jq -e '.key' &>/dev/null 2>&1; then
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
# CLOSED-LOOP FEEDBACK INTEGRATION (Tier 1)
# ═══════════════════════════════════════════════════════════════════════════════

# Record task outcome for an agent — called after pipeline completes
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
    trap "rm -f '$tmp_file'" RETURN
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
        trap "rm -f '$tmp_mh'" RETURN
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
    trap "rm -f '$tmp_file'" RETURN
    jq --arg role "$role" --arg event "$event" --arg ts "$(now_iso)" '
        .[$role] = (.[$role] // {matches: 0, successes: 0, failures: 0, last_used: ""}) |
        .[$role].last_used = $ts |
        if $event == "match" then .[$role].matches += 1
        elif $event == "success" then .[$role].successes += 1
        elif $event == "failure" then .[$role].failures += 1
        else . end
    ' "$ROLE_USAGE_DB" > "$tmp_file" && _recruit_locked_write "$ROLE_USAGE_DB" "$tmp_file" || rm -f "$tmp_file"
}

# Analyze role usage and suggest evolution (splits, merges, retirements)
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

# Track which agents excel at which task types
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
        if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
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

        if [[ -n "$result" ]] && echo "$result" | jq -e '.team' &>/dev/null 2>&1; then
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

        if echo "$issue_or_project" | grep -qiE "security|vulnerability|compliance"; then
            recommended_team+=("security-auditor")
        fi
        if echo "$issue_or_project" | grep -qiE "architecture|design|refactor"; then
            recommended_team+=("architect")
        fi
        if echo "$issue_or_project" | grep -qiE "deploy|infra|ci.cd|pipeline"; then
            recommended_team+=("devops")
        fi
        if echo "$issue_or_project" | grep -qiE "performance|speed|latency|optimization"; then
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
        if printf '%s\n' "${recommended_team[@]}" | grep -q "security-auditor"; then
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
        trap "rm -f '$tmp_file'" RETURN
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

# Full meta-learning reflection
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
    trap "rm -f '$tmp_file'" RETURN
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

# Meta feedback loop: checks if self-tune is actually improving accuracy
# If accuracy drops after self-tune, emits a warning and reverts heuristics
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
            trap "rm -f '$tmp_heur'" RETURN
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

    if [[ -n "$result" ]] && echo "$result" | jq -e '.roles | length > 0' &>/dev/null 2>&1; then
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

        if [[ -n "$result" ]] && echo "$result" | jq -e '.working_style' &>/dev/null 2>&1; then
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

        if [[ -n "$result" ]] && echo "$result" | jq -e '.sub_tasks' &>/dev/null 2>&1; then
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
    # Note: match history .outcome is not backfilled, so we use all matches
    # and rely on role-usage success/failure counts to weight quality
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
    trap "rm -f '$tmp_heuristics'" RETURN
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

        if [[ -n "$llm_result" ]] && echo "$llm_result" | jq -e '.primary_role' &>/dev/null 2>&1; then
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
    if ! jq -e ".\"${primary_role}\"" "$ROLES_DB" &>/dev/null 2>&1; then
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

    # Use population-aware thresholds instead of hardcoded ones
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

cmd_help() {
    cat <<EOF
${BOLD}${CYAN}shipwright recruit${RESET} ${DIM}v${RECRUIT_VERSION}${RESET} — AGI-Level Agent Recruitment & Talent Management

${BOLD}CORE COMMANDS${RESET}
  ${CYAN}roles${RESET}                    List all available agent roles (builtin + dynamic)
  ${CYAN}match${RESET} "<task>"           Analyze task → recommend role (LLM + keyword fallback)
  ${CYAN}evaluate${RESET} <id>            Score agent performance (population-aware thresholds)
  ${CYAN}team${RESET} "<issue>"           Recommend optimal team (AI + codebase analysis)
  ${CYAN}profiles${RESET}                 Show all agent performance profiles
  ${CYAN}promote${RESET} <id>             Recommend model upgrades (self-tuning thresholds)
  ${CYAN}onboard${RESET} <role> [agent]   Generate adaptive onboarding context
  ${CYAN}stats${RESET}                    Show recruitment statistics and talent trends

${BOLD}DYNAMIC ROLES (Tier 1)${RESET}
  ${CYAN}create-role${RESET} <key> [title] [desc]   Create a new role manually
  ${CYAN}create-role${RESET} --auto "<task>"         AI-generate a role from task description

${BOLD}FEEDBACK LOOP (Tier 1)${RESET}
  ${CYAN}record-outcome${RESET} <agent> <task> <success|failure> [quality] [duration]
  ${CYAN}ingest-pipeline${RESET} [days]              Ingest outcomes from events.jsonl

${BOLD}INTELLIGENCE (Tier 2)${RESET}
  ${CYAN}evolve${RESET}                   Analyze role usage → suggest splits/merges/retirements
  ${CYAN}specializations${RESET}          Show agent specialization analysis
  ${CYAN}route${RESET} "<task>"           Smart-route task to best available agent

${BOLD}AGI-LEVEL (Tier 3)${RESET}
  ${CYAN}reflect${RESET}                  Meta-learning: analyze matching accuracy
  ${CYAN}invent${RESET}                   Autonomously discover & create new roles
  ${CYAN}mind${RESET} [agent-id]          Theory of mind: agent working style profiles
  ${CYAN}decompose${RESET} "<goal>"       Break vague goals into sub-tasks + role assignments
  ${CYAN}self-tune${RESET}                Self-modify keyword→role heuristics from outcomes
  ${CYAN}audit${RESET}                   Negative-compounding self-audit of all loops and integrations

${BOLD}EXAMPLES${RESET}
  ${DIM}shipwright recruit match "Add OAuth2 authentication"${RESET}
  ${DIM}shipwright recruit create-role --auto "Database migration planning"${RESET}
  ${DIM}shipwright recruit record-outcome agent-001 task-42 success 8 15${RESET}
  ${DIM}shipwright recruit decompose "Make the product enterprise-ready"${RESET}
  ${DIM}shipwright recruit invent${RESET}
  ${DIM}shipwright recruit self-tune${RESET}
  ${DIM}shipwright recruit mind agent-builder-001${RESET}

${BOLD}ROLE CATALOG${RESET}
  Built-in: architect, builder, reviewer, tester, security-auditor,
  docs-writer, optimizer, devops, pm, incident-responder
  + any dynamically created or invented roles

${DIM}Store: ~/.shipwright/recruitment/${RESET}
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# NEGATIVE-COMPOUNDING FEEDBACK LOOP (Self-Audit)
#
# This command systematically asks every hard question about the system:
# - What's broken? What's not wired? What's not fully implemented?
# - Are feedback loops closed? Does data actually flow?
# - Are integrations proven or just claimed?
#
# Findings compound: each audit creates a score, the score feeds into the
# system, and declining scores trigger automated remediation.
# ═══════════════════════════════════════════════════════════════════════════════

cmd_audit() {
    ensure_recruit_dir

    info "Running negative-compounding self-audit..."
    echo ""

    local total_checks=0
    local pass_count=0
    local fail_count=0
    local warnings=()
    local failures=()

    _audit_check() {
        local name="$1"
        local result="$2"  # pass|fail|warn
        local detail="$3"
        total_checks=$((total_checks + 1))
        case "$result" in
            pass) pass_count=$((pass_count + 1)); echo -e "  ${GREEN}✓${RESET} $name" ;;
            fail) fail_count=$((fail_count + 1)); failures+=("$name: $detail"); echo -e "  ${RED}✗${RESET} $name — $detail" ;;
            warn) pass_count=$((pass_count + 1)); warnings+=("$name: $detail"); echo -e "  ${YELLOW}⚠${RESET} $name — $detail" ;;
        esac
    }

    echo -e "${BOLD}1. DATA STORES${RESET}"

    # Check all data stores exist and are valid JSON
    for db_name in ROLES_DB PROFILES_DB ROLE_USAGE_DB HEURISTICS_DB META_LEARNING_DB AGENT_MINDS_DB; do
        local db_path="${!db_name}"
        if [[ -f "$db_path" ]]; then
            if jq empty "$db_path" 2>/dev/null; then
                _audit_check "$db_name is valid JSON" "pass" ""
            else
                _audit_check "$db_name is valid JSON" "fail" "corrupted JSON"
            fi
        else
            _audit_check "$db_name exists" "warn" "not yet created (will be on first use)"
        fi
    done
    [[ -f "$MATCH_HISTORY" ]] && _audit_check "MATCH_HISTORY exists" "pass" "" || _audit_check "MATCH_HISTORY exists" "warn" "no matches yet"
    echo ""

    echo -e "${BOLD}2. FEEDBACK LOOPS${RESET}"

    # Loop 1: Role usage tracking — do successes/failures get updated?
    if [[ -f "$ROLE_USAGE_DB" ]]; then
        local has_outcomes
        has_outcomes=$(jq '[.[]] | map(select(.successes > 0 or .failures > 0)) | length' "$ROLE_USAGE_DB" 2>/dev/null || echo "0")
        if [[ "$has_outcomes" -gt 0 ]]; then
            _audit_check "Role usage tracks outcomes (successes/failures)" "pass" ""
        else
            _audit_check "Role usage tracks outcomes (successes/failures)" "warn" "all roles have 0 successes & 0 failures — run pipelines first"
        fi
    else
        _audit_check "Role usage tracks outcomes" "warn" "no role-usage.json yet"
    fi

    # Loop 2: Match → outcome linkage
    if [[ -f "$MATCH_HISTORY" ]]; then
        local has_match_ids
        has_match_ids=$(head -5 "$MATCH_HISTORY" | jq -r '.match_id // empty' 2>/dev/null | head -1)
        if [[ -n "$has_match_ids" ]]; then
            _audit_check "Match history has match_id for outcome linkage" "pass" ""
        else
            _audit_check "Match history has match_id for outcome linkage" "fail" "old records lack match_id — run new matches"
        fi

        local resolved_outcomes
        resolved_outcomes=$(grep -cE '"outcome":"(success|failure)"' "$MATCH_HISTORY" 2>/dev/null | tr -d '[:space:]' || true)
        resolved_outcomes="${resolved_outcomes:-0}"
        local total_mh
        total_mh=$(wc -l < "$MATCH_HISTORY" 2>/dev/null | tr -d ' ')
        if [[ "$resolved_outcomes" -gt 0 ]]; then
            _audit_check "Match outcomes backfilled" "pass" "${resolved_outcomes}/${total_mh} resolved"
        else
            _audit_check "Match outcomes backfilled" "warn" "0/${total_mh} resolved — need pipeline outcomes"
        fi
    else
        _audit_check "Match → outcome linkage" "warn" "no match history yet"
    fi

    # Loop 3: Self-tune effectiveness
    if [[ -f "$HEURISTICS_DB" ]]; then
        local kw_count
        kw_count=$(jq '.keyword_weights | length' "$HEURISTICS_DB" 2>/dev/null || echo "0")
        if [[ "$kw_count" -gt 0 ]]; then
            _audit_check "Self-tune has learned keyword weights" "pass" "${kw_count} keywords"
        else
            _audit_check "Self-tune has learned keyword weights" "warn" "empty — need more match/outcome data"
        fi
    else
        _audit_check "Self-tune active" "warn" "no heuristics.json yet"
    fi

    # Loop 4: Meta-learning accuracy trend
    if [[ -f "$META_LEARNING_DB" ]]; then
        local trend_len
        trend_len=$(jq '.accuracy_trend | length' "$META_LEARNING_DB" 2>/dev/null || echo "0")
        if [[ "$trend_len" -ge 3 ]]; then
            local latest_acc
            latest_acc=$(jq '.accuracy_trend[-1].accuracy' "$META_LEARNING_DB" 2>/dev/null || echo "0")
            local floor="${RECRUIT_META_ACCURACY_FLOOR:-50}"
            if awk -v a="$latest_acc" -v f="$floor" 'BEGIN{exit !(a >= f)}'; then
                _audit_check "Meta-learning accuracy above floor" "pass" "${latest_acc}% >= ${floor}%"
            else
                _audit_check "Meta-learning accuracy above floor" "fail" "${latest_acc}% < ${floor}%"
            fi
        else
            _audit_check "Meta-learning has accuracy trend" "warn" "only ${trend_len} data points (need 3+)"
        fi
    else
        _audit_check "Meta-learning active" "warn" "no meta-learning.json yet"
    fi
    echo ""

    echo -e "${BOLD}3. INTEGRATION WIRING${RESET}"

    # Check each integration exists in the source
    for script_check in \
        "sw-pipeline.sh:sw-recruit.sh.*match.*--json:pipeline model selection" \
        "sw-pipeline.sh:sw-recruit.sh.*ingest-pipeline:pipeline auto-ingest" \
        "sw-pipeline.sh:agent_id=.*PIPELINE_AGENT_ID:pipeline agent_id in events" \
        "sw-pm.sh:sw-recruit.sh.*team.*--json:PM team integration" \
        "sw-triage.sh:sw-recruit.sh.*team.*--json:triage team integration" \
        "sw-loop.sh:sw-recruit.sh.*team.*--json:loop role assignment" \
        "sw-loop.sh:recruit_roles_db:loop recruit DB descriptions" \
        "sw-swarm.sh:sw-recruit.sh.*match.*--json:swarm type selection" \
        "sw-autonomous.sh:sw-recruit.sh.*match.*--json:autonomous model selection" \
        "sw-autonomous.sh:sw-recruit.sh.*team.*--json:autonomous team recommendation" \
        "sw-pipeline.sh:intelligence_validate_prediction:pipeline intelligence validation" \
        "sw-pipeline.sh:confirm-anomaly:pipeline predictive anomaly confirmation" \
        "sw-pipeline.sh:fix-outcome.*true.*false:pipeline memory negative fix-outcome" \
        "sw-triage.sh:gh_available=false:triage offline fallback support"; do
        local sc="${script_check%%:*}"; local rest="${script_check#*:}"
        local pat="${rest%%:*}"; local desc="${rest#*:}"
        if [[ -f "$SCRIPT_DIR/$sc" ]] && grep -qE "$pat" "$SCRIPT_DIR/$sc" 2>/dev/null; then
            _audit_check "$desc ($sc)" "pass" ""
        else
            _audit_check "$desc ($sc)" "fail" "pattern not found"
        fi
    done
    echo ""

    echo -e "${BOLD}4. POLICY GOVERNANCE${RESET}"

    if [[ -f "$POLICY_FILE" ]]; then
        local has_recruit_section
        has_recruit_section=$(jq '.recruit // empty' "$POLICY_FILE" 2>/dev/null)
        if [[ -n "$has_recruit_section" ]]; then
            _audit_check "policy.json has recruit section" "pass" ""
        else
            _audit_check "policy.json has recruit section" "fail" "missing recruit section"
        fi
    else
        _audit_check "policy.json exists" "fail" "config/policy.json not found"
    fi
    echo ""

    echo -e "${BOLD}5. AUTOMATION TRIGGERS${RESET}"

    grep -q "cmd_self_tune.*2>/dev/null" "$SCRIPT_DIR/sw-recruit.sh" && \
        _audit_check "Self-tune auto-triggers after ingest" "pass" "" || \
        _audit_check "Self-tune auto-triggers after ingest" "fail" "not wired"

    grep -q "cmd_evolve.*2>/dev/null" "$SCRIPT_DIR/sw-recruit.sh" && \
        _audit_check "Evolve auto-triggers after sufficient outcomes" "pass" "" || \
        _audit_check "Evolve auto-triggers after sufficient outcomes" "fail" "not wired"

    grep -q "_recruit_meta_validate_self_tune" "$SCRIPT_DIR/sw-recruit.sh" && \
        _audit_check "Meta-validation runs during reflect" "pass" "" || \
        _audit_check "Meta-validation runs during reflect" "fail" "not wired"
    echo ""

    # ── Compute score ────────────────────────────────────────────────────────
    local score
    score=$(awk -v p="$pass_count" -v t="$total_checks" 'BEGIN{if(t>0) printf "%.1f", (p/t)*100; else print "0"}')

    echo "════════════════════════════════════════════════════════════════"
    echo -e "${BOLD}AUDIT SCORE:${RESET} ${score}% (${pass_count}/${total_checks} checks passed, ${fail_count} failures, ${#warnings[@]} warnings)"
    echo "════════════════════════════════════════════════════════════════"

    # Record audit result in events for trend tracking
    emit_event "recruit_audit" "score=${score}" "passed=${pass_count}" "failed=${fail_count}" "warnings=${#warnings[@]}" "total=${total_checks}"

    # Track audit score trend in meta-learning DB
    if [[ -f "$META_LEARNING_DB" ]]; then
        local tmp_audit
        tmp_audit=$(mktemp)
        trap "rm -f '$tmp_audit'" RETURN
        jq --argjson score "$score" --arg ts "$(now_iso)" --argjson fails "$fail_count" '
            .audit_trend = ((.audit_trend // []) + [{score: $score, ts: $ts, failures: $fails}] | .[-50:])
        ' "$META_LEARNING_DB" > "$tmp_audit" && _recruit_locked_write "$META_LEARNING_DB" "$tmp_audit" || rm -f "$tmp_audit"
    fi

    # Negative compounding: if score is declining, escalate
    if [[ -f "$META_LEARNING_DB" ]]; then
        local audit_trend_len
        audit_trend_len=$(jq '.audit_trend // [] | length' "$META_LEARNING_DB" 2>/dev/null || echo "0")
        if [[ "$audit_trend_len" -ge 3 ]]; then
            local prev_score
            prev_score=$(jq '.audit_trend[-2].score // 100' "$META_LEARNING_DB" 2>/dev/null || echo "100")
            if awk -v c="$score" -v p="$prev_score" 'BEGIN{exit !(c < p - 5)}'; then
                echo ""
                warn "NEGATIVE COMPOUND: Audit score DECLINED from ${prev_score}% to ${score}%"
                warn "System health is degrading. Failures that compound:"
                for f in "${failures[@]}"; do
                    echo -e "  ${RED}→${RESET} $f"
                done
                emit_event "recruit_audit_decline" "from=${prev_score}" "to=${score}" "failures=${fail_count}"
            fi
        fi
    fi

    if [[ ${#failures[@]} -gt 0 ]]; then
        echo ""
        echo -e "${RED}${BOLD}FAILURES REQUIRING ACTION:${RESET}"
        for f in "${failures[@]}"; do
            echo -e "  ${RED}→${RESET} $f"
        done
    fi

    [[ "$fail_count" -gt 0 ]] && return 1 || return 0
}

# ─── Main Router ──────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ensure_recruit_dir

    cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        roles)              cmd_roles ;;
        match)              cmd_match "$@" ;;
        evaluate)           cmd_evaluate "$@" ;;
        team)               cmd_team "$@" ;;
        profiles)           cmd_profiles ;;
        promote)            cmd_promote "$@" ;;
        onboard)            cmd_onboard "$@" ;;
        stats)              cmd_stats ;;
        create-role)        cmd_create_role "$@" ;;
        record-outcome)     cmd_record_outcome "$@" ;;
        ingest-pipeline)    cmd_ingest_pipeline "$@" ;;
        evolve)             cmd_evolve ;;
        specializations)    cmd_specializations ;;
        route)              cmd_route "$@" ;;
        reflect)            cmd_reflect ;;
        invent)             cmd_invent ;;
        mind)               cmd_mind "$@" ;;
        decompose)          cmd_decompose "$@" ;;
        self-tune)          cmd_self_tune ;;
        audit)              cmd_audit ;;
        help|--help|-h)     cmd_help ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
fi
