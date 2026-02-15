#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-recruit.sh — Agent Recruitment & Talent Management System            ║
# ║                                                                           ║
# ║  Role definitions · Skill matching · Performance evaluation · Team       ║
# ║  composition recommendations · Agent promotion/demotion based on metrics ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
GREEN='\033[38;2;74;222;128m'   # success
YELLOW='\033[38;2;250;204;21m'  # warning
RED='\033[38;2;248;113;113m'    # error
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Structured Event Log ──────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

emit_event() {
    local event_type="$1"
    shift
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            val="${val//\"/\\\"}"
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Recruitment Storage Paths ─────────────────────────────────────────────
RECRUIT_ROOT="${HOME}/.shipwright/recruitment"
ROLES_DB="${RECRUIT_ROOT}/roles.json"
PROFILES_DB="${RECRUIT_ROOT}/profiles.json"
TALENT_DB="${RECRUIT_ROOT}/talent.json"
ONBOARDING_DB="${RECRUIT_ROOT}/onboarding.json"

ensure_recruit_dir() {
    mkdir -p "$RECRUIT_ROOT"
    [[ -f "$ROLES_DB" ]]       || echo '{}' > "$ROLES_DB"
    [[ -f "$PROFILES_DB" ]]    || echo '{}' > "$PROFILES_DB"
    [[ -f "$TALENT_DB" ]]      || echo '[]' > "$TALENT_DB"
    [[ -f "$ONBOARDING_DB" ]]  || echo '{}' > "$ONBOARDING_DB"
}

# ─── Built-in Role Definitions ────────────────────────────────────────────
initialize_builtin_roles() {
    ensure_recruit_dir

    # Check if roles already initialized
    if jq -e '.architect' "$ROLES_DB" &>/dev/null 2>&1; then
        return 0
    fi

    local roles_json=$(cat <<'EOF'
{
  "architect": {
    "title": "Architect",
    "description": "System design, architecture decisions, scalability planning",
    "required_skills": ["system-design", "technology-evaluation", "code-review", "documentation"],
    "recommended_model": "opus",
    "context_needs": ["codebase-architecture", "system-patterns", "past-designs", "dependency-graph"],
    "success_metrics": ["design-quality", "implementation-feasibility", "team-alignment"],
    "estimated_cost_per_task_usd": 2.5
  },
  "builder": {
    "title": "Builder",
    "description": "Feature implementation, core development, code generation",
    "required_skills": ["coding", "testing", "debugging", "performance-optimization"],
    "recommended_model": "sonnet",
    "context_needs": ["codebase-structure", "api-specs", "test-patterns", "build-system"],
    "success_metrics": ["tests-passing", "code-quality", "productivity", "bug-rate"],
    "estimated_cost_per_task_usd": 1.5
  },
  "reviewer": {
    "title": "Code Reviewer",
    "description": "Code review, quality assurance, best practices enforcement",
    "required_skills": ["code-review", "static-analysis", "security-review", "best-practices"],
    "recommended_model": "sonnet",
    "context_needs": ["coding-standards", "previous-reviews", "common-errors", "team-patterns"],
    "success_metrics": ["review-quality", "issue-detection-rate", "feedback-clarity"],
    "estimated_cost_per_task_usd": 1.2
  },
  "tester": {
    "title": "Test Specialist",
    "description": "Test strategy, test case generation, test automation, quality validation",
    "required_skills": ["testing", "coverage-analysis", "automation", "edge-case-detection"],
    "recommended_model": "sonnet",
    "context_needs": ["test-framework", "coverage-metrics", "failure-patterns", "requirements"],
    "success_metrics": ["coverage-increase", "bug-detection", "test-execution-time"],
    "estimated_cost_per_task_usd": 1.2
  },
  "security-auditor": {
    "title": "Security Auditor",
    "description": "Security analysis, vulnerability detection, compliance verification",
    "required_skills": ["security-analysis", "threat-modeling", "penetration-testing", "compliance"],
    "recommended_model": "opus",
    "context_needs": ["security-policies", "vulnerability-database", "threat-models", "compliance-reqs"],
    "success_metrics": ["vulnerabilities-found", "severity-accuracy", "remediation-quality"],
    "estimated_cost_per_task_usd": 2.0
  },
  "docs-writer": {
    "title": "Documentation Writer",
    "description": "Documentation creation, API docs, user guides, onboarding materials",
    "required_skills": ["documentation", "clarity", "completeness", "example-generation"],
    "recommended_model": "haiku",
    "context_needs": ["codebase-knowledge", "api-specs", "user-personas", "doc-templates"],
    "success_metrics": ["documentation-completeness", "clarity-score", "example-coverage"],
    "estimated_cost_per_task_usd": 0.8
  },
  "optimizer": {
    "title": "Performance Optimizer",
    "description": "Performance analysis, optimization, profiling, efficiency improvements",
    "required_skills": ["performance-analysis", "profiling", "optimization", "metrics-analysis"],
    "recommended_model": "sonnet",
    "context_needs": ["performance-benchmarks", "profiling-tools", "optimization-history"],
    "success_metrics": ["performance-gain", "memory-efficiency", "latency-reduction"],
    "estimated_cost_per_task_usd": 1.5
  },
  "devops": {
    "title": "DevOps Engineer",
    "description": "Infrastructure, deployment pipelines, CI/CD, monitoring, reliability",
    "required_skills": ["infrastructure-as-code", "deployment", "monitoring", "incident-response"],
    "recommended_model": "sonnet",
    "context_needs": ["infrastructure-config", "deployment-pipelines", "monitoring-setup", "runbooks"],
    "success_metrics": ["deployment-success-rate", "incident-response-time", "uptime"],
    "estimated_cost_per_task_usd": 1.8
  },
  "pm": {
    "title": "Project Manager",
    "description": "Task decomposition, priority management, stakeholder communication, tracking",
    "required_skills": ["task-decomposition", "prioritization", "communication", "planning"],
    "recommended_model": "sonnet",
    "context_needs": ["project-state", "requirements", "team-capacity", "past-estimates"],
    "success_metrics": ["estimation-accuracy", "deadline-met", "scope-management"],
    "estimated_cost_per_task_usd": 1.0
  },
  "incident-responder": {
    "title": "Incident Responder",
    "description": "Crisis management, root cause analysis, rapid issue resolution, hotfixes",
    "required_skills": ["crisis-management", "root-cause-analysis", "debugging", "communication"],
    "recommended_model": "opus",
    "context_needs": ["incident-history", "system-health", "alerting-rules", "past-incidents"],
    "success_metrics": ["incident-resolution-time", "accuracy", "escalation-prevention"],
    "estimated_cost_per_task_usd": 2.0
  }
}
EOF
)
    echo "$roles_json" | jq '.' > "$ROLES_DB"
    success "Initialized 10 built-in agent roles"
}

# ─── Command Implementations ───────────────────────────────────────────────

cmd_roles() {
    ensure_recruit_dir
    initialize_builtin_roles

    info "Available Agent Roles:"
    echo ""

    jq -r 'to_entries | .[] |
        "\(.key): \(.value.title) — \(.value.description)\n  Model: \(.value.recommended_model) | Cost: $\(.value.estimated_cost_per_task_usd)/task\n  Skills: \(.value.required_skills | join(", "))\n"' \
        "$ROLES_DB"
}

cmd_match() {
    local task_description="${1:-}"

    if [[ -z "$task_description" ]]; then
        error "Usage: shipwright recruit match \"<task description>\""
        exit 1
    fi

    ensure_recruit_dir
    initialize_builtin_roles

    info "Analyzing task: ${CYAN}${task_description}${RESET}"
    echo ""

    # Simple keyword-based matching (can be enhanced with Claude)
    local detected_skills=""

    [[ "$task_description" =~ (architecture|design|scalability) ]] && detected_skills="${detected_skills}architect "
    [[ "$task_description" =~ (build|feature|implement|code) ]] && detected_skills="${detected_skills}builder "
    [[ "$task_description" =~ (review|quality|best.practice) ]] && detected_skills="${detected_skills}reviewer "
    [[ "$task_description" =~ (test|coverage|automation) ]] && detected_skills="${detected_skills}tester "
    [[ "$task_description" =~ (security|vulnerability|compliance) ]] && detected_skills="${detected_skills}security-auditor "
    [[ "$task_description" =~ (doc|guide|readme) ]] && detected_skills="${detected_skills}docs-writer "
    [[ "$task_description" =~ (performance|optimization|profile) ]] && detected_skills="${detected_skills}optimizer "
    [[ "$task_description" =~ (deploy|infra|ci.cd|monitoring) ]] && detected_skills="${detected_skills}devops "
    [[ "$task_description" =~ (plan|decompose|estimate|priorit) ]] && detected_skills="${detected_skills}pm "
    [[ "$task_description" =~ (urgent|incident|crisis|hotfix) ]] && detected_skills="${detected_skills}incident-responder "

    # Default to builder if no match
    if [[ -z "$detected_skills" ]]; then
        detected_skills="builder"
    fi

    # Show top recommendations
    local primary_role
    primary_role=$(echo "$detected_skills" | awk '{print $1}')

    success "Recommended role: ${CYAN}${primary_role}${RESET}"
    echo ""

    local role_info
    role_info=$(jq ".\"${primary_role}\"" "$ROLES_DB")
    echo "  $(echo "$role_info" | jq -r '.description')"
    echo "  Model: $(echo "$role_info" | jq -r '.recommended_model')"
    echo "  Skills: $(echo "$role_info" | jq -r '.required_skills | join(", ")')"

    if [[ "$(echo "$detected_skills" | wc -w)" -gt 1 ]]; then
        echo ""
        warn "Secondary roles detected: $(echo "$detected_skills" | cut -d' ' -f2-)"
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

    # Get agent profile
    local profile
    profile=$(jq ".\"${agent_id}\"" "$PROFILES_DB" 2>/dev/null || echo "{}")

    if [[ "$profile" == "{}" ]]; then
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

    # Recommendation
    local success_rate
    success_rate=$(echo "$profile" | jq -r '.success_rate // 0')

    if (( $(echo "$success_rate < 70" | bc -l 2>/dev/null || echo "1") )); then
        warn "Performance below threshold. Consider downgrading or retraining."
    elif (( $(echo "$success_rate >= 90" | bc -l 2>/dev/null || echo "0") )); then
        success "Excellent performance. Consider for promotion."
    else
        success "Acceptable performance. Continue current assignment."
    fi
}

cmd_team() {
    local issue_or_project="${1:-}"

    if [[ -z "$issue_or_project" ]]; then
        error "Usage: shipwright recruit team <issue|project>"
        exit 1
    fi

    ensure_recruit_dir
    initialize_builtin_roles

    info "Recommending team composition for: ${CYAN}${issue_or_project}${RESET}"
    echo ""

    # Default recommendation: builder + reviewer + tester
    local recommended_team=("builder" "reviewer" "tester")

    # Add security auditor for security-related issues
    if echo "$issue_or_project" | grep -qiE "security|vulnerability|compliance"; then
        recommended_team+=("security-auditor")
    fi

    # Add architect for design issues
    if echo "$issue_or_project" | grep -qiE "architecture|design|refactor"; then
        recommended_team+=("architect")
    fi

    success "Recommended Team Composition (${#recommended_team[@]} members):"
    echo ""

    for role in "${recommended_team[@]}"; do
        local role_info
        role_info=$(jq ".\"${role}\"" "$ROLES_DB")
        printf "  • ${CYAN}%-20s${RESET} (${PURPLE}%s${RESET}) — %s\n" \
            "$role" \
            "$(echo "$role_info" | jq -r '.recommended_model')" \
            "$(echo "$role_info" | jq -r '.title')"
    done

    echo ""
    local total_cost
    total_cost=$(printf "%.2f" $(
        for role in "${recommended_team[@]}"; do
            jq ".\"${role}\".estimated_cost_per_task_usd" "$ROLES_DB"
        done | awk '{sum+=$1} END {print sum}'
    ))
    echo "Estimated Team Cost: \$${total_cost}/task"
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
        "\(.key):\n  Success: \(.value.success_rate // "N/A")% | Quality: \(.value.quality_score // "N/A")/10 | Tasks: \(.value.tasks_completed // 0)\n  Avg Time: \(.value.avg_time_minutes // "N/A")min | Efficiency: \(.value.cost_efficiency // "N/A")%\n"' \
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

    if [[ "$profile" == "{}" ]]; then
        warn "No profile found for ${agent_id}"
        return 1
    fi

    local success_rate quality_score
    success_rate=$(echo "$profile" | jq -r '.success_rate // 0')
    quality_score=$(echo "$profile" | jq -r '.quality_score // 0')

    local current_model
    current_model=$(echo "$profile" | jq -r '.model // "haiku"')

    local recommended_model="$current_model"
    local promotion_reason=""

    if (( $(echo "$success_rate >= 95 && $quality_score >= 9" | bc -l 2>/dev/null || echo "0") )); then
        case "$current_model" in
            haiku)    recommended_model="sonnet"; promotion_reason="Excellent performance on Haiku" ;;
            sonnet)   recommended_model="opus"; promotion_reason="Outstanding results on Sonnet" ;;
            opus)     promotion_reason="Already on best model"; recommended_model="opus" ;;
        esac
    elif (( $(echo "$success_rate < 60 || $quality_score < 5" | bc -l 2>/dev/null || echo "0") )); then
        case "$current_model" in
            opus)     recommended_model="sonnet"; promotion_reason="Struggling on Opus, try Sonnet" ;;
            sonnet)   recommended_model="haiku"; promotion_reason="Poor performance, reduce cost" ;;
            haiku)    promotion_reason="Consider retraining"; recommended_model="haiku" ;;
        esac
    fi

    if [[ "$recommended_model" != "$current_model" ]]; then
        success "Recommend upgrading from ${CYAN}${current_model}${RESET} to ${PURPLE}${recommended_model}${RESET}"
        echo "  Reason: $promotion_reason"
        emit_event "recruit_promotion" "agent_id=${agent_id}" "from=${current_model}" "to=${recommended_model}" "reason=${promotion_reason}"
    else
        info "No model change recommended for ${agent_id}"
        echo "  Current: ${current_model} | Success: ${success_rate}% | Quality: ${quality_score}/10"
    fi
}

cmd_onboard() {
    local agent_role="${1:-builder}"

    ensure_recruit_dir
    initialize_builtin_roles

    info "Generating onboarding context for: ${CYAN}${agent_role}${RESET}"
    echo ""

    local role_info
    role_info=$(jq ".${agent_role}" "$ROLES_DB" 2>/dev/null)

    if [[ -z "$role_info" || "$role_info" == "null" ]]; then
        error "Unknown role: ${agent_role}"
        exit 1
    fi

    # Create onboarding document
    local onboarding_doc=$(cat <<EOF
# Onboarding Context: ${agent_role}

## Role Profile
**Title:** $(echo "$role_info" | jq -r '.title')
**Description:** $(echo "$role_info" | jq -r '.description')
**Recommended Model:** $(echo "$role_info" | jq -r '.recommended_model')

## Required Skills
$(echo "$role_info" | jq -r '.required_skills[]' | sed 's/^/- /')

## Context Needs
$(echo "$role_info" | jq -r '.context_needs[]' | sed 's/^/- /')

## Success Metrics
$(echo "$role_info" | jq -r '.success_metrics[]' | sed 's/^/- /')

## Cost Profile
Estimated cost per task: \$$(echo "$role_info" | jq -r '.estimated_cost_per_task_usd')

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
- Past learnings: Available in ~/.shipwright/memory/
EOF
)

    # Save to onboarding DB
    local onboarding_key=$(date +%s)
    jq --arg key "$onboarding_key" --arg doc "$onboarding_doc" '.[$key] = $doc' "$ONBOARDING_DB" > "${ONBOARDING_DB}.tmp"
    mv "${ONBOARDING_DB}.tmp" "$ONBOARDING_DB"

    success "Onboarding context generated for ${agent_role}"
    echo ""
    echo "$onboarding_doc"
    emit_event "recruit_onboarding" "role=${agent_role}" "timestamp=$(now_epoch)"
}

cmd_stats() {
    ensure_recruit_dir

    info "Recruitment Statistics & Talent Trends:"
    echo ""

    # Count roles
    local role_count
    role_count=$(jq 'length' "$ROLES_DB" 2>/dev/null || echo 0)

    # Count profiles
    local profile_count
    profile_count=$(jq 'length' "$PROFILES_DB" 2>/dev/null || echo 0)

    # Count talent entries
    local talent_count
    talent_count=$(jq 'length' "$TALENT_DB" 2>/dev/null || echo 0)

    echo "  Roles Defined:        $role_count"
    echo "  Agents Profiled:      $profile_count"
    echo "  Talent Records:       $talent_count"
    echo ""

    # Average metrics
    if [[ "$profile_count" -gt 0 ]]; then
        local avg_success
        avg_success=$(jq '[.[].success_rate // 0] | add / length' "$PROFILES_DB" 2>/dev/null || echo "0")

        local avg_quality
        avg_quality=$(jq '[.[].quality_score // 0] | add / length' "$PROFILES_DB" 2>/dev/null || echo "0")

        echo "  Avg Success Rate:     ${avg_success}%"
        echo "  Avg Quality Score:    ${avg_quality}/10"
        echo ""
    fi

    success "Use 'shipwright recruit profiles' for detailed breakdown"
}

cmd_help() {
    cat <<EOF
${BOLD}${CYAN}shipwright recruit${RESET} — Agent Recruitment & Talent Management

${BOLD}USAGE${RESET}
  ${CYAN}shipwright recruit${RESET} <command> [options]

${BOLD}COMMANDS${RESET}
  ${CYAN}roles${RESET}              List all available agent roles and skill requirements
  ${CYAN}match${RESET} "<task>"     Analyze task and recommend best agent role
  ${CYAN}evaluate${RESET} <id>      Score an agent's recent performance
  ${CYAN}team${RESET} "<issue>"     Recommend optimal team composition for an issue/project
  ${CYAN}profiles${RESET}           Show performance profiles by agent type
  ${CYAN}promote${RESET} <id>       Recommend model upgrades for agents (haiku→sonnet→opus)
  ${CYAN}onboard${RESET} <role>     Generate onboarding context for a new agent
  ${CYAN}stats${RESET}              Show recruitment statistics and talent trends
  ${CYAN}help${RESET}               Show this help message

${BOLD}EXAMPLES${RESET}
  ${DIM}shipwright recruit roles${RESET}
  ${DIM}shipwright recruit match "Add authentication system"${RESET}
  ${DIM}shipwright recruit team issue-123${RESET}
  ${DIM}shipwright recruit evaluate agent-builder-001${RESET}
  ${DIM}shipwright recruit promote agent-builder-001${RESET}
  ${DIM}shipwright recruit onboard architect${RESET}

${BOLD}ROLE CATALOG${RESET}
  Built-in roles: architect, builder, reviewer, tester, security-auditor,
  docs-writer, optimizer, devops, pm, incident-responder

${DIM}Store: ~/.shipwright/recruitment/${RESET}
EOF
}

# ─── Main Router ──────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ensure_recruit_dir

    cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        roles)      cmd_roles ;;
        match)      cmd_match "$@" ;;
        evaluate)   cmd_evaluate "$@" ;;
        team)       cmd_team "$@" ;;
        profiles)   cmd_profiles ;;
        promote)    cmd_promote "$@" ;;
        onboard)    cmd_onboard "$@" ;;
        stats)      cmd_stats ;;
        help|--help|-h)  cmd_help ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
fi
