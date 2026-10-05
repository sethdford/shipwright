#\!/bin/bash
# pipeline-stages.sh — Stage implementations loader
# Sources domain-specific stage modules (intake, build, review, delivery, monitor).
# Source from sw-pipeline.sh. Requires all pipeline globals and state/github/detection/quality modules.
[[ -n "${_PIPELINE_STAGES_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_LOADED=1

# Source skill registry for dynamic prompt injection
_SKILL_REGISTRY_SH="${SCRIPT_DIR}/lib/skill-registry.sh"
[[ -f "$_SKILL_REGISTRY_SH" ]] && source "$_SKILL_REGISTRY_SH"

# Source skill memory for learning system
_SKILL_MEMORY_SH="${SCRIPT_DIR}/lib/skill-memory.sh"
[[ -f "$_SKILL_MEMORY_SH" ]] && source "$_SKILL_MEMORY_SH"

# Source dark factory modules (test holdout, spec-driven, causal graph)
[[ -f "$SCRIPT_DIR/lib/test-holdout.sh" ]] && source "$SCRIPT_DIR/lib/test-holdout.sh" 2>/dev/null || true
[[ -f "$SCRIPT_DIR/lib/spec-driven.sh" ]] && source "$SCRIPT_DIR/lib/spec-driven.sh" 2>/dev/null || true
[[ -f "$SCRIPT_DIR/lib/causal-graph.sh" ]] && source "$SCRIPT_DIR/lib/causal-graph.sh" 2>/dev/null || true
[[ -f "$SCRIPT_DIR/lib/constitutional.sh" ]] && source "$SCRIPT_DIR/lib/constitutional.sh" 2>/dev/null || true
[[ -f "$SCRIPT_DIR/lib/formal-spec.sh" ]] && source "$SCRIPT_DIR/lib/formal-spec.sh" 2>/dev/null || true
[[ -f "$SCRIPT_DIR/lib/mutation-executor.sh" ]] && source "$SCRIPT_DIR/lib/mutation-executor.sh" 2>/dev/null || true
# Cross-session reinforcement learning optimizer (Phase 7)
[[ -f "$SCRIPT_DIR/lib/rl-optimizer.sh" ]] && source "$SCRIPT_DIR/lib/rl-optimizer.sh" 2>/dev/null || true
# Autoresearch RL modules (Phase 8): reward aggregation, bandit selection, policy learning
[[ -f "$SCRIPT_DIR/lib/reward-aggregator.sh" ]] && source "$SCRIPT_DIR/lib/reward-aggregator.sh" 2>/dev/null || true
[[ -f "$SCRIPT_DIR/lib/bandit-selector.sh" ]] && source "$SCRIPT_DIR/lib/bandit-selector.sh" 2>/dev/null || true
[[ -f "$SCRIPT_DIR/lib/policy-learner.sh" ]] && source "$SCRIPT_DIR/lib/policy-learner.sh" 2>/dev/null || true
# Pre-build toolchain check, run at the top of intake
[[ -f "$SCRIPT_DIR/lib/prebuild-check.sh" ]] && source "$SCRIPT_DIR/lib/prebuild-check.sh" 2>/dev/null || true

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
PIPELINE_CONFIG="${PIPELINE_CONFIG:-}"
PIPELINE_NAME="${PIPELINE_NAME:-pipeline}"
MODEL="${MODEL:-opus}"
BASE_BRANCH="${BASE_BRANCH:-main}"
NO_GITHUB="${NO_GITHUB:-false}"
ISSUE_NUMBER="${ISSUE_NUMBER:-}"
ISSUE_BODY="${ISSUE_BODY:-}"
ISSUE_LABELS="${ISSUE_LABELS:-}"
ISSUE_MILESTONE="${ISSUE_MILESTONE:-}"
GOAL="${GOAL:-}"
TASK_TYPE="${TASK_TYPE:-feature}"
INTELLIGENCE_ISSUE_TYPE="${INTELLIGENCE_ISSUE_TYPE:-backend}"
TEST_CMD="${TEST_CMD:-}"
GIT_BRANCH="${GIT_BRANCH:-}"
TASKS_FILE="${TASKS_FILE:-}"

# ─── Context pruning helpers ────────────────────────────────────────────────

# prune_context_section — Intelligently truncate a context section to fit a char budget.
#   $1: section name (for logging/markers)
#   $2: content string
#   $3: max_chars (default 5000)
# For JSON content (starts with { or [): extracts summary fields via jq.
# For text content: sandwich approach — keeps first + last N lines.
# Outputs the (possibly truncated) content to stdout.
prune_context_section() {
    local section_name="${1:-section}"
    local content="${2:-}"
    local max_chars="${3:-5000}"

    [[ -z "$content" ]] && return 0

    local content_len=${#content}
    if [[ "$content_len" -le "$max_chars" ]]; then
        printf '%s' "$content"
        return 0
    fi

    # JSON content — try jq summary extraction
    local first_char="${content:0:1}"
    if [[ "$first_char" == "{" || "$first_char" == "[" ]]; then
        local summary=""
        # Try extracting summary/results fields
        summary=$(printf '%s' "$content" | jq -r '
            if type == "object" then
                to_entries | map(
                    if (.value | type) == "array" then
                        "\(.key): \(.value | length) items"
                    elif (.value | type) == "object" then
                        "\(.key): \(.value | keys | join(", "))"
                    else
                        "\(.key): \(.value)"
                    end
                ) | join("\n")
            elif type == "array" then
                .[:5] | map(tostring) | join("\n")
            else . end
        ' 2>/dev/null) || true

        if [[ -n "$summary" && ${#summary} -le "$max_chars" ]]; then
            printf '%s' "$summary"
            return 0
        fi
        # jq failed or still too large — fall through to text truncation
    fi

    # Text content — sandwich approach (first N + last N lines)
    local line_count=0
    line_count=$(printf '%s\n' "$content" | wc -l | xargs)

    # Calculate how many lines to keep from each end
    # Approximate chars-per-line to figure out line budget
    local avg_chars_per_line=80
    if [[ "$line_count" -gt 0 ]]; then
        avg_chars_per_line=$(( content_len / line_count ))
        [[ "$avg_chars_per_line" -lt 20 ]] && avg_chars_per_line=20
    fi
    local total_lines_budget=$(( max_chars / avg_chars_per_line ))
    [[ "$total_lines_budget" -lt 4 ]] && total_lines_budget=4
    local half=$(( total_lines_budget / 2 ))

    local head_part=""
    local tail_part=""
    head_part=$(printf '%s\n' "$content" | head -"$half")
    tail_part=$(printf '%s\n' "$content" | tail -"$half")

    printf '%s\n[... %s truncated: %d→%d chars ...]\n%s' \
        "$head_part" "$section_name" "$content_len" "$max_chars" "$tail_part"
}

# guard_prompt_size — Warn and hard-truncate if prompt exceeds budget.
#   $1: stage name (for logging)
#   $2: prompt content
#   $3: max_chars (default 100000)
# Outputs the (possibly truncated) prompt to stdout.
PIPELINE_PROMPT_BUDGET="${PIPELINE_PROMPT_BUDGET:-100000}"

guard_prompt_size() {
    local stage_name="${1:-stage}"
    local prompt="${2:-}"
    local max_chars="${3:-$PIPELINE_PROMPT_BUDGET}"

    local prompt_len=${#prompt}
    if [[ "$prompt_len" -le "$max_chars" ]]; then
        printf '%s' "$prompt"
        return 0
    fi

    warn "${stage_name} prompt too large (${prompt_len} chars, budget ${max_chars}) — truncating"
    emit_event "pipeline.prompt_truncated" \
        "stage=$stage_name" \
        "original=$prompt_len" \
        "budget=$max_chars" 2>/dev/null || true

    printf '%s\n\n... [CONTEXT TRUNCATED: %s prompt exceeded %d char budget. Focus on the goal and requirements.]' \
        "${prompt:0:$max_chars}" "$stage_name" "$max_chars"
}

# ─── Safe git helpers ────────────────────────────────────────────────────────
# BASE_BRANCH may not exist locally (e.g. --local mode with no remote).
# These helpers return empty output instead of crashing under set -euo pipefail.
_safe_base_log() {
    local branch="${BASE_BRANCH:-main}"
    git rev-parse --verify "$branch" >/dev/null 2>&1 || { echo ""; return 0; }
    git log "$@" "${branch}..HEAD" 2>/dev/null || true
}

_safe_base_diff() {
    local branch="${BASE_BRANCH:-main}"
    git rev-parse --verify "$branch" >/dev/null 2>&1 || { git diff HEAD~5 "$@" 2>/dev/null || true; return 0; }
    git diff "${branch}...HEAD" "$@" 2>/dev/null || true
}

show_stage_preview() {
    local stage_id="$1"
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Stage: ${stage_id} ━━━${RESET}"
    case "$stage_id" in
        intake)   echo -e "  Fetch issue, detect task type, create branch, self-assign" ;;
        plan)     echo -e "  Generate plan via Claude, post task checklist to issue" ;;
        design)   echo -e "  Generate Architecture Decision Record (ADR), evaluate alternatives" ;;
        build)    echo -e "  Delegate to ${CYAN}shipwright loop${RESET} for autonomous building" ;;
        test_first) echo -e "  Generate tests from requirements (TDD mode) before implementation" ;;
        test)     echo -e "  Run test suite and check coverage" ;;
        review)   echo -e "  AI code review on the diff, post findings" ;;
        compound_quality) echo -e "  Adversarial review, negative tests, e2e, DoD audit" ;;
        pr)       echo -e "  Create GitHub PR with labels, reviewers, milestone" ;;
        merge)    echo -e "  Wait for CI checks, merge PR, optionally delete branch" ;;
        deploy)   echo -e "  Deploy to staging/production with rollback" ;;
        validate) echo -e "  Smoke tests, health checks, close issue" ;;
        monitor)  echo -e "  Post-deploy monitoring, health checks, auto-rollback" ;;
    esac
    echo ""
}

# ─── Load domain-specific stage modules ───────────────────────────────────────

# Load scope enforcement module for planned vs actual file tracking
_SCOPE_ENFORCEMENT_SH="${SCRIPT_DIR}/lib/scope-enforcement.sh"
[[ -f "$_SCOPE_ENFORCEMENT_SH" ]] && source "$_SCOPE_ENFORCEMENT_SH"

_PIPELINE_STAGES_INTAKE_SH="${SCRIPT_DIR}/lib/pipeline-stages-intake.sh"
[[ -f "$_PIPELINE_STAGES_INTAKE_SH" ]] && source "$_PIPELINE_STAGES_INTAKE_SH"

_PIPELINE_STAGES_BUILD_SH="${SCRIPT_DIR}/lib/pipeline-stages-build.sh"
[[ -f "$_PIPELINE_STAGES_BUILD_SH" ]] && source "$_PIPELINE_STAGES_BUILD_SH"

_PIPELINE_STAGES_REVIEW_SH="${SCRIPT_DIR}/lib/pipeline-stages-review.sh"
[[ -f "$_PIPELINE_STAGES_REVIEW_SH" ]] && source "$_PIPELINE_STAGES_REVIEW_SH"

_PIPELINE_STAGES_DELIVERY_SH="${SCRIPT_DIR}/lib/pipeline-stages-delivery.sh"
[[ -f "$_PIPELINE_STAGES_DELIVERY_SH" ]] && source "$_PIPELINE_STAGES_DELIVERY_SH"

_PIPELINE_STAGES_MONITOR_SH="${SCRIPT_DIR}/lib/pipeline-stages-monitor.sh"
[[ -f "$_PIPELINE_STAGES_MONITOR_SH" ]] && source "$_PIPELINE_STAGES_MONITOR_SH"
