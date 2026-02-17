#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pm — Autonomous PM Agent for Team Orchestration              ║
# ║  Intelligent team sizing · Composition · Stage orchestration              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ─── PM History Storage ──────────────────────────────────────────────────────
PM_HISTORY="${HOME}/.shipwright/pm-history.json"

# ─── Ensure PM history file exists ───────────────────────────────────────────
ensure_pm_history() {
    mkdir -p "${HOME}/.shipwright"
    if [[ ! -f "$PM_HISTORY" ]]; then
        echo '{"decisions":[],"outcomes":[]}' > "$PM_HISTORY"
    fi
}

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo -e "${CYAN}${BOLD}shipwright pm${RESET} ${DIM}v${VERSION}${RESET} — Autonomous PM agent for team orchestration"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright pm${RESET} <subcommand> [options]"
    echo ""
    echo -e "${BOLD}SUBCOMMANDS${RESET}"
    echo -e "  ${CYAN}analyze${RESET} <issue-num>              Deep analysis of issue complexity and scope"
    echo -e "  ${CYAN}team${RESET} <issue-num>                 Recommend team composition and pipeline"
    echo -e "  ${CYAN}orchestrate${RESET} <issue-num>          Plan stage execution and parallelization"
    echo -e "  ${CYAN}recommend${RESET} <issue-num>            Full PM recommendation (all above combined)"
    echo -e "  ${CYAN}learn${RESET} <issue-num> <outcome>      Record outcome (success|failure) for learning"
    echo -e "  ${CYAN}history${RESET} [--json|--pattern]       Show past decisions and outcomes"
    echo -e "  ${CYAN}help${RESET}                             Show this help message"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright pm analyze 42${RESET}                   # Analyze issue 42"
    echo -e "  ${DIM}shipwright pm team 42${RESET}                      # Get team recommendation"
    echo -e "  ${DIM}shipwright pm recommend 42${RESET}                 # Full recommendation"
    echo -e "  ${DIM}shipwright pm learn 42 success${RESET}             # Record successful outcome"
    echo -e "  ${DIM}shipwright pm history${RESET}                     # Show past decisions"
    echo -e "  ${DIM}shipwright pm history --pattern${RESET}           # Show success patterns"
    echo ""
    echo -e "${DIM}Docs: $(_sw_docs_url)  |  GitHub: $(_sw_github_url)${RESET}"
}

# ─── analyze_issue <issue_num> ───────────────────────────────────────────────
# Fetches issue and analyzes file scope, complexity, and risk
analyze_issue() {
    local issue_num="$1"
    local analysis

    # Check if gh is available and not disabled
    if [[ -n "${NO_GITHUB:-}" ]]; then
        warn "GitHub API disabled (NO_GITHUB set)"
        # Return mock analysis
        analysis=$(jq -n \
            --arg issue "$issue_num" \
            --arg file_scope "mock" \
            --arg complexity "5" \
            --arg risk "medium" \
            --arg effort_hours "8" \
            '{
                issue: $issue,
                file_scope: $file_scope,
                complexity: ($complexity | tonumber),
                risk: $risk,
                estimated_effort_hours: ($effort_hours | tonumber),
                recommendation: "mock analysis - GitHub API disabled"
            }')
        echo "$analysis"
        return 0
    fi

    # Fetch issue metadata
    local issue_data
    if ! issue_data=$(gh issue view "$issue_num" --json title,body,labels,createdAt 2>/dev/null); then
        error "Failed to fetch issue #${issue_num}"
        return 1
    fi

    local title body labels
    title=$(echo "$issue_data" | jq -r '.title // ""')
    body=$(echo "$issue_data" | jq -r '.body // ""')
    labels=$(echo "$issue_data" | jq -r '.labels[].name' | tr '\n' ',' | sed 's/,$//')

    # Analyze title and body for keywords
    local is_bugfix is_feature is_refactor is_security is_perf
    is_bugfix=$(echo "$title $body" | grep -iq "bug\|fix\|issue" && echo "true" || echo "false")
    is_feature=$(echo "$title $body" | grep -iq "feature\|add\|new\|implement" && echo "true" || echo "false")
    is_refactor=$(echo "$title $body" | grep -iq "refactor\|refactoring\|cleanup" && echo "true" || echo "false")
    is_security=$(echo "$title $body" | grep -iq "security\|vulnerability\|cve\|auth" && echo "true" || echo "false")
    is_perf=$(echo "$title $body" | grep -iq "performance\|perf\|speed\|optimize" && echo "true" || echo "false")

    # Count estimated files affected by analyzing body content
    local file_scope complexity risk estimated_hours
    local files_mentioned
    files_mentioned=$(echo "$body" | grep -o '\b[a-zA-Z0-9_.-]*\.[a-z]*' | sort -u | wc -l || echo "0")
    files_mentioned=$((files_mentioned + 1))  # At least 1 file

    # Determine file scope
    if [[ "$files_mentioned" -le 2 ]]; then
        file_scope="single_module"
    elif [[ "$files_mentioned" -le 5 ]]; then
        file_scope="multiple_modules"
    else
        file_scope="cross_system"
    fi

    # Calculate complexity (1-10 scale)
    complexity=5
    [[ "$is_bugfix" == "true" ]] && complexity=$((complexity - 2))
    [[ "$is_refactor" == "true" ]] && complexity=$((complexity + 2))
    [[ "$is_feature" == "true" ]] && complexity=$((complexity + 1))
    [[ "$is_security" == "true" ]] && complexity=$((complexity + 3))
    [[ "$is_perf" == "true" ]] && complexity=$((complexity + 2))
    [[ "${#body}" -gt 500 ]] && complexity=$((complexity + 1))
    complexity=$((complexity > 10 ? 10 : complexity < 1 ? 1 : complexity))

    # Determine risk
    if [[ "$is_security" == "true" ]]; then
        risk="critical"
    elif [[ "$is_refactor" == "true" ]]; then
        risk="high"
    elif [[ "$is_perf" == "true" ]]; then
        risk="medium"
    elif [[ "$is_bugfix" == "true" && "$file_scope" == "single_module" ]]; then
        risk="low"
    else
        risk="medium"
    fi

    # Estimate effort
    case "$complexity" in
        1|2|3)   estimated_hours=4 ;;
        4|5|6)   estimated_hours=8 ;;
        7|8)     estimated_hours=16 ;;
        9|10)    estimated_hours=32 ;;
        *)       estimated_hours=8 ;;
    esac

    analysis=$(jq -n \
        --arg issue "$issue_num" \
        --arg file_scope "$file_scope" \
        --arg complexity "$complexity" \
        --arg risk "$risk" \
        --arg effort_hours "$estimated_hours" \
        --arg title "$title" \
        --arg is_bugfix "$is_bugfix" \
        --arg is_feature "$is_feature" \
        --arg is_refactor "$is_refactor" \
        --arg is_security "$is_security" \
        --arg is_perf "$is_perf" \
        --arg files_count "$files_mentioned" \
        --arg labels "$labels" \
        '{
            issue: $issue,
            title: $title,
            file_scope: $file_scope,
            complexity: ($complexity | tonumber),
            risk: $risk,
            estimated_effort_hours: ($effort_hours | tonumber),
            estimated_files_affected: ($files_count | tonumber),
            labels: $labels,
            characteristics: {
                is_bugfix: ($is_bugfix == "true"),
                is_feature: ($is_feature == "true"),
                is_refactor: ($is_refactor == "true"),
                is_security: ($is_security == "true"),
                is_performance_critical: ($is_perf == "true")
            },
            recommendation: ("Based on complexity " + $complexity + ", estimated " + $effort_hours + "h effort")
        }')

    echo "$analysis"
}

# ─── recommend_team <analysis_json> ──────────────────────────────────────────
# Based on analysis, recommend team composition
# Tries recruit's AI/heuristic team composition first, falls back to hardcoded rules.
recommend_team() {
    local analysis="$1"

    # ── Try recruit-powered team composition first ──
    if [[ -x "${SCRIPT_DIR:-}/sw-recruit.sh" ]]; then
        local issue_title
        issue_title=$(echo "$analysis" | jq -r '.title // .recommendation // ""' 2>/dev/null || true)
        if [[ -n "$issue_title" ]]; then
            local recruit_result
            recruit_result=$(bash "$SCRIPT_DIR/sw-recruit.sh" team --json "$issue_title" 2>/dev/null) || true
            if [[ -n "$recruit_result" ]] && echo "$recruit_result" | jq -e '.team' &>/dev/null 2>&1; then
                local recruit_roles recruit_model recruit_agents recruit_cost
                recruit_roles=$(echo "$recruit_result" | jq -r '.team | join(",")')
                recruit_model=$(echo "$recruit_result" | jq -r '.model // "sonnet"')
                recruit_agents=$(echo "$recruit_result" | jq -r '.agents // 2')
                recruit_cost=$(echo "$recruit_result" | jq -r '.estimated_cost // 0')

                # Map recruit roles/model to PM output format
                local max_iterations=5
                local template="standard"
                if [[ "$recruit_agents" -ge 4 ]]; then template="full"; max_iterations=8;
                elif [[ "$recruit_agents" -le 1 ]]; then template="fast"; max_iterations=3;
                fi

                local team_rec
                team_rec=$(jq -n \
                    --arg roles "$recruit_roles" \
                    --arg template "$template" \
                    --arg model "$recruit_model" \
                    --arg max_iter "$max_iterations" \
                    --arg agents "$recruit_agents" \
                    --arg cost "$recruit_cost" \
                    '{
                        roles: ($roles | split(",")),
                        template: $template,
                        model: $model,
                        max_iterations: ($max_iter | tonumber),
                        estimated_agents: ($agents | tonumber),
                        confidence_percent: 80,
                        risk_factors: "recruit-powered recommendation",
                        mitigation_strategies: "AI-optimized team composition",
                        source: "recruit"
                    }')
                echo "$team_rec"
                return 0
            fi
        fi
    fi

    # ── Fallback: hardcoded heuristic team composition ──
    local complexity risk is_security is_perf file_scope
    complexity=$(echo "$analysis" | jq -r '.complexity')
    risk=$(echo "$analysis" | jq -r '.risk')
    is_security=$(echo "$analysis" | jq -r '.characteristics.is_security')
    is_perf=$(echo "$analysis" | jq -r '.characteristics.is_performance_critical')
    file_scope=$(echo "$analysis" | jq -r '.file_scope')

    local roles template model max_iterations estimated_agents
    local confidence risk_factors mitigations

    # Determine base team and template
    if [[ "$complexity" -le 3 && "$file_scope" == "single_module" ]]; then
        # Simple bugfix
        roles="builder"
        template="fast"
        estimated_agents=1
        model="haiku"
        max_iterations=3
        confidence=85
        risk_factors="Low complexity, single module"
        mitigations="Standard code review"
    elif [[ "$complexity" -le 5 && "$file_scope" == "multiple_modules" ]]; then
        # Small feature
        roles="builder,tester"
        template="standard"
        estimated_agents=2
        model="sonnet"
        max_iterations=5
        confidence=80
        risk_factors="Moderate complexity across modules"
        mitigations="Build + test iteration cycles"
    elif [[ "$complexity" -le 7 && "$file_scope" == "multiple_modules" ]]; then
        # Medium feature
        roles="builder,builder,tester"
        template="standard"
        estimated_agents=3
        model="sonnet"
        max_iterations=6
        confidence=75
        risk_factors="Moderate-high complexity, coordination needed"
        mitigations="Parallel builders with test validation"
    else
        # Complex feature or cross-system change
        roles="builder,builder,tester,reviewer"
        template="full"
        estimated_agents=4
        model="opus"
        max_iterations=8
        confidence=70
        risk_factors="High complexity, cross-system impact"
        mitigations="Full pipeline with review gates"
    fi

    # Add security specialist if needed
    if [[ "$is_security" == "true" ]]; then
        roles="${roles},security-auditor"
        estimated_agents=$((estimated_agents + 1))
        confidence=$((confidence - 10))
        risk_factors="${risk_factors}; security-sensitive changes"
        mitigations="${mitigations}; security review before merge"
    fi

    # Adjust for risk level
    case "$risk" in
        critical)
            template="enterprise"
            max_iterations=$((max_iterations + 4))
            confidence=$((confidence - 15))
            risk_factors="${risk_factors}; critical risk"
            mitigations="${mitigations}; emergency rollback plan"
            ;;
        high)
            template="full"
            max_iterations=$((max_iterations + 2))
            confidence=$((confidence - 5))
            ;;
    esac

    # Add performance specialist if needed
    if [[ "$is_perf" == "true" ]]; then
        roles="${roles},optimizer"
        estimated_agents=$((estimated_agents + 1))
        confidence=$((confidence - 5))
        risk_factors="${risk_factors}; performance-critical"
        mitigations="${mitigations}; performance benchmarking"
    fi

    # Cap confidence
    confidence=$((confidence > 95 ? 95 : confidence < 50 ? 50 : confidence))

    local team_rec
    team_rec=$(jq -n \
        --arg roles "$roles" \
        --arg template "$template" \
        --arg model "$model" \
        --arg max_iter "$max_iterations" \
        --arg agents "$estimated_agents" \
        --arg confidence "$confidence" \
        --arg risk_factors "$risk_factors" \
        --arg mitigations "$mitigations" \
        '{
            roles: ($roles | split(",")),
            template: $template,
            model: $model,
            max_iterations: ($max_iter | tonumber),
            estimated_agents: ($agents | tonumber),
            confidence_percent: ($confidence | tonumber),
            risk_factors: $risk_factors,
            mitigation_strategies: $mitigations
        }')

    echo "$team_rec"
}

# ─── orchestrate_stages <analysis_json> ──────────────────────────────────────
# Plan which stages to run and in what parallel groups
orchestrate_stages() {
    local analysis="$1"

    local complexity file_scope
    complexity=$(echo "$analysis" | jq -r '.complexity')
    file_scope=$(echo "$analysis" | jq -r '.file_scope')

    # Base stages
    local stages_json

    if [[ "$complexity" -le 3 && "$file_scope" == "single_module" ]]; then
        # Fast track: minimal stages
        stages_json=$(jq -n '[
            {name: "intake", parallel_group: 1, agents: 1, timeout_minutes: 5, skip_if: false},
            {name: "build", parallel_group: 2, agents: 1, timeout_minutes: 10, skip_if: false},
            {name: "test", parallel_group: 3, agents: 1, timeout_minutes: 5, skip_if: false},
            {name: "pr", parallel_group: 4, agents: 1, timeout_minutes: 5, skip_if: false}
        ]')
    elif [[ "$complexity" -le 5 ]]; then
        # Standard track
        stages_json=$(jq -n '[
            {name: "intake", parallel_group: 1, agents: 1, timeout_minutes: 5, skip_if: false},
            {name: "plan", parallel_group: 2, agents: 1, timeout_minutes: 10, skip_if: false},
            {name: "build", parallel_group: 3, agents: 1, timeout_minutes: 15, skip_if: false},
            {name: "test", parallel_group: 4, agents: 1, timeout_minutes: 10, skip_if: false},
            {name: "review", parallel_group: 5, agents: 1, timeout_minutes: 10, skip_if: false},
            {name: "pr", parallel_group: 6, agents: 1, timeout_minutes: 5, skip_if: false}
        ]')
    else
        # Full track with parallelization
        stages_json=$(jq -n '[
            {name: "intake", parallel_group: 1, agents: 1, timeout_minutes: 5, skip_if: false},
            {name: "plan", parallel_group: 2, agents: 1, timeout_minutes: 15, skip_if: false},
            {name: "design", parallel_group: 3, agents: 1, timeout_minutes: 20, skip_if: false},
            {name: "build", parallel_group: 4, agents: 2, timeout_minutes: 20, skip_if: false},
            {name: "test", parallel_group: 5, agents: 1, timeout_minutes: 15, skip_if: false},
            {name: "review", parallel_group: 6, agents: 1, timeout_minutes: 15, skip_if: false},
            {name: "compound_quality", parallel_group: 6, agents: 1, timeout_minutes: 10, skip_if: false},
            {name: "pr", parallel_group: 7, agents: 1, timeout_minutes: 5, skip_if: false}
        ]')
    fi

    echo "$stages_json"
}

# ─── cmd_analyze <issue_num> ────────────────────────────────────────────────
cmd_analyze() {
    local issue_num="${1:-}"
    if [[ -z "$issue_num" ]]; then
        error "Usage: shipwright pm analyze <issue-num>"
        return 1
    fi

    info "Analyzing issue #${issue_num}..."
    local analysis
    analysis=$(analyze_issue "$issue_num")

    # Output as formatted JSON
    echo "$analysis" | jq '.'
    emit_event "pm.analyze" "issue=${issue_num}"
}

# ─── cmd_team <issue_num> ───────────────────────────────────────────────────
cmd_team() {
    local issue_num="${1:-}"
    if [[ -z "$issue_num" ]]; then
        error "Usage: shipwright pm team <issue-num>"
        return 1
    fi

    info "Analyzing issue #${issue_num} for team composition..."
    local analysis
    analysis=$(analyze_issue "$issue_num")

    local team_rec
    team_rec=$(recommend_team "$analysis")

    echo "$team_rec" | jq '.'
    emit_event "pm.team" "issue=${issue_num}"
}

# ─── cmd_orchestrate <issue_num> ────────────────────────────────────────────
cmd_orchestrate() {
    local issue_num="${1:-}"
    if [[ -z "$issue_num" ]]; then
        error "Usage: shipwright pm orchestrate <issue-num>"
        return 1
    fi

    info "Planning stage orchestration for issue #${issue_num}..."
    local analysis
    analysis=$(analyze_issue "$issue_num")

    local stages
    stages=$(orchestrate_stages "$analysis")

    echo "$stages" | jq '.'
    emit_event "pm.orchestrate" "issue=${issue_num}"
}

# ─── cmd_recommend <issue_num> [--json] ──────────────────────────────────────
cmd_recommend() {
    local json_mode="false"
    local issue_num=""
    if [[ "${1:-}" == "--json" ]]; then
        json_mode="true"
        issue_num="${2:-}"
    else
        issue_num="${1:-}"
    fi
    if [[ -z "$issue_num" ]]; then
        error "Usage: shipwright pm recommend <issue-num> [--json]"
        return 1
    fi

    [[ "$json_mode" != "true" ]] && info "Generating full PM recommendation for issue #${issue_num}..."
    local analysis team_rec stages

    analysis=$(analyze_issue "$issue_num")
    team_rec=$(recommend_team "$analysis")
    stages=$(orchestrate_stages "$analysis")

    # Combine into comprehensive recommendation
    local recommendation
    recommendation=$(jq -n \
        --argjson analysis "$analysis" \
        --argjson team "$team_rec" \
        --argjson stages "$stages" \
        '{
            issue: $analysis.issue,
            title: $analysis.title,
            analysis: $analysis,
            team_composition: $team,
            stage_orchestration: $stages,
            recommendation_timestamp: "'$(now_iso)'"
        }')

    if [[ "$json_mode" == "true" ]]; then
        echo "$recommendation"
        ensure_pm_history
        local tmp_hist
        tmp_hist=$(mktemp)
        trap "rm -f '$tmp_hist'" RETURN
        jq --argjson rec "$recommendation" '.decisions += [$rec]' "$PM_HISTORY" > "$tmp_hist" && mv "$tmp_hist" "$PM_HISTORY"
        emit_event "pm.recommend" "issue=${issue_num}"
        return 0
    fi

    # Pretty-print
    echo ""
    echo -e "${BOLD}PM RECOMMENDATION FOR ISSUE #${issue_num}${RESET}"
    echo -e "${DIM}$(echo "$analysis" | jq -r '.title')${RESET}"
    echo ""
    echo -e "${CYAN}${BOLD}ANALYSIS${RESET}"
    echo "$analysis" | jq -r '"  File Scope: \(.file_scope)\n  Complexity: \(.complexity)/10\n  Risk Level: \(.risk)\n  Estimated Effort: \(.estimated_effort_hours)h\n  Files Affected: ~\(.estimated_files_affected)"'
    echo ""
    echo -e "${CYAN}${BOLD}TEAM COMPOSITION${RESET}"
    echo "$team_rec" | jq -r '"  Roles: \(.roles | join(", "))\n  Team Size: \(.estimated_agents) agents\n  Pipeline Template: \(.template)\n  Model: \(.model)\n  Max Iterations: \(.max_iterations)\n  Confidence: \(.confidence_percent)%"'
    echo ""
    echo -e "${CYAN}${BOLD}RISK ASSESSMENT${RESET}"
    echo "$team_rec" | jq -r '"  Factors: \(.risk_factors)\n  Mitigations: \(.mitigation_strategies)"'
    echo ""
    echo -e "${CYAN}${BOLD}STAGE PLAN${RESET}"
    echo "$stages" | jq -r '.[] | "  \(.parallel_group). \(.name) (group \(.parallel_group), \(.agents) agent\(if .agents > 1 then "s" else "" end), \(.timeout_minutes)m)"'
    echo ""

    # Save to history
    ensure_pm_history
    local tmp_hist
    tmp_hist=$(mktemp)
    trap "rm -f '$tmp_hist'" RETURN
    jq --argjson rec "$recommendation" '.decisions += [$rec]' "$PM_HISTORY" > "$tmp_hist" && mv "$tmp_hist" "$PM_HISTORY"

    success "Recommendation saved to history"
    emit_event "pm.recommend" "issue=${issue_num}"
}

# ─── cmd_learn <issue_num> <outcome> ────────────────────────────────────────
cmd_learn() {
    local issue_num="${1:-}"
    local outcome="${2:-}"

    if [[ -z "$issue_num" || -z "$outcome" ]]; then
        error "Usage: shipwright pm learn <issue-num> <outcome>"
        echo "  outcome: success or failure"
        return 1
    fi

    if [[ "$outcome" != "success" && "$outcome" != "failure" ]]; then
        error "Outcome must be 'success' or 'failure'"
        return 1
    fi

    ensure_pm_history

    # Find the recommendation in history
    local recommendation
    recommendation=$(jq -c --arg issue "$issue_num" '.decisions[] | select(.issue == $issue)' "$PM_HISTORY" 2>/dev/null | tail -1)

    if [[ -z "$recommendation" ]]; then
        warn "No previous recommendation found for issue #${issue_num}"
        recommendation='null'
    fi

    # Record the outcome
    local outcome_record
    if [[ "$recommendation" == "null" ]]; then
        outcome_record=$(jq -n \
            --arg issue "$issue_num" \
            --arg outcome "$outcome" \
            --arg timestamp "$(now_iso)" \
            '{
                issue: $issue,
                outcome: $outcome,
                recorded_at: $timestamp,
                recommendation: null
            }')
    else
        outcome_record=$(jq -n \
            --arg issue "$issue_num" \
            --arg outcome "$outcome" \
            --arg timestamp "$(now_iso)" \
            --argjson recommendation "$recommendation" \
            '{
                issue: $issue,
                outcome: $outcome,
                recorded_at: $timestamp,
                recommendation: $recommendation
            }')
    fi

    # Save to history
    local tmp_hist
    tmp_hist=$(mktemp)
    trap "rm -f '$tmp_hist'" RETURN
    jq --argjson outcome "$outcome_record" '.outcomes += [$outcome]' "$PM_HISTORY" > "$tmp_hist" && mv "$tmp_hist" "$PM_HISTORY"

    success "Recorded ${outcome} outcome for issue #${issue_num}"
    emit_event "pm.learn" "issue=${issue_num}" "outcome=${outcome}"
}

# ─── cmd_history [--json|--pattern] ─────────────────────────────────────────
cmd_history() {
    local format="${1:-table}"

    ensure_pm_history

    case "$format" in
        --json)
            jq '.' "$PM_HISTORY"
            ;;
        --pattern)
            # Show success patterns
            info "Success patterns from past recommendations:"
            echo ""

            local total_decisions success_count fail_count
            total_decisions=$(jq '.outcomes | length' "$PM_HISTORY")
            success_count=$(jq '[.outcomes[] | select(.outcome == "success")] | length' "$PM_HISTORY")
            fail_count=$(jq '[.outcomes[] | select(.outcome == "failure")] | length' "$PM_HISTORY")

            if [[ "$total_decisions" -gt 0 ]]; then
                local success_rate
                success_rate=$((success_count * 100 / total_decisions))
                echo -e "${CYAN}Overall Success Rate: ${BOLD}${success_rate}%${RESET} (${success_count}/${total_decisions})"
                echo ""

                # Group by template
                echo -e "${CYAN}${BOLD}Success Rate by Pipeline Template${RESET}"
                jq -r '
                    [.outcomes[] | select(.outcome == "success")] as $successes |
                    [.decisions[]] as $decisions |
                    [
                        ("fast", "standard", "full", "hotfix", "enterprise") as $template |
                        {
                            template: $template,
                            total: ([.decisions[] | select(.team_composition.template == $template)] | length),
                            success: ([$successes[] | select(.recommendation.team_composition.template == $template)] | length)
                        } |
                        select(.total > 0) |
                        .success_rate = (if .total > 0 then (.success * 100 / .total) else 0 end)
                    ] |
                    sort_by(-.success_rate)
                ' "$PM_HISTORY" | jq -r '.[] | "  \(.template): \(.success)/\(.total) (\(.success_rate | round)%)"'
                echo ""

                # Group by team size
                echo -e "${CYAN}${BOLD}Success Rate by Team Size${RESET}"
                jq -r '
                    [.outcomes[] | select(.outcome == "success")] as $successes |
                    [
                        (1, 2, 3, 4, 5) as $size |
                        {
                            size: $size,
                            total: ([.decisions[] | select(.team_composition.estimated_agents == $size)] | length),
                            success: ([$successes[] | select(.recommendation.team_composition.estimated_agents == $size)] | length)
                        } |
                        select(.total > 0) |
                        .success_rate = (if .total > 0 then (.success * 100 / .total) else 0 end)
                    ] |
                    sort_by(-.success_rate)
                ' "$PM_HISTORY" | jq -r '.[] | "  \(.size) agents: \(.success)/\(.total) (\(.success_rate | round)%)"'
            else
                warn "No history recorded yet"
            fi
            ;;
        *)
            # Show as pretty table
            if jq -e '.decisions | length > 0' "$PM_HISTORY" >/dev/null 2>&1; then
                echo -e "${CYAN}${BOLD}Past PM Recommendations${RESET}"
                echo ""
                jq -r '
                    .decisions[] |
                    "Issue #\(.issue): \(.title) (complexity: \(.analysis.complexity)/10, team: \(.team_composition.estimated_agents) agents, template: \(.team_composition.template))"
                ' "$PM_HISTORY"
                echo ""
            else
                info "No recommendations in history yet"
            fi

            if jq -e '.outcomes | length > 0' "$PM_HISTORY" >/dev/null 2>&1; then
                echo -e "${CYAN}${BOLD}Recorded Outcomes${RESET}"
                echo ""
                jq -r '.outcomes[] | "Issue #\(.issue): \(.outcome) (recorded: \(.recorded_at))"' "$PM_HISTORY"
            fi
            ;;
    esac
}

# ─── Main command router ────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        analyze)
            cmd_analyze "$@"
            ;;
        team)
            cmd_team "$@"
            ;;
        orchestrate)
            cmd_orchestrate "$@"
            ;;
        recommend)
            cmd_recommend "$@"
            ;;
        learn)
            cmd_learn "$@"
            ;;
        history)
            cmd_history "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# ─── Source guard ───────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
